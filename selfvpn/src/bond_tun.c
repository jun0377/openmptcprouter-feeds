#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <net/if.h>
#include <netinet/in.h>
#include <linux/if_tun.h>

#include "bond_tun.h"
#include "bond_trans_tool.h"

#define BOND_TUN_TX_QUEUE_LEN 10000
#define BOND_TUN_DEFAULT_MTU  1500

struct bond_tun {
    int  fd;
    char name[BOND_TUN_NAME_LEN];
    int  mtu;
    bool owns_fd;
    bool fake;
};

static int bond_tun_if_ioctl(const char *name, unsigned long req, struct ifreq *ifr)
{
    int fd;
    int ret;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return -1;

    snprintf(ifr->ifr_name, IFNAMSIZ, "%s", name);
    ret = ioctl(fd, req, ifr);
    if (ret < 0) {
        int err = errno;
        close(fd);
        errno = err;
        return -1;
    }

    close(fd);
    return 0;
}

static int bond_tun_set_flags(bond_tun_t *tun, short flags)
{
    struct ifreq ifr;

    memset(&ifr, 0, sizeof(ifr));
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", tun->name);
    ifr.ifr_flags = flags;

    return bond_tun_if_ioctl(tun->name, SIOCSIFFLAGS, &ifr);
}

int bond_tun_set_up(bond_tun_t *tun)
{
    struct ifreq ifr;

    if (NULL == tun)
        return -1;

    if (tun->fake)
        return 0;

    memset(&ifr, 0, sizeof(ifr));
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", tun->name);
    if (0 != bond_tun_if_ioctl(tun->name, SIOCGIFFLAGS, &ifr)) {
        bt_log_error(LOG_ALL_OUT, "get tun %s flags failed! errno:%d\n", tun->name, errno);
        return -1;
    }

    ifr.ifr_flags |= IFF_UP | IFF_RUNNING;
    if (0 != bond_tun_set_flags(tun, ifr.ifr_flags)) {
        bt_log_error(LOG_ALL_OUT, "set tun %s up failed! errno:%d\n", tun->name, errno);
        return -1;
    }

    return 0;
}

bond_tun_t *bond_tun_create(const char *name, int mtu)
{
    bond_tun_t *tun = NULL;
    struct ifreq ifr;
    int fd;

    if (mtu <= 0)
        mtu = BOND_TUN_DEFAULT_MTU;

    fd = open("/dev/net/tun", O_RDWR | O_CLOEXEC);
    if (fd < 0) {
        bt_log_error(LOG_ALL_OUT, "open /dev/net/tun failed! errno:%d errMsg:%s\n", errno, strerror(errno));
        return NULL;
    }

    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_flags = IFF_TUN | IFF_NO_PI;
    if (NULL != name && '\0' != name[0])
        snprintf(ifr.ifr_name, IFNAMSIZ, "%s", name);

    if (0 != ioctl(fd, TUNSETIFF, &ifr)) {
        bt_log_error(LOG_ALL_OUT, "TUNSETIFF failed! errno:%d errMsg:%s\n", errno, strerror(errno));
        close(fd);
        return NULL;
    }

    tun = calloc(1, sizeof(*tun));
    if (NULL == tun) {
        close(fd);
        return NULL;
    }

    tun->fd = fd;
    tun->mtu = mtu;
    tun->owns_fd = true;
    tun->fake = false;
    snprintf(tun->name, sizeof(tun->name), "%s", ifr.ifr_name);

    /* MTU 和发送队列长度 */
    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_mtu = mtu;
    if (0 != bond_tun_if_ioctl(tun->name, SIOCSIFMTU, &ifr)) {
        bt_log_warn(LOG_ALL_OUT, "set tun %s mtu %d failed! errno:%d\n", tun->name, mtu, errno);
    }

    memset(&ifr, 0, sizeof(ifr));
    ifr.ifr_qlen = BOND_TUN_TX_QUEUE_LEN;
    if (0 != bond_tun_if_ioctl(tun->name, SIOCSIFTXQLEN, &ifr)) {
        bt_log_warn(LOG_ALL_OUT, "set tun %s txqueuelen failed! errno:%d\n", tun->name, errno);
    }

    if (0 != bond_tun_set_up(tun)) {
        bond_tun_destroy(tun);
        return NULL;
    }

    bt_log_info(LOG_ALL_OUT, "tun device %s created, fd:%d mtu:%d\n", tun->name, tun->fd, tun->mtu);

    return tun;
}

bond_tun_t *bond_tun_from_fd(int fd, const char *name)
{
    bond_tun_t *tun;

    if (fd < 0)
        return NULL;

    tun = calloc(1, sizeof(*tun));
    if (NULL == tun)
        return NULL;

    tun->fd = fd;
    tun->mtu = BOND_TUN_DEFAULT_MTU;
    tun->owns_fd = false;
    tun->fake = true;
    snprintf(tun->name, sizeof(tun->name), "%s", (NULL == name) ? "fake-tun" : name);

    return tun;
}

