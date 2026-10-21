#ifndef BOND_SESSION_H
#define BOND_SESSION_H

#include "bond_types.h"
#include "bond_runtime.h"
#include "bond_connection.h"
#include "channel.h"
#include "reactor.h"
#include "traffic_statistics.h"

/* server: 半连接的非阻塞认证状态（请求累积 -> 校验 -> 写响应） */
typedef struct bond_session_auth {
    uint8_t  rx[2 + BOND_AUTH_REQUEST_MAX];   /* 请求累积缓冲(含 2B 总长) */
    uint32_t rx_len;
    uint32_t need;                        /* 完整请求长度(含 2B 前缀), 0 未知 */
    uint8_t  resp[2 + BOND_AUTH_RESPONSE_LEN];
    uint32_t tx_len;                      /* 0 表示响应尚未生成 */
    uint32_t tx_off;
    uint8_t  status;                      /* 待回复的认证结果 */
    int64_t  deadline_ms;                 /* 认证超时 */
} bond_session_auth_t;

struct bond_session {
    bond_runtime_t     *runtime;    /* 非拥有 */
    bond_session_cfg_t  cfg;        /* 只读 */

    bond_connection_t   conn;
    bond_channel_t     *ch;
    reactor_reg_t      *reg;

    bond_session_auth_t auth;       /* server 认证阶段使用 */

    atomic_bool         stop;       /* 会话级停止标志 */
    atomic_int          state;      /* bond_session_state_t */
    atomic_bool         auth_counted; /* 已计入 runtime->auth_count */
    bond_stat_slot_t   *stat;       /* 非拥有，生命周期同 traffic registry */

    bool                from_pool;  /* server: tun ip 来自地址池, 移除时需归还 */
    struct bond_session *hash_next; /* 会话表哈希链 */
    struct bond_session *reap_next; /* 待销毁队列 */

    /*
     * 保护 "入队 + 武装 EPOLLOUT" 与 "检查队列 + 撤销 EPOLLOUT" 的原子性。
     * 两侧不加锁会出现: TUN 线程刚武装 EPOLLOUT, handler 结尾用空队列
     * 把它覆盖成 0, 已入队的包永远等不到发送事件。
     */
    pthread_mutex_t     tx_lock;

    /* client 重连等待: stop 时立即唤醒, 避免 worker 在 join 上长时间阻塞 */
    pthread_mutex_t     wait_lock;
    pthread_cond_t      wait_cond;
};

bond_session_t *bond_session_create(bond_runtime_t *rt, const bond_session_cfg_t *cfg);
void bond_session_destroy(bond_session_t *s);

/* client: 启动重连线程; server 会话不使用 */
int  bond_session_start(bond_session_t *s);
void bond_session_stop(bond_session_t *s);

/* 把 socket fd 注册到 runtime 的 reactor；失败返回 -1 */
int  bond_session_attach(bond_session_t *s);
/* 只断开当前连接(可重连)，不销毁会话 */
void bond_session_detach_conn(bond_session_t *s);

bool bond_session_is_online(bond_session_t *s);
uint32_t bond_session_peer_ip(const bond_session_t *s);

/* TUN -> socket 方向入队，并保证 EPOLLOUT 被武装 */
int  bond_session_enqueue_from_tun(bond_session_t *s, bond_frame_t *frame);

/* reactor handler */
void bond_session_on_event(void *ctx, uint32_t events);

/* 连接不可用时由 handler 调用 */
void bond_session_connection_lost(bond_session_t *s);

/* 认证阶段结束(完成或失败), 不计入 pending 扫描 */
void bond_session_auth_done(bond_session_t *s);

#endif /* BOND_SESSION_H */
