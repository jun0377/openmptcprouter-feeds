# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 4G / 5G 基站状态的采集层: 与 siminfo.py 同一定位, 只提供数据, 不生成串口指令
#
# 数据来源: 基站模组挂在 LAN 口, MAC 地址取自 UCI lcd.bts.mac;
# 每次轮询都按 MAC 重新解析 IP(DHCP 租约 + ARP 邻居表), 模组 IP 变化后能自动跟上;
# 再用 lcd.bts 的 SSH 参数(见 btsremote.py)登录模组, 直接执行查询:
#   5G: OpState 判断激活:
#         odi -n oamProcess getcf Device.Services.FAPService.1.CellConfig.1.NR.RAN.OpState
#       getcf 读配置树; odi -n duapp0 display-ue-info 读终端数
#   4G: 按平台自适应(FGSL 本地 odi / FGBD expect+mdf):
#       先裸跑工具取注册列表, 再查 callpctrl0 ue-list;
#       输出含 "allocated in cell" 即激活
#   SN: 读 confdb_v2.xml 的 <SerialNumber>
#
# 每次查询间隔取自 UCI lcd.bts.intervalSec, 未配置时默认 60 秒.
# 查询在后台线程里执行, read_bts() 只返回最近一次缓存, 不阻塞串口主循环(屏幕每 3 秒取一次状态)
#
# 字段与 docs/018-屏幕.md 3.1 / 3.2 一致:
#   online  是否在线 = 是否激活   在线 Pic*Online.pic=43 / 离线 42
#   pci     物理小区 ID -> NumLteID / Num5GID
#   ue      终端数      -> NumLteUser / Num5GUser
#

import base64								# 4G 脚本需要编码后通过 ssh 下发
import os									# 读 /proc/net/arp、生成临时文件名
import subprocess							# 执行 ip neigh
import threading							# 后台轮询线程
import time									# 查询间隔

import btsremote							# SSH 执行模块(与本文件同目录), 见 btsremote.py
from logger import log						# 状态变化与失败原因记日志
from uci import uci_get						# 读取 lcd 配置

DEFAULT_INTERVAL = 60						# 查询间隔默认值(秒), 对应 lcd.bts.intervalSec
PROBE_TIMEOUT = 5							# SSH 连通性探测超时(秒)
PLATFORM_TIMEOUT = 10						# 平台识别超时(秒)
QUERY_5G_TIMEOUT = 60						# 5G 查询超时(秒)
QUERY_4G_TIMEOUT = 240						# 4G 查询超时(秒)
NEIGH_TIMEOUT = 2							# ip neigh 的超时(秒)
ARP_FILE = "/proc/net/arp"					# ip 命令不可用时的 ARP 表回退
DHCP_LEASES = "/tmp/dhcp.leases"			# dnsmasq 租约, 记录 MAC -> IP

BS_HOST_4G = "192.168.15.2"					# FGBD 的 4G 内核地址
PASS_4G_FGBD = "root123"					# FGBD 的 4G 内核密码

LABELS = ("4G", "5G")						# 页面上两张基站卡片的顺序

# SSH 登录参数取自 /etc/config/lcd 的 bts 节, 默认值与模组出厂配置一致
REMOTE_USER = uci_get("lcd.bts.user") or "root"
REMOTE_PORT = uci_get("lcd.bts.port") or None
REMOTE_KEY = uci_get("lcd.bts.key") or btsremote.KEY_FILE
REMOTE_PASSWORD = uci_get("lcd.bts.password") or "root"

_last_state = (None, None)					# (是否在线, IP), 只在变化时记日志, 避免每次轮询刷屏
_last_ip = None								# 最近一次解析到的 IP, 只在变化时记日志
_lock = threading.Lock()					# 保护 _details / _snapshot
_worker = None								# 后台轮询线程
_worker_lock = threading.Lock()				# 保证线程只启动一次
_platform = ""								# 基站平台: FGSL / FGBD, 首次查询时识别
_5g_active = False							# 最近一次查询的 5G 激活状态(OpState=1)
_4g_active = False							# 最近一次查询的 4G 激活状态(allocated in cell)


