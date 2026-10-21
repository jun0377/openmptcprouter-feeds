#ifndef BOND_CHANNEL_H
#define BOND_CHANNEL_H

#include <stdbool.h>
#include <stdint.h>
#include <sys/uio.h>

#include "bond_pipeline.h"

typedef struct bond_channel bond_channel_t;

/* TUN 写入回调：由 runtime 提供，负责排队/背压，channel 不直接阻塞 */
typedef int (*bond_tun_write_fn)(void *ctx, struct iovec *iov, int iovcnt);

/* 一条连接的字节流通道；只允许持有它的 reactor handler 访问，内部无锁 */
bond_channel_t *bond_channel_create(uint32_t ring_capacity,
                                    bond_pool_t *frame_pool,
                                    bond_pool_t *ref_pool,
                                    bond_tun_write_fn tun_write,
                                    void *tun_ctx);
void bond_channel_destroy(bond_channel_t *ch);

/* socket -> ring -> tun；返回 0 成功，-1 连接不可用 */
int bond_channel_recv(bond_channel_t *ch, int sock_fd, uint64_t *rx_bytes);
/* tun -> 队列 -> socket；EAGAIN 时保留进度，返回 0 */
int bond_channel_send(bond_channel_t *ch, int sock_fd, uint64_t *tx_bytes);

/* tun -> 待发队列，返回 0 成功 */
int bond_channel_enqueue(bond_channel_t *ch, bond_frame_t *frame);

bool bond_channel_tx_pending(const bond_channel_t *ch);
bool bond_channel_has_queued(const bond_channel_t *ch);
/* socket -> TUN 方向还有待写帧(预算用尽, 需要继续跑) */
bool bond_channel_tun_pending(const bond_channel_t *ch);
/* 上次写入因 TUN 侧队列满而失败, 需要等 TUN 腾出空间后唤醒 */
bool bond_channel_tun_blocked(const bond_channel_t *ch);
void bond_channel_reset(bond_channel_t *ch);

#endif /* BOND_CHANNEL_H */
