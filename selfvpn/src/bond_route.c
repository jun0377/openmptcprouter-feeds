#include <arpa/inet.h>
#include <errno.h>
#include <pthread.h>
#include <stdbool.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h>
#include <sys/wait.h>
#include <unistd.h>

#include "bond_route.h"
#include "bond_trans_tool.h"
#include "bond_types.h"
#include "bond_util.h"

/* 与 OMR 约定保持一致: omrvpn 固定使用 1500 号策略路由表 */
#define BOND_ROUTE_TABLE     "1500"
#define BOND_ROUTE_IP_LEN    20

static pthread_mutex_t bond_route_lock = PTHREAD_MUTEX_INITIALIZER;
static bool server_route_added;
static char route_tun[BOND_TUN_NAME_LEN];
static char route_local[BOND_ROUTE_IP_LEN];
static char route_peer[BOND_ROUTE_IP_LEN];
static char route_server[BOND_ROUTE_IP_LEN];

/* 直接调用 iproute2, 不引入额外依赖 */
static int bond_route_exec(const char *const *args)
{
    pid_t pid;
    int status;

    pid = fork();
    if (pid < 0)
        return -1;

    if (0 == pid) {
        static const char *paths[] = {
            "/sbin/ip", "/usr/sbin/ip", "/bin/ip", "/usr/bin/ip",
        };
        size_t i;

        for (i = 0; i < sizeof(paths) / sizeof(paths[0]); i++)
            execv(paths[i], (char *const *)args);
        execvp("ip", (char *const *)args);
        _exit(127);
    }

    while (waitpid(pid, &status, 0) < 0) {
        if (EINTR != errno)
            return -1;
    }

    return (WIFEXITED(status) && 0 == WEXITSTATUS(status)) ? 0 : -1;
}

/* 主表是否已存在该主机的 /32 路由(存在则说明 OMR 已经固定过外出路径) */
static bool bond_route_has_host(const char *ip)
{
    char cmd[128];
    char line[256];
    FILE *fp;
    bool found = false;

    snprintf(cmd, sizeof(cmd), "ip -4 route show %s/32 2>/dev/null", ip);
    fp = popen(cmd, "r");
    if (NULL == fp)
        return false;

    if (NULL != fgets(line, sizeof(line), fp) && '\0' != line[0])
        found = true;

    pclose(fp);
    return found;
}

/* 从当前路由中解析服务器地址的下一跳, 用于固定 /32 直连路由 */
static int bond_route_get_nexthop(const char *ip, char *via, char *dev)
{
    char cmd[128];
    char line[256];
    char *p;
    FILE *fp;

    via[0] = '\0';
    dev[0] = '\0';

    snprintf(cmd, sizeof(cmd), "ip -4 route get %s 2>/dev/null", ip);
    fp = popen(cmd, "r");
    if (NULL == fp)
        return -1;

    if (NULL == fgets(line, sizeof(line), fp)) {
        pclose(fp);
        return -1;
    }
    pclose(fp);

    p = strstr(line, " via ");
    if (NULL != p)
        sscanf(p + 5, "%19s", via);

    p = strstr(line, " dev ");
    if (NULL != p)
        sscanf(p + 5, "%15s", dev);

    return ('\0' != via[0] && '\0' != dev[0]) ? 0 : -1;
}

/* 调用方需持有 bond_route_lock */
static void bond_route_remove_locked(void)
{
    char local_host[32] = {0};
    char peer_host[32] = {0};
    char server_host[32] = {0};

    if ('\0' != route_tun[0]) {
        snprintf(local_host, sizeof(local_host), "%s/32", route_local);
        snprintf(peer_host, sizeof(peer_host), "%s/32", route_peer);

        const char *rule_from_del[] = {
            "ip", "rule", "del", "from", local_host, "table", BOND_ROUTE_TABLE, NULL,
        };
        const char *rule_oif_del[] = {
            "ip", "rule", "del", "oif", route_tun, "table", BOND_ROUTE_TABLE, NULL,
        };
        const char *peer_del[] = {
            "ip", "route", "del", peer_host, "dev", route_tun,
            "table", BOND_ROUTE_TABLE, NULL,
        };
        const char *default_del[] = {
            "ip", "route", "del", "default", "via", route_peer,
            "dev", route_tun, "table", BOND_ROUTE_TABLE, NULL,
        };

        (void)bond_route_exec(rule_from_del);
        (void)bond_route_exec(rule_oif_del);
        (void)bond_route_exec(peer_del);
        (void)bond_route_exec(default_del);
    }

    if (server_route_added && '\0' != route_server[0]) {
        snprintf(server_host, sizeof(server_host), "%s/32", route_server);
        const char *server_del[] = {"ip", "route", "del", server_host, NULL};

        (void)bond_route_exec(server_del);
    }

    route_tun[0] = '\0';
    route_local[0] = '\0';
    route_peer[0] = '\0';
    route_server[0] = '\0';
    server_route_added = false;
}

