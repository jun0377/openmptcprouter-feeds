#include <errno.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/uio.h>

#include "channel.h"
#include "bond_trans_tool.h"
#include "core.h"

#define CHANNEL_IOV_MAX       40
#define CHANNEL_RECV_BUDGET   32
#define CHANNEL_READ_MAX      (64 * 1024)
#define CHANNEL_TUN_BATCH     64

struct bond_channel {
    bond_ring_t      *socket_rb;    /* socket -> tun 的字节缓冲 */
    bond_ptr_queue_t *to_socket_q;  /* bond_frame_t*: tun -> socket */
    bond_ptr_queue_t *to_tun_q;     /* bond_frame_ref_t*: socket -> tun */

    bond_pool_t      *frame_pool;   /* bond_frame_t */
    bond_pool_t      *ref_pool;     /* bond_frame_ref_t */

    bond_tun_write_fn tun_write;    /* 由 runtime 提供，负责排队/背压 */
    void             *tun_ctx;
    atomic_bool       tun_blocked;  /* 上次写 TUN 因队列满失败 */

    /* 部分发送进度 */
    bond_frame_t     *tx_frames[CHANNEL_IOV_MAX];
    struct iovec      tx_iov[CHANNEL_IOV_MAX];
    int               tx_count;
    int               tx_first;
};

static void bond_release_frame(bond_list_node_t *node, void *ctx)
{
    bond_pool_put((bond_pool_t *)ctx, node);
}

static void bond_release_ref(bond_list_node_t *node, void *ctx)
{
    bond_pool_put((bond_pool_t *)ctx, node);
}

bond_channel_t *bond_channel_create(uint32_t ring_capacity,
                                    bond_pool_t *frame_pool,
                                    bond_pool_t *ref_pool,
                                    bond_tun_write_fn tun_write,
                                    void *tun_ctx)
{
    bond_channel_t *ch;

    if (NULL == frame_pool || NULL == ref_pool || NULL == tun_write)
        return NULL;

    ch = calloc(1, sizeof(*ch));
    if (NULL == ch)
        return NULL;

    ch->frame_pool = frame_pool;
    ch->ref_pool = ref_pool;
    ch->tun_write = tun_write;
    ch->tun_ctx = tun_ctx;
    ch->socket_rb = bond_ring_create(ring_capacity);
    ch->to_socket_q = bond_queue_create();
    ch->to_tun_q = bond_queue_create();
    if (NULL == ch->socket_rb || NULL == ch->to_socket_q || NULL == ch->to_tun_q) {
        bond_channel_destroy(ch);
        return NULL;
    }

    return ch;
}

void bond_channel_reset(bond_channel_t *ch)
{
    if (NULL == ch)
        return;

    for (int i = 0; i < ch->tx_count; i++) {
        ch->tx_frames[i]->len = 0;
        bond_pool_put(ch->frame_pool, ch->tx_frames[i]);
    }
    ch->tx_count = 0;
    ch->tx_first = 0;

    atomic_store_explicit(&ch->tun_blocked, false, memory_order_relaxed);

    bond_queue_drain(ch->to_socket_q, bond_release_frame, ch->frame_pool);
    bond_queue_drain(ch->to_tun_q, bond_release_ref, ch->ref_pool);
    bond_ring_reset(ch->socket_rb);
}

void bond_channel_destroy(bond_channel_t *ch)
{
    if (NULL == ch)
        return;

    if (NULL != ch->to_socket_q)
        bond_queue_destroy(ch->to_socket_q, bond_release_frame, ch->frame_pool);
    if (NULL != ch->to_tun_q)
        bond_queue_destroy(ch->to_tun_q, bond_release_ref, ch->ref_pool);
    if (NULL != ch->socket_rb)
        bond_ring_destroy(ch->socket_rb);

    free(ch);
}

static int bond_channel_parse_ring(bond_channel_t *ch, bond_frame_ref_t *ref)
{
    int ret;

    ret = bond_ring_peek_frame(ch->socket_rb, ref);
    if (0 != ret)
        return ret;

    if (0 != bond_queue_push(ch->to_tun_q, &ref->node))
        return -1;

    return 0;
}

/* 把 ring 中已完整的帧解析到 to_tun_q */
static int bond_channel_drain_ring(bond_channel_t *ch)
{
    for (;;) {
        bond_frame_ref_t *ref = bond_pool_get(ch->ref_pool, 0);
        int ret;

        if (NULL == ref)
            return 0;

        ret = bond_channel_parse_ring(ch, ref);
        if (0 != ret) {
            bond_pool_put(ch->ref_pool, ref);
            return (ret < 0) ? -1 : 0;
        }
    }
}

