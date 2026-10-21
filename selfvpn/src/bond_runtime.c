#include <errno.h>
#include <poll.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/prctl.h>
#include <sys/timerfd.h>

#include "bond_runtime.h"
#include "bond_connection.h"
#include "bond_server.h"
#include "bond_session.h"
#include "bond_trans_tool.h"
#include "bond_tun.h"
#include "bond_util.h"
#include "core.h"
#include "reactor.h"
#include "traffic_statistics.h"

#define BOND_DEFAULT_BUFFER_MB   5
#define BOND_MAX_BUFFER_MB       1024
#define BOND_TUN_READ_BATCH      64

/* socket -> TUN 的待写包；拷贝一份，避免 worker 阻塞在 TUN 写上 */
typedef struct bond_tun_out {
    bond_list_node_t node;
    uint16_t         len;
    uint8_t          data[BOND_TUN_MTU];
} bond_tun_out_t;

static uint32_t bond_session_bucket(const bond_runtime_t *rt, uint32_t tun_peer_ip)
{
    if (rt->sessions.bucket_count <= 1)
        return 0;

    return (tun_peer_ip * 2654435761u) % rt->sessions.bucket_count;
}

/* 调用方需持有对应 bucket 的读锁或写锁 */
static bond_session_t *bond_session_find_in_bucket(bond_session_bucket_t *bk,
                                                   uint32_t tun_peer_ip)
{
    for (bond_session_t *s = bk->head; NULL != s; s = s->hash_next) {
        if (s->cfg.tun_peer_ip == tun_peer_ip)
            return s;
    }

    return NULL;
}

static void bond_frame_ctor(void *elem)
{
    bond_frame_t *frame = elem;

    frame->data = calloc(1, BOND_FRAME_MAX);
    bt_debug_log_assert(NULL != frame->data, "frame data calloc failed!\n");
    frame->capacity = BOND_FRAME_MAX;
    frame->len = 0;
}

static void bond_frame_dtor(void *elem)
{
    bond_frame_t *frame = elem;

    free(frame->data);
    frame->data = NULL;
}

static void bond_tun_out_release(bond_list_node_t *node, void *ctx)
{
    bond_pool_put((bond_pool_t *)ctx, node);
}

/*
 * 已摘除会话的统一销毁入口。
 * 只在 worker 任务/idle 回调/销毁流程中调用，绝不在会话自己的 handler 里执行。
 */
static void bond_runtime_destroy_session(bond_session_t *s)
{
    bond_session_stop(s);
    bond_session_destroy(s);
}

/* 取走整条待销毁链表后逐个销毁，允许多个 worker 并发进入 */
static void bond_runtime_drain_reap(bond_runtime_t *rt)
{
    bond_session_t *list;

    pthread_mutex_lock(&rt->lifecycle_lock);
    list = rt->reap_head;
    rt->reap_head = NULL;
    rt->reap_tail = NULL;
    pthread_mutex_unlock(&rt->lifecycle_lock);

    while (NULL != list) {
        bond_session_t *s = list;

        list = s->reap_next;
        s->reap_next = NULL;
        bond_runtime_destroy_session(s);
    }
}

static void bond_runtime_reap_task(void *arg)
{
    bond_runtime_drain_reap((bond_runtime_t *)arg);
}

static void bond_runtime_kick_task(void *arg);

/* TUN 队列腾空后, 让仍被背压的会话继续摘取 ring 数据 */
static void bond_runtime_kick_sessions(bond_runtime_t *rt)
{
    if (NULL == rt->reactor)
        return;

    if (atomic_exchange_explicit(&rt->kick_pending, true, memory_order_acq_rel))
        return;

    if (0 != reactor_post(rt->reactor, bond_runtime_kick_task, rt))
        atomic_store_explicit(&rt->kick_pending, false, memory_order_release);
}

static void bond_runtime_kick_task(void *arg)
{
    bond_runtime_t *rt = arg;
    uint32_t kicked = 0;

    atomic_store_explicit(&rt->kick_pending, false, memory_order_release);

    for (uint32_t i = 0; i < rt->sessions.bucket_count; i++) {
        bond_session_bucket_t *bk = &rt->sessions.buckets[i];

        pthread_rwlock_rdlock(&bk->lock);
        for (bond_session_t *s = bk->head; NULL != s; s = s->hash_next) {
            if (NULL == s->reg || !bond_channel_tun_blocked(s->ch))
                continue;

            (void)reactor_kick(s->reg);
            kicked++;
        }
        pthread_rwlock_unlock(&bk->lock);
    }

    /* 没有任何积压: 清除标记, 停止后续 kick */
    if (0 == kicked)
        atomic_store_explicit(&rt->tun_bp, 0, memory_order_release);
}

