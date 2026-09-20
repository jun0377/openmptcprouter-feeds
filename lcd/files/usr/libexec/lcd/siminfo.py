# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 链路数据的采集层: 从 uci / tracker-sim / tracker-ovpn / sysfs 读取链路与聚合隧道的真实状态
#
# 数据来源(全部只读, 不改任何配置):
#   uci sim.<simN>            enable 是否启用 / alias 显示名 / usb 模组的 sysfs 路径
#   uci openmptcprouter.<simN>  state 该链路能否上网(omr-tracker 从该链路 ping 通服务器即为 up)
#   /tmp/tracker-sim/<simN>/  模组实时状态, 由 tracker-sim 每 5 秒更新一轮:
#       interface   模组对应的网口名(如 wwan0)
#       sim_status  取卡状态文本(SIM not Inserted / Initialized / Ready / ...)
#       plmn        运营商信息(JSON, long_name 为运营商名)
#       iccid       卡号, 读不到运营商名时用它的前 6 位(IIN)反推
#       hcsq        信号强度(JSON, rsrp_dbm 为 RSRP; sysmode 为 NOSERVICE 表示无服务)
#       monsc       当前驻留小区(hcsq 读不到时用它的 rsrp 兜底)
#       IPv4        拨号成功后的地址, 非空即认为在线
#       timestamp   写入时间, 用于判断这份数据是否已经失效
#   /sys/class/net/<dev>/statistics/  收发字节数, 两次采样差分算出速率
#   /tmp/tracker-ovpn/tracker-ovpn.json  聚合隧道(omrvpn)的探测结果, 见 read_tunnel()
#
# 各页面模块(modeAgg.py / modeDirect.py)只从这里取数据, 不自己读文件;
# 本模块不碰串口、不写配置, 能在开发机上直接 import 验证(缺 uci 时读出空数据)
#

import json									# 解析 tracker-sim / tracker-ovpn 写的 JSON
import os									# 读状态文件与 sysfs 字节数
import re									# 过滤 simN 形式的 uci 段名
import time									# 差分算速率, 判断状态是否过期

from uci import uci_show					# 一次读回整个 uci 配置

SIM_CONFIG = "sim"							# SIM 卡配置所在的 uci 配置文件
OMR_CONFIG = "openmptcprouter"				# omr-tracker 记录各链路探测结果的 uci 配置文件
TRACKER_DIR = "/tmp/tracker-sim"			# tracker-sim 的状态目录, 每个卡一个子目录
TRACKER_TUNNEL = "/tmp/tracker-ovpn/tracker-ovpn.json"		# 聚合隧道的探测结果
NET_STAT_DIR = "/sys/class/net"				# 网口统计目录, 用于读收发字节数
STALE_SECONDS = 30							# 状态文件超过该秒数未更新即视为失效(每 5 秒更新一轮)
OMR_STATE_UP = "up"							# omr-tracker 判定该链路能上网
TUNNEL_OK = "OK"							# omr-tracker 判定聚合隧道可达

SIM_NAME_PATTERN = re.compile(r"^sim\d+$")	# uci 里 SIM 段名形如 sim1 / sim2

# 链路状态: 与串口屏上的五张状态图一一对应(见各页面模块的 STATE_PICS)
STATE_ONLINE = "在线"						# 拨号成功, 有 IP
STATE_DIALING = "拨号中"					# 卡就绪、有服务, 但还没拿到 IP
STATE_OFFLINE = "离线"						# 无服务 / 读不到数据 / 模组不在
STATE_NO_SIM = "未插卡"						# 卡没插好或被移除
STATE_DISABLED = "已禁用"					# uci 里 enable 未开

# ICCID 前 6 位(IIN) -> 运营商, 与 oui-app-home 的 sim.lua 保持一致(仅中国大陆)
IIN_OPERATORS = {
	"898600": "中国移动", "898602": "中国移动",
	"898604": "中国移动", "898607": "中国移动",
	"898601": "中国联通", "898606": "中国联通",
	"898609": "中国联通",
	"898603": "中国电信", "898611": "中国电信",
	"898615": "中国广电",
}


# 读 tracker-sim 写的单个状态文件, 去掉首尾空白; 文件不存在按空串处理
def _read_file(name, item):
	try:
		with open(os.path.join(TRACKER_DIR, name, item)) as fd:
			return fd.read().strip()
	except OSError:								# 模组未识别 / tracker 还没写过
		return ""


# 读一个 JSON 文件, 解析失败或内容为空返回 {}
def _read_json_file(path):
	try:
		with open(path) as fd:
			data = json.loads(fd.read())
	except (OSError, ValueError):
		return {}
	return data if isinstance(data, dict) else {}


