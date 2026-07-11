#!/bin/bash

ifname=$1               # 逻辑网口名, 如sim1 wan1

SIM_ICCID=""            # SIM卡的ICCID
SIM_IMSI=""             # SIM卡的IMSI
SIM_STATUS=""           # SIM卡状态的字符串描述
SIM_C5GREG=""           # 5G Core 注册状态，即终端在 5G 核心网 的注册状态
SIM_CREG=""             # EPS域注册状态,即LTE注册状态
SIM_PLMN=""             # 运营商信息
SIM_FREQ=""             # LTE/NR工作频率查询,当前小区的频率信息
SIM_MONSC=""            # 当前驻留小区信息
SIM_MONNC=""            # 相邻小区信息
SIM_IPv4=""             # 拨号成功后获取到的IPv4地址
SIM_IPv6=""             # 拨号成功后获取到的IPv6地址

DIAL_CID=1              # 拨号使用的PDP上下文索引
DIAL_APN=""             # 拨号使用的APN
DIAL_NET=""             # 入网方式配置: AUTO SA NSA LTE

DIAL_AUTH_TYPE=""       # 鉴权方式: NONE PAP CHAP
DIAL_AUTH_USER=""       # 用户名
DIAL_AUTH_PASSWD=""     # 密码

NR_LOCK_ENABLE=""       # NR锁频/锁小区使能: 0-关闭锁频功能; 1-启用锁定频点功能; 2-启用锁定小区功能; 3-启用锁定Band功能
NR_LOCK_PCID=""         # NR PCID
NR_LOCK_BAND=""         # NR频段
NR_LOCK_FREQ=""         # NR频点
NR_LOCK_SCS=""          # NR子载波间隔
NR_FREQLOCK_JSON="{}"   # JSON格式的NR锁频/锁小区信息

LTE_LOCK_ENABLE=""      # LTE锁频/锁小区使能: 0-关闭锁频功能; 1-启用锁定频点功能; 2-启用锁定小区功能; 3-启用锁定Band功能
LTE_LOCK_PCID=""        # LTE PCID
LTE_LOCK_BAND=""        # LTE频段
LTE_LOCK_FREQ=""        # LTE频点
LTE_FREQLOCK_JSON="{}"  # JSON格式的LTE锁频/锁小区信息

function _log()
{
    logger -t "tracker-sim ${ifname}" "<${interface} ${ttyUSB}>" "$@"
}

# 保存到tmpfs
function _save()
{
    local item=$1       # 参数项
    local state=$2      # 参数值

    local statusfs="/tmp/tracker-sim/${ifname}"
    [ -d ${statusfs} ] || mkdir -p ${statusfs}

    # JSON 美化
    case "${state}" in
        {*}|\[{*)
            echo "${state}" | jq . > "${statusfs}/${item}"
            ;;
        *)
            echo "${state}" > "${statusfs}/${item}"
            ;;
    esac
}

# 由 tracker-sim 在 source 本文件前通过 check_base 设置的 sysfs 变量
# 在此处统一保存到 tmpfs
_save "ifname" "${ifname}"
_save "sysfs" "${sysfs}"
_save "ttyUSB" "${ttyUSB}"
_save "interface" "${interface}"
_save "VID" "${VID}"
_save "PID" "${PID}"

# CME错误码转成字符串 (3GPP TS 27.007)
errMsg=""
function CNE_ERROR_MSG
{
    # 从AT指令返回值中提取CME ERROR码，如 "+CME ERROR: 4"
    local code=$(echo "$1" | sed -n 's/.*+CME ERROR: *\([0-9]\+\).*/\1/p')
    [ -z "$code" ] && return

    case "$code" in
        0)  errMsg="phone failure" ;;
        1)  errMsg="no connection to phone" ;;
        2)  errMsg="phone-adaptor link reserved" ;;
        3)  errMsg="operation not allowed" ;;
        4)  errMsg="operation not supported" ;;
        5)  errMsg="PH-SIM PIN required" ;;
        6)  errMsg="PH-FSIM PIN required" ;;
        7)  errMsg="PH-FSIM PUK required" ;;
        10) errMsg="SIM not inserted" ;;
        11) errMsg="SIM PIN required" ;;
        12) errMsg="SIM PUK required" ;;
        13) errMsg="SIM failure" ;;
        14) errMsg="SIM busy" ;;
        15) errMsg="SIM wrong" ;;
        16) errMsg="incorrect password" ;;
        17) errMsg="SIM PIN2 required" ;;
        18) errMsg="SIM PUK2 required" ;;
        20) errMsg="memory full" ;;
        21) errMsg="invalid index" ;;
        22) errMsg="not found" ;;
        23) errMsg="memory failure" ;;
        24) errMsg="text string too long" ;;
        25) errMsg="invalid characters in text string" ;;
        26) errMsg="dial string too long" ;;
        27) errMsg="invalid characters in dial string" ;;
        30) errMsg="no network service" ;;
        31) errMsg="network timeout" ;;
        32) errMsg="network not allowed - emergency calls only" ;;
        40) errMsg="network personalization PIN required" ;;
        41) errMsg="network personalization PUK required" ;;
        42) errMsg="network subset personalization PIN required" ;;
        43) errMsg="network subset personalization PUK required" ;;
        44) errMsg="service provider personalization PIN required" ;;
        45) errMsg="service provider personalization PUK required" ;;
        46) errMsg="corporate personalization PIN required" ;;
        47) errMsg="corporate personalization PUK required" ;;
        48) errMsg="hidden key required" ;;
        49) errMsg="EAP method not supported" ;;
        50) errMsg="incorrect parameters" ;;
        55) errMsg="operation not allowed because of MT functionality restrictions" ;;
        100) errMsg="unknown" ;;
        103) errMsg="Illegal MS" ;;
        106) errMsg="Illegal ME" ;;
        107) errMsg="GPRS services not allowed" ;;
        111) errMsg="PLMN not allowed" ;;
        112) errMsg="Location area not allowed" ;;
        113) errMsg="roaming not allowed in this location area" ;;
        132) errMsg="service option not supported" ;;
        133) errMsg="requested service option not subscribed" ;;
        134) errMsg="service option temporarily out of order" ;;
        148) errMsg="unspecified GPRS error" ;;
        149) errMsg="PDP authentication failure" ;;
        150) errMsg="invalid mobile class" ;;
        151) errMsg="VBS/VGCS not supported by the network" ;;
        152) errMsg="no service subscription on SIM" ;;
        153) errMsg="no subscription for group ID" ;;
        154) errMsg="group ID not activated on SIM" ;;
        155) errMsg="no matching notification" ;;
        156) errMsg="VBS/VGCS call already present" ;;
        157) errMsg="congestion" ;;
        158) errMsg="network failure" ;;
        159) errMsg="uplink busy" ;;
        160) errMsg="no access rights for SIM file" ;;
        161) errMsg="no subscription for priority" ;;
        162) errMsg="operation not applicable or not possible" ;;
        163) errMsg="file not exist" ;;
        171) errMsg="service not provisioned" ;;
        181) errMsg="unsupported QCI value" ;;
        300) errMsg="PDP ACT LIMIT" ;;
        301) errMsg="network selection menu disable" ;;
        302) errMsg="CS service exist" ;;
        303) errMsg="FDN failed" ;;
        304) errMsg="call control failed" ;;
        305) errMsg="call control beyond capability" ;;
        306) errMsg="IMS not support" ;;
        307) errMsg="IMS service exist" ;;
        308) errMsg="IMS voice domain PS only" ;;
        309) errMsg="IMS stack time out" ;;
        310) errMsg="no RF" ;;
        311) errMsg="IMS open, LTE not support" ;;
        700) errMsg="APN length illegal" ;;
        701) errMsg="APN syntactical error" ;;
        702) errMsg="set APN before set auth" ;;
        703) errMsg="auth type illegal" ;;
        704) errMsg="user name too long" ;;
        705) errMsg="user password too long" ;;
        706) errMsg="access number too long" ;;
        707) errMsg="call cid in operation" ;;
        708) errMsg="bearer type not default" ;;
        709) errMsg="call cid invalid" ;;
        710) errMsg="call cid active" ;;
        711) errMsg="bearer type illegal" ;;
        712) errMsg="must exist default type cid" ;;
        713) errMsg="PDN type illegal" ;;
        714) errMsg="IPV4 address alloc type illegal" ;;
        715) errMsg="link cid invalid" ;;
        716) errMsg="no such element" ;;
        717) errMsg="missing resource" ;;
        750) errMsg="USB change to VCOM at diag connect" ;;
        751) errMsg="decrypt PIN fail" ;;
        752) errMsg="verify PIN fail" ;;
        753) errMsg="encrypt PIN fail" ;;
        754) errMsg="not find file" ;;
        755) errMsg="not find NV" ;;
        756) errMsg="modem id error" ;;
        757) errMsg="write NV timeout" ;;
        758) errMsg="NV not support" ;;
        759) errMsg="function disable" ;;
        760) errMsg="SCI error" ;;
        761) errMsg="EMAT open channel error" ;;
        762) errMsg="EMAT open channel cnf error" ;;
        763) errMsg="EMAT close channel error" ;;
        764) errMsg="EMAT close channel cnf error" ;;
        765) errMsg="EMAT get eid error" ;;
        766) errMsg="EMAT get eid data error" ;;
        767) errMsg="EMAT get pkid error" ;;
        768) errMsg="EMAT get pkid data error" ;;
        769) errMsg="EMAT clean profile error" ;;
        770) errMsg="EMAT clean profile data error" ;;
        771) errMsg="EMAT check profile error" ;;
        772) errMsg="EMAT check profile data error" ;;
        773) errMsg="EMAT TPDU cnf error" ;;
        774) errMsg="EMAT TPDU data store error" ;;
        775) errMsg="PIH switch drv error" ;;
        776) errMsg="PIH switch is not enable" ;;
        777) errMsg="PIH switch query error" ;;
        778) errMsg="CARRIER malloc fail" ;;
        779) errMsg="CARRIER read NV original data error" ;;
        780) errMsg="CARRIER file len error" ;;
        781) errMsg="CARRIER NV len error" ;;
        782) errMsg="CARRIER write NV free fail" ;;
        783) errMsg="CARRIER NV error" ;;
        784) errMsg="not found sync source temporarily" ;;
        785) errMsg="CARRIER HMAC verify fail" ;;
        786) errMsg="not in NR normal service" ;;
        787) errMsg="no need repeat again" ;;
        788) errMsg="only set MSD data not start ECALL" ;;
        789) errMsg="NR error" ;;
        65284) errMsg="SPN file content error" ;;
        65285) errMsg="read SPN file rejected" ;;
        65286) errMsg="SPN file not exist" ;;
        *)   errMsg="unknown CME error: $code" ;;
    esac

    _log "CME ERROR ${code}: ${errMsg}"
    # logger -t "NCM" "ifname:${ifname} CME ERROR ${code}: ${errMsg}"
}