# 5G 查询: 配置树 + 终端数, 输出 KEY=VALUE 行
_FIVE_G_CMD = r'''ODI=/opt/bbu/bts/bin/odi
[ -x "$ODI" ] || { echo "5G:FAIL"; exit 1; }
g() {
	"$ODI" -n oamProcess getcf "$1" 2>/dev/null | sed -n 's/.*nodeValue is \[\(.*\)\].*/\1/p' | head -1
}
SN=""
for c in /opt/bbu/oam/cm/confdb_v2.xml /data/oem/5G_PKS/cm/confdb_v2.xml; do
	[ -f "$c" ] || continue
	SN=$(sed -n 's:.*<SerialNumber>\([^<]*\)</SerialNumber>.*:\1:p' "$c" 2>/dev/null | head -1)
	[ -n "$SN" ] && break
done
echo "SN=$SN"
echo "GNBNAME=$(g 'Device.Services.FAPService.1.FAPControl.NR.RAN.Common.gNBName')"
echo "5G:1:OPSTATE=$(g 'Device.Services.FAPService.1.CellConfig.1.NR.RAN.OpState')"
for i in 1 2 3; do
	cellid=$(g "Device.Services.FAPService.1.CellConfig.$i.NR.RAN.Common.CellIdWithinGnb")
	[ -z "$cellid" ] && continue
	echo "5G:$i:CELLID=$cellid"
	echo "5G:$i:TAC=$(g "Device.Services.FAPService.1.CellConfig.$i.NR.CN.TA.1.TAC")"
	echo "5G:$i:PCI=$(g "Device.Services.FAPService.1.CellConfig.$i.NR.RAN.RF.PhyCellID")"
	echo "5G:$i:SSB=$(g "Device.Services.FAPService.1.CellConfig.$i.NR.RAN.PHY.SsbConfig.SsbPower")"
	echo "5G:$i:BAND=$(g "Device.Services.FAPService.1.CellConfig.$i.NR.RAN.RF.FreqBandIndicator")"
	echo "5G:$i:ARFCNDL=$(g "Device.Services.FAPService.1.CellConfig.$i.NR.RAN.RF.NRARFCNDL")"
	echo "5G:$i:ARFCNUL=$(g "Device.Services.FAPService.1.CellConfig.$i.NR.RAN.RF.NRARFCNUL")"
	echo "5G:$i:BWDL=$(g "Device.Services.FAPService.1.CellConfig.$i.NR.RAN.RF.DLBandwidth")"
	echo "5G:$i:BWUL=$(g "Device.Services.FAPService.1.CellConfig.$i.NR.RAN.RF.ULBandwidth")"
done
UE=$("$ODI" -n duapp0 display-ue-info 2>&1)
echo "5G:UE_COUNT=$(printf '%s\n' "$UE" | sed -n 's/.*number of UE.*: *\([0-9][0-9]*\).*/\1/p' | head -1)"
echo "5G:OK"'''

# FGBD 的 4G expect: 跳到 192.168.15.2, 把内层脚本 base64 解码后执行
_FOUR_G_EXPECT = r'''set pw [lindex $argv 0]
set f [open [lindex $argv 1] r]
gets $f cmd
close $f
set timeout 600
spawn ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null root@192.168.15.2
expect {
  "assword:" { send -- "$pw\r"; exp_continue }
  -re "~#|# " { }
}
send -- "echo $cmd | base64 -d | bash -s\r"
expect -re "~#|# "
send -- "exit\r"
expect eof'''

