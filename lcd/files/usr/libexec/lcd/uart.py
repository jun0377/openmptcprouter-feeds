# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 串口屏的串口操作: 打开并配置为 raw 8N1、下发指令、按结束符切分收到的指令帧
#
# 依赖 logger 模块记录收发内容, 不依赖 lcd.py(主程序以 __main__ 名运行, 引用它会重复执行)
#

import os									# 串口的 open/read/write/close
import termios								# 配置串口波特率、数据位、校验与流控

from logger import log						# 收发内容记入日志, 便于与屏侧工程对照排查

FRAME_END = b"\xff\xff\xff"					# 指令结束符


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
	os.write(fd, command.encode("utf-8") + FRAME_END)				# 屏侧字库为 UTF-8(weiruanYH-UTF8-16), 含中文的指令须按 UTF-8 下发


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
