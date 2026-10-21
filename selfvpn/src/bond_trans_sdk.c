/*================================================================
*
*   文件名称：bond_trans_sdk.c
*   描    述：bond_transmission_new 公共 API 门面
*
================================================================*/

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "bond_runtime.h"
#include "bond_server.h"
#include "bond_session.h"
#include "bond_trans_tool.h"
#include "traffic_statistics.h"
#include "version.h"

#define BOND_DEFAULT_RING_MB  5
#define BOND_MAX_RING_BYTES   (40u << 20)       // 40MB

static bond_runtime_t *g_runtime = NULL;

int trans_init(bond_comm_param_t *param)
{
    runtime_cfg_t cfg;

    ENTER_FUNC_PTINT;
    bt_log_info(LOG_ALL_OUT, "lib bond version: %s\n", bond_transmission_new_version_string);

    if (NULL == param) {
        bt_log_error(LOG_ALL_OUT, "param is NULL\n");
        return -1;
    }

    if (BOND_MODE_CLIENT != param->mode && BOND_MODE_SERVER != param->mode) {
        bt_log_error(LOG_ALL_OUT, "invalid mode:%d\n", param->mode);
        return -1;
    }

    if (param->buffer_size < 0) {
        bt_log_error(LOG_ALL_OUT, "invalid buffer_size:%d\n", param->buffer_size);
        return -1;
    }

    if (NULL != g_runtime) {
        bt_log_error(LOG_ALL_OUT, "bond handle is not null!!!\n");
        return -1;
    }

    memset(&cfg, 0, sizeof(cfg));
    cfg.mode = param->mode;
    cfg.buffer_size_mb = (uint32_t)param->buffer_size;

    snprintf(cfg.tun_name, sizeof(cfg.tun_name), "%s", param->tun_name);
    snprintf(cfg.tun_local_ip, sizeof(cfg.tun_local_ip), "%s", param->tun_local_ip);
    snprintf(cfg.tun_netmask, sizeof(cfg.tun_netmask), "%s", param->tun_netmask);
    snprintf(cfg.tun_pool_start, sizeof(cfg.tun_pool_start), "%s", param->tun_pool_start);
    snprintf(cfg.tun_pool_end, sizeof(cfg.tun_pool_end), "%s", param->tun_pool_end);
    cfg.tun_mtu = param->tun_mtu;

    if (BOND_MODE_SERVER == param->mode) {
        if ('\0' == cfg.tun_local_ip[0] || '\0' == cfg.tun_netmask[0] ||
            '\0' == cfg.tun_pool_start[0] || '\0' == cfg.tun_pool_end[0]) {
            bt_log_error(LOG_ALL_OUT, "server mode requires tun_local_ip/netmask/pool!\n");
            return -1;
        }
    }

    g_runtime = bond_runtime_create(&cfg);
    if (NULL == g_runtime) {
        bt_log_error(LOG_ALL_OUT, "bond runtime create failed!\n");
        return -1;
    }

    EXIT_FUNC_PRINT;
    return 0;
}

int trans_uninit(void)
{
    ENTER_FUNC_PTINT;

    if (NULL == g_runtime) {
        bt_log_error(LOG_ALL_OUT, "bond handle is null! can not uninit...\n");
        return -1;
    }

    bond_runtime_destroy(g_runtime);
    g_runtime = NULL;

    EXIT_FUNC_PRINT;
    return 0;
}

static uint32_t bond_ring_capacity_from_param(const bond_trans_param_t *param)
{
    uint64_t ring_bytes;

    ring_bytes = (uint64_t)((0 == param->ringbuffer_capacity) ? BOND_DEFAULT_RING_MB
                                                              : param->ringbuffer_capacity) * 1024ULL * 1024ULL;
    if (ring_bytes > BOND_MAX_RING_BYTES)
        ring_bytes = BOND_MAX_RING_BYTES;

    return (uint32_t)ring_bytes;
}

