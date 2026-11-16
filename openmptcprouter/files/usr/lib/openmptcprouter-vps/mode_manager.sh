#!/bin/sh
# 工作模式状态机: 单卡 / 负载均衡 / 聚合 的唯一切换入口
#
# 设计要点:
#   1. 单一入口 + flock 串行化, 避免并发 restart 时两套模式互相拆除;
#      目标模式在拿到锁之后再读, 并在搭建完成后复核, 保证最终生效的是最新模式;
#   2. 两阶段切换: teardown_all 先把三种模式的残留统一归零, 再按目标模式搭建;
#   3. firewall.zone_wan 由本文件统一快照/恢复, 各模式不再各自备份, 避免备份互相污染。

MODE_DIR="/usr/lib/openmptcprouter-vps"
MODE_LOCK_FILE="/var/lock/omr-mode.lock"
# 原始 zone_wan 快照, 保存格式: <masq>|<net1> <net2> ...
ZONE_BACKUP_KEY="zone_wan_backup"
_MODE_LOCKED=0

mode_log() {
	logger -t "OMR-VPS" "<mode_manager> $*"
}

# ---------------------------------------------------------------------------
# 串行化: 同一时刻只允许一个模式切换流程
# ---------------------------------------------------------------------------
_mode_lock() {
	# 极端情况下没有 flock 时退化为不加锁, 保证模式仍能切换
	if ! command -v flock >/dev/null 2>&1; then
		mode_log "flock not found, continue without serialization"
		return 0
	fi

	mkdir -p /var/lock
	exec 9>"${MODE_LOCK_FILE}"

	# 注意: 本机 BusyBox 的 flock 不支持 -w, 用 -xn + 循环自己实现超时。
	# 等待期间每 30s 记一条日志; 上限 600s, 避免另一个 apply 异常卡死时无限阻塞。
	local waited=0
	while ! flock -xn 9; do
		if [ "$waited" -gt 0 ] && [ $((waited % 30)) -eq 0 ]; then
			mode_log "waiting for mode lock... ${waited}s"
		fi
		[ "$waited" -ge 600 ] && {
			mode_log "ERROR: acquire lock timeout(${MODE_LOCK_FILE}), another apply is still running"
			exec 9>&-
			return 1
		}
		sleep 1
		waited=$((waited + 1))
	done

	_MODE_LOCKED=1
	return 0
}

_mode_unlock() {
	[ "$_MODE_LOCKED" = "1" ] || return 0
	flock -u 9 2>/dev/null
	exec 9>&-
	_MODE_LOCKED=0
}

# ---------------------------------------------------------------------------
# firewall zone_wan: 统一快照 / 恢复 / 按模式收窄
# ---------------------------------------------------------------------------
_zone_snapshot() {
	[ -n "$(uci -q get openmptcprouter.settings.${ZONE_BACKUP_KEY})" ] && return 0
	[ "$(uci -q get firewall.zone_wan)" = "zone" ] || return 0

	local masq networks legacy

	masq="$(uci -q get firewall.zone_wan.masq)"
	[ -z "$masq" ] && masq="0"

	# 升级迁移: 旧版本按模式各存一份备份, 优先采用它们记录的原值
	for legacy in single_wan_networks_backup balance_wan_networks_backup; do
		networks="$(uci -q get openmptcprouter.settings.${legacy})"
		[ -n "$networks" ] && break
	done
	[ -z "$networks" ] && networks="$(uci -q get firewall.zone_wan.network)"

	uci -q set openmptcprouter.settings.${ZONE_BACKUP_KEY}="${masq}|${networks}"
	uci -q commit openmptcprouter
	mode_log "snapshot zone_wan: masq=${masq} networks=${networks}"
}

_zone_restore() {
	local snap masq networks net

	snap="$(uci -q get openmptcprouter.settings.${ZONE_BACKUP_KEY})"
	[ -n "$snap" ] || return 0
	[ "$(uci -q get firewall.zone_wan)" = "zone" ] || return 0

	masq="${snap%%|*}"
	networks="${snap#*|}"
	[ -z "$masq" ] && masq="0"

	uci -q del firewall.zone_wan.network
	for net in $networks; do
		uci -q add_list firewall.zone_wan.network="$net"
	done
	uci -q set firewall.zone_wan.masq="$masq"
	uci -q commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
	mode_log "restore zone_wan: masq=${masq} networks=${networks}"
}

# 将 zone_wan 收窄到指定接口集合, 并开启 masquerade
_zone_apply() {
	local ifaces="$1" net

	[ -n "$ifaces" ] || return 0
	[ "$(uci -q get firewall.zone_wan)" = "zone" ] || return 0

	_zone_snapshot
	uci -q del firewall.zone_wan.network
	for net in $ifaces; do
		uci -q add_list firewall.zone_wan.network="$net"
	done
	uci -q set firewall.zone_wan.masq=1
	uci -q commit firewall
	/etc/init.d/firewall reload >/dev/null 2>&1
	mode_log "apply zone_wan: masq=1 networks=${ifaces}"
}

# ---------------------------------------------------------------------------
# 统一归零
# ---------------------------------------------------------------------------
teardown_all() {
	mode_log "teardown start"

	# 先快照(含旧版本备份键的迁移), 再拆除各模式
	_zone_snapshot

	# tracker 先停, 避免它在规则/路由尚未稳定的中间态上重算
	/etc/init.d/omr-tracker stop >/dev/null 2>&1

	# 停聚合(隧道) -> 负载均衡(mwan3) -> 单卡(策略规则), 三个 stop 都要求幂等
	stop_mode_aggregate
	stop_mode_balance
	stop_mode_single

	# 统一恢复原始 firewall WAN 区
	_zone_restore

	mode_log "teardown done"
}

