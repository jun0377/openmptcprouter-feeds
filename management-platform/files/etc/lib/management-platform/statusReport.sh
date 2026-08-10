#!/bin/bash
# 管理平台状态上报脚本
# 循环执行, 通过 curl 将路由器状态持续上报到后台管理平台服务器
# 配置来源: /etc/config/management-platform

CONFIG_NAME="management-platform"

# 默认配置(未配置 UCI 时使用)
DEFAULT_SERVER_IP="192.168.1.100"
DEFAULT_SERVER_PORT="8080"
DEFAULT_REPORT_INTERVAL="60"

# 后台服务器上报接口路径
REPORT_PATH="/report"

# 读取 UCI 配置, 无配置时使用默认值
server_ip=$(uci -q get ${CONFIG_NAME}.@main[0].server_ip)
[ -z "$server_ip" ] && server_ip="$DEFAULT_SERVER_IP"

server_port=$(uci -q get ${CONFIG_NAME}.@main[0].server_port)
[ -z "$server_port" ] && server_port="$DEFAULT_SERVER_PORT"

report_interval=$(uci -q get ${CONFIG_NAME}.@main[0].report_interval)
[ -z "$report_interval" ] && report_interval="$DEFAULT_REPORT_INTERVAL"

REPORT_URL="http://${server_ip}:${server_port}${REPORT_PATH}"

# 收集一次路由器状态, 输出 JSON
collect_status() {
	local timestamp time hostname model wan_ip uptime load mem_total mem_free

	timestamp=$(date +%s)
	time=$(date "+%Y-%m-%d %H:%M:%S")
	hostname=$(uci -q get system.@system[0].hostname)
	[ -z "$hostname" ] && hostname=$(hostname)
	model=$(cat /tmp/sysinfo/model 2>/dev/null)
	[ -z "$model" ] && model=$(sed -n 's/^Hardware[[:space:]]*: //p' /proc/cpuinfo 2>/dev/null)
	wan_ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{gsub(/\/.*/, "", $2); if ($2 !~ /^127/) print $2}' | head -1)
	uptime=$(awk '{print int($1)}' /proc/uptime 2>/dev/null)
	load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null)
	mem_total=$(awk '/^MemTotal/{print $2}' /proc/meminfo 2>/dev/null)
	mem_free=$(awk '/^MemAvailable/{print $2}' /proc/meminfo 2>/dev/null)
	[ -z "$mem_free" ] && mem_free=$(awk '/^MemFree/{print $2}' /proc/meminfo 2>/dev/null)

	cat <<EOF
{
  "timestamp": $timestamp,
  "time": "$time",
  "hostname": "$hostname",
  "model": "$model",
  "wan_ip": "$wan_ip",
  "uptime": $uptime,
  "load": "$load",
  "mem_total_kb": $mem_total,
  "mem_free_kb": $mem_free
}
EOF
}

# 循环上报
while true; do
	json=$(collect_status)
	curl -sS --max-time 10 -X POST -H 'Content-Type: application/json' \
		-d "$json" "$REPORT_URL" >/dev/null 2>&1
	sleep "$report_interval"
done
