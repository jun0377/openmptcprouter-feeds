#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>
#include <arpa/inet.h>
#include <sys/time.h>

#include "bond_pipeline.h"
#include "bond_trans_tool.h"

/*******************************************************************
 *                          指针队列
 *******************************************************************/
struct bond_ptr_queue {
    bond_list_node_t *head;
    bond_list_node_t *tail;
    uint32_t          count;
    bool              closed;
    pthread_mutex_t   lock;
    pthread_cond_t    not_empty;
};

static void bond_cond_deadline(struct timespec *ts, int timeout_ms)
{
    struct timeval now;

    gettimeofday(&now, NULL);
    ts->tv_sec = now.tv_sec + timeout_ms / 1000;
    ts->tv_nsec = (long)now.tv_usec * 1000L + (long)(timeout_ms % 1000) * 1000000L;
    if (ts->tv_nsec >= 1000000000L) {
        ts->tv_sec++;
        ts->tv_nsec -= 1000000000L;
    }
}

bond_ptr_queue_t *bond_queue_create(void)
{
    bond_ptr_queue_t *q = calloc(1, sizeof(*q));

    if (NULL == q)
        return NULL;

    pthread_mutex_init(&q->lock, NULL);
    pthread_cond_init(&q->not_empty, NULL);

    return q;
}

void bond_queue_close(bond_ptr_queue_t *q)
{
    if (NULL == q)
        return;

    pthread_mutex_lock(&q->lock);
    q->closed = true;
    pthread_cond_broadcast(&q->not_empty);
    pthread_mutex_unlock(&q->lock);
}

void bond_queue_wake_all(bond_ptr_queue_t *q)
{
    if (NULL == q)
        return;

    pthread_mutex_lock(&q->lock);
    pthread_cond_broadcast(&q->not_empty);
    pthread_mutex_unlock(&q->lock);
}

int bond_queue_push(bond_ptr_queue_t *q, bond_list_node_t *node)
{
    if (NULL == q || NULL == node)
        return -1;

    node->next = NULL;

    pthread_mutex_lock(&q->lock);
    if (q->closed) {
        pthread_mutex_unlock(&q->lock);
        return -1;
    }

    if (q->tail)
        q->tail->next = node;
    else
        q->head = node;

    q->tail = node;
    q->count++;
    pthread_cond_signal(&q->not_empty);
    pthread_mutex_unlock(&q->lock);

    return 0;
}

int bond_queue_push_front(bond_ptr_queue_t *q, bond_list_node_t *node)
{
    if (NULL == q || NULL == node)
        return -1;

    pthread_mutex_lock(&q->lock);
    if (q->closed) {
        pthread_mutex_unlock(&q->lock);
        return -1;
    }

    node->next = q->head;
    q->head = node;
    if (NULL == q->tail)
        q->tail = node;
    q->count++;
    pthread_cond_signal(&q->not_empty);
    pthread_mutex_unlock(&q->lock);

    return 0;
}

bond_list_node_t *bond_queue_peek(bond_ptr_queue_t *q)
{
    bond_list_node_t *node;

    if (NULL == q)
        return NULL;

    pthread_mutex_lock(&q->lock);
    node = q->head;
    pthread_mutex_unlock(&q->lock);

    return node;
}

bond_list_node_t *bond_queue_pop(bond_ptr_queue_t *q, int timeout_ms)
{
    bond_list_node_t *node = NULL;
    struct timespec deadline;
    bool has_deadline = false;

    if (NULL == q)
        return NULL;

    if (timeout_ms > 0) {
        bond_cond_deadline(&deadline, timeout_ms);
        has_deadline = true;
    }

    pthread_mutex_lock(&q->lock);

    while (NULL == q->head && !q->closed) {
        if (0 == timeout_ms)
            break;

        if (has_deadline) {
            int ret = pthread_cond_timedwait(&q->not_empty, &q->lock, &deadline);
            if (ETIMEDOUT == ret)
                break;
        } else {
            pthread_cond_wait(&q->not_empty, &q->lock);
        }
    }

    node = q->head;
    if (node) {
        q->head = node->next;
        if (NULL == q->head)
            q->tail = NULL;
        node->next = NULL;
        q->count--;
    }

    pthread_mutex_unlock(&q->lock);

    return node;
}

