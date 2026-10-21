#include <errno.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <pthread.h>
#include <sys/epoll.h>
#include <sys/eventfd.h>
#include <sys/prctl.h>

#include "reactor.h"
#include "core.h"
#include "bond_trans_tool.h"

#define REACTOR_EPOLL_BATCH 64

/* 注册对象状态位 */
#define REG_ACTIVE    0x1u
#define REG_DISABLED  0x2u
#define REG_WANT_OUT  0x4u
#define REG_WANT_IN   0x8u
#define REG_BUSY      0x10u
#define REG_CLOSING   0x20u
#define REG_KICK      0x40u

typedef struct reactor_task {
    struct reactor_task *next;
    void (*fn)(void *);
    void *arg;
} reactor_task_t;

struct reactor_reg {
    reactor_t       *r;
    uint32_t         index;
    atomic_uint      gen;
    uint64_t         data;

    int              fd;         /* arm_lock 保护 */
    reactor_event_fn on_event;
    void            *ctx;

    /* 热路径只读写该原子状态，不再加锁 */
    atomic_uint      state;

    pthread_mutex_t  arm_lock;   /* 串行化 epoll_ctl 与 fd 变更 */
    pthread_mutex_t  lock;       /* add/close 等低频路径 */
    pthread_cond_t   cond;
};

struct reactor {
    int              efd;
    int              wake_fd;
    pthread_t        tids[REACTOR_MAX_WORKERS];
    uint32_t         worker_count;
    atomic_bool      running;

    reactor_reg_t   *regs;
    uint32_t         max_regs;
    pthread_mutex_t  slot_lock;
    uint32_t         gen_seq;

    pthread_mutex_t  post_lock;
    reactor_task_t  *tasks;

    reactor_idle_fn  idle_fn;
    void            *idle_ctx;
};

static void reactor_run_tasks(reactor_t *r)
{
    for (;;) {
        reactor_task_t *task;

        pthread_mutex_lock(&r->post_lock);
        task = r->tasks;
        if (NULL != task)
            r->tasks = task->next;
        pthread_mutex_unlock(&r->post_lock);

        if (NULL == task)
            break;

        if (NULL != task->fn)
            task->fn(task->arg);

        free(task);
    }
}

/* 在 arm_lock 内读取最新状态并重武装；保证最后完成的一次 arm 使用最新的 want 位 */
static void reactor_arm(reactor_reg_t *reg)
{
    uint32_t st;
    int fd;

    pthread_mutex_lock(&reg->arm_lock);

    st = atomic_load_explicit(&reg->state, memory_order_acquire);
    fd = reg->fd;

    if ((st & (REG_ACTIVE | REG_DISABLED | REG_CLOSING)) == REG_ACTIVE && fd >= 0) {
        uint32_t mask = EPOLLONESHOT;

        if (st & REG_WANT_IN)
            mask |= EPOLLIN;
        if (st & REG_WANT_OUT)
            mask |= EPOLLOUT;

        if (0 != core_epoll_mod(reg->r->efd, fd, mask, reg->data)) {
            bt_log_error(LOG_ALL_OUT, "epoll re-arm fd:%d failed! errno:%d\n",
                         fd, errno);
        }
    }

    pthread_mutex_unlock(&reg->arm_lock);
}

/* 抢占 busy: 同一个注册对象同一时刻只允许一个 handler */
static bool reactor_try_enter(reactor_reg_t *reg)
{
    uint32_t st = atomic_load_explicit(&reg->state, memory_order_acquire);

    if (!(st & REG_ACTIVE) || (st & REG_BUSY))
        return false;

    return atomic_compare_exchange_strong_explicit(&reg->state, &st, st | REG_BUSY,
                                                   memory_order_acq_rel,
                                                   memory_order_acquire);
}

static uint32_t reactor_leave(reactor_reg_t *reg)
{
    uint32_t st = atomic_fetch_and_explicit(&reg->state, ~REG_BUSY, memory_order_acq_rel);

    if (st & REG_CLOSING) {
        pthread_mutex_lock(&reg->lock);
        pthread_cond_broadcast(&reg->cond);
        pthread_mutex_unlock(&reg->lock);
    }

    if ((st & (REG_ACTIVE | REG_DISABLED | REG_CLOSING)) == REG_ACTIVE)
        reactor_arm(reg);

    return st;
}

/* 执行一次 handler; 若期间有 kick 请求则继续执行 */
static void reactor_run(reactor_reg_t *reg, uint32_t events)
{
    for (;;) {
        reactor_event_fn fn;
        void *ctx;
        uint32_t st;

        if (!reactor_try_enter(reg))
            return;      /* 已有 handler 在跑: KICK 位由它结束时处理 */

        if (events & REACTOR_EVENT_KICK)
            atomic_fetch_and_explicit(&reg->state, ~REG_KICK, memory_order_acq_rel);

        fn = reg->on_event;
        ctx = reg->ctx;
        if (NULL != fn)
            fn(ctx, events);

        st = reactor_leave(reg);

        if (!(st & REG_KICK) || !(st & REG_ACTIVE))
            break;

        events = REACTOR_EVENT_KICK;
    }
}

