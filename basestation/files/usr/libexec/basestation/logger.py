# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :


import os									# 日志文件命名与轮转
import time									# 时间戳

from uci import uci_get						# 日志路径/大小取自 UCI: basestation.log 节

DEFAULT_LOG_FILE = "/var/log/basestation.log"	# 配置缺失时的默认日志文件路径
DEFAULT_LOG_MAX_MB = 1							# 配置缺失时的默认日志大小上限(MB)


# 读取 UCI 日志配置(basestation.log.file / basestation.log.max_size_MB), 缺失或非法时回退默认值
def _load_config():
	path = uci_get("basestation.log.file") or DEFAULT_LOG_FILE
	size_mb = DEFAULT_LOG_MAX_MB
	raw = uci_get("basestation.log.max_size_MB")
	if raw:
		try:
			value = int(raw)
			if value > 0:						# 非正整数视为非法配置, 保留默认值
				size_mb = value
		except ValueError:
			pass
	return path, size_mb * 1024 * 1024


LOG_FILE, LOG_MAX_SIZE = _load_config()		# 日志文件路径与大小上限(字节)

_log_fp = None								# 日志文件句柄, 打开失败时保持 None


# 打开日志文件(追加模式), 失败时退化为只输出 stdout
def open_log():
	global _log_fp
	try:
		_log_fp = open(LOG_FILE, "a", encoding="utf-8")
	except OSError as err:													# 目录不存在/只读等情况下不致命
		_log_fp = None
		print("Failed to open log file %s: %s" % (LOG_FILE, err), flush=True)	# 退化为只输出 stdout(procd 仍收进 logd)


# 关闭日志文件
def close_log():
	global _log_fp
	if _log_fp is not None:
		_log_fp.close()
		_log_fp = None


# 轮转日志: 当前文件超过上限时改名为 <日志文件>.1, 再重新打开新文件
def rotate_log():
	close_log()
	try:
		os.replace(LOG_FILE, LOG_FILE + ".1")
	except OSError:
		pass
	open_log()


# 统一的日志出口: 写入日志文件(超过上限自动轮转), 同时输出到标准输出
def log(message):
	global _log_fp
	line = "[%s] %s\n" % (time.strftime("%Y-%m-%d %H:%M:%S"), message)
	print(line, end="", flush=True)			# 同时输出到标准输出, 交给 procd/logd
	if _log_fp is None:
		open_log()
	if _log_fp is None:						# 文件不可写时仅保留标准输出
		return
	try:
		if _log_fp.tell() >= LOG_MAX_SIZE:
			rotate_log()
		_log_fp.write(line)
		_log_fp.flush()
	except OSError:
		pass
