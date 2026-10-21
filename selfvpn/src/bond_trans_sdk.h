

#ifndef __BOND_TRANS_SDK_H__
#define __BOND_TRANS_SDK_H__

#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>


#define IP_ADDR_LEN 20
#define AUTHENTICATE_INFO_LEN 100
#define BOND_TUN_NAME_LEN 16

enum BOND_WORKING_MODE
{
	BOND_MODE_CLIENT,
	BOND_MODE_SERVER,
};

typedef struct bond_comm_param_tag
{
	int buffer_size;	// mempry pool capacity, MB

	enum BOND_WORKING_MODE mode;

	/* TUN 设备由库创建和配置 */
	char tun_name[BOND_TUN_NAME_LEN];		// 为空时由内核分配, 例如 tun0
	char tun_local_ip[IP_ADDR_LEN];			// server: 本端 tun ip
	char tun_netmask[IP_ADDR_LEN];			// server: 地址池所在网段掩码
	int  tun_mtu;							// 0 时使用 1500
	char tun_pool_start[IP_ADDR_LEN];		// server: 分配给客户端的起始 ip
	char tun_pool_end[IP_ADDR_LEN];			// server: 分配给客户端的结束 ip

}bond_comm_param_t;

typedef struct bond_trans_param_tag
{
	char sn[AUTHENTICATE_INFO_LEN];

	char authentication[AUTHENTICATE_INFO_LEN];
	char server_ip[IP_ADDR_LEN]; 					//only client mode use
	int server_port;
	char server_bind_ip[IP_ADDR_LEN]; 				// server: listen bind ip, empty/0.0.0.0 means ANY

	int queue_capacity;								// 数据包转发队列大小
	int ringbuffer_capacity;						// 每会话读 socket 的环形缓冲区大小, MB
	int ringbuffer_total_capacity;					// 所有会话 ring 的总预算, MB; 0 表示默认值
	int socket_send_buffer;							// 每连接发送缓冲区, KB; 0 表示内核自动调优
	int socket_recv_buffer;							// 每连接接收缓冲区, KB; 0 表示内核自动调优

}bond_trans_param_t;

/* 单台设备的流量统计快照 */
typedef struct bond_device_stat_tag
{
	char sn[AUTHENTICATE_INFO_LEN];		// 序列号
	char tun_peer_ip[IP_ADDR_LEN];		// 隧道对端ip
	int index;							// 客户端索引
	int online;							// 是否在线
	uint64_t rx_bytes;					// 上行累计字节数(设备->服务器)
	uint64_t tx_bytes;					// 下行累计字节数(服务器->设备)

}bond_device_stat_t;

int trans_init(bond_comm_param_t *param);
int trans_uninit();

int trans_add_forward(bond_trans_param_t *param);
int trans_remove_forward(bond_trans_param_t *param);

/* 取所有已注册设备(含已离线)的流量快照, 返回实际写入的条数(最多max_count条) */
int bond_trans_get_device_list(bond_device_stat_t *list, int max_count);

/* 按序列号取单台设备的流量快照, 返回0成功, -1未找到 */
int bond_trans_get_device_stat(const char *sn, bond_device_stat_t *out);

/* 取当前在线设备数 */
int bond_trans_get_online_count(void);

#ifdef __cplusplus
}
#endif

#endif // __BOND_TRANS_SDK_H__