# 4G 脚本模板: 平台识别后替换 @LD@ / @TOOL@ / @MDF@
# 先裸跑工具取注册列表, 拿到 oamprocess / callpctrl0 端口;
# 4G 激活状态 = callpctrl0 ue-list 输出含 "allocated in cell"
_FOUR_G_INNER_TMPL = r'''@LD@TOOL_4G=@TOOL@
MDF_4G=@MDF@
PORT=""
CP_PORT=""
resolve_ports() {
	LIST=$($TOOL_4G 2>/dev/null)
	PORT=$(printf '%s\n' "$LIST" | sed -n 's/.*oamprocess.*-p *\([0-9][0-9]*\).*/\1/p' | head -1)
	CP_PORT=$(printf '%s\n' "$LIST" | sed -n 's/.*callpctrl0.*-p *\([0-9][0-9]*\).*/\1/p' | head -1)
}
for _ in 1 2 3; do
	resolve_ports
	[ -n "$PORT" ] && break
	sleep 2
done
getv() {
	v=$($TOOL_4G -p "$PORT" getcf "$1" 2>/dev/null | grep nodeValue | sed "s/.*\[//; s/\]//" | head -1)
	[ -z "$v" ] && v=$($TOOL_4G -p "$PORT" getcf "$1" 2>/dev/null | grep nodeValue | sed "s/.*\[//; s/\]//" | head -1)
	echo "$v"
}
if [ -n "$PORT" ]; then
	for f in 1 2 3 4 5 6; do
		e=$(getv Device.Services.FAPService.$f.CellConfig.LTE.RAN.RF.EARFCNDL)
		[ -z "$e" ] && continue
		echo "4G:$f:EARFCNDL=$e"
		for leaf in RAN.Common.CellIdentity EPC.TAC RAN.RF.PhyCellID RAN.RF.FreqBandIndicator RAN.RF.EARFCNUL RAN.RF.DLBandwidth RAN.RF.ULBandwidth; do
			echo "4G:$f:$leaf=$(getv Device.Services.FAPService.$f.CellConfig.LTE.$leaf)"
		done
	done
fi
run_mdf_n() {
	out=""
	i=0
	while [ $i -lt 3 ]; do
		out=$($MDF_4G -n "$@" 2>&1)
		case "$out" in
			*"could not get the server's port"*) sleep 1 ;;
			*) printf '%s\n' "$out"; return 0 ;;
		esac
		i=$((i + 1))
	done
	printf '%s\n' "$out"
}
if [ -n "$CP_PORT" ]; then
	UE=$($MDF_4G -p "$CP_PORT" ue-list 2>&1)
else
	UE=$(run_mdf_n callpctrl0 ue-list)
fi
if printf '%s\n' "$UE" | grep -q "allocated in cell"; then
	echo "4G:ACTIVE"
else
	echo "4G:INACTIVE"
fi
if printf '%s\n' "$UE" | grep -qi "no UEs allocated"; then
	UECNT=0
else
	UECNT=$(printf '%s\n' "$UE" | grep -oi "Crnti" | wc -l | tr -d ' ')
fi
echo "4G:UE_COUNT=$UECNT"
if [ -n "$PORT" ]; then
	ALARM=$($MDF_4G -p "$PORT" show-alarm-list 2>&1)
	ALARMCNT=$(printf '%s\n' "$ALARM" | sed -n '/Active Alarm List:/,/^====/p' | grep -c "^[0-9][0-9][0-9]")
else
	ALARMCNT=0
fi
echo "4G:ALARM_COUNT=$ALARMCNT"
echo "4G:OK"'''

_TDD_BANDS = {38, 39, 40, 41, 77, 78, 79}	# 常见 TDD 频段
_FDD_BANDS = {1, 3, 5, 8, 28}				# 常见 FDD 频段


# 单个小区的静态配置参数(5G 或 LTE)
# arfcn_dl/arfcn_ul: 5G 为 NRARFCN, LTE 为 EARFCN
class BtsCell:

	def __init__(self, name, cell_id, tac, pci, ssb, band, arfcn_dl, arfcn_ul, bw_dl, bw_ul, duplex):
		self.name = name			# 小区名称
		self.cell_id = cell_id		# CellID(5G: CellIdWithinGnb, LTE: ECI 低 8 位)
		self.tac = tac				# TAC
		self.pci = pci				# 物理小区 ID
		self.ssb = ssb				# 5G SSB 功率, LTE 为空
		self.band = band			# 频带指示
		self.arfcn_dl = arfcn_dl	# 下行频点
		self.arfcn_ul = arfcn_ul	# 上行频点
		self.bw_dl = bw_dl			# 下行带宽
		self.bw_ul = bw_ul			# 上行带宽
		self.duplex = duplex		# 双工方式(FDD/TDD/N/A)