/*
 * TUN 写线程：阻塞/退避写入，不占用 reactor worker。
 * worker 只负责把包拷贝入队，因此 TUN 再慢也不会卡住事件循环。
 */
static void *bond_runtime_tun_writer(void *arg)
{
    bond_runtime_t *rt = arg;

    prctl(PR_SET_NAME, "<bond>tunWrite", 0, 0, 0);

    while (!atomic_load_explicit(&rt->tun_writer_stop, memory_order_acquire)) {
        bond_list_node_t *node = bond_queue_pop(rt->tun_out_q, 100);
        bond_tun_out_t *item;
        size_t written = 0;

        if (NULL == node)
            continue;

        item = (bond_tun_out_t *)node;

        while (written < item->len) {
            ssize_t n = write(rt->tun_fd, item->data + written, item->len - written);

            if (n < 0) {
                if (EINTR == errno)
                    continue;
                if (EAGAIN == errno || EWOULDBLOCK == errno) {
                    struct pollfd pfd = { .fd = rt->tun_fd, .events = POLLOUT };

                    /* 等 TUN 可写, 顺带作为 stop 的检查点 */
                    if (poll(&pfd, 1, 100) < 0 && EINTR != errno)
                        break;
                    if (atomic_load_explicit(&rt->tun_writer_stop, memory_order_acquire))
                        break;
                    continue;
                }
                break;
            }
            if (0 == n)
                break;

            written += (size_t)n;
        }

        bond_pool_put(rt->tun_out_pool, item);

        /* 队列已腾出空间且曾发生背压: 唤醒被暂停读的会话 */
        if (0 != atomic_load_explicit(&rt->tun_bp, memory_order_relaxed) &&
            bond_queue_size(rt->tun_out_q) <= 16)
            bond_runtime_kick_sessions(rt);
    }

    return NULL;
}

int bond_runtime_tun_write(bond_runtime_t *rt, struct iovec *iov, int iovcnt)
{
    bond_tun_out_t *item;
    size_t len = 0;
    size_t off = 0;

    if (NULL == rt || NULL == iov || iovcnt <= 0 || iovcnt > 2)
        return -1;

    for (int i = 0; i < iovcnt; i++)
        len += iov[i].iov_len;

    if (0 == len || len > BOND_TUN_MTU)
        return -1;

    item = bond_pool_get(rt->tun_out_pool, 0);
    if (NULL == item) {
        atomic_fetch_add_explicit(&rt->tun_bp, 1, memory_order_relaxed);
        return -1;
    }

    for (int i = 0; i < iovcnt; i++) {
        memcpy(item->data + off, iov[i].iov_base, iov[i].iov_len);
        off += iov[i].iov_len;
    }
    item->len = (uint16_t)len;

    if (0 != bond_queue_push(rt->tun_out_q, &item->node)) {
        bond_pool_put(rt->tun_out_pool, item);
        atomic_fetch_add_explicit(&rt->tun_bp, 1, memory_order_relaxed);
        return -1;
    }

    return 0;
}

static int runtime_parse_cfg(bond_runtime_t *rt)
{
    if (BOND_MODE_SERVER != rt->cfg.mode)
        return 0;

    if (0 != ip_parse(rt->cfg.tun_local_ip, &rt->tun_local_ip) ||
        0 != ip_parse(rt->cfg.tun_netmask, &rt->tun_netmask) ||
        0 != ip_parse(rt->cfg.tun_pool_start, &rt->pool_start) ||
        0 != ip_parse(rt->cfg.tun_pool_end, &rt->pool_end)) {
        bt_log_error(LOG_ALL_OUT, "invalid tun config! local:%s mask:%s pool:%s-%s\n",
                     rt->cfg.tun_local_ip, rt->cfg.tun_netmask,
                     rt->cfg.tun_pool_start, rt->cfg.tun_pool_end);
        return -1;
    }

    if (rt->pool_start > rt->pool_end) {
        bt_log_error(LOG_ALL_OUT, "invalid tun pool: start > end\n");
        return -1;
    }

    if ((rt->pool_start & rt->tun_netmask) != (rt->tun_local_ip & rt->tun_netmask) ||
        (rt->pool_end & rt->tun_netmask) != (rt->tun_local_ip & rt->tun_netmask)) {
        bt_log_error(LOG_ALL_OUT, "tun pool is not in local subnet!\n");
        return -1;
    }

    rt->pool_count = rt->pool_end - rt->pool_start + 1;
    if (0 == rt->pool_count) {
        bt_log_error(LOG_ALL_OUT, "tun pool is empty!\n");
        return -1;
    }

    if (rt->tun_local_ip >= rt->pool_start && rt->tun_local_ip <= rt->pool_end) {
        bt_log_error(LOG_ALL_OUT, "tun local ip is inside the pool!\n");
        return -1;
    }

    if (0 != bond_tun_set_server_addr(rt->tun, rt->tun_local_ip, rt->tun_netmask))
        return -1;

    return 0;
}

