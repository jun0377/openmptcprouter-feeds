-- Copyright 2008 Steven Barth <steven@midlink.org>
-- Copyright 2011 Jo-Philipp Wich <jow@openwrt.org>
-- Copyright 2018-2023 Ycarus (Yannick Chabanois) <ycarus@zugaina.org>
-- Licensed to the public under the Apache License 2.0.

module("luci.controller.mptcp", package.seeall)


function index()
	-- 获取内核版本
	local uname = nixio.uname()
	-- 注册入口: http://192.168.100.1:8080/cgi-bin/luci/admin/network/mptcp
	entry({"admin", "network", "mptcp"}, alias("admin", "network", "mptcp", "settings"), _("MPTCP"))
	-- 内核5.x使用传统CBI配置页面, 其它版本内核使用lua view渲染
	if uname ~= nil and uname.release:sub(1,1) == "5" then
		entry({"admin", "network", "mptcp", "settings"}, cbi("mptcp"), _("Settings"),2).leaf = true
	else
		-- http://192.168.100.1:8080/cgi-bin/luci/admin/network/mptcp/settings
		entry({"admin", "network", "mptcp", "settings"}, view("mptcp/mptcp"), _("Settings"),2).leaf = true
	end
	-- 注册入口: http://192.168.100.1:8080/cgi-bin/luci/admin/network/mptcp/bandwidth
	entry({"admin", "network", "mptcp", "bandwidth"}, template("mptcp/multipath"), _("Bandwidth"), 3).leaf = true
	entry({"admin", "network", "mptcp", "multipath_bandwidth"}, call("multipath_bandwidth")).leaf = true
	entry({"admin", "network", "mptcp", "interface_bandwidth"}, call("interface_bandwidth")).leaf = true
	if uname ~= nil and uname.release:sub(1,1) == "5" then
		entry({"admin", "network", "mptcp", "mptcp_check"}, template("mptcp/mptcp_check"), _("MPTCP Support Check"), 4).leaf = true
	end
	entry({"admin", "network", "mptcp", "mptcp_check_trace"}, post("mptcp_check_trace")).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_fullmesh"}, template("mptcp/mptcp_fullmesh"), _("MPTCP Fullmesh"), 5).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_fullmesh_data"}, post("mptcp_fullmesh_data")).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_connections"}, template("mptcp/mptcp_connections"), _("Established connections"), 6).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_connections_data"}, post("mptcp_connections_data")).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_monitor"}, template("mptcp/mptcp_monitor"), _("MPTCP monitoring"), 6).leaf = true
	entry({"admin", "network", "mptcp", "mptcp_monitor_data"}, post("mptcp_monitor_data")).leaf = true
end

-- 返回某个网卡的带宽历史数据(JSON 数组)
function interface_bandwidth(iface)
	luci.http.prepare_content("application/json")
	local bwc = io.popen("luci-bwc -i %q 2>/dev/null" % iface)	--  luci-bwc -i eth1
	if bwc then
		luci.http.write("[")
		while true do
			local ln = bwc:read("*l")
			if not ln then break end
			luci.http.write(ln)
		end
		luci.http.write("]")
		bwc:close()
	end
end

-- 按固定分隔符（plain text，不是正则）切分字符串，返回数组
function string.split(input, delimiter)
	input = tostring(input)
	delimiter = tostring(delimiter)
	if (delimiter=='') then return false end
	local pos,arr = 0, {}
	-- for each divider found
	for st,sp in function() return string.find(input, delimiter, pos, true) end do
		table.insert(arr, string.sub(input, pos, st - 1))
		pos = sp + 1
	end
	table.insert(arr, string.sub(input, pos))
	return arr
end

