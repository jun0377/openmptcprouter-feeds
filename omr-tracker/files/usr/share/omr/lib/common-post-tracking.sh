#!/bin/sh
#
# Copyright (C) 2018-2024 Ycarus (Yannick Chabanois) <ycarus@zugaina.org> for OpenMPTCProuter
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

. /lib/functions/network.sh

# 根据 UCI 接口名（如 wan、wanb）查找对应的 network 配置节名（device section）
# 参数: $1 - UCI 接口名（如 "wan"）
# 输出: 对应的 device 配置节名（如 "eth1"），未找到则输出空
# 流程: 通过 uci get network.<接口>.device 获取物理设备名，然后在 network device 配置中查找匹配的节
find_network_device() {
	local device="${1}"
	local device_section=""

	check_device() {
		local cfg="${1}"
		local device="${2}"

		local name
		config_get name "${cfg}" name

		[ "${name}" = "${device}" ] && device_section="${cfg}"
	}
	if [ -n "$device" ]; then
		config_load network
		config_foreach check_device device "$(uci -q network.${device}.device)"
	fi
	echo "${device_section}"
}

# 接口降级时，为指定接口替换全局默认路由和特殊路由表 991337 的默认路由（IPv4）
# 参数: $1 - 要设置路由的接口名（INTERFACE）
#       $2 - 之前使用的接口名（PREVINTERFACE），用于去重判断
#       $3 - 是否覆盖主默认路由（SETDEFAULT），默认 "yes"；设为 "no" 时只更新 table 991337 而不动主表
# 全局前置条件: 本函数仅在全链路只有一个 tracker 触发过路由设置时才执行（SETROUTE=false）
# 调用场景: 002-error 中，当一个链路 down 后，切换到下一个可用链路时调用
set_route() {
	local multipath_config_route interface_gw interface_if
	INTERFACE=$1
	PREVINTERFACE=$2
	SETDEFAULT=$3
	[ -z "$SETDEFAULT" ] && SETDEFAULT="yes"
	[ -z "$INTERFACE" ] && return
	multipath_config_route=$(uci -q get openmptcprouter.$INTERFACE.multipath)
	[ -z "$multipath_config_route" ] && multipath_config_route=$(uci -q get network.$INTERFACE.multipath || echo "off")
	[ "$(uci -q get openmptcprouter.$INTERFACE.multipathvpn)" = "1" ] && {
		[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "openvpn" ] && multipath_config_route="$(uci -q get openmptcprouter.ovpn${INTERFACE}.multipath || echo "off")"
		[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "wireguard" ] && multipath_config_route="$(uci -q get openmptcprouter.wg${INTERFACE}.multipath || echo "off")"
	}
	#network_get_device interface_if $INTERFACE
	interface_up=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -q -e '@["up"]')
	[ -z "$interface_if" ] && interface_if=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
	[ -z "$interface_if" ] && interface_if=$(ifstatus "${INTERFACE}_4" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
	[ -z "$interface_if" ] && interface_if=$(uci -q get network.$INTERFACE.ifname)
	[ -z "$interface_if" ] && interface_if=$(uci -q get network.$INTERFACE.device)
	[ -n "$(echo $interface_if | grep '@')" ] && interface_if=$(ifstatus "${INTERFACE}" | jsonfilter -q -e '@["device"]')
	interface_current_config=$(uci -q get openmptcprouter.$INTERFACE.state || echo "up")
	if [ "$multipath_config_route" != "off" ] && [ "$SETROUTE" != true ] && [ "$INTERFACE" != "$PREVINTERFACE" ] && [ "$interface_current_config" = "up" ] && [ "$interface_up" = "true" ]; then
		interface_gw="$(uci -q get network.$INTERFACE.gateway)"
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.target="0.0.0.0"].nexthop' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.route[@.target="0.0.0.0"].nexthop' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.${INTERFACE}_4 status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.target="0.0.0.0"].nexthop' | tr -d "\n")
		fi
		if [ "$interface_gw" != "" ] && [ "$interface_if" != "" ]; then
			[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && [ "$SETDEFAULT" = "yes" ] && _log "$PREVINTERFACE down. Replace default route by $interface_gw dev $interface_if"
			[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && [ "$SETDEFAULT" != "yes" ] && _log "$PREVINTERFACE down. Replace default in table 991337 route by $interface_gw dev $interface_if"
			[ "$SETDEFAULT" = "yes" ] && [ "$(uci -q openmptcprouter.settings.defaultgw)" != "0" ] && ip route replace default scope global metric 1 via $interface_gw dev $interface_if $initcwrwnd >/dev/null 2>&1
			ip route replace default via $interface_gw dev $interface_if table 991337 $initcwrwnd >/dev/null 2>&1 && SETROUTE=true
		fi
	fi
}

# 接口降级时，为指定接口替换 IPv6 默认路由和特殊路由表 6991337 的默认路由
# 功能与 set_route 对称，处理 IPv6 路由
# 参数和调用场景与 set_route 相同
set_route6() {
	local multipath_config_route interface_gw interface_if
	INTERFACE=$1
	PREVINTERFACE=$2
	SETDEFAULT=$3
	[ -z "$SETDEFAULT" ] && SETDEFAULT="yes"
	[ -z "$INTERFACE" ] && return
	multipath_config_route=$(uci -q get openmptcprouter.$INTERFACE.multipath)
	[ -z "$multipath_config_route" ] && multipath_config_route=$(uci -q get network.$INTERFACE.multipath || echo "off")
	[ "$(uci -q get openmptcprouter.$INTERFACE.multipathvpn)" = "1" ] && {
		[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "openvpn" ] && multipath_config_route="$(uci -q get openmptcprouter.ovpn${INTERFACE}.multipath || echo "off")"
		[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "wireguard" ] && multipath_config_route="$(uci -q get openmptcprouter.wg${INTERFACE}.multipath || echo "off")"
	}
	#network_get_device interface_if $INTERFACE
	interface_up=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -q -e '@["up"]')
	[ -z "$interface_if" ] && interface_if=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
	[ -z "$interface_if" ] && interface_if=$(ifstatus "${INTERFACE}_4" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
	[ -z "$interface_if" ] && interface_if=$(uci -q get network.$INTERFACE.ifname)
	[ -z "$interface_if" ] && interface_if=$(uci -q get network.$INTERFACE.device)
	[ -n "$(echo $interface_if | grep '@')" ] && interface_if=$(ifstatus "$INTERFACE" | jsonfilter -q -e '@["device"]')
	interface_current_config=$(uci -q get openmptcprouter.$INTERFACE.state || echo "up")
	if [ "$multipath_config_route" != "off" ] && [ "$SETROUTE" != true ] && [ "$INTERFACE" != "$PREVINTERFACE" ] && [ "$interface_current_config" = "up" ] && [ "$interface_up" = "true" ]; then
		interface_gw="$(uci -q get network.$INTERFACE.gateway)"
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.target="::"].nexthop' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.route[@.target="::"].nexthop' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.${INTERFACE}_6 status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.target="::"].nexthop' | tr -d "\n")
		fi
		if [ "$interface_gw" != "" ] && [ "$interface_if" != "" ] && [ -n "$(echo $interface_gw | grep ':')" ]; then
			[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "$PREVINTERFACE down. Replace default route by $interface_gw dev $interface_if"
			[ "$SETDEFAULT" = "yes" ] && [ "$(uci -q openmptcprouter.settings.defaultgw)" != "0" ] && ip -6 route replace default scope metric 1 global nexthop via $interface_gw dev $interface_if >/dev/null 2>&1
			ip -6 route replace default via $interface_gw dev $interface_if table 6991337 >/dev/null 2>&1 && SETROUTE=true
		fi
	fi
}

