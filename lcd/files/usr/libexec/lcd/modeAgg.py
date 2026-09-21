# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 聚合模式页面的全部状态: 采集数据并生成串口屏指令
#
# 类结构:
#   LinkStatus       单条链路的状态
#   LinkList         全部链路的集合(内部一个数组), 链路侧的聚合口径在这里算
#   AggLinkStatus    聚合链路状态卡片(页面顶部)的状态
#   BtsStatus        单张基站卡片的状态
#   AggregateStatus  页面全部状态 = 一个 AggLinkStatus + 一个 LinkList + 一个 BtsStatus 数组, 用 collect() 采集
#
# 指令见 docs/018-屏幕.md 第4节 3.2
#
# 数据来源见 siminfo.py(链路状态/运营商/信号/速率/聚合隧道), 本模块只做"取状态 + 生成指令文本"
#
# 本模块由 lcd.py 通过 sys.path 引入(打包装到 /usr/libexec/lcd, 见 Makefile 的 install 段),
# 不碰串口、不写日志:
#   - 串口发送与日志统一由 lcd.py 负责, 两个模块不互相 import
#     (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#   - 本模块无任何串口依赖, 可在开发机上直接 import 验证
#

from siminfo import RateMeter, SimState, read_sims, read_tunnel


LINK_SLOTS = 5								# 屏上预置的链路卡槽数, 需与串口屏工程一致

# 链路类型: WAN 有线广域网口 / LAN 局域网口 / SIM 蜂窝模组
LINK_TYPES = ("WAN", "LAN", "SIM")

# 屏上每个链路卡槽的控件(卡槽号 x 从 1 起, 如 PicSim1Op / NumSim3Rtt), 图片号需与串口屏工程一致:
#   PicSimxOp.pic       运营商图标   25 中国移动 / 24 中国联通 / 23 中国电信 / 145 未知
#   PicSimxOnline.pic   在线状态图标 30 在线 / 29 已禁用 / 28 未插卡 / 27 离线 / 26 拨号中
#   PicSimxRsrp.pic     信号格图标   36 满格 / 35 四格 / 34 三格 / 33 两格 / 32 一格 / 31 无服务
#   TextSimxRsrp.txt    信号强度文本, 有读数时是数值(如 "-75"), 读不到信号时是 "--"
#   FloatSimxTx.val     上行带宽, 单位为 0.01Mbps(如 12345 即 123.45Mbps)
#   FloatSimxRx.val     下行带宽, 单位同上
#   NumSimxRtt.val      RTT 时延(ms)

# 聚合链路状态卡片(页面顶部, 五列: 连接状态/上行/下行/时延/链路数)的控件:
#   TextAggSta.txt     聚合链路状态   在线 / 离线, 与网页一致: 聚合隧道可达才在线
#   TextAggSta.pco     聚合链路状态文字颜色, 与状态一起下发
#   FloatAggTx.val     聚合上行速率   单位同 FloatSimxTx, 为在线链路之和
#   FloatAggRx.val     聚合下行速率   单位同 FloatSimxRx, 为在线链路之和
#   NumAggRtt.val      聚合时延(ms)   聚合隧道的时延, 与网页一致
#   NumAggChannel.val  聚合链路数量   真正在线的链路条数(见 LinkList.online_count)

# 基站状态卡片(页面右侧, 4G / 5G 上下各一张, 控件名不按卡槽编号)的控件:
#   PicLteOnline.pic  4G 在线状态图标   43 在线 / 42 离线
#   Pic5GOnline.pic   5G 在线状态图标   同上
#   NumLteID.val      4G 物理小区 ID
#   NumLteUser.val    4G 连接用户数
#   Num5GID.val       5G 物理小区 ID
#   Num5GUser.val     5G 连接用户数

# 运营商 -> PicSimxOp 的图片号
OPERATOR_PICS = {
	"中国移动": 25,
	"中国联通": 24,
	"中国电信": 23,
}
UNKNOWN_OPERATOR_PIC = 145					# 读不到运营商时用"未知"图标

# 链路状态 -> PicSimxOnline 的图片号(状态由 siminfo 采集, 只有在线有速率与时延读数)
STATE_PICS = {
	SimState.ONLINE: 30,
	SimState.DISABLED: 29,
	SimState.NO_SIM: 28,
	SimState.OFFLINE: 27,
	SimState.DIALING: 26,
}

# 聚合链路状态 -> TextAggSta.pco 的文字颜色(RGB565, 见 docs/018-屏幕.md 3.2)
AGG_STATE_COLORS = {
	SimState.ONLINE: 2024,					# 绿
	SimState.OFFLINE: 63504,				# 红
}

# RSRP 门限(dBm) -> PicRsrpx 的图片号, 由强到弱排列, 取第一个满足 rsrp >= 门限的档位
RSRP_PICS = (
	(-80, 36),								# >= -80dBm  满格
	(-90, 35),								# >= -90dBm  四格
	(-100, 34),								# >= -100dBm 三格
	(-110, 33),								# >= -110dBm 两格
	(-120, 32),								# >= -120dBm 一格
)
RSRP_NONE_PIC = 31							# 无信号(rsrp 为 None)

