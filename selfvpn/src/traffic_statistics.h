/*================================================================
*
*   文件名称：traffic_statistics.h
*   描    述：设备流量统计
*            - 转发路径: 建连时拿到槽位指针并缓存, 之后只做原子累加,
*                        无锁、无查找, 与设备总数无关
*            - 查询路径: 按 (序列号, tun ip) 哈希查找, 平均 O(1), 不依赖设备数量上限
*            - 槽位只增不删: 断线、重连、注销后累计流量仍然连续, 供计费使用
*
================================================================*/

#ifndef __TRAFFIC_STATISTICS_H__
#define __TRAFFIC_STATISTICS_H__

#include <stdint.h>
#include <stdbool.h>
#include <stdatomic.h>

#include "bond_trans_sdk.h"     /* AUTHENTICATE_INFO_LEN / IP_ADDR_LEN / bond_device_stat_t */

/* 单个设备的统计槽位; 由 traffic_register 分配, 进程内地址永不改变 */
typedef struct bond_stat_slot_tag
{
    char sn[AUTHENTICATE_INFO_LEN];         // 序列号
    char tun_peer_ip[IP_ADDR_LEN];          // 客户端tun ip

    atomic_int online;                      // 客户端是否在线
    atomic_int index;                       // 客户端索引
    atomic_uint_fast64_t rx_bytes;          // 客户端上行流量
    atomic_uint_fast64_t tx_bytes;          // 客户端下行流量

    uint64_t sn_hash;                       // sn 单独哈希, 用于按序列号查
    uint64_t key_hash;                      // (sn, tun_peer_ip) 哈希, 用于注册去重
    struct bond_stat_slot_tag *hnext;       // key 哈希链
    struct bond_stat_slot_tag *sn_next;     // sn 哈希链
} bond_stat_slot_t;

/* 初始化统计表; 由 trans_init 调用, 调用期间不可并发查询/注册 */
void traffic_init(void);

/* 释放统计表; 由 trans_uninit 调用, 调用期间不可并发查询/注册 */
void traffic_uninit(void);

/* 注册设备并返回槽位指针; 键为 (sn, tun_peer_ip) */
bond_stat_slot_t *traffic_register(const char *sn, const char *tun_peer_ip, int index);

/* 热路径: 对缓存的槽位指针做原子累加, 无锁、O(1) 约定 rx_bytes 只由接收线程调用, tx_bytes 只由发送线程调用 */
static inline void traffic_add_rx(bond_stat_slot_t *slot, uint64_t bytes)
{
    if (NULL == slot || 0 == bytes)
        return;

    atomic_fetch_add_explicit(&slot->rx_bytes, bytes, memory_order_relaxed);
}

static inline void traffic_add_tx(bond_stat_slot_t *slot, uint64_t bytes)
{
    if (NULL == slot || 0 == bytes)
        return;

    atomic_fetch_add_explicit(&slot->tx_bytes, bytes, memory_order_relaxed);
}

/* 更新在线状态 */
void traffic_set_online(bond_stat_slot_t *slot, bool online);

/* 按序列号快速查找; 同一 sn 多连接时优先返回在线槽位 */
bond_stat_slot_t *traffic_find_by_sn(const char *sn);

/* 读取单个槽位的快照 */
void traffic_snapshot(bond_stat_slot_t *slot, bond_device_stat_t *out);

/* 获取当前所有已注册设备的快照, 返回实际写入的条数; 条数不足时只返回前 max_count 条 */
int traffic_get_all(bond_device_stat_t *list, int max_count);

/* 当前已注册设备总数(含已断开的设备) */
int traffic_device_count(void);

/* 当前在线设备数 */
int traffic_online_count(void);

#endif
