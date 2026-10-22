#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 淘晶驰(TJC)串口屏固件升级工具
#
# 由 /etc/init.d/lcd 在检测到 /root/*.tft 时作为 procd 实例启动:
#   1. 按 HMI 下载协议联机、校验 FLASH 大小、分块下发 tft 文件
#   2. 依次尝试 DOWNLOAD_BAUDS 里的波特率, 每种尝试 ATTEMPTS_PER_BAUD 次
#   3. 成功后把文件重命名为 <name>.tft.<日期时间>, 避免下次开机重复升级
#   4. 全部失败后重命名为 <name>.tft.failed.<日期时间>
#   5. 结束时 exec 成 /usr/bin/lcd.py, PID 不变, 不需要重启 lcd 服务
#
# 协议参考: http://wiki2.tjc1688.com/advanced/hmi_download_protocol.html
#

import argparse								# 命令行参数
import datetime							# 生成重命名后缀
import errno								# 区分 EINTR/EAGAIN
import fcntl								# 升级互斥锁
import os									# 串口/文件操作
import select								# 串口读超时
import sys									# 退出
import termios							# 串口配置与波特率
import time								# 延时与超时计算

FRAME_END = b"\xff\xff\xff"				# 指令结束符
EXIT_RECMOD = b"DRAKJHSUYDGBNCJHGJKSHBDN"	# 退出主动解析模式的魔数
EMPTY_CMD = b"\x00\xff\xff\xff"			# 联机前先发一条空指令

DEFAULT_DEV = "/dev/ttyAMA4"				# uart4, 与 lcd.py 保持一致
RUNTIME_BAUD = 115200						# 屏幕运行波特率, lcd.py 固定使用该值

# 依次尝试的下载波特率(从高到低), 以及每种波特率的尝试次数
# 921600 实测可用; 460800 在本型号(TJC8548X250, 固件196)上会握手失败, 不再尝试
DOWNLOAD_BAUDS = (921600, 460800, 230400, 115200)
ATTEMPTS_PER_BAUD = 2

CHUNK_SIZE = 4096						# 协议规定每包 4096 字节
CHUNK_TIMEOUT = 5.0						# 单包应答超时(秒)
START_ACK_TIMEOUT = 5.0					# whmi-wri 之后首个 0x05 的超时(秒)
SCAN_BAUDS = (9600, 19200, 38400, 57600, 230400, 460800, 921600)	# 联机失败时的恢复扫描

LCD_BIN = "/usr/bin/lcd.py"				# 升级结束后要接管的 UI 进程
LOCK_FILE = "/var/run/lcd-update.lock"	# 防止两个升级进程同时操作串口

# 日志: 输出到 stdout 与 /var/log/lcd/lcd.log, 写满 1MB 备份为 lcd.log.rotate
LOG_DIR = "/var/log/lcd"
LOG_FILE = LOG_DIR + "/lcd.log"
LOG_ROTATE = LOG_DIR + "/lcd.log.rotate"
LOG_MAX_SIZE = 1024 * 1024

NO_EXEC = False							# 调试用: 为 True 时结束后不 exec 成 lcd.py

_log_fd = None							# 日志文件描述符, 打开失败时保持 None