# 基站制式 -> (在线状态图标控件, 物理小区 ID 控件, 连接用户数控件)
BTS_WIDGETS = {
	"4G": ("PicLteOnline", "NumLteID", "NumLteUser"),
	"5G": ("Pic5GOnline", "Num5GID", "Num5GUser"),
}

# 基站在线状态 -> Pic*Online 的图片号
BTS_ONLINE_PIC = 43							# 在线
BTS_OFFLINE_PIC = 42						# 离线


# RSRP(dBm) -> PicRsrpx 的图片号; rsrp 为 None 表示读不到信号
def rsrp_pic(rsrp):
	if rsrp is None:
		return RSRP_NONE_PIC
	for threshold, pic in RSRP_PICS:
		if rsrp >= threshold:
			return pic
	return RSRP_NONE_PIC


# Mbps -> 屏上的整数值(单位为 0.01Mbps), 如 12.34 -> 1234
def mbps_to_val(mbps):
	return int(round(mbps * 100))


# 单条链路的状态
# 参数顺序: 链路名, 类型, 运营商, 状态, RSRP(dBm), 上行(Mbps), 下行(Mbps), 时延(ms)
class LinkStatus:

	def __init__(self, name, link_type, operator, state, rsrp, up, down, latency):
		self.name = name					# 链路名, 如 wan0
		self.type = link_type				# 链路类型, 取值见 LINK_TYPES(WAN / LAN / SIM)
		self.operator = operator			# 运营商, 空串表示读不到(未插卡/已禁用)
		self.state = state					# 链路状态, 取值见 siminfo.SimState
		self.rsrp = rsrp					# 信号强度(dBm), None 表示读不到信号
		self.up = up						# 上行速率(Mbps)
		self.down = down					# 下行速率(Mbps)
		self.latency = latency				# 时延(ms)

	# 是否在线: 只有在线链路参与聚合口径, 也只有它在屏上有速率与时延
	@property
	def online(self):
		return self.state is SimState.ONLINE


# 全部链路的集合: 内部用一个数组保存, 顺序即屏上从上到下的顺序
# 链路侧的聚合口径(在线速率之和 / 能上网的条数)都在这里算, 上层不再重复遍历
class LinkList:

	def __init__(self, links=None):
		self.items = list(links) if links else []

	def __len__(self):
		return len(self.items)

	def __getitem__(self, index):
		return self.items[index]

	def __iter__(self):
		return iter(self.items)

	# 在线的链路
	@property
	def online_items(self):
		return [link for link in self.items if link.online]

	# 各链路的运营商名称, 顺序与链路一一对应(含离线链路)
	@property
	def operators(self):
		return [link.operator for link in self.items]

	# 聚合上行速率(Mbps): 在线链路之和
	@property
	def up(self):
		return sum(link.up for link in self.online_items)

	# 聚合下行速率(Mbps): 在线链路之和
	@property
	def down(self):
		return sum(link.down for link in self.online_items)

	# 参与聚合的链路数量: 真正在线的链路才作为一条聚合链路, 与参与速率求和的链路一致
	@property
	def online_count(self):
		return len(self.online_items)


# 聚合链路状态卡片(页面顶部, 五列: 连接状态/上行/下行/时延/链路数)的状态
# 是否在线看聚合隧道可达(与网页 ModeAggregate 同一数据源), 时延取隧道时延,
# 上下行取在线链路速率之和, 链路数取真正在线的链路条数(卡名取自 uci sim 段, 状态取自 tracker-sim 的探测结果)
class AggLinkStatus:

	def __init__(self, state=SimState.OFFLINE, up=0.0, down=0.0, latency=0, channels=0):
		self.state = state											# 聚合链路状态, 取值见 AGG_STATE_COLORS
		self.up = up												# 聚合上行速率(Mbps), 为在线链路之和
		self.down = down											# 聚合下行速率(Mbps), 单位同上
		self.latency = latency										# 聚合时延(ms), 取聚合隧道的时延
		self.channels = channels									# 参与聚合的链路数量

	# 由链路集合与聚合隧道采集: 隧道可达即在线
	@classmethod
	def collect(cls, links, tunnel):
		return cls(SimState.ONLINE if tunnel.reachable else SimState.OFFLINE,
			links.up, links.down, tunnel.latency, links.online_count)

	# 转成串口屏指令序列(不含 FF FF FF), 顺序即下发顺序
	def commands(self):
		return [
			"TextAggSta.pco=%d" % AGG_STATE_COLORS[self.state],
			'TextAggSta.txt="%s"' % self.state.value,				# 下发枚举值(中文), 不是枚举本身
			"FloatAggTx.val=%d" % mbps_to_val(self.up),
			"FloatAggRx.val=%d" % mbps_to_val(self.down),
			"NumAggRtt.val=%d" % self.latency,
			"NumAggChannel.val=%d" % self.channels,
		]