# 将所有执行的AT指令保存到 /tmp/tracker-sim/<ifname>/at_log.jsonl
# 每条 AT 指令及其完整响应保存为一条 JSONL 记录，并带有单调递增 seq
# 采用双文件轮转，避免因 truncate 导致前端增量读取时丢失日志
function _next_at_log_seq()
{
    local log_dir="/tmp/tracker-sim/${ifname}"
    local seq_file="${log_dir}/at_log.seq"
    local seq=0

    [ -f "$seq_file" ] && seq=$(cat "$seq_file" 2>/dev/null)
    case "$seq" in
        ''|*[!0-9]*) seq=0 ;;
    esac

    seq=$((seq + 1))
    echo "$seq" > "$seq_file"
    echo "$seq"
}

function _rotate_at_log_if_needed()
{
    local log_dir="/tmp/tracker-sim/${ifname}"
    local log_file="${log_dir}/at_log.jsonl"
    local log_file_prev="${log_dir}/at_log.jsonl.1"
    local MAX_LOG_ENTRIES=300

    [ -f "$log_file" ] || return 0

    local entry_count=$(wc -l < "$log_file" 2>/dev/null)
    case "$entry_count" in
        ''|*[!0-9]*) entry_count=0 ;;
    esac

    if [ "$entry_count" -ge "$MAX_LOG_ENTRIES" ]; then
        rm -f "$log_file_prev"
        mv "$log_file" "$log_file_prev"
    fi
}

function at_log()
{
    local ttyUSB=$1
    local atcmd=$2
    local at_res=$3

    local log_dir="/tmp/tracker-sim/${ifname}"
    local log_file="${log_dir}/at_log.jsonl"
    local seq=""
    local ts=""
    local entry_json=""

    mkdir -p "$log_dir"
    _rotate_at_log_if_needed

    seq=$(_next_at_log_seq)
    ts=$(date '+%Y-%m-%d %H:%M:%S')
    entry_json=$(jq -cn \
        --arg seq "$seq" \
        --arg ts "$ts" \
        --arg tty "$ttyUSB" \
        --arg cmd "$atcmd" \
        --arg res "$at_res" \
        '{seq: ($seq | tonumber), ts: $ts, tty: $tty, cmd: $cmd, res: $res}')

    [ -n "$entry_json" ] && echo "$entry_json" >> "$log_file"
}

# 执行AT指令，结果存入_AT_RES全局变量，成功返回0，失败返回1
function _exec_at
{
    local ATCMD=$1
    local ttyUSB=$2

    _log "${ATCMD}"
    # logger -t "NCM" "ifname:${ifname} ${ATCMD} ${ttyUSB}"

    _AT_RES=$(sms_tool -D -d "$ttyUSB" at "$ATCMD" 2>/dev/null | tr -d '\r')

    at_log "${ttyUSB}" "${ATCMD}" "${_AT_RES}"

    if [ -z "$_AT_RES" ] || ! echo "$_AT_RES" | grep -q "OK"; then
        _log "failed to execute $1 by ${ttyUSB}! res=${_AT_RES}"
        # logger -t "NCM" "ifname:${ifname} failed to execute $1 by ${ttyUSB}! res=${_AT_RES}"
        CNE_ERROR_MSG "$_AT_RES"
        return 1
    fi

    return 0
}

