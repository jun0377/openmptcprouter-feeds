#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "bond_session.h"
#include "bond_trans_tool.h"
#include "bond_tun.h"
#include "bond_util.h"
#include "core.h"

static int bond_session_tun_write(void *ctx, struct iovec *iov, int iovcnt)
{
    return bond_runtime_tun_write((bond_runtime_t *)ctx, iov, iovcnt);
}

bond_session_t *bond_session_create(bond_runtime_t *rt, const bond_session_cfg_t *cfg)
{
    bond_session_t *s;

    if (NULL == rt || NULL == cfg)
        return NULL;

    s = calloc(1, sizeof(*s));
    if (NULL == s)
        return NULL;

    s->runtime = rt;
    s->cfg = *cfg;
    atomic_init(&s->stop, false);
    atomic_init(&s->state, BOND_SESSION_INIT);
    atomic_init(&s->auth_counted, false);
    pthread_mutex_init(&s->tx_lock, NULL);
    pthread_mutex_init(&s->wait_lock, NULL);
    pthread_cond_init(&s->wait_cond, NULL);

    s->conn.fd = BOND_INVALID_FD;
    s->conn.listen_fd = BOND_INVALID_FD;
    atomic_init(&s->conn.stop, false);

    s->ch = bond_channel_create(cfg->ring_capacity, rt->to_socket_pool, rt->to_tun_pool,
                                bond_session_tun_write, rt);
    if (NULL == s->ch) {
        free(s);
        return NULL;
    }

    /* 统计槽位在认证完成后按 (sn, tun ip) 注册, 此时还没有真实的 sn/ip */
    s->stat = NULL;

    return s;
}

void bond_session_destroy(bond_session_t *s)
{
    if (NULL == s)
        return;

    if (BOND_SESSION_INIT != atomic_load_explicit(&s->state, memory_order_acquire) &&
        BOND_SESSION_STOPPED != atomic_load_explicit(&s->state, memory_order_acquire))
        bond_session_stop(s);

    if (NULL != s->ch)
        bond_channel_destroy(s->ch);

    pthread_mutex_destroy(&s->tx_lock);
    pthread_cond_destroy(&s->wait_cond);
    pthread_mutex_destroy(&s->wait_lock);
    free(s);
}

int bond_session_start(bond_session_t *s)
{
    int ret;

    if (NULL == s || NULL == s->runtime || NULL == s->runtime->ops)
        return -1;

    atomic_store_explicit(&s->stop, false, memory_order_release);
    atomic_store_explicit(&s->state, BOND_SESSION_CONNECTING, memory_order_release);

    ret = s->runtime->ops->session_start(s);
    if (0 != ret)
        atomic_store_explicit(&s->state, BOND_SESSION_INIT, memory_order_release);

    return ret;
}

void bond_session_stop(bond_session_t *s)
{
    int state;

    if (NULL == s)
        return;

    state = atomic_load_explicit(&s->state, memory_order_acquire);
    if (BOND_SESSION_STOPPED == state)
        return;

    atomic_store_explicit(&s->state, BOND_SESSION_STOPPING, memory_order_release);
    atomic_store_explicit(&s->stop, true, memory_order_release);
    atomic_store_explicit(&s->conn.stop, true, memory_order_release);

    /* 唤醒可能正在重连等待的连接线程 */
    pthread_mutex_lock(&s->wait_lock);
    pthread_cond_broadcast(&s->wait_cond);
    pthread_mutex_unlock(&s->wait_lock);

    core_socket_shutdown(s->conn.fd);

    if (s->runtime && s->runtime->ops && s->runtime->ops->session_stop)
        s->runtime->ops->session_stop(s);

    bond_session_detach_conn(s);

    atomic_store_explicit(&s->state, BOND_SESSION_STOPPED, memory_order_release);
}

bool bond_session_is_online(bond_session_t *s)
{
    if (NULL == s)
        return false;

    return BOND_SESSION_ONLINE == atomic_load_explicit(&s->state, memory_order_acquire);
}

uint32_t bond_session_peer_ip(const bond_session_t *s)
{
    return (NULL == s) ? 0 : s->cfg.tun_peer_ip;
}

int bond_session_attach(bond_session_t *s)
{
    if (NULL == s || NULL == s->runtime || s->conn.fd < 0)
        return -1;

    core_socket_nonblock(s->conn.fd);

    s->reg = reactor_add(s->runtime->reactor, s->conn.fd, 0,
                         bond_session_on_event, s);
    if (NULL == s->reg)
        return -1;

    return 0;
}

void bond_session_detach_conn(bond_session_t *s)
{
    if (NULL == s)
        return;

    if (NULL != s->reg) {
        reactor_close(s->reg, NULL);
        s->reg = NULL;
    }

    if (NULL != s->ch)
        bond_channel_reset(s->ch);

    if (s->conn.fd >= 0) {
        close(s->conn.fd);
        s->conn.fd = BOND_INVALID_FD;
    }

    traffic_set_online(s->stat, false);
}