# 单个基站的实时状态: 页面上 4G / 5G 各一张卡片
class BtsInfo:

	def __init__(self, label, online, pci, ue, name="", sn="", cells=None):
		self.label = label			# 制式, "4G" / "5G"
		self.online = online		# 是否在线
		self.pci = pci				# 第一张小区的物理小区 ID, 供屏幕使用
		self.ue = ue				# 终端数, 5G/4G 均来自状态查询
		self.name = name			# 基站名称(gNBName)
		self.sn = sn				# 基站序列号
		self.cells = list(cells) if cells else []	# 该制式下所有小区(list[BtsCell])

	# 第一张小区的名称, 屏上单张卡片取第一小区
	@property
	def cell_name(self):
		return self.cells[0].name if self.cells else ""


# 最近一次解析出的静态参数与状态
# 结构: {"name":..., "sn":..., "cells": {"4G": [...], "5G": [...]}, "ue": {"4G": 0, "5G": 0}, "alarms": 0}
_details = {"name": "", "sn": "", "cells": {"4G": [], "5G": []}, "ue": {"4G": 0, "5G": 0}, "alarms": 0}

# 最近一次生成的基站状态, 初始全部离线
_snapshot = [BtsInfo(label, False, 0, 0) for label in LABELS]


# MAC 规范化: 接受 AA:BB:... / aa-bb-... / aabbcc... 等写法, 非法时返回空串
def _norm_mac(value):
	hexs = "".join(c for c in value.lower() if c in "0123456789abcdef")
	if len(hexs) != 12:
		return ""
	return ":".join(hexs[i:i + 2] for i in range(0, 12, 2))


# 读取查询间隔(lcd.bts.intervalSec), 缺失或非正整数时用默认值
def _load_interval():
	raw = uci_get("lcd.bts.intervalSec")
	if raw:
		try:
			value = int(raw)
			if value > 0:
				return value
		except ValueError:
			pass
	return DEFAULT_INTERVAL


MAC = _norm_mac(uci_get("lcd.bts.mac") or "")	# 规范化后的模组 MAC, 空串表示未配置或格式非法
INTERVAL = _load_interval()						# 两次查询的间隔(秒)


# 从 DHCP 租约查 IP: 每行格式为 <过期时间> <MAC> <IP> <主机名> <客户端ID>
def _ip_from_leases(mac):
	ip = None
	try:
		with open(DHCP_LEASES, "r", encoding="utf-8", errors="replace") as fp:
			for line in fp:
				parts = line.split()
				if len(parts) >= 3 and _norm_mac(parts[1]) == mac:
					ip = parts[2]
	except OSError:
		pass
	return ip


# 从 ARP 邻居表查 IP: 优先 ip neigh, 失败时退回 /proc/net/arp
def _ip_from_arp(mac):
	try:
		proc = subprocess.run(["ip", "neigh", "show"], capture_output=True, text=True, timeout=NEIGH_TIMEOUT)
		if proc.returncode == 0:
			for line in proc.stdout.splitlines():
				parts = line.split()
				if "lladdr" not in parts:
					continue
				idx = parts.index("lladdr")
				if idx + 1 < len(parts) and _norm_mac(parts[idx + 1]) == mac:
					if parts[-1].upper() not in ("FAILED", "INCOMPLETE"):
						return parts[0]
	except (OSError, subprocess.SubprocessError):
		pass
	try:
		with open(ARP_FILE, "r", encoding="utf-8", errors="replace") as fp:
			for line in fp:
				parts = line.split()
				if len(parts) >= 4 and _norm_mac(parts[3]) == mac:
					try:
						if int(parts[2], 16) & 0x2:
							return parts[0]
					except ValueError:
						pass
	except OSError:
		pass
	return None


