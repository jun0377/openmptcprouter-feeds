#!/bin/sh

# 从OpenVPN配置文件中获取指定选项的值
get_openvpn_option() {
	# 配置文件路径
	local config="$1"
	# 选项值
	local variable="$2"
	# 选项键
	local option="$3"

	# 尝试匹配单引号包围的值（例如：option 'value'）
	local value="$(sed -rne 's/^[ \t]*'"$option"'[ \t]+'"'([^']+)'"'[ \t]*$/\1/p' "$config" | tail -n1)"
	# 尝试匹配双引号包围的值
	[ -n "$value" ] || value="$(sed -rne 's/^[ \t]*'"$option"'[ \t]+"(([^"\\]|\\.)+)"[ \t]*$/\1/p' "$config" | tail -n1 | sed -re 's/\\(.)/\1/g')"
	# 尝试匹配无引号的值
	[ -n "$value" ] || value="$(sed -rne 's/^[ \t]*'"$option"'[ \t]+(([^ \t\\]|\\.)+)[ \t]*$/\1/p' "$config" | tail -n1 | sed -re 's/\\(.)/\1/g')"
	# 未找到配置
	[ -n "$value" ] || return 1

	# 将找到的值赋值给指定的变量名，-n选项防止导出到环境变量
	export -n "$variable=$value"
	return 0
}

