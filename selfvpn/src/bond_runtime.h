#ifndef BOND_RUNTIME_H
#define BOND_RUNTIME_H

#include <sys/uio.h>

#include "bond_types.h"
#include "bond_pipeline.h"
#include "bond_mode.h"

#define BOND_REACTOR_WORKERS 4

/* 所有会话 ring 的总内存预算; 单会话上限仍由调用方请求值决定 */
#define BOND_DEFAULT_RING_BYTES   (5u << 20)
#define BOND_DEFAULT_RING_TOTAL   (512u << 20)
#define BOND_MIN_RING_BYTES       (16u << 10)

typedef struct bond_tun bond_tun_t;
typedef struct bond_server bond_server_t;
typedef struct reactor reactor_t;
typedef struct reactor_reg reactor_reg_t;

typedef struct bond_session_bucket {
    pthread_rwlock_t  lock;   /* 保护本桶链表; 分发只取本桶读锁 */
    bond_session_t   *head;
} bond_session_bucket_t;

typedef struct bond_session_table {
    pthread_rwlock_t       lock;   /* 结构性变更与全表遍历 */
    bond_session_bucket_t *buckets;
    uint32_t               bucket_count;
    uint32_t               count;
} bond_session_table_t;

typedef struct bond_runtime_cfg {
    bond_mode_t          mode;
    uint32_t             buffer_size_mb;

    char                 tun_name[BOND_TUN_NAME_LEN];
    char                 tun_local_ip[BOND_IP_STR_LEN];
    char                 tun_netmask[BOND_IP_STR_LEN];
    int                  tun_mtu;
    char                 tun_pool_start[BOND_IP_STR_LEN];
    char                 tun_pool_end[BOND_IP_STR_LEN];
} runtime_cfg_t;

struct bond_runtime {
    runtime_cfg_t     cfg;           /* 只读 */
    const bond_mode_ops_t *ops;      /* 由 mode 选择 */

    bond_tun_t            *tun;           /* 库创建并拥有 */

    uint32_t               tun_local_ip;  /* host order */
    uint32_t               tun_netmask;   /* host order */
    uint32_t               pool_start;    /* host order, server */
    uint32_t               pool_end;      /* host order, server */
    uint32_t               pool_count;

    _Atomic(bond_server_t *) server;      /* server 模式下的监听/地址池 */

    bond_pool_t           *to_socket_pool; /* bond_frame_t */
    bond_pool_t           *to_tun_pool;    /* bond_frame_ref_t */

    bond_session_table_t   sessions;
    uint32_t               next_session_id; /* 单调递增, 不复用 */
    uint32_t               ring_total_bytes; /* 所有会话 ring 的预算 */
    int                    sock_send_buf;    /* 每连接发送缓冲(bytes), 0 = 内核自动调优 */
    int                    sock_recv_buf;    /* 每连接接收缓冲(bytes) */

    bond_session_t        *reap_head;     /* 已摘除、待 worker 销毁的会话 */
    bond_session_t        *reap_tail;
    atomic_uint            auth_count;    /* 认证中的会话数, 用于跳过 idle 全表扫描 */

    reactor_t             *reactor;       /* 单 epoll + worker 池 */
    reactor_reg_t         *tun_reg;
    int                    auth_timer_fd; /* 认证超时定时器 */
    reactor_reg_t         *auth_timer_reg;

    int                    tun_fd;        /* TUN 读事件使用 */
    bond_ptr_queue_t      *tun_out_q;     /* socket -> TUN 的待写包 */
    bond_pool_t           *tun_out_pool;
    atomic_uint            tun_bp;        /* TUN 写队列满的标记, 用于触发重试 */
    atomic_bool            kick_pending;  /* 已投递 kick 任务 */
    pthread_t              tun_writer_tid;
    atomic_bool            tun_writer_stop;

    pthread_mutex_t        lifecycle_lock;
};

bond_runtime_t *bond_runtime_create(const runtime_cfg_t *cfg);

/* 内部测试接口：接管一个已有 tun 设备，不执行 TUNSETIFF/IP 配置 */
bond_runtime_t *bond_runtime_create_with_tun(const runtime_cfg_t *cfg, bond_tun_t *tun);

void bond_runtime_destroy(bond_runtime_t *rt);

int  bond_runtime_start(bond_runtime_t *rt);
void bond_runtime_stop(bond_runtime_t *rt);

int  bond_runtime_add_session(bond_runtime_t *rt, const bond_session_cfg_t *cfg);
int  bond_runtime_add_accepted_session(bond_runtime_t *rt, const bond_session_cfg_t *cfg, int fd);
int  bond_runtime_remove_session(bond_runtime_t *rt, uint32_t tun_peer_ip);
int  bond_runtime_remove_client_session(bond_runtime_t *rt);

/* ring 总预算(bytes); 0 表示使用默认值 */
void     bond_runtime_set_ring_limit(bond_runtime_t *rt, uint32_t bytes);
/* 每连接 socket 收发缓冲(bytes); 0 表示交给内核自动调优 */
void     bond_runtime_set_socket_buffer(bond_runtime_t *rt, int send_bytes, int recv_bytes);
/* 按总预算折算单会话实际可用 ring 容量(bytes) */
uint32_t bond_runtime_ring_capacity(const bond_runtime_t *rt, uint32_t requested);

/* TUN 分发: 按目的地址哈希到桶后只取该桶读锁 */
int  bond_runtime_dispatch_from_tun(bond_runtime_t *rt, bond_frame_t *frame);

/* socket -> TUN：拷贝入队，由独立写线程负责实际写入与背压 */
int  bond_runtime_tun_write(bond_runtime_t *rt, struct iovec *iov, int iovcnt);

#endif /* BOND_RUNTIME_H */
