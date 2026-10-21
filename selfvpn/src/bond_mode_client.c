#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <time.h>
#include <unistd.h>
#include <sys/prctl.h>
#include <sys/socket.h>

#include "bond_mode.h"
#include "bond_runtime.h"
#include "bond_session.h"
#include "bond_trans_tool.h"
#include "bond_tun.h"
#include "bond_util.h"
#include "core.h"

#define BOND_CLIENT_RETRY_MS      1000
#define BOND_CLIENT_ALIVE_MS      3000
#define BOND_CONNECT_TIMEOUT_SEC  5

static const char *bond_client_secret(const bond_session_t *s)
{
    return ('\0' == s->cfg.secret[0]) ? "bond_test_demo" : s->cfg.secret;
}

static bool bond_client_wait(bond_session_t *s, int total_ms)
{
    struct timespec deadline;
    bool alive;

    clock_gettime(CLOCK_REALTIME, &deadline);
    deadline.tv_sec += total_ms / 1000;
    deadline.tv_nsec += (long)(total_ms % 1000) * 1000000L;
    if (deadline.tv_nsec >= 1000000000L) {
        deadline.tv_sec++;
        deadline.tv_nsec -= 1000000000L;
    }

    pthread_mutex_lock(&s->wait_lock);
    while (!atomic_load_explicit(&s->stop, memory_order_acquire)) {
        if (ETIMEDOUT == pthread_cond_timedwait(&s->wait_cond, &s->wait_lock, &deadline))
            break;
    }
    alive = !atomic_load_explicit(&s->stop, memory_order_acquire);
    pthread_mutex_unlock(&s->wait_lock);

    return alive;
}

