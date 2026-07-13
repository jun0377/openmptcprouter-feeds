#!/bin/sh

# 停止所有omr-tracker VPN和代理进程
stop_all_vpn() {

	/etc/init.d/shadowsocks-libev stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/shadowsocks-libev stop"

	/etc/init.d/shadowsocks-rust stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/shadowsocks-rust stop"

	/etc/init.d/v2ray stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/v2ray stop"

	/etc/init.d/xray stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/xray stop"

	/etc/init.d/shadowsocks-libev stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/shadowsocks-libev stop"

	/etc/init.d/openvpn stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/openvpn stop"
	uci -q set openvpn.omr.enabled=0 && uci commit openvpn

	/etc/init.d/mlvpn stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/mlvpn stop"
	uci -q set mlvpn.general.enable=0 && uci commit mlvpn

	/etc/init.d/dsvpn stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/dsvpn stop"
	uci -q set dsvpn.vpn.enable=0 && uci commit dsvpn

	/etc/init.d/glorytun stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/glorytun stop"
	uci -q set glorytun.vpn.enable=0 && uci commit glorytun

	/etc/init.d/glorytun-udp stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/glorytun-udp stop"
	uci -q set glorytun-udp.vpn.enable=0 && uci commit glorytun-udp

	# 负载均衡mwan3
	/etc/init.d/mwan3 stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/mwan3 stop"

	# omr-tracker
	/etc/init.d/omr-tracker restart >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/omr-tracker restart"
}

# 更新nft snat规则
nft_snat() {

	# 1. 再次判断工作模式, 确保为单卡模式single, uci get global.single
	local mode="$(uci -q get global.global.mode)"
	[ "$mode" != "single" ] && { 
		logger -t "OMR-VPS" "<$FUNCNAME> mode is ${mode} not single! return now..."
		return 
	} 

	# 2. 获取单卡模式所用链路, uci get global.single.channel
	local channel="$(uci -q get global.single.channel)"
	[ -z "$channel" ] && { 
		logger -t "OMR-VPS" "<$FUNCNAME> unknown single channel! return now..."
		return 
	}

	logger -t "OMR-VPS" "<$FUNCNAME> single channel: ${channel}"

	# 3. 获取LAN口br-lan的地址, uci get network.lan.ipaddr; uci get network.lan.netmask
	local lan_ip="$(uci -q get network.lan.ipaddr)"
	[ -z "$lan_ip" ] && { 
		logger -t "OMR-VPS" "<$FUNCNAME> unknown lan_ip! return now..."
		return 
	}

	logger -t "OMR-VPS" "<$FUNCNAME> lan_ip:${lan_ip}"

	# LAN口br-lan的掩码
	local lan_netmask="$(uci -q get network.lan.netmask)"
	[ -z "$lan_netmask" ] && { 
		logger -t "OMR-VPS" "<$FUNCNAME> unknown lan_netmask! return now..."
		return 
	}

	logger -t "OMR-VPS" "<$FUNCNAME> lan_netmask:${lan_netmask}"

	# LAN口br-lan的物理网口名
	local lan_dev="$(uci -q get network.lan.device)"
	[ -z "$lan_dev" ] && { 
		logger -t "OMR-VPS" "<$FUNCNAME> unknown lan_dev! return now..."
		return 
	}

	logger -t "OMR-VPS" "<$FUNCNAME> lan_dev:${lan_dev}"

	# 当前单卡链路的物理网口名
	local wan_dev="$(ifstatus "$channel" 2>/dev/null | jsonfilter -q -e '@.l3_device')"
	[ -z "$wan_dev" ] && wan_dev="$(ifstatus "$channel" 2>/dev/null | jsonfilter -q -e '@.device')"
	[ -z "$wan_dev" ] && {
		logger -t "OMR-VPS" "<$FUNCNAME> unknown wan_dev! return now..."
		return 
	}

	logger -t "OMR-VPS" "<$FUNCNAME> wan_dev:${wan_dev}"

	# 添加nft SNAT规则
	logger -t "OMR-VPS" "<$FUNCNAME> snat from ${lan_dev}:${lan_ip}/${lan_netmask} to ${wan_dev}"
	local ip4table="$(uci -q get network.${channel}.ip4table)"
	[ -z "$ip4table" ] && {
		logger -t "OMR-VPS" "<$FUNCNAME> unknown ip4table for ${channel}! return now..."
		return
	}

	local prefix="$(echo "$lan_netmask" | awk -F. '{c=0; for(i=1;i<=4;i++){n=$i+0; for(b=0;b<8;b++){c+=and(n,1); n=rshift(n,1)}} print c}')"
	local lan_network="$(echo "$lan_ip $lan_netmask" | awk '{split($1,ip,"."); split($2,mask,"."); printf "%d.%d.%d.%d", and(ip[1],mask[1]), and(ip[2],mask[2]), and(ip[3],mask[3]), and(ip[4],mask[4])}')"
	local lan_subnet="${lan_network}/${prefix}"

	# 用户选择的单卡链路还没有配置路由,后续由omr-tracker来处理
	[ -n "$(ip -4 route show table "$ip4table" 2>/dev/null | grep -m 1 '^default ')" ] || {
		logger -t "OMR-VPS" "<$FUNCNAME> warning: table ${ip4table} has no default route now! omr-tracker may fix later..."
	}

	# 添加单卡模式路由规则
	[ "$(uci -q get network.omr_single_lan)" = "rule" ] || uci -q set network.omr_single_lan=rule
	uci -q set network.omr_single_lan.family="ipv4"
	uci -q set network.omr_single_lan.priority="50"
	uci -q set network.omr_single_lan.src="$lan_subnet"
	uci -q set network.omr_single_lan.lookup="$ip4table"
	uci -q set network.omr_single_lan.in='lan'
	uci -q commit network
	/etc/init.d/network reload >/dev/null 2>&1

	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/network reload"
	logger -t "OMR-VPS" "<$FUNCNAME> from ${lan_subnet} lookup table ${ip4table} priority=$(uci -q get network.omr_single_lan.priority)"

	[ "$(uci -q get firewall.zone_wan)" = "zone" ] || {
		logger -t "OMR-VPS" "<$FUNCNAME> firewall.zone_wan not found! return now..."
		return
	}

	# 添加单卡模式防火墙规则,先备份一下, 然后只允许当前选择的这个链路作为出口
	# 备份防火墙wan zone配置
	local current_networks="$(uci -q get firewall.zone_wan.network)"
	[ -n "$current_networks" ] && [ -z "$(uci -q get openmptcprouter.settings.single_wan_networks_backup)" ] && {
		uci -q set openmptcprouter.settings.single_wan_networks_backup="$current_networks"
		uci -q commit openmptcprouter
	}
	# 删除防火墙wan zone
	uci -q del firewall.zone_wan.network
	# 只允许当前选择的单卡链路作为出口wan
	uci -q add_list firewall.zone_wan.network="$channel"
	# 开启防火墙masquerade(SNAT)
	[ "$(uci -q get firewall.zone_wan.masq)" = "1" ] || uci -q set firewall.zone_wan.masq="1"
	uci -q commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/firewall reload"
}

