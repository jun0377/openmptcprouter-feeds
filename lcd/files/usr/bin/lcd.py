#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 串口屏后台进程: 接收并处理触摸串口屏发来的指令, 必要时向屏下发握手指令
#
# 屏幕: 淘晶驰 TJC8548X250 (854x480), uart4 -> /dev/ttyAMA4, 115200 8N1
# 协议: 淘晶驰/Nextion 兼容, 屏侧用 prints 发来的 ASCII 字符串即一条指令, 以 0xFF 0xFF 0xFF 结束
#
# 依赖的私有模块打包装到 /usr/libexec/lcd, 源码见 files/usr/libexec/lcd/:
#   logger.py     日志, 同时输出到 stdout 与 /var/log/lcd.log
#   uart.py       串口的打开/下发/按结束符切帧
#   uci.py        uci 配置读写
#   modeDirect.py 直连模式页面(屏幕01)的状态
#   modeAgg.py    聚合模式页面(屏幕02)的状态
#   ctrl-main.py  运维模式首页(屏幕04 链路设置)的状态
#   ctrl-simx.py  运维模式 SIMx链路(屏幕05)的状态
#   reboot.py     页脚「重启设备」的重启动作
#   systemSettings.py 系统设置页面(页脚)的状态
#   version.py    版本信息页面(页脚弹窗)的状态
#
# 模式切换与状态查询的指令见 docs/018-屏幕.md 第4节

import importlib								# 加载文件名带连字符的页面模块(见下面的页面模块导入)
import os									# 主循环读串口, 退出时关闭描述符
import select								# select(): 带超时等待串口可读, 避免 read 阻塞主循环
import signal								# 注册 SIGINT/SIGTERM/SIGHUP, 实现优雅退出
import sys									# 把私有库目录加入模块搜索路径
import time									# 单调时钟与小步休眠

# 私有库目录(打包装到 /usr/libexec/lcd, 见 Makefile 的 install 段)
# 可用环境变量覆盖, 便于在开发机上直接运行: LCD_LIB_DIR=./files/usr/libexec/lcd python3 lcd.py
LIB_DIR = os.environ.get("LCD_LIB_DIR", "/usr/libexec/lcd")
sys.path.insert(0, LIB_DIR)					# 必须早于下面 import 私有模块

# 页面模块: 文件名里带连字符(ctrl-main.py / ctrl-simx.py)不能写 import 语句, 用 importlib 按名字加载
CtrlStatus = importlib.import_module("ctrl-main").CtrlStatus		# 运维模式首页(屏幕04 链路设置)的状态
SimxStatus = importlib.import_module("ctrl-simx").SimxStatus		# 运维模式 SIMx链路(屏幕05)的状态
from modeAgg import AggregateStatus					# 聚合模式页面(屏幕02)的状态
from logger import log, open_log						# 日志输出
from modeDirect import DirectStatus						# 直连模式页面(屏幕01)的状态
from reboot import reboot_device						# 重启本机
from uart import FrameParser, open_uart, uart_send		# 串口操作
from uci import uci_get									# uci 配置读取
from systemSettings import SystemSettings				# 系统设置页面(页脚)的状态
from version import VersionStatus						# 版本信息页面(页脚弹窗)的状态

UART_DEV = "/dev/ttyAMA4"					# uart4, 见 docs/018-屏幕.md
UART_BAUD = 115200							# 串口屏波特率(仅用于启动日志, 实际配置见 uart.open_uart)
RECONNECT_DELAY = 3							# 串口打开失败后的重试间隔(秒)
READ_TIMEOUT = 0.2							# select 等待串口数据的时间(秒)

running = True								# 主循环运行标志, 收到退出信号时置为 False

# 屏的回报码(单字节 + FF FF FF): 屏收到不合法的指令时会回一字节, 用于排查下发内容
# 常见值见 Nextion/TJC 指令集第 7 节 "Format of Nextion Return Data"
RETURN_CODES = {
	0x00: "无效指令",
	0x01: "指令成功",
	0x02: "控件/部件 ID 无效",
	0x03: "页面 ID 无效",
	0x04: "图片 ID 无效",
	0x05: "字体 ID 无效",
	0x11: "波特率设置无效",
	0x12: "曲线控件 ID 或通道号无效",
	0x1A: "变量名或属性名无效",				# 控件不存在、属性名写错、或控件不在当前页
	0x1B: "变量操作无效",
	0x1C: "赋值失败",
	0x1D: "EEPROM 操作失败",
	0x1E: "参数数量无效",
	0x1F: "IO 操作失败",
	0x20: "转义字符无效",
	0x23: "变量名过长",
	0x24: "串口缓冲区溢出",
}


