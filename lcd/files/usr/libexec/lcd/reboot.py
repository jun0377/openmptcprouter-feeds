# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 重启设备: 处理屏上页脚「重启设备」按钮(二级确认后)发来的 Reboot 指令
#
# 交互见 design.html 的「重启设备」二级确认弹窗, 屏侧确认后才发 Reboot
#
# 本模块由 lcd.py 通过 sys.path 引入(打包装到 /usr/libexec/lcd, 见 Makefile 的 install 段),
# 只负责执行重启, 不碰串口:
#   - 串口发送与日志出口统一由 lcd.py 负责, 两个模块不互相 import
#     (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#

import subprocess							# 调用系统 reboot

from logger import log						# 失败原因记进日志(与 uci.py 同一套用法)

REBOOT_TIMEOUT = 5							# reboot 命令的超时(秒), 防止命令卡住后主循环不再响应屏

REBOOT_CMD = ["reboot"]						# 系统重启命令(busybox + procd 负责后续关机流程)


# 重启本机: 命令已发出返回 True, 失败返回 False(失败原因已记日志)
def reboot_device():
	try:
		subprocess.run(REBOOT_CMD, capture_output=True, text=True, timeout=REBOOT_TIMEOUT)
	except (OSError, subprocess.SubprocessError) as err:			# reboot 不存在、超时、被信号杀掉等
		log("Run reboot failed: %s" % err)
		return False
	return True														# 命令返回后系统随即重启, 本进程也会被结束
