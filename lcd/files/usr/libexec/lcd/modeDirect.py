# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 直连模式页面的状态(屏幕01): 取链路状态并生成串口屏指令
#
# 类结构:
#   SimLink        单条 SIM 链路的状态
#   DirectStatus   页面全部状态 = 一个 SimLink 数组, 用 collect() 采集
#
# 指令见 docs/018-屏幕.md 第4节 3.1
#
# 数据来源见 siminfo.py(链路状态/运营商/信号/速率), 本模块只做"取状态 + 生成指令文本"
#
# 本模块由 lcd.py 通过 sys.path 引入(打包装到 /usr/libexec/lcd, 见 Makefile 的 install 段),
# 不碰串口、不写日志:
#   - 串口发送与日志统一由 lcd.py 负责, 两个模块不互相 import
#     (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#   - 本模块无任何串口依赖, 可在开发机上直接 import 验证
#

from siminfo import (RateMeter, STATE_DIALING, STATE_DISABLED, STATE_NO_SIM,
	STATE_OFFLINE, STATE_ONLINE, read_sims)

# 直连模式只认 SIM4 / SIM5 两张卡(见 design.html 的 DIRECT_SIMS), 顺序即屏上从上到下的顺序
# 名字取自 uci 的 sim 段名(sim4 / sim5), 与 /tmp/tracker-sim/<名字> 对应
SIM_NAMES = ("sim4", "sim5")

# SIM 卡 -> 控件名的中间部分, 完整控件名 = 前缀 + 中间部分 + 后缀, 需与串口屏工程一致:
#   PicSim4Op.pic       运营商图标      25 中国移动 / 24 中国联通 / 23 中国电信 / 145 未知
#   PicSim4Online.pic   在线状态图标    30 在线 / 29 已禁用 / 28 未插卡 / 27 离线 / 26 拨号中
#   PicSim4Rsrp.pic     信号格图标      36 满格 / 35 四格 / 34 三格 / 33 两格 / 32 一格 / 31 无服务
#   TextSim4Rsrp.txt    信号强度文本, 有读数时是数值(如 "-101"), 读不到信号时是 "--"
#   FloatSim4Tx.val     上行带宽, 单位为 0.01Mbps(如 12345 即 123.45Mbps)
#   FloatSim4Rx.val     下行带宽, 单位同上
#   NumSim4Rtt.val      RTT 时延(ms)
SIM_WIDGETS = {
	"sim4": "Sim4",
	"sim5": "Sim5",
}

# 运营商 -> PicSimxOp 的图片号
OPERATOR_PICS = {
	"中国移动": 25,
	"中国联通": 24,
	"中国电信": 23,
}
UNKNOWN_OPERATOR_PIC = 145					# 读不到运营商时用"未知"图标

# 在线状态 -> PicSimxOnline 的图片号(与聚合页同一套, 状态由 siminfo 采集)
STATE_PICS = {
	STATE_ONLINE: 30,
	STATE_DISABLED: 29,
	STATE_NO_SIM: 28,
	STATE_OFFLINE: 27,
	STATE_DIALING: 26,
}

# RSRP 门限(dBm) -> PicSimxRsrp 的图片号, 由强到弱排列, 取第一个满足 rsrp >= 门限的档位
RSRP_PICS = (
	(-80, 36),								# >= -80dBm  五格
	(-90, 35),								# >= -90dBm  四格
	(-100, 34),								# >= -100dBm 三格
	(-110, 33),								# >= -110dBm 两格
	(-120, 32),								# >= -120dBm 一格
)
RSRP_NONE_PIC = 31							# 无服务(rsrp 为 None)


# RSRP(dBm) -> PicSimxRsrp 的图片号; rsrp 为 None 表示读不到信号
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


# 单条 SIM 链路的状态
# 参数顺序: SIM 卡名, 运营商, 状态, RSRP(dBm), 上行(Mbps), 下行(Mbps), 时延(ms)
class SimLink:

	def __init__(self, name, operator, state, rsrp, up, down, latency):
		self.name = name					# SIM 卡名, 见 SIM_NAMES
		self.operator = operator			# 运营商, 空串表示读不到(未插卡/已禁用)
		self.state = state					# 在线状态, 取值见 STATE_PICS
		self.rsrp = rsrp					# 信号强度(dBm), None 表示读不到信号
		self.up = up						# 上行速率(Mbps)
		self.down = down					# 下行速率(Mbps)
		self.latency = latency				# 时延(ms)

	# 是否在线: 只有在线链路在屏上有速率与时延读数
	@property
	def online(self):
		return self.state == STATE_ONLINE


# 速率计: 速率靠两次采样的字节数差分得到, 需跨次调用保存上一次的值, 所以放在模块级
_meter = RateMeter()


# 直连模式页面的全部状态: 一个 SIM 链路数组
class DirectStatus:

	def __init__(self, sims=None):
		self.sims = list(sims) if sims else []		# 所有 SIM 链路(list[SimLink]), 顺序即屏上顺序

	# 采集当前状态并返回实例
	@classmethod
	def collect(cls):
		sims = {sim.name: sim for sim in read_sims()}		# 真实数据, 来源见 siminfo.py
		links = []
		for name in SIM_NAMES:
			sim = sims.get(name)
			if sim is None:					# 屏上留了卡槽但系统里没配这张卡
				links.append(SimLink(name, "", STATE_DISABLED, None, 0.0, 0.0, 0))
				continue
			up, down = _meter.rates(sim.dev)	# 没拨号的链路流量为 0, 速率自然是 0
			links.append(SimLink(name, sim.operator, sim.state, sim.rsrp, up, down,
				0))							# TODO 时延: uci openmptcprouter.<simN>.latency
		return cls(links)

	# 转成串口屏指令序列(不含 FF FF FF), 返回列表, 顺序即下发顺序
	def commands(self):
		commands = []
		for sim in self.sims:
			commands.extend(self._sim_commands(sim))
		return commands

	# 生成单张 SIM 卡片(页面上半区左右各一张)的全部指令
	# 只有在线链路有速率与时延读数, 其余状态一律下发 0
	def _sim_commands(self, sim):
		prefix = SIM_WIDGETS[sim.name]
		# 信号强度统一走 txt 下发字符串: 有读数是数值, 读不到信号是 "--"
		rsrp_text = 'Text%sRsrp.txt="%s"' % (prefix, sim.rsrp if sim.rsrp is not None else "--")
		return [
			"Pic%sOp.pic=%d" % (prefix, OPERATOR_PICS.get(sim.operator, UNKNOWN_OPERATOR_PIC)),
			"Pic%sOnline.pic=%d" % (prefix, STATE_PICS[sim.state]),
			"Pic%sRsrp.pic=%d" % (prefix, rsrp_pic(sim.rsrp)),
			rsrp_text,
			"Float%sTx.val=%d" % (prefix, mbps_to_val(sim.up if sim.online else 0)),
			"Float%sRx.val=%d" % (prefix, mbps_to_val(sim.down if sim.online else 0)),
			"Num%sRtt.val=%d" % (prefix, sim.latency if sim.online else 0),
		]