-- 汇总所有启用 multipath 的接口带宽，并计算一个 total 总带宽序列，返回 JSON。
function multipath_bandwidth()
	local result = { };
	local uci = luci.model.uci.cursor()
	local res={ };
	local str="";
	local tmpstr="";

	-- 遍历/etc/config/network中的所有interface段
	uci:foreach("network", "interface", function(s)
		local intname = s[".name"]		-- 逻辑接口名, 如wan0 wan1
		local label = s["label"]		-- 显示标签

		-- 获取三层设备名, 如wan0 => eth1
		local dev = get_device(intname)
		if dev == "" then
			dev = get_device(s["device"])
			if dev == "" then
				dev = get_device(s["ifname"])
			end
		end

		-- 获取/etc/config/network中的multipath配置
		local multipath = s["multipath"] or ""
		-- 跳过回环设备和无效设备名
		if dev ~= "lo" and dev ~= "" then
			-- 再次尝试从/etc/config/openmptcprouter中获取multipath配置
			if multipath == "" then
				multipath = uci:get("openmptcprouter", intname, "multipath") or ""
			end
			-- multipath设置为off
			if multipath == "" then
				multipath = "off"
			end
			-- 只统计参与MPTCP的接口
			if multipath == "on" or multipath == "master" or multipath == "backup" or multipath == "handover" then
				-- 读取60个采样点的带宽数据
				local bwc = luci.sys.exec("luci-bwc -i %q 2>/dev/null" % dev) or ""
				-- 去除换行符,并包一层[],然后存入result
				if bwc ~= nil then
					--result[dev] = "[" .. string.gsub(bwc, '[\r\n]', '') .. "]"
					if label ~= nil then
						result[intname .. " (" .. label .. ")" ] = "[" .. string.gsub(bwc, '[\r\n]', '') .. "]"
					else
						result[intname] = "[" .. string.gsub(bwc, '[\r\n]', '') .. "]"
					end
				-- 失败时赋值空数组
				else
					if label ~= nil then
						result[intname .. " (" .. label .. ")" ] = "[]"
					else
						result[intname] = "[]"
					end
				end
			end
		end
	end)

	-- 初始化total二维数组
	res["total"]={ };
	-- 60个采样点
	for i=1,60 do
		-- 每个采样点初始化一行
		res["total"][i]={}
		-- 每行5个字段
		for j=1,5 do
			res["total"][i][j]=0
		end
	end

	-- 遍历每个接口的带宽数据
	for key,value in pairs(result) do
		-- 为当前接口初始化解析后的二维数组
		res[key]={}
		-- 去掉开头的 "[["（因为 value 本身又包了一层 []）
		value=(string.gsub(value, "^%[%[", ""))
		-- 去掉结尾的 "]]"
		value=(string.gsub(value, "%]%]", ""))
		-- 按 "]," 切分 60 个点（每点形如 "[a,b,c,d,e"）
		local temp1 = string.split(value, "],")
		-- 确认至少有两段，避免异常格式
		if temp1[2] ~= nil then
			res[key][1]=temp1[1]										-- 保存第一段（注意这里仍是字符串，后面会再 split）
			for i=2,60 do												-- 从第 2 个点开始填充（第 1 个点已赋值）
				res[key][i]={}											-- 初始化该点容器
				if temp1[i] ~= nil then
					res[key][i]=(string.gsub(temp1[i], "%[", " "))
				end
			end
			-- 遍历每个点，拆分成 5 列并累加 total
			for i=1,60 do
				res[key][i] = string.split(res[key][i], ",")					-- 以逗号切分列
				for j=1,5 do													-- 遍历 5 列字段
					res[key][i][j]= tonumber(res[key][i][j])					-- 当前接口该点该列转数字
					res["total"][i][j]= tonumber(res["total"][i][j])			-- total 对应位置确保为数字
					if j ==1 then												-- 第一列特殊处理（通常像是时间戳/序号，不做累加）
						if res[key][i][j] ~= nil and res[key][i][j] > 0 then	-- 若该列有有效值
							res["total"][i][j] = res[key][i][j]					-- 用当前接口的值覆盖 total（不是相加）
						else													-- 若无有效值
							res["total"][i][j] = 0								-- total 第一列置 0
						end
					else														-- 其余列做数值累加（例如 RX/TX 速率等）
						if res[key][i][j] ~= nil and res[key][i][j] > 0 then	-- 仅累加正值
							res["total"][i][j] = res["total"][i][j] + res[key][i][j]
						end
					end
				end
			end
		end
	end
	-- 把 total 的数字再转回字符串（便于后续 table.concat）
	for i=1,60 do
		for j=1,5 do	-- 逐列转换
			if "number"== type(res["total"][i][j]) then				-- 只转换数字类型
				res["total"][i][j]= tostring(res["total"][i][j])	-- 数字转字符串
			end
		end
	end
	-- 把 total 二维数组拼成 JSON 数组字符串
	for i=1,60 do
		if i == 60 then												-- 最后一个点不追加逗号（但这里实现方式比较特殊）
			tmpstr = "["..table.concat(res["total"][i], ",")		-- 生成形如 "[a,b,c,d,e"（注意这里没有补上 "]"）
		else
			tmpstr = "["..table.concat(res["total"][i], ",").."],"	-- 生成形如 "[a,b,c,d,e],"（有右括号和逗号）
		end
		str  = str..tmpstr											-- 追加到总字符串
	end
	str  = "["..str.."]]"				-- 外层再包一层并补齐结尾（使整体形如 "[[...],[...],...]]"）
	result["total"]=str					-- 把 total 放回 result，作为额外字段

	luci.http.prepare_content("application/json")	-- 设置响应类型 JSON
	luci.http.write_json(result)					-- 输出 JSON（注意：接口数据与 total 是“字符串化数组”，不是 JSON 数组类型）
