#include <arpa/inet.h>
#include <ctype.h>
#include <errno.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>

#include "config.h"

#define CFG_MODE_ANY (-1)
#define ARRAY_SIZE(a) (sizeof(a) / sizeof((a)[0]))

/* 配置文件中所有参数集中解析到该结构, 校验通过后再统一导出 */
typedef struct sample_config_tag {
	char tun_name[BOND_TUN_NAME_LEN];
	int  mtu;
	int  log_level;
	int  buffer_size;
	int  queue_capacity;
	int  ring_capacity;
	int  ring_total_capacity;
	int  socket_send_buffer;
	int  socket_recv_buffer;
	char sn[AUTHENTICATE_INFO_LEN];
	char authentication[AUTHENTICATE_INFO_LEN];
	char server_ip[IP_ADDR_LEN];
	int  server_port;
	char server_bind_ip[IP_ADDR_LEN];
	char pool_net[IP_ADDR_LEN];
	char pool_mask[IP_ADDR_LEN];
	char log_file[512];
	int  log_size;
} sample_config_t;

typedef enum config_value_type_tag {
	CFG_STRING,
	CFG_INT,
	CFG_LOG_LEVEL,
} config_value_type_t;

typedef struct config_item_tag {
	const char *key;
	size_t offset;
	size_t size;
	config_value_type_t type;
	int mode; /* CFG_MODE_ANY 表示两种模式都生效 */
} config_item_t;

#define CFG_ITEM_STR(k, m, f) \
	{ (k), offsetof(sample_config_t, f), sizeof(((sample_config_t *)0)->f), CFG_STRING, (m) }
#define CFG_ITEM_INT(k, m, f) \
	{ (k), offsetof(sample_config_t, f), sizeof(int), CFG_INT, (m) }
#define CFG_ITEM_LOG_LEVEL(k, m, f) \
	{ (k), offsetof(sample_config_t, f), sizeof(int), CFG_LOG_LEVEL, (m) }

static const config_item_t g_config_items[] = {
	CFG_ITEM_STR("interface",       CFG_MODE_ANY,       tun_name),
	CFG_ITEM_INT("mtu",             CFG_MODE_ANY,       mtu),
	CFG_ITEM_LOG_LEVEL("logLevel",  CFG_MODE_ANY,       log_level),
	CFG_ITEM_INT("bufferCapacity",  CFG_MODE_ANY,       buffer_size),
	CFG_ITEM_INT("queueCapacity",   CFG_MODE_ANY,       queue_capacity),
	CFG_ITEM_INT("ringCapacity",    CFG_MODE_ANY,       ring_capacity),
	CFG_ITEM_INT("ringTotalCapacity", CFG_MODE_ANY,     ring_total_capacity),
	CFG_ITEM_INT("socketSendBuffer", CFG_MODE_ANY,      socket_send_buffer),
	CFG_ITEM_INT("socketRecvBuffer", CFG_MODE_ANY,      socket_recv_buffer),
	CFG_ITEM_STR("logFile",         CFG_MODE_ANY,       log_file),
	CFG_ITEM_INT("logSize",         CFG_MODE_ANY,       log_size),
	CFG_ITEM_STR("authentication",  CFG_MODE_ANY,       authentication),
	CFG_ITEM_STR("sn",              BOND_MODE_CLIENT,   sn),
	CFG_ITEM_STR("remoteAddr",      BOND_MODE_CLIENT,   server_ip),
	CFG_ITEM_INT("remotePort",      BOND_MODE_CLIENT,   server_port),
	CFG_ITEM_STR("localAddr",       BOND_MODE_SERVER,   server_bind_ip),
	CFG_ITEM_INT("localPort",       BOND_MODE_SERVER,   server_port),
	CFG_ITEM_STR("ipPoolNet",       BOND_MODE_SERVER,   pool_net),
	CFG_ITEM_STR("ipPoolMask",      BOND_MODE_SERVER,   pool_mask),
};

