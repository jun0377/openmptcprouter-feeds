# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 版本信息页面(页脚「版本信息」弹窗)的状态: 采集版本信息并生成串口屏指令
#
# 数据来源(全部只读):
#   /etc/version         编译时由 build.sh 生成, 形如
#       {
#           "version" : "0.1.5",
#           "build_timestamp" : "2026.09.16-07:01",
#           "commit": "5589440"
#       }
#   /etc/ReleaseNote.md  开发&发布日志, 取最新一条记录(文件里第一条 version:)的 feature 列表
#       作为发布说明, 记录形如
#           version:        0.1.5
#           date:           2026.07.18
#           feature:        (1) 大幅修改页面布局
#                           (2) 使用dnsmasq和unbound配合实现DNS解析功能
#
# 本模块由 lcd.py 通过 sys.path 引入(打包装到 /usr/libexec/lcd, 见 Makefile 的 install 段),
# 只负责"采集 + 生成指令文本", 不碰串口、不写日志:
#   - 串口发送与日志统一由 lcd.py 负责, 两个模块不互相 import
#     (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#   - 本模块无任何串口依赖, 可在开发机上直接 import 验证
#

import json									# 解析 /etc/version
import re									# 提取发布日志里的 feature 条目

# 屏上版本信息弹窗的四个文本控件:
#   TextVersion.txt    版本号, 如 V0.1.5
#   TextBuildTime.txt  构建时间, 如 2026.09.16-07:01
#   TextCommit.txt     commit id, 如 5589440
#   TextRelease.txt    发布说明, 多行文本, 行间用转义字符 \r 分隔

VERSION_FILE = "/etc/version"				# 版本信息文件, 编译时由 build.sh 生成
RELEASE_FILE = "/etc/ReleaseNote.md"		# 发布日志, 随 files/ 目录一起装进设备

UNKNOWN = "--"								# 读不到时屏上的占位

FEATURE_ITEM = re.compile(r"^\(\d+\)\s*(.+)$")		# 发布日志里的一条 feature: "(1) 大幅修改页面布局"


# 读版本文件(JSON): 文件不存在或内容不合法时返回空字典, 由上层决定兜底显示
def _read_version_file():
	try:
		fp = open(VERSION_FILE, "r")
	except OSError:
		return {}
	with fp:
		try:
			return json.load(fp)
		except ValueError:
			return {}


# 读发布日志的全部行: 文件不存在时返回空列表
def _read_release_lines():
	try:
		fp = open(RELEASE_FILE, "r")
	except OSError:
		return []
	with fp:
		return fp.readlines()


# 读最新一条发布记录的 feature 列表
# 条目在日志里形如 "(1) 大幅修改页面布局", 这里只取序号后的正文;
# 条目之外的行(分隔线、date、空行)都跳过, 读到下一条 version: 即结束
def _read_features():
	features = []
	started = False
	for line in _read_release_lines():
		text = line.strip()
		if text.startswith("version:"):				# 又一条记录: 最新一条已经读完
			if started:
				break
			started = True
		elif started:
			if text.startswith("feature:"):			# 首条 feature 可能紧跟在 feature: 同一行
				text = text[len("feature:"):].strip()
			match = FEATURE_ITEM.match(text)
			if match:
				features.append(match.group(1).strip())
	return features


# feature 列表 -> 屏上的发布说明: 每行一条, 行前重新编号, 行尾用屏侧的换行转义 \r
# \r 必须是"反斜杠+r"两个字符(源码里写 \\r), 不能写成 Python 的 "\r"——那是真正的回车字节 0x0D, 屏侧不认
def _release_text(features):
	return "".join("%d.%s\\r" % (index, text) for index, text in enumerate(features, 1))


# 版本信息弹窗的全部状态
class VersionStatus:

	def __init__(self, version, build_time, commit, release):
		self.version = version				# 版本号
		self.build_time = build_time		# 构建时间
		self.commit = commit				# commit id
		self.release = release				# 发布说明(已转义的多行文本)

	# 采集当前版本信息并返回实例
	@classmethod
	def collect(cls):
		info = _read_version_file()
		version = info.get("version")
		return cls(
			"V%s" % version if version else UNKNOWN,	# 文件里是 0.1.5, 屏上按设计稿显示 V0.1.5
			info.get("build_timestamp") or UNKNOWN,		# 原样显示, 如 2026.09.16-07:01
			info.get("commit") or UNKNOWN,
			_release_text(_read_features()) or UNKNOWN,	# 最新一条记录的功能列表
		)

	# 转成串口屏指令序列(不含 FF FF FF), 返回列表, 顺序即下发顺序
	def commands(self):
		return [
			'TextVersion.txt="%s"' % self.version,
			'TextBuildTime.txt="%s"' % self.build_time,
			'TextCommit.txt="%s"' % self.commit,
			'TextRelease.txt="%s"' % self.release,
		]
