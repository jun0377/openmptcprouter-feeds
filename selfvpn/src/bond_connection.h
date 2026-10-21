#ifndef BOND_CONNECTION_H
#define BOND_CONNECTION_H

#include "bond_types.h"

typedef struct bond_connection {
    int         fd;         /* -1 表示未连接；全库唯一持有者 */
    int         listen_fd;  /* 保留字段；池模式下由 bond_server 持有监听 fd */

    pthread_t   thread;     /* client 重连线程 */

    atomic_bool stop;       /* 当前连接级停止标志 */

    uint32_t    local_tun_ip; /* client: 服务端分配的 tun ip */
    uint32_t    peer_tun_ip;  /* client: 服务端 tun ip */
} bond_connection_t;

typedef struct bond_auth_result {
    uint8_t  status;
    uint32_t assigned_ip;   /* host order */
    uint32_t server_ip;     /* host order, 服务端 tun ip */
} bond_auth_result_t;

#define BOND_AUTH_STATUS_OK          0
#define BOND_AUTH_STATUS_FAILED      1
#define BOND_AUTH_STATUS_POOL_EMPTY  2
#define BOND_AUTH_STATUS_INTERNAL    3

/* 请求: 2B 总长 + 2B secret 长度 + secret + 2B sn 长度 + sn */
#define BOND_AUTH_REQUEST_MAX        (4 + BOND_AUTH_LEN + BOND_AUTH_LEN)
/* 响应: 2B 总长 + status(1) + assigned_ip(4) + server_ip(4) */
#define BOND_AUTH_RESPONSE_LEN       9
#define BOND_AUTH_TIMEOUT_MS         3000

/* client: 发送认证请求(secret + sn), 接收服务端下发的 tun ip */
int bond_connection_send_auth_request(int sockfd, const char *secret, const char *sn);
int bond_connection_recv_auth_response(int sockfd, bond_auth_result_t *result);

/*
 * server: 非阻塞认证。请求可能分多次到达, 由调用方累积到 buf 后调用:
 * length 只解析 2B 总长; verify 校验完整请求并输出 sn。
 */
int  bond_auth_request_length(const uint8_t *buf, uint32_t len, uint32_t *need);
int  bond_auth_request_verify(const uint8_t *buf, uint32_t len, const char *secret,
                              char *sn, size_t sn_len);
void bond_auth_response_build(uint8_t *buf, uint8_t status,
                              uint32_t assigned_ip, uint32_t server_ip);

#endif /* BOND_CONNECTION_H */