int bond_route_setup(const char *tun_name, uint32_t local_ip, uint32_t peer_ip,
                     const char *server_ip)
{
    struct in_addr addr;
    char local_host[32];
    char peer_host[32];
    char server_host[32];
    int ret = 0;

    if (NULL == tun_name || '\0' == tun_name[0] || 0 == local_ip || 0 == peer_ip)
        return -1;

    pthread_mutex_lock(&bond_route_lock);

    /* 重连时先清掉上一轮的路由, 保证 replace 语义 */
    bond_route_remove_locked();

    snprintf(route_tun, sizeof(route_tun), "%s", tun_name);
    bond_ip_format(local_ip, route_local, sizeof(route_local));
    bond_ip_format(peer_ip, route_peer, sizeof(route_peer));

    snprintf(local_host, sizeof(local_host), "%s/32", route_local);
    snprintf(peer_host, sizeof(peer_host), "%s/32", route_peer);

    /*
     * 1. 服务器 /32 直连路由必须最先存在:
     *    默认路由一旦指向隧道, 外层连接若没有独立路由就会绕回隧道导致断链。
     *    已存在时不再覆盖, 交给 omr-tracker 的多路径路由管理。
     */
    if (NULL != server_ip && '\0' != server_ip[0] &&
        strcmp(server_ip, "0.0.0.0") != 0 &&
        1 == inet_pton(AF_INET, server_ip, &addr) &&
        !bond_route_has_host(server_ip)) {
        char via[BOND_ROUTE_IP_LEN] = {0};
        char dev[BOND_TUN_NAME_LEN] = {0};

        if (0 == bond_route_get_nexthop(server_ip, via, dev) &&
            0 != strcmp(dev, "lo") &&
            /* 不能把服务器路由指回隧道自身, 否则重连时的外层连接会绕进隧道 */
            0 != strcmp(dev, route_tun) &&
            0 != strcmp(via, route_peer)) {
            snprintf(server_host, sizeof(server_host), "%s/32", server_ip);
            const char *args[] = {
                "ip", "route", "replace", server_host, "via", via,
                "dev", dev, "metric", "1", NULL,
            };

            if (0 == bond_route_exec(args)) {
                snprintf(route_server, sizeof(route_server), "%s", server_ip);
                server_route_added = true;
                bt_log_info(LOG_ALL_OUT, "server route %s via %s dev %s\n",
                            server_host, via, dev);
            } else {
                bt_log_warn(LOG_ALL_OUT, "add server route %s failed!\n", server_host);
                ret = -1;
            }
        }
    }

    /*
     * 2. 策略路由表 1500:
     *    隧道本地地址/隧道出口的流量固定查 1500 表, 与 OMR 的 fwmark 规则保持一致。
     */
    {
        const char *rule_from_del[] = {
            "ip", "rule", "del", "from", local_host, "table", BOND_ROUTE_TABLE, NULL,
        };
        const char *rule_oif_del[] = {
            "ip", "rule", "del", "oif", route_tun, "table", BOND_ROUTE_TABLE, NULL,
        };
        const char *peer_replace[] = {
            "ip", "route", "replace", peer_host, "dev", route_tun,
            "table", BOND_ROUTE_TABLE, NULL,
        };
        const char *default_replace[] = {
            "ip", "route", "replace", "default", "via", route_peer,
            "dev", route_tun, "table", BOND_ROUTE_TABLE, NULL,
        };
        const char *rule_from_add[] = {
            "ip", "rule", "add", "from", local_host, "table", BOND_ROUTE_TABLE,
            "pref", "0", NULL,
        };
        const char *rule_oif_add[] = {
            "ip", "rule", "add", "oif", route_tun, "table", BOND_ROUTE_TABLE,
            "pref", "0", NULL,
        };

        (void)bond_route_exec(rule_from_del);
        (void)bond_route_exec(rule_oif_del);

        if (0 != bond_route_exec(peer_replace)) {
            bt_log_warn(LOG_ALL_OUT, "add peer route %s failed!\n", peer_host);
            ret = -1;
        }
        if (0 != bond_route_exec(default_replace)) {
            bt_log_warn(LOG_ALL_OUT, "add tunnel default route failed!\n");
            ret = -1;
        }
        if (0 != bond_route_exec(rule_from_add)) {
            bt_log_warn(LOG_ALL_OUT, "add rule from %s failed!\n", local_host);
            ret = -1;
        }
        if (0 != bond_route_exec(rule_oif_add)) {
            bt_log_warn(LOG_ALL_OUT, "add rule oif %s failed!\n", route_tun);
            ret = -1;
        }
    }

    if (0 == ret) {
        bt_log_info(LOG_ALL_OUT, "tunnel routes ready: local %s peer %s dev %s\n",
                    route_local, route_peer, route_tun);
    }

    pthread_mutex_unlock(&bond_route_lock);

    return ret;
}

void bond_route_remove(void)
{
    pthread_mutex_lock(&bond_route_lock);
    bond_route_remove_locked();
    pthread_mutex_unlock(&bond_route_lock);
}
