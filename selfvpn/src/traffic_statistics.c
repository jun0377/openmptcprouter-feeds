/*================================================================
*
*   文件名称：traffic_statistics.c
*   描    述：设备流量统计实现
*            - 哈希表: 分离链表 + FNV-1a, 桶数按需翻倍, 槽位地址始终不变
*            - 统计值: 原子累加, 转发路径不加锁、不做查找
*            - 槽位: 只增不删, 断线重连后累计流量连续
*
================================================================*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <pthread.h>

#include "bond_trans_tool.h"
#include "traffic_statistics.h"

/* 哈希桶初始数量, 必须是 2 的幂(取模用位与) */
#define TRAFFIC_BUCKET_INIT     1024

/* 槽位池初始容量 */
#define TRAFFIC_POOL_INIT       64

static bond_stat_slot_t **g_buckets = NULL;                 /* 哈希桶, 每条链挂哈希相同的槽位 */
static size_t g_bucket_cnt = 0;                             /* 桶数量(2的幂) */
static size_t g_bucket_used = 0;                            /* 已挂载槽位数, 用于判断是否需要扩容 */

/* 按序列号单独建索引, 支持同 sn 多连接的快速查找 */
static bond_stat_slot_t **g_sn_buckets = NULL;
static size_t g_sn_bucket_cnt = 0;
static size_t g_sn_bucket_used = 0;

static bond_stat_slot_t **g_slots = NULL;                   /* 客户端设备槽位池, 只存指针, 用于全量遍历 */
static size_t g_slot_cnt = 0;
static size_t g_slot_cap = 0;

/* 保护哈希表/槽位池以及槽位的 sn、tun_peer_ip、index */
static pthread_rwlock_t g_lock = PTHREAD_RWLOCK_INITIALIZER;

// 把序列号做 FNV-1a 哈希, 供 sn 索引使用
static uint64_t traffic_hash_sn(const char *sn)
{
    uint64_t hash = 1469598103934665603ULL;
    const unsigned char *p = (const unsigned char *)sn;

    while ('\0' != *p) {
        hash ^= (uint64_t)(*p++);
        hash *= 1099511628211ULL;
    }

    return hash;
}

// 把 (序列号, 隧道ip) 一起哈希: 同一台设备换 ip 视为新槽位, 同 sn 的多连接互不覆盖
static uint64_t traffic_hash_key(const char *sn, const char *tun_peer_ip)
{
    uint64_t hash = 1469598103934665603ULL;                 /* FNV-1a 64 offset basis */
    const unsigned char *p = (const unsigned char *)sn;

    while ('\0' != *p) {
        hash ^= (uint64_t)(*p++);
        hash *= 1099511628211ULL;                           /* FNV-1a 64 prime */
    }

    hash ^= (uint64_t)'|';
    hash *= 1099511628211ULL;

    for (p = (const unsigned char *)tun_peer_ip; '\0' != *p; p++) {
        hash ^= (uint64_t)(*p);
        hash *= 1099511628211ULL;
    }

    return hash;
}

/* 扩容哈希桶; 只重新串联 hnext, 槽位自身地址不变, 调用方须持有写锁 */
static int traffic_rehash(void)
{
    size_t new_cnt = g_bucket_cnt << 1;
    bond_stat_slot_t **new_buckets = calloc(new_cnt, sizeof(*new_buckets));
    bond_stat_slot_t **new_sn_buckets = calloc(new_cnt, sizeof(*new_sn_buckets));

    if (NULL == new_buckets || NULL == new_sn_buckets) {
        free(new_buckets);
        free(new_sn_buckets);
        return -1;
    }

    for (size_t i = 0; i < g_bucket_cnt; i++) {
        bond_stat_slot_t *slot = g_buckets[i];

        while (NULL != slot) {
            bond_stat_slot_t *next = slot->hnext;
            size_t bucket = slot->key_hash & (new_cnt - 1);

            slot->hnext = new_buckets[bucket];
            new_buckets[bucket] = slot;

            slot = next;
        }

        slot = g_sn_buckets[i];
        while (NULL != slot) {
            bond_stat_slot_t *next = slot->sn_next;
            size_t bucket = slot->sn_hash & (new_cnt - 1);

            slot->sn_next = new_sn_buckets[bucket];
            new_sn_buckets[bucket] = slot;

            slot = next;
        }
    }

    free(g_buckets);
    free(g_sn_buckets);
    g_buckets = new_buckets;
    g_sn_buckets = new_sn_buckets;
    g_bucket_cnt = new_cnt;
    g_sn_bucket_cnt = new_cnt;

    return 0;
}