# 解析指令并路由到相应的处理函数
def handle_frame(fd, frame):
	if not frame:													# 空帧(只有结束符)直接忽略
		return

	if len(frame) == 1 and frame[0] in RETURN_CODES:				# 单字节帧是屏的回报, 不是指令
		log("Screen Return: 0x%02x %s" % (frame[0], RETURN_CODES[frame[0]]))
		return

	text = frame.decode("utf-8", "replace")							# 整帧就是一条字符串指令
	log("Recv Cmd: %s" % text)										# 先记录收到的指令, 便于对照屏侧工程排查
	handler = TEXT_HANDLERS.get(text)								# 查指令分发表(定义见"指令处理"一节)
	if handler is None:												# 未登记的指令: 连同原始字节记下来
		log("Unknown Cmd: %r len=%d hex=%s" % (text, len(frame), frame.hex()))
		return

	try:
		handler(fd, text)											# 统一签名: 处理函数自己解释指令
	except Exception as err:										# 单条指令出错不应拖垮整个进程
		log("Handle Cmd %s failed: %s" % (text, err))


# 指令处理
# 处理函数签名统一为 (fd, text): fd 为串口描述符, text 为解码后的指令字符串

# 屏幕仍在开机动画界面: 通知屏退出开机动画, 并按当前工作模式进入对应的模式主页
def handle_booting(fd, text):
	uart_send(fd, "BootFlag.val=1")										# 屏收到后退出开机动画
	mode = uci_get("global.global.mode")
	if mode == "single":
		uart_send(fd, "direct_mode=1")									# 直连模式主页
	elif mode == "aggregate":
		uart_send(fd, "agg_mode=1")										# 聚合模式主页
	elif mode == "balance":
		uart_send(fd, "satellite_mode=1")								# 卫星模式主页

# 开机动画已完成, 即将进入主页面
def handle_ready_report(fd, text):
	log("Screen ready, entering main page")

# 在直连模式页面时,获取直连模式页面的所有状态
def handle_GetDirectModeStatus(fd, text):
	for command in DirectStatus.collect().commands():			# 采集状态并生成待下发的指令序列
		uart_send(fd, command)									# 逐条下发

# 在聚合模式页面时,获取聚合模式页面的所有状态
def handle_GetAggregateStatus(fd, text):
	for command in AggregateStatus.collect().commands():		# 采集状态并生成待下发的指令序列
		uart_send(fd, command)									# 逐条下发, 串口与日志由 uart.py 统一负责

# 在版本信息页面时,获取版本信息
def handle_GetVersion(fd, text):
	for command in VersionStatus.collect().commands():			# 采集版本信息并生成待下发的指令序列
		uart_send(fd, command)									# 逐条下发

# 在系统设置页面时,获取管理平台地址(GetServerAddr)与状态上报频率(GetReportFre)
# 两个查询下发的是同一份页面状态(地址 + 四个频率按钮), 保证屏上两项始终一致
def handle_GetSystemSettings(fd, text):
	for command in SystemSettings.collect().commands():			# 采集配置并生成待下发的指令序列
		uart_send(fd, command)									# 逐条下发

# 在运维模式->链路设置页面时,获取所有链路与基站的状态
def handle_GetAllStatus(fd, text):
	for command in CtrlStatus.collect().commands():				# 采集状态并生成待下发的指令序列
		uart_send(fd, command)									# 逐条下发

# 在运维模式->链路设置->SIMx链路页面时,获取该链路的设置参数
# 指令形如 GetSim1Status, 其中的数字就是屏上的卡槽号(与 uci 的 simN 段名一致)
def handle_GetSimxStatus(fd, text):
	name = "sim" + text[len("GetSim"):-len("Status")]			# GetSim1Status -> sim1
	for command in SimxStatus.collect(name).commands():			# 采集该链路的设置并生成待下发的指令序列
		uart_send(fd, command)									# 逐条下发

