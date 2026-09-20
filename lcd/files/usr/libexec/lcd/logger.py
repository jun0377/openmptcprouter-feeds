# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 日志: 同时输出到 stdout(procd 启动时收进 logd) 与日志文件, 供各模块共用
#
# 本模块不引用任何其它私有模块, 是依赖树的叶子;
# uart/uci 等都从这里取 log, 从而避免与 lcd.py 互相 import
# (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#

import os									# 日志文件的 open/close 与写入
import time									# 时间戳

LOG_FILE = "/var/log/lcd.log"				# 日志文件路径
LOG_MAX_SIZE = 512 * 1024					# 日志文件大小上限(字节), 超出后从头覆盖

_log_fd = None								# 日志文件描述符, 打开失败时保持 None


# 打开日志文件, 失败时退化为只输出到 stdout
def open_log():
	global _log_fd																		# 函数内部修改全部变量
	try:
		_log_fd = os.open(LOG_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)	  	# 追加打开, 不存在则创建, 权限 0644
	except OSError as err:															  	# 目录不存在/只读等情况下不致命
		print("Failed to open log file %s: %s" % (LOG_FILE, err), flush=True)			# 退化为只输出 stdout(procd 仍收进 logd)

# 把一行日志写入文件, 超出上限时清空重写
def _write_log_file(line):
	if _log_fd is None:														# 日志文件不可用(打开失败)则跳过(只读, 无需声明 global)
		return
	try:
		data = line.encode("utf-8")											# 文本转 UTF-8 字节

		# 写入后仍不超上限则直接追加; 否则清空文件, 从头开始覆盖旧内容
		if os.lseek(_log_fd, 0, os.SEEK_END) + len(data) > LOG_MAX_SIZE:	# 写入后仍不超上限则直接追加; 否则清空文件, 从头开始覆盖旧内容
			os.ftruncate(_log_fd, 0)										# 截断为 0: 旧内容全部丢弃
		os.write(_log_fd, data)												# O_APPEND 追加写(截断后即从头开始)
	except OSError:															# 磁盘满/文件被删等写失败不影响主流程
		pass

# 统一的日志出口: 同时输出到 stdout 与日志文件
def log(message):
	line = "[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message)		# 加时间戳和换行符
	# 由 procd 启动时 stdout 会进 logd(logread 查看), 同时落盘供长期查看
	print(line, end="", flush=True)											# 立即刷新, 保证 logd 收到完整行
	_write_log_file(line)													# 再写入 /var/log/lcd.log
