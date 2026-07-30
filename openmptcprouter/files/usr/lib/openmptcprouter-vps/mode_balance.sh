#!/bin/sh

MWAN3_CONFIG_FILE="/etc/config/mwan3"
MWAN3_CONFIG_BACKUP="/etc/config/mwan3.omr_backup"
MWAN3_BALANCE_POLICY="balanced"
MWAN3_BALANCE_RULE_V4="default_rule_v4"

# 统一输出负载均衡模式相关日志，便于排查配置生成与切换过程。
mwan3_balance_log() {
	logger -t "OMR-VPS" "<${FUNCNAME:-mwan3_balance}> $*"
}

# 首次进入负载均衡模式时备份原始 mwan3 配置，退出模式后用于完整恢复。
mwan3_balance_backup_config() {
	[ -f "$MWAN3_CONFIG_BACKUP" ] && {
		mwan3_balance_log "backup already exists, skip"
		return 0
	}
	[ -f "$MWAN3_CONFIG_FILE" ] || {
		mwan3_balance_log "mwan3 config file not found, skip backup"
		return 0
	}

	cp "$MWAN3_CONFIG_FILE" "$MWAN3_CONFIG_BACKUP"
	mwan3_balance_log "backup mwan3 config to $MWAN3_CONFIG_BACKUP"
}

# 将此前备份的原始mwan3配置恢复回来,避免覆盖用户已有自定义配置
mwan3_balance_restore_config() {
	[ -f "$MWAN3_CONFIG_BACKUP" ] || return 0

	cp "$MWAN3_CONFIG_BACKUP" "$MWAN3_CONFIG_FILE"
	rm -f "$MWAN3_CONFIG_BACKUP"
	uci -q commit mwan3
	mwan3_balance_log "restore mwan3 config from backup"
}

# 清空当前mwan3中的interface/member/policy/rule节,为重新生成负载均衡配置做准备
# 使用计数器防止uci delete静默失败时的无限循环
mwan3_balance_clear_runtime_config() {
	local section max_iter=128 i=0

	while [ $i -lt $max_iter ]; do
		i=$((i + 1))
		section="$(uci -q show mwan3 | awk -F'[.=]' '$3 == "interface" || $3 == "member" || $3 == "policy" || $3 == "rule" {print $2; exit}')"
		[ -n "$section" ] || break
		uci -q delete "mwan3.${section}"
	done

	[ $i -ge $max_iter ] && mwan3_balance_log "WARNING: clear_runtime_config hit max_iter=$max_iter, may be incomplete"
}

# 为指定接口写入默认探测目标，使用国内常见公共 DNS 作为链路可达性检测地址。
mwan3_balance_set_default_track_ips() {
	local iface="$1"

	uci -q add_list "mwan3.${iface}.track_ip=223.5.5.5"
	uci -q add_list "mwan3.${iface}.track_ip=223.6.6.6"
	uci -q add_list "mwan3.${iface}.track_ip=119.29.29.29"
	uci -q add_list "mwan3.${iface}.track_ip=180.76.76.76"
}

# 为参与负载均衡的接口生成 mwan3 interface 配置，只启用 IPv4 探测。
mwan3_balance_add_interface() {
	local iface="$1"

	uci -q set "mwan3.${iface}=interface"
	uci -q set "mwan3.${iface}.enabled=1"
	uci -q set "mwan3.${iface}.family=ipv4"
	uci -q set "mwan3.${iface}.reliability=1"
	mwan3_balance_set_default_track_ips "$iface"
}

# 为指定接口按 weight 生成一个固定 metric=1 的 mwan3 member。
mwan3_balance_add_member() {
	local iface="$1"
	local weight="$2"
	local member="${iface}_m1_w${weight}"

	uci -q set "mwan3.${member}=member"
	uci -q set "mwan3.${member}.interface=${iface}"
	uci -q set "mwan3.${member}.metric=1"
	uci -q set "mwan3.${member}.weight=${weight}"

	echo "$member"
}

# 生成统一的 balanced policy，并把所有有效 member 挂到该策略下
mwan3_balance_add_policy() {
	local members="$1"
	local member

	uci -q set "mwan3.${MWAN3_BALANCE_POLICY}=policy"
	uci -q set "mwan3.${MWAN3_BALANCE_POLICY}.last_resort=unreachable"

	for member in $members; do
		uci -q add_list "mwan3.${MWAN3_BALANCE_POLICY}.use_member=${member}"
	done
}