end

-- 从 ubus 获取逻辑接口对应的三层设备名(l3_device)
function get_device(interface)
	local dump = require("luci.util").ubus("network.interface.%s" % interface, "status", {})
	if dump then
		return dump['l3_device']
	else
		return ""
	end
end

-- 对当前配置的远端服务器做 tracebox 路径探测，并把输出按行回传（text/plain）
function mptcp_check_trace(iface)
	luci.http.prepare_content("text/plain")
	local tracebox
	local uci    = require "luci.model.uci".cursor()
	local interface = get_device(iface)
	local server = uci:get("shadowsocks-libev", "sss0", "server") or ""
	if server == "" then return end
	if interface == "" then
		tracebox = io.popen("tracebox -s /usr/share/tracebox/omr-mptcp-trace.lua " .. server)
	else
		tracebox = io.popen("tracebox -s /usr/share/tracebox/omr-mptcp-trace.lua -i " .. interface .. " " .. server)
	end
	if tracebox then
		while true do
			local ln = tracebox:read("*l")
			if not ln then break end
			luci.http.write(ln)
			luci.http.write("\n")
		end
	end
	return
end

-- 输出 multipath -f 的结果（text/plain），用于 Fullmesh 页面显示
function mptcp_fullmesh_data()
	luci.http.prepare_content("text/plain")
	local fullmesh
	fullmesh = io.popen("multipath -f")
	if fullmesh then
		while true do
			local ln = fullmesh:read("*l")
			if not ln then break end
			luci.http.write(ln)
			luci.http.write("\n")
		end
	end
	return
end

-- 输出 multipath -m 的结果（text/plain），用于 MPTCP monitoring 页面
function mptcp_monitor_data()
	luci.http.prepare_content("text/plain")
	local fullmesh
	fullmesh = io.popen("multipath -m")
	if fullmesh:read() ~= nil then
		while true do
			local ln = fullmesh:read("*l")
			if not ln then break end
			luci.http.write(ln)
			luci.http.write("\n")
		end
	end
	return
end

-- 输出 multipath -c 的结果（text/plain），用于 Established connections 页面
function mptcp_connections_data()
	luci.http.prepare_content("text/plain")
	local connections
	connections = io.popen("multipath -c")
	if connections:read() ~= nil then
		while true do
			local ln = connections:read("*l")
			if not ln then break end
			luci.http.write(ln)
			luci.http.write("\n")
		end
	end
	return
end