# 读 tracker-sim 写的 JSON 状态文件, 解析失败或内容为空返回 {}
def _read_json(name, item):
	return _read_json_file(os.path.join(TRACKER_DIR, name, item))


# "2026-09-18 12:00:00" -> 时间戳; 解析不出来返回 None(当作不知道时间)
def _parse_epoch(text):
	try:
		return time.mktime(time.strptime(text, "%Y-%m-%d %H:%M:%S"))
	except ValueError:
		return None


# 状态是否已失效: tracker-sim 每 5 秒写一次 timestamp, 太久没更新说明模组/tracker 有问题
def _is_stale(text):
	epoch = _parse_epoch(text)
	return epoch is not None and (time.time() - epoch) > STALE_SECONDS


# 是否已入网(有服务): hcsq 缺失或 sysmode 为 NOSERVICE 都算没服务
def _has_service(hcsq):
	return bool(hcsq) and hcsq.get("sysmode") not in (None, "", "NOSERVICE")


# RSRP(dBm): 优先 hcsq.rsrp_dbm(tracker 已换算成 dBm), 读不到再用当前驻留小区的 rsrp
def _rsrp(hcsq, monsc):
	value = hcsq.get("rsrp_dbm")
	if isinstance(value, (int, float)):
		return int(value)
	if hcsq and not _has_service(hcsq):			# hcsq 已明确无服务, 小区里的旧读数不再作数
		return None
	cell = monsc.get("cell") or monsc.get("nr_cell") or monsc.get("lte_cell") or {}
	try:
		return int(cell.get("rsrp"))
	except (TypeError, ValueError):
		return None


# 运营商: plmn 里的名称优先, 为空时用 ICCID 前 6 位反推; 都取不到返回空串
def _operator(plmn, iccid):
	for key in ("long_name", "short_name", "spn_name"):
		value = str(plmn.get(key, "")).strip()
		if value:
			return value
	if len(iccid) >= 6:
		return IIN_OPERATORS.get(iccid[:6], "")
	return ""


# 单张 SIM 卡的状态
class SimInfo:

	def __init__(self, name, alias, enable, module_exist, dev, sim_status, ipv4,
			service, stale, operator, rsrp, reachable):
		self.name = name					# uci 段名, 如 sim1
		self.alias = alias					# 显示名, 如 5G-1
		self.enable = enable				# uci 里是否启用
		self.module_exist = module_exist	# 模组的 sysfs 路径是否存在(模组插好没有)
		self.dev = dev						# 模组对应的网口名, 如 wwan0
		self.sim_status = sim_status		# 取卡状态文本
		self.ipv4 = ipv4					# 拨号拿到的地址, 空串表示还没拨上
		self.service = service				# 是否已入网
		self.stale = stale					# 状态文件是否已失效
		self.operator = operator			# 运营商, 空串表示读不到
		self.rsrp = rsrp					# 信号强度(dBm), None 表示读不到
		self.reachable = reachable			# omr-tracker 判定能上网(从该链路 ping 通服务器)
		self.state = self._resolve_state()

	# 链路状态, 按优先级判定, 取值见 STATE_*
	def _resolve_state(self):
		if not self.enable:											# 用户关了这张卡
			return STATE_DISABLED
		if not self.module_exist:									# 模组不在(没插或没上电)
			return STATE_OFFLINE
		if self.stale:												# 数据太久没更新, 不报在线
			return STATE_OFFLINE
		if "not Inserted" in self.sim_status or "removed" in self.sim_status:
			return STATE_NO_SIM
		if "Initialized" in self.sim_status or "Ready" in self.sim_status:
			if self.ipv4:											# 卡就绪且有地址 = 在线
				return STATE_ONLINE
			return STATE_DIALING if self.service else STATE_OFFLINE
		return STATE_OFFLINE										# 初始化中/锁卡/卡错误等

	# 是否在线: 各页面按同一口径判断, 不必自己去比字符串
	@property
	def online(self):
		return self.state == STATE_ONLINE

	# 拨号成功且能上网: 先要在线(拿到 IP), 再要 omr-tracker 判定这条链路能 ping 通服务器
	@property
	def internet(self):
		return self.online and self.reachable