# 停止单卡模式, 删除SNAT规则和路由
function stop_mode_single() {

	logger -t "OMR-VPS" "<$FUNCNAME>"
	
	# 1. 清除单卡模式路由规则
	uci -q delete network.omr_single_lan
	uci -q commit network
	/etc/init.d/network reload >/dev/null 2>&1

	logger -t "OMR-VPS" "<$FUNCNAME> uci -q delete network.omr_single_lan"

	[ "$(uci -q get firewall.zone_wan)" = "zone" ] || return
	local backup_networks="$(uci -q get openmptcprouter.settings.single_wan_networks_backup)"
	[ -z "$backup_networks" ] && return

	# 2. 恢复防火墙 zone_wan 的 network 配置
	uci -q del firewall.zone_wan.network
	local net
	for net in $backup_networks; do
		uci -q add_list firewall.zone_wan.network="$net"
	done
	uci -q commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1

	uci -q delete openmptcprouter.settings.single_wan_networks_backup
	uci -q commit openmptcprouter

	logger -t "OMR-VPS" "<$FUNCNAME> done..."
}

# 单卡模式处理逻辑
mode_single_handler() {
	logger -t "OMR-VPS" "<$FUNCNAME> mode: single"
	
	# 停止聚合模式
	[ -f /usr/lib/openmptcprouter-vps/mode_aggregate.sh ] && {
		. /usr/lib/openmptcprouter-vps/mode_aggregate.sh
		stop_mode_aggregate
	}

	# 停止负载均衡模式
	[ -f /usr/lib/openmptcprouter-vps/mode_balance.sh ] && {
		. /usr/lib/openmptcprouter-vps/mode_balance.sh
		stop_mode_balance
	}

	# 停止所有VPN和代理进程
	stop_all_vpn

	# 更新nft snat规则
	nft_snat
}