static void *reactor_worker_thread(void *arg)
{
    reactor_t *r = arg;
    struct epoll_event events[REACTOR_EPOLL_BATCH];

    prctl(PR_SET_NAME, "<bond>worker", 0, 0, 0);

    while (atomic_load_explicit(&r->running, memory_order_acquire)) {
        int n = core_epoll_wait(r->efd, events, REACTOR_EPOLL_BATCH, 1000);

        if (n < 0) {
            if (EBADF == errno)
                break;
            continue;
        }

        if (0 == n) {
            if (NULL != r->idle_fn)
                r->idle_fn(r->idle_ctx);
            continue;
        }

        for (int i = 0; i < n; i++) {
            uint64_t data = events[i].data.u64;
            reactor_reg_t *reg;
            uint32_t index;
            uint32_t gen;

            /* data 0 表示内部唤醒 fd */
            if (0 == data) {
                if (!atomic_load_explicit(&r->running, memory_order_acquire))
                    continue;

                uint64_t value;
                while (read(r->wake_fd, &value, sizeof(value)) == (ssize_t)sizeof(value))
                    ;
                reactor_run_tasks(r);
                continue;
            }

            index = (uint32_t)(data & 0xffffffffu) - 1;
            gen = (uint32_t)(data >> 32);
            if (index >= r->max_regs)
                continue;

            reg = &r->regs[index];

            if (atomic_load_explicit(&reg->gen, memory_order_acquire) != gen)
                continue;

            reactor_run(reg, events[i].events);
        }
    }

    return NULL;
}

reactor_t *reactor_create(uint32_t workers, uint32_t max_regs)
{
    reactor_t *r;

    if (0 == workers || workers > REACTOR_MAX_WORKERS || 0 == max_regs)
        return NULL;

    r = calloc(1, sizeof(*r));
    if (NULL == r)
        return NULL;

    r->efd = -1;
    r->wake_fd = -1;
    r->efd = core_epoll_create();
    r->wake_fd = eventfd(0, EFD_NONBLOCK | EFD_CLOEXEC);
    r->regs = calloc(max_regs, sizeof(*r->regs));
    if (r->efd < 0 || r->wake_fd < 0 || NULL == r->regs)
        goto fail;

    r->worker_count = workers;
    r->max_regs = max_regs;
    atomic_init(&r->running, false);
    pthread_mutex_init(&r->slot_lock, NULL);
    pthread_mutex_init(&r->post_lock, NULL);

    for (uint32_t i = 0; i < max_regs; i++) {
        pthread_mutex_init(&r->regs[i].lock, NULL);
        pthread_mutex_init(&r->regs[i].arm_lock, NULL);
        pthread_cond_init(&r->regs[i].cond, NULL);
        atomic_init(&r->regs[i].gen, 0);
        atomic_init(&r->regs[i].state, 0);
        r->regs[i].index = i;
        r->regs[i].fd = -1;
    }

    if (0 != core_epoll_add(r->efd, r->wake_fd, EPOLLIN, 0))
        goto fail;

    return r;

fail:
    if (r->regs) {
        for (uint32_t i = 0; i < max_regs; i++) {
            pthread_cond_destroy(&r->regs[i].cond);
            pthread_mutex_destroy(&r->regs[i].arm_lock);
            pthread_mutex_destroy(&r->regs[i].lock);
        }
        pthread_mutex_destroy(&r->post_lock);
        pthread_mutex_destroy(&r->slot_lock);
        free(r->regs);
    }
    if (r->wake_fd >= 0)
        close(r->wake_fd);
    if (r->efd >= 0)
        close(r->efd);
    free(r);
    return NULL;
}

int reactor_start(reactor_t *r)
{
    if (NULL == r)
        return -1;

    atomic_store_explicit(&r->running, true, memory_order_release);

    for (uint32_t i = 0; i < r->worker_count; i++) {
        if (0 != pthread_create(&r->tids[i], NULL, reactor_worker_thread, r)) {
            bt_log_error(LOG_ALL_OUT, "create reactor worker %u failed!\n", i);
            atomic_store_explicit(&r->running, false, memory_order_release);
            for (uint32_t j = 0; j < i; j++) {
                pthread_join(r->tids[j], NULL);
                r->tids[j] = 0;
            }
            r->worker_count = 0;
            return -1;
        }
    }

    return 0;
}

