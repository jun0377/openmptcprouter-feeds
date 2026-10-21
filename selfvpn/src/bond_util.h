#ifndef BOND_UTIL_H
#define BOND_UTIL_H

#include <stdint.h>
#include <stddef.h>

int ip_parse(const char *ip_str, uint32_t *ip_out);
void bond_ip_format(uint32_t ip, char *buf, size_t buf_len);

/* 单调毫秒时钟，用于超时判断 */
int64_t bond_now_ms(void);

#endif /* BOND_UTIL_H */