static void *bond_client_connect_thread(void *arg)
{
    bond_session_t *s = arg;
    bond_connection_t *conn = &s->conn;

    prctl(PR_SET_NAME, "<bond>tconn_cli", 0, 0, 0);

    while (!atomic_load_explicit(&s->stop, memory_order_acquire)) {

        if (conn->fd >= 0) {
            if (!atomic_load_explicit(&conn->stop, memory_order_acquire) &&
                core_socket_alive(conn->fd)) {
                bond_client_wait(s, BOND_CLIENT_ALIVE_MS);
                continue;
            }

            bond_session_detach_conn(s);
            atomic_store_explicit(&s->state, BOND_SESSION_CONNECTING, memory_order_release);
        }

        /* 不绑定具体网口，由 MPTCP 路径管理自动加入子流 */
        int fd = core_socket_connect(s->cfg.client.server_ip,
                                     s->cfg.client.server_port,
                                     NULL,
                                     BOND_CONNECT_TIMEOUT_SEC);
        if (fd < 0) {
            if (!bond_client_wait(s, BOND_CLIENT_RETRY_MS))
                break;
            continue;
        }

        atomic_store_explicit(&conn->stop, false, memory_order_release);
        conn->fd = fd;
        core_socket_tune(fd, s->runtime->sock_send_buf, s->runtime->sock_recv_buf);

        if (0 != bond_connection_send_auth_request(fd, bond_client_secret(s), s->cfg.sn)) {
            close(fd);
            conn->fd = BOND_INVALID_FD;
            if (!bond_client_wait(s, BOND_CLIENT_RETRY_MS))
                break;
            continue;
        }

        bond_auth_result_t auth;
        memset(&auth, 0, sizeof(auth));
        if (0 != bond_connection_recv_auth_response(fd, &auth) ||
            BOND_AUTH_STATUS_OK != auth.status || 0 == auth.assigned_ip) {
            bt_log_error(LOG_ALL_OUT, "sn:%s auth failed! status:%u\n", s->cfg.sn, auth.status);
            close(fd);
            conn->fd = BOND_INVALID_FD;
            if (!bond_client_wait(s, BOND_CLIENT_RETRY_MS))
                break;
            continue;
        }

        if (0 == auth.server_ip) {
            bt_log_error(LOG_ALL_OUT, "sn:%s server did not provide tun ip!\n", s->cfg.sn);
            close(fd);
            conn->fd = BOND_INVALID_FD;
            if (!bond_client_wait(s, BOND_CLIENT_RETRY_MS))
                break;
            continue;
        }

        uint32_t peer_ip = auth.server_ip;
        if (0 != bond_tun_set_client_addr(s->runtime->tun, auth.assigned_ip, peer_ip)) {
            bt_log_error(LOG_ALL_OUT, "sn:%s configure tun failed! ip:%u\n",
                         s->cfg.sn, auth.assigned_ip);
            close(fd);
            conn->fd = BOND_INVALID_FD;
            if (!bond_client_wait(s, BOND_CLIENT_RETRY_MS))
                break;
            continue;
        }

        conn->local_tun_ip = auth.assigned_ip;
        conn->peer_tun_ip = peer_ip;

        /* 用服务端下发的 peer tun ip 刷新统计槽位描述 */
        char peer_str[BOND_IP_STR_LEN] = {0};
        bond_ip_format(peer_ip, peer_str, sizeof(peer_str));
        s->stat = traffic_register(s->cfg.sn, peer_str, (int)s->cfg.id);

        if (atomic_load_explicit(&s->stop, memory_order_acquire)) {
            close(fd);
            conn->fd = BOND_INVALID_FD;
            break;
        }

        /* 先置 ONLINE 再注册：避免 attach 后、状态迁移前的事件被当成认证阶段处理 */
        atomic_store_explicit(&s->state, BOND_SESSION_ONLINE, memory_order_release);

        if (0 != bond_session_attach(s)) {
            atomic_store_explicit(&s->state, BOND_SESSION_CONNECTING, memory_order_release);
            bond_session_detach_conn(s);
            if (!bond_client_wait(s, BOND_CLIENT_RETRY_MS))
                break;
            continue;
        }

        traffic_set_online(s->stat, true);

        bt_log_info(LOG_ALL_OUT, "sn:%s online, tun ip %u.%u.%u.%u peer %u.%u.%u.%u\n",
                    s->cfg.sn,
                    (auth.assigned_ip >> 24) & 0xFF, (auth.assigned_ip >> 16) & 0xFF,
                    (auth.assigned_ip >> 8) & 0xFF, auth.assigned_ip & 0xFF,
                    (peer_ip >> 24) & 0xFF, (peer_ip >> 16) & 0xFF,
                    (peer_ip >> 8) & 0xFF, peer_ip & 0xFF);
    }

    if (conn->fd >= 0)
        bond_session_detach_conn(s);

    return NULL;
}

static int bond_client_session_start(bond_session_t *s)
{
    int ret;

    if (NULL == s)
        return -1;

    ret = pthread_create(&s->conn.thread, NULL, bond_client_connect_thread, s);
    if (0 != ret) {
        s->conn.thread = 0;
        return -1;
    }

    return 0;
}

static void bond_client_session_stop(bond_session_t *s)
{
    if (NULL == s)
        return;

    if (s->conn.fd >= 0)
        shutdown(s->conn.fd, SHUT_RDWR);

    if (0 != s->conn.thread) {
        pthread_join(s->conn.thread, NULL);
        s->conn.thread = 0;
    }
}

/* client 只有一条会话, 固定落在 0 号桶 */
static int bond_client_route_key(bond_runtime_t *rt, const uint8_t *ip_pkt,
                                 uint32_t len, uint32_t *key)
{
    (void)rt;
    (void)ip_pkt;
    (void)len;

    if (NULL == key)
        return -1;

    *key = 0;
    return 0;
}

const bond_mode_ops_t bond_client_ops = {
    .session_start = bond_client_session_start,
    .session_stop = bond_client_session_stop,
    .route_key = bond_client_route_key,
};