/* TUN 侧收包：非阻塞批量读取 IP 包并按目的地址分发 */
static void bond_runtime_on_tun(void *ctx, uint32_t events)
{
    bond_runtime_t *rt = ctx;
    int tun_fd = rt->tun_fd;

    (void)events;

    for (uint32_t i = 0; i < BOND_TUN_READ_BATCH; i++) {
        bond_frame_t *frame = bond_pool_get(rt->to_socket_pool, 0);
        ssize_t n;

        if (NULL == frame) {
            uint8_t drop[BOND_TUN_MTU];
            ssize_t dropped = read(tun_fd, drop, sizeof(drop));
            (void)dropped;
            break;
        }

        n = read(tun_fd, frame->data + 2, BOND_TUN_MTU);
        if (n < 0) {
            bond_pool_put(rt->to_socket_pool, frame);
            if (EINTR == errno)
                continue;
            break;
        }
        if (0 == n) {
            bond_pool_put(rt->to_socket_pool, frame);
            break;
        }

        /* 只处理 IPv4 */
        if (n < 20 || 4 != ((frame->data[2] >> 4) & 0x0F)) {
            bond_pool_put(rt->to_socket_pool, frame);
            continue;
        }

        uint16_t be_len = htons((uint16_t)n);
        memcpy(frame->data, &be_len, sizeof(be_len));
        frame->len = (uint16_t)(n + 2);

        if (0 != bond_runtime_dispatch_from_tun(rt, frame))
            bond_pool_put(rt->to_socket_pool, frame);
    }
}

static void bond_runtime_on_idle(void *ctx)
{
    bond_runtime_t *rt = ctx;

    /* post 失败或任务未及时执行的兜底 */
    bond_runtime_drain_reap(rt);
    bond_server_reap(rt);
}

/* 按最近的认证 deadline 重新武装一次性定时器; 没有半连接时解除 */
static void bond_runtime_auth_timer_arm(bond_runtime_t *rt)
{
    struct itimerspec its;
    int64_t now;
    int64_t nearest = 0;
    int64_t delay;

    if (NULL == rt || rt->auth_timer_fd < 0)
        return;

    memset(&its, 0, sizeof(its));

    if (0 == atomic_load_explicit(&rt->auth_count, memory_order_acquire) ||
        !bond_server_is_active(rt)) {
        (void)timerfd_settime(rt->auth_timer_fd, 0, &its, NULL);
        return;
    }

    now = bond_now_ms();

    for (uint32_t i = 0; i < rt->sessions.bucket_count; i++) {
        bond_session_bucket_t *bk = &rt->sessions.buckets[i];

        pthread_rwlock_rdlock(&bk->lock);
        for (bond_session_t *s = bk->head; NULL != s; s = s->hash_next) {
            if (BOND_SESSION_AUTHENTICATING !=
                atomic_load_explicit(&s->state, memory_order_acquire))
                continue;
            if (0 == nearest || s->auth.deadline_ms < nearest)
                nearest = s->auth.deadline_ms;
        }
        pthread_rwlock_unlock(&bk->lock);
    }

    if (0 == nearest)
        return;

    delay = nearest - now;
    if (delay < 1)
        delay = 1;

    its.it_value.tv_sec = (time_t)(delay / 1000);
    its.it_value.tv_nsec = (long)(delay % 1000) * 1000000L;
    (void)timerfd_settime(rt->auth_timer_fd, 0, &its, NULL);
}