# 生成默认 IPv4 规则,让普通出站流量进入 balanced 策略
mwan3_balance_add_rule() {
	uci -q set "mwan3.${MWAN3_BALANCE_RULE_V4}=rule"
	uci -q set "mwan3.${MWAN3_BALANCE_RULE_V4}.dest_ip=0.0.0.0/0"
	uci -q set "mwan3.${MWAN3_BALANCE_RULE_V4}.use_policy=${MWAN3_BALANCE_POLICY}"
	uci -q set "mwan3.${MWAN3_BALANCE_RULE_V4}.family=ipv4"
}

# 从 global.balance 收集有效链路，并为每条权重大于 0 的接口生成 interface/member。
mwan3_balance_collect_members() {
	local option iface weight member
	local members=""

	for option in $(uci -q show global.balance | sed -n "s/^global\\.balance\\.\\([^=]*\\)_weight='\\([^']*\\)'$/\\1:\\2/p"); do
		iface="${option%%:*}"
		weight="${option##*:}"

		case "$weight" in
			''|*[!0-9]*)
				mwan3_balance_log "skip invalid weight ${iface}=${weight}"
				continue
			;;
		esac

		[ "$weight" -gt 0 ] || {
			mwan3_balance_log "skip disabled iface ${iface} weight=${weight}"
			continue
		}

		[ "$(uci -q get "network.${iface}")" = "interface" ] || {
			mwan3_balance_log "skip unknown network interface ${iface}"
			continue
		}

		mwan3_balance_add_interface "$iface"
		member="$(mwan3_balance_add_member "$iface" "$weight")"
		members="${members} ${member}"
		mwan3_balance_log "use iface ${iface} weight=${weight} member=${member}"
	done

	echo "$members" | xargs
}

# 生成完整的mwan3负载均衡配置并提交到 UCI
mwan3_balance_generate_config() {
	local members

	# 清空当前 mwan3 中的 interface/member/policy/rule 节,准备重新生成配置
	mwan3_balance_clear_runtime_config

	# 确保globals节存在（mwan3_init需要从中读取mmx_mask）
	[ "$(uci -q get mwan3.globals)" = "globals" ] || {
		uci -q set mwan3.globals=globals
		uci -q set mwan3.globals.mmx_mask=0x3F00
	}

	# 从 global.balance 收集有效链路，并为每条权重大于 0 的接口生成 interface/member。
	members="$(mwan3_balance_collect_members)"

	[ -n "$members" ] || {
		mwan3_balance_log "no valid balance members found"
		return 1
	}

	# 生成统一的 balanced policy，并把所有有效 member 挂到该策略下
	mwan3_balance_add_policy "$members"
	# 生成默认 IPv4 规则,让普通出站流量进入 balanced 策略
	mwan3_balance_add_rule
	uci -q commit mwan3

	mwan3_balance_log "generated mwan3 balance config: members=${members}"
	return 0
}

# 收集参与负载均衡的原始接口名列表（如 sim1 wan1），供 masquerade 使用。
mwan3_balance_get_ifaces() {
	local option iface weight

	for option in $(uci -q show global.balance | sed -n "s/^global\\.balance\\.\\([^=]*\\)_weight='\\([^']*\\)'$/\\1:\\2/p"); do
		iface="${option%%:*}"
		weight="${option##*:}"

		case "$weight" in ''|*[!0-9]*) continue ;; esac
		[ "$weight" -gt 0 ] || continue
		[ "$(uci -q get "network.${iface}")" = "interface" ] || continue
		echo "$iface"
	done | xargs
}