# 单张基站卡片的状态(4G / 5G 各一张)
class BtsStatus:

	def __init__(self, label, online, pci, ue):
		self.label = label					# 制式, 如 4G / 5G
		self.online = online				# 是否在线
		self.pci = pci						# 物理小区 ID
		self.ue = ue						# 当前连接用户数


# 速率计: 速率靠两次采样的字节数差分得到, 需跨次调用保存上一次的值, 所以放在模块级
_meter = RateMeter()


# 采集各链路的状态: 顺序即屏上从上到下的顺序(卡槽 1 对应 sim1)
# 卡槽多过实际配置的 SIM 时, 余下的按"已禁用"下发, 避免屏上留着上一次的内容
def _read_links():
	links = []
	sims = read_sims()
	for index in range(LINK_SLOTS):
		if index < len(sims):
			sim = sims[index]
			up, down = _meter.rates(sim.dev)	# 没拨号的链路流量为 0, 速率自然是 0
			links.append(LinkStatus(sim.name, "SIM", sim.operator, sim.state, sim.rsrp,
				up, down, 0))				# TODO 时延: 逐链路 uci openmptcprouter.<simN>.latency
		else:
			links.append(LinkStatus("sim%d" % (index + 1), "SIM", "",
				SimState.DISABLED, None, 0.0, 0.0, 0))
	return links


# 基站卡片: 屏上固定显示离线与 0
# 模组是终端, 读不到基站的物理小区 ID 与连接用户数, 这两个字段没有数据源
def _read_bts():
	return [
		BtsStatus("4G", False, 0, 0),
		BtsStatus("5G", False, 0, 0),
	]


# 聚合模式页面的全部状态: 一个聚合链路状态卡片 + 一个链路集合 + 一个基站卡片数组
class AggregateStatus:

	def __init__(self):
		self.agg = AggLinkStatus()			# 顶部聚合链路状态卡片, 口径见 AggLinkStatus
		self.links = LinkList()				# 所有链路(内部一个数组), 顺序即屏上从上到下的顺序
		self.bts = []						# 所有基站卡片(list[BtsStatus]), 顺序同上

	# 采集当前状态并返回实例
	@classmethod
	def collect(cls):
		status = cls()
		status.links = LinkList(_read_links())		# 真实数据, 来源见 siminfo.py
		status.agg = AggLinkStatus.collect(status.links, read_tunnel())
		status.bts = _read_bts()
		return status

	# 转成串口屏指令序列(不含 FF FF FF), 返回列表, 顺序即下发顺序
	# 不含切页指令: 进入聚合模式页由 lcd.py 在握手时下发 agg_mode=1 完成, 见 docs/018-屏幕.md 第4节
	def commands(self):
		commands = self.agg.commands()				# 顶部的聚合链路状态卡片
		for index, link in enumerate(list(self.links)[:LINK_SLOTS]):
			commands.extend(self._link_commands(index, link))
		commands.extend(self._bts_commands())		# 右侧的基站状态卡片
		return commands

	# 生成第 index 个卡槽(从 0 起)的全部指令; 卡槽号从 1 起, 控件名即 "PicSim/TextSim/FloatSim/NumSim + 卡槽号 + 后缀"
	# 只有在线链路有速率与时延读数, 其余状态一律下发 0
	def _link_commands(self, index, link):
		slot = index + 1
		# 信号强度统一走 txt 下发字符串: 有读数是数值, 读不到信号是 "--"
		rsrp_text = 'TextSim%dRsrp.txt="%s"' % (slot, link.rsrp if link.rsrp is not None else "--")
		return [
			"PicSim%dOp.pic=%d" % (slot, OPERATOR_PICS.get(link.operator, UNKNOWN_OPERATOR_PIC)),
			"PicSim%dOnline.pic=%d" % (slot, STATE_PICS[link.state]),
			"PicSim%dRsrp.pic=%d" % (slot, rsrp_pic(link.rsrp)),
			rsrp_text,
			"FloatSim%dTx.val=%d" % (slot, mbps_to_val(link.up if link.online else 0)),
			"FloatSim%dRx.val=%d" % (slot, mbps_to_val(link.down if link.online else 0)),
			"NumSim%dRtt.val=%d" % (slot, link.latency if link.online else 0),
		]

	# 生成基站状态卡片(4G / 5G 各一张)的全部指令
	# 控件名不按卡槽编号, 由制式 label 查表; 基站离线时两个数值均下发 0
	def _bts_commands(self):
		commands = []
		for bts in self.bts:
			state_widget, pci_widget, ue_widget = BTS_WIDGETS[bts.label]
			commands.append("%s.pic=%d" % (state_widget, BTS_ONLINE_PIC if bts.online else BTS_OFFLINE_PIC))
			commands.append("%s.val=%d" % (pci_widget, bts.pci if bts.online else 0))
			commands.append("%s.val=%d" % (ue_widget, bts.ue if bts.online else 0))
		return commands
