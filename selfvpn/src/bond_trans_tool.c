
/*================================================================
*
*   文件名称：bond_trans_tool.c
*   创 建 者：zhaop
*   创建日期：2020年05月26日
*   描    述：
*
================================================================*/

#include <stdio.h>
#include <errno.h>
#include <unistd.h>
#include <stdint.h>
#include <stdlib.h>
#include <stdarg.h>
#include <string.h>
#include <pthread.h>
#include <sys/time.h>
#include <arpa/inet.h>
#include "bond_trans_tool.h"

int set_bits(char *buf, int start_bits, int bit_num, uint32_t value, uint32_t bitmask)
{
	int stop_bits = start_bits + bit_num - 1;
	int pos = stop_bits / 8;
	int r_off = 7 - stop_bits % 8;

	if(bit_num + r_off > 32)
		return -1;

	value &= bitmask;

	bitmask <<= r_off;
	value <<= r_off;
	bit_num += r_off;

	uint8_t *p = (uint8_t *)(buf + pos);
	uint8_t *q = (uint8_t *)&value;
	uint8_t *h = (uint8_t *)&bitmask;

	//Little Endian
	while(bit_num > 0)
	{
		*p &= ~(*h);
		*p |= *q;
		p--;
		q++;
		h++;
		bit_num -= 8;
	}

	return 0;
}

int get_bits(const char *buf, int start_bits, int bit_num, uint32_t *value_p, uint32_t bitmask)
{
	int stop_bits = start_bits + bit_num - 1;
	int pos = stop_bits / 8;
	int r_off = 7 - stop_bits % 8;

	if(bit_num + r_off > 32)
		return -1;

	uint32_t value = 0;
	bitmask <<= r_off;
	bit_num += r_off;

	uint8_t *p = (uint8_t *)(buf + pos);
	uint8_t *q = (uint8_t *)&value;
	uint8_t *h = (uint8_t *)&bitmask;

	//Little Endian
	while(bit_num > 0)
	{
		*q = *p & *h;
		p--;
		q++;
		h++;
		bit_num -= 8;
	}

	value >>= r_off;
	*value_p = value;

	return 0;
}

void dump_buff_content(char *buf, int len, char *info)
{
	int buflen = len * 3 + len / 16 + 10;
	char *logbuf = malloc(buflen);
	int logoff = 0;
	int i;
	for(i = 0; i < len; i++)
	{
		if(i % 16 == 0)
			logoff += snprintf(logbuf + logoff, buflen - logoff, "\n");
		logoff += snprintf(logbuf + logoff, buflen - logoff, "%02x ", (uint8_t)buf[i]);
	}
	bt_log_warn(LOG_ALL_OUT, "%s%s\n", info, logbuf);
	free(logbuf);
}

uint64_t bond_trans_get_time_msec(void)
{
	struct timeval tv;
	gettimeofday(&tv, NULL);

	uint64_t msec = (uint64_t)tv.tv_sec * 1000 + tv.tv_usec/1000;

	return msec;
}

/*
 * 默认日志/断言实现使用 weak 符号:
 * 宿主程序(如 sample)可以定义同名强符号覆盖, 库不再依赖外部必须提供这两个函数。
 */
__attribute__((weak)) int log_printf(int out_target, int level, const char* format, ...)
{
	char buf[2048];
	va_list args;
	int len;

	(void)out_target;
	(void)level;

	va_start(args, format);
	len = vsnprintf(buf, sizeof(buf), format, args);
	va_end(args);

	if (len > 0) {
		fprintf(stderr, "%s", buf);
		fflush(stderr);
	}

	return 0;
}

__attribute__((weak)) void _my_assert(char* func, int line, int value)
{
	if (0 == value) {
		fprintf(stderr, "******FETAL ERROR****** %s:%d errno:%d errMsg:%s\n",
			func ? func : "unknown", line, errno, strerror(errno));
		fflush(stderr);
		abort();
	}
}



