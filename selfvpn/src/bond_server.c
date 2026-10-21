#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <netinet/in.h>
#include <sys/socket.h>

#include "bond_server.h"
#include "bond_connection.h"
#include "bond_runtime.h"
#include "bond_session.h"
#include "bond_trans_tool.h"
#include "bond_util.h"
#include "core.h"
#include "reactor.h"

#define BOND_ACCEPT_BATCH 32

struct bond_server {
    bond_runtime_t  *rt;

    int              listen_fd;
    uint16_t         listen_port;
    char             bind_ip[BOND_IP_STR_LEN];
    reactor_reg_t   *reg;
    atomic_bool      stop;

    char             secret[BOND_AUTH_LEN];

    uint32_t         pool_start;
    uint32_t         pool_end;
    uint32_t         pool_count;
    uint8_t         *pool_used;
    uint32_t         pool_in_use;
    pthread_mutex_t  pool_lock;

    uint32_t         ring_capacity;
    uint32_t         queue_capacity;
};

static int bond_server_pool_alloc(bond_server_t *srv, uint32_t *ip)
{
    int ret = -1;

    pthread_mutex_lock(&srv->pool_lock);

    for (uint32_t i = 0; i < srv->pool_count; i++) {
        if (0 == srv->pool_used[i]) {
            srv->pool_used[i] = 1;
            srv->pool_in_use++;
            *ip = srv->pool_start + i;
            ret = 0;
            break;
        }
    }

    pthread_mutex_unlock(&srv->pool_lock);

    return ret;
}

void bond_server_pool_release(bond_server_t *srv, uint32_t ip)
{
    uint32_t index;

    if (NULL == srv || ip < srv->pool_start || ip > srv->pool_end)
        return;

    index = ip - srv->pool_start;

    pthread_mutex_lock(&srv->pool_lock);
    if (index < srv->pool_count && 0 != srv->pool_used[index]) {
        srv->pool_used[index] = 0;
        if (srv->pool_in_use > 0)
            srv->pool_in_use--;
    }
    pthread_mutex_unlock(&srv->pool_lock);
}

void bond_server_reap(bond_runtime_t *rt)
{
    uint32_t *ips;
    uint32_t capacity;
    uint32_t count = 0;

    if (NULL == rt || NULL == atomic_load_explicit(&rt->server, memory_order_acquire))
        return;

    /* 没有认证中的会话时不扫描：断链已由 handler 主动摘除 */
    if (0 == atomic_load_explicit(&rt->auth_count, memory_order_acquire))
        return;

    pthread_rwlock_rdlock(&rt->sessions.lock);

    capacity = rt->sessions.count;
    if (0 == capacity) {
        pthread_rwlock_unlock(&rt->sessions.lock);
        return;
    }

    ips = calloc(capacity, sizeof(*ips));
    if (NULL == ips) {
        pthread_rwlock_unlock(&rt->sessions.lock);
        return;
    }

    for (uint32_t i = 0; i < rt->sessions.bucket_count; i++) {
        bond_session_bucket_t *bk = &rt->sessions.buckets[i];

        pthread_rwlock_rdlock(&bk->lock);
        for (bond_session_t *s = bk->head; NULL != s; s = s->hash_next) {
            int state = atomic_load_explicit(&s->state, memory_order_acquire);

            if (!s->from_pool)
                continue;

            /* 半连接认证超时: 交给下面的统一摘除路径回收地址 */
            if (BOND_SESSION_AUTHENTICATING == state &&
                bond_now_ms() >= s->auth.deadline_ms) {
                bt_log_info(LOG_ALL_OUT, "auth timeout, tun ip %u.%u.%u.%u\n",
                            (s->cfg.tun_peer_ip >> 24) & 0xFF,
                            (s->cfg.tun_peer_ip >> 16) & 0xFF,
                            (s->cfg.tun_peer_ip >> 8) & 0xFF,
                            s->cfg.tun_peer_ip & 0xFF);
                atomic_store_explicit(&s->conn.stop, true, memory_order_release);
            }

            if (BOND_SESSION_ONLINE == state || BOND_SESSION_STOPPING == state)
                continue;
            if (!atomic_load_explicit(&s->conn.stop, memory_order_acquire) &&
                BOND_SESSION_STOPPED != state)
                continue;

            if (count < capacity)
                ips[count++] = s->cfg.tun_peer_ip;
        }
        pthread_rwlock_unlock(&bk->lock);
    }

    pthread_rwlock_unlock(&rt->sessions.lock);

    for (uint32_t i = 0; i < count; i++) {
        bt_log_info(LOG_ALL_OUT, "reap server session ip %u.%u.%u.%u\n",
                    (ips[i] >> 24) & 0xFF, (ips[i] >> 16) & 0xFF,
                    (ips[i] >> 8) & 0xFF, ips[i] & 0xFF);
        (void)bond_runtime_remove_session(rt, ips[i]);
    }

    free(ips);
}