# 通过 VPN 隧道网关为服务器 IP 添加 IPv4 主机路由（/32）
# 参数: $1 - openmptcprouter 中的 server 配置节名
# 前置条件: OMR_TRACKER_INTERFACE 和 OMR_TRACKER_DEVICE_GATEWAY 必须有效，
#          当前触发 tracker 的接口 multipath 不能为 "off"
# 路由格式: 服务器 IP via 隧道网关 dev 隧道设备 metric 1
# 调用场景: 003-up 中 master 接口上线时、002-error 中 omrvpn 链路恢复检测到时可调用
# 注意: 这条路由走的是 VPN 隧道网关（如 10.255.252.1），不是物理接口网关！
#      仅用于确保 VPN 隧道建立后服务器可达，不解决"OpenVPN 自身控制连接不被隧道吸入"的问题
set_server_default_route() {
	local server=$1
	server_route() {
		local serverip multipath_config_route
		serverip=$1
		[ -n "$serverip" ] && serverip="$(resolveip -4 -t 5 $serverip | head -n 1 | tr -d '\n')"
		config_get disabled $server disabled
		[ "$disabled" = "1" ] && return
		[ -z "$OMR_TRACKER_INTERFACE" ] && return
		multipath_config_route=$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.multipath)
		[ -z "$multipath_config_route" ] && multipath_config_route=$(uci -q get network.$OMR_TRACKER_INTERFACE.multipath || echo "off")
		[ "$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.multipathvpn)" = "1" ] && {
			[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "openvpn" ] && multipath_config_route="$(uci -q get openmptcprouter.ovpn${OMR_TRACKER_INTERFACE}.multipath || echo "off")"
			[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "wireguard" ] && multipath_config_route="$(uci -q get openmptcprouter.wg${OMR_TRACKER_INTERFACE}.multipath || echo "off")"
		}
		if [ "$serverip" != "" ] && [ "$OMR_TRACKER_DEVICE_GATEWAY" != "" ] && [ -n "$OMR_TRACKER_DEVICE" ] && [ "$(ip route show dev $OMR_TRACKER_DEVICE metric 1 | grep $serverip | grep $OMR_TRACKER_DEVICE_GATEWAY)" = "" ] && [ "$multipath_config_route" != "off" ]; then
			[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "Set server $server ($serverip) default route via $OMR_TRACKER_DEVICE_GATEWAY"
			if [ "$(ip r show $serverip | grep nexthop)" != "" ]; then
				ip r delete $serverip >/dev/null 2>&1
			fi
			ip route replace $serverip via $OMR_TRACKER_DEVICE_GATEWAY dev $OMR_TRACKER_DEVICE metric 1 $initcwrwnd >/dev/null 2>&1
		fi
	}
	config_list_foreach $server ip server_route
}

# 通过 VPN 隧道网关为服务器 IP 添加 IPv6 主机路由（/128）
# 功能与 set_server_default_route 对称，处理 IPv6
set_server_default_route6() {
	local server=$1
	server_route() {
		local serverip multipath_config_route
		serverip=$1
		[ -n "$serverip" ] && serverip="$(resolveip -6 -t 5 $serverip | head -n 1 | tr -d '\n')"
		config_get disabled $server disabled
		[ "$disabled" = "1" ] && return
		[ -z "$OMR_TRACKER_INTERFACE" ] && return
		multipath_config_route=$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.multipath)
		[ -z "$multipath_config_route" ] && multipath_config_route=$(uci -q get network.$OMR_TRACKER_INTERFACE.multipath || echo "off")
		[ "$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.multipathvpn)" = "1" ] && {
			[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "openvpn" ] && multipath_config_route="$(uci -q get openmptcprouter.ovpn${OMR_TRACKER_INTERFACE}.multipath || echo "off")"
			[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "wireguard" ] && multipath_config_route="$(uci -q get openmptcprouter.wg${OMR_TRACKER_INTERFACE}.multipath || echo "off")"
		}
		if [ "$serverip" != "" ] && [ "$OMR_TRACKER_DEVICE_GATEWAY6" != "" ] && [ -n "$OMR_TRACKER_DEVICE" ] && [ "$(ip -6 route show dev $OMR_TRACKER_DEVICE metric 1 | grep $serverip | grep $OMR_TRACKER_DEVICE_GATEWAY6)" = "" ] && [ "$multipath_config_route" != "off" ]; then
			[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "Set server $server ($serverip) default route via $OMR_TRACKER_DEVICE_GATEWAY6"
			if [ "$(ip -6 r show $serverip | grep nexthop)" != "" ]; then
				ip -6 r delete $serverip >/dev/null 2>&1
			fi
			ip -6 route replace $serverip via $OMR_TRACKER_DEVICE_GATEWAY6 dev $OMR_TRACKER_DEVICE metric 1 >/dev/null 2>&1
		fi
	}
	config_list_foreach $server ip server_route
}