static int bond_channel_tun_write(bond_channel_t *ch, uint32_t budget)
{
    atomic_store_explicit(&ch->tun_blocked, false, memory_order_relaxed);

    for (uint32_t i = 0; i < budget; i++) {
        bond_list_node_t *node = bond_queue_peek(ch->to_tun_q);
        bond_frame_ref_t *ref;
        struct iovec iov[2];
        int iovcnt = 1;
        int ret;

        if (NULL == node)
            break;

        ref = (bond_frame_ref_t *)node;

        if (ref->generation != bond_ring_generation(ch->socket_rb)) {
            (void)bond_queue_pop(ch->to_tun_q, 0);
            bond_pool_put(ch->ref_pool, ref);
            continue;
        }

        iov[0].iov_base = (void *)ref->chunk[0];
        iov[0].iov_len = ref->chunk_len[0];
        if (NULL != ref->chunk[1]) {
            iov[1].iov_base = (void *)ref->chunk[1];
            iov[1].iov_len = ref->chunk_len[1];
            iovcnt = 2;
        }

        ret = ch->tun_write(ch->tun_ctx, iov, iovcnt);
        if (0 != ret) {
            /*
             * TUN 侧队列满: 不消费 ring 槽位, 帧留在队首等下次重试。
             * ring 涨满后会自然反压 socket 读取, 不丢包。
             */
            atomic_store_explicit(&ch->tun_blocked, true, memory_order_relaxed);
            bt_log_debug(LOG_ALL_OUT, "tun output full, backpressure len:%u\n",
                         ref->len);
            return -1;
        }

        (void)bond_queue_pop(ch->to_tun_q, 0);
        bond_ring_consume(ch->socket_rb, ref);
        bond_pool_put(ch->ref_pool, ref);
    }

    return 0;
}

int bond_channel_recv(bond_channel_t *ch, int sock_fd, uint64_t *rx_bytes)
{
    if (NULL == ch || sock_fd < 0)
        return -1;

    if (0 != bond_channel_drain_ring(ch))
        return -1;
    (void)bond_channel_tun_write(ch, CHANNEL_TUN_BATCH);

    /* TUN 队列满: 暂停读 socket, 由 ring 与内核接收缓冲形成背压 */
    if (bond_channel_tun_blocked(ch))
        return 0;

    for (uint32_t i = 0; i < CHANNEL_RECV_BUDGET; i++) {
        uint32_t contig = 0;
        uint8_t *ptr = bond_ring_reserve(ch->socket_rb, &contig);
        ssize_t n;

        if (NULL == ptr)
            break;

        if (contig > CHANNEL_READ_MAX)
            contig = CHANNEL_READ_MAX;

        n = core_socket_recv(sock_fd, ptr, contig);
        if (n > 0) {
            bond_ring_commit(ch->socket_rb, (uint32_t)n);
            if (NULL != rx_bytes)
                *rx_bytes += (uint64_t)n;

            if (0 != bond_channel_drain_ring(ch))
                return -1;

            (void)bond_channel_tun_write(ch, CHANNEL_TUN_BATCH);
            if (bond_channel_tun_blocked(ch))
                break;
            continue;
        }
        if (0 == n)
            return -1;
        if (EAGAIN == errno || EWOULDBLOCK == errno)
            break;

        return -1;
    }

    return 0;
}

int bond_channel_send(bond_channel_t *ch, int sock_fd, uint64_t *tx_bytes)
{
    if (NULL == ch || sock_fd < 0)
        return -1;

    if (0 == ch->tx_count) {
        bond_list_node_t *node = bond_queue_pop(ch->to_socket_q, 0);
        int i;

        if (NULL == node)
            return 0;

        ch->tx_frames[0] = (bond_frame_t *)node;
        ch->tx_count = 1;
        while (ch->tx_count < CHANNEL_IOV_MAX) {
            node = bond_queue_pop(ch->to_socket_q, 0);
            if (NULL == node)
                break;
            ch->tx_frames[ch->tx_count++] = (bond_frame_t *)node;
        }

        for (i = 0; i < ch->tx_count; i++) {
            ch->tx_iov[i].iov_base = ch->tx_frames[i]->data;
            ch->tx_iov[i].iov_len = ch->tx_frames[i]->len;
        }
        ch->tx_first = 0;
    }

    while (ch->tx_first < ch->tx_count) {
        ssize_t n;

        n = core_socket_sendmsg(sock_fd, &ch->tx_iov[ch->tx_first],
                                ch->tx_count - ch->tx_first);
        if (n < 0) {
            if (EAGAIN == errno || EWOULDBLOCK == errno)
                return 0;
            return -1;
        }
        if (0 == n)
            return -1;

        if (NULL != tx_bytes)
            *tx_bytes += (uint64_t)n;

        size_t off = (size_t)n;
        while (off > 0 && ch->tx_first < ch->tx_count) {
            struct iovec *cur = &ch->tx_iov[ch->tx_first];

            if (off >= cur->iov_len) {
                off -= cur->iov_len;
                ch->tx_first++;
            } else {
                cur->iov_base = (char *)cur->iov_base + off;
                cur->iov_len -= off;
                off = 0;
            }
        }
    }

    for (int i = 0; i < ch->tx_count; i++) {
        ch->tx_frames[i]->len = 0;
        bond_pool_put(ch->frame_pool, ch->tx_frames[i]);
    }
    ch->tx_count = 0;
    ch->tx_first = 0;

    return 0;
}

int bond_channel_enqueue(bond_channel_t *ch, bond_frame_t *frame)
{
    if (NULL == ch || NULL == frame)
        return -1;

    return bond_queue_push(ch->to_socket_q, &frame->node);
}

bool bond_channel_tx_pending(const bond_channel_t *ch)
{
    return (NULL != ch && 0 != ch->tx_count);
}

bool bond_channel_has_queued(const bond_channel_t *ch)
{
    return (NULL != ch && bond_queue_size(ch->to_socket_q) > 0);
}

bool bond_channel_tun_pending(const bond_channel_t *ch)
{
    return (NULL != ch && bond_queue_size(ch->to_tun_q) > 0);
}

bool bond_channel_tun_blocked(const bond_channel_t *ch)
{
    return (NULL != ch &&
            atomic_load_explicit(&ch->tun_blocked, memory_order_relaxed));
}
