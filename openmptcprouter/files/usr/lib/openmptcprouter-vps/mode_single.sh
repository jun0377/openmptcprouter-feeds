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

	# omr-tracker
	/etc/init.d/omr-tracker stop >/dev/null 2>&1
	logger -t "OMR-VPS" "<$FUNCNAME> /etc/init.d/omr-tracker stop"
}

# 单卡模式处理逻辑
mode_single_handler() {
	logger -t "OMR-VPS" "<$FUNCNAME> mode: single"
	# 停止所有VPN和代理进程
	stop_all_vpn
}