static void bond_runtime_on_auth_timer(void *ctx, uint32_t events)
{
    bond_runtime_t *rt = ctx;
    uint64_t expirations = 0;
    ssize_t drained;

    (void)events;
    drained = read(rt->auth_timer_fd, &expirations, sizeof(expirations));
    (void)drained;

    bond_server_reap(rt);
    bond_runtime_auth_timer_arm(rt);
}

bond_runtime_t *bond_runtime_create_with_tun(const runtime_cfg_t *cfg, bond_tun_t *tun)
{
    bond_runtime_t *rt;
    uint32_t frame_count;
    uint32_t max_regs;
    bool traffic_ready = false;
    bool locks_ready = false;

    if (NULL == cfg || NULL == tun)
        return NULL;

    if (BOND_MODE_CLIENT != cfg->mode && BOND_MODE_SERVER != cfg->mode)
        return NULL;

    rt = calloc(1, sizeof(*rt));
    if (NULL == rt)
        return NULL;

    rt->auth_timer_fd = -1;
    rt->tun_fd = -1;
    rt->tun = tun;
    rt->cfg = *cfg;
    rt->ring_total_bytes = BOND_DEFAULT_RING_TOTAL;
    if (0 == rt->cfg.buffer_size_mb)
        rt->cfg.buffer_size_mb = BOND_DEFAULT_BUFFER_MB;
    if (rt->cfg.buffer_size_mb > BOND_MAX_BUFFER_MB)
        rt->cfg.buffer_size_mb = BOND_MAX_BUFFER_MB;

    rt->ops = (BOND_MODE_CLIENT == rt->cfg.mode) ? &bond_client_ops : &bond_server_ops;
    atomic_init(&rt->server, NULL);

    pthread_rwlock_init(&rt->sessions.lock, NULL);
    pthread_mutex_init(&rt->lifecycle_lock, NULL);
    atomic_init(&rt->auth_count, 0);
    locks_ready = true;

    if (0 != runtime_parse_cfg(rt))
        goto fail;

    /* 会话表大小由可用地址池决定：server 为地址池 IP 数，client 固定 1 个会话 */
    rt->sessions.bucket_count = (BOND_MODE_SERVER == rt->cfg.mode) ? rt->pool_count : 1;
    rt->sessions.buckets = calloc(rt->sessions.bucket_count, sizeof(*rt->sessions.buckets));
    if (NULL == rt->sessions.buckets) {
        bt_log_error(LOG_ALL_OUT, "session table alloc failed! buckets:%u\n",
                     rt->sessions.bucket_count);
        goto fail;
    }
    for (uint32_t i = 0; i < rt->sessions.bucket_count; i++)
        pthread_rwlock_init(&rt->sessions.buckets[i].lock, NULL);

    frame_count = (uint32_t)(((uint64_t)rt->cfg.buffer_size_mb * 1024ULL * 1024ULL) / BOND_FRAME_MAX);
    if (frame_count < 16)
        frame_count = 16;

    rt->to_socket_pool = bond_pool_create(frame_count, sizeof(bond_frame_t),
                                          bond_frame_ctor, bond_frame_dtor);
    rt->to_tun_pool = bond_pool_create(frame_count, sizeof(bond_frame_ref_t), NULL, NULL);
    if (NULL == rt->to_socket_pool || NULL == rt->to_tun_pool)
        goto fail;

    traffic_init();
    traffic_ready = true;

    rt->tun_fd = bond_tun_fd(rt->tun);
    rt->tun_out_q = bond_queue_create();
    /* 待写队列与缓冲区同量级：突发由队列吸收，真正的背压由写线程的退避保证 */
    rt->tun_out_pool = bond_pool_create(frame_count, sizeof(bond_tun_out_t), NULL, NULL);
    if (NULL == rt->tun_out_q || NULL == rt->tun_out_pool) {
        bt_log_error(LOG_ALL_OUT, "tun output queue init failed!\n");
        goto fail;
    }
    atomic_init(&rt->tun_writer_stop, false);
    atomic_init(&rt->tun_bp, 0);
    atomic_init(&rt->kick_pending, false);

    /* TUN + 监听 + 认证定时器 + 每会话一个注册槽位 */
    max_regs = rt->sessions.bucket_count + 3;
    rt->reactor = reactor_create((BOND_MODE_SERVER == rt->cfg.mode) ? BOND_REACTOR_WORKERS : 1,
                                 max_regs);
    if (NULL == rt->reactor) {
        bt_log_error(LOG_ALL_OUT, "reactor create failed!\n");
        goto fail;
    }

    /* TUN 读写都非阻塞：写由独立线程负责排队与背压 */
    core_socket_nonblock(rt->tun_fd);
    rt->tun_reg = reactor_add(rt->reactor, rt->tun_fd, 0,
                              bond_runtime_on_tun, rt);
    if (NULL == rt->tun_reg) {
        bt_log_error(LOG_ALL_OUT, "register tun fd failed!\n");
        goto fail;
    }

    /* 认证超时用 timerfd 精确定时, 不再依赖 idle 扫描周期 */
    rt->auth_timer_fd = timerfd_create(CLOCK_MONOTONIC, TFD_NONBLOCK | TFD_CLOEXEC);
    if (rt->auth_timer_fd < 0) {
        bt_log_error(LOG_ALL_OUT, "create auth timer failed! errno:%d\n", errno);
        goto fail;
    }
    rt->auth_timer_reg = reactor_add(rt->reactor, rt->auth_timer_fd, 0,
                                     bond_runtime_on_auth_timer, rt);
    if (NULL == rt->auth_timer_reg) {
        bt_log_error(LOG_ALL_OUT, "register auth timer failed!\n");
        goto fail;
    }

    reactor_set_idle(rt->reactor, bond_runtime_on_idle, rt);

    if (0 != reactor_start(rt->reactor)) {
        bt_log_error(LOG_ALL_OUT, "reactor start failed!\n");
        goto fail;
    }

    if (0 != pthread_create(&rt->tun_writer_tid, NULL, bond_runtime_tun_writer, rt)) {
        rt->tun_writer_tid = 0;
        bt_log_error(LOG_ALL_OUT, "create tun writer failed!\n");
        goto fail;
    }

    return rt;

fail:
    bond_runtime_stop(rt);
    if (NULL != rt->reactor)
        reactor_destroy(rt->reactor);
    if (rt->auth_timer_fd >= 0)
        close(rt->auth_timer_fd);
    if (rt->tun_out_q)
        bond_queue_destroy(rt->tun_out_q, bond_tun_out_release, rt->tun_out_pool);
    if (rt->tun_out_pool)
        bond_pool_destroy(rt->tun_out_pool);
    if (rt->to_socket_pool)
        bond_pool_destroy(rt->to_socket_pool);
    if (rt->to_tun_pool)
        bond_pool_destroy(rt->to_tun_pool);
    if (traffic_ready)
        traffic_uninit();
    if (locks_ready) {
        pthread_mutex_destroy(&rt->lifecycle_lock);
        pthread_rwlock_destroy(&rt->sessions.lock);
    }
    if (NULL != rt->sessions.buckets) {
        for (uint32_t i = 0; i < rt->sessions.bucket_count; i++)
            pthread_rwlock_destroy(&rt->sessions.buckets[i].lock);
        free(rt->sessions.buckets);
    }
    bond_tun_destroy(rt->tun);
    free(rt);
    return NULL;
}