# 删除通过 VPN 隧道网关添加的服务器 IPv4 主机路由
# 参数: $1 - server 配置节名
# 遍历 server 的 ip 列表，删除 metric=1 的对应路由
# 调用场景: 002-error 中链路 down 时用来清理旧路由
delete_server_default_route() {
	local server=$1
	delete_route() {
		local serverip=$1
		[ -n "$serverip" ] && serverip="$(resolveip -4 -t 5 $serverip | head -n 1 | tr -d '\n')"
		config_get disabled $server disabled
		[ "$disabled" = "1" ] && return
		if [ "$serverip" != "" ] && [ "$(ip route show $serverip metric 1)" != "" ]; then
			[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "Delete server ($serverip) default route"
			[ -n "$(ip route show $serverip metric 1)" ] && ip route del $serverip metric 1 >/dev/null 2>&1
		fi
	}
	config_list_foreach $server ip delete_route
}

# 删除通过 VPN 隧道网关添加的服务器 IPv6 主机路由
# 功能与 delete_server_default_route 对称，处理 IPv6
delete_server_default_route6() {
	local server=$1
	delete_route() {
		local serverip=$1
		[ -n "$serverip" ] && serverip="$(resolveip -6 -t 5 $serverip | head -n 1 | tr -d '\n')"
		config_get disabled $server disabled
		[ "$disabled" = "1" ] && return
		if [ "$serverip" != "" ] && [ "$(ip -6 route show $serverip metric 1)" != "" ]; then
			[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "Delete server ($serverip) default route"
			[ -n "$(ip -6 route show $serverip metric 1)" ] && ip -6 route del $serverip metric 1 >/dev/null 2>&1
		fi
	}
	config_list_foreach $server ip delete_route
}

# 收集物理接口的 nexthop 信息，用于拼装多路径服务器路由（IPv4）
# 参数: $1 - 接口名（如 wan、wanb），跳过 omrvpn
# 输出: 追加到全局变量 routesintf（主链路）或 routesintfbackup（备份链路）
#       格式为 "nexthop via <网关IP> dev <设备名> weight <权重>"
# 权重规则: master 接口权重 100，普通接口权重 1，backup 接口放到备用链路组
# 调用场景: 被 set_server_all_routes 通过 config_foreach 调用，遍历所有活跃物理接口
set_routes_intf() {
	local multipath_config_route
	local interface_if
	local INTERFACE=$1
	[ -z "$INTERFACE" ] && return
	[ "$INTERFACE" = "omrvpn" ] && return
	multipath_config_route=$(uci -q get openmptcprouter.$INTERFACE.multipath)
	[ -z "$multipath_config_route" ] && multipath_config_route=$(uci -q get network.$INTERFACE.multipath || echo "off")
	[ "$(uci -q get openmptcprouter.$INTERFACE.multipathvpn)" = "1" ] && {
		[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "openvpn" ] && multipath_config_route="$(uci -q get openmptcprouter.ovpn${INTERFACE}.multipath || echo "off")"
		[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "wireguard" ] && multipath_config_route="$(uci -q get openmptcprouter.wg${INTERFACE}.multipath || echo "off")"
	}
	#network_get_device interface_if $INTERFACE
	interface_if=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
	[ -z "$interface_if" ] && interface_if=$(ifstatus "${INTERFACE}_4" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
	[ -z "$interface_if" ] && interface_if=$(uci -q get network.$INTERFACE.ifname)
	[ -z "$interface_if" ] && interface_if=$(uci -q get network.$INTERFACE.device)
	[ -n "$(echo $interface_if | grep '@')" ] && interface_if=$(ifstatus "$INTERFACE" | jsonfilter -q -e '@["device"]')
	interface_up=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -q -e '@["up"]')
	#multipath_current_config=$(multipath $interface_if | grep 'deactivated')
	interface_current_config=$(uci -q get openmptcprouter.$INTERFACE.state || echo "up")
	interface_vpn=$(uci -q get openmptcprouter.$INTERFACE.vpn || echo "0")
	if { [ "$interface_vpn" = "0" ] || [ "$(uci -q get openmptcprouter.settings.allmptcpovervpn)" = "0" ]; } && [ "$multipath_config_route" != "off" ] && [ "$interface_current_config" = "up" ] && [ "$interface_if" != "" ] && [ "$interface_up" = "true" ]; then
		interface_gw="$(uci -q get network.$INTERFACE.gateway)"
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.target="0.0.0.0"].nexthop' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.route[@.target="0.0.0.0"].nexthop' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.${INTERFACE}_4 status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.target="0.0.0.0"].nexthop' | tr -d "\n")
		fi
		#if [ "$interface_gw" != "" ] && [ "$interface_if" != "" ] && [ -n "$serverip" ] && [ "$(ip route show $serverip | grep $interface_if)" = "" ]; then
		if [ "$interface_gw" != "" ] && [ "$interface_if" != "" ] && [ -z "$(echo $interface_gw | grep :)" ]; then
			if [ "$multipath_config_route" = "master" ]; then
				weight=100
			else
				weight=1
			fi
			if [ "$multipath_config_route" = "backup" ]; then
				nbintfb=$((nbintfb+1))
				if [ -z "$routesintfbackup" ]; then
					routesintfbackup="nexthop via $interface_gw dev $interface_if weight $weight"
				else
					routesintfbackup="$routesintfbackup nexthop via $interface_gw dev $interface_if weight $weight"
				fi
			else
				nbintf=$((nbintf+1))
				if [ -z "$routesintf" ]; then
					routesintf="nexthop via $interface_gw dev $interface_if weight $weight"
				else
					routesintf="$routesintf nexthop via $interface_gw dev $interface_if weight $weight"
				fi
			fi
		fi
	fi
}

# 收集物理接口的 nexthop 信息，用于拼装多路径服务器路由（IPv6）
# 功能与 set_routes_intf 对称，处理 IPv6，跳过 omrvpn 和 omr6in4
# IPv6 网关获取方式与 IPv4 不同：优先从 ip6gw 配置读取，失败则通过 ubus 多层兜底
set_routes_intf6() {
	local multipath_config_route
	local interface_if
	local INTERFACE=$1
	[ -z "$INTERFACE" ] && return
	[ "$INTERFACE" = "omr6in4" ] && return
	[ "$INTERFACE" = "omrvpn" ] && return
	multipath_config_route=$(uci -q get openmptcprouter.$INTERFACE.multipath)
	[ -z "$multipath_config_route" ] && multipath_config_route=$(uci -q get network.$INTERFACE.multipath || echo "off")
	[ "$(uci -q get openmptcprouter.$INTERFACE.multipathvpn)" = "1" ] && {
		[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "openvpn" ] && multipath_config_route="$(uci -q get openmptcprouter.ovpn${INTERFACE}.multipath || echo "off")"
		[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "wireguard" ] && multipath_config_route="$(uci -q get openmptcprouter.wg${INTERFACE}.multipath || echo "off")"
	}
	#network_get_device interface_if $INTERFACE
	interface_if=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
	[ -z "$interface_if" ] && interface_if=$(ifstatus "${INTERFACE}_6" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
	[ -z "$interface_if" ] && interface_if=$(uci -q get network.$INTERFACE.ifname)
	[ -z "$interface_if" ] && interface_if=$(uci -q get network.$INTERFACE.device)
	[ -n "$(echo $interface_if | grep '@')" ] && interface_if=$(ifstatus "$INTERFACE" | jsonfilter -q -e '@["device"]')
	interface_up=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -q -e '@["up"]')
	#multipath_current_config=$(multipath $interface_if | grep 'deactivated')
	interface_current_config=$(uci -q get openmptcprouter.$INTERFACE.state || echo "up")
	interface_vpn=$(uci -q get openmptcprouter.$INTERFACE.vpn || echo "0")
	if { [ "$interface_vpn" = "0" ] || [ "$(uci -q get openmptcprouter.settings.allmptcpovervpn)" = "0" ]; } && [ "$multipath_config_route" != "off" ] && [ "$interface_current_config" = "up" ] && [ "$interface_if" != "" ] && [ "$interface_up" = "true" ]; then
		interface_gw="$(uci -q get network.$INTERFACE.ip6gw)"
		interface_ip6="$(uci -q get network.$INTERFACE.ip6)"
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e "@.inactive.route[@.source=\"${interface_ip6}\"].nexthop" | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e "@.inactive.route[@.source=\"${interface_ip6}/64\"].nexthop" | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e "@.inactive.route[@.source=\"${interface_ip6}/56\"].nexthop" | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.target="::"].nexthop' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.nexthop="::"].target' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.route[@.target="::"].nexthop' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.route[@.nexthop="::"].target' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.${INTERFACE}_6 status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.target="::"].nexthop' | tr -d "\n")
		fi
		#if [ "$interface_gw" != "" ] && [ "$interface_if" != "" ] && [ -n "$serverip" ] && [ "$(ip -6 route show $serverip | grep $interface_if)" = "" ]; then
		if [ "$interface_gw" != "" ] && [ "$interface_if" != "" ] && [ -n "$(echo $interface_gw | grep :)" ]; then
			if [ "$multipath_config_route" = "master" ]; then
				weight=100
			else
				weight=1
			fi
			if [ "$multipath_config_route" = "backup" ]; then
				nbintfb6=$((nbintfb6+1))
				if [ -z "$routesintfbackup6" ]; then
					routesintfbackup6="nexthop via $interface_gw dev $interface_if weight $weight"
				else
					routesintfbackup6="$routesintfbackup6 nexthop via $interface_gw dev $interface_if weight $weight"
				fi
			else
				nbintf6=$((nbintf6+1))
				if [ -z "$routesintf6" ]; then
					routesintf6="nexthop via $interface_gw dev $interface_if weight $weight"
				else
					routesintf6="$routesintf6 nexthop via $interface_gw dev $interface_if weight $weight"
				fi
			fi
		fi
	fi
}