# 将参与负载均衡的接口加入 firewall zone_wan 并启用 MASQUERADE，
# 确保路由器自身发出的流量使用正确的源 IP，避免源地址与出口不匹配导致丢包。
# 该函数备份原始 firewall.zone_wan 配置，退出负载均衡模式时恢复。
mwan3_balance_setup_masquerade() {
	[ "$(uci -q get firewall.zone_wan)" = "zone" ] || {
		mwan3_balance_log "firewall.zone_wan not found, skip masquerade setup"
		return
	}

	local current_networks="$(uci -q get firewall.zone_wan.network)"
	[ -n "$current_networks" ] && [ -z "$(uci -q get openmptcprouter.settings.balance_wan_networks_backup)" ] && {
		uci -q set openmptcprouter.settings.balance_wan_networks_backup="$current_networks"
		uci -q commit openmptcprouter
		mwan3_balance_log "backup firewall.zone_wan.network"
	}

	uci -q del firewall.zone_wan.network
	for iface in $1; do
		uci -q add_list firewall.zone_wan.network="$iface"
	done
	[ "$(uci -q get firewall.zone_wan.masq)" = "1" ] || uci -q set firewall.zone_wan.masq=1
	uci -q commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
	mwan3_balance_log "enable MASQUERADE for balance interfaces: $1"
}

# 恢复进入负载均衡模式前的 firewall.zone_wan 配置。
mwan3_balance_cleanup_masquerade() {
	[ "$(uci -q get firewall.zone_wan)" = "zone" ] || return
	local backup_networks="$(uci -q get openmptcprouter.settings.balance_wan_networks_backup)"
	[ -z "$backup_networks" ] && return

	uci -q del firewall.zone_wan.network
	for net in $backup_networks; do
		uci -q add_list firewall.zone_wan.network="$net"
	done
	uci -q commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1

	uci -q delete openmptcprouter.settings.balance_wan_networks_backup
	uci -q commit openmptcprouter
	mwan3_balance_log "restore firewall.zone_wan from backup"
}

# 停止负载均衡模式，停掉 mwan3 并恢复进入该模式前的原始配置。
stop_mode_balance() {
	mwan3_balance_log "stop balance mode"

# 	mwan3_balance_cleanup_masquerade

	/etc/init.d/mwan3 stop >/dev/null 2>&1
	mwan3_balance_restore_config
}

# 负载均衡模式主入口：停止其他模式，生成配置并重启 mwan3 使其生效。
mode_balance_handler() {
	logger -t "OMR-VPS" "<mode_balance_handler> mode: balance"

	# 停止单卡模式，并复用其中的公共辅助函数
	[ -f /usr/lib/openmptcprouter-vps/mode_single.sh ] && {
		. /usr/lib/openmptcprouter-vps/mode_single.sh
		stop_mode_single
	}

	# 停止聚合模式
	[ -f /usr/lib/openmptcprouter-vps/mode_aggregate.sh ] && {
		. /usr/lib/openmptcprouter-vps/mode_aggregate.sh
		stop_mode_aggregate
	}

	type stop_all_vpn >/dev/null 2>&1 && stop_all_vpn

	mwan3_balance_backup_config
	
	# 生成完整的mwan3负载均衡配置并提交到 UCI
	if ! mwan3_balance_generate_config; then
		mwan3_balance_log "generate balance config failed, stop mwan3"
		/etc/init.d/mwan3 stop >/dev/null 2>&1
		mwan3_balance_restore_config
		return 1
	fi

	# 收集参与负载均衡的原始接口名列表(如 sim1 wan1), 供masquerade使用
	# 解决的是路由器自身出站流量的源IP与出口不匹配问题
	# 具体场景如下:
	## 1. 路由器自己发起请求(如 DNS 查询、NTP 同步、ping 检测), Linux 内核根据路由表选择源 IP, 比如选的是 sim1 的 IP
	## 2. mwan3 的fwmark策略路由把这个包实际从wan1发出去了
	## 3. 包到达对方服务器时,源IP还是sim1的地址
	## 4. 对方回复时把包发给sim1的IP,但sim1此时可能不通,或者回复路径与发出路径不一致
	## 5. 结果是conntrack中出现大量[UNREPLIED] —— 包发出去了但没收到回复
	## 6. 启用MASQUERADE后,iptables会把源IP改写为实际出口接口的IP,确保回包能正确返回
	## 7. 注意: 这只影响路由器自身的流量。来自LAN的转发流量不受影响,因为mwan3在PREROUTING阶段就已经决定了出口,且LAN设备的IP是私有地址,本来就会被MASQUERADE
	local balance_ifaces
	balance_ifaces="$(mwan3_balance_get_ifaces)"
	[ -n "$balance_ifaces" ] && mwan3_balance_setup_masquerade "$balance_ifaces"

	/etc/init.d/mwan3 restart >/dev/null 2>&1
	mwan3_balance_log "restart mwan3 for balance mode"
}