/* 把设备槽位指针追加到槽位池的末尾——容量不够时按 2 倍 realloc 扩容, 调用方须持有写锁 */
static int traffic_pool_push(bond_stat_slot_t *slot)
{
    // 容量不足, 两倍扩容
    if (g_slot_cnt == g_slot_cap) {
        size_t new_cap = (0 == g_slot_cap) ? TRAFFIC_POOL_INIT : (g_slot_cap << 1);
        bond_stat_slot_t **new_slots = realloc(g_slots, new_cap * sizeof(*new_slots));
        if (NULL == new_slots)
            return -1;

        g_slots = new_slots;
        g_slot_cap = new_cap;
    }

    g_slots[g_slot_cnt++] = slot;

    return 0;
}

// 把流量统计模块复位成"空表"状态——释放全部设备槽位、清空哈希桶，让统计重新从零开始
void traffic_init(void)
{
    pthread_rwlock_wrlock(&g_lock);

    for (size_t i = 0; i < g_slot_cnt; i++)
        free(g_slots[i]);

    g_slot_cnt = 0;
    g_bucket_used = 0;
    g_sn_bucket_used = 0;

    if (NULL == g_buckets) {
        g_buckets = calloc(TRAFFIC_BUCKET_INIT, sizeof(*g_buckets));
        g_sn_buckets = calloc(TRAFFIC_BUCKET_INIT, sizeof(*g_sn_buckets));
        if (NULL == g_buckets || NULL == g_sn_buckets) {
            free(g_buckets);
            free(g_sn_buckets);
            g_buckets = NULL;
            g_sn_buckets = NULL;
            g_bucket_cnt = 0;
            g_sn_bucket_cnt = 0;
            bt_log_error(LOG_ALL_OUT, "traffic buckets alloc fail!\n");
        } else {
            g_bucket_cnt = TRAFFIC_BUCKET_INIT;
            g_sn_bucket_cnt = TRAFFIC_BUCKET_INIT;
        }
    } else {
        memset(g_buckets, 0, g_bucket_cnt * sizeof(*g_buckets));
        memset(g_sn_buckets, 0, g_bucket_cnt * sizeof(*g_sn_buckets));
    }

    pthread_rwlock_unlock(&g_lock);
}

void traffic_uninit(void)
{
    pthread_rwlock_wrlock(&g_lock);

    for (size_t i = 0; i < g_slot_cnt; i++)
        free(g_slots[i]);

    free(g_slots);
    g_slots = NULL;
    g_slot_cnt = 0;
    g_slot_cap = 0;

    free(g_buckets);
    g_buckets = NULL;
    free(g_sn_buckets);
    g_sn_buckets = NULL;
    g_bucket_cnt = 0;
    g_sn_bucket_cnt = 0;
    g_bucket_used = 0;
    g_sn_bucket_used = 0;

    pthread_rwlock_unlock(&g_lock);
}

// 按 (序列号, 隧道ip) 取统计槽位——已存在就复用（保留累计流量），不存在就新建并挂进哈希表
bond_stat_slot_t *traffic_register(const char *sn, const char *tun_peer_ip, int index)
{
    if (NULL == sn || '\0' == sn[0] || NULL == g_buckets)
        return NULL;

    if (NULL == tun_peer_ip)
        tun_peer_ip = "";

    uint64_t key_hash = traffic_hash_key(sn, tun_peer_ip);          // 计算 (sn, ip) 哈希
    uint64_t sn_hash = traffic_hash_sn(sn);                         // sn 二级索引哈希
    size_t bucket = key_hash & (g_bucket_cnt - 1);                  // 拿到哈希桶号

    pthread_rwlock_wrlock(&g_lock);

    // 同一设备(序列号 + tun ip 都相同)重连时复用原槽位, 累计流量保持不变
    for (bond_stat_slot_t *slot = g_buckets[bucket]; NULL != slot; slot = slot->hnext) {

        // 不是同一台设备, 继续找链上的下一个
        if (slot->key_hash != key_hash ||
            0 != strcmp(slot->sn, sn) ||
            0 != strcmp(slot->tun_peer_ip, tun_peer_ip))
            continue;

        // 找到同一台设备(重连): 索引可能变化, 累计流量一律不动
        atomic_store_explicit(&slot->index, index, memory_order_relaxed);
        atomic_store_explicit(&slot->online, 0, memory_order_relaxed);

        pthread_rwlock_unlock(&g_lock);
        return slot;
    }

    // 分配新槽位
    bond_stat_slot_t *slot = calloc(1, sizeof(*slot));
    if (NULL == slot) {
        bt_log_error(LOG_ALL_OUT, "traffic slot alloc fail! sn:%s\n", sn);
        pthread_rwlock_unlock(&g_lock);
        return NULL;
    }

    // 填充字段
    snprintf(slot->sn, sizeof(slot->sn), "%s", sn);
    snprintf(slot->tun_peer_ip, sizeof(slot->tun_peer_ip), "%s", tun_peer_ip);
    atomic_init(&slot->index, index);
    slot->key_hash = key_hash;
    slot->sn_hash = sn_hash;
    atomic_init(&slot->online, 0);
    atomic_init(&slot->rx_bytes, 0);
    atomic_init(&slot->tx_bytes, 0);

    // 入槽位池
    if (0 != traffic_pool_push(slot)) {
        bt_log_error(LOG_ALL_OUT, "traffic pool push fail! sn:%s\n", sn);
        free(slot);
        pthread_rwlock_unlock(&g_lock);
        return NULL;
    }

    // 头插进两张哈希链
    slot->hnext = g_buckets[bucket];
    g_buckets[bucket] = slot;
    g_bucket_used++;

    size_t sn_bucket = sn_hash & (g_sn_bucket_cnt - 1);
    slot->sn_next = g_sn_buckets[sn_bucket];
    g_sn_buckets[sn_bucket] = slot;
    g_sn_bucket_used++;

    // 扩容失败只影响后续查询效率(链变长), 不影响正确性
    if ((g_bucket_used > g_bucket_cnt || g_sn_bucket_used > g_sn_bucket_cnt) &&
        0 != traffic_rehash())
        bt_log_warn(LOG_ALL_OUT, "traffic rehash fail! used:%zu cnt:%zu\n",
                    g_bucket_used, g_bucket_cnt);

    pthread_rwlock_unlock(&g_lock);

    return slot;
}