void bond_queue_drain(bond_ptr_queue_t *q, bond_node_release_fn release, void *ctx)
{
    bond_list_node_t *node = NULL;

    if (NULL == q)
        return;

    while (NULL != (node = bond_queue_pop(q, 0))) {
        if (release)
            release(node, ctx);
    }
}

int bond_queue_size(bond_ptr_queue_t *q)
{
    int size;

    if (NULL == q)
        return 0;

    pthread_mutex_lock(&q->lock);
    size = (int)q->count;
    pthread_mutex_unlock(&q->lock);

    return size;
}

void bond_queue_destroy(bond_ptr_queue_t *q, bond_node_release_fn release, void *ctx)
{
    if (NULL == q)
        return;

    bond_queue_close(q);
    bond_queue_drain(q, release, ctx);
    pthread_cond_destroy(&q->not_empty);
    pthread_mutex_destroy(&q->lock);
    free(q);
}

/*******************************************************************
 *                          内存池
 *******************************************************************/
#define BOND_POOL_SHARDS   8
#define BOND_POOL_BATCH    16

typedef struct bond_pool_shard {
    bond_list_node_t *head;
    pthread_mutex_t   lock;
} bond_pool_shard_t;

struct bond_pool {
    bond_pool_shard_t shards[BOND_POOL_SHARDS];
    size_t            elem_size;
    bond_pool_elem_fn dtor;
};

/* 每个线程固定使用一个分片, 把一把全局锁拆成 8 把 */
static atomic_uint g_pool_thread_seq;
static __thread uint32_t g_pool_shard;      /* 0 表示尚未分配 */

static uint32_t bond_pool_local_shard(void)
{
    if (0 == g_pool_shard) {
        uint32_t seq = atomic_fetch_add_explicit(&g_pool_thread_seq, 1,
                                                 memory_order_relaxed);

        g_pool_shard = seq % BOND_POOL_SHARDS + 1;
    }

    return g_pool_shard - 1;
}

static bond_list_node_t *bond_pool_shard_pop(bond_pool_shard_t *sh)
{
    bond_list_node_t *node;

    pthread_mutex_lock(&sh->lock);
    node = sh->head;
    if (NULL != node) {
        sh->head = node->next;
        node->next = NULL;
    }
    pthread_mutex_unlock(&sh->lock);

    return node;
}

static void bond_pool_shard_push(bond_pool_shard_t *sh, bond_list_node_t *node)
{
    pthread_mutex_lock(&sh->lock);
    node->next = sh->head;
    sh->head = node;
    pthread_mutex_unlock(&sh->lock);
}

bond_pool_t *bond_pool_create(uint32_t count, size_t elem_size,
                              bond_pool_elem_fn ctor, bond_pool_elem_fn dtor)
{
    bond_pool_t *pool = NULL;

    if (0 == count || elem_size < sizeof(bond_list_node_t))
        return NULL;

    pool = calloc(1, sizeof(*pool));
    if (NULL == pool)
        return NULL;

    pool->elem_size = elem_size;
    pool->dtor = dtor;

    for (uint32_t i = 0; i < BOND_POOL_SHARDS; i++)
        pthread_mutex_init(&pool->shards[i].lock, NULL);

    for (uint32_t i = 0; i < count; i++) {
        void *elem = calloc(1, elem_size);

        if (NULL == elem) {
            bond_pool_destroy(pool);
            return NULL;
        }

        if (ctor)
            ctor(elem);

        bond_pool_shard_push(&pool->shards[i % BOND_POOL_SHARDS],
                             (bond_list_node_t *)elem);
    }

    return pool;
}

