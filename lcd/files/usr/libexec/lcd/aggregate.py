# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 聚合模式页面的全部状态: 采集数据并生成串口屏指令
#
# 类结构:
#   LinkStatus       单条链路的状态
#   LinkList         全部链路的集合(内部一个数组), 聚合口径在这里算
#   BtsStatus        单张基站卡片的状态
#   AggregateStatus  页面全部状态 = 一个 LinkList + 一个 BtsStatus 数组, 用 collect() 采集
#
# 本模块由 lcd.py 通过 sys.path 引入(打包装到 /usr/libexec/lcd, 见 Makefile 的 install 段),
# 只负责"采集 + 生成指令文本", 不碰串口、不写日志:
#   - 串口发送与日志统一由 lcd.py 负责, 两个模块不互相 import
#     (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#   - 本模块无任何串口依赖, 可在开发机上直接 import 验证
#


LINK_SLOTS = 5								# 屏上预置的链路卡槽数, 需与串口屏工程一致

# 链路类型: WAN 有线广域网口 / LAN 局域网口 / SIM 蜂窝模组
LINK_TYPES = ("WAN", "LAN", "SIM")

# 屏上每个链路卡槽的控件(卡槽号 x 从 1 起, 如 PicOperator1 / TX3), 图片号需与串口屏工程一致:
#   PicOperatorx.pic  运营商图标   25 中国移动 / 24 中国联通 / 23 中国电信 / 40 未识别
#   PicOnlinex.pic    在线状态图标 30 在线 / 29 已禁用 / 28 未插卡 / 27 离线 / 26 拨号中
#   PicRsrpx.pic      信号格图标   36 满格 / 35 四格 / 34 三格 / 33 两格 / 32 一格 / 31 无信号
#   TextRsrpx.txt     信号强度文本, 有读数时是数值(如 "-75"), 读不到信号时是 "--"
#   TXx.val           上行带宽, 单位为 0.01Mbps(如 12345 即 123.45Mbps)
#   RXx.val           下行带宽, 单位同上
#   Rttx.val          RTT 时延(ms)

# 聚合链路状态卡片(页面顶部, 五列: 连接状态/上行/下行/时延/链路数)的控件:
#   TextAggSta.txt     聚合链路状态   在线 / 离线(只要有一条链路在线即为在线)
#   FloatAggTx.val     聚合上行速率   单位同 TXx, 为在线链路之和
#   FloatAggRx.val     聚合下行速率   单位同 RXx, 为在线链路之和
#   NumAggRtt.val      聚合时延(ms)   为在线链路的平均值
#   NumAggChannel.val  聚合链路数量   在线链路的条数

# 运营商 -> PicOperatorx 的图片号
OPERATOR_PICS = {
	"中国移动": 25,
	"中国联通": 24,
	"中国电信": 23,
}
UNKNOWN_OPERATOR_PIC = 40					# 读不到运营商时用"未识别"图标