static char *trim_whitespace(char *str)
{
	while ('\0' != *str && isspace((unsigned char)*str))
		str++;

	char *end = str + strlen(str);
	while (end > str && isspace((unsigned char)end[-1]))
		*--end = '\0';

	return str;
}

static void strip_quotes(char *str)
{
	size_t len = strlen(str);

	if (len >= 2 &&
		((str[0] == '\'' && str[len - 1] == '\'') ||
		 (str[0] == '"' && str[len - 1] == '"'))) {
		memmove(str, str + 1, len - 2);
		str[len - 2] = '\0';
	}
}

static int parse_log_level(const char *value)
{
	if (0 == strcasecmp(value, "debug"))
		return LOG_LEVEL_DEBUG;
	if (0 == strcasecmp(value, "info"))
		return LOG_LEVEL_INFO;
	if (0 == strcasecmp(value, "warn") || 0 == strcasecmp(value, "warning"))
		return LOG_LEVEL_WARNING;
	if (0 == strcasecmp(value, "error"))
		return LOG_LEVEL_ERROR;

	return atoi(value);
}

static const config_item_t *config_find(const char *key)
{
	for (size_t i = 0; i < ARRAY_SIZE(g_config_items); i++) {
		if (0 == strcmp(g_config_items[i].key, key))
			return &g_config_items[i];
	}

	return NULL;
}

static void config_apply(sample_config_t *cfg, const config_item_t *item,
                         const char *value)
{
	char *field = (char *)cfg + item->offset;

	switch (item->type) {
	case CFG_STRING:
		snprintf(field, item->size, "%s", value);
		break;
	case CFG_INT:
		*(int *)field = atoi(value);
		break;
	case CFG_LOG_LEVEL:
		*(int *)field = parse_log_level(value);
		break;
	default:
		break;
	}
}

static void config_ip_format(uint32_t ip, char *buf, size_t size)
{
	struct in_addr addr;

	addr.s_addr = htonl(ip);
	inet_ntop(AF_INET, &addr, buf, size);
}

/* 由 ipPoolNet/ipPoolMask 推导: 服务端取首个可用地址, 其余地址依次分配给客户端 */
static int config_server_pool(const sample_config_t *cfg, bond_comm_param_t *comm_param)
{
	struct in_addr net;
	struct in_addr mask;
	uint32_t netmask;
	uint32_t network;
	uint32_t broadcast;

	if ('\0' == cfg->pool_net[0] || '\0' == cfg->pool_mask[0]) {
		fprintf(stderr, "server config requires ipPoolNet and ipPoolMask\n");
		return -1;
	}

	if (1 != inet_pton(AF_INET, cfg->pool_net, &net) ||
	    1 != inet_pton(AF_INET, cfg->pool_mask, &mask)) {
		fprintf(stderr, "invalid ipPoolNet/ipPoolMask: %s %s\n",
		        cfg->pool_net, cfg->pool_mask);
		return -1;
	}

	netmask = ntohl(mask.s_addr);
	network = ntohl(net.s_addr) & netmask;
	broadcast = network | ~netmask;

	/* 至少需要 2 个可用地址: 服务端 1 个 + 客户端 1 个 */
	if (0 == netmask || broadcast <= network + 1) {
		fprintf(stderr, "ip pool too small: %s %s\n", cfg->pool_net, cfg->pool_mask);
		return -1;
	}

	snprintf(comm_param->tun_netmask, sizeof(comm_param->tun_netmask), "%s", cfg->pool_mask);
	config_ip_format(network + 1, comm_param->tun_local_ip, sizeof(comm_param->tun_local_ip));
	config_ip_format(network + 2, comm_param->tun_pool_start, sizeof(comm_param->tun_pool_start));
	config_ip_format(broadcast - 1, comm_param->tun_pool_end, sizeof(comm_param->tun_pool_end));

	return 0;
}