void traffic_set_online(bond_stat_slot_t *slot, bool online)
{
    if (NULL == slot)
        return;

    atomic_store_explicit(&slot->online, online ? 1 : 0, memory_order_relaxed);
}

/* 按序列号查找: 同一 sn 可能有多条连接(不同 tun ip), 优先返回在线的那条 */
bond_stat_slot_t *traffic_find_by_sn(const char *sn)
{
    bond_stat_slot_t *result = NULL;
    uint64_t hash;
    size_t bucket;

    if (NULL == sn || NULL == g_sn_buckets)
        return NULL;

    hash = traffic_hash_sn(sn);
    bucket = hash & (g_sn_bucket_cnt - 1);

    pthread_rwlock_rdlock(&g_lock);

    for (bond_stat_slot_t *slot = g_sn_buckets[bucket]; NULL != slot; slot = slot->sn_next) {
        if (slot->sn_hash != hash || 0 != strcmp(slot->sn, sn))
            continue;

        if (NULL == result)
            result = slot;

        if (atomic_load_explicit(&slot->online, memory_order_relaxed)) {
            result = slot;
            break;
        }
    }

    pthread_rwlock_unlock(&g_lock);

    return result;
}

/*
 * 槽位地址在进程内不变, sn/tun_peer_ip 创建后不再修改, 其余字段都是原子量,
 * 因此快照路径不需要持表锁, 不会阻塞注册/查询。
 */
void traffic_snapshot(bond_stat_slot_t *slot, bond_device_stat_t *out)
{
    if (NULL == slot || NULL == out)
        return;

    snprintf(out->sn, sizeof(out->sn), "%s", slot->sn);
    snprintf(out->tun_peer_ip, sizeof(out->tun_peer_ip), "%s", slot->tun_peer_ip);
    out->index = atomic_load_explicit(&slot->index, memory_order_relaxed);
    out->online = atomic_load_explicit(&slot->online, memory_order_relaxed);
    out->rx_bytes = atomic_load_explicit(&slot->rx_bytes, memory_order_relaxed);
    out->tx_bytes = atomic_load_explicit(&slot->tx_bytes, memory_order_relaxed);
}

// 只在读锁内拷贝槽位指针, 逐条取值放到锁外完成, 缩短持锁时间
int traffic_get_all(bond_device_stat_t *list, int max_count)
{
    bond_stat_slot_t **slots;
    size_t count;

    if (NULL == list || max_count <= 0)
        return 0;

    slots = malloc(sizeof(*slots) * (size_t)max_count);
    if (NULL == slots)
        return 0;

    pthread_rwlock_rdlock(&g_lock);
    count = (g_slot_cnt < (size_t)max_count) ? g_slot_cnt : (size_t)max_count;
    if (count > 0)
        memcpy(slots, g_slots, count * sizeof(*slots));
    pthread_rwlock_unlock(&g_lock);

    for (size_t i = 0; i < count; i++)
        traffic_snapshot(slots[i], &list[i]);

    free(slots);

    return (int)count;
}

/* 当前已注册设备总数 */
int traffic_device_count(void)
{
    int count;

    pthread_rwlock_rdlock(&g_lock);
    count = (int)g_slot_cnt;
    pthread_rwlock_unlock(&g_lock);

    return count;
}

/* 当前在线设备数: 遍历槽位池, 统计 online 标志为真的槽位个数 */
int traffic_online_count(void)
{
    int count = 0;

    pthread_rwlock_rdlock(&g_lock);

    for (size_t i = 0; i < g_slot_cnt; i++) {
        if (atomic_load_explicit(&g_slots[i]->online, memory_order_relaxed))
            count++;
    }

    pthread_rwlock_unlock(&g_lock);

    return count;
}
