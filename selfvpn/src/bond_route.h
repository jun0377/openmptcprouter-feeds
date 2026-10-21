#ifndef BOND_ROUTE_H
#define BOND_ROUTE_H

#include <stdint.h>

/*
 * 安装/清理 client 模式隧道路由。
 *
 * tun_name  : selfvpn 创建的 tun 设备名
 * local_ip  : 服务端分配的 tun 本地地址
 * peer_ip   : 服务端 tun 地址, 即隧道路由的网关
 * server_ip : 外层服务器地址(remoteAddr), 用于固定隧道自身的外出路径
 *
 * 主表默认路由由 omr-tracker(003-up) 负责, 本模块只处理:
 *   1. 服务器 /32 直连路由(避免默认路由切到隧道后外层连接绕回隧道)
 *   2. 1500 号策略路由表的 from/oif 规则与默认路由
 */
int bond_route_setup(const char *tun_name, uint32_t local_ip, uint32_t peer_ip,
                     const char *server_ip);

/* 幂等清理, 断开/停止时调用 */
void bond_route_remove(void);

#endif /* BOND_ROUTE_H */