static int config_export(const sample_config_t *cfg,
                         bond_comm_param_t *comm_param,
                         bond_trans_param_t *param,
                         int *log_level,
                         char *log_file, size_t log_file_size,
                         int *log_size_mb)
{
	snprintf(comm_param->tun_name, sizeof(comm_param->tun_name), "%s",
	         ('\0' == cfg->tun_name[0]) ? "tun0" : cfg->tun_name);
	comm_param->buffer_size = cfg->buffer_size;
	comm_param->tun_mtu = cfg->mtu;
	param->queue_capacity = cfg->queue_capacity;
	param->ringbuffer_capacity = cfg->ring_capacity;
	param->ringbuffer_total_capacity = cfg->ring_total_capacity;
	param->socket_send_buffer = cfg->socket_send_buffer;
	param->socket_recv_buffer = cfg->socket_recv_buffer;
	param->server_port = cfg->server_port;
	snprintf(param->authentication, sizeof(param->authentication), "%s", cfg->authentication);
	*log_level = cfg->log_level;

	if (NULL != log_file && log_file_size > 0)
		snprintf(log_file, log_file_size, "%s", cfg->log_file);
	if (NULL != log_size_mb)
		*log_size_mb = cfg->log_size;

	if (BOND_MODE_CLIENT == comm_param->mode) {
		snprintf(param->sn, sizeof(param->sn), "%s", cfg->sn);
		snprintf(param->server_ip, sizeof(param->server_ip), "%s", cfg->server_ip);
		return 0;
	}

	snprintf(param->server_bind_ip, sizeof(param->server_bind_ip), "%s", cfg->server_bind_ip);

	return config_server_pool(cfg, comm_param);
}

int config_load(const char *path, bond_comm_param_t *comm_param,
                bond_trans_param_t *param, int *log_level,
                char *log_file, size_t log_file_size, int *log_size_mb)
{
	FILE *fp = fopen(path, "r");
	if (NULL == fp) {
		fprintf(stderr, "open config %s failed: %s\n", path, strerror(errno));
		return -1;
	}

	sample_config_t cfg = {
		.mtu = 1500,
		.log_level = *log_level,
		.server_ip = "0.0.0.0",
		.server_bind_ip = "0.0.0.0",
		.log_file = "/var/log/selfvpn.log",
		.log_size = 1,
	};

	char line[512];
	int line_no = 0;

	while (NULL != fgets(line, sizeof(line), fp)) {
		line_no++;

		char *p = trim_whitespace(line);
		if ('\0' == *p || '#' == *p || ';' == *p)
			continue;

		char *eq = strchr(p, '=');
		if (NULL == eq) {
			fprintf(stderr, "%s:%d invalid config line: %s\n", path, line_no, p);
			continue;
		}

		*eq = '\0';
		char *key = trim_whitespace(p);
		char *value = trim_whitespace(eq + 1);
		strip_quotes(value);

		const config_item_t *item = config_find(key);
		if (NULL == item) {
			fprintf(stderr, "%s:%d unknown config key: %s\n", path, line_no, key);
			continue;
		}

		if (CFG_MODE_ANY != item->mode && (int)comm_param->mode != item->mode)
			continue;

		config_apply(&cfg, item, value);
	}

	fclose(fp);

	if (0 != config_export(&cfg, comm_param, param, log_level,
	                       log_file, log_file_size, log_size_mb))
		return -1;

	if (BOND_MODE_CLIENT == comm_param->mode &&
		('\0' == param->server_ip[0] || 0 == strcmp(param->server_ip, "0.0.0.0"))) {
		fprintf(stderr, "client config requires remoteAddr\n");
		return -1;
	}

	if (BOND_MODE_CLIENT == comm_param->mode && '\0' == param->sn[0]) {
		fprintf(stderr, "client config requires sn\n");
		return -1;
	}

	if (param->server_port <= 0 || param->server_port > 65535) {
		fprintf(stderr, "invalid server port in config: %d\n", param->server_port);
		return -1;
	}

	return 0;
}
