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
		local sysfs="$(uci -q get sim.${channel}.usb)"
		[ -n "$sysfs" ] && [ -d "$sysfs" ] && wan_dev="$(ls "$sysfs"/*/net/ 2>/dev/null | head -n 1)"
	}
	
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
	# 不设置 in='lan'，避免 iif br-lan 限制导致路由器本地发出的流量无法命中此规则
	# 显式删除旧的 in 选项，因为 uci set 不会自动清除之前已设置的选项
	uci -q delete network.omr_single_lan.in
	uci -q commit network
	/etc/init.d/network reload >/dev/null 2>&1

	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/network reload"
	logger -t "OMR-VPS" "<$FUNCNAME> from ${lan_subnet} lookup table ${ip4table} priority=$(uci -q get network.omr_single_lan.priority)"

	# network reload 后 netifd 会重建路由表，手动补路由必须放在 reload 之后
	# 否则路由器回复 LAN 客户端的回包 (src=lan_ip, dst=lan_client) 会因 table 中无 LAN 路由而被丢弃
	ip route replace "$lan_subnet" dev "$lan_dev" table "$ip4table" 2>/dev/null
	logger -t "OMR-VPS" "<$FUNCNAME> ip route replace ${lan_subnet} dev ${lan_dev} table ${ip4table}"

	# firewall.zone_wan 由 mode_manager.sh 统一收窄/恢复, 这里不再修改
}

# 停止单卡模式: 删除策略规则与手工补的 LAN 回程路由
# firewall.zone_wan 的恢复由 mode_manager.sh 统一处理
stop_mode_single() {
	logger -t "OMR-VPS" "<$FUNCNAME>"

	local channel ip4table lan_ip lan_netmask
	local prefix lan_network lan_subnet

	channel="$(uci -q get global.single.channel)"
	ip4table=""
	[ -n "$channel" ] && ip4table="$(uci -q get network.${channel}.ip4table)"

	# 删除 nft_snat 中补的 LAN 回程路由, 避免残留在策略表里影响其它模式
	lan_ip="$(uci -q get network.lan.ipaddr)"
	lan_netmask="$(uci -q get network.lan.netmask)"
	case "$ip4table" in
		''|*[!0-9]*) ;;
		*)
			if [ -n "$lan_ip" ] && [ -n "$lan_netmask" ]; then
				prefix="$(echo "$lan_netmask" | awk -F. '{c=0; for(i=1;i<=4;i++){n=$i+0; for(b=0;b<8;b++){c+=and(n,1); n=rshift(n,1)}} print c}')"
				lan_network="$(echo "$lan_ip $lan_netmask" | awk '{split($1,ip,"."); split($2,mask,"."); printf "%d.%d.%d.%d", and(ip[1],mask[1]), and(ip[2],mask[2]), and(ip[3],mask[3]), and(ip[4],mask[4])}')"
				lan_subnet="${lan_network}/${prefix}"
				ip route del "$lan_subnet" table "$ip4table" >/dev/null 2>&1
				logger -t "OMR-VPS" "<$FUNCNAME> ip route del ${lan_subnet} table ${ip4table}"
			fi
			;;
	esac

	# 清除单卡模式策略规则
	uci -q delete network.omr_single_lan
	uci -q commit network
	/etc/init.d/network reload >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> delete network.omr_single_lan"

	# 旧版本遗留的备份键由 mode_manager.sh 迁移, 这里清理
	if [ -n "$(uci -q get openmptcprouter.settings.single_wan_networks_backup)" ]; then
		uci -q delete openmptcprouter.settings.single_wan_networks_backup
		uci -q commit openmptcprouter >/dev/null 2>&1
	fi
}
