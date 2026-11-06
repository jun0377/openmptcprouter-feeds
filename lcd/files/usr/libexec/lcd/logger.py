# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 日志: 同时输出到 stdout(手动运行时可见) 与日志文件
# 路径和大小上限由 /etc/config/lcd 的 log 段配置(lcd.log.path / lcd.log.max_size),
# 未配置或读取失败时默认 /var/log/lcd/lcd.log、1MB;
# 文件写满后先备份为 <path>.rotate(只保留一份, 旧的被覆盖), 再从空文件重新写
#
# 本模块不引用任何其它私有模块, 是依赖树的叶子;
# uart/uci 等都从这里取 log, 从而避免与 lcd.py 互相 import
# (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#

import os									# 日志目录/文件的 open/write/rename
import subprocess							# 读取 /etc/config/lcd 的日志配置
import time									# 时间戳

CONFIG = "lcd"								# uci 配置文件 /etc/config/lcd
SECTION = "log"								# 日志配置段
UCI_TIMEOUT = 2								# 读配置时 uci 命令的超时(秒)

LOG_FILE = "/var/log/lcd/lcd.log"			# 当前日志文件(默认值, open_log 时按 uci 覆盖)
LOG_DIR = "/var/log/lcd"					# 日志目录
LOG_ROTATE = LOG_DIR + "/lcd.log.rotate"	# 写满后的备份文件(只保留一份)
LOG_MAX_SIZE = 1024 * 1024					# 单个日志文件大小上限(默认 1MB)

_log_fd = None								# 日志文件描述符, 打开失败时保持 None


# 读取一项日志配置, 不存在或读取失败返回 None
def _uci_get(option):
	try:
		proc = subprocess.run(["uci", "-q", "get", "%s.%s.%s" % (CONFIG, SECTION, option)],
							  capture_output=True, text=True, timeout=UCI_TIMEOUT)
	except (OSError, subprocess.SubprocessError):							# uci 不存在/超时等
		return None
	if proc.returncode != 0:												# 配置项不存在(uci -q 不报错, 只返回非 0)
		return None
	return proc.stdout.strip()


# 从 uci 读取日志路径与大小上限, 配置缺失或非法时保留默认值
def _load_config():
	global LOG_FILE, LOG_DIR, LOG_ROTATE, LOG_MAX_SIZE
	path = _uci_get("path")
	if path:
		LOG_FILE = path
		LOG_DIR = os.path.dirname(path) or "."
		LOG_ROTATE = path + ".rotate"
	size = _uci_get("max_size")
	if size:
		try:
			mb = int(size)
		except ValueError:
			mb = 0
		if mb > 0:															# 0/负数视为未配置, 用默认值
			LOG_MAX_SIZE = mb * 1024 * 1024


# 打开日志文件, 失败时退化为只输出到 stdout
def open_log():
	global _log_fd
	_load_config()															# 先按 uci 配置确定路径与大小上限
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
