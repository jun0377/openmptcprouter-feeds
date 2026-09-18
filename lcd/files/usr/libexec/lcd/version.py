# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 版本信息页面(页脚「版本信息」弹窗)的状态: 采集版本信息并生成串口屏指令
#
# 数据来源: /etc/version, 编译时由 build.sh 生成, 形如
#   {
#       "version" : "0.1.5",
#       "build_timestamp" : "2026.09.16-07:01",
#       "commit": "5589440"
#   }
#
# 本模块由 lcd.py 通过 sys.path 引入(打包装到 /usr/libexec/lcd, 见 Makefile 的 install 段),
# 只负责"采集 + 生成指令文本", 不碰串口、不写日志:
#   - 串口发送与日志统一由 lcd.py 负责, 两个模块不互相 import
#     (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#   - 本模块无任何串口依赖, 可在开发机上直接 import 验证
#

import json									# 解析 /etc/version

# 屏上版本信息弹窗的四个文本控件:
#   TextVersion.txt    版本号, 如 V0.1.5
#   TextBuildTime.txt  构建时间, 如 2026.09.16-07:01
#   TextCommit.txt     commit id, 如 5589440
#   TextRelease.txt    发布说明, 多行文本, 行间用转义字符 \r 分隔

VERSION_FILE = "/etc/version"				# 版本信息文件, 编译时由 build.sh 生成

UNKNOWN = "--"								# 版本文件读不到时屏上的占位

# 发布说明: 版本文件里没有该字段, 暂用固定文本
# (编译时的来源是 files/etc/ReleaseNote.md, 未装进设备, 需要的话可一并打包)
# 行间的 \r 是屏侧的换行转义, 必须是"反斜杠+r"两个字符(源码里写 \\r),
# 不能写成 Python 的 "\r"——那是真正的回车字节 0x0D, 屏侧不认;
# 末尾两个 \r 与设计稿一致, 用于把文本顶到控件顶端
RELEASE = "1.这是一个测试版本\\r2.测试通过\\r\\r"


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
			info.get("build_timestamp") or UNKNOWN,
			info.get("commit") or UNKNOWN,
			RELEASE,
		)

	# 转成串口屏指令序列(不含 FF FF FF), 返回列表, 顺序即下发顺序
	def commands(self):
		return [
			'TextVersion.txt="%s"' % self.version,
			'TextBuildTime.txt="%s"' % self.build_time,
			'TextCommit.txt="%s"' % self.commit,
			'TextRelease.txt="%s"' % self.release,
		]
