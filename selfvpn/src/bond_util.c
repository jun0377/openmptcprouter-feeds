#include <arpa/inet.h>
#include <stdio.h>
#include <time.h>

#include "bond_util.h"

int ip_parse(const char *ip_str, uint32_t *ip_out)
{
    struct in_addr addr;

    if (NULL == ip_str || NULL == ip_out)
        return -1;

    if (1 != inet_pton(AF_INET, ip_str, &addr))
        return -1;

    *ip_out = ntohl(addr.s_addr);
    return 0;
}

void bond_ip_format(uint32_t ip, char *buf, size_t buf_len)
{
    struct in_addr addr;

    if (NULL == buf || 0 == buf_len)
        return;

    addr.s_addr = htonl(ip);
    if (NULL == inet_ntop(AF_INET, &addr, buf, (socklen_t)buf_len))
        snprintf(buf, buf_len, "0.0.0.0");
}

int64_t bond_now_ms(void)
{
    struct timespec ts;

    clock_gettime(CLOCK_MONOTONIC, &ts);

    return (int64_t)ts.tv_sec * 1000 + ts.tv_nsec / 1000000;
}
