
#ifdef MEM_LEAK_CHECK
	#include <mcheck.h>
#endif
#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <stdarg.h>
#include <getopt.h>
#include <string.h>
#include <unistd.h>
#include <assert.h>
#include <signal.h>
#include <time.h>
#include <sys/time.h>
#include <sys/syscall.h>
#include <sys/stat.h>
#include <sys/types.h>
#include <fcntl.h>
#include <pthread.h>

#include "bond_trans_sdk.h"
#include "config.h"

#define gettid() syscall(__NR_gettid)

bond_comm_param_t comm_param;
bond_trans_param_t param;

static char conf_path[512] = {0};

volatile sig_atomic_t exit_signal_received = 0;

static void signal_handler(int sig)
{
	signal(sig, SIG_DFL);
	exit_signal_received = 1;
}


#define LOG_FILE_OUT	0x01
#define LOG_STD_OUT		0x02
#define LOG_ALL_OUT		(LOG_FILE_OUT | LOG_STD_OUT)

void _my_assert(char* func, int line, int value);

int log_level = LOG_LEVEL_INFO;

static int log_fd = -1;
static long long log_max_bytes = 0;
static char log_file_path[512] = {0};
static pthread_mutex_t log_mutex = PTHREAD_MUTEX_INITIALIZER;

/* 确保日志文件所在目录存在 */
static void log_mkdir(const char *path)
{
	char dir[512];
	char *slash;

	snprintf(dir, sizeof(dir), "%s", path);
	slash = strrchr(dir, '/');
	if (NULL == slash || slash == dir)
		return;

	*slash = '\0';
	mkdir(dir, 0755);
}

/* 打开日志文件, size_mb <= 0 表示不限制大小、不轮转 */
static void log_init_file(const char *path, int size_mb)
{
	if (NULL == path || '\0' == path[0])
		return;

	snprintf(log_file_path, sizeof(log_file_path), "%s", path);
	log_mkdir(log_file_path);

	log_fd = open(log_file_path, O_WRONLY | O_CREAT | O_APPEND, 0644);
	if (log_fd < 0) {
		fprintf(stderr, "open log file %s failed: %s\n", log_file_path, strerror(errno));
		return;
	}

	log_max_bytes = (size_mb > 0) ? (long long)size_mb * 1024 * 1024 : 0;
}