void reactor_stop(reactor_t *r)
{
    uint64_t one = 1;

    if (NULL == r || 0 == r->worker_count)
        return;

    atomic_store_explicit(&r->running, false, memory_order_release);

    for (uint32_t i = 0; i < r->worker_count; i++) {
        ssize_t ignored = write(r->wake_fd, &one, sizeof(one));
        (void)ignored;
    }

    for (uint32_t i = 0; i < r->worker_count; i++) {
        if (0 != r->tids[i]) {
            pthread_join(r->tids[i], NULL);
            r->tids[i] = 0;
        }
    }
    r->worker_count = 0;
}

void reactor_destroy(reactor_t *r)
{
    reactor_task_t *task;

    if (NULL == r)
        return;

    reactor_stop(r);

    close(r->wake_fd);
    close(r->efd);

    pthread_mutex_lock(&r->post_lock);
    task = r->tasks;
    r->tasks = NULL;
    pthread_mutex_unlock(&r->post_lock);
    while (NULL != task) {
        reactor_task_t *next = task->next;
        free(task);
        task = next;
    }

    pthread_mutex_destroy(&r->post_lock);
    pthread_mutex_destroy(&r->slot_lock);

    for (uint32_t i = 0; i < r->max_regs; i++) {
        pthread_cond_destroy(&r->regs[i].cond);
        pthread_mutex_destroy(&r->regs[i].arm_lock);
        pthread_mutex_destroy(&r->regs[i].lock);
    }
    free(r->regs);
    free(r);
}

reactor_reg_t *reactor_add(reactor_t *r, int fd, uint32_t events,
                           reactor_event_fn on_event, void *ctx)
{
    reactor_reg_t *reg = NULL;
    uint64_t data;
    uint32_t i;

    if (NULL == r || fd < 0 || NULL == on_event)
        return NULL;

    pthread_mutex_lock(&r->slot_lock);

    for (i = 0; i < r->max_regs; i++) {
        reactor_reg_t *candidate = &r->regs[i];

        pthread_mutex_lock(&candidate->lock);
        /* 关闭中的槽位要等 close 完成回调后才能复用 */
        if (0 != atomic_load_explicit(&candidate->state, memory_order_acquire)) {
            pthread_mutex_unlock(&candidate->lock);
            continue;
        }
        reg = candidate;
        break;
    }
    if (NULL == reg) {
        pthread_mutex_unlock(&r->slot_lock);
        return NULL;
    }

    uint32_t gen = ++r->gen_seq;

    if (0 == gen)
        gen = ++r->gen_seq;

    data = ((uint64_t)gen << 32) | (uint64_t)(reg->index + 1);

    /* 已持有 reg->lock */
    pthread_mutex_lock(&reg->arm_lock);

    reg->r = r;
    atomic_store_explicit(&reg->gen, gen, memory_order_relaxed);
    reg->data = data;
    reg->fd = fd;
    reg->on_event = on_event;
    reg->ctx = ctx;

    atomic_store_explicit(&reg->state,
                          REG_ACTIVE | REG_WANT_IN |
                              ((events & EPOLLOUT) ? REG_WANT_OUT : 0),
                          memory_order_release);

    if (0 != core_epoll_add(r->efd, fd, EPOLLIN | EPOLLONESHOT | (events & EPOLLOUT), data)) {
        atomic_store_explicit(&reg->state, 0, memory_order_release);
        reg->fd = -1;
        reg->ctx = NULL;
        reg->on_event = NULL;
        pthread_mutex_unlock(&reg->arm_lock);
        pthread_mutex_unlock(&reg->lock);
        pthread_mutex_unlock(&r->slot_lock);
        return NULL;
    }

    pthread_mutex_unlock(&reg->arm_lock);
    pthread_mutex_unlock(&reg->lock);
    pthread_mutex_unlock(&r->slot_lock);
    return reg;
}

void reactor_want(reactor_reg_t *reg, uint32_t events)
{
    reactor_want_ex(reg, (events & EPOLLOUT) != 0, true);
}

void reactor_want_ex(reactor_reg_t *reg, bool want_out, bool want_in)
{
    uint32_t st;

    if (NULL == reg)
        return;

    for (;;) {
        uint32_t new_st;

        st = atomic_load_explicit(&reg->state, memory_order_acquire);
        new_st = st;
        if (want_out)
            new_st |= REG_WANT_OUT;
        else
            new_st &= ~REG_WANT_OUT;
        if (want_in)
            new_st |= REG_WANT_IN;
        else
            new_st &= ~REG_WANT_IN;

        if (atomic_compare_exchange_weak_explicit(&reg->state, &st, new_st,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire))
            break;
    }

    /*
     * handler 正在执行时只改 want 位, 由它在结束时统一重武装;
     * 否则立即 arm(arm_lock 保证与 handler 的重武装串行)。
     */
    if (!(st & REG_ACTIVE) || (st & REG_BUSY))
        return;

    reactor_arm(reg);
}