# 收集物理接口的 nexthop 信息，用于拼装默认路由的负载均衡（IPv4）
# 参数: $1 - 接口名（如 wan、wanb），跳过 omrvpn
# 输出: 追加到全局变量 routesbalancing（主链路）或 routesbalancingbackup（备用链路）
# 与 set_routes_intf 的区别: 本函数支持自定义权重（通过 network.<接口>.weight 配置），
#                         主要用于构建 ip route replace default 的多路径 nexthop 列表
# 调用场景: 003-up 中 balancing 模式下替换默认路由时调用
set_route_balancing() {
	local multipath_config_route interface_gw interface_if
	INTERFACE=$1
	[ -z "$INTERFACE" ] && return
	[ "$INTERFACE" = "omrvpn" ] && return
	multipath_config_route=$(uci -q get openmptcprouter.$INTERFACE.multipath)
	[ -z "$multipath_config_route" ] && multipath_config_route=$(uci -q get network.$INTERFACE.multipath || echo "off")
	[ "$(uci -q get openmptcprouter.$INTERFACE.multipathvpn)" = "1" ] && {
		[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "openvpn" ] && multipath_config_route="$(uci -q get openmptcprouter.ovpn${INTERFACE}.multipath || echo "off")"
		[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "wireguard" ] && multipath_config_route="$(uci -q get openmptcprouter.wg${INTERFACE}.multipath || echo "off")"
	}
	#network_get_device interface_if $INTERFACE
	[ -z "$interface_if" ] && interface_if=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
	[ -z "$interface_if" ] && interface_if=$(ifstatus "${INTERFACE}_4" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
	[ -z "$interface_if" ] && interface_if=$(uci -q get network.$INTERFACE.ifname)
	[ -z "$interface_if" ] && interface_if=$(uci -q get network.$INTERFACE.device)
	[ -n "$(echo $interface_if | grep '@')" ] && interface_if=$(ifstatus "$INTERFACE" | jsonfilter -q -e '@["device"]')
	interface_up=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -q -e '@["up"]')
	interface_current_config=$(uci -q get openmptcprouter.$INTERFACE.state || echo "up")
	interface_vpn=$(uci -q get openmptcprouter.$INTERFACE.vpn || echo "0")
	if { [ "$interface_vpn" = "0" ] || [ "$(uci -q get openmptcprouter.settings.allmptcpovervpn)" = "0" ]; } && [ "$multipath_config_route" != "off" ] && [ "$interface_current_config" = "up" ] && [ "$interface_up" = "true" ]; then
		interface_gw="$(uci -q get network.$INTERFACE.gateway)"
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.target="0.0.0.0"].nexthop' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.route[@.target="0.0.0.0"].nexthop' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.${INTERFACE}_4 status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.target="0.0.0.0"].nexthop' | tr -d "\n")
		fi
		if [ "$interface_gw" != "" ] && [ "$interface_if" != "" ]; then
			if [ "$(uci -q get network.$INTERFACE.weight)" != "" ]; then
				weight=$(uci -q get network.$INTERFACE.weight)
			elif [ "$(uci -q get openmtpcprouter.$INTERFACE.weight)" != "" ]; then
				weight=$(uci -q get openmtpcprouter.$INTERFACE.weight)
			elif [ "$multipath_config_route" = "master" ]; then
				weight=100
			else
				weight=1
			fi
			if [ "$multipath_config_route" = "backup" ]; then
				nbintfb=$((nbintfb+1))
				if [ -z "$routesbalancingbackup" ]; then
					routesbalancingbackup="nexthop via $interface_gw dev $interface_if weight $weight"
				else
					routesbalancingbackup="$routesbalancingbackup nexthop via $interface_gw dev $interface_if weight $weight"
				fi
			else
				nbintf=$((nbintf+1))
				if [ -z "$routesbalancing" ]; then
					routesbalancing="nexthop via $interface_gw dev $interface_if weight $weight"
				else
					routesbalancing="$routesbalancing nexthop via $interface_gw dev $interface_if weight $weight"
				fi
			fi
		fi
	fi
}

# 收集物理接口的 nexthop 信息，用于拼装 IPv6 默认路由的负载均衡
# 功能与 set_route_balancing 对称，处理 IPv6，跳过 omrvpn 和 omr6in4
set_route_balancing6() {
	local multipath_config_route interface_gw interface_if
	INTERFACE=$1
	[ -z "$INTERFACE" ] && return
	[ "$INTERFACE" = "omr6in4" ] && return
	[ "$INTERFACE" = "omrvpn" ] && return
	multipath_config_route=$(uci -q get openmptcprouter.$INTERFACE.multipath)
	[ -z "$multipath_config_route" ] && multipath_config_route=$(uci -q get network.$INTERFACE.multipath || echo "off")
	[ "$(uci -q get openmptcprouter.$INTERFACE.multipathvpn)" = "1" ] && {
		[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "openvpn" ] && multipath_config_route="$(uci -q get openmptcprouter.ovpn${INTERFACE}.multipath || echo "off")"
		[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "wireguard" ] && multipath_config_route="$(uci -q get openmptcprouter.wg${INTERFACE}.multipath || echo "off")"
	}
	#network_get_device interface_if $INTERFACE
	[ -z "$interface_if" ] && interface_if=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
	[ -z "$interface_if" ] && interface_if=$(ifstatus "${INTERFACE}_4" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
	[ -z "$interface_if" ] && interface_if=$(uci -q get network.$INTERFACE.ifname)
	[ -z "$interface_if" ] && interface_if=$(uci -q get network.$INTERFACE.device)
	[ -n "$(echo $interface_if | grep '@')" ] && interface_if=$(ifstatus "$INTERFACE" | jsonfilter -q -e '@["device"]')
	interface_up=$(ifstatus "$INTERFACE" 2>/dev/null | jsonfilter -q -e '@["up"]')
	interface_current_config=$(uci -q get openmptcprouter.$INTERFACE.state || echo "up")
	interface_vpn=$(uci -q get openmptcprouter.$INTERFACE.vpn || echo "0")
	if { [ "$interface_vpn" = "0" ] || [ "$(uci -q get openmptcprouter.settings.allmptcpovervpn)" = "0" ]; } && [ "$multipath_config_route" != "off" ] && [ "$interface_current_config" = "up" ] && [ "$interface_up" = "true" ]; then
		interface_gw="$(uci -q get network.$INTERFACE.gateway)"
		interface_ip6="$(uci -q get network.$INTERFACE.ip6)"
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e "@.inactive.route[@.source=\"${interface_ip6}\"].nexthop" | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e "@.inactive.route[@.source=\"${interface_ip6}/64\"].nexthop" | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e "@.inactive.route[@.source=\"${interface_ip6}/56\"].nexthop" | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.target="::"].nexthop' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.nexthop="::"].target' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.route[@.target="::"].nexthop' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.$INTERFACE status 2>/dev/null | jsonfilter -q -l 1 -e '@.route[@.nexthop="::"].target' | tr -d "\n")
		fi
		if [ -z "$interface_gw" ]; then
			interface_gw=$(ubus call network.interface.${INTERFACE}_6 status 2>/dev/null | jsonfilter -q -l 1 -e '@.inactive.route[@.target="::"].nexthop' | tr -d "\n")
		fi
		if [ "$interface_gw" != "" ] && [ "$interface_if" != "" ] && [ -n "$(echo $interface_gw | grep :)" ]; then
			if [ "$(uci -q get network.$INTERFACE.weight)" != "" ]; then
				weight=$(uci -q get network.$INTERFACE.weight)
			elif [ "$(uci -q get openmtpcprouter.$INTERFACE.weight)" != "" ]; then
				weight=$(uci -q get openmtpcprouter.$INTERFACE.weight)
			elif [ "$multipath_config_route" = "master" ]; then
				weight=100
			else
				weight=1
			fi
			if [ "$multipath_config_route" = "backup" ]; then
				nbintfb6=$((nbintfb6+1))
				if [ -z "$routesbalancingbackup6" ]; then
					routesbalancingbackup6="nexthop via $interface_gw dev $interface_if weight $weight"
				else
					routesbalancingbackup6="$routesbalancingbackup6 nexthop via $interface_gw dev $interface_if weight $weight"
				fi
			else
				nbintf6=$((nbintf6+1))
				if [ -z "$routesbalancing6" ]; then
					routesbalancing6="nexthop via $interface_gw dev $interface_if weight $weight"
				else
					routesbalancing6="$routesbalancing6 nexthop via $interface_gw dev $interface_if weight $weight"
				fi
			fi
		fi
	fi
}

