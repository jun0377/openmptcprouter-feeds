#ifndef BOND_MODE_H
#define BOND_MODE_H

#include "bond_types.h"

/*
 * client / server 只在这几个动作上存在真实差异。
 * authenticate 仅在 server 使用：返回 1 表示认证进行中, 0 表示完成, -1 表示失败。
 * route_key 从 IP 包解析会话键(tun ip, host order): server 取目的地址, client 固定 0。
 */
typedef struct bond_mode_ops {
    int  (*session_start)(bond_session_t *s);
    void (*session_stop)(bond_session_t *s);
    int  (*authenticate)(bond_session_t *s, uint32_t events);
    int  (*route_key)(bond_runtime_t *rt, const uint8_t *ip_pkt, uint32_t len,
                      uint32_t *key);
} bond_mode_ops_t;

extern const bond_mode_ops_t bond_client_ops;
extern const bond_mode_ops_t bond_server_ops;

#endif /* BOND_MODE_H */