void *bond_pool_get(bond_pool_t *pool, int timeout_ms)
{
    uint32_t local;
    bond_list_node_t *node;
    int waited = 0;

    if (NULL == pool)
        return NULL;

    local = bond_pool_local_shard();

    for (;;) {
        uint32_t i;

        node = bond_pool_shard_pop(&pool->shards[local]);
        if (NULL != node)
            return node;

        /* 本地为空: 从其它分片批量搬一批到本地, 把锁开销摊到 BATCH 次取用上 */
        for (i = 0; i < BOND_POOL_SHARDS - 1; i++) {
            uint32_t victim = (local + 1 + i) % BOND_POOL_SHARDS;
            bond_pool_shard_t *vs = &pool->shards[victim];
            bond_list_node_t *list = NULL;
            bond_list_node_t *cur;
            uint32_t n = 0;

            if (victim == local)
                continue;

            pthread_mutex_lock(&vs->lock);
            while (n < BOND_POOL_BATCH && NULL != (cur = vs->head)) {
                vs->head = cur->next;
                cur->next = list;
                list = cur;
                n++;
            }
            pthread_mutex_unlock(&vs->lock);

            if (0 == n)
                continue;

            node = list;
            list = node->next;
            node->next = NULL;
            while (NULL != list) {
                bond_list_node_t *rest = list->next;

                bond_pool_shard_push(&pool->shards[local], list);
                list = rest;
            }
            return node;
        }

        if (timeout_ms <= 0 || waited >= timeout_ms)
            return NULL;

        usleep(200);
        waited += 200;
    }
}

void bond_pool_put(bond_pool_t *pool, void *elem)
{
    if (NULL == pool || NULL == elem)
        return;

    bond_pool_shard_push(&pool->shards[bond_pool_local_shard()],
                         (bond_list_node_t *)elem);
}

void bond_pool_destroy(bond_pool_t *pool)
{
    if (NULL == pool)
        return;

    for (uint32_t i = 0; i < BOND_POOL_SHARDS; i++) {
        bond_list_node_t *node;

        while (NULL != (node = bond_pool_shard_pop(&pool->shards[i]))) {
            void *elem = (void *)node;

            if (pool->dtor)
                pool->dtor(elem);
            free(elem);
        }
        pthread_mutex_destroy(&pool->shards[i].lock);
    }

    free(pool);
}

/*******************************************************************
 *                          环形缓冲区
 *******************************************************************/
struct bond_ring {
    uint8_t         *data;
    uint32_t         capacity;    /* 2 的幂 */
    uint32_t         mask;

    atomic_uint      write_pos;   /* 只由写者修改 */
    atomic_uint      read_pos;    /* 只由消费者修改 */
    uint32_t         parse_pos;   /* 只由解析者修改 */

    atomic_uint      generation;
};

static uint32_t bond_roundup_pow2(uint32_t v)
{
    if (v < 4096)
        v = 4096;

    if (v > (1u << 30))
        v = 1u << 30;

    v--;
    v |= v >> 1;
    v |= v >> 2;
    v |= v >> 4;
    v |= v >> 8;
    v |= v >> 16;
    v++;

    return v;
}

bond_ring_t *bond_ring_create(uint32_t capacity)
{
    bond_ring_t *rb = calloc(1, sizeof(*rb));

    if (NULL == rb)
        return NULL;

    rb->capacity = bond_roundup_pow2(capacity);
    rb->mask = rb->capacity - 1;
    rb->data = calloc(1, rb->capacity);
    if (NULL == rb->data) {
        free(rb);
        return NULL;
    }

    atomic_init(&rb->write_pos, 0);
    atomic_init(&rb->read_pos, 0);
    atomic_init(&rb->generation, 0);
    rb->parse_pos = 0;

    return rb;
}

void bond_ring_destroy(bond_ring_t *rb)
{
    if (NULL == rb)
        return;

    free(rb->data);
    free(rb);
}

uint32_t bond_ring_capacity(const bond_ring_t *rb)
{
    return (NULL == rb) ? 0 : rb->capacity;
}

void bond_ring_reset(bond_ring_t *rb)
{
    if (NULL == rb)
        return;

    atomic_store_explicit(&rb->write_pos, 0, memory_order_release);
    atomic_store_explicit(&rb->read_pos, 0, memory_order_release);
    rb->parse_pos = 0;
    atomic_fetch_add_explicit(&rb->generation, 1, memory_order_release);
}