/*
 * 分配地址并创建会话；认证由会话的 reactor handler 以非阻塞状态机完成，
 * 这里不再等待客户端发数据。
 */
static void bond_server_handle_connection(bond_server_t *srv, int newfd)
{
    bond_runtime_t *rt = srv->rt;
    bond_session_cfg_t cfg;
    uint32_t assigned_ip = 0;

    if (0 != bond_server_pool_alloc(srv, &assigned_ip)) {
        uint8_t resp[2 + BOND_AUTH_RESPONSE_LEN];

        bt_log_error(LOG_ALL_OUT, "tun ip pool exhausted! in_use:%u/%u\n",
                     srv->pool_in_use, srv->pool_count);
        /* 尽力告知客户端；失败就直接关闭 */
        bond_auth_response_build(resp, BOND_AUTH_STATUS_POOL_EMPTY, 0, 0);
        (void)send(newfd, resp, sizeof(resp), MSG_DONTWAIT | MSG_NOSIGNAL);
        close(newfd);
        return;
    }

    memset(&cfg, 0, sizeof(cfg));
    snprintf(cfg.secret, sizeof(cfg.secret), "%s", srv->secret);
    cfg.tun_local_ip = rt->tun_local_ip;
    cfg.tun_peer_ip = assigned_ip;
    cfg.ring_capacity = srv->ring_capacity;
    cfg.queue_capacity = srv->queue_capacity;

    core_socket_tune(newfd, rt->sock_send_buf, rt->sock_recv_buf);

    if (0 != bond_runtime_add_accepted_session(rt, &cfg, newfd)) {
        bt_log_error(LOG_ALL_OUT, "add accepted session failed! ip:%u\n", assigned_ip);
        bond_server_pool_release(srv, assigned_ip);
    }
}

/* reactor handler: 监听 fd 可读, 批量 accept, 每个连接交给非阻塞认证 */
static void bond_server_on_accept(void *ctx, uint32_t events)
{
    bond_server_t *srv = ctx;

    (void)events;

    if (atomic_load_explicit(&srv->stop, memory_order_acquire))
        return;

    bond_server_reap(srv->rt);

    for (uint32_t i = 0; i < BOND_ACCEPT_BATCH; i++) {
        struct sockaddr_in peeraddr;
        int newfd;

        memset(&peeraddr, 0, sizeof(peeraddr));
        newfd = core_socket_accept(srv->listen_fd, &peeraddr);
        if (newfd < 0) {
            if (!(EAGAIN == errno || EWOULDBLOCK == errno || EINTR == errno ||
                  ECONNABORTED == errno)) {
                bt_log_error(LOG_ALL_OUT, "accept failed! errno:%d errMsg:%s\n",
                             errno, strerror(errno));
            }
            break;
        }

        if (atomic_load_explicit(&srv->stop, memory_order_acquire)) {
            close(newfd);
            break;
        }

        bond_server_handle_connection(srv, newfd);
    }
    /* reactor 在 handler 返回后自动重武装 EPOLLIN */
}

