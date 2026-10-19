# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :

import shlex								# argv 拼成远端命令时逐个参数做 shell 引用

import cmd									# cmd.CmdSpec 与本地执行(未配置远端主机时回退)
import remote								# 远端(SSH)命令执行
from logger import log
from uci import uci_get

# ---- 远端连接参数: 取自 UCI basestation.remote 节(见 files/etc/config/basestation) ----
REMOTE_HOST = uci_get("basestation.remote.host") or ""				# 留空则在本地执行
REMOTE_USER = uci_get("basestation.remote.user") or "root"
REMOTE_PORT = uci_get("basestation.remote.port") or None
REMOTE_KEY = uci_get("basestation.remote.key") or None				# 私钥路径, 为空则跳过公钥认证
REMOTE_PASSWORD = uci_get("basestation.remote.password") or None	# 备选密码, 仅在公钥认证失败时使用


# 在远端执行一条命令并取回响应: argv 逐个 shell 引用后拼成命令串(远端命令要过远端 shell)
# 未配置远端主机时回退本地执行; 返回 (是否成功, 标准输出, 错误输出), 与 cmd.execute 一致
def execute(argv, timeout=None):
	if not REMOTE_HOST:
		return cmd.execute(argv, timeout=timeout or cmd.TIMEOUT)
	cmdline = " ".join(shlex.quote(str(a)) for a in argv)
	rc, out, err = remote.run(REMOTE_HOST, REMOTE_USER, cmdline, password=REMOTE_PASSWORD,
							  port=REMOTE_PORT, key=REMOTE_KEY, timeout=timeout or remote.TIMEOUT)
	return rc == 0, out, err


# 归一化回包: 统一换行并去掉结尾空行, 便于按行解析
def _clean(text):
	return text.replace("\r\n", "\n").replace("\r", "\n").rstrip("\n")


# ---- 各指令的解析函数: 入参为清洗后的输出文本, 出参按各自语义自定 ----

# ls-dir: 目录列表, 去掉空行后按行返回
def parse_ls_dir(text):
	return [line for line in text.split("\n") if line]


# ls-opt: 目录列表(带可选参数), 同样按行返回
def parse_ls_opt(text):
	return [line for line in text.split("\n") if line]


# date-fmt: 单行时间戳
def parse_date_fmt(text):
	return text.strip()


# ---- 被测指令: 指令名 -> cmd.CmdSpec(argv 模板或 callable, 解析函数) ----
CMDS = {
	"ls-dir":   cmd.CmdSpec(["ls", "{path}", "-alh"], parse_ls_dir),
	"ls-opt":   cmd.CmdSpec(lambda **kw: ["ls"] + ([kw["path"]] if kw.get("path") else []) + (["-alh"] if kw.get("long") else []), parse_ls_opt),
	"date-fmt": cmd.CmdSpec(["date", "+{fmt}"], parse_date_fmt),
}


# ---- 用例: run_argv 执行任意命令传 argv 列表; run 执行已登记指令传 (指令名, 具名参数) ----
ARGV_CASES = (
	["ls"],
	["ls", "/opt", "-alh"],
	["date", "+%Y-%m-%d %H:%M:%S"],
	["ls", "/no/such/dir"],					# 命令失败
)

RUN_CASES = (
	("ls-dir", {"path": "/opt"}),
	("date-fmt", {"fmt": "%Y-%m-%d %H:%M:%S"}),
	("ls-opt", {"path": "/opt", "long": True}),
	("ls-dir", {}),							# 缺少必填参数
	("no-such-cmd", {}),					# 未登记的指令
)


# 执行一条命令并解析响应: parse 省略时以文本形式返回
# 返回 (是否成功, 解析结果, 原始输出, 错误输出)
def run_argv(argv, parse=None):
	ok, raw, err = execute(argv)
	if not ok:
		log("command %s failed: %s" % (" ".join(str(a) for a in argv), err.strip() or _clean(raw).strip()))
		return False, None, raw, err
	text = _clean(raw)
	return True, (parse(text) if parse else text), raw, err


# 执行 CMDS 里登记的指令: 按 argv 模板渲染后执行, 结果交给该指令自己的解析函数
def run(name, **kwargs):
	spec = CMDS.get(name)
	if spec is None:
		log("command %s failed: unknown command" % name)
		return False, None, "", ""
	try:
		argv = spec.argv(**kwargs) if callable(spec.argv) else [part.format(**kwargs) for part in spec.argv]
	except KeyError as err:					# 缺少必填参数
		log("command %s failed: missing argument %s" % (name, err.args[0] if err.args else ""))
		return False, None, "", ""
	return run_argv(argv, parse=spec.parse)


# 把 CMDS 登记进 cmd 的注册表(经 cmd.register 走占位符校验; 未配置远端主机时也可用 cmd.run 执行)
def register_all():
	for name, spec in CMDS.items():
		cmd.register(name, spec.argv, spec.parse)


if __name__ == "__main__":
	register_all()

	print("---- run_argv: 执行任意命令 ----")
	for argv in ARGV_CASES:
		ok, data, raw, err = run_argv(argv)
		print("%-30s ok=%s err=%r\n    data=%r" % (" ".join(argv), ok, err.strip(), data))

	print("---- run: 执行已登记的指令 ----")
	for name, kwargs in RUN_CASES:
		ok, data, raw, err = run(name, **kwargs)
		print("%-12s %-30s ok=%s err=%r\n    data=%r" % (name, kwargs, ok, err.strip(), data))