uint32_t bond_ring_free_space(bond_ring_t *rb)
{
    uint32_t w, r;

    if (NULL == rb)
        return 0;

    w = atomic_load_explicit(&rb->write_pos, memory_order_acquire);
    r = atomic_load_explicit(&rb->read_pos, memory_order_acquire);

    if (w - r > rb->capacity)
        return 0;

    return rb->capacity - (w - r);
}

uint8_t *bond_ring_reserve(bond_ring_t *rb, uint32_t *contig_len)
{
    uint32_t w, r, used, free_space, idx, contig;

    if (NULL == rb || NULL == contig_len)
        return NULL;

    w = atomic_load_explicit(&rb->write_pos, memory_order_relaxed);
    r = atomic_load_explicit(&rb->read_pos, memory_order_acquire);
    used = w - r;

    if (used >= rb->capacity)
        return NULL;
    free_space = rb->capacity - used;
    idx = w & rb->mask;
    contig = rb->capacity - idx;
    if (contig > free_space)
        contig = free_space;

    *contig_len = contig;
    return rb->data + idx;
}

void bond_ring_commit(bond_ring_t *rb, uint32_t len)
{
    if (NULL == rb || 0 == len)
        return;

    atomic_fetch_add_explicit(&rb->write_pos, len, memory_order_release);
}

uint32_t bond_ring_write(bond_ring_t *rb, const uint8_t *data, uint32_t len)
{
    uint32_t written = 0;

    if (NULL == rb || NULL == data)
        return 0;

    while (written < len) {
        uint32_t contig = 0;
        uint8_t *dst = bond_ring_reserve(rb, &contig);

        if (NULL == dst || 0 == contig)
            break;

        if (contig > len - written)
            contig = len - written;

        memcpy(dst, data + written, contig);
        bond_ring_commit(rb, contig);
        written += contig;
    }

    return written;
}

uint32_t bond_ring_generation(bond_ring_t *rb)
{
    if (NULL == rb)
        return 0;

    return atomic_load_explicit(&rb->generation, memory_order_acquire);
}

int bond_ring_peek_frame(bond_ring_t *rb, bond_frame_ref_t *ref)
{
    uint32_t w, p, len;
    uint16_t be_len;
    uint8_t bytes[2];
    uint32_t idx, start, first;

    if (NULL == rb || NULL == ref)
        return -1;

    w = atomic_load_explicit(&rb->write_pos, memory_order_acquire);
    p = rb->parse_pos;

    if (w - p < 2)
        return 1;

    idx = p & rb->mask;
    bytes[0] = rb->data[idx];
    bytes[1] = rb->data[(idx + 1) & rb->mask];
    memcpy(&be_len, bytes, sizeof(be_len));
    len = ntohs(be_len);

    if (0 == len || len > BOND_TUN_MTU)
        return -1;

    if (w - p < 2 + len)
        return 1;

    start = (p + 2) & rb->mask;
    first = rb->capacity - start;
    if (first > len)
        first = len;

    ref->chunk[0] = rb->data + start;
    ref->chunk_len[0] = (uint16_t)first;
    if (first < len) {
        ref->chunk[1] = rb->data;
        ref->chunk_len[1] = (uint16_t)(len - first);
    } else {
        ref->chunk[1] = NULL;
        ref->chunk_len[1] = 0;
    }
    ref->len = (uint16_t)len;
    ref->generation = atomic_load_explicit(&rb->generation, memory_order_acquire);

    rb->parse_pos = p + 2 + len;

    return 0;
}

void bond_ring_consume(bond_ring_t *rb, const bond_frame_ref_t *ref)
{
    uint32_t generation;

    if (NULL == rb || NULL == ref)
        return;

    generation = atomic_load_explicit(&rb->generation, memory_order_acquire);
    if (ref->generation != generation)
        return;

    atomic_fetch_add_explicit(&rb->read_pos, (uint32_t)ref->len + 2, memory_order_release);
}