/* 日志超过限制: 内容转存为 .bak, 原文件截断后从头覆盖 */
static void log_rotate(void)
{
	char bak_path[sizeof(log_file_path) + 4];
	struct stat st;
	char buf[16 * 1024];
	int in_fd;
	int out_fd;
	ssize_t n;

	if (log_fd < 0 || log_max_bytes <= 0)
		return;

	if (0 != fstat(log_fd, &st) || st.st_size < log_max_bytes)
		return;

	snprintf(bak_path, sizeof(bak_path), "%s.bak", log_file_path);

	in_fd = open(log_file_path, O_RDONLY);
	out_fd = open(bak_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
	if (in_fd >= 0 && out_fd >= 0) {
		while ((n = read(in_fd, buf, sizeof(buf))) > 0) {
			ssize_t off = 0;
			while (off < n) {
				ssize_t w = write(out_fd, buf + off, n - off);
				if (w <= 0)
					break;
				off += w;
			}
			if (off < n)
				break;
		}
	}

	if (in_fd >= 0)
		close(in_fd);
	if (out_fd >= 0)
		close(out_fd);

	if (0 != ftruncate(log_fd, 0))
		fprintf(stderr, "truncate log file %s failed: %s\n", log_file_path, strerror(errno));
}

/* 写入日志文件, 写入前检查是否需要轮转 */
static void log_write_file(const char *buf, size_t len)
{
	size_t off = 0;

	if (log_fd < 0)
		return;

	log_rotate();

	while (off < len) {
		ssize_t w = write(log_fd, buf + off, len - off);
		if (w <= 0)
			break;
		off += (size_t)w;
	}
}

int log_printf(int out_target, int level, const char* format, ...)
{
	if(level > log_level)
		return 0;

	char printf_buf[2048] = {'\0'};

	char *level_str = NULL;
	switch (level)
	{
	case LOG_LEVEL_DEBUG:
		level_str = "[Debug]";
		break;;
	case LOG_LEVEL_INFO:
		level_str = "[ Info]";
		break;
	case LOG_LEVEL_WARNING:
		level_str = "[ Warn]";
		break;
	case LOG_LEVEL_ERROR:
		level_str = "[Error]";
		break;
	default:
		_my_assert((char*)__func__, __LINE__, 0);
		break;
	}

	struct timeval tv;
	gettimeofday(&tv,NULL);
	struct tm now_time;
	localtime_r(&tv.tv_sec, &now_time);
	long long msec =  tv.tv_usec / 1000;

	sprintf(printf_buf, "%s_%04d/%02d/%02d_%02d:%02d:%02d:%03lld: <%05d> ",
		level_str, now_time.tm_year + 1900, now_time.tm_mon + 1, now_time.tm_mday, now_time.tm_hour, now_time.tm_min, now_time.tm_sec, msec, (int)gettid());

	int in_buff_len = strlen(printf_buf);
	va_list arg;
	va_start(arg, format);
	int done = vsnprintf(printf_buf + in_buff_len, sizeof(printf_buf) - 1 - in_buff_len, format, arg);
	if (done <= 0)
	{
		_my_assert((char*)__func__, __LINE__, 0);
	}
	va_end(arg);

	pthread_mutex_lock(&log_mutex);
	if (out_target & LOG_FILE_OUT)
		log_write_file(printf_buf, strlen(printf_buf));
	if (out_target & LOG_STD_OUT) {
		fprintf(stdout, "%s", printf_buf);
		fflush(stdout);
	}
	pthread_mutex_unlock(&log_mutex);

	return 0;
}

void _my_assert(char* func, int line, int value)
{
	if (value == 0)
	{
		printf("******FETAL ERROR******, we assert here. %s:%d, errno:%d errstr:%s *******\n", func, line, errno, strerror(errno));
		printf("******FETAL ERROR******, we assert here. %s:%d, errno:%d errstr:%s *******\n", func, line, errno, strerror(errno));
		printf("******FETAL ERROR******, we assert here. %s:%d, errno:%d errstr:%s *******\n", func, line, errno, strerror(errno));
		printf("******FETAL ERROR******, we assert here. %s:%d, errno:%d errstr:%s *******\n", func, line, errno, strerror(errno));
		printf("******FETAL ERROR******, we assert here. %s:%d, errno:%d errstr:%s *******\n", func, line, errno, strerror(errno));
		printf("******FETAL ERROR******, we assert here. %s:%d, errno:%d errstr:%s *******\n", func, line, errno, strerror(errno));
		printf("******FETAL ERROR******, we assert here. %s:%d, errno:%d errstr:%s *******\n", func, line, errno, strerror(errno));
		printf("******FETAL ERROR******, we assert here. %s:%d, errno:%d errstr:%s *******\n", func, line, errno, strerror(errno));

		sync();
		fflush(stdout);
		assert(0);
	}
}

void usage(char *prog)
{
	fprintf(stderr, "\nUsage: %s -c|-s --conf <path>\n\n", prog);
	fprintf(stderr, "        [-s]                     work in server mode\n");
	fprintf(stderr, "        [-c]                     work in client mode\n");
	fprintf(stderr, "        [--conf  path]           config file, e.g. conf/server.ini or conf/client.ini\n");
	fprintf(stderr, "\n\n");

	exit(0);
}

int parse_options(int argc, char *argv[])
{
	int opt = 0;
	int option_index = 0;
	int mode_set = 0;

	/* 兼容单横线写法: -conf path */
	for (int i = 1; i < argc; i++) {
		if (0 == strcmp(argv[i], "-conf"))
			argv[i] = "--conf";
	}

	struct option long_options[] = {
		{"conf",  required_argument, 0,  'f' },
		{0, 			0,				   0,  0 }
	};

	while((opt = getopt_long(argc, argv, "cstf:", long_options, &option_index)) != -1)
	{
		switch(opt)
		{
		case 'c':
			comm_param.mode = BOND_MODE_CLIENT;
			mode_set = 1;
			break;
		case 's':
			comm_param.mode = BOND_MODE_SERVER;
			mode_set = 1;
			break;
		case 't':
			/* 仅保留兼容, 传输协议固定为 MPTCPv1 */
			break;
		case 'f':
			snprintf(conf_path, sizeof(conf_path), "%s", optarg);
			break;
		default: /* '?' */
			usage(argv[0]);
		}
	}

	if (!mode_set) {
		fprintf(stderr, "must specify -c or -s\n");
		usage(argv[0]);
	}

	if ('\0' == conf_path[0]) {
		fprintf(stderr, "must specify --conf <path>\n");
		usage(argv[0]);
	}

	return 0;
}

static void handle_pipe(int sig)
{
	/* 信号处理函数中不能使用带锁的日志接口, 直接写 stderr */
	const char msg[] = "[Error] recv SIGPIPE !!!\n\n";
	(void)sig;
	write(STDERR_FILENO, msg, sizeof(msg) - 1);
}

int main(int argc, char *argv[])
{
// 检测内存泄漏
#ifdef MEM_LEAK_CHECK
	mtrace();
#endif

	signal(SIGINT, signal_handler);
	signal(SIGPIPE, handle_pipe);

	if(argc == 1) {
		usage(argv[0]);
	}
	strcpy(param.server_ip, "0.0.0.0");
	strcpy(param.server_bind_ip, "0.0.0.0");
	parse_options(argc, argv);

	char log_file[512] = {0};
	int log_size_mb = 1;
	if (0 != config_load(conf_path, &comm_param, &param, &log_level,
	                     log_file, sizeof(log_file), &log_size_mb))
		return -1;

	log_init_file(log_file, log_size_mb);

	log_printf(LOG_ALL_OUT, LOG_LEVEL_INFO,
			"config:%s mode:%s tun:%s server:%s:%d bind:%s buffer:%dMB queue:%d log_level:%d\n",
			conf_path,
			comm_param.mode == BOND_MODE_CLIENT ? "client" : "server",
			comm_param.tun_name, param.server_ip, param.server_port,
			param.server_bind_ip, comm_param.buffer_size, param.queue_capacity, log_level);

	if (0 != trans_init(&comm_param)) {
		log_printf(LOG_ALL_OUT, LOG_LEVEL_ERROR, "trans_init failed\n");
		return -1;
	}

	if (0 != trans_add_forward(&param)) {
		log_printf(LOG_ALL_OUT, LOG_LEVEL_ERROR, "trans_add_forward failed\n");
		trans_uninit();
		return -1;
	}

	while(1) {
		usleep(10 * 1000);
		if(exit_signal_received)
			break;
	}

	trans_remove_forward(&param);
	trans_uninit();

#ifdef MEM_LEAK_CHECK
	muntrace();
#endif

	return 0;
}

