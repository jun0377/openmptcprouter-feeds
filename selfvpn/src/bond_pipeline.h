#ifndef BOND_PIPELINE_H
#define BOND_PIPELINE_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>

#include "bond_types.h"

/*
 * 队列节点必须是结构体的第一个成员。
 * bond_frame_t / bond_frame_ref_t 都满足该约定, 因此队列不需要额外分配节点。
 */
typedef struct bond_list_node {
    struct bond_list_node *next;
} bond_list_node_t;

/* 拥有内存的帧: tun -> socket 方向 */
typedef struct bond_frame {
    bond_list_node_t node;
    uint8_t         *data;      /* 由 frame pool 统一分配和释放 */
    uint16_t         len;       /* 有效长度, 含 2B 长度前缀 */
    uint16_t         capacity;  /* BOND_FRAME_MAX */
} bond_frame_t;

/* 借用 ringbuffer 的帧: socket -> tun 方向 */
typedef struct bond_frame_ref {
    bond_list_node_t node;
    const uint8_t   *chunk[2];    /* ringbuffer 回绕时最多两段 */
    uint16_t         chunk_len[2];
    uint16_t         len;         /* IP 帧长度, 不含长度前缀 */
    uint32_t         generation;  /* ring 重置代数 */
} bond_frame_ref_t;

/*******************************************************************
 *                          指针队列
 *******************************************************************/
typedef struct bond_ptr_queue bond_ptr_queue_t;
typedef void (*bond_node_release_fn)(bond_list_node_t *node, void *ctx);

bond_ptr_queue_t *bond_queue_create(void);
void bond_queue_destroy(bond_ptr_queue_t *q, bond_node_release_fn release, void *ctx);
void bond_queue_close(bond_ptr_queue_t *q);
void bond_queue_wake_all(bond_ptr_queue_t *q);
int  bond_queue_push(bond_ptr_queue_t *q, bond_list_node_t *node);
/* 头插: 用于写入失败时把已取出的节点放回队首, 保证顺序 */
int  bond_queue_push_front(bond_ptr_queue_t *q, bond_list_node_t *node);
bond_list_node_t *bond_queue_pop(bond_ptr_queue_t *q, int timeout_ms);
/* 只查看队首, 不移除 */
bond_list_node_t *bond_queue_peek(bond_ptr_queue_t *q);
void bond_queue_drain(bond_ptr_queue_t *q, bond_node_release_fn release, void *ctx);
int  bond_queue_size(bond_ptr_queue_t *q);

/*******************************************************************
 *                          内存池
 *******************************************************************/
typedef struct bond_pool bond_pool_t;
typedef void (*bond_pool_elem_fn)(void *elem);

bond_pool_t *bond_pool_create(uint32_t count, size_t elem_size,
                              bond_pool_elem_fn ctor, bond_pool_elem_fn dtor);
void bond_pool_destroy(bond_pool_t *pool);
void *bond_pool_get(bond_pool_t *pool, int timeout_ms);
void bond_pool_put(bond_pool_t *pool, void *elem);

/*******************************************************************
 *                          环形缓冲区
 *******************************************************************/
typedef struct bond_ring bond_ring_t;

bond_ring_t *bond_ring_create(uint32_t capacity);
void bond_ring_destroy(bond_ring_t *rb);
void bond_ring_reset(bond_ring_t *rb);

/* 写者: 预先取得一段连续可写空间, 读取后 commit 实际写入长度 */
uint8_t *bond_ring_reserve(bond_ring_t *rb, uint32_t *contig_len);
void bond_ring_commit(bond_ring_t *rb, uint32_t len);
uint32_t bond_ring_write(bond_ring_t *rb, const uint8_t *data, uint32_t len);
uint32_t bond_ring_free_space(bond_ring_t *rb);

/* 解析者: 取一个完整帧的只读切片, 不移动 read_pos */
int bond_ring_peek_frame(bond_ring_t *rb, bond_frame_ref_t *ref);
/* 消费者: tun 写成功后提交消费 */
void bond_ring_consume(bond_ring_t *rb, const bond_frame_ref_t *ref);

uint32_t bond_ring_generation(bond_ring_t *rb);
/* 实际分配容量(向上取整到 2 的幂) */
uint32_t bond_ring_capacity(const bond_ring_t *rb);

#endif /* BOND_PIPELINE_H */