bond_runtime_t *bond_runtime_create(const runtime_cfg_t *cfg)
{
    bond_tun_t *tun;

    if (NULL == cfg)
        return NULL;

    tun = bond_tun_create(cfg->tun_name, cfg->tun_mtu);
    if (NULL == tun)
        return NULL;

    return bond_runtime_create_with_tun(cfg, tun);
}

void bond_runtime_stop(bond_runtime_t *rt)
{
    if (NULL == rt)
        return;

    /* 先停 reactor，确保不再有新的 TUN 写请求入队 */
    if (NULL != rt->reactor)
        reactor_stop(rt->reactor);

    if (0 != rt->tun_writer_tid) {
        atomic_store_explicit(&rt->tun_writer_stop, true, memory_order_release);
        pthread_join(rt->tun_writer_tid, NULL);
        rt->tun_writer_tid = 0;
    }
}

void bond_runtime_destroy(bond_runtime_t *rt)
{
    if (NULL == rt)
        return;

    bond_runtime_stop(rt);
    bond_server_stop(rt);

    /* reactor 已停，先清空待销毁队列，再摘除表中剩余会话 */
    bond_runtime_drain_reap(rt);

    /* 逐个从会话表摘除；detach 会等待 handler 退出 */
    pthread_mutex_lock(&rt->lifecycle_lock);
    for (;;) {
        bond_session_t *s = NULL;

        pthread_rwlock_wrlock(&rt->sessions.lock);
        for (uint32_t i = 0; i < rt->sessions.bucket_count && NULL == s; i++) {
            bond_session_bucket_t *bk = &rt->sessions.buckets[i];

            pthread_rwlock_wrlock(&bk->lock);
            if (NULL != bk->head) {
                s = bk->head;
                bk->head = s->hash_next;
                s->hash_next = NULL;
                rt->sessions.count--;
            }
            pthread_rwlock_unlock(&bk->lock);
        }
        pthread_rwlock_unlock(&rt->sessions.lock);

        if (NULL == s)
            break;

        bond_runtime_destroy_session(s);
    }
    pthread_mutex_unlock(&rt->lifecycle_lock);

    reactor_destroy(rt->reactor);
    rt->reactor = NULL;

    if (rt->auth_timer_fd >= 0) {
        close(rt->auth_timer_fd);
        rt->auth_timer_fd = -1;
    }

    if (rt->tun_out_q)
        bond_queue_destroy(rt->tun_out_q, bond_tun_out_release, rt->tun_out_pool);
    if (rt->tun_out_pool)
        bond_pool_destroy(rt->tun_out_pool);

    bond_pool_destroy(rt->to_socket_pool);
    bond_pool_destroy(rt->to_tun_pool);
    traffic_uninit();

    pthread_mutex_destroy(&rt->lifecycle_lock);
    pthread_rwlock_destroy(&rt->sessions.lock);

    for (uint32_t i = 0; i < rt->sessions.bucket_count; i++)
        pthread_rwlock_destroy(&rt->sessions.buckets[i].lock);
    free(rt->sessions.buckets);
    bond_tun_destroy(rt->tun);
    free(rt);
}