# 按 MAC 解析模组当前 IP: 先查 DHCP 租约, 再查 ARP 邻居表
def resolve_ip(mac):
	mac = _norm_mac(mac)
	if not mac:
		return None
	return _ip_from_leases(mac) or _ip_from_arp(mac)


# 在基站上执行一条命令, 登录参数统一走 lcd.bts 配置
def _remote_run(ip, cmd, timeout=PROBE_TIMEOUT):
	return btsremote.run(ip, REMOTE_USER, cmd, password=REMOTE_PASSWORD,
						 port=REMOTE_PORT, key=REMOTE_KEY, timeout=timeout)


# 平台识别: sn -r 的 SN_b 前缀最权威; 拿不到时看站内是否有 sshpass
def _detect_platform(ip):
	cmd = (
		"snb=$(sh -lc 'sn -r' 2>/dev/null | grep -oE 'SN_b: *(FGSL|FGBD)-V' | head -1 | grep -oE 'FGSL|FGBD'); "
		"if [ -n \"$snb\" ]; then echo \"$snb\"; "
		"elif [ -x /appfs/bbu/rootfs/bts/bin/sshpass ]; then echo FGSL; "
		"else echo FGBD; fi"
	)
	rc, out, err = _remote_run(ip, cmd, timeout=PLATFORM_TIMEOUT)
	platform = ""
	for line in reversed(out.splitlines()):
		value = line.strip()
		if value in ("FGSL", "FGBD"):
			platform = value
			break
	if not platform:
		platform = "FGBD"					# 与参考脚本默认一致
	return platform, rc, out, err


# 平台只识别一次; 识别失败时本周期按 FGBD 处理, 下周期再试
def _get_platform(ip):
	global _platform
	if _platform:
		return _platform
	platform, rc, out, err = _detect_platform(ip)
	if rc == 0:
		_platform = platform
		log("bts platform: %s (out=%r)" % (platform, _last_line(out)))
		return platform
	detail = (err or out).strip() or ("rc=%d" % rc)
	log("bts platform detect failed: rc=%d err=%r last=%r detail=%r" % (
		rc, (err or "").strip()[:200], _last_line(out), detail[:200]))
	return "FGBD"


# 按平台生成 4G 内层脚本
def _four_g_inner(platform):
	if platform == "FGSL":
		ld = "export LD_LIBRARY_PATH=/data/appfs/bbu/rootfs/bts/lib\n"
		tool = "/opt4g/bts/bin/odi"
	else:
		ld = ""
		tool = "/opt4g/bts/bin/mdf"
	return (_FOUR_G_INNER_TMPL
			.replace("@LD@", ld)
			.replace("@TOOL@", tool)
			.replace("@MDF@", "/opt4g/bts/bin/mdf"))


# 构造 4G 远程命令: FGSL 本地执行, FGBD 走 expect 跳板
def _build_4g_cmd(platform):
	inner = base64.b64encode(_four_g_inner(platform).encode("utf-8")).decode("ascii")
	if platform == "FGSL":
		return "printf '%%s' '%s' | base64 -d | sh -s" % inner
	token = os.urandom(4).hex()
	exp_path = "/tmp/lcd_bts_%s.exp" % token
	cmd_path = "/tmp/lcd_bts_%s.cmd" % token
	expect_script = _FOUR_G_EXPECT.replace("192.168.15.2", BS_HOST_4G)
	return (
		"rm -f /tmp/lcd_bts_*.exp /tmp/lcd_bts_*.cmd\n"
		"e=%s\n" % exp_path
		+ "c=%s\n" % cmd_path
		+ "cat > $e <<'EOF'\n" + expect_script + "\nEOF\n"
		+ "cat > $c <<'EOF'\n" + inner + "\nEOF\n"
		+ ("timeout 120 expect $e '%s' $c 2>&1 | tr -d '\\r'\n" % PASS_4G_FGBD)
		+ "rm -f $e $c\n"
	)


