#ifndef BOND_TUN_H
#define BOND_TUN_H

#include <stdbool.h>
#include <stdint.h>

#include "bond_types.h"

typedef struct bond_tun bond_tun_t;

/* 由库创建 TUN 设备；name 为空时由内核分配 */
bond_tun_t *bond_tun_create(const char *name, int mtu);

/* 内部测试接口：接管一个已有的 tun fd，不负责 close */
bond_tun_t *bond_tun_from_fd(int fd, const char *name);

void bond_tun_destroy(bond_tun_t *tun);

int bond_tun_fd(const bond_tun_t *tun);
const char *bond_tun_name(const bond_tun_t *tun);

/* server: local_ip/netmask 配置在 tun 上, 地址池走该网段的直连路由 */
int bond_tun_set_server_addr(bond_tun_t *tun, uint32_t local_ip, uint32_t netmask);
/* client: local_ip 为服务端分配地址, peer_ip 为服务端 tun ip */
int bond_tun_set_client_addr(bond_tun_t *tun, uint32_t local_ip, uint32_t peer_ip);

int bond_tun_set_up(bond_tun_t *tun);

#endif /* BOND_TUN_H */
