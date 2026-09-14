#!/bin/sh
# 遍历配置文件中的接口，找到属于LAN防火墙区域的接口，将其IP和掩码保存到全局变量lanips中
_get_lan_ip() {
	local intf=$1
	# 只关注LAN防火墙区域的接口，即只关注LAN口
	if [ "$(uci -q get firewall.zone_lan.network | grep $intf)" != "" ]; then
		lanip="$(uci -q get network.${intf}.ipaddr)/$(uci -q get network.${intf}.netmask)"
		if [ "$lanip" != "/" ]; then
			if [ -z "$lanips" ]; then
				# lanips='"192.168.1.1/255.255.255.0"'
				lanips='"'${lanip}'"'
			else
				# 追加，如：lanips='"192.168.1.1/255.255.255.0" "192.168.2.1/255.255.255.0"'
				lanips='"'$lanips'" "'${lanip}'"'
			fi
		fi

		logger -t "OMR-VPS" "<$FUNCNAME> interface:${intf} lanip:${lanip} lanips:${lanips}"
	fi
}

# 设备和VPS之间同步VPN接口的IP地址配置
_set_vpn_ip() {
	local settings
	[ -z "$vps_config" ] && vps_config=$(_get_json "config?serial=${serial}")
	[ -z "$vps_config" ] && logger -t "OMR-VPS" "<$FUNCNAME> No config..." && return
	# 未启用任何VPN，return
	[ "$(uci -q get openmptcprouter.settings.vpn)" = "none" ] && logger -t "OMR-VPS" "openmptcprouter.settings.vpn=none, return now..." && return
	# 从UCI配置文件获取VPN虚拟网口名称(network.omrvpn.device)
	vpnifname="$(uci -q get network.omrvpn.device)"
	# mqvpn 的隧道设备由 mqvpn.interface.tun_name 决定(默认 mqvpn0), network.omrvpn.device 可能仍是遗留的 tun0
	if [ "$(uci -q get openmptcprouter.settings.vpn)" = "mqvpn" ]; then
		vpnifname="$(uci -q get mqvpn.interface.tun_name)"
		[ -z "$vpnifname" ] && vpnifname="mqvpn0"
	fi
	# 从服务器获取到的vpn本地IP，服务器的remoteip就是设备的local ip
	vpnip_local_current="$(echo "$vps_config" | jsonfilter -q -e '@.vpn.remoteip')"
	# vpn当前本地IP, 即隧道设备(openvpn:tun0, mqvpn:mqvpn0)的IP
	vpnip_local=$(ip -4 -br addr ls dev ${vpnifname} 2>/dev/null | awk -F'[ /]+' '{print $3}')

	# 服务器端的VPN IP，服务器的local ip就是设备的remote ip
	vpnip_remote_current="$(echo "$vps_config" | jsonfilter -q -e '@.vpn.localip')"
	# 多种方式尝试获取VPN远端IP，增强程序鲁棒性
	vpnip_remote=$(ip -4 r show default dev ${vpnifname} 2>/dev/null | awk '{print $3}' | tr -d "\n")
	[ -z "$vpnip_remote" ] && [ -n "$vpnifname" ] && vpnip_remote=$(ip -4 r list dev ${vpnifname} 2>/dev/null | grep kernel | awk '{print $1}' | tr -d "\n")
	[ -z "$vpnip_remote" ] && [ -n "$vpnifname" ] && vpnip_remote=$(ip -4 r list dev ${vpnifname} 2>/dev/null | grep "proto static src" | awk '{print $3}' | tr -d "\n")
	[ -z "$vpnip_remote" ] && vpnip_remote=$(ifstatus omrvpn | jsonfilter -e '@.route[0].nexthop')
	[ -z "$vpnip_remote" ] && [ "$vpnifname" = "bonding-omrvpn" ] && vpnip_remote="10.255.248.1"
	
	# Unique Local Address，IPv6的唯一本地地址
	ula="$(uci -q get network.globals.ula_prefix)"
	ula_current="$(echo "$vps_config" | jsonfilter -q -e '@.ip6in4.ula')"
	
	logger -t "OMR-VPS" "<$FUNCNAME> vpnifname:${vpnifname}" "vpnip_local:${vpnip_local}" "vpnip_remote:${vpnip_remote}" "ula:${ula}"
	
	# 服务器和客户端的参数不一致，重新将本地配置同步到服务器端
	if [ "$vpnip_remote" != "" ] \
	&& [ "$vpnip_local" != "" ] \
	&& ([ "$vpnip_remote" != "$vpnip_remote_current" ] \
	|| [ "$vpnip_local" != "$vpnip_local_current" ] \
	|| [ "$ula" != "$ula_current" ]); then
		settings='{"remoteip" : "'$vpnip_local'","localip" : "'$vpnip_remote'","ula" : "'$ula'"}'
		logger -t "OMR-VPS" "<$FUNCNAME> set VPS vpn ip:${settings}"
		result=$(_set_json "vpnips" "$settings")
	fi
}