# 把 "KEY=VALUE" 行解析成字典, 只保留指定前缀的键
def _parse_kv(text, prefixes):
	values = {}
	for line in text.splitlines():
		line = line.strip()
		if "=" not in line:
			continue
		key, value = line.split("=", 1)
		key = key.strip()
		if key.startswith(prefixes):
			values[key] = value.strip()
	return values


# 字符串转整数, 空值/非法值返回 None
def _int_or_none(value):
	try:
		return int(str(value).strip())
	except (TypeError, ValueError):
		return None


# 输出末行: 失败时最有用的线索, 能看出命令停在哪一步
def _last_line(text):
	lines = (text or "").splitlines()
	return lines[-1].strip()[:160] if lines else ""


# 输出摘要: 头尾各取一段并压成一行, 避免日志被多行输出刷屏
def _snippet(text, limit=300):
	text = (text or "").strip()
	if len(text) <= limit:
		return text.replace("\n", " | ")
	half = limit // 2
	return (text[:half] + " ... " + text[-half:]).replace("\n", " | ")


# 记录一次远程查询的失败详情: rc / 耗时 / 输出规模 / 末行 / stderr / 输出摘要
# rc=124 表示超时, 124 之后的输出通常是不完整的; rc=255 多为 ssh 连接异常
def _log_query_failure(tag, rc, out, err, elapsed):
	lines = (out or "").splitlines()
	log("bts %s query failed: rc=%d elapsed=%.1fs out=%dB/%dlines err=%r last=%r out=%r" % (
		tag, rc, elapsed, len(out or ""), len(lines),
		(err or "").strip()[:200], _last_line(out), _snippet(out)))


# 按频带推导双工方式
def _duplex(band):
	value = _int_or_none(band)
	if value in _TDD_BANDS:
		return "TDD"
	if value in _FDD_BANDS:
		return "FDD"
	return "N/A"


# 5G 查询: 返回 ({name, sn}, list[BtsCell], status); 失败返回 (None, None, None)
def _query_5g(ip):
	started = time.monotonic()
	rc, out, err = _remote_run(ip, _FIVE_G_CMD, timeout=QUERY_5G_TIMEOUT)
	elapsed = time.monotonic() - started
	if rc != 0:
		_log_query_failure("5G", rc, out, err, elapsed)
		return None, None, None
	if "5G:OK" not in out:
		log("bts 5G query incomplete: elapsed=%.1fs out=%dB/%dlines err=%r last=%r" % (
			elapsed, len(out), len(out.splitlines()), (err or "").strip()[:200], _last_line(out)))
		return None, None, None
	values = _parse_kv(out, ("GNBNAME", "SN", "5G:"))
	meta = {}
	if values.get("GNBNAME"):
		meta["name"] = values["GNBNAME"]
	if values.get("SN"):
		meta["sn"] = values["SN"]
	cells = []
	for i in range(1, 4):
		prefix = "5G:%d:" % i
		if prefix + "CELLID" not in values:
			continue
		band = values.get(prefix + "BAND", "")
		name = values.get("GNBNAME", "")
		cells.append(BtsCell(
			name=("%s-小区%d" % (name, i)) if name else ("小区%d" % i),
			cell_id=values[prefix + "CELLID"],
			tac=values.get(prefix + "TAC", ""),
			pci=_int_or_none(values.get(prefix + "PCI")) or 0,
			ssb=values.get(prefix + "SSB", ""),
			band=band,
			arfcn_dl=values.get(prefix + "ARFCNDL", ""),
			arfcn_ul=values.get(prefix + "ARFCNUL", ""),
			bw_dl=values.get(prefix + "BWDL", ""),
			bw_ul=values.get(prefix + "BWUL", ""),
			duplex=_duplex(band),
		))
	status = {
		"ue": _int_or_none(values.get("5G:UE_COUNT")),
		"opstate": _int_or_none(values.get("5G:1:OPSTATE")),
	}
	log("bts 5G query ok: elapsed=%.1fs cells=%d opstate=%s ue=%s" % (
		elapsed, len(cells), status["opstate"], status["ue"]))
	return meta, cells, status