# 页脚「重启设备」二级确认后, 重启本机(屏侧随后自行显示重启中的界面)
def handle_reboot(fd, text):
	log("Reboot requested by screen")							# 重启前先记一条日志, 便于对照屏上的操作
	reboot_device()												# 成功时系统随即重启, 失败原因由 reboot.py 记日志

# 指令分发表: 字符串指令 -> 处理函数
# 新增指令只需在此登记一行并写一个同签名的处理函数, handle_frame 无需改动
# 注意 prints 无结束符, 屏侧需紧跟一条 printh ff ff ff 才能被 FrameParser 切成帧
TEXT_HANDLERS = {
	"Booting": handle_booting,										# 等待 BootFlag 握手, 仍在播动画
	"Ready": handle_ready_report,									# 握手完成, 准备进入主页
	"GetDirectModeStatus": handle_GetDirectModeStatus,				# 在直连模式页面时,获取直连模式页面的所有状态
	"GetAggModeStatus": handle_GetAggregateStatus,					# 在聚合模式页面时,获取聚合模式页面的所有状态
	"GetVersion": handle_GetVersion,								# 在版本信息页面时,获取版本信息
	"GetServerAddr": handle_GetSystemSettings,						# 在系统设置页面时,获取管理平台地址与状态上报频率
	"GetReportFre": handle_GetSystemSettings,						# 同上, 两个查询一并下发整页状态
	"GetAllStatus": handle_GetAllStatus,							# 在运维模式->链路设置页面时,获取所有链路与基站状态
	# 运维模式->链路设置->SIMx链路: 5 个卡槽各一条查询指令, 处理函数相同(卡槽号在指令里)
	"GetSim1Status": handle_GetSimxStatus,
	"GetSim2Status": handle_GetSimxStatus,
	"GetSim3Status": handle_GetSimxStatus,
	"GetSim4Status": handle_GetSimxStatus,
	"GetSim5Status": handle_GetSimxStatus,
	"Reboot": handle_reboot,										# 页脚「重启设备」二级确认后, 重启本机
}

# 可被退出信号打断的定时等待
def sleep_until_stopped(seconds):
	end = time.monotonic() + seconds								# 目标时刻
	while running and time.monotonic() < end:						# 未收到退出信号且未到点
		time.sleep(0.1)												# 小步休眠, 保证能及时响应信号

# 主循环
def run_loop(fd):
	parser = FrameParser()											# 每次(重)开串口都用新解析器, 丢弃旧残留

	while running:													# 收到退出信号后 running=False 即跳出
		readable, _, _ = select.select([fd], [], [], READ_TIMEOUT)	# 最多等 READ_TIMEOUT 秒
		if readable:												# 串口有数据可读
			data = os.read(fd, 4096)								# 一次最多读 4KB
			if data:												# 有数据才继续解析
				for frame in parser.feed(data):						# 按 FF FF FF 切帧
					handle_frame(fd, frame)							# 逐帧处理

# 退出进程
def stop(signum, frame):
	global running													# 修改模块级标志
	running = False													# 通知主循环退出


def main():

	for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):		# Ctrl+C / procd stop / 挂断
		signal.signal(sig, stop)									# 统一走优雅退出

	open_log()														# 打开 /var/log/lcd.log(失败仅退化到 stdout)
	log("lcd service started: %s @ %d 8N1" % (UART_DEV, UART_BAUD))	# 记录启动信息

	while running:													# 打开失败则重试, 直到收到退出信号
		try:
			fd = open_uart(UART_DEV)								# 打开并配置串口
		except OSError as err:										# 设备不存在/被占用等
			log("Failed to open %s: %s, retry in %d seconds" % (UART_DEV, err, RECONNECT_DELAY))
			sleep_until_stopped(RECONNECT_DELAY)					# 3秒后重试, 可被退出信号打断的等待
			continue												# 回到 while 重试

		log("Serial port %s ready" % UART_DEV)					 	# 打开成功
		try:
			run_loop(fd)											# 进入主循环, 直到退出或串口异常
		except OSError as err:										# 读/写串口出错(如设备被拔掉)
			log("Serial port error: %s, reopening" % err)
		finally:
			os.close(fd)											# 无论正常结束还是异常, 都关闭 fd

	log("lcd service exited")									 	# 循环结束时的收尾日志


if __name__ == "__main__":											# 被 import 时不执行(便于单测/调试)
	main()