void bond_session_auth_done(bond_session_t *s)
{
    if (NULL == s)
        return;

    if (atomic_exchange_explicit(&s->auth_counted, false, memory_order_acq_rel))
        atomic_fetch_sub_explicit(&s->runtime->auth_count, 1, memory_order_relaxed);
}

void bond_session_connection_lost(bond_session_t *s)
{
    if (NULL == s)
        return;

    if (atomic_load_explicit(&s->stop, memory_order_acquire))
        return;

    if (atomic_exchange_explicit(&s->conn.stop, true, memory_order_acq_rel))
        return;

    bt_log_info(LOG_ALL_OUT, "sn:%s connection lost, state:%d\n", s->cfg.sn,
                atomic_load_explicit(&s->state, memory_order_acquire));

    core_socket_shutdown(s->conn.fd);
    reactor_disable(s->reg);
    traffic_set_online(s->stat, false);
    atomic_store_explicit(&s->state, BOND_SESSION_CONNECTING, memory_order_release);
    bond_session_auth_done(s);

    /*
     * server 会话断链即主动摘除，地址池立刻归还；
     * 真正的 stop/destroy 由 reactor_post 投递到 worker 执行，避免在 handler 内同步 close。
     */
    if (s->from_pool)
        (void)bond_runtime_remove_session(s->runtime, s->cfg.tun_peer_ip);
}

int bond_session_enqueue_from_tun(bond_session_t *s, bond_frame_t *frame)
{
    int ret;

    if (NULL == s || NULL == s->ch || NULL == s->reg)
        return -1;

    pthread_mutex_lock(&s->tx_lock);

    ret = bond_channel_enqueue(s->ch, frame);
    if (0 == ret)
        reactor_want(s->reg, EPOLLOUT);

    pthread_mutex_unlock(&s->tx_lock);

    return ret;
}

static void bond_session_on_auth_event(bond_session_t *s, uint32_t events)
{
    int ret;

    /* 认证阶段不响应 kick 等伪事件 */
    if (0 == (events & (EPOLLIN | EPOLLOUT | EPOLLERR | EPOLLHUP)))
        return;

    if (events & (EPOLLERR | EPOLLHUP)) {
        bond_session_connection_lost(s);
        return;
    }

    ret = (NULL != s->runtime->ops->authenticate)
              ? s->runtime->ops->authenticate(s, events)
              : -1;

    if (ret < 0) {
        bond_session_connection_lost(s);
        return;
    }
    if (ret > 0)
        return;

    /* 认证完成：转为 ONLINE，后续事件走数据通道 */
    bt_log_info(LOG_ALL_OUT, "sn:%s auth done, peer %u.%u.%u.%u\n", s->cfg.sn,
                (s->cfg.tun_peer_ip >> 24) & 0xFF, (s->cfg.tun_peer_ip >> 16) & 0xFF,
                (s->cfg.tun_peer_ip >> 8) & 0xFF, s->cfg.tun_peer_ip & 0xFF);

    bond_session_auth_done(s);
    atomic_store_explicit(&s->state, BOND_SESSION_ONLINE, memory_order_release);
    traffic_set_online(s->stat, true);
    reactor_want(s->reg, 0);
}

void bond_session_on_event(void *ctx, uint32_t events)
{
    bond_session_t *s = ctx;
    uint64_t rx = 0;
    uint64_t tx = 0;
    bool fatal = false;
    bool pending;
    bool blocked;

    if (NULL == s)
        return;

    if (BOND_SESSION_ONLINE != atomic_load_explicit(&s->state, memory_order_acquire)) {
        bond_session_on_auth_event(s, events);
        return;
    }

    if (events & (EPOLLERR | EPOLLHUP))
        fatal = true;

    if (((events & EPOLLIN) || (events & REACTOR_EVENT_KICK)) && !fatal) {
        if (0 != bond_channel_recv(s->ch, s->conn.fd, &rx))
            fatal = true;
        if (rx > 0)
            traffic_add_rx(s->stat, rx);
    }

    if ((events & EPOLLOUT) && !fatal) {
        if (0 != bond_channel_send(s->ch, s->conn.fd, &tx))
            fatal = true;
        if (tx > 0)
            traffic_add_tx(s->stat, tx);
    }

    if (fatal) {
        bond_session_connection_lost(s);
        return;
    }

    pthread_mutex_lock(&s->tx_lock);
    pending = bond_channel_tx_pending(s->ch) || bond_channel_has_queued(s->ch);
    blocked = bond_channel_tun_blocked(s->ch);
    /* 只有 TUN 队列真的满时才暂停 EPOLLIN */
    reactor_want_ex(s->reg, pending, !blocked);
    pthread_mutex_unlock(&s->tx_lock);

    /*
     * 预算用尽但未被背压: 通道里还有待写帧, 立刻续跑一轮,
     * 不能等 socket 新事件(否则连接会静默停住)。
     */
    if (!blocked && bond_channel_tun_pending(s->ch))
        reactor_kick_self(s->reg);
}
