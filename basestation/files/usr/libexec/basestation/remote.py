#!/usr/bin/env python3
# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 远端命令执行模块: 通过 dropbear 客户端(/usr/bin/ssh, 软链接到 /usr/sbin/dropbear)
# SSH 到远端主机执行命令并取回结果
#
# 主路径: 预置公钥认证(-i 指定私钥), 无密码、非交互
# 备选路径: 公钥不可用/部署有误时回退到伪终端(pty)驱动, 自动应答密码提示
#
# 用法:
#   import remote
#   rc, out, err = remote.run("192.168.16.7", "jun", "ls -l", password="xxx")

import os									# 私钥是否存在判断
import pty									# 伪终端, 用于驱动 dropbear 客户端输入密码
import re									# 输出清洗与错误判定
import select								# pty 读取超时控制
import signal								# 超时后终止子进程
import subprocess							# 公钥路径的执行
import time									# 超时计时

SSH_BIN = os.environ.get("BASESTATION_SSH_BIN", "/usr/bin/ssh")					# dropbear 客户端
KEY_FILE = os.environ.get("BASESTATION_SSH_KEY", "/root/.ssh/id_dropbear")		# 默认私钥
UCI_BIN = os.environ.get("BASESTATION_UCI_BIN", "/sbin/uci")					# uci 命令, 用于读取运行参数
UCI_CONFIG = "basestation"														# 配置文件(见 files/etc/config/basestation)
UCI_SECTION = "remote"															# 配置节

DEFAULT_TIMEOUT = 10						# 单次执行超时默认值(秒)
DEFAULT_MAX_OUTPUT = 64 * 1024				# 输出上限默认值, 防止 pty 无限读取


# 从 UCI 配置读取整型参数: uci 不可用、配置缺失或取值非法时回退默认值
def _uci_get_int(option, default):
	try:
		p = subprocess.run([UCI_BIN, "-q", "get", "%s.%s.%s" % (UCI_CONFIG, UCI_SECTION, option)],
						   stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
						   stderr=subprocess.DEVNULL, timeout=5)
		return int(p.stdout.decode("utf-8", errors="replace").strip())
	except (OSError, ValueError, subprocess.TimeoutExpired):
		return default


TIMEOUT = _uci_get_int("timeout", DEFAULT_TIMEOUT)				# 单次执行超时(秒)
MAX_OUTPUT = _uci_get_int("max_output", DEFAULT_MAX_OUTPUT)		# 输出上限, 防止 pty 无限读取

# dropbear 客户端自身打印的错误行(形如 "ssh: ...")
CLIENT_LINE_PAT = re.compile(r"(?im)^\s*(?:ssh|dbclient)\s*:\s*(.*)$")
# 出现这些关键字说明是认证失败(而非远端命令本身报错)
AUTH_HINT_PAT = re.compile(r"(?i)password|auth|permission denied|failed to read")
# pty 模式下的密码提示(如 "jun@host's password: ")
PASSWORD_PROMPT_PAT = re.compile(rb"password\s*:", re.IGNORECASE)


def _decode(data):
	return data.decode("utf-8", errors="replace")


def _target(host, user):
	return "%s@%s" % (user, host)


# 组装 dropbear 客户端公共参数
#   -y 免 host key 确认   -q 屏蔽远端 banner   -T 不分配远端 pty
def _base_args(host, user, port):
	args = [SSH_BIN, "-y", "-q", "-T"]
	if port:
		args += ["-p", str(port)]
	args += [_target(host, user)]
	return args


# 清洗 pty 输出: 统一换行、去掉密码提示行与密码回显
def _clean(data, pwd=None):
	text = _decode(data).replace("\r\n", "\n").replace("\r", "\n")
	text = re.sub(r"[^\n]*password\s*: ?", "", text, flags=re.IGNORECASE)
	if pwd:
		text = text.replace(pwd, "")
	return text.strip("\n")


# 判定是否为认证失败: dropbear 客户端错误行里含认证关键字
def _looks_auth_fail(err):
	for m in CLIENT_LINE_PAT.finditer(err):
		if AUTH_HINT_PAT.search(m.group(1)):
			return True
	return False


# 主路径: 公钥认证, 非交互执行
def run_key(host, user, cmd, port=None, key=KEY_FILE, timeout=TIMEOUT):
	args = _base_args(host, user, port) + ["-i", key, cmd]
	try:
		p = subprocess.run(args, stdin=subprocess.DEVNULL,
						   stdout=subprocess.PIPE, stderr=subprocess.PIPE,
						   timeout=timeout)
	except subprocess.TimeoutExpired:
		return 124, "", "timeout"
	except OSError as e:
		return 127, "", str(e)
	return p.returncode, _decode(p.stdout), _decode(p.stderr)


# 备选路径: pty 驱动 dropbear 客户端, 自动应答密码提示
def run_password(host, user, pwd, cmd, port=None, timeout=TIMEOUT):
	args = _base_args(host, user, port) + [cmd]
	pid, master = pty.fork()				# 子进程自带控制终端, 客户端才能从 /dev/tty 读密码
	if pid == 0:
		try:
			os.execv(args[0], args)			# 用 dropbear 客户端替换子进程
		except OSError:
			os._exit(127)

	out = bytearray()
	sent = False							# 是否已应答过密码
	killed = False
	deadline = time.monotonic() + timeout
	while True:
		left = deadline - time.monotonic()
		if left <= 0:
			os.kill(pid, signal.SIGKILL)
			killed = True
			break
		r, _, _ = select.select([master], [], [], left)
		if not r:
			continue
		try:
			chunk = os.read(master, 4096)
		except OSError:						# 子进程退出, 从端关闭
			break
		if not chunk:
			break
		out += chunk
		if not sent and PASSWORD_PROMPT_PAT.search(bytes(out)):
			os.write(master, (pwd + "\n").encode())
			sent = True
		if len(out) >= MAX_OUTPUT:
			os.kill(pid, signal.SIGKILL)
			killed = True
			break
	os.close(master)

	_, status = os.waitpid(pid, 0)
	rc = os.WEXITSTATUS(status) if os.WIFEXITED(status) else -1
	if killed:
		return 124, _clean(bytes(out), pwd), "timeout"
	return rc, _clean(bytes(out), pwd), ""


# 统一入口: 优先公钥认证, 认证失败且提供了密码时回退 pty
def run(host, user, cmd, password=None, port=None, key=KEY_FILE, timeout=TIMEOUT):
	if key and os.path.exists(key):
		rc, out, err = run_key(host, user, cmd, port=port, key=key, timeout=timeout)
		if rc == 0 or not _looks_auth_fail(err):
			return rc, out, err
		if not password:					# 公钥认证失败且无密码可回退
			return rc, out, err
		return run_password(host, user, password, cmd, port=port, timeout=timeout)
	if password:							# 没有可用私钥, 直接用密码
		return run_password(host, user, password, cmd, port=port, timeout=timeout)
	return 127, "", "no identity key (%s) and no password" % KEY_FILE
