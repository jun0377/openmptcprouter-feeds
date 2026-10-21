#ifndef BOND_TYPES_H
#define BOND_TYPES_H

#include <stdint.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdatomic.h>
#include <pthread.h>

#include "bond_trans_sdk.h"

#define BOND_IP_STR_LEN       IP_ADDR_LEN
#define BOND_AUTH_LEN         AUTHENTICATE_INFO_LEN
#define BOND_TUN_MTU          1500
#define BOND_FRAME_MAX        (BOND_TUN_MTU + 2)   /* 2B 长度前缀 */
#define BOND_INVALID_FD       (-1)

typedef enum BOND_WORKING_MODE bond_mode_t;

typedef struct bond_runtime bond_runtime_t;
typedef struct bond_session bond_session_t;

typedef enum {
    BOND_SESSION_INIT = 0,
    BOND_SESSION_CONNECTING,
    BOND_SESSION_AUTHENTICATING,
    BOND_SESSION_ONLINE,
    BOND_SESSION_STOPPING,
    BOND_SESSION_STOPPED,
} bond_session_state_t;

typedef struct bond_client_cfg {
    char     server_ip[BOND_IP_STR_LEN];
    uint16_t server_port;
} bond_client_cfg_t;

typedef struct bond_session_cfg {
    uint32_t           id;
    char               sn[BOND_AUTH_LEN];
    char               secret[BOND_AUTH_LEN];

    uint32_t           tun_local_ip;
    uint32_t           tun_peer_ip;

    uint32_t           queue_capacity;  /* 帧数量上限提示, 实际由全局内存池约束 */
    uint32_t           ring_capacity;   /* 字节数 */

    bond_client_cfg_t  client;          /* 仅 client 模式有效 */
} bond_session_cfg_t;

#endif /* BOND_TYPES_H */