# 链路状态 -> PicOnlinex 的图片号
STATE_ONLINE = "在线"						# 只有该状态有速率与时延读数
STATE_PICS = {
	"在线": 30,
	"已禁用": 29,
	"未插卡": 28,
	"离线": 27,
	"拨号中": 26,
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
		self.state = state					# 链路状态, 取值见 STATE_PICS
		self.rsrp = rsrp					# 信号强度(dBm), None 表示读不到信号
		self.up = up						# 上行速率(Mbps)
		self.down = down					# 下行速率(Mbps)
		self.latency = latency				# 时延(ms)

	# 是否在线: 只有在线链路参与聚合口径, 也只有它在屏上有速率与时延
	@property
	def online(self):
		return self.state == STATE_ONLINE


# 全部链路的集合: 内部用一个数组保存, 顺序即屏上从上到下的顺序
# 聚合口径(在线数量/速率之和/时延均值/运营商列表)都在这里算, 上层不再重复遍历
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

	# 是否有链路在线: 只要有一条, 聚合链路整体即为在线
	@property
	def online(self):
		return any(link.online for link in self.items)

	# 在线链路数量
	@property
	def online_count(self):
		return len(self.online_items)

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

	# 聚合时延(ms): 在线链路平均值
	@property
	def latency(self):
		online = self.online_items
		return int(sum(link.latency for link in online) / len(online)) if online else 0


# 单张基站卡片的状态(4G / 5G 各一张)
class BtsStatus:

	def __init__(self, label, online, pci, ue):
		self.label = label					# 制式, 如 4G / 5G
		self.online = online				# 是否在线
		self.pci = pci						# 物理小区 ID
		self.ue = ue						# 当前连接用户数


# 模拟的链路状态: 5 条链路各取一种状态, 把 PicOnlinex 的 5 张状态图都覆盖一遍;
# 运营商与信号档位也尽量错开, 便于一眼核对图标是否对上
# 想单独验证某一档信号, 改对应链路的 rsrp 即可(门限见 RSRP_PICS); 想验证"无信号"就把 rsrp 置为 None
def _mock_links():
	return [
		LinkStatus("wan0", "SIM", "中国移动", "在线", -75, 12.34, 45.67, 32),
		LinkStatus("wan1", "SIM", "中国联通", "拨号中", -85, 0.0, 0.0, 0),
		LinkStatus("wan2", "SIM", "中国电信", "离线", -95, 0.0, 0.0, 0),
		LinkStatus("wan3", "SIM", "", "未插卡", None, 0.0, 0.0, 0),
		LinkStatus("wan4", "SIM", "", "已禁用", None, 0.0, 0.0, 0),
	]

# 模拟的基站状态: 4G 在线, 5G 离线
def _mock_bts():
	return [
		BtsStatus("4G", True, 128, 36),
		BtsStatus("5G", False, 0, 0),
	]


# 聚合模式页面的全部状态: 一个链路集合 + 一个基站卡片数组
class AggregateStatus:

	def __init__(self):
		self.links = LinkList()				# 所有链路(内部一个数组), 顺序即屏上从上到下的顺序
		self.bts = []						# 所有基站卡片(list[BtsStatus]), 顺序同上

	# 采集当前状态并返回实例
	@classmethod
	def collect(cls):
		status = cls()
		status.links = LinkList(_mock_links())		# TODO 接入真实数据源: uci openmptcprouter.<iface>.{state,latency,asn} / luci-bwc -i <dev>
		status.bts = _mock_bts()					# TODO 接入真实数据源
		return status

	# 转成串口屏指令序列(不含 FF FF FF), 返回列表, 顺序即下发顺序
	def commands(self):
		commands = ["BtnModeAggre.val=1"]			# 先切到聚合模式页
		commands.extend(self._agg_commands())		# 顶部的聚合链路状态卡片
		for index, link in enumerate(list(self.links)[:LINK_SLOTS]):
			commands.extend(self._link_commands(index, link))
		return commands

	# 生成聚合链路状态卡片(页面顶部)的全部指令
	# 取值口径见 LinkList: 状态只要有一条在线即为在线, 速率为在线之和, 时延为在线均值
	def _agg_commands(self):
		links = self.links
		return [
			'TextAggSta.txt="%s"' % ("在线" if links.online else "离线"),
			"FloatAggTx.val=%d" % mbps_to_val(links.up),
			"FloatAggRx.val=%d" % mbps_to_val(links.down),
			"NumAggRtt.val=%d" % links.latency,
			"NumAggChannel.val=%d" % links.online_count,
		]

	# 生成第 index 个卡槽(从 0 起)的全部指令; 卡槽号从 1 起, 控件名为"控件名+卡槽号"
	# 只有在线链路有速率与时延读数, 其余状态一律下发 0
	def _link_commands(self, index, link):
		slot = index + 1
		# 信号强度统一走 txt 下发字符串: 有读数是数值, 读不到信号是 "--"
		rsrp_text = 'TextRsrp%d.txt="%s"' % (slot, link.rsrp if link.rsrp is not None else "--")
		return [
			"PicOperator%d.pic=%d" % (slot, OPERATOR_PICS.get(link.operator, UNKNOWN_OPERATOR_PIC)),
			"PicOnline%d.pic=%d" % (slot, STATE_PICS[link.state]),
			"PicRsrp%d.pic=%d" % (slot, rsrp_pic(link.rsrp)),
			rsrp_text,
			"TX%d.val=%d" % (slot, mbps_to_val(link.up if link.online else 0)),
			"RX%d.val=%d" % (slot, mbps_to_val(link.down if link.online else 0)),
			"Rtt%d.val=%d" % (slot, link.latency if link.online else 0),
		]

	# 生成第 index 张基站卡片的赋值指令
	def _bts_commands(self, index, bts):
		slot = index + 1
		return [
			'BtsName%d.txt="%s"' % (slot, bts.label),
			'BtsState%d.txt="%s"' % (slot, "在线" if bts.online else "离线"),
			'BtsPci%d.txt="%s"' % (slot, bts.pci if bts.online else "--"),
			'BtsUe%d.txt="%s"' % (slot, bts.ue if bts.online else "--"),
		]
