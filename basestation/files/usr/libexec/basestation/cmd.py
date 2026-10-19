# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :


import subprocess									# 执行命令
from collections import namedtuple					# 指令描述符
from string import Formatter						# 校验占位符写法

from logger import log

TIMEOUT = 10										# 单次执行超时(秒)

# 一条已登记的指令: argv 为含具名占位符的模板(list)或 callable, parse 为结果解析函数(可省略)
CmdSpec = namedtuple("CmdSpec", "argv parse")

COMMANDS = {}										# 指令注册表: key 为指令名, 由 register() 登记


def _decode(data):
	return data.decode("utf-8", errors="replace")


# 归一化输出: 统一换行并去掉结尾空行, 便于按行解析
def _clean(text):
	return text.replace("\r\n", "\n").replace("\r", "\n").rstrip("\n")


# 校验 argv 模板只允许具名占位符, "{}"/"{0}"/"{a.b}" 等写法直接报错
def _check_placeholders(name, argv):
	if callable(argv):
		return
	for part in argv:
		for _, field, _, _ in Formatter().parse(part):
			if field is not None and not field.isidentifier():
				raise ValueError("command %r: bad placeholder %r in %r" % (name, field, part))


# 登记一条指令, 供各业务模块在自身模块里调用, 如:
#   register("ls-dir", ["ls", "{path}"], parse_ls)
#   register("ls-dir", lambda **kw: ["ls"] + (["-lh"] if kw.get("long") else []), parse_ls)
def register(name, argv, parse=None):
	_check_placeholders(name, argv)
	COMMANDS[name] = CmdSpec(argv, parse)


# 渲染命令行参数: 模板走具名占位符(位置由模板决定, 传参顺序无关), callable 直接调用
# 缺参抛 KeyError, 交由调用方转成明确报错, 不做空串兜底
def _build_argv(spec, kwargs):
	if callable(spec.argv):
		return spec.argv(**kwargs)
	return [part.format(**kwargs) for part in spec.argv]


# 执行一条命令: argv 为参数列表, 不经 shell(带空格的参数无需转义, 通配符/管道也不生效;
# 需要管道等 shell 语义时自行传 ["sh", "-c", "..."])
# 返回 (是否成功, 原始标准输出, 原始错误输出)
def execute(argv, timeout=TIMEOUT):
	try:
		p = subprocess.run(argv, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
						   stderr=subprocess.PIPE, timeout=timeout)
	except subprocess.TimeoutExpired:
		return False, "", "timeout"
	except OSError as err:							# 可执行文件不存在等
		return False, "", str(err)
	return p.returncode == 0, _decode(p.stdout), _decode(p.stderr)


# 直接执行任意命令, 最通用的入口: run_argv(["ls"]) / run_argv(["ls", "/opt", "-lh"])
# parse 省略时 data 为归一化后的输出文本, 提供 parse 时为解析函数的返回值
# 返回 (是否成功, 解析结果, 原始标准输出, 原始错误输出)
def run_argv(argv, parse=None, timeout=TIMEOUT):
	ok, raw, err = execute(argv, timeout=timeout)
	if not ok:
		log("command %s failed: %s" % (" ".join(str(a) for a in argv), err.strip() or _clean(raw).strip()))
		return False, None, raw, err
	text = _clean(raw)
	return True, (parse(text) if parse else text), raw, err


# 执行已登记的指令: 按注册表渲染 argv 再解析结果; 未登记或缺少必填参数时返回 ok=False
def run(name, **kwargs):
	spec = COMMANDS.get(name)
	if spec is None:
		log("command %s failed: unknown command" % name)
		return False, None, "", ""
	try:
		argv = _build_argv(spec, kwargs)
	except KeyError as err:							# 缺少必填参数
		log("command %s failed: missing argument %s" % (name, err.args[0] if err.args else ""))
		return False, None, "", ""
	return run_argv(argv, parse=spec.parse)