static int bond_validate_forward_param(const bond_trans_param_t *param)
{
    if (NULL == param)
        return -1;

    if (param->ringbuffer_capacity < 0 || param->ringbuffer_total_capacity < 0 ||
        param->socket_send_buffer < 0 || param->socket_recv_buffer < 0 ||
        param->queue_capacity < 0 ||
        param->server_port <= 0 || param->server_port > 65535) {
        bt_log_error(LOG_ALL_OUT, "invalid params! ring:%d total:%d snd:%d rcv:%d queue:%d port:%d\n",
                     param->ringbuffer_capacity, param->ringbuffer_total_capacity,
                     param->socket_send_buffer, param->socket_recv_buffer,
                     param->queue_capacity, param->server_port);
        return -1;
    }

    if (BOND_MODE_CLIENT == g_runtime->cfg.mode && '\0' == param->server_ip[0]) {
        bt_log_error(LOG_ALL_OUT, "client server_ip is empty!\n");
        return -1;
    }

    return 0;
}

int trans_add_forward(bond_trans_param_t *param)
{
    const char *secret;
    uint32_t ring_capacity;

    if (NULL == g_runtime || NULL == param) {
        bt_log_error(LOG_ALL_OUT, "bond runtime not initialized! param:%p\n", param);
        return -1;
    }

    if (0 != bond_validate_forward_param(param))
        return -1;

    secret = ('\0' == param->authentication[0]) ? "bond_test_demo" : param->authentication;
    ring_capacity = bond_ring_capacity_from_param(param);

    /* 总预算按配置折算; 单会话实际容量由 runtime 结合会话数再收敛 */
    {
        uint64_t total = (uint64_t)param->ringbuffer_total_capacity * 1024ULL * 1024ULL;

        if (total > 0xFFFFFFFFULL)
            total = 0xFFFFFFFFULL;
        bond_runtime_set_ring_limit(g_runtime, (uint32_t)total);
    }

    bond_runtime_set_socket_buffer(g_runtime,
                                   param->socket_send_buffer * 1024,
                                   param->socket_recv_buffer * 1024);

    if (BOND_MODE_SERVER == g_runtime->cfg.mode) {
        const char *bind_ip = ('\0' == param->server_bind_ip[0]) ? "0.0.0.0" : param->server_bind_ip;

        bt_log_info(LOG_ALL_OUT, "start server endpoint %s:%d ring:%u MB\n",
                    bind_ip, param->server_port, ring_capacity / 1024 / 1024);
        return bond_server_start(g_runtime, bind_ip, (uint16_t)param->server_port, secret,
                                 ring_capacity, (uint32_t)param->queue_capacity);
    }

    bond_session_cfg_t cfg;
    memset(&cfg, 0, sizeof(cfg));
    snprintf(cfg.sn, sizeof(cfg.sn), "%s", param->sn);
    snprintf(cfg.secret, sizeof(cfg.secret), "%s", secret);

    /* client 的 tun 地址由服务端在握手响应中下发, 本地不再配置 */
    cfg.tun_local_ip = 0;
    cfg.tun_peer_ip = 0;
    cfg.ring_capacity = ring_capacity;
    cfg.queue_capacity = (uint32_t)param->queue_capacity;
    snprintf(cfg.client.server_ip, sizeof(cfg.client.server_ip), "%s", param->server_ip);
    cfg.client.server_port = (uint16_t)param->server_port;

    bt_log_info(LOG_ALL_OUT, "add client forward sn:%s server:%s:%d ring:%u MB\n",
                cfg.sn, cfg.client.server_ip, cfg.client.server_port,
                cfg.ring_capacity / 1024 / 1024);

    return bond_runtime_add_session(g_runtime, &cfg);
}

int trans_remove_forward(bond_trans_param_t *param)
{
    if (NULL == g_runtime || NULL == param) {
        bt_log_error(LOG_ALL_OUT, "bond runtime not initialized! param:%p\n", param);
        return -1;
    }

    if (BOND_MODE_SERVER == g_runtime->cfg.mode) {
        bt_log_info(LOG_ALL_OUT, "stop server endpoint\n");
        bond_server_stop(g_runtime);
        return 0;
    }

    bt_log_info(LOG_ALL_OUT, "remove client forward sn:%s\n", param->sn);
    return bond_runtime_remove_client_session(g_runtime);
}

int bond_trans_get_device_list(bond_device_stat_t *list, int max_count)
{
    return traffic_get_all(list, max_count);
}

int bond_trans_get_device_stat(const char *sn, bond_device_stat_t *out)
{
    bond_stat_slot_t *slot = NULL;

    if (NULL == sn || NULL == out)
        return -1;

    slot = traffic_find_by_sn(sn);
    if (NULL == slot)
        return -1;

    traffic_snapshot(slot, out);

    return 0;
}

int bond_trans_get_online_count(void)
{
    return traffic_online_count();
}