set_vpn_ip() {
	_set_vpn_ip
}

# 优雅停止指定 VPN: 先关 UCI 开关(procd 不再 respawn, 重启后也不自启), 再让 procd 结束实例
_stop_vpn() {
	local name="$1" section flag
	case "$name" in
		openvpn) section="openvpn.omr"; flag="openvpn.omr.enabled" ;;
		mqvpn)   section="mqvpn.settings"; flag="mqvpn.settings.enable" ;;
		*)       return 0 ;;
	esac
	[ -f /etc/init.d/${name} ] && [ -n "$(uci -q get ${section})" ] || return 0
	# 已经是禁用状态就不用再写 UCI, 只负责把可能残留的实例停掉
	[ "$(uci -q get ${flag})" = "0" ] || { uci -q set "${flag}=0"; uci -q commit "${name}"; }
	/etc/init.d/${name} stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> stop ${name}"
}

# mqvpn
_set_mqvpn_vps() {

	local enabled="$(uci -q get mqvpn.settings.enable)"
	logger -t "OMR-VPS" "<$FUNCNAME> enable:${enabled}"
	# 能走到这里说明聚合模式就是要用 mqvpn, enable 不为 1 时直接修正并回写, 而不是退出
	[ "$enabled" = "1" ] || {
		logger -t "OMR-VPS" "<$FUNCNAME> MQVPN disabled(enable:${enabled}), set enable=1 now..."
		enabled="1"
		uci -q set mqvpn.settings.enable="1"
	}

	# 服务器IP
	local server_ip="$(uci -q get openmptcprouter.vps.ip | awk '{print $1}')"
	local current_server_ip="$(uci -q get mqvpn.server.ip)"
	if [ -z "$server_ip" ]; then
		logger -t "OMR-VPS" "<$FUNCNAME> openmptcprouter.vps.ip is empty, keep mqvpn.server.ip:${current_server_ip}"
	elif [ "$current_server_ip" != "$server_ip" ]; then
		logger -t "OMR-VPS" "<$FUNCNAME> mqvpn.server.ip changed:${current_server_ip} -> ${server_ip}, set mqvpn now..."
		uci -q set mqvpn.server.ip="$server_ip"
	fi

	# 统一提交上面 enable 与 server.ip 的修改
	[ -n "$(uci -q changes mqvpn)" ] && uci -q commit mqvpn

	local mqvpn_dev="$(uci -q get mqvpn.interface.tun_name)"
	[ -z "$mqvpn_dev" ] && mqvpn_dev="mqvpn0"
	if [ "$(uci -q get network.omrvpn.device)" != "$mqvpn_dev" ]; then
		logger -t "OMR-VPS" "<$FUNCNAME> set network.omrvpn.device=${mqvpn_dev}"
		uci -q set network.omrvpn.device="$mqvpn_dev"
		uci -q commit network
		ifup omrvpn >/dev/null 2>&1
	fi

	# 检查端口号是否为空
	local port="$(uci -q get mqvpn.server.port)"
	[ -z "$port" ] && logger -t "OMR-VPS" "<$FUNCNAME> mqvpn.server.port is empty, wait for next time..." && echo 1 && return

	# 从服务器检索配置
	[ -z "$vps_config" ] && vps_config=$(_get_json "config?serial=${serial}")
	[ -z "$vps_config" ] && logger -t "OMR-VPS" "<$FUNCNAME> vps_config is empty! return now..." && return
	
	# 从服务器检索到的端口号
	local current_port="$(echo "$vps_config" | jsonfilter -q -e '@.mqvpn.port')"
	logger -t "OMR-VPS" "<$FUNCNAME> local port:${port} vps port:${current_port}"
	[ -z "$current_port" ] && logger -t "OMR-VPS" "<$FUNCNAME> vps mqvpn.port is empty, wait for next time..." && echo 1 && return
	
	# 本地key
	local key="$(uci -q get mqvpn.auth.key)"
	[ -z "$key" ] && logger -t "OMR-VPS" "<$FUNCNAME> MQVPN key not set, return now..." && echo "MQVPN key not set" && return
	
	# 调度策略
	local scheduler="$(uci -q get mqvpn.multipath.scheduler)"
	[ -z "$scheduler" ] && scheduler="$(echo "$vps_config" | jsonfilter -q -e '@.mqvpn.scheduler')"
	[ -z "$scheduler" ] && scheduler="wlb"

	# 拥塞控制策略
	local cc="$(uci -q get mqvpn.multipath.cc)"
	[ -z "$cc" ] && cc="$(echo "$vps_config" | jsonfilter -q -e '@.mqvpn.cc')"
	[ -z "$cc" ] && cc="bbr2"

	# FEC
	local fec_enable="$(echo "$vps_config" | jsonfilter -q -e '@.mqvpn.fec_enable')"
	[ -z "$fec_enable" ] && fec_enable="false"
	local fec_scheme="$(echo "$vps_config" | jsonfilter -q -e '@.mqvpn.fec_scheme')"
	[ -z "$fec_scheme" ] && fec_scheme="xor"

	# 重注入策略
	local reinjection_control="$(echo "$vps_config" | jsonfilter -q -e '@.mqvpn.reinjection_control')"
	[ -z "$reinjection_control" ] && reinjection_control="false"
	local reinjection_mode="$(echo "$vps_config" | jsonfilter -q -e '@.mqvpn.reinjection_mode')"
	[ -z "$reinjection_mode" ] && reinjection_mode="default"

	local settings='{"key": "'$key'", "port": '$port', "scheduler": "'$scheduler'", "cc": "'$cc'", "fec_enable": '$fec_enable', "fec_scheme": "'$fec_scheme'", "reinjection_control": '$reinjection_control', "reinjection_mode": "'$reinjection_mode'"}'
	logger -t "OMR-VPS" "<$FUNCNAME> set VPS mqvpn:${settings}"

	local result=$(_set_json "mqvpn" "$settings")
	logger -t "OMR-VPS" "<$FUNCNAME> result:${result}"

	[ -n "$result" ] && uci -q set openmptcprouter.${servername}.get_config="1"
	
	/etc/init.d/mqvpn restart >/dev/null 2>&1
	
	echo $result
}

