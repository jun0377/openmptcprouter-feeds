#!/bin/bash

# 停止负载均衡模式
function stop_mode_balance() {
	echo ""
}


# 负载均衡模式处理逻辑
mode_balance_handler() {
	logger -t "OMR-VPS" "<$FUNCNAME> mode: single"

    # 停止单卡模式
	[ -f /usr/lib/openmptcprouter-vps/mode_single.sh ] && {
		. /usr/lib/openmptcprouter-vps/mode_single.sh
		stop_mode_single
	}

	# 停止聚合模式
	[ -f /usr/lib/openmptcprouter-vps/mode_aggregate.sh ] && {
		. /usr/lib/openmptcprouter-vps/mode_aggregate.sh
		stop_mode_aggregate
	}

	# 停止所有VPN和代理进程
	stop_all_vpn
	# 更新nft snat规则
	nft_snat
}
