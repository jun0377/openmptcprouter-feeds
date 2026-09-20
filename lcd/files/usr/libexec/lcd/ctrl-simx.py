# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 运维模式->链路设置->SIMx链路(屏幕05)的状态: 采集该链路的设置参数并生成串口屏指令
#
# 数据来源(全部只读): uci 配置文件 sim 的 simN 段(sim.simN.*)
#   enable / net / apn / auth / user / passwd		链路使能与拨号参数
#   ltePciLockEnable + ltePciPcid|Band|Freq		锁 LTE 小区
#   nrPciLockEnable  + nrPciPcid|Band|Freq|Scs		锁 5G 小区
# 网页「广域网 -> SIM 卡详情」(oui-app-network-wan) 读写的就是这些选项
#
# 类结构:
#   LockStatus   一个制式的小区锁定参数(LTE 没有子载波间隔)
#   SimxStatus   单条链路的全部设置, 用 collect(name) 采集, name 形如 sim1
#
# 指令见 docs/018-屏幕.md 第4节 6
#
# 本模块由 lcd.py 通过 sys.path 引入(打包装到 /usr/libexec/lcd, 见 Makefile 的 install 段),
# 注意文件名里的连字符不能写 import 语句, lcd.py 用 importlib 按名字加载本模块;
# 不碰串口、不写日志:
#   - 串口发送与日志统一由 lcd.py 负责, 两个模块不互相 import
#     (主程序以 __main__ 名运行, 私有模块里 import lcd 会把主程序再执行一遍)
#   - 本模块无任何串口依赖, 可在开发机上直接 import 验证
#

from siminfo import read_sim_settings

UNKNOWN = "--"								# 读不到时屏上的占位
LOCKED = "locked"							# uci 里"已锁小区"
UNLOCKED = "unlocked"						# uci 里"未锁小区 / 还没设置过"的占位值

# 链路使能: 两个按钮没有互斥, 每次都要一起下发, 顺序即屏上从左到右
ENABLE_BUTTONS = ("BtnEnable", "BtnDisable")

# 入网方式: uci sim.simN.net 的取值 -> 屏上按钮, 顺序即屏上从左到右
NET_BUTTONS = {
	"auto": "BtnNetAUTO",
	"sa": "BtnNetSA",
	"nsa": "BtnNetNSA",
	"lte": "BtnNetLTE",
}
NET_DEFAULT = "auto"						# 读不到或取值异常时按自动

# 鉴权方式: uci sim.simN.auth 的取值 -> 屏上按钮, 顺序即屏上从左到右
AUTH_BUTTONS = {
	"none": "BtnAuthNone",
	"auto": "BtnAuthAuto",
	"pap": "BtnAuthPAP",
	"chap": "BtnAuthCHAP",
}
AUTH_DEFAULT = "none"						# 读不到或取值异常时按无鉴权

# 锁小区开关: 两个按钮没有互斥, 每次都要一起下发 (开 / 关)
LTE_LOCK_BUTTONS = ("BtnLteLockEn", "BtnLteLockDis")
NR_LOCK_BUTTONS = ("Btn5gLockEn", "Btn5gLockDis")

# 频段: uci 里存的是不带前缀的编号(如 78), 屏上按制式补前缀(如 n78 / B3)
BAND_PREFIX = {"lte": "B", "nr": "n"}

# 子载波间隔: uci 里存的是索引, 屏上显示 kHz(与网页下拉里的选项一一对应)
SCS_TEXTS = ("15kHz", "30kHz", "60kHz", "120kHz", "240kHz")


# 文本类参数: 空值在屏上显示占位符, 避免控件留白看不出是"没读到"
def _text(value):
	return value.strip() or UNKNOWN


# uci list 的第一项(屏上每个参数只有一个控件); 空值或未设置占位(unlocked)一律返回空串
def _first(options, key):
	value = options.get(key, "").strip()
	return "" if value == UNLOCKED else value


# 数值类参数: 十进制串转整数, 未设置或不是数字一律返回 0(屏上 Num 控件只认数字)
def _number(value):
	return int(value) if value.isdigit() else 0


# 频段: 配置里是不带前缀的编号(如 78), 屏上补前缀(如 n78); 已带前缀或异常的值原样显示
def _band(value, kind):
	if not value:
		return UNKNOWN
	return BAND_PREFIX[kind] + value if value.isdigit() else value


# 子载波间隔: 配置里是索引(0 = 15kHz ... 4 = 240kHz), 屏上显示 kHz; 越界或异常的值原样显示
def _scs(value):
	if not value:
		return UNKNOWN
	if value.isdigit() and int(value) < len(SCS_TEXTS):
		return SCS_TEXTS[int(value)]
	return value


