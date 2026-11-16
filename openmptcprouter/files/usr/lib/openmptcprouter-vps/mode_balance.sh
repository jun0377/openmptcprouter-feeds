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

# 停止负载均衡模式，停掉 mwan3 并恢复进入该模式前的原始配置。
# firewall.zone_wan 的恢复由 mode_manager.sh 统一处理。
# 注意: mwan3 的 stop_service 会 flush 所有 <=MWAN3_INTERFACE_MAX(默认 60) 的路由表,
# 因此本项目的 WAN 策略表已统一放到 metric+100(>60), 不会被误删。
stop_mode_balance() {
	mwan3_balance_log "stop balance mode"

	# 无论 procd 是否认为 mwan3 在运行, 都执行一次 stop:
	# 它同时清理可能残留的 iptables/fwmark 规则; 本项目 WAN 表已迁到 >60, 不会被其 flush
	if [ -x /etc/init.d/mwan3 ]; then
		/etc/init.d/mwan3 stop >/dev/null 2>&1
	else
		mwan3_balance_log "mwan3 init script not found, skip stop"
	fi

	mwan3_balance_restore_config

	# 旧版本遗留的备份键(新版本由 mode_manager.sh 统一维护)
	if [ -n "$(uci -q get openmptcprouter.settings.balance_wan_networks_backup)" ]; then
		uci -q delete openmptcprouter.settings.balance_wan_networks_backup
		uci -q commit openmptcprouter >/dev/null 2>&1
	fi
}