# 为服务器 IP 设置多路径主机路由（IPv4）—— 这是路由分析文档中那条多路径路由的来源
# 参数: $1 - server 配置节名
# 流程: 遍历 server 的 ip 列表，对每个 IP：
#       1. 调用 set_routes_intf 收集所有物理接口的 nexthop（含权重）
#       2. 拼装成 ip route replace $serverip metric 1 nexthop via eth1 weight 100 nexthop via usb0 weight 1
#       3. 同时为 backup 组设置 metric 999 的备用路由
# 这就是你路由分析文档中 8.153.200.211 那条多路径路由的生成位置
# 调用场景: 003-up 中 balancing 模式下非 VPN 链路上线时调用
# 注意: omrvpn 上线时走的是 separate VPN 分支，会提前 exit，不会执行到这里！
set_server_all_routes() {
	local server=$1
	[ -z "$OMR_TRACKER_INTERFACE" ] && return
	server_route() {
		local serverip multipath_config_route
		serverip=$1
		[ -n "$serverip" ] && serverip="$(resolveip -4 -t 5 $serverip | head -n 1 | tr -d '\n')"
		config_get disabled $server disabled
		[ "$disabled" = "1" ] && return
		#network_get_device interface_if $OMR_TRACKER_INTERFACE
		[ -z "$interface_if" ] && interface_if=$(ifstatus "$OMR_TRACKER_INTERFACE" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
		[ -z "$interface_if" ] && interface_if=$(ifstatus "${OMR_TRACKER_INTERFACE}_4" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
		[ -z "$interface_if" ] && interface_if=$(ifstatus "$OMR_TRACKER_INTERFACE" | jsonfilter -q -e '@["device"]')
		[ -z "$interface_if" ] && interface_if=$(uci -q get network.$OMR_TRACKER_INTERFACE.ifname)
		[ -z "$interface_if" ] && interface_if=$(uci -q get network.$OMR_TRACKER_INTERFACE.device)
		interface_up=$(ifstatus "$OMR_TRACKER_INTERFACE" 2>/dev/null | jsonfilter -q -e '@["up"]')
		multipath_config_route=$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.multipath || echo "off")
		[ -z "$multipath_config_route" ] && multipath_config_route=$(uci -q get network.$OMR_TRACKER_INTERFACE.multipath || echo 'off')
		[ "$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.multipathvpn)" = "1" ] && {
			[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "openvpn" ] && multipath_config_route="$(uci -q get openmptcprouter.ovpn${OMR_TRACKER_INTERFACE}.multipath || echo "off")"
			[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "wireguard" ] && multipath_config_route="$(uci -q get openmptcprouter.wg${OMR_TRACKER_INTERFACE}.multipath || echo "off")"
		}
		if [ "$serverip" != "" ] && [ "$OMR_TRACKER_DEVICE_GATEWAY" != "" ] && [ "$multipath_config_route" != "off" ] && [ "$interface_up" = "true" ]; then
			routesintf=""
			routesintfbackup=""
			nbintf=0
			nbintfb=0
			config_load network
			config_foreach set_routes_intf interface
			uintf="$(echo $routesintf | awk '{print $5}')"
			uintfb="$(echo $routesintfbackup | awk '{print $5}')"
			if [ -n "$routesintf" ] && { [ "$nbintf" -gt "1" ] && [ "$(ip r show $serverip metric 1 | tr -d '\t' | tr -d '\n' | sed 's/ *$//' | tr ' ' '\n' | sort | tr -d '\n')" != "$(echo $serverip $routesintf | sed 's/ *$//' | tr ' ' '\n' | sort | tr -d '\n')" ]; } || { [ "$nbintf" = "1" ] && [ -n "$uintf" ] && [ "$(ip r show $serverip metric 1 | grep $uintf)" = "" ]; }; then
				while [ "$(ip r show $serverip | grep -v nexthop | sed 's/ //g' | tr -d '\n')" != "$serverip" ] && [ "$(ip r show $serverip | grep -v nexthop | sed 's/ //g' | tr -d '\n')" != "" ]; do
					ip r del $serverip
				done
				[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "Set server $server ($serverip) default route $serverip $routesintf"
				ip route replace $serverip scope global metric 1 $routesintf >/dev/null 2>&1
				[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "New server route is $(ip r show $serverip metric 1 | tr -d '\t' | tr -d '\n')"
			fi
			if [ -n "$routesintfbackup" ] && { [ "$nbintfb" -gt "1" ] && [ "$(ip r show $serverip metric 999 | tr -d '\t' | tr -d '\n' | sed 's/ *$//' | tr ' ' '\n' | sort | tr -d '\n')" != "$(echo $serverip $routesintfbackup | sed 's/ *$//' | tr ' ' '\n' | sort | tr -d '\n')" ]; } || { [ "$nbintfb" = "1" ] && [ -n "$uintfb" ] && [ "$(ip r show $serverip metric 999 | grep $uintfb)" = "" ]; }; then
				[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "Set server $server ($serverip) backup default route $serverip $routesintfbackup nbintfb $nbintfb $OMR_TRACKER_DEVICE"
				ip route replace $serverip scope global metric 999 $routesintfbackup >/dev/null 2>&1
			fi
		fi
	}
	config_load openmptcprouter
	config_list_foreach $server ip server_route
}

# 为服务器 IP 设置多路径主机路由（IPv6）
# 功能与 set_server_all_routes 对称，处理 IPv6，跳过 omrvpn 和 omr6in4
set_server_all_routes6() {
	local server=$1
	[ -z "$OMR_TRACKER_INTERFACE" ] && return
	server_route() {
		local serverip multipath_config_route
		serverip=$1
		[ -n "$serverip" ] && serverip="$(resolveip -6 -t 5 $serverip | head -n 1 | tr -d '\n')"
		config_get disabled $server disabled
		[ "$disabled" = "1" ] && return
		#network_get_device interface_if $OMR_TRACKER_INTERFACE
		[ -z "$interface_if" ] && interface_if=$(ifstatus "$OMR_TRACKER_INTERFACE" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
		[ -z "$interface_if" ] && interface_if=$(ifstatus "${OMR_TRACKER_INTERFACE}_6" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
		[ -z "$interface_if" ] && interface_if=$(ifstatus "$OMR_TRACKER_INTERFACE" | jsonfilter -q -e '@["device"]')
		[ -z "$interface_if" ] && interface_if=$(uci -q get network.$OMR_TRACKER_INTERFACE.ifname)
		[ -z "$interface_if" ] && interface_if=$(uci -q get network.$OMR_TRACKER_INTERFACE.device)
		interface_up=$(ifstatus "$OMR_TRACKER_INTERFACE" 2>/dev/null | jsonfilter -q -e '@["up"]')
		multipath_config_route=$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.multipath || echo "off")
		[ "$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.multipathvpn)" = "1" ] && {
			[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "openvpn" ] && multipath_config_route="$(uci -q get openmptcprouter.ovpn${OMR_TRACKER_INTERFACE}.multipath || echo "off")"
			[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "wireguard" ] && multipath_config_route="$(uci -q get openmptcprouter.wg${OMR_TRACKER_INTERFACE}.multipath || echo "off")"
		}
		if [ "$serverip" != "" ] && [ "$OMR_TRACKER_DEVICE_GATEWAY6" != "" ] && [ "$multipath_config_route" != "off" ] && [ "$interface_up" = "true" ]; then
			routesintf=""
			routesintfbackup=""
			nbintf6=0
			nbintfb6=0
			config_load network
			config_foreach set_routes_intf6 interface
			uintf="$(echo $routesintf6 | awk '{print $5}')"
			uintfb="$(echo $routesintfbackup6 | awk '{print $5}')"
			if [ -n "$routesintf6" ] && { [ "$nbintf6" -gt "1" ] && [ "$(ip -6 r show $serverip metric 1 | tr -d '\t' | sort | tr -d '\n' | sed 's/ *$//')" != "$(echo $serverip $routesintf6 | sort | sed 's/ *$//')" ]; } || { [ "$nbintf6" = "1" ] && [ -n "$uintf" ] && [ "$(ip -6 r show $serverip metric 1 | grep $uintf)" = "" ]; }; then
				while [ "$(ip -6 r show $serverip | grep -v nexthop | sed 's/ //g' | tr -d '\n')" != "$serverip" ] && [ "$(ip -6 r show $serverip | grep -v nexthop | sed 's/ //g' | tr -d '\n')" != "" ]; do
					ip -6 r del $serverip
				done
				[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "Set server $server ($serverip) default route $serverip $routesintf6"
				ip -6 route replace $serverip scope global metric 1 $routesintf6 >/dev/null 2>&1
				[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "New server route is $(ip -6 r show $serverip metric 1 | tr -d '\t' | tr -d '\n')"
			fi
			if [ -n "$routesintfbackup6" ] && { [ "$nbintfb6" -gt "1" ] && [ "$(ip -6 r show $serverip metric 999 | tr -d '\t' | tr -d '\n')" != "$serverip $routesintfbackup6 " ]; } || { [ "$nbintfb6" = "1" ] && [ -n "$uintfb" ] && [ "$(ip -6 r show $serverip metric 999 | grep $uintfb)" = "" ]; }; then
				[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "Set server $server ($serverip) backup default route $serverip $routesintfbackup6 nbintfb $nbintfb6 $OMR_TRACKER_DEVICE"
				ip -6 route replace $serverip scope global metric 999 $routesintfbackup6 >/dev/null 2>&1
			fi
		fi
	}
	config_load openmptcprouter
	config_list_foreach $server ip server_route
}

# 为服务器 IP 设置单链路主机路由（IPv4），非负载均衡模式使用
# 参数: $1 - server 配置节名，$2 - metric 值（可选，默认取 network.<接口>.metric）
# 流程: 遍历 server 的 ip 列表，对每个 IP 添加:
#       ip route replace $serverip via <接口网关> dev <接口设备> metric $metric
# 同时如果接口尚无默认路由且 defaultgw 未禁用，也补上默认路由
# 与 set_server_all_routes 的区别: 本函数生成单 nexthop 路由（非多路径），
#                               适用于非 balancing 模式
# 调用场景: 003-up 中非 VPN、非 balancing 链路上线时调用
set_server_route() {
	local server=$1
	[ -z "$OMR_TRACKER_INTERFACE" ] && return
	server_route() {
		local serverip multipath_config_route
		serverip=$1
		[ -n "$serverip" ] && serverip="$(resolveip -4 -t 5 $serverip | head -n 1 | tr -d '\n')"
		config_get disabled $server disabled
		[ "$disabled" = "1" ] && return
		local metric=$2
		[ -z "$metric" ] && metric=$(uci -q get network.$OMR_TRACKER_INTERFACE.metric)
		multipath_config_route=$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.multipath)
		[ "$multipath_config_route" ] && multipath_config_route=$(uci -q get network.$OMR_TRACKER_INTERFACE.multipath || echo "off")
		[ "$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.multipathvpn)" = "1" ] && {
			[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "openvpn" ] && multipath_config_route="$(uci -q get openmptcprouter.ovpn${OMR_TRACKER_INTERFACE}.multipath || echo "off")"
			[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "wireguard" ] && multipath_config_route="$(uci -q get openmptcprouter.wg${OMR_TRACKER_INTERFACE}.multipath || echo "off")"
		}
		#network_get_device interface_if $OMR_TRACKER_INTERFACE
		[ -z "$interface_if" ] && interface_if=$(ifstatus "$OMR_TRACKER_INTERFACE" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
		[ -z "$interface_if" ] && interface_if=$(ifstatus "${OMR_TRACKER_INTERFACE}_4" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
		[ -z "$interface_if" ] && interface_if=$(ifstatus "$OMR_TRACKER_INTERFACE" | jsonfilter -q -e '@["device"]')
		[ -z "$interface_if" ] && interface_if=$(uci -q get network.$OMR_TRACKER_INTERFACE.ifname)
		[ -z "$interface_if" ] && interface_if=$(uci -q get network.$OMR_TRACKER_INTERFACE.device)
		interface_up=$(ifstatus "$OMR_TRACKER_INTERFACE" 2>/dev/null | jsonfilter -q -e '@["up"]')
		#multipath_current_config=$(multipath $interface_if | grep "deactivated")
		interface_current_config=$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.state || echo "up")
		#if [ "$serverip" != "" ] && [ "$OMR_TRACKER_DEVICE_GATEWAY" != "" ] && [ "$(ip route show dev $OMR_TRACKER_DEVICE metric $metric | grep $serverip | grep $OMR_TRACKER_DEVICE_GATEWAY)" = "" ] && [ "$multipath_config_route" != "off" ] && [ "$multipath_current_config" = "" ]; then
		if [ "$serverip" != "" ] && [ -n "$OMR_TRACKER_DEVICE" ] && [ "$OMR_TRACKER_DEVICE_GATEWAY" != "" ] && [ "$(ip route show dev $OMR_TRACKER_DEVICE metric $metric | grep $serverip | grep $OMR_TRACKER_DEVICE_GATEWAY)" = "" ] && [ "$multipath_config_route" != "off" ] && [ "$interface_current_config" = "up" ] && [ "$interface_up" = "true" ]; then
			[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "Set server $server ($serverip) route via $OMR_TRACKER_DEVICE_GATEWAY metric $metric"
			ip route replace $serverip via $OMR_TRACKER_DEVICE_GATEWAY dev $OMR_TRACKER_DEVICE metric $metric $initcwrwnd >/dev/null 2>&1
		fi
	}
	config_list_foreach $server ip server_route
	if [ "$(uci -q get openmptcprouter.settings.defaultgw)" != "0" ] && [ -n "$metric" ] && [ "$OMR_TRACKER_DEVICE_GATEWAY" != "" ] && [ -n "$OMR_TRACKER_DEVICE" ] && [ "$(ip route show dev $OMR_TRACKER_DEVICE metric $metric | grep default | grep $OMR_TRACKER_DEVICE_GATEWAY)" = "" ] && [ "$multipath_config_route" != "off" ] && [ "$interface_current_config" = "up" ] && [ "$interface_up" = "true" ]; then
		ip route replace default via $OMR_TRACKER_DEVICE_GATEWAY dev $OMR_TRACKER_DEVICE metric $metric $initcwrwnd >/dev/null 2>&1
	fi
}

# 为服务器 IP 设置单链路主机路由（IPv6）
# 功能与 set_server_route 对称，处理 IPv6
set_server_route6() {
	local server=$1
	[ -z "$OMR_TRACKER_INTERFACE" ] && return
	server_route() {
		local serverip multipath_config_route
		serverip=$1
		[ -n "$serverip" ] && serverip="$(resolveip -6 -t 5 $serverip | head -n 1 | tr -d '\n')"
		config_get disabled $server disabled
		[ "$disabled" = "1" ] && return
		local metric=$2
		[ -z "$metric" ] && metric=$(uci -q get network.$OMR_TRACKER_INTERFACE.metric)
		multipath_config_route=$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.multipath)
		[ "$multipath_config_route" ] && multipath_config_route=$(uci -q get network.$OMR_TRACKER_INTERFACE.multipath || echo "off")
		[ "$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.multipathvpn)" = "1" ] && {
			[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "openvpn" ] && multipath_config_route="$(uci -q get openmptcprouter.ovpn${OMR_TRACKER_INTERFACE}.multipath || echo "off")"
			[ "$(uci -q get openmptcprouter.settings.mptcpovervpn)" = "wireguard" ] && multipath_config_route="$(uci -q get openmptcprouter.wg${OMR_TRACKER_INTERFACE}.multipath || echo "off")"
		}
		#network_get_device interface_if $OMR_TRACKER_INTERFACE
		[ -z "$interface_if" ] && interface_if=$(ifstatus "$OMR_TRACKER_INTERFACE" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
		[ -z "$interface_if" ] && interface_if=$(ifstatus "${OMR_TRACKER_INTERFACE}_6" 2>/dev/null | jsonfilter -q -e '@["l3_device"]')
		[ -z "$interface_if" ] && interface_if=$(ifstatus "$OMR_TRACKER_INTERFACE" | jsonfilter -q -e '@["device"]')
		[ -z "$interface_if" ] && interface_if=$(uci -q get network.$OMR_TRACKER_INTERFACE.ifname)
		[ -z "$interface_if" ] && interface_if=$(uci -q get network.$OMR_TRACKER_INTERFACE.device)
		interface_up=$(ifstatus "$OMR_TRACKER_INTERFACE" 2>/dev/null | jsonfilter -q -e '@["up"]')
		#multipath_current_config=$(multipath $interface_if | grep "deactivated")
		interface_current_config=$(uci -q get openmptcprouter.$OMR_TRACKER_INTERFACE.state || echo "up")
		#if [ "$serverip" != "" ] && [ "$OMR_TRACKER_DEVICE_GATEWAY6" != "" ] && [ "$(ip -6 route show dev $OMR_TRACKER_DEVICE metric $metric | grep $serverip | grep $OMR_TRACKER_DEVICE_GATEWAY)" = "" ] && [ "$multipath_config_route" != "off" ] && [ "$multipath_current_config" = "" ]; then
		if [ "$serverip" != "" ] && [ "$OMR_TRACKER_DEVICE_GATEWAY6" != "" ] && [ -n "$OMR_TRACKER_DEVICE" ] && [ "$(ip -6 route show dev $OMR_TRACKER_DEVICE metric $metric | grep $serverip | grep $OMR_TRACKER_DEVICE_GATEWAY6)" = "" ] && [ "$multipath_config_route" != "off" ] && [ "$interface_current_config" = "up" ] && [ "$interface_up" = "true" ]; then
			[ "$(uci -q get openmptcprouter.settings.debug)" = "true" ] && _log "Set server $server ($serverip) route via $OMR_TRACKER_DEVICE_GATEWAY metric $metric"
			ip -6 route replace $serverip via $OMR_TRACKER_DEVICE_GATEWAY6 dev $OMR_TRACKER_DEVICE metric $metric >/dev/null 2>&1
		fi
	}
	config_list_foreach $server ip server_route
	if [ "$(uci -q get openmptcprouter.settings.defaultgw)" != "0" ] && [ "$OMR_TRACKER_DEVICE_GATEWAY6" != "" ] && [ -n "$OMR_TRACKER_DEVICE" ] && [ -n "$metric" ] && [ "$(ip -6 route show dev $OMR_TRACKER_DEVICE metric $metric | grep default | grep $OMR_TRACKER_DEVICE_GATEWAY6)" = "" ] && [ "$multipath_config_route" != "off" ] && [ "$interface_current_config" = "up" ] && [ "$interface_up" = "true" ]; then
		ip -6 route replace default via $OMR_TRACKER_DEVICE_GATEWAY6 dev $OMR_TRACKER_DEVICE metric $metric >/dev/null 2>&1
	fi
}

# 删除当前 tracker 接口上的 IPv4 默认路由
# 调用场景: 002-error 中链路 down 时清理残留默认路由
del_default_route() {
	ip route del default dev $OMR_TRACKER_DEVICE >/dev/null 2>&1
}

# 删除服务器 IPv4 主机路由，包括指定 metric 的、无 metric 的、以及各种匹配方式
# 参数: $1 - server 配置节名
# 流程: 遍历 server 的 ip 列表，用多种方式尝试删除路由（metric 匹配、dev 匹配、grep 匹配）
#       同时删除该接口上的默认路由
# 调用场景: 002-error 中链路 down 时清理该链路对应的服务器路由
del_server_route() {
	local server=$1
	remove_route() {
		local serverip="$1"
		[ -n "$serverip" ] && serverip="$(resolveip -4 -t 5 $serverip | head -n 1 | tr -d '\n')"
		[ -n "$serverip" ] && _log "Delete default route to $serverip dev $OMR_TRACKER_DEVICE"
		local metric
		if [ -z "$OMR_TRACKER_INTERFACE" ]; then
			metric=0
		else
			metric=$(uci -q get network.$OMR_TRACKER_INTERFACE.metric)
		fi
		[ -n "$metric" ] && [ -n "$OMR_TRACKER_DEVICE" ] && [ -n "$serverip" ] && [ -n "$(ip route show $serverip dev $OMR_TRACKER_DEVICE metric $metric)" ] && ip route del $serverip dev $OMR_TRACKER_DEVICE metric $metric >/dev/null 2>&1
		[ -n "$OMR_TRACKER_DEVICE" ] && [ -n "$serverip" ] && [ -n "$(ip route show $serverip dev $OMR_TRACKER_DEVICE)" ] && ip route del $serverip dev $OMR_TRACKER_DEVICE >/dev/null 2>&1
		[ -n "$OMR_TRACKER_DEVICE" ] && [ -n "$serverip" ] && [ -n "$(ip route show $serverip | grep $OMR_TRACKER_DEVICE)" ] && ip route del $serverip dev $OMR_TRACKER_DEVICE >/dev/null 2>&1
	}
	config_list_foreach $server ip remove_route
	if [ -n "$OMR_TRACKER_DEVICE_GATEWAY" ] && [ -n "$OMR_TRACKER_DEVICE" ]; then
		[ -n "$(ip route show default via $OMR_TRACKER_DEVICE_GATEWAY dev $OMR_TRACKER_DEVICE)" ] && ip route del default via $OMR_TRACKER_DEVICE_GATEWAY dev $OMR_TRACKER_DEVICE >/dev/null 2>&1
	elif [ -n "$OMR_TRACKER_DEVICE" ]; then
		[ -n "$(ip route show default dev $OMR_TRACKER_DEVICE)" ] && ip route del default dev $OMR_TRACKER_DEVICE >/dev/null 2>&1
	fi
}

# 删除服务器 IPv6 主机路由
# 功能与 del_server_route 对称，处理 IPv6
del_server_route6() {
	local server=$1
	remove_route() {
		local serverip="$1"
		[ -n "$serverip" ] && serverip="$(resolveip -6 -t 5 $serverip | head -n 1 | tr -d '\n')"
		[ -n "$serverip" ] && _log "Delete default route to $serverip via $OMR_TRACKER_DEVICE_GATEWAY6 dev $OMR_TRACKER_DEVICE"
		local metric
		if [ -z "$OMR_TRACKER_INTERFACE" ]; then
			metric=0
		else
			metric=$(uci -q get network.$OMR_TRACKER_INTERFACE.metric)
		fi
		[ -n "$OMR_TRACKER_DEVICE" ] && [ -n "$metric" ] && [ -n "$serverip" ] && [ -n "$(ip -6 route show $serverip dev $OMR_TRACKER_DEVICE metric $metric)" ] && ip -6 route del $serverip dev $OMR_TRACKER_DEVICE metric $metric >/dev/null 2>&1
		[ -n "$OMR_TRACKER_DEVICE" ] && [ -n "$metric" ] && [ -n "$serverip" ] && [ -n "$(ip -6 route show $serverip dev $OMR_TRACKER_DEVICE)" ] && ip -6 route del $serverip dev $OMR_TRACKER_DEVICE >/dev/null 2>&1
	}
	config_list_foreach $server ip remove_route
	if [ -n "$OMR_TRACKER_DEVICE_GATEWAY6" ] && [ -n "$OMR_TRACKER_DEVICE" ]; then
		[ -n "$(ip -6 route show default via $OMR_TRACKER_DEVICE_GATEWAY6 dev $OMR_TRACKER_DEVICE)" ] && ip -6 route del default via $OMR_TRACKER_DEVICE_GATEWAY6 dev $OMR_TRACKER_DEVICE >/dev/null 2>&1
	elif [ -n "$OMR_TRACKER_DEVICE" ]; then
		[ -n "$(ip -6 route show default dev $OMR_TRACKER_DEVICE)" ] && ip -6 route del default dev $OMR_TRACKER_DEVICE >/dev/null 2>&1
	fi
}

# 统计启用了 Pi-hole 功能的服务器数量
# 参数: $1 - server 配置节名
# 输出: 递增全局变量 nbserver（总服务器数）和 piholeenabled（启用 Pi-hole 的服务器数）
# 调用场景: 003-up 中隧道 up 后，判断是否所有服务器都启用了 Pi-hole，若是则触发 set_pihole
enable_pihole() {
	local server=$1
	nbserver=$((nbserver+1))
	if [ -n "$server" ] && [ "$(uci -q get openmptcprouter.${server}.pihole)" = "1" ] && [ "$(uci -q get dhcp.@dnsmasq[0].server | grep '127.0.0.1#5353')" != "" ]; then
		piholeenabled=$((piholeenabled+1))
	fi
}

# 禁用 Pi-hole DNS 服务，将 DNS 回退到本地 unbound (127.0.0.1#5353)
# 当检测到 dnsmasq 配置中有指向 VPN 隧道的 DNS 服务器（10.255.25.x）时执行
# 操作: 删除 VPN 隧道 DNS，添加本地 unbound，重启 dnsmasq
# 调用场景: 002-error 中链路 down 时避免 DNS 请求走已断开的隧道
disable_pihole() {
	local server=$1
	if [ -n "$(uci -q get dhcp.@dnsmasq[0].server | grep '#53' | grep '10.255.25')" ]; then
		_log "Disable Pi-Hole..."
		uci -q del_list dhcp.@dnsmasq[0].server="$(uci -q get dhcp.@dnsmasq[0].server | tr ' ' '\n' | grep '#53' | grep '10.255.25')"
		if [ -z "$(uci -q get dhcp.@dnsmasq[0].server | grep '127.0.0.1#5353')" ]; then
			uci -q batch <<-EOF >/dev/null
				add_list dhcp.@dnsmasq[0].server='127.0.0.1#5353'
				commit dhcp
			EOF
		fi
		/etc/init.d/dnsmasq restart >/dev/null 2>&1
	fi
}

# 刷新 unbound DNS 缓存（清除负面缓存和伪造缓存）
# 调用场景: 003-up 中链路恢复时清除旧 DNS 缓存，确保新链路的 DNS 解析正确
dns_flush() {
	_log "DNS flush"
	unbound-control flush-negative >/dev/null 2>&1
	unbound-control flush-bogus >/dev/null 2>&1
}

# 设置多个 OpenVPN 实例（omr、omr2 等）间的负载均衡默认路由
# 参数: $1 - VPN 网关 IP（如 10.255.252.1）
# 流程: 遍历 openvpn 配置中所有以 "omr" 开头的实例，拼接 nexthop
#       生成: ip route replace default scope global nexthop via <vpngw> dev tun0 nexthop via <vpngw> dev tun1 ...
# 调用场景: 003-up 中 omrvpn 链路 up 且启用了第二个 OpenVPN 实例时调用
set_vpn_balancing_routes() {
	vpngw="$1"
	vpn_route() {
		local vpnname
		vpnname=$1
		[ -z "$(echo $vpnname | grep omr)" ] && return
		config_get enabled $vpnname enabled
		[ "$enabled" != "1" ] && return
		config_get dev $vpnname dev
		[ -z "$dev" ] && return
		allvpnroutes="$allvpnroutes nexthop via $vpngw dev $dev"
	}
	allvpnroutes=""
	config_load openvpn
	config_foreach vpn_route openvpn
	_log "allvpnroutes: $allvpnroutes"
	[ -n "$allvpnroutes" ] && ip route replace default scope global${allvpnroutes} >/dev/null 2>&1
}