void reactor_disable(reactor_reg_t *reg)
{
    if (NULL == reg)
        return;

    /* 只阻止后续重武装; 已在进行中的 handler 会正常返回 */
    atomic_fetch_or_explicit(&reg->state, REG_DISABLED, memory_order_acq_rel);
}

void reactor_close(reactor_reg_t *reg, reactor_closed_fn on_closed)
{
    reactor_t *r;
    void *ctx;
    uint32_t st;

    if (NULL == reg)
        return;

    r = reg->r;

    pthread_mutex_lock(&r->slot_lock);
    pthread_mutex_lock(&reg->lock);

    for (;;) {
        st = atomic_load_explicit(&reg->state, memory_order_acquire);
        if (!(st & REG_ACTIVE)) {
            pthread_mutex_unlock(&reg->lock);
            pthread_mutex_unlock(&r->slot_lock);
            return;
        }
        /* 一次性清掉 ACTIVE 并置 CLOSING, 避免与重武装交错 */
        if (atomic_compare_exchange_weak_explicit(&reg->state, &st,
                                                  (st | REG_CLOSING) & ~REG_ACTIVE,
                                                  memory_order_acq_rel,
                                                  memory_order_acquire))
            break;
    }

    /*
     * closing 标记阻止 reactor_add 复用该槽位；
     * 不能持 slot_lock 等待 busy, 否则正在执行的 handler 里
     * 若调用 reactor_add 会与 close 互锁。
     */
    pthread_mutex_lock(&reg->arm_lock);
    if (reg->fd >= 0)
        core_epoll_del(r->efd, reg->fd);
    reg->fd = -1;
    pthread_mutex_unlock(&reg->arm_lock);

    pthread_mutex_unlock(&r->slot_lock);

    while (atomic_load_explicit(&reg->state, memory_order_acquire) & REG_BUSY)
        pthread_cond_wait(&reg->cond, &reg->lock);

    ctx = reg->ctx;
    reg->ctx = NULL;
    reg->on_event = NULL;
    /* 等 busy 清零后再复位状态; worker 在清理 BUSY 时看到 CLOSING 才会唤醒 */
    atomic_store_explicit(&reg->state, 0, memory_order_release);

    pthread_mutex_unlock(&reg->lock);

    if (NULL != on_closed)
        on_closed(ctx);
}

int reactor_post(reactor_t *r, void (*fn)(void *), void *arg)
{
    reactor_task_t *task;
    uint64_t one = 1;

    if (NULL == r)
        return -1;

    task = calloc(1, sizeof(*task));
    if (NULL == task)
        return -1;

    task->fn = fn;
    task->arg = arg;

    pthread_mutex_lock(&r->post_lock);
    task->next = r->tasks;
    r->tasks = task;
    pthread_mutex_unlock(&r->post_lock);

    if (write(r->wake_fd, &one, sizeof(one)) != (ssize_t)sizeof(one))
        return -1;

    return 0;
}

typedef struct reactor_kick_arg {
    reactor_reg_t *reg;
    uint32_t       gen;
} reactor_kick_arg_t;

static void reactor_kick_task(void *arg)
{
    reactor_kick_arg_t *k = arg;
    reactor_reg_t *reg = k->reg;

    if (atomic_load_explicit(&reg->gen, memory_order_acquire) == k->gen)
        reactor_run(reg, REACTOR_EVENT_KICK);

    free(k);
}

int reactor_kick(reactor_reg_t *reg)
{
    reactor_kick_arg_t *k;

    if (NULL == reg)
        return -1;

    /*
     * 先置位再投递: 即使任务被延迟, 正在执行的 handler 结束时
     * 也会看到 KICK 位并再跑一轮。
     */
    atomic_fetch_or_explicit(&reg->state, REG_KICK, memory_order_acq_rel);

    k = calloc(1, sizeof(*k));
    if (NULL == k)
        return -1;

    k->reg = reg;
    k->gen = atomic_load_explicit(&reg->gen, memory_order_acquire);

    if (0 != reactor_post(reg->r, reactor_kick_task, k)) {
        free(k);
        return -1;
    }

    return 0;
}

void reactor_kick_self(reactor_reg_t *reg)
{
    if (NULL == reg)
        return;

    /* 当前 handler 结束时 reactor_run 会看到 KICK 位并再跑一轮 */
    atomic_fetch_or_explicit(&reg->state, REG_KICK, memory_order_acq_rel);
}

void reactor_set_idle(reactor_t *r, reactor_idle_fn fn, void *ctx)
{
    if (NULL == r)
        return;

    r->idle_fn = fn;
    r->idle_ctx = ctx;
}