void bond_runtime_set_ring_limit(bond_runtime_t *rt, uint32_t bytes)
{
    if (NULL == rt)
        return;

    if (0 == bytes)
        bytes = BOND_DEFAULT_RING_TOTAL;
    if (bytes < BOND_MIN_RING_BYTES)
        bytes = BOND_MIN_RING_BYTES;

    rt->ring_total_bytes = bytes;
}

void bond_runtime_set_socket_buffer(bond_runtime_t *rt, int send_bytes, int recv_bytes)
{
    if (NULL == rt)
        return;

    rt->sock_send_buf = (send_bytes > 0) ? send_bytes : 0;
    rt->sock_recv_buf = (recv_bytes > 0) ? recv_bytes : 0;
}

/* ring 实际按 2 的幂分配, 预算折算必须使用取整后的容量 */
static uint32_t bond_ring_pow2_floor(uint32_t v)
{
    uint32_t p = 4096;

    if (v < p)
        return p;

    while (p <= (v >> 1))
        p <<= 1;

    return p;
}

static uint32_t bond_ring_pow2_ceil(uint32_t v)
{
    uint32_t p = 4096;

    if (v <= p)
        return p;

    while (p < v)
        p <<= 1;

    return p;
}

uint32_t bond_runtime_ring_capacity(const bond_runtime_t *rt, uint32_t requested)
{
    uint32_t sessions;
    uint32_t limit;

    if (NULL == rt)
        return BOND_MIN_RING_BYTES;

    /* server 的会话数上限就是地址池大小, client 只有 1 条 */
    sessions = (BOND_MODE_SERVER == rt->cfg.mode && rt->pool_count > 0)
                   ? rt->pool_count : 1;

    limit = bond_ring_pow2_floor(rt->ring_total_bytes / sessions);
    if (limit < BOND_MIN_RING_BYTES)
        limit = BOND_MIN_RING_BYTES;

    if (0 == requested)
        requested = BOND_DEFAULT_RING_BYTES;
    requested = bond_ring_pow2_ceil(requested);

    if (requested > limit)
        requested = limit;
    if (requested < BOND_MIN_RING_BYTES)
        requested = BOND_MIN_RING_BYTES;

    return requested;
}