# 打开日志文件, 失败时退化为只输出到 stdout
def open_log():
	global _log_fd
	try:
		os.makedirs(LOG_DIR, exist_ok=True)
		_log_fd = os.open(LOG_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
	except OSError:
		_log_fd = None


# 写满时: 关闭当前文件, 覆盖备份文件, 再从空文件重新开始
def _rotate_log_file():
	global _log_fd
	if _log_fd is not None:
		try:
			os.close(_log_fd)
		except OSError:
			pass
		_log_fd = None
	try:
		os.replace(LOG_FILE, LOG_ROTATE)	# 覆盖上一份备份
	except OSError:
		pass
	try:
		_log_fd = os.open(LOG_FILE, os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o644)
	except OSError:
		_log_fd = None


# 日志出口: 同时输出到 stdout 与日志文件
def log(msg):
	line = "[lcd-update] %s\n" % msg
	print(line, end="", flush=True)
	if _log_fd is None:
		return
	data = line.encode("utf-8")
	try:
		if os.lseek(_log_fd, 0, os.SEEK_END) + len(data) > LOG_MAX_SIZE:
			_rotate_log_file()
		if _log_fd is not None:
			os.write(_log_fd, data)
	except OSError:						# 磁盘满/文件被删等写失败不影响升级流程
		pass


# 升级流程结束后把当前进程替换成 lcd.py, 保持 PID 不变, 由 procd 继续监管
def exec_lcd():
	if NO_EXEC:
		log("no-exec mode, exit")
		sys.exit(0)

	try:
		os.execv(LCD_BIN, [LCD_BIN])
	except OSError:
		# lcd.py 的 shebang 不可用时退回显式调用 python3
		try:
			os.execvp("python3", ["python3", LCD_BIN])
		except OSError as e:
			log("exec %s failed: %s" % (LCD_BIN, e))
			sys.exit(1)


# 加升级锁: 已有升级在跑时直接退出, 由持锁进程负责升级和启动 UI
def acquire_lock():
	try:
		fd = os.open(LOCK_FILE, os.O_CREAT | os.O_RDWR, 0o600)
	except OSError as e:
		log("open lock %s failed: %s, continue" % (LOCK_FILE, e))
		return 0
	try:
		fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
	except OSError:
		os.close(fd)
		return None
	return fd


# 扫描待升级文件: 只认 /root/*.tft, 忽略上传中的 *.part 与已重命名的历史文件
def scan_upgrade_file():
	best = ""
	best_mtime = 0
	try:
		names = os.listdir("/root")
	except OSError:
		return ""
	for name in names:
		if not name.endswith(".tft"):
			continue
		path = os.path.join("/root", name)
		if not os.path.isfile(path):
			continue
		mtime = os.path.getmtime(path)
		if mtime > best_mtime:
			best = path
			best_mtime = mtime
	return best


# 把 tft 文件重命名: 成功加日期后缀, 失败加 .failed.<日期> 后缀
def rename_file(path, failed):
	ts = datetime.datetime.now().strftime("%Y%m%d-%H%M%S")
	suffix = ".failed." if failed else "."
	new_path = "%s%s%s" % (path, suffix, ts)
	try:
		os.replace(path, new_path)
		log("renamed %s -> %s" % (path, new_path))
	except OSError as e:
		log("rename %s failed: %s" % (path, e))


# 关闭串口, 忽略重复关闭等错误
def close_uart(fd):
	try:
		os.close(fd)
	except OSError:
		pass


# 把波特率数字转成 termios 常量
def baud_const(baud):
	const = getattr(termios, "B%d" % baud, None)
	if const is None:
		raise ValueError("unsupported baud %d" % baud)
	return const


# 配置串口为 raw 8N1; drain=True 时等待发送缓冲区清空后再切换波特率
def configure_uart(fd, baud, drain=False):
	attrs = termios.tcgetattr(fd)
	attrs[0] = 0											# iflag: 关闭输入处理
	attrs[1] = 0											# oflag: 关闭输出处理
	attrs[2] = termios.CS8 | termios.CREAD | termios.CLOCAL	# 8 位数据, 忽略调制解调器控制线
	attrs[3] = 0											# lflag: 非规范模式, 不回显
	baud_val = baud_const(baud)
	attrs[4] = baud_val										# 输入波特率
	attrs[5] = baud_val										# 输出波特率
	attrs[6][termios.VMIN] = 0								# 读操作立即返回
	attrs[6][termios.VTIME] = 0								# 不做读超时等待
	action = termios.TCSADRAIN if drain else termios.TCSANOW
	termios.tcsetattr(fd, action, attrs)


# 打开串口并配置为 raw 8N1
def open_uart(dev, baud):
	fd = os.open(dev, os.O_RDWR | os.O_NOCTTY)
	configure_uart(fd, baud)
	termios.tcflush(fd, termios.TCIOFLUSH)
	return fd


# 完整写出一段数据, 处理短写与 EINTR
def write_all(fd, data):
	view = memoryview(data)
	while view:
		try:
			n = os.write(fd, view)
		except OSError as e:
			if e.errno == errno.EINTR:
				continue
			raise
		view = view[n:]


# 读到 FF FF FF 为止, 返回结束符之前的内容; 超时返回 None
def read_frame(fd, timeout):
	buf = b""
	deadline = time.monotonic() + timeout
	while True:
		remain = deadline - time.monotonic()
		if remain <= 0:
			return None
		rlist, _, _ = select.select([fd], [], [], remain)
		if not rlist:
			return None
		try:
			chunk = os.read(fd, 256)
		except OSError as e:
			if e.errno in (errno.EINTR, errno.EAGAIN):
				continue
			raise
		if not chunk:
			continue
		buf += chunk
		end = buf.find(FRAME_END)
		if end >= 0:
			return buf[:end]
		if len(buf) > 4096:					# 一直凑不成帧时丢弃历史噪声
			buf = buf[-64:]


# 解析 comok 应答: comok 1,地址,型号,固件版本,芯片编码,序列号,FLASH大小
def parse_comok(frame):
	if frame is None:
		return None
	idx = frame.lower().find(b"comok")
	if idx < 0:
		return None
	text = frame[idx:].decode("ascii", "ignore").strip()
	parts = [p.strip() for p in text.split(",")]
	info = {"model": "", "firmware": "", "flash": 0, "raw": text}
	if len(parts) > 2:
		info["model"] = parts[2]
	if len(parts) > 3:
		info["firmware"] = parts[3]
	if len(parts) > 6:
		try:
			info["flash"] = int(parts[6])
		except ValueError:
			info["flash"] = 0
	return info


# 发送联机指令: 先发空指令, 再发 connect+结束符; 失败时先退出主动解析模式再试
def handshake(fd, baud):
	# 每次尝试的最短等待时间(ms): 1000000/波特率 + 30, 这里再留一点余量
	wait = 1000000.0 / baud / 1000.0 + 0.3

	termios.tcflush(fd, termios.TCIFLUSH)	# 丢掉上一次尝试残留的字节
	write_all(fd, EMPTY_CMD)
	write_all(fd, b"connect" + FRAME_END)
	info = parse_comok(read_frame(fd, wait))
	if info:
		return info

	# 屏幕可能处于主动解析模式: 发魔数强制退出, 再按同样流程联机
	termios.tcflush(fd, termios.TCIFLUSH)
	write_all(fd, EXIT_RECMOD + FRAME_END)
	write_all(fd, EMPTY_CMD)
	write_all(fd, b"connect" + FRAME_END)
	return parse_comok(read_frame(fd, wait))


# 联机: 先按运行时波特率, 失败后扫描常见波特率(应对上次升级中断改了波特率)
def connect_screen(dev):
	bauds = [RUNTIME_BAUD] + [b for b in SCAN_BAUDS if b != RUNTIME_BAUD]
	for baud in bauds:
		try:
			fd = open_uart(dev, baud)
		except OSError as e:
			log("open %s failed: %s" % (dev, e))
			return None, None
		except ValueError as e:
			log("skip baud %d: %s" % (baud, e))
			continue
		info = handshake(fd, baud)
		if info:
			log("connected at %d, comok: %s" % (baud, info["raw"]))
			log("model=%s firmware=%s flash=%d" %
				(info["model"], info["firmware"], info["flash"]))
			return fd, info
		close_uart(fd)
	return None, None


# 读串口当前可用的数据, 超时返回空字节串
def read_available(fd, timeout):
	rlist, _, _ = select.select([fd], [], [], timeout)
	if not rlist:
		return b""
	try:
		return os.read(fd, 256)
	except OSError as e:
		if e.errno in (errno.EINTR, errno.EAGAIN):
			return b""
		raise


# 等待屏幕回一个 0x05 应答; 切换波特率后可能混入旧波特率的噪声, 忽略非 0x05 字节
def wait_ack(fd, timeout):
	deadline = time.monotonic() + timeout
	while True:
		remain = deadline - time.monotonic()
		if remain <= 0:
			return False
		data = read_available(fd, remain)
		if not data:
			continue
		if b"\x05" in data:
			return True
		log("ignore unexpected ack bytes: %s" % data.hex())


# 按 HMI 下载协议下发整个 tft 文件
def download(fd, path, size, dl_baud):
	cmd = "whmi-wri %d,%d,0" % (size, dl_baud)
	log("send: %s" % cmd)
	write_all(fd, cmd.encode("ascii") + FRAME_END)

	# 发完下载指令立即切到下载波特率.
	# 注意不能 tcflush: 屏幕约 250ms 后会在新波特率上回一个 0x05, 清缓冲会把应答丢掉.
	configure_uart(fd, dl_baud, drain=True)

	if not wait_ack(fd, START_ACK_TIMEOUT):
		log("no start ack after whmi-wri (screen may stay in download mode, power-cycle it)")
		return False

	sent = 0
	next_report = 10
	with open(path, "rb") as f:
		while True:
			data = f.read(CHUNK_SIZE)
			if not data:
				break
			write_all(fd, data)
			if not wait_ack(fd, CHUNK_TIMEOUT):
				log("no chunk ack at %d/%d" % (sent, size))
				return False
			sent += len(data)
			pct = (sent * 100 // size) if size else 100
			if pct >= next_report:
				log("progress %d%% (%d/%d)" % (pct, sent, size))
				next_report = pct - (pct % 10) + 10

	return sent == size


def main():
	open_log()

	parser = argparse.ArgumentParser(description="TJC HMI firmware updater")
	parser.add_argument("--file", default="", help="tft file to download")
	parser.add_argument("--dev", default=DEFAULT_DEV, help="serial device")
	parser.add_argument("--baud", type=int, default=0,
		help="only try this download baud")
	parser.add_argument("--bauds", default="",
		help="comma separated download bauds, default: %s" %
			",".join(str(b) for b in DOWNLOAD_BAUDS))
	parser.add_argument("--no-exec", action="store_true",
		help="debug: do not exec lcd.py after upgrade")
	args = parser.parse_args()

	global NO_EXEC
	NO_EXEC = args.no_exec

	if acquire_lock() is None:
		log("another update is running, exit")
		return 0

	# 下载波特率列表: --bauds 优先, 其次 --baud(只试一个), 否则用文件顶部的默认列表
	if args.bauds:
		baud_list = []
		for item in args.bauds.split(","):
			item = item.strip()
			if not item:
				continue
			try:
				baud_list.append(int(item))
			except ValueError:
				log("ignore invalid baud: %s" % item)
	elif args.baud:
		baud_list = [args.baud]
	else:
		baud_list = list(DOWNLOAD_BAUDS)

	# 过滤掉主机串口不支持的波特率, 避免屏幕切到主机跟不上的速率
	usable_bauds = []
	for baud in baud_list:
		try:
			baud_const(baud)
			usable_bauds.append(baud)
		except ValueError as e:
			log("host does not support %s, skip" % e)
	if not usable_bauds:
		log("no usable download baud, fallback to %d" % RUNTIME_BAUD)
		usable_bauds = [RUNTIME_BAUD]

	# 文件可能已被上一次成功升级重命名, 这里再扫一遍以便被 procd 重新拉起时仍能工作
	path = args.file
	if not path or not os.path.isfile(path):
		path = scan_upgrade_file()
	if not path:
		log("no upgrade file, start lcd")
		exec_lcd()
		return 0

	size = os.path.getsize(path)
	log("upgrade file: %s (%d bytes)" % (path, size))
	if size <= 0:
		log("empty file, mark as failed")
		rename_file(path, failed=True)
		exec_lcd()
		return 0

	# 依次尝试每种下载波特率, 每种最多 ATTEMPTS_PER_BAUD 次
	for dl_baud in usable_bauds:
		for attempt in range(1, ATTEMPTS_PER_BAUD + 1):
			log("download baud %d, attempt %d/%d" % (dl_baud, attempt, ATTEMPTS_PER_BAUD))

			fd, info = connect_screen(args.dev)
			if fd is None:
				log("connect failed")
				time.sleep(0.5)
				continue

			try:
				# FLASH 放不下时没必要继续尝试
				if info and info["flash"] and size > info["flash"]:
					log("file is larger than screen flash (%d > %d)" % (size, info["flash"]))
					rename_file(path, failed=True)
					exec_lcd()
					return 0

				if download(fd, path, size, dl_baud):
					log("upgrade succeeded")
					close_uart(fd)
					fd = None
					time.sleep(3)			# 等待屏幕重启进入新工程
					rename_file(path, failed=False)
					exec_lcd()
					return 0
			finally:
				if fd is not None:
					close_uart(fd)

			time.sleep(0.5)

	log("upgrade failed, tried bauds: %s" % ",".join(str(b) for b in usable_bauds))
	rename_file(path, failed=True)
	exec_lcd()
	return 0


if __name__ == "__main__":
	try:
		sys.exit(main())
	except Exception as err:			# 未捕获异常也写进日志, 避免只留在被丢弃的 stderr
		log("fatal: %r" % err)
		raise