void bond_tun_destroy(bond_tun_t *tun)
{
    if (NULL == tun)
        return;

    if (tun->owns_fd && tun->fd >= 0)
        close(tun->fd);

    free(tun);
}

int bond_tun_fd(const bond_tun_t *tun)
{
    return (NULL == tun) ? -1 : tun->fd;
}

const char *bond_tun_name(const bond_tun_t *tun)
{
    return (NULL == tun) ? "" : tun->name;
}

int bond_tun_set_server_addr(bond_tun_t *tun, uint32_t local_ip, uint32_t netmask)
{
    struct ifreq ifr;
    struct sockaddr_in *sin;
    int fd;

    if (NULL == tun)
        return -1;

    if (tun->fake)
        return 0;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return -1;

    memset(&ifr, 0, sizeof(ifr));
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", tun->name);

    sin = (struct sockaddr_in *)&ifr.ifr_addr;
    sin->sin_family = AF_INET;
    sin->sin_addr.s_addr = htonl(local_ip);
    if (0 != ioctl(fd, SIOCSIFADDR, &ifr)) {
        bt_log_error(LOG_ALL_OUT, "set tun %s addr failed! errno:%d\n", tun->name, errno);
        close(fd);
        return -1;
    }

    memset(&ifr, 0, sizeof(ifr));
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", tun->name);
    sin = (struct sockaddr_in *)&ifr.ifr_netmask;
    sin->sin_family = AF_INET;
    sin->sin_addr.s_addr = htonl(netmask);
    if (0 != ioctl(fd, SIOCSIFNETMASK, &ifr)) {
        bt_log_error(LOG_ALL_OUT, "set tun %s netmask failed! errno:%d\n", tun->name, errno);
        close(fd);
        return -1;
    }

    close(fd);

    if (0 != bond_tun_set_up(tun))
        return -1;

    bt_log_info(LOG_ALL_OUT, "tun %s server addr %u.%u.%u.%u mask %u.%u.%u.%u\n", tun->name,
                (local_ip >> 24) & 0xFF, (local_ip >> 16) & 0xFF, (local_ip >> 8) & 0xFF, local_ip & 0xFF,
                (netmask >> 24) & 0xFF, (netmask >> 16) & 0xFF, (netmask >> 8) & 0xFF, netmask & 0xFF);
    return 0;
}

int bond_tun_set_client_addr(bond_tun_t *tun, uint32_t local_ip, uint32_t peer_ip)
{
    struct ifreq ifr;
    struct sockaddr_in *sin;
    int fd;

    if (NULL == tun || 0 == local_ip)
        return -1;

    if (tun->fake)
        return 0;

    fd = socket(AF_INET, SOCK_DGRAM, 0);
    if (fd < 0)
        return -1;

    memset(&ifr, 0, sizeof(ifr));
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", tun->name);
    sin = (struct sockaddr_in *)&ifr.ifr_addr;
    sin->sin_family = AF_INET;
    sin->sin_addr.s_addr = htonl(local_ip);
    if (0 != ioctl(fd, SIOCSIFADDR, &ifr)) {
        bt_log_error(LOG_ALL_OUT, "set tun %s client addr failed! errno:%d\n", tun->name, errno);
        close(fd);
        return -1;
    }

    memset(&ifr, 0, sizeof(ifr));
    snprintf(ifr.ifr_name, IFNAMSIZ, "%s", tun->name);
    sin = (struct sockaddr_in *)&ifr.ifr_netmask;
    sin->sin_family = AF_INET;
    sin->sin_addr.s_addr = htonl(0xFFFFFFFFu);
    if (0 != ioctl(fd, SIOCSIFNETMASK, &ifr)) {
        bt_log_warn(LOG_ALL_OUT, "set tun %s client netmask failed! errno:%d\n", tun->name, errno);
    }

    if (0 != peer_ip) {
        memset(&ifr, 0, sizeof(ifr));
        snprintf(ifr.ifr_name, IFNAMSIZ, "%s", tun->name);
        sin = (struct sockaddr_in *)&ifr.ifr_dstaddr;
        sin->sin_family = AF_INET;
        sin->sin_addr.s_addr = htonl(peer_ip);
        if (0 != ioctl(fd, SIOCSIFDSTADDR, &ifr)) {
            bt_log_warn(LOG_ALL_OUT, "set tun %s peer addr failed! errno:%d\n", tun->name, errno);
        }
    }

    close(fd);

    if (0 != bond_tun_set_up(tun))
        return -1;

    bt_log_info(LOG_ALL_OUT, "tun %s client addr %u.%u.%u.%u peer %u.%u.%u.%u\n", tun->name,
                (local_ip >> 24) & 0xFF, (local_ip >> 16) & 0xFF, (local_ip >> 8) & 0xFF, local_ip & 0xFF,
                (peer_ip >> 24) & 0xFF, (peer_ip >> 16) & 0xFF, (peer_ip >> 8) & 0xFF, peer_ip & 0xFF);
    return 0;
}