int bond_runtime_add_session(bond_runtime_t *rt, const bond_session_cfg_t *cfg)
{
    bond_session_t *s = NULL;
    bond_session_cfg_t local_cfg;
    uint32_t bucket;

    if (NULL == rt || NULL == cfg)
        return -1;

    if (BOND_MODE_SERVER == rt->cfg.mode)
        return -1;

    bucket = bond_session_bucket(rt, cfg->tun_peer_ip);
    local_cfg = *cfg;
    local_cfg.ring_capacity = bond_runtime_ring_capacity(rt, cfg->ring_capacity);

    pthread_mutex_lock(&rt->lifecycle_lock);
    pthread_rwlock_wrlock(&rt->sessions.lock);

    if (BOND_MODE_CLIENT == rt->cfg.mode && 0 != rt->sessions.count) {
        pthread_rwlock_unlock(&rt->sessions.lock);
        pthread_mutex_unlock(&rt->lifecycle_lock);
        bt_log_error(LOG_ALL_OUT, "client mode only supports one session!\n");
        return -1;
    }

    bond_session_bucket_t *bk = &rt->sessions.buckets[bucket];

    pthread_rwlock_wrlock(&bk->lock);
    if (NULL != bond_session_find_in_bucket(bk, cfg->tun_peer_ip)) {
        pthread_rwlock_unlock(&bk->lock);
        pthread_rwlock_unlock(&rt->sessions.lock);
        pthread_mutex_unlock(&rt->lifecycle_lock);
        bt_log_error(LOG_ALL_OUT, "session %s already exists!\n", cfg->sn);
        return -1;
    }
    pthread_rwlock_unlock(&bk->lock);

    /* 先确定 id, 再创建 session; id 单调递增, 避免统计槽位索引复用 */
    local_cfg.id = ++rt->next_session_id;
    s = bond_session_create(rt, &local_cfg);
    if (NULL == s) {
        pthread_rwlock_unlock(&rt->sessions.lock);
        pthread_mutex_unlock(&rt->lifecycle_lock);
        return -1;
    }

    pthread_rwlock_wrlock(&bk->lock);
    s->hash_next = bk->head;
    bk->head = s;
    rt->sessions.count++;
    pthread_rwlock_unlock(&bk->lock);

    pthread_rwlock_unlock(&rt->sessions.lock);
    pthread_mutex_unlock(&rt->lifecycle_lock);

    if (0 != bond_session_start(s)) {
        (void)bond_runtime_remove_session(rt, cfg->tun_peer_ip);
        return -1;
    }

    return 0;
}

int bond_runtime_remove_session(bond_runtime_t *rt, uint32_t tun_peer_ip)
{
    bond_session_t *s = NULL;
    uint32_t bucket;

    if (NULL == rt)
        return -1;

    bucket = bond_session_bucket(rt, tun_peer_ip);

    pthread_mutex_lock(&rt->lifecycle_lock);
    pthread_rwlock_wrlock(&rt->sessions.lock);

    bond_session_bucket_t *bk = &rt->sessions.buckets[bucket];

    pthread_rwlock_wrlock(&bk->lock);
    bond_session_t **pp = &bk->head;
    while (NULL != *pp) {
        if ((*pp)->cfg.tun_peer_ip == tun_peer_ip) {
            s = *pp;
            *pp = s->hash_next;
            s->hash_next = NULL;
            if (rt->sessions.count > 0)
                rt->sessions.count--;
            break;
        }
        pp = &(*pp)->hash_next;
    }
    pthread_rwlock_unlock(&bk->lock);

    pthread_rwlock_unlock(&rt->sessions.lock);

    if (NULL == s) {
        pthread_mutex_unlock(&rt->lifecycle_lock);
        return -1;
    }

    /* 地址池在控制面同步归还，保证新连接立刻可用 */
    if (s->from_pool) {
        bond_server_t *srv = atomic_load_explicit(&rt->server, memory_order_acquire);

        if (NULL != srv)
            bond_server_pool_release(srv, tun_peer_ip);
    }

    bond_session_auth_done(s);

    /* 挂入待销毁队列，由 worker 上下文完成 stop/destroy */
    s->reap_next = NULL;
    if (NULL != rt->reap_tail)
        rt->reap_tail->reap_next = s;
    else
        rt->reap_head = s;
    rt->reap_tail = s;

    pthread_mutex_unlock(&rt->lifecycle_lock);

    /* 投递失败时由 idle 回调兜底 */
    if (NULL != rt->reactor)
        (void)reactor_post(rt->reactor, bond_runtime_reap_task, rt);

    return 0;
}

