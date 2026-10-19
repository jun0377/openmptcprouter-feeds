#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :

import os									# 私有库目录
import signal								# 注册 SIGINT/SIGTERM/SIGHUP, 实现优雅退出
import sys									# 把私有库目录加入模块搜索路径, 并作为进程退出码
import time									# 主循环休眠

# 私有库目录(打包装到 /usr/libexec/basestation, 见 Makefile 的 install 段)
# 可用环境变量覆盖, 便于在开发机上直接运行: BASESTATION_LIB_DIR=./files/usr/libexec/basestation python3 basestation.py
LIB_DIR = os.environ.get("BASESTATION_LIB_DIR", "/usr/libexec/basestation")
sys.path.insert(0, LIB_DIR)					# 必须早于下面 import 私有模块

import run									# 测试指令与用例, 见 run.py(仅自测用)

from logger import log, close_log			# 日志出口, 见 logger.py
from uci import uci_get						# 主循环间隔取自 UCI: basestation.remote 节

DEFAULT_INTERVAL = 10						# 主循环周期(秒)默认值, 配置项缺失或非法时使用


# 读取 UCI 主循环间隔(basestation.remote.interval_sec), 缺失或非法时回退默认值
def _load_interval():
	raw = uci_get("basestation.remote.interval_sec")
	if raw:
		try:
			value = int(raw)
			if value > 0:						# 非正整数视为非法配置, 保留默认值
				return value
		except ValueError:
			pass
	return DEFAULT_INTERVAL


LOOP_INTERVAL = _load_interval()			# 主循环周期(秒)

running = True								# 主循环运行标志, 收到退出信号时置为 False


# 信号处理: 只置退出标志, 由主循环自行收尾, 避免在信号处理里做复杂操作
def on_signal(signum, frame):
	global running
	running = False


# 注册退出信号
def setup_signals():
	for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
		signal.signal(sig, on_signal)


# 测试: 逐条执行 run 里的用例(远端执行)并记录结果
def run_cmd_tests():
	for argv in run.ARGV_CASES:
		ok, data, _raw, err = run.run_argv(argv)
		log("run_argv %s -> ok=%s data=%r err=%r" % (" ".join(argv), ok, data, err.strip()))
	for name, kwargs in run.RUN_CASES:
		ok, data, _raw, err = run.run(name, **kwargs)
		log("run %s %s -> ok=%s data=%r err=%r" % (name, kwargs, ok, data, err.strip()))


# 主循环
def main_loop():
	while running:
		run_cmd_tests()
		time.sleep(LOOP_INTERVAL)


def main():
	setup_signals()

	if not run.REMOTE_HOST:						# 未配置远端主机: 不做任何执行, 直接退出
		log("basestation.remote.host not configured")
		return 1

	log("basestation start")
	run.register_all()
	main_loop()
	log("basestation stop")
	close_log()

	return 0


if __name__ == "__main__":
	sys.exit(main())
