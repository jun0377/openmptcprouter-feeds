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

# 设备和VPS之间协商LAN口IP地址配置
_set_lan_ip() {

	# 将LAN IP发送到服务器端，由服务器端协商分配
	uci get network.lan.ipaddr;    uci get network.lan.netmask;
	local settings='{"sn" : "'${serial}'", "lanip" : "'$(uci get network.lan.ipaddr)'", "lanmask" : "'$(uci get network.lan.netmask)'"}'
	local result=$(_set_json "setLanIP" "${settings}")
	logger -t "OMR-VPS" "<$FUNCNAME> result:${result}"

	# 重新从服务器获取LAN IP
	local response=$(_get_json "getLanIP?serial=${serial}")
	logger -t "OMR-VPS" "<$FUNCNAME> response:${response}"
	local lanIP=$(echo ${response} | jsonfilter -e '@.lanip') # 192.168.0.1/255.255.255.0
	# logger -t "OMR-VPS" "<$FUNCNAME> lanIP:${lanIP}"
	local lanMask=$(echo ${response} | jsonfilter -e '@.lanmask')

    # lan ip
	if [ ! -z "${lanIP}" ] && [ "${lanIP}" != "$(uci get network.lan.ipaddr)" ]; then
        logger -t "OMR-VPS" "<$FUNCNAME> lan ip changed from $(uci get network.lan.ipaddr) to ${lanIP}"
		uci set network.lan.ipaddr=${lanIP}
		logger -t "OMR-VPS" "<$FUNCNAME> uci set network.lan.ipaddr=${lanIP}"
	else
		logger -t "OMR-VPS" "<$FUNCNAME> lanIP:${lanIP}"
	fi

    # lan mask
	if [ ! -z "${lanMask}" ] && [ "${lanMask}" != "$(uci get network.lan.netmask)" ]; then
        logger -t "OMR-VPS" "<$FUNCNAME> lan netmask changed from $(uci get network.lan.netmask) to ${lanMask}"
		uci set network.lan.netmask=${lanMask}
		logger -t "OMR-VPS" "<$FUNCNAME> uci set network.lan.netmask=${lanMask}"
	else
		logger -t "OMR-VPS" "<$FUNCNAME> lanMask:${lanMask}"
	fi

	uci commit network
	logger -t "OMR-VPS" "<$FUNCNAME> uci commit network"
	
	# 立即生效
	ifdown lan && ifup lan
}

# 设备和VPS之间同步VPN接口的IP地址配置
_set_vpn_ip() {
	local settings
	[ -z "$vps_config" ] && vps_config=$(_get_json "config?serial=${serial}")
	[ -z "$vps_config" ] && logger -t "OMR-VPS" "<$FUNCNAME> No config..." && return
	# 未启用任何VPN，return
	[ "$(uci -q get openmptcprouter.settings.vpn)" = "none" ] && logger -t "OMR-VPS" "openmptcprouter.settings.vpn=none, return now..." && return
	# 从UCI配置文件获取VPN虚拟网口名称，uci get network.omrvpn.device == tun0
	vpnifname="$(uci -q get network.omrvpn.device)"
	# 从服务器获取到的vpn本地IP，服务器的remoteip就是设备的local ip
	vpnip_local_current="$(echo "$vps_config" | jsonfilter -q -e '@.vpn.remoteip')"
	# vpn当前本地IP,即tun0的IP
	vpnip_local=$(ip -4 -br addr ls dev ${vpnifname} 2>/dev/null | awk -F'[ /]+' '{print $3}')
	[ -z "$vpnip_local" ]  && vpnip_local=$(ip -4 addr show dev "$OMR_TRACKER_DEVICE" | grep -m 1 inet | awk '{print $2}' | cut -d'/' -s -f1)
	# 服务器端的VPN IP，服务器的local ip就是设备的remote ip
	vpnip_remote_current="$(echo "$vps_config" | jsonfilter -q -e '@.vpn.localip')"
	# 多种方式尝试获取VPN远端IP，增强程序鲁棒性
	vpnip_remote=$(ip -4 r show default dev ${vpnifname} | awk '{print $3}' | tr -d "\n")
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

_config_service() {
	servername=$1
	logger -t "OMR-VPS" "<$FUNCNAME> servername:${servername} serverip:$(uci -q get openmptcprouter.vps.ip) serverport:$(uci -q get openmptcprouter.vps.port)"

	[ "$(uci -q get openmptcprouter.${servername}.disabled)" = "1" ] && logger -t "OMR-VPS" "<$FUNCNAME> servername:$1 disabled" && return

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

        local lan_ips="$(echo "$vps_config" | jsonfilter -q -e '@.lan.ips')"
        logger -t "OMR-VPS" "<$FUNCNAME> lan ips:${lan_ips}"
    }
	
    [ -z "$vps_config" ] && logger -t "OMR-VPS" "<$FUNCNAME> vps_config is empty! return now..." && return

	kernel="$(echo "$vps_config" | jsonfilter -q -e '@.vps.kernel')"
	[ -z "$kernel" ] && logger -t "OMR-VPS" "<$FUNCNAME> vps kernel unknown! return now..." && return
	logger -t "OMR-VPS" "<$FUNCNAME> vps kernel: ${kernel}"

	[ -n "$(uci -q get openvpn.omr)" ] && [ -z "$(_set_openvpn_vps)" ] && error=1 && logger -t "OMR-VPS" "<$FUNCNAME> _set_openvpn_vps error!"

	# _backup_list

	# redirect_port="0"
	# if [ "$(uci -q get openmptcprouter.${servername}.redirect_ports)" = "1" ] || [ "$(uci -q get upnpd.config.enabled)" = "1" ]; then
	# 	redirect_port="1"
	# fi
	# logger -t "OMR-VPS" "<$FUNCNAME> redirect_port=${redirect_port}"

	# [ -z "$(_set_redirect_ports_from_vps $redirect_port)" ] && error=1 && logger -t "OMR-VPS" "<$FUNCNAME> _set_redirect_ports_from_vps error!"

	[ -z "$(_set_mptcp_vps)" ] && error=1 && logger -t "OMR-VPS" "<$FUNCNAME> _set_mptcp_vps error!"
	[ -z "$(_set_vpn_vps)" ] && error=1 && logger -t "OMR-VPS" "<$FUNCNAME> _set_vpn_vps error!"
	# [ -z "$(_set_proxy_vps)" ] && error=1 && logger -t "OMR-VPS" "<$FUNCNAME> _set_proxy_vps error!"

	[ -n "$wanips" ] && _set_wan_ip
	_set_vpn_ip
	config_load network
	lanips=""
	config_foreach _get_lan_ip interface
	_set_lan_ip
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

mode_aggregate_handler() {
    
    logger -t "OMR-VPS" "<$FUNCNAME>..."

	config_load openmptcprouter
	config_foreach _get_local_wan_ip interface
	config_foreach _config_service server
	uci -q batch <<-EOF >/dev/null
		commit openmptcprouter
	EOF
}