# 4G 查询: 返回 (list[BtsCell], status); 失败返回 (None, None)
def _query_4g(ip, platform):
	cmd = _build_4g_cmd(platform)
	started = time.monotonic()
	rc, out, err = _remote_run(ip, cmd, timeout=QUERY_4G_TIMEOUT)
	elapsed = time.monotonic() - started
	if rc != 0:
		_log_query_failure("4G", rc, out, err, elapsed)
		log("bts 4G query cmd: platform=%s cmd=%dB" % (platform, len(cmd)))
		return None, None
	if "4G:OK" not in out:
		log("bts 4G query incomplete: platform=%s elapsed=%.1fs out=%dB/%dlines err=%r last=%r" % (
			platform, elapsed, len(out), len(out.splitlines()),
			(err or "").strip()[:200], _last_line(out)))
		return None, None
	values = _parse_kv(out, ("4G:",))
	cells = []
	for i in range(1, 7):
		prefix = "4G:%d:" % i
		earfcn = values.get(prefix + "EARFCNDL", "")
		if not earfcn:
			continue
		eci = values.get(prefix + "RAN.Common.CellIdentity", "")
		eci_value = _int_or_none(eci)
		band = values.get(prefix + "RAN.RF.FreqBandIndicator", "")
		cells.append(BtsCell(
			name="LTE-小区%d" % i,
			cell_id=str(eci_value & 255) if eci_value is not None else "",
			tac=values.get(prefix + "EPC.TAC", ""),
			pci=_int_or_none(values.get(prefix + "RAN.RF.PhyCellID")) or 0,
			ssb="",
			band=band,
			arfcn_dl=earfcn,
			arfcn_ul=values.get(prefix + "RAN.RF.EARFCNUL", ""),
			bw_dl=values.get(prefix + "RAN.RF.DLBandwidth", ""),
			bw_ul=values.get(prefix + "RAN.RF.ULBandwidth", ""),
			duplex=_duplex(band),
		))
	status = {
		"ue": _int_or_none(values.get("4G:UE_COUNT")),
		"alarms": _int_or_none(values.get("4G:ALARM_COUNT")),
		"active": "4G:ACTIVE" in out,
	}
	log("bts 4G query ok: platform=%s elapsed=%.1fs cells=%d active=%s ue=%s alarms=%s" % (
		platform, elapsed, len(cells), status["active"], status["ue"], status["alarms"]))
	return cells, status


# 保存解析结果: cells/status 为 None 表示本次没查或失败, 保留旧值
def _update_details(meta, cells5, cells4, status5=None, status4=None):
	global _details
	with _lock:
		name = _details["name"]
		sn = _details["sn"]
		old5 = _details["cells"]["5G"]
		old4 = _details["cells"]["4G"]
		ue = dict(_details.get("ue", {"4G": 0, "5G": 0}))
		alarms = _details.get("alarms", 0)
	if meta:
		name = meta.get("name") or name
		sn = meta.get("sn") or sn
	if status5 and status5.get("ue") is not None:
		ue["5G"] = status5["ue"]
	if status4:
		if status4.get("ue") is not None:
			ue["4G"] = status4["ue"]
		if status4.get("alarms") is not None:
			alarms = status4["alarms"]
	details = {
		"name": name,
		"sn": sn,
		"cells": {
			"5G": cells5 if cells5 is not None else old5,
			"4G": cells4 if cells4 is not None else old4,
		},
		"ue": ue,
		"alarms": alarms,
	}
	with _lock:
		_details = details
	log("bts info updated: name=%s sn=%s 5G=%d 4G=%d ue5=%s ue4=%s alarms=%s" % (
		name or "-", sn or "-", len(details["cells"]["5G"]), len(details["cells"]["4G"]),
		ue.get("5G"), ue.get("4G"), alarms))


