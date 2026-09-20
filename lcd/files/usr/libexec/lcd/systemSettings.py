# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 系统设置页面(页脚「系统设置」)的状态: 采集平台地址与上报频率并生成串口屏指令
#
# 类结构:
#   SystemSettings  页面全部状态 = 平台地址 + 上报频率, 用 collect() 采集
#
# 指令见 docs/018-屏幕.md 第4节 7
#
# 数据来源(全部只读, 不改任何配置):
#   uci openmptcprouter.vps.ip                          管理平台地址, 与网页取服务器地址同一处
#   uci management-platform.@main[0].report_interval    状态上报频率(秒)
#     上报进程 management-platform 每轮循环前重新读该值(见 statusReport.sh), 改完即生效, 不用重启服务
#
# 本模块由 lcd.py 通过 sys.path 引入(打包装到 /usr/libexec/lcd, 见 Makefile 的 install 段),
# 不碰串口、不写日志:
#   - 串口发送与日志统一由 lcd.py 负责, 两个模块不互相 import
#     (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#   - 本模块无任何串口依赖, 可在开发机上直接 import 验证
#

from uci import uci_get						# 读配置, 只读不写

SERVER_OPTION = "openmptcprouter.vps.ip"					# 管理平台地址
REPORT_OPTION = "management-platform.@main[0].report_interval"		# 状态上报频率(秒)

# 屏上系统设置页的控件:
#   TextIP.txt              管理平台地址文本
#   Btn5s/Btn15s/Btn30s/Btn60s.val  上报频率四个档位的按钮
#
# 四个按钮在屏侧没有互斥(见文档第4节 7), 必须四个一起下发:
# 当前档位为 1, 其余三个为 0, 否则上一次选中的按钮会一直亮着
REPORT_BUTTONS = (
	(5, "Btn5s"),
	(15, "Btn15s"),
	(30, "Btn30s"),
	(60, "Btn60s"),
)

DEFAULT_REPORT_INTERVAL = 15				# 配置读不到或不在四档内时, 按设计稿默认的 15s 高亮
UNKNOWN_SERVER = "--"						# 地址读不到时屏上的占位


# 读管理平台地址, 读不到返回空串
def _read_server_ip():
	return uci_get(SERVER_OPTION) or ""


# 读状态上报频率(秒): 读不到或不在四档内时返回默认档, 保证屏上总有一档被选中
def _read_report_interval():
	value = (uci_get(REPORT_OPTION) or "").strip()
	interval = int(value) if value.isdigit() else 0
	for seconds, _ in REPORT_BUTTONS:
		if seconds == interval:
			return interval
	return DEFAULT_REPORT_INTERVAL


# 系统设置页面的全部状态
class SystemSettings:

	def __init__(self, server_ip, report_interval):
		self.server_ip = server_ip					# 管理平台地址
		self.report_interval = report_interval		# 状态上报频率(秒), 取值见 REPORT_BUTTONS

	# 采集当前配置并返回实例
	@classmethod
	def collect(cls):
		return cls(_read_server_ip() or UNKNOWN_SERVER, _read_report_interval())

	# 转成串口屏指令序列(不含 FF FF FF), 返回列表, 顺序即下发顺序
	# 两个查询指令(GetServerAddr / GetReportFre)都下发整页状态, 保证屏上两项始终一致
	def commands(self):
		commands = ['TextIP.txt="%s"' % self.server_ip]
		for seconds, widget in REPORT_BUTTONS:		# 四个按钮全部下发, 命中为 1, 其余强制为 0
			commands.append("%s.val=%d" % (widget, 1 if seconds == self.report_interval else 0))
		return commands