int bond_runtime_add_accepted_session(bond_runtime_t *rt, const bond_session_cfg_t *cfg, int fd)
{
    bond_session_t *s = NULL;
    bond_session_cfg_t local_cfg;
    uint32_t bucket;

    if (NULL == rt || NULL == cfg || fd < 0)
        return -1;

    if (BOND_MODE_SERVER != rt->cfg.mode)
        return -1;

    bucket = bond_session_bucket(rt, cfg->tun_peer_ip);
    local_cfg = *cfg;
    local_cfg.ring_capacity = bond_runtime_ring_capacity(rt, cfg->ring_capacity);

    pthread_mutex_lock(&rt->lifecycle_lock);
    pthread_rwlock_wrlock(&rt->sessions.lock);

    bond_session_bucket_t *bk = &rt->sessions.buckets[bucket];

    pthread_rwlock_wrlock(&bk->lock);
    if (NULL != bond_session_find_in_bucket(bk, cfg->tun_peer_ip)) {
        pthread_rwlock_unlock(&bk->lock);
        pthread_rwlock_unlock(&rt->sessions.lock);
        pthread_mutex_unlock(&rt->lifecycle_lock);
        close(fd);
        return -1;
    }
    pthread_rwlock_unlock(&bk->lock);

    local_cfg.id = ++rt->next_session_id;
    s = bond_session_create(rt, &local_cfg);
    if (NULL == s) {
        pthread_rwlock_unlock(&rt->sessions.lock);
        pthread_mutex_unlock(&rt->lifecycle_lock);
        close(fd);
        return -1;
    }

    s->from_pool = true;
    s->conn.fd = fd;
    s->auth.deadline_ms = bond_now_ms() + BOND_AUTH_TIMEOUT_MS;
    atomic_store_explicit(&s->conn.stop, false, memory_order_release);

    pthread_rwlock_wrlock(&bk->lock);
    s->hash_next = bk->head;
    bk->head = s;
    rt->sessions.count++;
    pthread_rwlock_unlock(&bk->lock);

    pthread_rwlock_unlock(&rt->sessions.lock);
    pthread_mutex_unlock(&rt->lifecycle_lock);

    /* 先注册 reactor, 再进入认证态; 认证完成由 handler 置为 ONLINE */
    if (0 != bond_session_attach(s)) {
        (void)bond_runtime_remove_session(rt, cfg->tun_peer_ip);
        return -1;
    }

    atomic_store_explicit(&s->state, BOND_SESSION_AUTHENTICATING, memory_order_release);
    atomic_store_explicit(&s->auth_counted, true, memory_order_release);
    atomic_fetch_add_explicit(&rt->auth_count, 1, memory_order_relaxed);
    traffic_set_online(s->stat, false);

    bond_runtime_auth_timer_arm(rt);

    return 0;
}

int bond_runtime_remove_client_session(bond_runtime_t *rt)
{
    uint32_t ip = 0;
    bool found = false;

    if (NULL == rt)
        return -1;

    pthread_rwlock_rdlock(&rt->sessions.lock);
    for (uint32_t i = 0; i < rt->sessions.bucket_count && !found; i++) {
        bond_session_bucket_t *bk = &rt->sessions.buckets[i];

        pthread_rwlock_rdlock(&bk->lock);
        if (NULL != bk->head) {
            ip = bk->head->cfg.tun_peer_ip;
            found = true;
        }
        pthread_rwlock_unlock(&bk->lock);
    }
    pthread_rwlock_unlock(&rt->sessions.lock);

    if (!found)
        return -1;

    return bond_runtime_remove_session(rt, ip);
}

int bond_runtime_dispatch_from_tun(bond_runtime_t *rt, bond_frame_t *frame)
{
    bond_session_t *s = NULL;
    uint32_t key;
    uint32_t bucket;
    int ret = -1;

    if (NULL == rt || NULL == frame || frame->len < 22)
        return -1;

    if (0 != rt->ops->route_key(rt, frame->data + 2, frame->len - 2, &key))
        return -1;

    bucket = bond_session_bucket(rt, key);

    /* 只锁目标桶: 分发路径不再触碰全局会话表锁 */
    bond_session_bucket_t *bk = &rt->sessions.buckets[bucket];

    pthread_rwlock_rdlock(&bk->lock);
    s = bond_session_find_in_bucket(bk, key);
    if (NULL != s &&
        bond_session_is_online(s) &&
        !atomic_load_explicit(&s->conn.stop, memory_order_acquire)) {

        if (0 == bond_session_enqueue_from_tun(s, frame)) {
            ret = 0;
        }
    }

    pthread_rwlock_unlock(&bk->lock);

    return ret;
}
