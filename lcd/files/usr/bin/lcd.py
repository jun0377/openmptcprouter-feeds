#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 串口屏后台进程: 接收并处理触摸串口屏发来的指令, 必要时向屏下发握手指令
#
# 屏幕: 淘晶驰 TJC8548X250 (854x480), uart4 -> /dev/ttyAMA4, 115200 8N1
# 协议: 淘晶驰/Nextion 兼容, 屏侧用 prints 发来的 ASCII 字符串即一条指令, 以 0xFF 0xFF 0xFF 结束
#

import os									# 串口与日志文件的 open/read/close, 以及日志写入
import select								# select(): 带超时等待串口可读, 避免 read 阻塞主循环
import signal								# 注册 SIGINT/SIGTERM/SIGHUP, 实现优雅退出
import subprocess							# 调用 uci 命令读写系统配置
import termios								# 配置串口波特率、数据位、校验与流控
import time									# 时间戳、单调时钟与休眠

UART_DEV = "/dev/ttyAMA4"					# uart4, 见 docs/018-屏幕.md
UART_BAUD = 115200							# 串口屏波特率(仅用于启动日志, 实际配置见 open_uart)
RECONNECT_DELAY = 3							# 串口打开失败后的重试间隔(秒)
READ_TIMEOUT = 0.2							# select 等待串口数据的时间(秒)
LOG_FILE = "/var/log/lcd.log"				# 日志文件路径
LOG_MAX_SIZE = 512 * 1024					# 日志文件大小上限(字节), 超出后从头覆盖

FRAME_END = b"\xff\xff\xff"					# 指令结束符

UCI_TIMEOUT = 5								# 单条 uci 命令的超时(秒), 防止 uci 卡住阻塞主循环

running = True								# 主循环运行标志, 收到退出信号时置为 False


# 日志
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


# 打开串口并配置为 raw 8N1, 返回文件描述符
def open_uart(dev):
	fd = os.open(dev, os.O_RDWR | os.O_NOCTTY | os.O_NONBLOCK)		# 读写、不设为控制终端、非阻塞
	try:
		attrs = termios.tcgetattr(fd)								# 读取当前串口参数
	except termios.error:											# 参数读取失败说明设备异常
		os.close(fd)												# 先关闭 fd, 避免泄漏
		raise														# 交给 main 记日志并重试

	attrs[0] = 0													# iflag: 关闭输入处理
	attrs[1] = 0													# oflag: 关闭输出处理
	attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL			# 8 位数据, 忽略调制解调器控制线
	attrs[3] = 0													# lflag: 非规范模式, 不回显
	attrs[4] = termios.B115200										# 输入波特率
	attrs[5] = termios.B115200										# 输出波特率
	attrs[6][termios.VMIN] = 0										# 读操作立即返回, 由 select 决定何时读
	attrs[6][termios.VTIME] = 0										# 配合 VMIN=0: 不做读超时等待
	termios.tcsetattr(fd, termios.TCSANOW, attrs)					# 参数立即生效
	termios.tcflush(fd, termios.TCIOFLUSH)							# 清掉打开瞬间可能残留的收发数据
	return fd														# 返回配置好的描述符

# 向串口屏下发一条指令: command 为不含结束符的命令文本, 由本函数补上 FF FF FF
def uart_send(fd, command):
	log("Send Cmd: %s" % command)									# 先记录本次下发的命令, 便于与屏侧工程对照排查
	os.write(fd, command.encode("ascii") + FRAME_END)				# 写出错由 handle_frame 统一兜底


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


# 设置 uci 配置项(只写入, 不会提交), 必须调用uci_commit后才会真正生效
def uci_set(option, value):
	return _run_uci(["set", "%s=%s" % (option, value)])[0]

# 提交 uci 修改使配置持久化, config 为配置文件路径或名称(如 global), 成功返回 True
def uci_commit(config):
	return _run_uci(["commit", config])[0]

# 收到指令进行解析, 按 FF FF FF 结束符从字节流中切分指令帧
class FrameParser:
	def __init__(self):
		self.buffer = bytearray()									# 存放尚未凑成完整帧的字节

	def feed(self, data):
		frames = []													# 本次解析出的完整帧
		self.buffer.extend(data)									# 先追加到残留缓冲
		while True:
			end = self.buffer.find(FRAME_END)						# 查找结束符位置
			if end < 0:												# 未找到: 帧还不完整
																	# 迟迟等不到结束符时丢弃历史数据, 避免缓冲区无限增长
				if len(self.buffer) > 1024:							# 超过 1KB 仍未成帧, 视为噪声
					del self.buffer[:-16]							# 只保留最后 16 字节
				break												# 等下次 feed 再拼接
			frames.append(bytes(self.buffer[:end]))					# 结束符之前的内容即一帧
			del self.buffer[:end + len(FRAME_END)]					# 连同结束符一起移出缓冲
		return frames												# 返回本次结果(可能为空列表)

# 解析指令并路由到相应的处理函数
def handle_frame(fd, frame):
	if not frame:													# 空帧(只有结束符)直接忽略
		return

	text = frame.decode("utf-8", "replace")							# 整帧就是一条字符串指令
	log("Recv Cmd: %s" % text)										# 先记录收到的指令, 便于对照屏侧工程排查
	handler = TEXT_HANDLERS.get(text)								# 查指令分发表(定义见"指令处理"一节)
	if handler is None:												# 未登记的指令: 只记日志, 不猜语义
		log("Unknown Cmd: %s" % text)
		return

	try:
		handler(fd, text)											# 统一签名: 处理函数自己解释指令
	except Exception as err:										# 单条指令出错不应拖垮整个进程
		log("Handle Cmd %s failed: %s" % (text, err))


# 指令处理
# 处理函数签名统一为 (fd, text): fd 为串口描述符, text 为解码后的指令字符串

# 屏幕仍在开机动画界面, 进入主界面
def handle_booting(fd, text):
	uart_send(fd, "n0.val=1")										# 置位握手变量, 屏下次开机动画结束即上报 Ready 并跳到主界面
	mode = uci_get("global.global.mode")
	if mode == "single":
		uart_send(fd, "BtnModeDirect.val=1")
	elif mode == "aggregate":
		uart_send(fd, "BtnModeAggre.val=1")
	elif mode == "balance":
		uart_send(fd, "BtnModeSatell.val=1")

# 开机动画已完成, 即将进入主页面
def handle_ready_report(fd, text):
	log("Screen ready, entering main page")

# 在聚合模式页面时,获取聚合模式页面的所有状态
def handle_GetAggregateStatus(fd, text):
	pass

# 指令分发表: 字符串指令 -> 处理函数
# 新增指令只需在此登记一行并写一个同签名的处理函数, handle_frame 无需改动
# 注意 prints 无结束符, 屏侧需紧跟一条 printh ff ff ff 才能被 FrameParser 切成帧
TEXT_HANDLERS = {
	"Booting": handle_booting,								# 等待 n0.val 握手, 仍在播动画
	"Ready": handle_ready_report,							# 握手完成, 准备进入主页
	"GetAggregateStatus": handle_GetAggregateStatus,		# 在聚合模式页面时,获取聚合模式页面的所有状态
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
