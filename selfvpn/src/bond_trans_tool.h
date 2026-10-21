
/*================================================================
*
*   文件名称：bond_trans_tool.h
*   创 建 者：zhaop
*   创建日期：2020年05月26日
*   描    述：
*
================================================================*/


#ifndef __BOND_TRANS_TOOL_H__
#define __BOND_TRANS_TOOL_H__

#include <unistd.h>
#include <stdint.h>
#include <stdbool.h>
#include <sys/prctl.h>
#include <sys/syscall.h>

#define gettid() syscall(__NR_gettid)

#define BOND_TRANSMISSION_LOG_LABEL "<Bond>"

#define LOG_FILE_OUT	0x01
#define LOG_STD_OUT		0x02
#define LOG_ALL_OUT		(LOG_FILE_OUT | LOG_STD_OUT)

#define LOG_LEVEL_ERROR		1
#define LOG_LEVEL_WARNING	2
#define LOG_LEVEL_INFO		3
#define LOG_LEVEL_DEBUG		4

extern int log_printf(int out_target, int level, const char* format, ...);
 
#define bt_log_error(target, type, args...) log_printf(target, LOG_LEVEL_ERROR, BOND_TRANSMISSION_LOG_LABEL " <%s> " type, __func__, ##args)
#define bt_log_warn(target, type, args...) log_printf(target, LOG_LEVEL_WARNING, BOND_TRANSMISSION_LOG_LABEL " <%s> " type, __func__, ##args)
#define bt_log_notice(target, type, args...) log_printf(target, LOG_LEVEL_INFO, BOND_TRANSMISSION_LOG_LABEL " <%s> " type, __func__, ##args)
#define bt_log_info(target, type, args...) log_printf(target, LOG_LEVEL_INFO, BOND_TRANSMISSION_LOG_LABEL " <%s> " type, __func__, ##args)
#define bt_log_debug(target, type, args...) log_printf(target, LOG_LEVEL_DEBUG, BOND_TRANSMISSION_LOG_LABEL " <%s> " type, __func__, ##args)

#if 0
#define bt_log_trace(target, type, args...) log_printf(target, LOG_LEVEL_DEBUG, BOND_TRANSMISSION_LOG_LABEL " <%s> " type, __func__, ##args)
#else
#define bt_log_trace(target, type, args...)
#endif

extern void _my_assert(char* func, int line, int value);

#define bt_debug_assert(value)		_my_assert((char*)__func__, __LINE__, value)
#define bt_release_assert(value)		_my_assert((char*)__func__, __LINE__, value)
#define bt_debug_log_assert(value, type, args...)	({\
    if (!(value)) { \
        bt_log_error(LOG_ALL_OUT, type, ##args); \
    } \
    _my_assert((char*)__func__, __LINE__, value); \
})

#define ENTER_THREAD_PTINT	bt_log_info(LOG_ALL_OUT, "Enter thread %s, tid %d.\n", (char *)__func__, (int)gettid())
#define EXIT_THREAD_PRINT	bt_log_info(LOG_ALL_OUT, "Exit  thread %s.\n", (char *)__func__)
#define ENTER_FUNC_PTINT	bt_log_info(LOG_ALL_OUT, "Enter func %s.\n", (char *)__func__)
#define EXIT_FUNC_PRINT		bt_log_info(LOG_ALL_OUT, "Exit  func %s.\n", (char *)__func__)

#define TRACE_PRINT 		bt_log_info(LOG_ALL_OUT, "%s:%d\n", __func__, __LINE__)


#define EFFICIENCY_CHECK_INIT	uint64_t efficiency_old_time = bond_trans_get_time_msec();

#define EFFICIENCY_CHECK_BEGIN	({\
    efficiency_old_time = bond_trans_get_time_msec(); \
})

#define EFFICIENCY_CHECK_END(thresh)	({\
    uint64_t efficiency_curr_time = bond_trans_get_time_msec(); \
    int efficiency_diff_time = efficiency_curr_time - efficiency_old_time;  \
    if(efficiency_diff_time > (thresh)) { \
		bt_log_error(LOG_ALL_OUT, "%s:%d thresh %d ms !!!\n", (char*)__func__, __LINE__, efficiency_diff_time); \
	} \
	efficiency_old_time = efficiency_curr_time; \
})

#define PARAM_CHECK_RANGE(value, min, max)	((value) < (min) ? (min) : ((value) > (max) ? (max) : (value)))


int set_bits(char *buf, int start_bits, int bit_num, uint32_t value, uint32_t bitmask);
int get_bits(const char *buf, int start_bits, int bit_num, uint32_t *value, uint32_t bitmask);

void dump_buff_content(char *buf, int len, char *info);

uint64_t bond_trans_get_time_msec(void);


#endif // __BOND_TRANS_TOOL_H__