# ---------------------------------------------------------------------------
# 第二阶段: 按目标模式搭建
# ---------------------------------------------------------------------------
# 单卡模式
apply_single_mode() {
	local channel

	nft_snat
	channel="$(uci -q get global.single.channel)"
	[ -n "$channel" ] && _zone_apply "$channel"
	return 0
}

# 负载均衡模式
apply_balance_mode() {
	local ifaces

	mwan3_balance_backup_config
	if ! mwan3_balance_generate_config; then
		mode_log "generate balance config failed"
		/etc/init.d/mwan3 stop >/dev/null 2>&1
		mwan3_balance_restore_config
		return 1
	fi

	ifaces="$(mwan3_balance_get_ifaces)"
	[ -n "$ifaces" ] && _zone_apply "$ifaces"

	/etc/init.d/mwan3 restart >/dev/null 2>&1
	mode_log "balance mode applied: ${ifaces}"
	return 0
}

# 聚合模式
apply_aggregate_mode() {
	config_load openmptcprouter
	config_foreach _get_local_wan_ip interface
	config_foreach _config_service server
	uci -q commit openmptcprouter >/dev/null 2>&1
	mode_log "aggregate mode applied"
	return 0
}

# ---------------------------------------------------------------------------
# 切换后自检: 只记录异常, 不在切换过程中做重操作
# ---------------------------------------------------------------------------
_verify_mode() {
	local mode="$1" iface table lookup

	case "$mode" in
		single)
			lookup="$(uci -q get network.omr_single_lan.lookup)"
			[ -n "$lookup" ] && [ -z "$(ip -4 rule show 2>/dev/null | grep -E "lookup ${lookup}\$")" ] && \
				mode_log "WARN: single-mode rule for table ${lookup} missing"
			;;
		balance)
			/etc/init.d/mwan3 running >/dev/null 2>&1 || mode_log "WARN: mwan3 not running"
			;;
		aggregate)
			lookup="$(uci -q get network.omrvpn.ip4table)"
			[ -n "$lookup" ] && [ -z "$(ip -4 rule show 2>/dev/null | grep -E "lookup ${lookup}\$")" ] && \
				mode_log "WARN: aggregate rule for table ${lookup} missing"
			;;
	esac

	# 已拨号成功的模拟链路: 策略表里必须有默认路由
	for iface in $(uci -q show network 2>/dev/null | sed -n "s/^network\.\([^.=]*\)=interface$/\1/p"); do
		case "$iface" in sim*) ;; *) continue ;; esac
		table="$(uci -q get network.${iface}.ip4table)"
		case "$table" in ''|*[!0-9]*) continue ;; esac
		[ "$(ifstatus "$iface" 2>/dev/null | jsonfilter -q -e '@.up')" = "true" ] || continue
		[ -n "$(ip -4 route show table "$table" 2>/dev/null | grep '^default ')" ] || \
			mode_log "WARN: ${iface} table ${table} has no default route"
	done
}

# ---------------------------------------------------------------------------
# 主入口: 使指定工作模式生效
# ---------------------------------------------------------------------------
omr_mode_apply() {
	local mode rc=0 round=0 latest
	local max_round=5

	_mode_lock || return 1

	# 目标模式必须在拿到锁之后再读: 确保当用户在网页上快速切换工作模式时, 最终生效的一定是最新的配置
	while :; do
		round=$((round + 1))
		mode="$(uci -q get global.global.mode)"
		case "$mode" in
			single|balance|aggregate) ;;
			*)
				mode_log "unknown mode '${mode}', fallback to single"
				mode="single"
				;;
		esac

		mode_log "apply start: mode=${mode} (round ${round})"

		rc=0
		teardown_all
		case "$mode" in
			single)		apply_single_mode || rc=1 ;;
			balance)	apply_balance_mode || rc=1 ;;
			aggregate)	apply_aggregate_mode || rc=1 ;;
		esac

		# 给 netifd/firewall 一点收敛时间, 再做自检, 减少中间态误报
		sleep 3
		_verify_mode "$mode"

		# tracker 无论搭建是否成功都要拉起, 否则链路故障后无法自动恢复
		/etc/init.d/omr-tracker restart >/dev/null 2>&1

		# 搭建期间用户又切换了模式: 继续按最新模式收敛, 保证最后一次 apply 对应最终状态
		latest="$(uci -q get global.global.mode)"
		[ -z "$latest" ] && latest="single"
		[ "$latest" = "$mode" ] && break

		if [ "$round" -ge "$max_round" ]; then
			mode_log "mode keeps changing, stop after ${round} rounds (applied=${mode}, latest=${latest})"
			rc=1
			break
		fi
		mode_log "mode changed during apply: ${mode} -> ${latest}, re-apply"
	done

	if [ "$rc" = "0" ]; then
		mode_log "apply done: mode=${mode}"
	else
		mode_log "apply finished with errors: mode=${mode}"
	fi

	_mode_unlock
	return $rc
}

# 加载各模式的辅助函数(只提供 stop/搭建步骤, 不再互相调用)
[ -f "${MODE_DIR}/mode_single.sh" ] && . "${MODE_DIR}/mode_single.sh"
[ -f "${MODE_DIR}/mode_balance.sh" ] && . "${MODE_DIR}/mode_balance.sh"
[ -f "${MODE_DIR}/mode_aggregate.sh" ] && . "${MODE_DIR}/mode_aggregate.sh"
