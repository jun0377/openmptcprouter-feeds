#include <errno.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>
#include <arpa/inet.h>
#include <sys/epoll.h>
#include <sys/socket.h>

#include "bond_mode.h"
#include "bond_connection.h"
#include "bond_runtime.h"
#include "bond_session.h"
#include "bond_trans_tool.h"
#include "bond_util.h"

static int bond_server_session_start(bond_session_t *s)
{
    (void)s;
    /* server 会话由监听事件动态创建，不走 per-session start */
    return -1;
}

/*
 * 累积认证请求。返回 0=请求完整, 1=数据未到齐, -1=出错。
 * fd 为非阻塞，读取不做任何等待。
 */
static int bond_server_auth_recv(bond_session_t *s)
{
    bond_session_auth_t *a = &s->auth;

    for (;;) {
        ssize_t n;

        if (a->rx_len >= sizeof(a->rx))
            return -1;

        n = recv(s->conn.fd, a->rx + a->rx_len, sizeof(a->rx) - a->rx_len, 0);
        if (n > 0) {
            a->rx_len += (uint32_t)n;

            if (0 == a->need) {
                if (a->rx_len < 2)
                    continue;
                if (0 != bond_auth_request_length(a->rx, a->rx_len, &a->need))
                    return -1;
            }

            if (a->rx_len < a->need)
                continue;

            return 0;
        }
        if (0 == n)
            return -1;
        if (EINTR == errno)
            continue;
        if (EAGAIN == errno || EWOULDBLOCK == errno)
            return 1;
        return -1;
    }
}

/*
 * 非阻塞认证状态机：收齐请求 -> 校验 -> 写响应。
 * 返回 1=进行中(已按需武装 EPOLLOUT), 0=完成, -1=失败。
 */
static int bond_server_authenticate(bond_session_t *s, uint32_t events)
{
    bond_session_auth_t *a;
    int ret;

    (void)events;

    if (NULL == s)
        return -1;

    a = &s->auth;

    if (0 == a->tx_len) {
        char sn[BOND_AUTH_LEN] = {0};
        uint8_t status = BOND_AUTH_STATUS_OK;

        ret = bond_server_auth_recv(s);
        if (ret > 0) {
            reactor_want(s->reg, 0);
            return 1;
        }
        if (ret < 0)
            return -1;

        if (0 != bond_auth_request_verify(a->rx, a->rx_len, s->cfg.secret, sn, sizeof(sn)))
            status = BOND_AUTH_STATUS_FAILED;

        if (BOND_AUTH_STATUS_OK == status) {
            char peer_ip[BOND_IP_STR_LEN] = {0};

            if ('\0' == sn[0])
                bond_ip_format(s->cfg.tun_peer_ip, sn, sizeof(sn));

            snprintf(s->cfg.sn, sizeof(s->cfg.sn), "%s", sn);
            bond_ip_format(s->cfg.tun_peer_ip, peer_ip, sizeof(peer_ip));
            s->stat = traffic_register(s->cfg.sn, peer_ip, (int)s->cfg.id);
        } else {
            bt_log_error(LOG_ALL_OUT, "auth failed! assigned tun ip %u.%u.%u.%u\n",
                         (s->cfg.tun_peer_ip >> 24) & 0xFF,
                         (s->cfg.tun_peer_ip >> 16) & 0xFF,
                         (s->cfg.tun_peer_ip >> 8) & 0xFF, s->cfg.tun_peer_ip & 0xFF);
        }

        a->status = status;
        bond_auth_response_build(a->resp, status,
                                 (BOND_AUTH_STATUS_OK == status) ? s->cfg.tun_peer_ip : 0,
                                 (BOND_AUTH_STATUS_OK == status) ? s->runtime->tun_local_ip : 0);
        a->tx_len = (uint32_t)sizeof(a->resp);
        a->tx_off = 0;
    }

    while (a->tx_off < a->tx_len) {
        ssize_t n = send(s->conn.fd, a->resp + a->tx_off, a->tx_len - a->tx_off,
                         MSG_NOSIGNAL);

        if (n > 0) {
            a->tx_off += (uint32_t)n;
            continue;
        }
        if (n < 0 && EINTR == errno)
            continue;
        if (n < 0 && (EAGAIN == errno || EWOULDBLOCK == errno)) {
            reactor_want(s->reg, EPOLLOUT);
            return 1;
        }
        return -1;
    }

    return (BOND_AUTH_STATUS_OK == a->status) ? 0 : -1;
}

static void bond_server_session_stop(bond_session_t *s)
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

/* server: 按目的地址找会话 */
static int bond_server_route_key(bond_runtime_t *rt, const uint8_t *ip_pkt,
                                 uint32_t len, uint32_t *key)
{
    uint32_t dst_ip;

    (void)rt;

    if (NULL == ip_pkt || len < 20 || NULL == key)
        return -1;

    memcpy(&dst_ip, ip_pkt + 16, sizeof(dst_ip));
    *key = ntohl(dst_ip);

    return 0;
}

const bond_mode_ops_t bond_server_ops = {
    .session_start = bond_server_session_start,
    .session_stop = bond_server_session_stop,
    .authenticate = bond_server_authenticate,
    .route_key = bond_server_route_key,
};