# 按钮组: 取值 -> 屏上控件; 取值大小写不限(网页写入过 AUTO / SA / PAP 这类大写), 未识别时按默认项
def _active(buttons, value, default):
	return buttons.get(value.strip().lower(), buttons[default])


# 一组按钮(没有互斥): 命中的一项下发 1, 其余下发 0
def _buttons(widgets, active):
	return ["%s.val=%d" % (widget, 1 if widget == active else 0) for widget in widgets]


# 一组开关按钮(开 / 关): 开时第一项为 1, 关时第二项为 1
def _switch_buttons(widgets, on):
	return _buttons(widgets, widgets[0] if on else widgets[1])


# 一个制式的小区锁定参数(LTE 没有子载波间隔, scs 传空串)
class LockStatus:

	def __init__(self, locked, pcid, freq, band, scs=""):
		self.locked = locked			# 锁定开关
		self.pcid = pcid				# 物理小区 ID, 未设置时为 0
		self.freq = freq				# 频点(EARFCN / ARFCN), 未设置时为 0
		self.band = band				# 频段, 未设置时为占位符
		self.scs = scs					# 子载波间隔, 只有 NR(5G) 有


# 读一个制式的小区锁定参数: kind 为 lte / nr, 两者在 uci 里的选项名只差前缀
def _read_lock(options, kind):
	return LockStatus(
		options.get(kind + "PciLockEnable", "") == LOCKED,
		_number(_first(options, kind + "PciPcid")),
		_number(_first(options, kind + "PciFreq")),
		_band(_first(options, kind + "PciBand"), kind),
		_scs(_first(options, kind + "PciScs")) if kind == "nr" else "",		# LTE 没有子载波间隔
	)


# 运维模式->SIMx链路(屏幕05)的全部设置
class SimxStatus:

	def __init__(self, enabled, net, apn, auth, user, passwd, lte_lock, nr_lock):
		self.enabled = enabled			# 链路使能
		self.net = net					# 入网方式命中的按钮控件
		self.apn = apn					# APN
		self.auth = auth				# 鉴权方式命中的按钮控件
		self.user = user				# 用户名
		self.passwd = passwd			# 密码
		self.lte_lock = lte_lock		# 锁 LTE 小区参数(LockStatus)
		self.nr_lock = nr_lock			# 锁 5G 小区参数(LockStatus)

	# 采集指定链路的设置并返回实例, name 形如 sim1(与 uci 段名、屏上卡槽号一致)
	@classmethod
	def collect(cls, name):
		options = read_sim_settings().get(name, {})
		return cls(
			enabled = options.get("enable", "") in ("1", "true", "on"),
			net = _active(NET_BUTTONS, options.get("net", ""), NET_DEFAULT),
			apn = _text(options.get("apn", "")),
			auth = _active(AUTH_BUTTONS, options.get("auth", ""), AUTH_DEFAULT),
			user = _text(options.get("user", "")),
			passwd = _text(options.get("passwd", "")),
			lte_lock = _read_lock(options, "lte"),
			nr_lock = _read_lock(options, "nr"),
		)

	# 转成串口屏指令序列(不含 FF FF FF), 返回列表, 顺序即下发顺序
	def commands(self):
		commands = []
		# SIM 参数设置: 链路开关 / 入网方式 / APN / 鉴权方式 / 用户名 / 密码
		commands.extend(_switch_buttons(ENABLE_BUTTONS, self.enabled))
		commands.extend(_buttons(NET_BUTTONS.values(), self.net))
		commands.append('TextAPN.txt="%s"' % self.apn)
		commands.extend(_buttons(AUTH_BUTTONS.values(), self.auth))
		commands.append('TextUser.txt="%s"' % self.user)
		commands.append('TextPasswd.txt="%s"' % self.passwd)
		# 锁LTE小区: 锁定开关 / PCID / 频点 / 频段
		commands.extend(_switch_buttons(LTE_LOCK_BUTTONS, self.lte_lock.locked))
		commands.append("NumLtePCID.val=%d" % self.lte_lock.pcid)
		commands.append("NumLteFreq.val=%d" % self.lte_lock.freq)
		commands.append('TextLteBand.txt="%s"' % self.lte_lock.band)
		# 锁5G小区: 比 LTE 多一个子载波间隔
		commands.extend(_switch_buttons(NR_LOCK_BUTTONS, self.nr_lock.locked))
		commands.append("Num5gPCID.val=%d" % self.nr_lock.pcid)
		commands.append("Num5gFreq.val=%d" % self.nr_lock.freq)
		commands.append('Text5gBand.txt="%s"' % self.nr_lock.band)
		commands.append('Text5gSCS.txt="%s"' % self.nr_lock.scs)
		return commands
