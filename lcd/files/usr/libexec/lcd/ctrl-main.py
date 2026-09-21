# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 运维模式首页(屏幕04「链路设置」)的状态: 采集链路/卫星/基站状态并生成串口屏指令
#
# 类结构:
#   SimEntry     单条 SIM 链路入口卡的状态(SIM1~SIM5)
#   BtsEntry     单个基站入口卡的状态(4G / 5G)
#   CtrlStatus   页面全部状态 = 一个 SimEntry 数组 + 一个卫星链路状态 + 一个 BtsEntry 数组, 用 collect() 采集
#
# 指令见 docs/018-屏幕.md 第4节 5
#
# SIM 卡的在线状态与运营商与直连页(3.1)完全相同, 本页只下发这两项, 所以直接复用
# modeDirect.py 的图标表, 不重复定义; 数据来源见 siminfo.py
#
# 本模块由 lcd.py 通过 sys.path 引入(打包装到 /usr/libexec/lcd, 见 Makefile 的 install 段),
# 注意文件名里的连字符不能写 import 语句, lcd.py 用 importlib 按名字加载本模块;
# 不碰串口、不写日志:
#   - 串口发送与日志统一由 lcd.py 负责, 两个模块不互相 import
#     (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#   - 本模块无任何串口依赖, 可在开发机上直接 import 验证
#

from modeDirect import OPERATOR_PICS, STATE_PICS
from siminfo import SimState, read_sims

SIM_SLOTS = 5								# 屏上「链路设置」里的 SIM 卡数(SIM1~SIM5), 需与串口屏工程一致

# 卫星链路入口卡: 控件名按串口屏工程(拼写即 PicStatellite), 图片号见文档第4节 5
SATELLITE_WIDGET = "PicStatellite"
SATELLITE_PICS = {
	"无卫星链路": 70,
	"在线": 71,
	"离线": 69,
}
SATELLITE_NONE = "无卫星链路"				# 卫星链路功能尚未实现(见文档 3.3), 先固定这个状态

# 基站入口卡: 制式 -> (在线状态控件, 物理小区 ID 控件, 连接用户数控件)
# 注意本页(运维模式)的 5G 控件名是小写 g, 与聚合页的 Pic5GOnline / Num5GID / Num5GUser 不同
BTS_WIDGETS = {
	"4G": ("PicLteOnline", "NumLteID", "NumLteUser"),
	"5G": ("Pic5gOnline", "Num5gID", "Num5gUser"),
}
BTS_ONLINE_PIC = 43							# 在线
BTS_OFFLINE_PIC = 42						# 离线


# 单条 SIM 链路入口卡的状态: 本页只有运营商与在线状态两项
class SimEntry:

	def __init__(self, operator, state):
		self.operator = operator			# 运营商, 空串表示读不到(未插卡/已禁用)
		self.state = state					# 在线状态, 取值见 siminfo.SimState


# 单个基站入口卡的状态(4G / 5G 各一张)
class BtsEntry:

	def __init__(self, label, online, pci, ue):
		self.label = label					# 制式, 如 4G / 5G
		self.online = online				# 是否在线
		self.pci = pci						# 物理小区 ID
		self.ue = ue						# 当前连接用户数


# 采集 SIM1~SIM5 的状态: 顺序即屏上从上到下的顺序(卡槽 1 对应 sim1)
# 卡槽多过实际配置的 SIM 时, 余下的按"已禁用"下发, 避免屏上留着上一次的内容
def _read_entries():
	entries = []
	configured = read_sims()
	for index in range(SIM_SLOTS):
		if index < len(configured):
			sim = configured[index]
			entries.append(SimEntry(sim.operator, sim.state))
		else:
			entries.append(SimEntry("", SimState.DISABLED))
	return entries


# 基站入口卡: 屏上固定显示离线与 0
# 模组是终端, 读不到基站的物理小区 ID 与连接用户数, 这两个字段没有数据源
def _read_bts():
	return [
		BtsEntry("4G", False, 0, 0),
		BtsEntry("5G", False, 0, 0),
	]


# 运维模式首页(链路设置)的全部状态
class CtrlStatus:

	def __init__(self, sims=None, satellite=SATELLITE_NONE, bts=None):
		self.sims = list(sims) if sims else []		# SIM1~SIM5(list[SimEntry]), 顺序即屏上顺序
		self.satellite = satellite					# 卫星链路状态, 取值见 SATELLITE_PICS
		self.bts = list(bts) if bts else []			# 基站入口卡(list[BtsEntry]), 顺序即屏上顺序

	# 采集当前状态并返回实例
	@classmethod
	def collect(cls):
		return cls(_read_entries(), SATELLITE_NONE, _read_bts())

	# 转成串口屏指令序列(不含 FF FF FF), 返回列表, 顺序即下发顺序
	def commands(self):
		commands = self._link_commands()			# 链路设置: SIM1~SIM5 + 卫星链路
		commands.extend(self._bts_commands())		# 基站设置: 4G / 5G 各一张
		return commands

	# 生成链路设置的全部指令: 每张 SIM 卡只下发运营商与在线状态, 卫星链路只下发状态
	def _link_commands(self):
		commands = []
		for index, sim in enumerate(self.sims):
			slot = index + 1
			commands.append("PicSim%dOp.pic=%d" % (slot,
				OPERATOR_PICS.get(sim.operator, OPERATOR_PICS[""])))
			commands.append("PicSim%dOnline.pic=%d" % (slot, STATE_PICS[sim.state]))
		commands.append("%s.pic=%d" % (SATELLITE_WIDGET, SATELLITE_PICS[self.satellite]))
		return commands

	# 生成基站设置(4G / 5G 各一张)的全部指令; 基站离线时两个数值均下发 0
	def _bts_commands(self):
		commands = []
		for bts in self.bts:
			state_widget, pci_widget, ue_widget = BTS_WIDGETS[bts.label]
			commands.append("%s.pic=%d" % (state_widget, BTS_ONLINE_PIC if bts.online else BTS_OFFLINE_PIC))
			commands.append("%s.val=%d" % (pci_widget, bts.pci if bts.online else 0))
			commands.append("%s.val=%d" % (ue_widget, bts.ue if bts.online else 0))
		return commands
