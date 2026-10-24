# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 恢复出厂设置: 处理屏上「恢复出厂设置」二级确认后发来的 FactoryReset 指令
#
# 交互见 design.html 的屏幕 08(确认弹窗)与屏幕 10(恢复中动画):
# 屏侧确认后先切到动画页, 再发 FactoryReset, 然后等待主控重启断电
#
# 本模块由 lcd.py 通过 sys.path 引入(打包装到 /usr/libexec/lcd, 见 Makefile 的 install 段),
# 只负责清 overlay 与重启, 不碰串口:
#   - 串口发送与日志出口统一由 lcd.py 负责, 两个模块不互相 import
#     (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#

import os									# 存在性检查与 sync
import subprocess							# 调用 jffs2reset / reboot

from logger import log						# 执行结果记进日志(与 reboot.py 同一套用法)

# 新老固件两种入口: 新版直接用 jffs2reset, 老版只有 firstboot(内部也是调 jffs2reset)
RESET_CMDS = (["/sbin/jffs2reset", "-y"], ["/sbin/firstboot", "-y"])
RESET_TIMEOUT = 30							# 擦除 overlay 需要时间, 超时视为失败
REBOOT_TIMEOUT = 5							# reboot 命令的超时, 防止卡住
REBOOT_CMD = ["reboot"]

_running = False							# 屏可能重复下发, 只执行一次


# 恢复出厂: 清空 overlay 并重启; 返回 True 表示复位命令已执行
def factory_reset():
	global _running

	if _running:											# 已在执行, 忽略重复指令
		log("Factory reset already in progress, ignore")
		return False

	_running = True
	cmd = next((c for c in RESET_CMDS if os.path.exists(c[0])), None)
	if cmd is None:
		log("Factory reset failed: neither jffs2reset nor firstboot found")
		_running = False
		return False

	log("Factory reset requested by screen, run %s" % " ".join(cmd))
	os.sync()												# 先把缓存落盘, 避免复位时丢日志

	try:
		ret = subprocess.run(cmd, capture_output=True, text=True, timeout=RESET_TIMEOUT)
	except subprocess.TimeoutExpired:
		log("Factory reset timed out after %ds" % RESET_TIMEOUT)
		_running = False
		return False
	except (OSError, subprocess.SubprocessError) as err:	# 命令不存在、被信号杀掉等
		log("Run %s failed: %s" % (cmd[0], err))
		_running = False
		return False

	if ret.returncode != 0:
		log("Factory reset failed: %s exit %d, stderr: %s" %
			(cmd[0], ret.returncode, (ret.stderr or "").strip()))
		_running = False
		return False

	# jffs2reset 正常会自行重启; 命令能返回说明还没重启, 这里补发一次 reboot
	log("Overlay erased, rebooting")
	os.sync()
	try:
		subprocess.run(REBOOT_CMD, capture_output=True, text=True, timeout=REBOOT_TIMEOUT)
	except (OSError, subprocess.SubprocessError) as err:
		log("Run reboot failed: %s" % err)
		_running = False
		return False
	return True													# 命令返回后系统随即重启, 本进程也会被结束