# 打开回显
function atcmd_init_echo
{
    logger -t "NCM" "ifname:${ifname} atcmd_init_echo $1"

    local ATCMD="ATE1"
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 初始化网卡数量为1
function atcmd_init_netnum
{
    local ATCMD="AT^SETNETNUM?"

    _exec_at "$ATCMD" $1 || return 1

    local NETNUM=$(echo "$_AT_RES" | awk '/^[0-9]+$/{print $1}')
    [ "x${NETNUM}" == "x1" ] && return 0

    ATCMD="AT^SETNETNUM=1"
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 设置USB端口形态配置为Linux NCM模式
function atcmd_init_ncm
{
    local ATCMD="AT^SETMODE?"
    _exec_at "$ATCMD" $1 || return 1

    local MODE=$(echo "$_AT_RES" | awk '/^[0-9]+$/{print $1}')
    [ "x${MODE}" == "x4" ] && return 0

    ATCMD="AT^SETMODE=4"
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 开启SIM卡热插拔
function atcmd_init_hotplug
{
    local ATCMD="AT^TDSIMHP?"
    _exec_at "$ATCMD" $1 || return 1

    local HOTPLUG=$(echo "$_AT_RES" | awk '/\^TDSIMHP:/{print $2}')
    [ "x${HOTPLUG}" == "x1" ] && return 0

    ATCMD="AT^TDSIMHP=1"
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 当前时间戳
function atcmd_timestamp()
{
    TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")
    _save "timestamp" "${TIMESTAMP}"
}

# 获取运营商信息
function atcmd_get_plmn()
{
    # 查询运营商
    # AT^EONS=1
    # ^EONS: 1,46011,"4E2D56FD75354FE1","4E2D56FD75354FE1",1,"4E2D56FD75354FE1"
    # OK
    local ATCMD="AT^EONS=1"
    _exec_at "$ATCMD" $1 || return 1

    local eons_fields=""
    local mode=""
    local plmn=""
    local country=""
    local long_name_hex=""
    local short_name_hex=""
    local spn_flag=""
    local spn_name_hex=""
    local long_name=""
    local short_name=""
    local spn_name=""

    eons_fields=$(echo "$_AT_RES" | awk -F'[,:]+' '/\^EONS:/{
        mode=$2
        plmn=$3
        long_name=$4
        short_name=$5
        spn_flag=$6
        spn_name=$7

        gsub(/^[[:space:]]+|[[:space:]]+$/, "", mode)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", plmn)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", long_name)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", short_name)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", spn_flag)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", spn_name)
        gsub(/"/, "", long_name)
        gsub(/"/, "", short_name)
        gsub(/"/, "", spn_name)

        printf "%s\t%s\t%s\t%s\t%s\t%s", mode, plmn, long_name, short_name, spn_flag, spn_name
        exit
    }')

    [ -z "$eons_fields" ] && _log "failed to parse PLMN from AT^EONS=1" && return 1

    IFS='	' read -r mode plmn long_name_hex short_name_hex spn_flag spn_name_hex <<EOF
$eons_fields
EOF

    [ -z "$plmn" ] && _log "PLMN is empty" && return 1

    long_name="$long_name_hex"
    short_name="$short_name_hex"
    spn_name="$spn_name_hex"

    # UCS2 hex -> UTF-8 纯 shell 解码 (无 iconv/xxd 依赖)
    _ucs2be_hex_to_utf8() {
        local hex="$1"
        local i=0 codepoint

        while [ $i -lt ${#hex} ]; do
            # 读取 2 字节 (4 个 hex 字符) = 1 个 UCS-2 码点
            codepoint=$(( 0x${hex:i:4} ))
            i=$(( i + 4 ))

            if [ "$codepoint" -lt 128 ]; then
                # U+0000 - U+007F: 1 byte UTF-8
                printf "\\$(printf '%03o' "$codepoint")"
            elif [ "$codepoint" -lt 2048 ]; then
                # U+0080 - U+07FF: 2 byte UTF-8
                printf "\\$(printf '%03o' $(( 0xC0 | (codepoint >> 6) )))"
                printf "\\$(printf '%03o' $(( 0x80 | (codepoint & 0x3F) )))"
            else
                # U+0800 - U+FFFF: 3 byte UTF-8
                printf "\\$(printf '%03o' $(( 0xE0 | (codepoint >> 12) )))"
                printf "\\$(printf '%03o' $(( 0x80 | ((codepoint >> 6) & 0x3F) )))"
                printf "\\$(printf '%03o' $(( 0x80 | (codepoint & 0x3F) )))"
            fi
        done
    }

    echo "$long_name_hex" | grep -qE '^[0-9A-Fa-f]+$' && [ $(( ${#long_name_hex} % 4 )) -eq 0 ] && \
        long_name=$(_ucs2be_hex_to_utf8 "$long_name_hex")
    echo "$short_name_hex" | grep -qE '^[0-9A-Fa-f]+$' && [ $(( ${#short_name_hex} % 4 )) -eq 0 ] && \
        short_name=$(_ucs2be_hex_to_utf8 "$short_name_hex")
    echo "$spn_name_hex" | grep -qE '^[0-9A-Fa-f]+$' && [ $(( ${#spn_name_hex} % 4 )) -eq 0 ] && \
        spn_name=$(_ucs2be_hex_to_utf8 "$spn_name_hex")

    # 根据 PLMN 从 mccmnc.dat 查找国家名称
    local mccmnc_file="/usr/share/modemdata/libs/mccmnc.dat"
    if [ -f "$mccmnc_file" ]; then
        country=$(grep "^${plmn};" "$mccmnc_file" 2>/dev/null | head -1 | cut -d';' -f2)
    fi

    SIM_PLMN=$(printf '{"mode":"%s","plmn":"%s","country":"%s","long_name":"%s","long_name_hex":"%s","short_name":"%s","short_name_hex":"%s","spn_flag":"%s","spn_name":"%s","spn_name_hex":"%s"}' \
        "$mode" "$plmn" "$country" "$long_name" "$long_name_hex" "$short_name" "$short_name_hex" "$spn_flag" "$spn_name" "$spn_name_hex")

    # {
    #     "mode": "1",
    #     "plmn": "46001",
    #     "country": "China"
    #     "long_name": "中国联通",
    #     "long_name_hex": "4E2D56FD8054901A",
    #     "short_name": "中国联通",
    #     "short_name_hex": "4E2D56FD8054901A",
    #     "spn_flag": "",
    #     "spn_name": "",
    #     "spn_name_hex": ""
    # }


    _save "plmn" "${SIM_PLMN}"

    return 0
}

# 获取apn
function atcmd_get_apn
{
    local ATCMD="AT+CGDCONT?"
    _exec_at "${ATCMD}" $1 || return 1

    local PDP_JSON=$(echo "$_AT_RES" | awk -F',' '/\+CGDCONT:/{
        cid=$1
        sub(/.*CGDCONT: /, "", cid)
        
        pdp_type=$2
        gsub(/"/, "", pdp_type)
        
        apn=$3
        gsub(/"/, "", apn)
        
        pdp_addr=$4
        gsub(/"/, "", pdp_addr)
        
        if(cid==1) printf "{\"cid\":\"%s\",\"pdp_type\":\"%s\",\"apn\":\"%s\",\"pdp_addr\":\"%s\"}", cid,pdp_type,apn,pdp_addr
    }')

    DIAL_APN=$(jsonfilter -s "$PDP_JSON" -e '@.apn' 2>/dev/null)
    [ -z "$DIAL_APN" ] && return 1

    DIAL_APN=apn 
    return 0
}

# 设置apn
function atcmd_set_apn
{
    local ATCMD="AT+CGDCONT=1,\"IPV4V6\",\"$2\""
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 查询入网方式配置, 注意: 是配置, 不是实时状态
function atcmd_get_net
{
    # 首先查询是否为LTE入网
    local ATCMD="AT^SYSCFGEX?"
    _exec_at "$ATCMD" $1 || return 1

    local acqorder=$(echo "$_AT_RES" | awk -F'[,: ]+' '/SYSCFGEX/{printf "acqorder=%s",$2}')
    [ x"${acqorder}" = "x03" ] && DIAL_NET="LTE" && return 0

    # 查询5G入网方式
    ATCMD="AT^C5GOPTION?"
    _exec_at "$ATCMD" $1 || return 1

    eval $(echo "$_AT_RES" | awk -F'[,: ]+' '/C5GOPTION/{printf "nr_sa_support_flag=%s nr_dc_mode=%s gc_access_mode=%s",$2,$3,$4}')

    if [ x"${nr_sa_support_flag}" = "x1" ] && [ x"${nr_dc_mode}" = "x1" ] && [ x"${gc_access_mode}" = "x1" ]; then
        DIAL_NET="AUTO"
    elif [ x"${nr_sa_support_flag}" = "x1" ] && [ x"${nr_dc_mode}" = "x0" ] && [ x"${gc_access_mode}" = "x1" ]; then
        DIAL_NET="SA"
    elif [ x"${nr_sa_support_flag}" = "x0" ] && [ x"${nr_dc_mode}" = "x1" ] && [ x"${gc_access_mode}" = "x0" ]; then
        DIAL_NET="NSA"
    else
        DIAL_NET=""
    fi
}

# 设置入网方式
function atcmd_set_net
{
    NET_SETTING=$(echo "$2" | tr 'a-z' 'A-Z')

    # 避免重复设置
    atcmd_get_net $1 && [ "${DIAL_NET}" == "${NET_SETTING}" ] && return 0

    local ATCMD_1=""
    local ATCMD_2=""
    [ "LTE" == "${NET_SETTING}" ] && {
        ATCMD_1="AT^SYSCFGEX=\"03\",3FFFFFFF,1,2,7FFFFFFFFFFFFFFF,,"
    }

    [ "SA" == "${NET_SETTING}" ] && {
        ATCMD_1="AT^SYSCFGEX=\"08\",3FFFFFFF,1,2,7FFFFFFFFFFFFFFF,,"
        ATCMD_2="AT^C5GOPTION=1,0,1"
    }

    [ "NSA" == "${NET_SETTING}" ] && { 
        ATCMD_1="AT^SYSCFGEX=\"0803\",3FFFFFFF,1,2,7FFFFFFFFFFFFFFF,,"
        ATCMD_2="AT^C5GOPTION=0,1,0"
    }

    [ "AUTO" == "${NET_SETTING}" ] && {
        ATCMD_1="AT^SYSCFGEX=\"0803\",3FFFFFFF,1,2,7FFFFFFFFFFFFFFF,,"
        ATCMD_2="AT^C5GOPTION=1,1,1"
    }
    
    _exec_at "$ATCMD_1" $1 || return 1
    
    [ ! -z "${ATCMD_2}" ] && { _exec_at "$ATCMD_2" $1 || return 1; }

    return 0
}

# 获取鉴权
function atcmd_get_auth
{
    local ATCMD="AT^AUTHDATA?"
    _exec_at "$ATCMD" $1 || return 1

    local AUTH_JSON=$(echo "$_AT_RES" | awk -F'[,"]+' '/\^AUTHDATA:/{cid=substr($1,index($1," ")+1); if(cid==1) printf "{\"cid\":\"%s\",\"auth_type\":\"%s\",\"passwd\":\"%s\",\"username\":\"%s\",\"plmn\":\"%s\"}", cid,$2,$3,$4,$5}')

    DIAL_AUTH_TYPE=""
    DIAL_AUTH_PASSWD=""
    DIAL_AUTH_USER=""

    local auth_type=$(jsonfilter -s "$AUTH_JSON" -e '@.auth_type' 2>/dev/null)
    local passwd=$(jsonfilter -s "$AUTH_JSON" -e '@.passwd' 2>/dev/null)
    local username=$(jsonfilter -s "$AUTH_JSON" -e '@.username' 2>/dev/null)

    # 鉴权类型: 
    ## 0 - 不使用握手协议
    ## 1 - PAP
    ## 2 - CHAP
    [ -n "${auth_type}" ] && {
        [ "0" = "$auth_type" ] && DIAL_AUTH_TYPE="NONE"
        [ "1" = "$auth_type" ] && DIAL_AUTH_TYPE="PAP"
        [ "2" = "$auth_type" ] && DIAL_AUTH_TYPE="CHAP"
    }

    [ -n "${passwd}" ] && DIAL_AUTH_PASSWD="${passwd}"
    [ -n "${username}" ] && DIAL_AUTH_USER="${username}"

    return 0
}

# 设置鉴权
function atcmd_set_auth
{
    local AUTH_TYPE=$(echo "$2" | tr 'a-z' 'A-Z')
    local AUTH_USER=""
    local AUTH_PASSWD=""
    [ -n "$2" ] && AUTH_USER=$(echo "$3" | tr 'a-z' 'A-Z')
    [ -n "$3" ] && AUTH_PASSWD=$(echo "$4" | tr 'a-z' 'A-Z')

    [ -z "${AUTH_TYPE}" ] && { _log "auth type required!"; return 1; }

    local ATCMD=""

    # 不需鉴权
    [ "NONE" == "${AUTH_TYPE}" ] && {
        ATCMD="AT^AUTHDATA=1,0,"
        _exec_at "$ATCMD" $1 || return 1
        return 0
    }

    # 需要鉴权
    [ -z "${AUTH_USER}" ] && { _log "auth user required!"; return 1; }
    [ -z "${AUTH_PASSWD}" ] && { _log "auth password required!"; return 1; }

    # PAP鉴权
    [ "PAP" == "${AUTH_TYPE}" ] && {
        ATCMD="AT^AUTHDATA=1,1,\"\",\"$AUTH_USER\",\"$AUTH_PASSWD\""
    }

    # CHAP鉴权
    [ "CHAP" == "${AUTH_TYPE}" ] && {
        ATCMD="AT^AUTHDATA=1,2,\"\",\"${AUTH_USER}\",\"${AUTH_PASSWD}\""
    }

    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 获取模组序列号
function atcmd_get_modem_sn()
{
    local ATCMD="AT+CGSN"
    _exec_at "$ATCMD" $1 || return 1

    # AT+CGSN
    # 864640060193826
    # OK

    MODEM_SN=$(echo "$_AT_RES" | awk '/^[0-9]+$/{print $1; exit}')
    [ -n "${MODEM_SN}" ] && _save "sn" "${MODEM_SN}"
}

# 获取模组的厂商/型号/版本/IMEI
function atcmd_get_modem_model()
{
    local ATCMD="ATI"
    _exec_at "${ATCMD}" $1 || return 1

    # ATI返回值格式:
    # Manufacturer: TD-Tech Ltd.
    # Model: MT5700M-CN
    # Revision: V100R001C00B050
    # IMEI: 356112010004540
    # +GCAP: +CGSM,+DS,+ES
    # OK

    MODEM_MANUFACTURE=$(echo "$_AT_RES" | sed -n 's/^Manufacturer: *//p')
    MODEM_MODEL=$(echo "$_AT_RES" | sed -n 's/^Model: *//p')
    MODEM_REVISION=$(echo "$_AT_RES" | sed -n 's/^Revision: *//p')
    MODEM_IMEI=$(echo "$_AT_RES" | sed -n 's/^IMEI: *//p')

    [ -z "$MODEM_MANUFACTURE" ] && return 1
    [ -z "$MODEM_MODEL" ] && return 1
    [ -z "$MODEM_REVISION" ] && return 1
    [ -z "$MODEM_IMEI" ] && return 1

    _save "manufacture" "${MODEM_MANUFACTURE}"
    _save "model" "${MODEM_MODEL}"
    _save "revision" "${MODEM_REVISION}"
    _save "imei" "${MODEM_IMEI}"

    return 0
}

# 获取SIM卡的ICCID
function atcmd_get_iccid()
{
    local ATCMD="AT^ICCID?"
    _exec_at "$ATCMD" $1 || return 1

    # 有sim卡时的返回值
    # ^ICCID: 89860125801058759095
    # OK
    # 无sim卡时的返回值
    # +CME ERROR: 4

    SIM_ICCID=$(echo "$_AT_RES" | sed -n 's/.*\^ICCID: *//p')
    [ -z "$SIM_ICCID" ] && _log "failed to parse ICCID" && return 1
    _log "ICCID: ${SIM_ICCID}"
    _save "iccid" "${SIM_ICCID}"
    # logger -t "NCM" "ifname:${ifname} ${SIM_ICCID}"

    return 0
}

# 获取SIM卡的IMSI
function atcmd_get_imsi()
{
    local ATCMD="AT+CIMI"
    _exec_at "$ATCMD" $1 || return 1

    # 有sim卡时的返回值
    # 230020216666831
    # OK

    SIM_IMSI=$(echo "$_AT_RES" | sed -n '/^[0-9]\{14,15\}$/p')
    [ -z "$SIM_IMSI" ] && _log "failed to parse IMSI" && return 1
    _log "IMSI: ${SIM_IMSI}"
    _save "imsi" "${SIM_IMSI}"
    # logger -t "NCM" "ifname:${ifname} IMSI: ${SIM_IMSI}"

    return 0
}

# 查询5G 锁频/锁小区配置
function atcmd_get_nr_lock()
{
    local ATCMD="AT^NRFREQLOCK?"
    _exec_at "$ATCMD" $1 || return 1
    _log $_AT_RES

    # 返回格式 (多行):
    # ^NRFREQLOCK: <operatetype>
    # [<forbidFlag>,<num>]
    # [<band>,<arfcn>,<scstype>,<pci>]
    # ...重复num行...
    # OK

    local operatetype="" forbidFlag="" num=""
    local band="" arfcn="" scstype="" pci=""

    # 用 awk 逐行解析，每行按逗号分隔
    eval $(echo "$_AT_RES" | tr -d '"' | awk -F',' '
        BEGIN { op=""; forbid=""; n=0; pc=0; split("", bands); split("", arfcns); split("", scs); split("", pcis) }
        /^\^NRFREQLOCK:/ {
            split($1, a, /[: ]+/)
            op = a[2]
            next
        }
        /^OK/ { next }
        /^$/ { next }
        /^AT/ { next }
        {
            # 如果 forbid/n 还未解析且 NF==2，则是 forbid,num 行
            if (forbid == "" && NF == 2) {
                forbid = $1; n = $2
                next
            }
            # 否则是数据行: band,arfcn,scstype,pci
            pc++
            bands[pc] = $1
            arfcns[pc] = $2
            if (NF >= 3) scs[pc] = $3
            if (NF >= 4) pcis[pc] = $4
        }
        END {
            printf "operatetype=%s forbidFlag=%s num=%s", (op==""?"0":op), (forbid==""?"0":forbid), (n==""?"0":n)
            for (i=1; i<=pc; i++) {
                sep = (i==1 ? " " : ",")
                printf " band=\"%s%s\" arfcn=\"%s%s\" scstype=\"%s%s\" pci=\"%s%s\"",
                    (i>1?",":""), bands[i],
                    (i>1?",":""), arfcns[i],
                    (i>1?",":""), scs[i],
                    (i>1?",":""), pcis[i]
            }
        }
    ')

    # 封装成 JSON
    local BAND_JSON=$(echo "$band" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}; printf "]"}')    
    local ARFCN_JSON=$(echo "$arfcn" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}; printf "]"}')    
    local SCSTYPE_JSON=$(echo "$scstype" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}; printf "]"}')    
    local PCI_JSON=$(echo "$pci" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}; printf "]"}')    
    NR_FREQLOCK_JSON=$(printf '{"operatetype":"%s","forbid_flag":"%s","num":"%s","band":%s,"arfcn":%s,"scstype":%s,"pci":%s}' \
        "${operatetype}" "${forbidFlag}" "${num}" \
        "${BAND_JSON:-[]}" "${ARFCN_JSON:-[]}" "${SCSTYPE_JSON:-[]}" "${PCI_JSON:-[]}")

    _save "nrlock_setting" "${NR_FREQLOCK_JSON}"
}

# 解锁5G 频段/PCI小区
function atcmd_nr_unlock()
{
    local ATCMD="AT^NRFREQLOCK=0"
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 5G锁频点, 必须同时锁频段 不锁PCI小区
function atcmd_nr_arfcn_lock()
{
    local band=$2
    local freq=$3
    local scs=$4

    [ -z "${band}" ] && { _log "band required!" && return 1; }
    [ -z "${freq}" ] && { _log "arfcn required!" && return 1; }
    [ -z "${scs}" ] && { _log "scs required!" && return 1; }

    local ATCMD="AT^NRFREQLOCK=1,0,1,\"${band}\",\"${freq}\",\"${scs}\""
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 5G 锁PCI 必须同时锁频段和频点 
function atcmd_nr_pci_lock()
{
    local forbidFlag=$2     # 0:允许切换与重选 1:不允许
    local band=$3
    local freq=$4
    local scs=$5
    local pcid=$6

    _log "nr_pci_lock forbid:${forbidFlag} band:${band} freq:${freq} scs:${scs} pcid:${pcid}"

    [ -z "${forbidFlag}" ] && { _log "forbidFlag required!" && return 1; }
    [ -z "${band}" ] && { _log "band required!" && return 1; }
    [ -z "${freq}" ] && { _log "arfcn required!" && return 1; }
    [ -z "${scs}" ] && { _log "scs required!" && return 1; }
    [ -z "${pcid}" ] && { _log "pcid required!" && return 1; }

    local band_count=$(echo "$band" | wc -w)
    local freq_count=$(echo "$freq" | wc -w)
    local scs_count=$(echo "$scs" | wc -w)
    local pcid_count=$(echo "$pcid" | wc -w)

    # 如果 band_count freq_count scs_count pcid_count 不相等, 报错并退出
    if [ "$band_count" != "$freq_count" ] || [ "$band_count" != "$scs_count" ] || [ "$band_count" != "$pcid_count" ]; then
        _log "param count mismatch! band:${band_count} freq:${freq_count} scs:${scs_count} pcid:${pcid_count}"
        return 1
    fi

    local ATCMD="AT^NRFREQLOCK=2,${forbidFlag},${band_count},\"${band// /,}\",\"${freq// /,}\",\"${scs// /,}\",\"${pcid// /,}\""
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 锁5G频段 不锁频点 不锁PCI小区
function atcmd_nr_band_lock()
{
    local band=$2
    [ -z "${band}" ] && { _log "band required!" && return 1; }

    local ATCMD="AT^NRFREQLOCK=3,0,1,\"${band}\""
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 锁5G频段/PCI小区
function atcmd_set_nr_lock()
{
    local nr_operatetype=$2
    local forbidFlag=$3
    local nr_pcid=$4
    local nr_band=$5
    local nr_freq=$6
    local nr_scs=$7

    # 将所有参数都输出到日志
    _log "nr_lock op:${nr_operatetype} forbid:${forbidFlag} pcid:${nr_pcid} band:${nr_band} freq:${nr_freq} scs:${nr_scs}"
    [ -z "${nr_operatetype}" ] && { _log "operatetype required!" && return -1; }

    case "$nr_operatetype" in
        0) 
            atcmd_nr_unlock $1
            ;;
        1) 
            atcmd_nr_arfcn_lock $1 "${nr_band}" "${nr_freq}" "${nr_scs}"
            ;;
        2)
            atcmd_nr_pci_lock $1 "${forbidFlag}" "${nr_band}" "${nr_freq}" "${nr_scs}" "${nr_pcid}"
            ;;  
        3)  
            atcmd_nr_band_lock $1 "${nr_band}"
            ;;
    esac

}

#  关闭4G 锁频 锁小区功能
function atcmd_lte_unlock()
{
    local ATCMD="AT^LTEFREQLOCK=0"
    _exec_at "$ATCMD" $1 || return 1
    
    return 0
} 

# 4G 锁频点
function atcmd_lte_arfcn_lock()
{
    local band=$2
    local freq=$3

    [ -z "${band}" ] && { _log "band required!" && return -1; }
    [ -z "${freq}" ] && { _log "freq required!" && return -1; }

    local ATCMD="AT^LTEFREQLOCK=1,0,1,\"${band}\",\"${freq}\""
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 4G 锁小区
function atcmd_lte_pci_lock()
{
    local band=$2
    local freq=$3
    local pcid=$4

    [ -z "${band}" ] && { _log "band required!" && return -1; }
    [ -z "${freq}" ] && { _log "freq required!" && return -1; }
    [ -z "${pcid}" ] && { _log "pcid required!" && return -1; }

    local ATCMD="AT^LTEFREQLOCK=2,0,1,\"${band}\",\"${freq}\",\"${pcid}\""
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 4G 锁band 不锁频点 不锁PCI小区
function atcmd_lte_band_lock()
{
    local band=$2
    [ -z "${band}" ] && { _log "band required!" && return -1; }

    local ATCMD="AT^LTEFREQLOCK=3,0,1,\"${band}\""
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 查询LTE 锁频 锁小区设置
function atcmd_get_lte_lock()
{
    local ATCMD="AT^LTEFREQLOCK?"
    _exec_at "$ATCMD" $1 || return 1
    _log $_AT_RES

    # 返回格式 (多行, 同 NR):
    # ^LTEFREQLOCK: <operatetype>
    # [<forbidFlag>,<num>]
    # [<band>,<arfcn>[,<pci>]]
    # ...重复num行...
    # OK

    local operatetype="" forbidFlag="" num=""
    local band="" arfcn="" pci=""

    eval $(echo "$_AT_RES" | tr -d '"' | awk -F',' '
        BEGIN { op=""; forbid=""; n=0; pc=0; split("", bands); split("", arfcns); split("", pcis) }
        /^\^LTEFREQLOCK:/ {
            split($1, a, /[: ]+/)
            op = a[2]
            next
        }
        /^OK/ { next }
        /^$/ { next }
        /^AT/ { next }
        {
            if (forbid == "" && NF == 2) {
                forbid = $1; n = $2
                next
            }
            pc++
            bands[pc] = $1
            arfcns[pc] = $2
            if (NF >= 3) pcis[pc] = $3
        }
        END {
            printf "operatetype=%s forbidFlag=%s num=%s", (op==""?"0":op), (forbid==""?"0":forbid), (n==""?"0":n)
            for (i=1; i<=pc; i++) {
                printf " band=\"%s%s\" arfcn=\"%s%s\" pci=\"%s%s\"",
                    (i>1?",":""), bands[i],
                    (i>1?",":""), arfcns[i],
                    (i>1?",":""), pcis[i]
            }
        }
    ')

    # 封装成 JSON
    local BAND_JSON=$(echo "$band" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}; printf "]"}')    
    local ARFCN_JSON=$(echo "$arfcn" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}; printf "]"}')
    local PCI_JSON=$(echo "$pci" | awk -F',' '{printf "["; for(i=1;i<=NF;i++){printf "%s\"%s\"",(i>1?",":""),$i}; printf "]"}')    
    LTE_FREQLOCK_JSON=$(printf '{"operatetype":"%s","forbid_flag":"%s","num":"%s","band":%s,"arfcn":%s,"pci":%s}' \
        "${operatetype}" "${forbidFlag}" "${num}" \
        "${BAND_JSON:-[]}" "${ARFCN_JSON:-[]}" "${PCI_JSON:-[]}")

    _save "ltelock_setting" "${LTE_FREQLOCK_JSON}"
}

# 锁LTE频段/PCI小区
function atcmd_set_lte_lock()
{
    local lte_operatetype=$2
    local pcid=$3
    local band=$4
    local freq=$5

    [ -z "${lte_operatetype}" ] && { _log "operatetype required!" && return 1; }

    case "$lte_operatetype" in
        0) 
            atcmd_lte_unlock $1
            ;;
        1) 
            atcmd_lte_arfcn_lock $1 "${band}" "${freq}"
            ;;
        2)
            atcmd_lte_pci_lock $1 "${band}" "${freq}" "${pcid}"
            ;;  
        3)
            atcmd_lte_band_lock $1 "${band}"
            ;;
    esac

    return 0
}

# 飞行模式开
function atcmd_set_airplane_on()
{
    local ATCMD="AT+CFUN=0"
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 飞行模式关
function atcmd_set_airplane_off()
{
    local ATCMD="AT+CFUN=1"
    _exec_at "$ATCMD" $1 || return 1

    return 0
}

# 拨号
function atcmd_connect()
{
    local ATCMD="AT^NDISDUP=1,1"
    _exec_at "$ATCMD" $1 || return 1
    
    return 0
}

# 断开连接
function atcmd_disconnect()
{
    local ATCMD="AT^NDISDUP=1,0"
    _exec_at "$ATCMD" $1 || return 1
    logger -t "NCM" "ifname:${ifname} ${ATCMD}"

    return 0
}

# SIM卡状态
function atcmd_get_sim_status_realtime()
{
    # <CR><LF>^SIMSQ: <mode>,<sim_status><CR><LF>
    # mode:0-关闭SIM卡状态主动上报; 1-使能SIM卡状态主动上报
    # 0: 卡不在位 SIM not Inserted
    # 1: 卡已插入 SIM Inserted
    # 2: 卡被锁 SIM PIN/PUK locked
    # 3: SIMLOCK 锁定(暂不支持上报)
    # 10: 卡文件正在初始化 SIM Initializing
    # 11: 卡初始化完成 （可接入网络）SIM Initialized (Network service available)
    # 12: 卡初始化完成 （短信和电话本可以接入）SIM Ready (PBM and SMS access)
    # 98: 卡物理失效 （PUK锁死或者卡物理    失效）
    # 99: 卡移除 SIM removed
    # 100: 卡错误（初始化过程中，卡失败）

    local ATCMD="AT^SIMSQ?"
    _exec_at "$ATCMD" $1 || return 1

    CPIN_TEXT=$(echo "$_AT_RES" | awk -F'[,:]+' '/\^SIMSQ:/{
        mode=$2
        sim_status=$3
        
        # 转换 sim_status 为可读文本
        if(sim_status=="0") status_text="SIM not Inserted"
        else if(sim_status=="1") status_text="SIM Inserted"
        else if(sim_status=="2") status_text="SIM PIN/PUK locked"
        else if(sim_status=="3") status_text="SIMLOCK"
        else if(sim_status=="10") status_text="SIM Initializing"
        else if(sim_status=="11") status_text="SIM Initialized (Network service available)"
        else if(sim_status=="12") status_text="SIM Ready (PBM and SMS access)"
        else if(sim_status=="98") status_text="卡物理失效(PUK锁死或者卡物理失效)"
        else if(sim_status=="99") status_text="SIM removed"
        else if(sim_status=="100") status_text="卡错误(初始化过程中，卡失败)"
        else status_text=sim_status
        
        printf "%s", status_text
    }')

    SIM_STATUS="$CPIN_TEXT"
    _save "sim_status" "${SIM_STATUS}"
    # logger -t "NCM" "ifname:${ifname} ${SIM_STATUS}"
}

# 5G Core注册状态, 即终端在 5G 核心网 的注册状态
function atcmd_get_sim_5GCore_realtime()
{
    # +C5GREG: <n>,<stat>[,[<tac>],[<ci>],[<AcT>],...]
    # n: 0：禁止+C5GREG的主动上报; 1：使能+C5GREG: <stat>的主动上报; 2: 更详细的上报信息
    # stat: 0-未注册 1-已注册本地网 2-未注册但正在搜索 3-注册被拒绝 5-已注册漫游网 8：只允许紧急呼救
    # tac: 位置区码 (16 进制)
    # ci: 小区 ID(16 进制)
    # AcT: 接入技术 10：EUTRAN-5GC 11：NR-5GC

    local ATCMD="AT+C5GREG?"
    _exec_at "$ATCMD" $1 || return 1

    C5GREG_JSON=$(echo "$_AT_RES" | awk -F'[,: ]+' '/\+C5GREG:/{
        n=$2
        stat=$3
        tac=$4
        ci=$5
        act=$6
        
        # 转换 stat 为可读文本
        if(stat=="0") stat_text="未注册"
        else if(stat=="1") stat_text="已注册本地网"
        else if(stat=="2") stat_text="未注册但正在搜索"
        else if(stat=="3") stat_text="注册被拒绝"
        else if(stat=="5") stat_text="已注册漫游网"
        else if(stat=="8") stat_text="只允许紧急呼救"
        else stat_text=stat
        
        # 转换 act 为可读文本
        if(act=="10") act_text="EUTRAN-5GC"
        else if(act=="11") act_text="NR-5GC"
        else act_text=act

        # 去除多余双引号
        gsub(/"/, "", ci)
        gsub(/"/, "", tac)
        
        printf "{\"n\":\"%s\",\"stat\":\"%s\",\"tac\":\"%s\",\"ci\":\"%s\",\"act\":\"%s\"}", n,stat_text,tac,ci,act_text
    }')

    local ts=$(date "+%Y-%m-%d %H:%M:%S")

    # root@MP-Router:/tmp/tracker-sim/sim1# cat C5GREG 
    # {
    # "timestamp": "08:49:03",                # 更新时间戳
    # "n": "2",                               # 主动上报状态, 0-禁止主动上报; 1 - 使能主动上报; 2-使能部分信息的主动上报
    # "stat": "已注册本地网",                   # 附网状态
    # "tac": "59090A",                        # 位置码信息  
    # "ci": "0000000592E60002",               # 小区信息
    # "act": "NR-5GC"                         # 网络接入技术: EUTRAN-5GC / NR-5GC
    # }

    C5GREG_JSON=$(echo "$C5GREG_JSON" | sed "s/^{/{\"timestamp\":\"${ts}\",/")
    SIM_C5GREG="$C5GREG_JSON"
    _save "C5GREG" "${SIM_C5GREG}"
}

# EPS域注册状态,即LTE注册状态
function atcmd_get_sim_EREG_realtime()
{
    # <CR><LF>+CEREG: <n>,<stat>[,<lac>,<ci>[,<AcT>]]<CR><LF>
    # n: 0-关闭主动上报 1-开启stat主动上报 2-上报完整信息
    # stat: 0-未注册 1-已注册本地网 2-未注册但正在搜索 3-注册被拒绝 4-未知原因 5-已注册漫游网
    # lac: 位置码信息，四个字符，16进制表示。（例：“00C3”＝10进制的195）
    # ci: 小区信息，八个字符，16进制表示
    # AcT: 整型值，当前网络的接入技术 0-GSM 1-GSM Compact 2-UTRAN 3-GSM w/EGPRS 4-UTRAN w/HSDPA 5-UTRAN w/HSUPA 6-UTRAN w/HSDPA 和HSUPA 7-E-UTRAN 10-EUTRAN-5GC 11-NR-5GC

    local ATCMD="AT+CEREG?"
    _exec_at "$ATCMD" $1 || return 1

    CEREG_JSON=$(echo "$_AT_RES" | awk -F'[,: ]+' '/\+CEREG:/{
        n=$2
        stat=$3
        lac=$4
        ci=$5
        act=$6
        
        # 转换 stat 为可读文本
        if(stat=="0") stat_text="未注册"
        else if(stat=="1") stat_text="已注册本地网"
        else if(stat=="2") stat_text="未注册但正在搜索"
        else if(stat=="3") stat_text="注册被拒绝"
        else if(stat=="4") stat_text="未知原因"
        else if(stat=="5") stat_text="已注册漫游网"
        else stat_text=stat
        
        # 转换 act 为可读文本
        if(act=="0") act_text="GSM"
        else if(act=="1") act_text="GSM Compact"
        else if(act=="2") act_text="UTRAN"
        else if(act=="3") act_text="GSM w/EGPRS"
        else if(act=="4") act_text="UTRAN w/HSDPA"
        else if(act=="5") act_text="UTRAN w/HSUPA"
        else if(act=="6") act_text="UTRAN w/HSDPA 和HSUPA"
        else if(act=="7") act_text="E-UTRAN"
        else if(act=="10") act_text="EUTRAN-5GC"
        else if(act=="11") act_text="NR-5GC"
        else act_text=act
        
        if (ci=="") ci_json="\"\""
        else ci_json=ci

        if (lac=="") lac_json="\"\""
        else lac_json=lac

        printf "{\"n\":\"%s\",\"stat\":\"%s\",\"lac\":%s,\"ci\":%s,\"act\":\"%s\"}", n,stat_text,lac_json,ci_json,act_text
    }')

    SIM_CREG="$CEREG_JSON"
    local ts=$(date "+%Y-%m-%d %H:%M:%S")
    CEREG_JSON=$(echo "$CEREG_JSON" | sed "s/^{/{\"timestamp\":\"${ts}\",/")
    SIM_CREG="$CEREG_JSON"
    _save "CLTEREG" "${SIM_CREG}"
}

# LTE/NR工作频率查询,当前小区的频率信息
function atcmd_get_sim_freq_realtime()
{
    # AT^HFREQINFO?
    # <CR><LF>^HFREQINFO:<n>,<sysmode>,
    # <band_class1>,<dl_fcn1>,<dl_freq1><dl_bw1>,<ul_fcn1>,<ul_freq1>,<ul_bw1>,
    # [<band_class2>,<dl_fcn2>,<dl_freq2><dl_bw2>,<ul_fcn2>,<ul_freq2>,<ul_bw2>,
    # [<band_class3>,<dl_fcn3>,<dl_freq3><dl_bw3>,<ul_fcn3>,<ul_freq3>,<ul_bw3>,
    # [<band_class4>,<dl_fcn4>,<dl_freq4><dl_bw4>,<ul_fcn4>,<ul_freq4>,<ul_bw4>]]
    # ]<CR><LF>
    # <CR><LF>OK<CR><LF>

    local ATCMD="AT^HFREQINFO?"
    _exec_at "$ATCMD" $1 || return 1

    HFREQINFO_JSON=$(echo "$_AT_RES" | awk '
        /\^HFREQINFO:/ {
            line=$0
            sub(/.*\^HFREQINFO:[ ]*/, "", line)
            gsub(/,/, " ", line)
            gsub(/[[:space:]]+/, " ", line)
            n=split(line, a, " ")
            if (n < 2) next

            i=1
            nval=a[i++]
            sysmode=a[i++]

            bands=""
            first=1
            while (i + 6 <= n) {
                band_class=a[i++]
                dl_fcn=a[i++]
                dl_freq=a[i++]
                dl_bw=a[i++]
                ul_fcn=a[i++]
                ul_freq=a[i++]
                ul_bw=a[i++]

                if (band_class == "") break
                if (!first) bands=bands ","
                bands=bands sprintf("{\"band_class\":\"%s\",\"dl_fcn\":\"%s\",\"dl_freq\":\"%s\",\"dl_bw\":\"%s\",\"ul_fcn\":\"%s\",\"ul_freq\":\"%s\",\"ul_bw\":\"%s\"}", band_class, dl_fcn, dl_freq, dl_bw, ul_fcn, ul_freq, ul_bw)
                first=0
            }

            printf "{\"n\":\"%s\",\"sysmode\":\"%s\",\"bands\":[%s]}", nval, sysmode, bands
            exit
        }')

    SIM_FREQ="$HFREQINFO_JSON"
    local ts=$(date "+%Y-%m-%d %H:%M:%S")
    HFREQINFO_JSON=$(echo "$HFREQINFO_JSON" | sed "s/^{/{\"timestamp\":\"${ts}\",/")
    SIM_FREQ="$HFREQINFO_JSON"
    _save "freq" "${SIM_FREQ}"
}

# 当前驻留小区信息
function atcmd_get_sim_monsc_realtime()
{
    # 基础信息
    local RAT="" 
    local MCC="" 
    local MNC=""
    # NR特有信息
    local NR_CELL_ID=""
    local NR_ARFCN=""
    local NR_SCS=""
    local NR_PCI=""
    local NR_TAC=""
    local NR_RSRP=""
    local NR_RSRQ=""
    local NR_SINR=""
    # LTE特有信息
    local LTE_CELL_ID=""
    local LTE_ARFCN=""
    local LTE_PCI=""
    local LTE_TAC=""
    local LTE_RSRP=""
    local LTE_RSRQ=""
    local LTE_RSSI=""
    # WCDMA特有信息
    local WCDMA_ARFCN=""
    local WCDMA_PCS=""
    local WCDMA_CELL_ID=""
    local WCDMA_LAC=""
    local WCDMA_RSCP=""
    local WCDMA_RXLEV=""
    local WCDMA_ECNO=""
    local WCDMA_DRX=""
    local WCDMA_URA=""
    # 查询当前驻留小区的参数值 AT^MONSC
    local NSA=""

    local ATCMD="AT^MONSC"
    _exec_at "$ATCMD" $1 || return 1

    # NSA时会同时返回NR和LTE的驻网信息, 需特殊处理
    echo "$_AT_RES" | grep -q '^MONSC:.*NR' && echo "$_AT_RES" | grep -q '^MONSC:.*LTE' && NSA="yes"
    if [ x"${NSA}" == x"yes" ]; then
        RAT="NSA"
    else
        RAT=$(echo "$_AT_RES" | awk -F'[ ,]' '/\^MONSC:/{print $2}')
    fi

    # 不同网络制式, 返回的数据格式不同
    case "$RAT" in
        "NR")
            # ^MONSC: <RAT>,<MCC>,<MNC>,<ARFCN-NR>,<SCS>,<Cell_ID>,<PCI>,<TAC>,<RSRP>,<RSRQ>,<SINR> OK
            eval $(echo "$_AT_RES" | awk -F'[,: ]+' '/MONSC/{printf "RAT=%s MCC=%s MNC=%s NR_ARFCN=%s NR_SCS=%s NR_CELL_ID=%s NR_PCI=%s NR_TAC=%s NR_RSRP=%s NR_RSRQ=%s NR_SINR=%s",$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}')
            RAT="NR/SA"
            ;;
        "LTE")
            # ^MONSC: <RAT>,<MCC>,<MNC>,<ARFCN>,<Cell_ID>,<PCI>,<TAC>,<RSRP>,<RSRQ>,<RSSI>
            # ^MONSC: LTE,460,11,1750,B26F9B2,DF,5D63,-91,-14,-56 OK
            eval $(echo "$_AT_RES" | awk -F'[,: ]+' '/MONSC/{printf "RAT=%s MCC=%s MNC=%s LTE_ARFCN=%s LTE_CELL_ID=%s LTE_PCI=%s LTE_TAC=%s LTE_RSRP=%s LTE_RSRQ=%s LTE_RSSI=%s",$2,$3,$4,$5,$6,$7,$8,$9,$10,$11}')
            RAT="LTE"
            # echo "RAT=${RAT} MCC=${MCC} MNC=${MNC} LTE_ARFCN=${LTE_ARFCN} LTE_CELL_ID=${LTE_CELL_ID} LTE_PCI=${LTE_PCI} LTE_TAC=${LTE_TAC} LTE_RSRP=${LTE_RSRP} LTE_RSRQ=${LTE_RSRQ} LTE_RSSI=${LTE_RSSI}"
            ;;
        "WCDMA")
            # ^MONSC: <RAT>,<MCC>,<MNC>,<ARFCN>,<PSC>,<Cell_ID>,<LAC>,<RSCP>,<RXLEV>,<EC/N0>,<DRX>,<URA>
            eval $(echo "$_AT_RES" | awk -F'[,: ]+' '/MONSC/{printf "RAT=%s MCC=%s MNC=%s WCDMA_ARFCN=%s WCDMA_PCS=%s WCDMA_CELL_ID=%s LAC=%s RSCP=%s RXLEV=%s ECNO=%s DRX=%s URA=%s",$2,$3,$4,$5,$6,$7,$8,$9,$10,$11,$12,$13}')
            RAT="WCDMA"
            ;;
        "NSA")
            # ^MONSC: NR,<MCC>,<MNC>,<ARFCN-NR>,<SCS>,<Cell_ID>,<PCI>,<TAC>,<RSRP>,<RSRQ>,<SINR>
            # ^MONSC: LTE,<MCC>,<MNC>,<ARFCN>,<Cell_ID>,<PCI>,<TAC>,<RSRP>,<RSRQ>,<RSSI>
            NR_LINE=$(echo "$_AT_RES" | awk '/\^MONSC:.*NR/{print; exit}')
            LTE_LINE=$(echo "$_AT_RES" | awk '/\^MONSC:.*LTE/{print; exit}')
            eval $(echo "$NR_LINE"  | awk -F'[,: ]+' '/MONSC/{printf "MCC=%s MNC=%s NR_ARFCN=%s NR_SCS=%s NR_CELL_ID=%s NR_PCI=%s NR_TAC=%s NR_RSRP=%s NR_RSRQ=%s NR_SINR=%s",$3,$4,$5,$6,$7,$8,$9,$10,$11,$12}')
            eval $(echo "$LTE_LINE" | awk -F'[,: ]+' '/MONSC/{printf "LTE_MCC=%s LTE_MNC=%s LTE_ARFCN=%s LTE_CELL_ID=%s LTE_PCI=%s LTE_TAC=%s LTE_RSRP=%s LTE_RSRQ=%s LTE_RSSI=%s",$3,$4,$5,$6,$7,$8,$9,$10,$11}')
            RAT="NR/NSA"
            ;;
    esac

    # 未驻留到小区时,尝试从IMSI中获取运营商信息
    T=$(echo "$_AT_RES" | awk '/CIMI:/{gsub(/.*CIMI[ ]*:[ ]*/,"");gsub(/"/,"");print $0}')
    [ -n "$T" ] && MCC=$(echo "$T" | cut -c1-3) && MNC=$(echo "$T" | cut -c4-5)

    # 拼装成JSON
    case "$RAT" in
        "NR/SA")
            SIM_MONSC=$(printf '{"rat":"%s","mcc":"%s","mnc":"%s","cell":{"type":"nr","arfcn":"%s","scs":"%s","cell_id":"%s","pci":"%s","tac":"%s","rsrp":"%s","rsrq":"%s","sinr":"%s"}}' \
                "$RAT" "$MCC" "$MNC" "$NR_ARFCN" "$NR_SCS" "$NR_CELL_ID" "$NR_PCI" "$NR_TAC" "$NR_RSRP" "$NR_RSRQ" "$NR_SINR")
            ;;
        "LTE")
            SIM_MONSC=$(printf '{"rat":"%s","mcc":"%s","mnc":"%s","cell":{"type":"lte","arfcn":"%s","cell_id":"%s","pci":"%s","tac":"%s","rsrp":"%s","rsrq":"%s","rssi":"%s"}}' \
                "$RAT" "$MCC" "$MNC" "$LTE_ARFCN" "$LTE_CELL_ID" "$LTE_PCI" "$LTE_TAC" "$LTE_RSRP" "$LTE_RSRQ" "$LTE_RSSI")
            ;;
        "WCDMA")
            SIM_MONSC=$(printf '{"rat":"%s","mcc":"%s","mnc":"%s","cell":{"type":"wcdma","arfcn":"%s","psc":"%s","cell_id":"%s","lac":"%s","rscp":"%s","rxlev":"%s","ecno":"%s","drx":"%s","ura":"%s"}}' \
                "$RAT" "$MCC" "$MNC" "$WCDMA_ARFCN" "$WCDMA_PCS" "$WCDMA_CELL_ID" "$LAC" "$RSCP" "$RXLEV" "$ECNO" "$DRX" "$URA")
            ;;
        "NR/NSA")
            SIM_MONSC=$(printf '{"rat":"%s","mcc":"%s","mnc":"%s","nr_cell":{"arfcn":"%s","scs":"%s","cell_id":"%s","pci":"%s","tac":"%s","rsrp":"%s","rsrq":"%s","sinr":"%s"},"lte_cell":{"mcc":"%s","mnc":"%s","arfcn":"%s","cell_id":"%s","pci":"%s","tac":"%s","rsrp":"%s","rsrq":"%s","rssi":"%s"}}' \
                "$RAT" "$MCC" "$MNC" \
                "$NR_ARFCN" "$NR_SCS" "$NR_CELL_ID" "$NR_PCI" "$NR_TAC" "$NR_RSRP" "$NR_RSRQ" "$NR_SINR" \
                "$LTE_MCC" "$LTE_MNC" "$LTE_ARFCN" "$LTE_CELL_ID" "$LTE_PCI" "$LTE_TAC" "$LTE_RSRP" "$LTE_RSRQ" "$LTE_RSSI")
            ;;
        *)
            SIM_MONSC="{}"
            ;;
    esac

    local ts=$(date "+%Y-%m-%d %H:%M:%S")
    SIM_MONSC=$(echo "$SIM_MONSC" | sed "s/^{/{\"timestamp\":\"${ts}\",/")
    _save "monsc" "${SIM_MONSC}"

    return 0
}

# 相邻小区信息
function atcmd_get_sim_monnc_realtime()
{
    local ATCMD="AT^MONNC"
    _exec_at "$ATCMD" $1 || return 1

    # 格式: ^MONNC: <RAT>[,<cell_paras>]
    # 每种 RAT 可能有多行 (GSM最多6个, WCDMA/LTE/NR最多16个)
    # GSM:   ^MONNC: GSM,<BAND>,<ARFCN>,<BSIC>,<Cell_ID>,<LAC>,<RXLEV>
    # WCDMA: ^MONNC: WCDMA,<ARFCN>,<PSC>,<RSCP>,<EC/N0>
    # LTE:   ^MONNC: LTE,<ARFCN>,<PCI>,<RSRP>,<RSRQ>,<RXLEV>
    # NR:    ^MONNC: NR,<ARFCN-NR>,<PCI>,<RSRP>,<RSRQ>,<SINR>
    # NONE:  ^MONNC: NONE

    # GSM 相邻小区: BAND,ARFCN,BSIC,Cell_ID,LAC,RXLEV
    NC_GSM=$(echo "$_AT_RES" | awk -F'[ ,]+' '/\^MONNC:.*GSM/{printf "%s,%s,%s,%s,%s,%s\n",$3,$4,$5,$6,$7,$8}')

    # WCDMA 相邻小区: ARFCN,PSC,RSCP,ECNO
    NC_WCDMA=$(echo "$_AT_RES" | awk -F'[ ,]+' '/\^MONNC:.*WCDMA/{printf "%s,%s,%s,%s\n",$3,$4,$5,$6}')

    # LTE 相邻小区: ARFCN,PCI,RSRP,RSRQ,RXLEV
    NC_LTE=$(echo "$_AT_RES" | awk -F'[ ,]+' '/\^MONNC:.*LTE/{printf "%s,%s,%s,%s,%s\n",$3,$4,$5,$6,$7}')

    # NR 相邻小区: ARFCN,PCI,RSRP,RSRQ,SINR
    NC_NR=$(echo "$_AT_RES" | awk -F'[ ,]+' '/\^MONNC:.*NR/{printf "%s,%s,%s,%s,%s\n",$3,$4,$5,$6,$7}')

    # NONE: 无相邻小区
    echo "$_AT_RES" | grep -q '^\^MONNC: NONE' && NC_GSM="" && NC_WCDMA="" && NC_LTE="" && NC_NR=""

    # echo "NC_GSM=${NC_GSM}"
    # echo "NC_WCDMA=${NC_WCDMA}"
    # echo "NC_LTE=${NC_LTE}"
    # echo "NC_NR=${NC_NR}"

    # 封装成 JSON
    NC_GSM_JSON=$(echo "$NC_GSM" | awk -F',' 'NF>=6{printf "%s{\"band\":\"%s\",\"arfcn\":\"%s\",\"bsic\":\"%s\",\"cell_id\":\"%s\",\"lac\":\"%s\",\"rxlev\":\"%s\"}", (NR>1?",":""),$1,$2,$3,$4,$5,$6}' | awk 'BEGIN{printf "["} {printf "%s",$0} END{printf "]"}')
    NC_WCDMA_JSON=$(echo "$NC_WCDMA" | awk -F',' 'NF>=4{printf "%s{\"arfcn\":\"%s\",\"psc\":\"%s\",\"rscp\":\"%s\",\"ecno\":\"%s\"}", (NR>1?",":""),$1,$2,$3,$4}' | awk 'BEGIN{printf "["} {printf "%s",$0} END{printf "]"}')
    NC_LTE_JSON=$(echo "$NC_LTE" | awk -F',' 'NF>=5{printf "%s{\"arfcn\":\"%s\",\"pci\":\"%s\",\"rsrp\":\"%s\",\"rsrq\":\"%s\",\"rxlev\":\"%s\"}", (NR>1?",":""),$1,$2,$3,$4,$5}' | awk 'BEGIN{printf "["} {printf "%s",$0} END{printf "]"}')
    NC_NR_JSON=$(echo "$NC_NR" | awk -F',' 'NF>=5{printf "%s{\"arfcn\":\"%s\",\"pci\":\"%s\",\"rsrp\":\"%s\",\"rsrq\":\"%s\",\"sinr\":\"%s\"}", (NR>1?",":""),$1,$2,$3,$4,$5}' | awk 'BEGIN{printf "["} {printf "%s",$0} END{printf "]"}')

    # 封装成一个整体大的JSON
    SIM_MONNC=$(printf '{"gsm":%s,"wcdma":%s,"lte":%s,"nr":%s}' \
        "$NC_GSM_JSON" "$NC_WCDMA_JSON" "$NC_LTE_JSON" "$NC_NR_JSON")
    local ts=$(date "+%Y-%m-%d %H:%M:%S")
    SIM_MONNC=$(echo "$SIM_MONNC" | sed "s/^{/{\"timestamp\":\"${ts}\",/")
    _save "monnc" "${SIM_MONNC}"
}

# 查询PDP上下文实际使用的IP地址
function atcmd_get_addr()
{
    local ATCMD="AT+CGPADDR=1"
    _exec_at "$ATCMD" $1 || return 1

    # AT+CGPADDR=1
    # +CGPADDR: 1,"10.130.211.28","36.8.132.13.110.0.125.201.24.187.158.93.237.218.64.128"
    # OK
    # 解析IPv4
    SIM_IPv4=$(echo "$_AT_RES" | awk -F'"' '/\+CGPADDR:/{print $2}')
    [ -z "$SIM_IPv4" ] && _log "failed to parse IPv4 from AT+CGPADDR" && return 1

    # 解析IPv6 (点分十进制 -> 冒号十六进制)
    local ipv6_decimal=$(echo "$_AT_RES" | awk -F'"' '/\+CGPADDR:/{print $4}')
    if [ -n "$ipv6_decimal" ]; then
        SIM_IPv6=$(echo "$ipv6_decimal" | awk -F'.' '{
            for (i=1; i<=NF; i++) {
                hex = sprintf("%02x", $i)
                printf "%s%s", hex, (i%2==0 ? (i<NF ? ":" : "") : "")
            }
        }')
    #     _log "IPv4: ${SIM_IPv4}, IPv6: ${SIM_IPv6}"
    # else
    #     _log "IPv4: ${SIM_IPv4}"
    fi

    _save "IPv4" "${SIM_IPv4:-}"
    _save "IPv6" "${SIM_IPv6:-}"

    return 0
}

# 查询信号强度
function atcmd_HCSQ()
{
    local ATCMD="AT^HCSQ?"
    _exec_at "$ATCMD" $1 || return 1

    # ^HCSQ: "WCDMA",30,30,58
    # ^HCSQ: "LTE",45,60,150,30
    # ^HCSQ: "NR",85,200,30
    # ^HCSQ: "NOSERVICE"

    local sysmode="" rssi="" rsrp="" sinr="" rsrq="" rscp="" ecio=""

    sysmode=$(echo "$_AT_RES" | awk -F'[," ]+' '/\^HCSQ:/{gsub(/"/,"",$2); print $2; exit}')
    [ -z "$sysmode" ] && { _log "failed to parse HCSQ sysmode"; return 1; }

    if [ "$sysmode" = "NOSERVICE" ]; then
        SIM_HCSQ='{"sysmode":"NOSERVICE"}'
        _save "hcsq" "${SIM_HCSQ}"
        return 0
    fi

    # 根据 sysmode 解析各参数
    case "$sysmode" in
        "GSM")
            rssi=$(echo "$_AT_RES" | awk -F'[," ]+' '/\^HCSQ:/{print $3}')
            ;;
        "WCDMA")
            rssi=$(echo "$_AT_RES" | awk -F'[," ]+' '/\^HCSQ:/{print $3}')
            rscp=$(echo "$_AT_RES" | awk -F'[," ]+' '/\^HCSQ:/{print $4}')
            ecio=$(echo "$_AT_RES" | awk -F'[," ]+' '/\^HCSQ:/{print $5}')
            ;;
        "LTE")
            rssi=$(echo "$_AT_RES" | awk -F'[," ]+' '/\^HCSQ:/{print $3}')
            rsrp=$(echo "$_AT_RES" | awk -F'[," ]+' '/\^HCSQ:/{print $4}')
            sinr=$(echo "$_AT_RES" | awk -F'[," ]+' '/\^HCSQ:/{print $5}')
            rsrq=$(echo "$_AT_RES" | awk -F'[," ]+' '/\^HCSQ:/{print $6}')
            ;;
        "NR")
            rsrp=$(echo "$_AT_RES" | awk -F'[," ]+' '/\^HCSQ:/{print $3}')
            sinr=$(echo "$_AT_RES" | awk -F'[," ]+' '/\^HCSQ:/{print $4}')
            rsrq=$(echo "$_AT_RES" | awk -F'[," ]+' '/\^HCSQ:/{print $5}')
            ;;
    esac

    # 索引值 -> dBm/dB 近似值转换
    # RSSI: 0=-121dBm, 96=-25dBm, 255=unknown
    _rssi_to_dbm() {
        local v="$1"
        [ -z "$v" ] || [ "$v" = "255" ] && { echo "null"; return; }
        echo "$(( v - 121 ))"
    }
    # RSRP: 0=-141dBm, 97=-44dBm, 255=unknown
    _rsrp_to_dbm() {
        local v="$1"
        [ -z "$v" ] || [ "$v" = "255" ] && { echo "null"; return; }
        echo "$(( v - 141 ))"
    }
    # SINR: 0=-20dB, 251=30dB, 255=unknown, step=0.2dB
    # 返回一位小数的 dB 值，用整数*10 表示避免浮点
    _sinr_to_db_x10() {
        local v="$1"
        [ -z "$v" ] || [ "$v" = "255" ] && { echo "null"; return; }
        echo "$(( (v - 1) * 2 - 200 ))"
    }
    # RSRQ: 0=-19.5dB, 34=-3dB, 255=unknown, step=0.5dB
    _rsrq_to_db_x10() {
        local v="$1"
        [ -z "$v" ] || [ "$v" = "255" ] && { echo "null"; return; }
        echo "$(( (v - 1) * 5 - 195 ))"
    }
    # RSCP: same as RSSI, 0=-121dBm, 96=-25dBm
    # ECIO: 0=<-32dB, 65=>0dB, step=0.5dB
    _ecio_to_db_x10() {
        local v="$1"
        [ -z "$v" ] || [ "$v" = "255" ] && { echo "null"; return; }
        echo "$(( (v - 1) * 5 - 325 ))"
    }

    # 组装 JSON
    SIM_HCSQ=$(printf '{"sysmode":"%s"' "$sysmode")
    [ -n "$rssi" ] && SIM_HCSQ="${SIM_HCSQ},\"rssi\":${rssi},\"rssi_dbm\":$(_rssi_to_dbm "$rssi")"
    [ -n "$rsrp" ] && SIM_HCSQ="${SIM_HCSQ},\"rsrp\":${rsrp},\"rsrp_dbm\":$(_rsrp_to_dbm "$rsrp")"
    [ -n "$sinr" ] && [ "$sinr" != "255" ] && SIM_HCSQ="${SIM_HCSQ},\"sinr\":${sinr},\"sinr_db\":$(awk "BEGIN {printf \"%.1f\", $(_sinr_to_db_x10 "$sinr")/10}")"
    [ -n "$rsrq" ] && [ "$rsrq" != "255" ] && SIM_HCSQ="${SIM_HCSQ},\"rsrq\":${rsrq},\"rsrq_db\":$(awk "BEGIN {printf \"%.1f\", $(_rsrq_to_db_x10 "$rsrq")/10}")"
    [ -n "$rscp" ] && SIM_HCSQ="${SIM_HCSQ},\"rscp\":${rscp},\"rscp_dbm\":$(_rssi_to_dbm "$rscp")"
    [ -n "$ecio" ] && [ "$ecio" != "255" ] && SIM_HCSQ="${SIM_HCSQ},\"ecio\":${ecio},\"ecio_db\":$(awk "BEGIN {printf \"%.1f\", $(_ecio_to_db_x10 "$ecio")/10}")"

    SIM_HCSQ="${SIM_HCSQ}}"

    _save "hcsq" "${SIM_HCSQ}"

    return 0
}

# 初始化
function atcmd_init
{
    logger -t "NCM" "ifname:${ifname} atcmd_init $1"
    # 打开回显
    atcmd_init_echo $1
    # 初始化网卡数量为1
    atcmd_init_netnum $1
    # 设置USB端口形态配置为Linux NCM模式
    atcmd_init_ncm $1
    # 开启SIM卡热插拔
    atcmd_init_hotplug $1

    return 0
}

# 拨号
function dial
{
    # 必须先断开连接才能激活PDP上下文
    atcmd_disconnect $1

    # 设置APN
    local apn=$(uci -q get sim.$ifname.apn)
    [ -z ${apn} ] && {
        echo "apn required! (uci -q get sim.$ifname.apn)"
        # logger -t "NCM" "ifname:${ifname} apn required! (uci -q get sim.$ifname.apn)"
        return 1
    }
    atcmd_set_apn $1 $apn

    # 设置入网方式
    local net=$(uci -q get sim.$ifname.net)
    atcmd_set_net $1 $net

    # 设置鉴权
    local auth=$(uci -q get sim.$ifname.auth)
    local user=$(uci -q get sim.$ifname.user)
    local passwd=$(uci -q get sim.$ifname.passwd)
    atcmd_set_auth $1 $auth $user $passwd

    # 锁5G频段
    local nrBandLock=$(uci -q get sim.$ifname.nrBandLock)
    # 去掉前导的 n/N（如 n78 → 78）
    nrBandLock=$(echo "$nrBandLock" | sed 's/^[nN]//')
    # 锁5G PCI小区
    local nrPciLockEnable=$(uci -q get sim.$ifname.nrPciLockEnable)
    local nrPciPcid=$(uci -q get sim.$ifname.nrPciPcid)
    local nrPciBand=$(uci -q get sim.$ifname.nrPciBand)
    local nrPciFreq=$(uci -q get sim.$ifname.nrPciFreq)
    local nrPciScs=$(uci -q get sim.$ifname.nrPciScs)
    local nrPciForbidFlag=$(uci -q get sim.$ifname.nrPciForbidFlag)

    if [ -n "$nrBandLock" ] && [ "$nrBandLock" != "unlocked" ]; then
        atcmd_nr_band_lock $1 "$nrBandLock"
    elif [ -n "$nrPciLockEnable" ] && [ "$nrPciLockEnable" = "locked" ]; then
        atcmd_nr_pci_lock $1 "$nrPciForbidFlag" "$nrPciBand" "$nrPciFreq" "$nrPciScs" "$nrPciPcid"
    else
        atcmd_nr_unlock $1
    fi

    # 锁LTE频段
    local lteBandLock=$(uci -q get sim.$ifname.lteBandLock)
    # 去掉前导的 b/B/n/N
    lteBandLock=$(echo "$lteBandLock" | sed 's/^[bBnN]//')
    # 锁LTE PCI小区
    local ltePciLockEnable=$(uci -q get sim.$ifname.ltePciLockEnable)
    local ltePciPcid=$(uci -q get sim.$ifname.ltePciPcid)
    local ltePciBand=$(uci -q get sim.$ifname.ltePciBand)
    local ltePciFreq=$(uci -q get sim.$ifname.ltePciFreq)

    if [ -n "$lteBandLock" ] && [ "$lteBandLock" != "unlocked" ]; then
        atcmd_lte_band_lock $1 "$lteBandLock"
    elif [ -n "$ltePciLockEnable" ] && [ "$ltePciLockEnable" = "locked" ]; then
        atcmd_lte_pci_lock $1 "$ltePciBand" "$ltePciFreq" "$ltePciPcid"
    else
        atcmd_lte_unlock $1
    fi

    # 切换一次飞行模式
    atcmd_set_airplane_on $1
    sleep 3
    atcmd_set_airplane_off $1

    # 拨号
    if atcmd_connect $1; then
        return 0
    fi

    return 1
}

# 拨号
function atcmd_dial
{
    # 检查是否插卡
    atcmd_get_sim_status_realtime $1

    # 判断SIM_STATUS中是否包含: "SIM Initialized" 或 "SIM Ready"
    if ! echo "${SIM_STATUS}" | grep -qE "SIM Initialized|SIM Ready"; then
        return 1
    fi

    # 获取iccid
    atcmd_get_iccid $1

    # 获取imsi
    atcmd_get_imsi $1

    # 检查是否需要重新拨号
    atcmd_get_addr $1
    # IPv4
    [ -z "${SIM_IPv4}" ] || { 
        echo "IPv4: ${SIM_IPv4}"
        # logger -t "NCM" "ifname:${ifname} IPv4:${SIM_IPv4}"
    } 
    [ -z "${SIM_IPv4}" ] && { 
        echo "IPv4 not ready!"
        # logger -t "NCM" "ifname:${ifname} IPv4 not ready!"
    }
    # IPv6
    [ -z "${SIM_IPv6}" ] || {
        echo "IPv6: ${SIM_IPv6}"
        # logger -t "NCM" "ifname:${ifname} IPv6: ${SIM_IPv6}"
    }
    [ -z "${SIM_IPv6}" ] && {
        echo "IPv6 not ready!"
        # logger -t "NCM" "ifname:${ifname} IPv6 not ready!"
    }

    # 拨号
    if ! dial $1; then
        return 1
    fi

    return 0
}
