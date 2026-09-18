# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# uci 配置读写: 对 uci 命令的薄封装, 供各页面模块读取/修改系统配置
#
# 依赖 logger 模块记录失败原因, 不依赖 lcd.py(主程序以 __main__ 名运行, 引用它会重复执行)
#

import subprocess							# 调用 uci 命令读写系统配置

from logger import log

UCI_TIMEOUT = 5								# 单条 uci 命令的超时(秒), 防止 uci 卡住阻塞主循环


# 执行一条 uci 命令: args 为不含 "uci" 的参数列表, 返回 (是否成功, 标准输出)
def _run_uci(args):
	try:
		proc = subprocess.run(["uci"] + args, capture_output=True, text=True, timeout=UCI_TIMEOUT)
	except (OSError, subprocess.SubprocessError) as err:			# uci 不存在、超时、被信号杀掉等
		log("Run uci %s failed: %s" % (" ".join(args), err))
		return False, ""
	if proc.returncode != 0:										# uci 自身报错(如配置项不存在)
		log("Run uci %s failed: %s" % (" ".join(args), proc.stderr.strip()))
		return False, ""
	return True, proc.stdout										# 成功: 读配置时结果在 stdout


# 读取 uci 配置项(如 global.global.mode), 不存在或执行失败返回 None
def uci_get(option):
	ok, out = _run_uci(["get", option])
	if not ok:
		return None
	return out.strip()												# 去掉结尾换行


# 设置 uci 配置项(只写入, 不会提交), 必须调用 uci_commit 后才会真正生效, 成功返回 True
# 多改几项后再调一次 uci_commit 提交, 避免每改一项提交一次
def uci_set(option, value):
	return _run_uci(["set", "%s=%s" % (option, value)])[0]


# 提交 uci 修改使配置持久化, config 为配置文件路径或名称(如 global), 成功返回 True
def uci_commit(config):
	return _run_uci(["commit", config])[0]