# 网口速率计: 速率只能靠两次采样的字节数差分得到, 因此需要跨次调用保存上一次的值
# 用法: 每次屏来取数据时调用一次 rates(), 两次之间的时间间隔就是采样周期
class RateMeter:

	def __init__(self):
		self._last = {}						# 网口名 -> (采样时刻, 收到的字节数, 发出的字节数)

	# 返回 (上行 Mbps, 下行 Mbps); 第一次调用没有基准, 返回 (0.0, 0.0)
	def rates(self, dev):
		if not dev:
			return 0.0, 0.0
		try:
			with open(os.path.join(NET_STAT_DIR, dev, "statistics", "rx_bytes")) as fd:
				rx = int(fd.read())
			with open(os.path.join(NET_STAT_DIR, dev, "statistics", "tx_bytes")) as fd:
				tx = int(fd.read())
		except (OSError, ValueError):								# 网口不存在或内容异常
			return 0.0, 0.0

		now = time.monotonic()
		last = self._last.get(dev)
		self._last[dev] = (now, rx, tx)
		if last is None or now <= last[0]:
			return 0.0, 0.0

		elapsed = now - last[0]
		up = (tx - last[2]) * 8 / elapsed / 1000000					# 上行 = 本机发出的字节
		down = (rx - last[1]) * 8 / elapsed / 1000000				# 下行 = 本机收到的字节
		return max(up, 0.0), max(down, 0.0)							# 计数回绕时按 0 处理


# simN 里的编号, 用于按 sim1 / sim2 ... 排序
def _sim_number(name):
	return int(name[3:])


# 读一个 uci 配置文件里的 simN 段, 返回 {sim1: {enable: "true", alias: "5G-1", ...}, ...}
# 同一个 option 出现多次即为 uci list(如锁小区的 nrPciPcid), 只保留第一条:
# 屏上每个参数只有一个控件, 与网页"多条取第一条显示"的口径一致
def _read_sim_sections(config):
	settings = {}
	for line in uci_show(config).splitlines():
		key, _, raw = line.partition("=")							# 形如 sim.sim1.enable='true'
		parts = key.split(".")
		if len(parts) < 2 or not SIM_NAME_PATTERN.match(parts[1]):
			continue
		section = settings.setdefault(parts[1], {})
		if len(parts) >= 3:											# 只保留 option, 忽略段声明行
			section.setdefault(parts[2], raw.strip().strip("'"))
	return settings


# 读 uci sim 段(卡的开关与显示名)
def read_sim_settings():
	return _read_sim_sections(SIM_CONFIG)


# 读 uci openmptcprouter 段(omr-tracker 写的每链路探测结果: state / latency)
def read_omr_settings():
	return _read_sim_sections(OMR_CONFIG)


# 读单张卡的完整状态
def _read_sim(name, options, omr):
	lines = _read_file(name, "interface").splitlines()				# 有多个网口时取第一个
	hcsq = _read_json(name, "hcsq")
	monsc = _read_json(name, "monsc")
	stale = _is_stale(_read_file(name, "timestamp"))
	usb = options.get("usb", "")
	info = SimInfo(
		name = name,
		alias = options.get("alias", ""),
		enable = options.get("enable", "") in ("1", "true", "on"),
		module_exist = bool(usb) and os.path.exists(usb),
		dev = lines[0].strip() if lines else "",
		sim_status = _read_file(name, "sim_status"),
		ipv4 = _read_file(name, "IPv4"),
		service = _has_service(hcsq),
		stale = stale,
		operator = _operator(_read_json(name, "plmn"), _read_file(name, "iccid")),
		rsrp = _rsrp(hcsq, monsc),
		reachable = omr.get("state", "") == OMR_STATE_UP,
	)
	if info.state in (STATE_DISABLED, STATE_NO_SIM) or stale:		# 卡不可用/数据过期时不报信号
		info.rsrp = None
	return info


# 读全部 SIM 卡: names 省略时取 uci 里所有 simN, settings / omr 省略时自己去 uci 读
# 三者都可显式传入, 便于在开发机上用假数据验证本模块
def read_sims(names=None, settings=None, omr=None):
	if settings is None:
		settings = read_sim_settings()
	if omr is None:
		omr = read_omr_settings()
	if names is None:
		names = sorted(settings, key=_sim_number)
	return [_read_sim(name, settings.get(name, {}), omr.get(name, {})) for name in names]


# 聚合隧道(omrvpn)的探测结果: 网页 ModeAggregate 的连接状态与时延取自同一份数据
class TunnelStatus:

	def __init__(self, reachable, latency):
		self.reachable = reachable		# 隧道是否可达(能通到聚合服务器)
		self.latency = latency			# 隧道时延(ms), 不可达时为 0


# 读聚合隧道的探测结果, 由 omr-tracker 的 omrvpn 实例不断刷新
# 文件不存在或 status 不是 OK(探测失败 / 还没出结果)都按不可达处理, 时延为 0
def read_tunnel():
	data = _read_json_file(TRACKER_TUNNEL)
	if data.get("status") != TUNNEL_OK:
		return TunnelStatus(False, 0)
	latency = data.get("latency")
	if not isinstance(latency, (int, float)):						# 隧道通但没测到时延
		latency = 0
	return TunnelStatus(True, int(latency))