# 用最近一次静态参数和激活状态生成缓存
# 在线状态 = 激活状态: 5G 看 OpState=1, 4G 看 callpctrl0 是否有 allocated in cell
def _apply(ip, reachable, reason=""):
	global _snapshot, _last_state
	if (reachable, ip) != _last_state:
		detail = (": " + reason) if reason and not reachable else ""
		log("bts %s: %s%s" % ("online" if reachable else "offline", ip or "-", detail))
		_last_state = (reachable, ip)
	with _lock:
		details = _details
		snapshot = []
		for label in LABELS:
			cells = details["cells"][label]
			if label == "4G":
				online = reachable and _4g_active
			else:
				online = reachable and _5g_active
			pci = cells[0].pci if cells else 0
			ue = details.get("ue", {}).get(label, 0)
			snapshot.append(BtsInfo(label, online, pci, ue, details["name"], details["sn"], cells))
		_snapshot = snapshot


# 轻量在线探测
# 除 rc==0 外, 回包正确也视为可达: ssh 客户端偶发被信号终止(rc 为负)时输出已经拿到了
def _probe(ip):
	rc, out, err = _remote_run(ip, "echo ok", timeout=PROBE_TIMEOUT)
	if rc == 0:
		return True
	if out.strip() == "ok":
		log("bts probe: rc=%d but got output, treat as reachable (err=%r)" % (rc, (err or "").strip()[:160]))
		return True
	if (False, ip) != _last_state:			# 离线期间每轮都失败, 只在状态变化时记录
		log("bts probe failed: ip=%s rc=%d err=%r out=%r" % (
			ip, rc, (err or "").strip()[:160], _snippet(out, 120)))
	return False


# 单次轮询: 解析 IP -> 探测 -> 按平台查询 5G/4G -> 刷新缓存
def _poll_once():
	global _5g_active, _4g_active, _last_ip
	if not MAC:
		_apply(None, False, "lcd.bts.mac not configured")
		return
	ip = resolve_ip(MAC)
	if not ip:
		_apply(None, False, "no ip found by mac")
		return
	if ip != _last_ip:
		log("bts ip resolved: %s (mac=%s)" % (ip, MAC))
		_last_ip = ip
	if not _probe(ip):
		_apply(ip, False, "ssh unreachable")
		return

	platform = _get_platform(ip)

	meta, cells5, status5 = _query_5g(ip)
	_5g_active = bool(status5 and status5.get("opstate") == 1)
	if meta is None:						# 5G 查询失败: 保留旧小区, 只刷新 4G
		cells5 = None
		status5 = None

	cells4, status4 = _query_4g(ip, platform)
	_4g_active = bool(status4 and status4.get("active"))
	if cells4 is None:
		status4 = None

	if meta is not None or cells4 is not None:
		_update_details(meta, cells5, cells4, status5=status5, status4=status4)

	_apply(ip, True)


# 后台轮询线程: 单次异常不能让它退出
# 按 lcd.bts.intervalSec 控制两次查询的起始间隔, 查询耗时从间隔中扣除
def _worker_loop():
	while True:
		started = time.monotonic()
		try:
			_poll_once()
		except Exception as err:
			log("bts poll failed: %r" % err)
		elapsed = time.monotonic() - started
		if elapsed >= 10:					# 单轮耗时接近超时上限时记录, 便于定位变慢的查询
			log("bts poll slow: %.1fs" % elapsed)
		time.sleep(max(1, INTERVAL - elapsed))


# 首次 read_bts 时启动轮询线程
def _ensure_worker():
	global _worker
	with _worker_lock:
		if _worker is None:
			log("bts poll started: interval=%ds mac=%s" % (INTERVAL, MAC or "-"))
			_worker = threading.Thread(target=_worker_loop, name="bts-poll", daemon=True)
			_worker.start()


# 读全部基站状态: 返回最近一次轮询的副本, 不阻塞调用方
def read_bts():
	_ensure_worker()
	with _lock:
		return [BtsInfo(b.label, b.online, b.pci, b.ue, b.name, b.sn, b.cells) for b in _snapshot]