_config_service() {
	servername=$1		# vps
	logger -t "OMR-VPS" "<$FUNCNAME> servername:${servername} serverip:$(uci -q get openmptcprouter.vps.ip) serverport:$(uci -q get openmptcprouter.vps.port)"

	vps_config=""
	tokenserver=$(_get_token $servername)
	server="$(echo $tokenserver | cut -f1 -d:)"
	serverport="$(echo $tokenserver | cut -f2 -d:)"
    token="$(echo $tokenserver | cut -f3 -d:)"
	[ -z "$token" ] && logger -t "OMR-VPS" "<$FUNCNAME> Get token error!" && return
	
    error=0

    # 根据序列号从服务器端检索配置
	if [ -n "$serial" ]; then
		logger -t "OMR-VPS" "<$FUNCNAME> serial=${serial}"
		[ -z "$vps_config" ] && { 
            logger -t "OMR-VPS" "<$FUNCNAME> get config from ${servername}:${server}"
            vps_config=$(_get_json "config?serial=${serial}") 
        }

		if [ -n "$vps_config" ] && [ "$( echo "$vps_config" | jsonfilter -q -e '@.error')" = "False serial number" ]; then
			logger -t "OMR-VPS" "<$FUNCNAME> Invalid serial number! return now..."
			sed -i "s:${server}::g" /etc/config/*
			return
		fi
	fi

    # 获取服务器信息
	vps_info=$(_get_json "getservernode?serial=${serial}") && echo ${vps_info} > /etc/vps_info
    logger -t "OMR-VPS" "<$FUNCNAME> vps country: $(echo "$vps_info" | jsonfilter -q -e '@.country')"
    logger -t "OMR-VPS" "<$FUNCNAME> vps countryCode: $(echo "$vps_info" | jsonfilter -q -e '@.countryCode')"
    logger -t "OMR-VPS" "<$FUNCNAME> vps regionName: $(echo "$vps_info" | jsonfilter -q -e '@.regionName')"
    logger -t "OMR-VPS" "<$FUNCNAME> vps region: $(echo "$vps_info" | jsonfilter -q -e '@.region')"
    logger -t "OMR-VPS" "<$FUNCNAME> vps city: $(echo "$vps_info" | jsonfilter -q -e '@.city')"
    logger -t "OMR-VPS" "<$FUNCNAME> vps lat: $(echo "$vps_info" | jsonfilter -q -e '@.lat') lon: $(echo "$vps_info" | jsonfilter -q -e '@.lon')"
    logger -t "OMR-VPS" "<$FUNCNAME> vps timezone: $(echo "$vps_info" | jsonfilter -q -e '@.timezone')"
    logger -t "OMR-VPS" "<$FUNCNAME> vps isp: $(echo "$vps_info" | jsonfilter -q -e '@.isp')"
    logger -t "OMR-VPS" "<$FUNCNAME> vps org: $(echo "$vps_info" | jsonfilter -q -e '@.org')"
    logger -t "OMR-VPS" "<$FUNCNAME> vps as: $(echo "$vps_info" | jsonfilter -q -e '@.as')"
    logger -t "OMR-VPS" "<$FUNCNAME> vps query: $(echo "$vps_info" | jsonfilter -q -e '@.query')"

    logger -t "OMR-VPS" "<$FUNCNAME> get vps version"
	vps_version=$(_get_json "getserverversion?serial=${serial}") && echo ${vps_version} | jsonfilter -q -e '@.version' | tr -d '\r\n' > /etc/vps_version
	logger -t "OMR-VPS" "<$FUNCNAME> vps_version: $(cat /etc/vps_version)"

    logger -t "OMR-VPS" "<$FUNCNAME> get vps annpurcement"
	vps_annourcement=$(_get_json "getserverannourcement?serial=${serial}") && echo ${vps_annourcement} | jsonfilter -q -e '@.annourcement' > /etc/vps_annourcement
	logger -t "OMR-VPS" "<$FUNCNAME> vps_annourcement: $(cat /etc/vps_annourcement)"

	[ "$(uci -q get openmptcprouter.${servername}.get_config)" = "1" ] && \
	([ "$(uci -q get openmptcprouter.${servername}.master)" = "1" ] || \
	[ "$(uci -q get openmptcprouter.${servername}.current)" = "1" ]) && \
	{
		logger -t "OMR-VPS" "<$FUNCNAME> get config from VPS..."
		_set_config_from_vps
		_get_vps_config
	}

    # 首次配置阶段”自动选择更合适的加密算法（优先启用 AES 硬件加速对应的算法）
	if [ "$(uci -q get openmptcprouter.settings.firstboot)" != "0" ]; then
		[ -n "$(cat /proc/cpuinfo | grep aes)" ] && {
			vps_aes="$(echo "$vps_config" | jsonfilter -q -e '@.vps.aes')"
			method="$(uci -q get openmptcprouter.settings.encryption)"
			if [ "$vps_aes" != "false" ] && [ "$method" != "aes-256-gcm" ]; then
				logger -t "OMR-VPS" "<$FUNCNAME> CPU support AES, set it by default"
				uci -q batch <<-EOF >/dev/null
					set openmptcprouter.settings.encryption="aes-256-gcm"
					commit openmptcprouter
				EOF
			fi
		}
	fi

	[ -z "$vps_config" ] && { 
        logger -t "OMR-VPS" "<$FUNCNAME> get config from VPS..."
        vps_config=$(_get_json "config?serial=${serial}")
    }

	[ -z "$vps_config" ] || { 
        local vps_kernel="$(echo "$vps_config" | jsonfilter -q -e '@.vps.kernel')"
        local vps_machine="$(echo "$vps_config" | jsonfilter -q -e '@.vps.machine')"
        local vps_aes="$(echo "$vps_config" | jsonfilter -q -e '@.vps.aes')"
        logger -t "OMR-VPS" "<$FUNCNAME> vps kernel:${vps_kernel} machine:${vps_machine} aes:${vps_aes}"
    }
	
    [ -z "$vps_config" ] && logger -t "OMR-VPS" "<$FUNCNAME> vps_config is empty! return now..." && return

	kernel="$(echo "$vps_config" | jsonfilter -q -e '@.vps.kernel')"
	[ -z "$kernel" ] && logger -t "OMR-VPS" "<$FUNCNAME> vps kernel unknown! return now..." && return
	logger -t "OMR-VPS" "<$FUNCNAME> vps kernel: ${kernel}"

	# openmptcprouter.settings.vpn 决定聚合模式使用哪种 VPN
	local vpn_type="$(uci -q get openmptcprouter.settings.vpn)"
	if [ -z "$vpn_type" ]; then
		vpn_type="mqvpn"
		logger -t "OMR-VPS" "<$FUNCNAME> settings.vpn is empty, set default to ${vpn_type}"
		uci -q set openmptcprouter.settings.vpn="${vpn_type}"
		uci -q commit openmptcprouter
	fi

	logger -t "OMR-VPS" "<$FUNCNAME> aggregate vpn:${vpn_type}"

	case "$vpn_type" in
		openvpn)
			_stop_vpn mqvpn
			[ -n "$(uci -q get openvpn.omr)" ] && [ -z "$(_set_openvpn_vps)" ] && error=1 && logger -t "OMR-VPS" "<$FUNCNAME> _set_openvpn_vps error!"
			;;
		mqvpn)
			_stop_vpn openvpn
			[ -z "$(_set_mqvpn_vps)" ] && error=1 && logger -t "OMR-VPS" "<$FUNCNAME> _set_mqvpn_vps error!"
			;;
		*)
			logger -t "OMR-VPS" "<$FUNCNAME> aggregate vpn:${vpn_type} not supported, skip!"
			;;
	esac

	[ -z "$(_set_mptcp_vps)" ] && error=1 && logger -t "OMR-VPS" "<$FUNCNAME> _set_mptcp_vps error!"

	[ -z "$(_set_vpn_vps)" ] && error=1 && logger -t "OMR-VPS" "<$FUNCNAME> _set_vpn_vps error!"

	[ -n "$wanips" ] && _set_wan_ip
	_set_vpn_ip
	config_load network
	lanips=""
	config_foreach _get_lan_ip interface
	_set_sipalg
	if [ "$error" = 0 ]; then
		logger -t "OMR-VPS" "<$FUNCNAME> No errors"
		uci -q set openmptcprouter.${servername}.lastchange=$(date "+%s")
		[ -n "$vps_config" ] && uci -q set openmptcprouter.settings.firstboot=0
	else
		logger -t "OMR-VPS" "<$FUNCNAME> Set server config error, try again"
	fi

	uci -q batch <<-EOF >/dev/null
		set openmptcprouter.${servername}.admin_error=$error
		commit openmptcprouter
	EOF
}

# 停止聚合模式
stop_mode_aggregate() {
	echo ""
}

mode_aggregate_handler() {

	# 停止单卡模式
	[ -f /usr/lib/openmptcprouter-vps/mode_single.sh ] && {
		. /usr/lib/openmptcprouter-vps/mode_single.sh
		stop_mode_single
	}

	# 停止负载均衡模式
	[ -f /usr/lib/openmptcprouter-vps/mode_balance.sh ] && {
		. /usr/lib/openmptcprouter-vps/mode_balance.sh
		stop_mode_balance
	}

    logger -t "OMR-VPS" "$FUNCNAME..."

	config_load openmptcprouter
	config_foreach _get_local_wan_ip interface
	config_foreach _config_service server				# uci show openmptcprouter | grep '=server
	uci -q batch <<-EOF >/dev/null
		commit openmptcprouter
	EOF
}
