# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 日志: 同时输出到 stdout(手动运行时可见) 与 /var/log/lcd/lcd.log
# 文件超过 1MB 时先备份为 lcd.log.rotate(只保留一份, 旧的被覆盖), 再从空文件重新写
#
# 本模块不引用任何其它私有模块, 是依赖树的叶子;
# uart/uci 等都从这里取 log, 从而避免与 lcd.py 互相 import
# (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#

import os									# 日志目录/文件的 open/write/rename
import time									# 时间戳

LOG_DIR = "/var/log/lcd"					# 日志目录
LOG_FILE = LOG_DIR + "/lcd.log"				# 当前日志文件
LOG_ROTATE = LOG_DIR + "/lcd.log.rotate"	# 写满后的备份文件(只保留一份)
LOG_MAX_SIZE = 1024 * 1024					# 单个日志文件大小上限(1MB)

_log_fd = None								# 日志文件描述符, 打开失败时保持 None


# 打开日志文件, 失败时退化为只输出到 stdout
def open_log():
	global _log_fd
	try:
		os.makedirs(LOG_DIR, exist_ok=True)											# /var/log 下可能没有 lcd 目录
		_log_fd = os.open(LOG_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)	# 追加打开, 不存在则创建
	except OSError as err:
		print("Failed to open log file %s: %s" % (LOG_FILE, err), flush=True)


# 文件写满时: 关闭当前文件, 覆盖备份文件, 再从空文件重新开始
def _rotate_log_file():
	global _log_fd
	if _log_fd is not None:
		try:
			os.close(_log_fd)
		except OSError:
			pass
		_log_fd = None
	try:
		os.replace(LOG_FILE, LOG_ROTATE)											# 覆盖上一份备份
	except OSError:
		pass
	try:
		_log_fd = os.open(LOG_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
	except OSError:
		_log_fd = None


# 把一行日志写入文件, 超出上限时先轮转
def _write_log_file(line):
	if _log_fd is None:
		return
	data = line.encode("utf-8")
	try:
		if os.lseek(_log_fd, 0, os.SEEK_END) + len(data) > LOG_MAX_SIZE:
			_rotate_log_file()
		if _log_fd is not None:
			os.write(_log_fd, data)
	except OSError:																# 磁盘满/文件被删等写失败不影响主流程
		pass


# 统一的日志出口: 同时输出到 stdout 与日志文件
def log(message):
	line = "[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message)			# 加时间戳和换行符
	print(line, end="", flush=True)												# 手动运行时在终端可见
	_write_log_file(line)														# 再写入 /var/log/lcd/lcd.log