int bond_server_start(bond_runtime_t *rt, const char *bind_ip, uint16_t listen_port, const char *secret,
                      uint32_t ring_capacity, uint32_t queue_capacity)
{
    bond_server_t *srv;
    int listen_fd;

    if (NULL == rt || BOND_MODE_SERVER != rt->cfg.mode ||
        NULL != atomic_load_explicit(&rt->server, memory_order_acquire))
        return -1;
    if (0 == rt->pool_count || NULL == secret)
        return -1;

    srv = calloc(1, sizeof(*srv));
    if (NULL == srv)
        return -1;

    srv->rt = rt;
    srv->listen_fd = BOND_INVALID_FD;
    srv->listen_port = listen_port;
    snprintf(srv->bind_ip, sizeof(srv->bind_ip), "%s",
             (NULL == bind_ip || '\0' == bind_ip[0]) ? "0.0.0.0" : bind_ip);
    snprintf(srv->secret, sizeof(srv->secret), "%s", secret);
    srv->pool_start = rt->pool_start;
    srv->pool_end = rt->pool_end;
    srv->pool_count = rt->pool_count;
    srv->ring_capacity = bond_runtime_ring_capacity(rt, ring_capacity);
    srv->queue_capacity = queue_capacity;

    bt_log_info(LOG_ALL_OUT, "server ring per session:%u KB, total budget:%u MB\n",
                srv->ring_capacity / 1024, rt->ring_total_bytes / 1024 / 1024);

    srv->pool_used = calloc(srv->pool_count, sizeof(uint8_t));
    if (NULL == srv->pool_used) {
        free(srv);
        return -1;
    }

    pthread_mutex_init(&srv->pool_lock, NULL);
    atomic_init(&srv->stop, false);

    listen_fd = core_socket_listen(srv->bind_ip, srv->listen_port);
    if (listen_fd < 0) {
        pthread_mutex_destroy(&srv->pool_lock);
        free(srv->pool_used);
        free(srv);
        return -1;
    }
    core_socket_nonblock(listen_fd);
    srv->listen_fd = listen_fd;

    atomic_store_explicit(&rt->server, srv, memory_order_release);

    srv->reg = reactor_add(rt->reactor, listen_fd, 0, bond_server_on_accept, srv);
    if (NULL == srv->reg) {
        atomic_store_explicit(&rt->server, NULL, memory_order_release);
        close(listen_fd);
        pthread_mutex_destroy(&srv->pool_lock);
        free(srv->pool_used);
        free(srv);
        return -1;
    }

    return 0;
}

void bond_server_stop(bond_runtime_t *rt)
{
    bond_server_t *srv;
    uint32_t *ips = NULL;
    uint32_t capacity = 0;
    uint32_t count = 0;

    if (NULL == rt || NULL == (srv = atomic_load_explicit(&rt->server, memory_order_acquire)))
        return;

    atomic_store_explicit(&srv->stop, true, memory_order_release);

    /* 关闭监听注册; 会话认证由各自的 handler 完成，这里等待 accept handler 退出 */
    if (NULL != srv->reg) {
        reactor_close(srv->reg, NULL);
        srv->reg = NULL;
    }
    if (srv->listen_fd >= 0) {
        close(srv->listen_fd);
        srv->listen_fd = BOND_INVALID_FD;
    }

    /*
     * 先摘掉全局指针，阻止 idle 回调里的并发 reap 再访问 srv；
     * 地址池即将随 srv 一起释放，下面的移除不再需要归还。
     */
    atomic_store_explicit(&rt->server, NULL, memory_order_release);

    pthread_rwlock_rdlock(&rt->sessions.lock);
    capacity = rt->sessions.count;
    if (capacity > 0)
        ips = calloc(capacity, sizeof(*ips));
    if (NULL != ips) {
        for (uint32_t i = 0; i < rt->sessions.bucket_count; i++) {
            bond_session_bucket_t *bk = &rt->sessions.buckets[i];

            pthread_rwlock_rdlock(&bk->lock);
            for (bond_session_t *s = bk->head; NULL != s; s = s->hash_next) {
                if (s->from_pool && count < capacity)
                    ips[count++] = s->cfg.tun_peer_ip;
            }
            pthread_rwlock_unlock(&bk->lock);
        }
    }
    pthread_rwlock_unlock(&rt->sessions.lock);

    for (uint32_t i = 0; i < count; i++)
        (void)bond_runtime_remove_session(rt, ips[i]);

    free(ips);

    pthread_mutex_destroy(&srv->pool_lock);
    free(srv->pool_used);
    free(srv);
}

bool bond_server_is_active(const bond_runtime_t *rt)
{
    return (NULL != rt &&
            NULL != atomic_load_explicit(&rt->server, memory_order_acquire));
}
