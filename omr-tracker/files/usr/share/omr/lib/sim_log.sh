#!/bin/sh
#
# SIM 日志工具: 每个 SIM 一个日志文件 /var/log/sim/<ifname>.log
# 超过 1MB 时备份为 <ifname>.log.rotate(只保留一份, 旧的被覆盖), 再从空文件开始写
#
# tracker-sim 与 34663301.sh 共用本文件, 两者都从同一目录 source
#

# 只加载一次: 34663301.sh 每轮被 source 时不要把 SIM_LOG_FILE/字节计数重置掉
[ -n "$SIM_LOG_LOADED" ] && return 0
SIM_LOG_LOADED=1

SIM_LOG_DIR="/var/log/sim"
SIM_LOG_MAX_SIZE=1048576
SIM_LOG_BYTES=0
SIM_LOG_FILE=""

# 初始化日志文件: sim_log_init <name> -> /var/log/sim/<name>.log
sim_log_init() {
	local name="$1"

	mkdir -p "$SIM_LOG_DIR" 2>/dev/null
	SIM_LOG_FILE="${SIM_LOG_DIR}/${name}.log"
	SIM_LOG_BYTES=0
	[ -f "$SIM_LOG_FILE" ] && SIM_LOG_BYTES=$(wc -c < "$SIM_LOG_FILE" 2>/dev/null | tr -d ' ')
	[ -n "$SIM_LOG_BYTES" ] || SIM_LOG_BYTES=0
}

# 写一行到指定文件, 按进程内累计字节数判断是否需要轮转
sim_log_write() {
	local file="$1"
	local line="$2"
	local len

	mkdir -p "$(dirname "$file")" 2>/dev/null
	len=$(( ${#line} + 1 ))
	if [ $((SIM_LOG_BYTES + len)) -gt "$SIM_LOG_MAX_SIZE" ]; then
		mv -f "$file" "${file}.rotate" 2>/dev/null
		SIM_LOG_BYTES=0
	fi
	printf '%s\n' "$line" >> "$file" 2>/dev/null
	SIM_LOG_BYTES=$((SIM_LOG_BYTES + len))
}

# 统一日志出口: 时间戳 + <interface ttyUSB> 前缀; 未初始化时按 $ifname 自动初始化
sim_log() {
	local line

	[ -n "$SIM_LOG_FILE" ] || sim_log_init "$ifname"
	line="[$(date '+%Y-%m-%d %H:%M:%S')] <${interface} ${ttyUSB}> $*"
	sim_log_write "$SIM_LOG_FILE" "$line"
}
