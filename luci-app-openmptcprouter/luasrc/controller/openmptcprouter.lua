local math  = require "math"
local sys   = require "luci.sys"
local json  = require("luci.json")
local fs    = require("nixio.fs")
local net   = require "luci.model.network".init()
local ucic  = luci.model.uci.cursor()
local ipc = require "luci.ip"
module("luci.controller.openmptcprouter", package.seeall)

-- web界面路由
function index()
	local ucic  = luci.model.uci.cursor()
	-- uci get openmptcprouter.settings.menu
	menuentry = ucic:get("openmptcprouter","settings","menu") or "OpenMPTCProuter"
	entry({"admin", "system", menuentry:lower()}, alias("admin", "system", menuentry:lower(), "wizard"), _(menuentry), 1)
	entry({"admin", "system", menuentry:lower(), "wizard"}, template("openmptcprouter/wizard"), _("Settings Wizard"), 1)
	entry({"admin", "system", menuentry:lower(), "wizard_add"}, post("wizard_add"))
	entry({"admin", "system", menuentry:lower(), "status"}, template("openmptcprouter/wanstatus"), _("Status"), 2).leaf = true
	entry({"admin", "system", menuentry:lower(), "interfaces_status"}, call("interfaces_status")).leaf = true
	entry({"admin", "system", menuentry:lower(), "settings"}, template("openmptcprouter/settings"), _("Advanced Settings"), 3).leaf = true
	entry({"admin", "system", menuentry:lower(), "settings_add"}, post("settings_add"))
	entry({"admin", "system", menuentry:lower(), "update_vps"}, post("update_vps"))
	entry({"admin", "system", menuentry:lower(), "backup"}, template("openmptcprouter/backup"), _("Backup on server"), 3).leaf = true
	entry({"admin", "system", menuentry:lower(), "backupgr"}, post("backupgr"))
	entry({"admin", "system", menuentry:lower(), "debug"}, template("openmptcprouter/debug"), _("Show all settings"), 5).leaf = true
end

-- 根据物理设备名获取网络接口名，如根据 eth0 获取到 WAN0
function interface_from_device(dev)
	for _, iface in ipairs(net:get_networks()) do
		local ifacen = iface:name()
		local ifacename = ""
		ifacename = ucic:get("network",ifacen,"device")
		if ifacename == "" then
			ifacename = ucic:get("network",ifacen,"ifname")
		end
		if ifacename == dev then
			return ifacen
		end
	end
	return ""
end

-- 根据网络接口名查找对应的 UCI 设备配置名
function uci_device_from_interface(intf)
	intfname = ucic:get("network",intf,"device")
	deviceuci = ""
	ucic:foreach("network", "device", function(s)
		if intfname == ucic:get("network",s[".name"],"name") then
		    deviceuci = s[".name"]
		end
	end)
	return deviceuci
end

function wizard_add()
	-- 是否跳转到状态页面
	local gostatus = true
	
	-- Force WAN zone firewall members to be a list
	-- 强制将防火墙WAN区域的网络成员转换为列表形式
	local fwwan = sys.exec("uci -q get firewall.zone_wan.network")
	luci.sys.call("uci -q delete firewall.zone_wan.network")
	for interface in fwwan:gmatch("%S+") do
		luci.sys.call("uci -q add_list firewall.zone_wan.network=" .. interface)
	end
	ucic:save("firewall")
	
	-- Add new server
	-- 添加新服务器
	local add_server = luci.http.formvalue("add_server") or ""
	local add_server_name = luci.http.formvalue("add_server_name") or ""
	if add_server ~= "" and add_server_name ~= "" then
		-- uci set openmptcprouter.vps=server
		ucic:set("openmptcprouter",add_server_name:gsub("[^%w_]+","_"),"server")
		-- uci set openmptcprouter.vps.username=openmptcprouter
		ucic:set("openmptcprouter",add_server_name:gsub("[^%w_]+","_"),"username","openmptcprouter")
		gostatus = false
	end

	-- Remove existing server
	-- 删除现有服务器
	local delete_server = luci.http.formvaluetable("deleteserver") or ""
	if delete_server ~= "" and next(delete_server) ~= nil then
		-- 遍历要删除的服务器
		for serverdel, _ in pairs(delete_server) do
			-- 删除与该服务器相关的所有网络接口路由
			ucic:foreach("network", "interface", function(s)
				local sectionname = s[".name"]
				ucic:delete("network","server_" .. serverdel .. "_" .. sectionname .. "_route")
			end)
			-- 删除默认路由
			ucic:delete("network","server_" .. serverdel .. "_default_route")
			-- 删除服务器配置
			ucic:delete("openmptcprouter",serverdel)
			ucic:delete("iperf",serverdel)
			ucic:save("openmptcprouter")
			ucic:commit("openmptcprouter")
			ucic:save("network")
			ucic:commit("network")
		end
		-- 更新剩余服务器配置
		local nbserver = 0
		local server_ip = ''
		ucic:foreach("openmptcprouter", "server", function(s)
			local servername = s[".name"]
			nbserver = nbserver + 1
			server_ips = ucic:get_list("openmptcprouter",servername,"ip")
			server_ip = server_ips[1]
		end)
		-- 如果只剩一个服务器，更新所有VPN和服务相关的IP配置
		if nbserver == 1 and server_ip ~= "" and server_ip ~= nil then
			ucic:set("shadowsocks-libev","sss0","server",server_ip)
			ucic:set("shadowsocks-rust","sss0","server",server_ip)
			ucic:set("glorytun","vpn","host",server_ip)
			ucic:set("glorytun-udp","vpn","host",server_ip)
			ucic:set("dsvpn","vpn","host",server_ip)
			ucic:set("mlvpn","general","host",server_ip)
			ucic:set("ubond","general","host",server_ip)
			luci.sys.call("uci -q del openvpn.omr.remote")
			luci.sys.call("uci -q add_list openvpn.omr.remote=" .. server_ip)
			ucic:set("qos","serverin","srchost",server_ip)
			ucic:set("qos","serverout","dsthost",server_ip)
		end
		-- 重定向到向导页面
		luci.http.redirect(luci.dispatcher.build_url("admin/system/openmptcprouter/wizard"))
		return
	end

	-- Add new interface
	-- 添加新接口
	local add_interface = luci.http.formvalue("add_interface") or ""
	local add_interface_ifname = luci.http.formvalue("add_interface_ifname") or ""
	if add_interface ~= "" then
		-- 计算新接口编号
		local i = 1
		local multipath_master = false
		ucic:foreach("network", "interface", function(s)
			local sectionname = s[".name"]
			if sectionname:match("^wan(%d+)$") then
				if i <= tonumber(string.match(sectionname, '%d+')) then
					i = tonumber(string.match(sectionname, '%d+')) + 1
				end
			end
			if ucic:get("network",sectionname,"multipath") == "master" then
				multipath_master = true
			end
		end)
		-- 确定默认接口名
		local defif = "eth0"
		if add_interface_ifname == "" then
			local defif1 = ucic:get("network","wan1_dev","device") or ""
			if defif1 == "" then
				defif1 = ucic:get("network","wan1_dev","ifname") or ""
			end
			if defif1 ~= "" then
				defif = defif1
			end
		else
			defif = add_interface_ifname
		end
		
		-- 检查是否存在对应的接口，并设置macvlan配置
		local ointf = interface_from_device(defif) or ""
		local wanif = defif
		if ointf ~= "" then
			if ucic:get("network",ointf,"type") == "" then
				ucic:set("network",ointf,"type","macvlan")
				ucic:set("network",ointf,"device",ointf)
				ucic:set("network",ointf .. "_dev","device")
				ucic:set("network",ointf .. "_dev","type","macvlan")
				ucic:set("network",ointf .. "_dev","mode","vepa")
				ucic:set("network",ointf .. "_dev","ifname",defif)
				ucic:set("network",ointf .. "_dev","name",ointf)
			end
			wanif = "wan" .. i
		end
		
		-- 创建新的WAN接口配置
		ucic:set("network","wan" .. i,"interface")
		ucic:set("network","wan" .. i,"device",defif)
		ucic:set("network","wan" .. i,"proto","static")
		ucic:set("openmptcprouter","wan" .. i,"interface")

		-- 如果需要macvlan，设置相关配置
		if ointf ~= "" then
			ucic:set("network","wan" .. i,"type","macvlan")
			ucic:set("network","wan" .. i,"device","wan" .. i)
			ucic:set("network","wan" .. i,"masterintf",defif)
			ucic:set("network","wan" .. i .. "_dev","device")
			ucic:set("network","wan" .. i .. "_dev","type","macvlan")
			ucic:set("network","wan" .. i .. "_dev","mode","vepa")
			ucic:set("network","wan" .. i .. "_dev","ifname",defif)
			ucic:set("network","wan" .. i .. "_dev","name","wan" .. i)
			ucic:set("network","wan" .. i .. "_dev","txqueuelen","1000")
		end

		-- 设置路由表和多路径配置
		ucic:set("network","wan" .. i,"ip4table","wan")
		if multipath_master then
			ucic:set("network","wan" .. i,"multipath","on")
			ucic:set("openmptcprouter","wan" .. i,"multipath","on")
		else
			ucic:set("network","wan" .. i,"multipath","master")
			ucic:set("openmptcprouter","wan" .. i,"multipath","master")
		end
		ucic:set("network","wan" .. i,"defaultroute","0")
		ucic:reorder("network","wan" .. i, i + 2)
		ucic:save("network")
		ucic:commit("network")
		ucic:save("openmptcprouter")
		ucic:commit("openmptcprouter")

		-- 设置QoS配置
		ucic:set("qos","wan" .. i,"interface")
		ucic:set("qos","wan" .. i,"classgroup","Default")
		ucic:set("qos","wan" .. i,"enabled","0")
		ucic:set("qos","wan" .. i,"upload","4000")
		ucic:set("qos","wan" .. i,"download","100000")
		ucic:save("qos")
		ucic:commit("qos")

		-- 设置SQM配置
		ucic:set("sqm","wan" .. i,"queue")
		if ointf ~= "" then
			ucic:set("sqm","wan" .. i,"interface","wan" .. i)
		else
			ucic:set("sqm","wan" .. i,"interface",defif)
		end
		ucic:set("sqm","wan" .. i,"qdisc","cake")
		ucic:set("sqm","wan" .. i,"script","piece_of_cake.qos")
		ucic:set("sqm","wan" .. i,"qdisc_advanced","0")
		ucic:set("sqm","wan" .. i,"linklayer","none")
		ucic:set("sqm","wan" .. i,"enabled","1")
		ucic:set("sqm","wan" .. i,"debug_logging","0")
		ucic:set("sqm","wan" .. i,"verbosity","5")
		ucic:set("sqm","wan" .. i,"download","0")
		ucic:set("sqm","wan" .. i,"upload","0")
		ucic:set("sqm","wan" .. i,"iqdisc_opts","autorate-ingress dual-dsthost")
		ucic:set("sqm","wan" .. i,"eqdisc_opts","dual-srchost")
		ucic:save("sqm")
		ucic:commit("sqm")
		
		-- 添加接口到vnstat监控
		luci.sys.call("uci -q add_list vnstat.@vnstat[-1].interface=" .. wanif)
		luci.sys.call("uci -q commit vnstat")

		-- Dirty way to add new interface to firewall...
		-- 添加接口到防火墙WAN区域
		luci.sys.call("uci -q add_list firewall.zone_wan.network=wan" .. i)
		luci.sys.call("uci -q commit firewall")

		-- 重启相关服务
		luci.sys.call("/etc/init.d/macvlan restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/vnstat restart >/dev/null 2>/dev/null")
		gostatus = false
	end

	-- Remove existing interface
	-- 删除现有接口
	local delete_intf = luci.http.formvaluetable("delete") or ""
	if delete_intf ~= "" then
		for intf, _ in pairs(delete_intf) do
			-- 获取接口设备名
			local defif = ucic:get("network",intf,"ifname") or ""
			if defif == "" then
				defif = ucic:get("network",intf,"ifname")
			end
			-- 删除网络配置
			ucic:delete("network",intf)
			if ucic:get("network",intf .. "_dev") ~= "" then
				ucic:delete("network",intf .. "_dev")
			end
			ucic:save("network")
			ucic:commit("network")
			-- 删除SQM配置
			ucic:delete("sqm",intf)
			ucic:save("sqm")
			ucic:commit("sqm")
			-- 删除QoS配置
			ucic:delete("qos",intf)
			ucic:save("qos")
			ucic:commit("qos")
			-- 删除OpenMPTCProuter配置
			ucic:delete("openmptcprouter",intf)
			ucic:save("openmptcprouter")
			ucic:commit("openmptcprouter")
			-- 从vnstat监控中移除接口
			if defif ~= nil and defif ~= "" then
				luci.sys.call("uci -q del_list vnstat.@vnstat[-1].interface=" .. defif)
			end
			luci.sys.call("uci -q commit vnstat")
			-- 从防火墙WAN区域移除接口
			luci.sys.call("uci -q del_list firewall.zone_wan.network=" .. intf)
			luci.sys.call("uci -q commit firewall")
			gostatus = false
		end
	end

	-- Enable/disable IPv6
	-- 启用/禁用IPv6
	local disableipv6 = luci.http.formvalue("enableipv6") or "1"
	ucic:set("openmptcprouter","settings","disable_ipv6",disableipv6)


	-- Set interfaces settings
	-- 设置接口配置
	local downloadmax = 0
	local uploadmax = 0
	local interfaces = luci.http.formvaluetable("intf")
	for intf, _ in pairs(interfaces) do
		-- 获取接口基本配置
		local label = luci.http.formvalue("cbid.network.%s.label" % intf) or ""
		local proto = luci.http.formvalue("cbid.network.%s.proto" % intf) or "static"
		local typeintf = luci.http.formvalue("cbid.network.%s.type" % intf) or ""
		local masterintf = luci.http.formvalue("cbid.network.%s.masterintf" % intf) or ""
		local ifname = luci.http.formvalue("cbid.network.%s.intf" % intf) or ""
		local vlan = luci.http.formvalue("cbid.network.%s.vlan" % intf) or ""

		-- 获取移动网络设备配置
		local device_ncm = luci.http.formvalue("cbid.network.%s.device.ncm" % intf) or ""
		local device_qmi = luci.http.formvalue("cbid.network.%s.device.qmi" % intf) or ""
		local device_modemmanager = luci.http.formvalue("cbid.network.%s.device.modemmanager" % intf) or ""

		-- 获取IP配置
		local ipaddr = luci.http.formvalue("cbid.network.%s.ipaddr" % intf) or ""
		local ip6addr = luci.http.formvalue("cbid.network.%s.ip6addr" % intf) or ""
		local netmask = luci.http.formvalue("cbid.network.%s.netmask" % intf) or ""
		local gateway = luci.http.formvalue("cbid.network.%s.gateway" % intf) or ""
		local ip6gw = luci.http.formvalue("cbid.network.%s.ip6gw" % intf) or ""
		local ipv6 = luci.http.formvalue("cbid.network.%s.ipv6" % intf) or "0"

		-- 获取移动网络配置
		local apn = luci.http.formvalue("cbid.network.%s.apn" % intf) or ""
		local pincode = luci.http.formvalue("cbid.network.%s.pincode" % intf) or ""
		local delay = luci.http.formvalue("cbid.network.%s.delay" % intf) or ""
		local username = luci.http.formvalue("cbid.network.%s.username" % intf) or ""
		local password = luci.http.formvalue("cbid.network.%s.password" % intf) or ""
		local auth = luci.http.formvalue("cbid.network.%s.auth" % intf) or ""
		local mode = luci.http.formvalue("cbid.network.%s.mode" % intf) or ""

		-- 获取QoS和SQM配置
		local sqmenabled = luci.http.formvalue("cbid.sqm.%s.enabled" % intf) or "0"
		local sqmautorate = luci.http.formvalue("cbid.sqm.%s.autorate" % intf) or "0"
		local qosenabled = luci.http.formvalue("cbid.qos.%s.enabled" % intf) or "0"

		-- 获取多路径和LAN配置
		local multipath = luci.http.formvalue("cbid.network.%s.multipath" % intf) or "on"
		local lan = luci.http.formvalue("cbid.network.%s.lan" % intf) or "0"
		local ttl = luci.http.formvalue("cbid.network.%s.ttl" % intf) or ""

		-- 设置接口类型
		if typeintf ~= "" then
			if typeintf == "normal" then
				typeintf = ""
			end
			ucic:set("network",intf,"type",typeintf)
		end

		-- 处理VLAN配置
		if vlan ~= "" then
			ifname = ifname .. '.' .. vlan
		end

		-- 设置macvlan配置
		if typeintf == "macvlan" and masterintf ~= "" then
			ucic:set("network",intf,"type","macvlan")
			ucic:set("network",intf .. "_dev","device")
			ucic:set("network",intf .. "_dev","type","macvlan")
			ucic:set("network",intf .. "_dev","ifname",masterintf)
			ucic:set("network",intf .. "_dev","mode","vepa")
			ucic:set("network",intf .. "_dev","name",intf)
			ucic:set("network",intf,"device",intf)
			ucic:set("network",intf,"masterintf",masterintf)
		-- 设置普通网络接口配置
		elseif typeintf == "" and ifname ~= "" and (proto == "static" or proto == "dhcp" or proto == "dhcpv6") then
			ucic:set("network",intf,"device",ifname)
			if uci_device_from_interface(intf) == "" then
				ucic:set("network",intf .. "_dev","device")
				ucic:set("network",intf .. "_dev","name",ifname)
			end
		-- 设置NCM设备配置
		elseif typeintf == "" and device ~= "" and proto == "ncm" then
			ucic:set("network",intf,"device",device_ncm)
			if uci_device_from_interface(intf) == "" then
				ucic:set("network",intf .. "_dev","device")
				ucic:set("network",intf .. "_dev","name",device_ncm)
			end
		-- 设置QMI设备配置
		elseif typeintf == "" and device ~= "" and proto == "qmi" then
			ucic:set("network",intf,"device",device_qmi)
			if uci_device_from_interface(intf) == "" then
				ucic:set("network",intf .. "_dev","device")
				ucic:set("network",intf .. "_dev","name",device_qmi)
			end
		-- 设置ModemManager设备配置
		elseif typeintf == "" and device ~= "" and proto == "modemmanager" then
			ucic:set("network",intf,"device",device_manager)
			if uci_device_from_interface(intf) == "" then
				ucic:set("network",intf .. "_dev","device")
				ucic:set("network",intf .. "_dev","name",device_manager)
			end
		 -- 设置静态接口配置
		elseif typeintf == "" and ifname ~= "" and proto == "static" then
			ucic:set("network",intf,"device",ifname)
			if uci_device_from_interface(intf) == "" then
				ucic:set("network",intf .. "_dev","device")
				ucic:set("network",intf .. "_dev","name",ifname)
			end
		end
		-- 清理非macvlan接口的macvlan相关配置
		if typeintf ~= "macvlan" then
			if ucic:get("network",intf .. "_dev","type") == "macvlan" then
				ucic:delete("network",intf .. "_dev","type")
				ucic:delete("network",intf .. "_dev","mode")
				ucic:delete("network",intf .. "_dev","ifname")
				ucic:delete("network",intf .. "_dev","macaddr")
			end
			ucic:delete("network",intf,"masterintf")
		end
		-- 设置PPPoE选项
		if proto == "pppoe" then
			ucic:set("network",intf,"pppd_options","persist maxfail 0")
		end
		-- 设置协议
		if proto ~= "other" then
			ucic:set("network",intf,"proto",proto)
		end
		-- 获取并设置设备配置
		uci_device = uci_device_from_interface(intf)
		if uci_device == "" then
			uci_device = intf .. "_dev"
			ucic:set("network",uci_device,"device")
		end
		ucic:set("network",uci_device,"ttl",ttl)

		-- 设置移动网络配置
		ucic:set("network",intf,"apn",apn)
		ucic:set("network",intf,"pincode",pincode)
		ucic:set("network",intf,"delay",delay)
		ucic:set("network",intf,"username",username)
		ucic:set("network",intf,"password",password)
		ucic:set("network",intf,"auth",auth)
		ucic:set("network",intf,"mode",mode)
		ucic:set("network",intf,"label",label)
		ucic:set("network",intf,"ipv6",ipv6)

		-- 设置多路径配置
		if lan == "1" then
			ucic:set("network",intf,"multipath","off")
		else
			ucic:set("network",intf,"multipath",multipath)
			ucic:set("openmptcprouter",intf,"multipath",multipath)
		end

		-- 设置路由和DNS配置
		ucic:set("network",intf,"defaultroute",0)
		ucic:set("network",intf,"peerdns",0)
		ucic:set("network",intf,"delegate",0)

		-- 设置IPv4配置
		if ipaddr ~= "" then
			ucic:set("network",intf,"ipaddr",ipaddr:gsub("%s+", ""))
			ucic:set("network",intf,"netmask",netmask:gsub("%s+", ""))
			ucic:set("network",intf,"gateway",gateway:gsub("%s+", ""))
		else
			ucic:set("network",intf,"ipaddr","")
			ucic:set("network",intf,"netmask","")
			ucic:set("network",intf,"gateway","")
		end

		-- 设置IPv6配置
		if ip6addr ~= "" then
			ucic:set("network",intf,"ip6addr",ip6addr:gsub("%s+", ""))
			ucic:set("network",intf,"ip6gw",ip6gw:gsub("%s+", ""))
			ucic:set("network",intf,"ipv6","1")
		elseif proto ~= "static" and proto ~= "dhcp" and disableipv6 ~= "1" then
			ucic:set("network",intf,"ip6addr","")
			ucic:set("network",intf,"ip6gw","")
			ucic:set("network",intf,"ipv6","1")
		else
			ucic:set("network",intf,"ip6addr","")
			ucic:set("network",intf,"ip6gw","")
			ucic:set("network",intf,"ipv6","0")
		end
		
		-- 设置DHCPv6配置
		if proto == "dhcpv6" then
			ucic:set("network",intf,"reqaddress","try")
			ucic:set("network",intf,"reqprefix","no")
			ucic:set("network",intf,"iface_map","0")
			ucic:set("network",intf,"iface_dslite","0")
			ucic:set("network",intf,"iface_464xlate","0")
			ucic:set("network",intf,"ipv6","1")
		end

		-- 清理OpenMPTCProuter接口配置
		ucic:delete("openmptcprouter",intf,"lc")
		ucic:save("openmptcprouter")

		-- 获取接口的VPN多路径设置
		local multipathvpn = luci.http.formvalue("multipathvpn.%s.enabled" % intf) or "0"
		ucic:set("openmptcprouter",intf,"multipathvpn",multipathvpn)
		ucic:save("openmptcprouter")

		-- 获取接口的下载、上传速度和测速设置
		local downloadspeed = luci.http.formvalue("cbid.sqm.%s.download" % intf) or "0"
		local uploadspeed = luci.http.formvalue("cbid.sqm.%s.upload" % intf) or "0"
		local testspeed = luci.http.formvalue("cbid.sqm.%s.testspeed" % intf) or "0"

		-- 检查并初始化QoS设置
		local qos_settings = ucic:get("qos",intf) or ""
		if qos_settings == "" then
			ucic:set("qos",intf,"interface")
			ucic:set("qos",intf,"classgroup","Default")
			ucic:set("qos",intf,"enabled","0")
			ucic:set("qos",intf,"upload","4000")
			ucic:set("qos",intf,"download","100000")
		end

		-- 检查并初始化SQM设置
		local sqm_settings = ucic:get("sqm",intf) or ""
		if sqm_settings == "" then
			local defif = get_device(intf)
			if defif == "" then
				defif = ucic:get("network",intf,"device") or ""
				if defif == "" then
					defif = ucic:get("network",intf,"ifname") or ""
				end
			end
			ucic:set("sqm",intf,"queue")
			ucic:set("sqm",intf,"interface",defif)
			ucic:set("sqm",intf,"qdisc","cake")
			ucic:set("sqm",intf,"script","piece_of_cake.qos")
			ucic:set("sqm",intf,"qdisc_advanced","0")
			ucic:set("sqm",intf,"linklayer","atm")
			ucic:set("sqm",intf,"overhead","44")
			ucic:set("sqm",intf,"enabled","0")
			ucic:set("sqm",intf,"debug_logging","0")
			ucic:set("sqm",intf,"verbosity","5")
			ucic:set("sqm",intf,"download","0")
			ucic:set("sqm",intf,"upload","0")
			ucic:set("sqm",intf,"iqdisc_opts","autorate-ingress")
			--ucic:set("sqm",intf,"iqdisc_opts","autorate-ingress dual-dsthost")
			--ucic:set("sqm",intf,"eqdisc_opts","dual-srchost")
		end

		-- 设置SQM自动速率选项
		ucic:set("sqm",intf,"autorate",sqmautorate)

		-- 如果启用了自动速率，使用CAKE算法
		if sqmautorate == "1" then
			ucic:set("sqm",intf,"qdisc","cake")
			ucic:set("sqm",intf,"script","piece_of_cake.qos")
		end
		-- 保存测速设置
		ucic:set("openmptcprouter",intf,"testspeed",testspeed)
		if testspeed == "1" then
			ucic:delete("openmptcprouter",intf,"testspeed_lc")
		end
		-- 配置下载速度
		if downloadspeed ~= "0" and downloadspeed ~= "" then
			-- 如果启用了自动速率且下载速度有变化
			if sqmautorate == "1" and (ucic:get("network",intf,"downloadspeed") ~= downloadspeed or ucic:get("sqm",intf,"max_download") == "" or ucic:get("sqm",intf,"download") == "0") then
				-- 设置SQM下载速度为最大速度的65%
				ucic:set("sqm",intf,"download",math.ceil(downloadspeed*65/100))
				-- 最小下载速度为最大速度的10%
				ucic:set("sqm",intf,"min_download",math.ceil(downloadspeed*10/100))
				ucic:set("sqm",intf,"max_download",downloadspeed)
			elseif sqmautorate ~= "1" then
				-- 非自动速率模式下，设置为最大速度的95%
				ucic:set("sqm",intf,"download",math.ceil(downloadspeed*95/100))
			end
			-- 保存下载速度设置
			ucic:set("network",intf,"downloadspeed",downloadspeed)
			ucic:set("qos",intf,"download",math.ceil(downloadspeed*95/100))
			downloadmax = downloadmax + tonumber(downloadspeed)
		else
			-- 如果下载速度为0，删除相关设置
			ucic:delete("network",intf,"downloadspeed")
			ucic:set("sqm",intf,"download","0")
			ucic:set("qos",intf,"download","0")
		end

		-- 配置上传速度(逻辑与下载速度类似)
		if uploadspeed ~= "0" and uploadspeed ~= "" then
			if sqmautorate == "1" and (ucic:get("network",intf,"uploadspeed") ~= uploadspeed or ucic:get("sqm",intf,"max_upload") == "" or ucic:get("sqm",intf,"upload") == "0") then
				ucic:set("sqm",intf,"upload",math.ceil(uploadspeed*65/100))
				ucic:set("sqm",intf,"min_upload",math.ceil(uploadspeed*10/100))
				ucic:set("sqm",intf,"max_upload",uploadspeed)
			elseif sqmautorate ~= "1" then
				ucic:set("sqm",intf,"upload",math.ceil(uploadspeed*95/100))
			end
			ucic:set("network",intf,"uploadspeed",uploadspeed)
			ucic:set("qos",intf,"upload",math.ceil(uploadspeed*95/100))
			uploadmax = uploadmax + tonumber(uploadspeed)
		else
			ucic:delete("network",intf,"uploadspeed")
			ucic:set("sqm",intf,"upload","0")
			ucic:set("qos",intf,"upload","0")
		end

		-- 配置SQM启用状态
		if sqmenabled == "1" then
			-- 启用SQM时设置队列选项
			ucic:set("sqm",intf,"iqdisc_opts","autorate-ingress")
			--ucic:set("sqm",intf,"iqdisc_opts","autorate-ingress dual-dsthost")
			--ucic:set("sqm",intf,"eqdisc_opts","dual-srchost")
			ucic:set("sqm",intf,"enabled","1")
		else
			ucic:set("sqm",intf,"enabled","0")
		end

		-- 配置QoS启用状态
		if qosenabled == "1" then
			ucic:set("qos",intf,"enabled","1")
		else
			ucic:set("qos",intf,"enabled","0")
		end
	end
	-- Disable multipath on LAN, VPN and loopback
	-- 在LAN、VPN和环回接口上禁用多路径
	ucic:set("network","loopback","multipath","off")
	ucic:set("network","lan","multipath","off")
	ucic:set("network","omr6in4","multipath","off")
	ucic:set("network","omrvpn","multipath","off")

	-- 保存所有配置更改
	ucic:save("sqm")
	ucic:commit("sqm")
	ucic:save("qos")
	ucic:commit("qos")
	ucic:save("network")
	ucic:commit("network")

	--local ut = require "luci.util"
	--local result = ut.ubus("openmptcprouter", "set_ipv6_state", { disable_ipv6 = disableipv6 })
	-- 设置ULA前缀
	local ula = luci.http.formvalue("ula") or ""
	ucic:set("network","globals","ula_prefix",ula)

	-- Get VPN set by default
	-- 配置默认VPN设置
	local default_vpn = luci.http.formvalue("default_vpn") or "glorytun_tcp"
	local vpn_port = ""
	local vpn_intf = ""
	-- 根据不同VPN类型设置端口和接口
	if default_vpn:match("^glorytun.*") then
		vpn_port = 65001
		vpn_intf = "tun0"
		--ucic:set("network","omrvpn","proto","dhcp")
		ucic:set("network","omrvpn","proto","none")
	elseif default_vpn == "mlvpn" then
		vpn_port = 65201
		vpn_intf = "mlvpn0"
		ucic:set("network","omrvpn","proto","dhcp")
	elseif default_vpn == "ubond" then
		vpn_port = 65251
		vpn_intf = "ubond0"
		ucic:set("network","omrvpn","proto","dhcp")
	elseif default_vpn == "dsvpn" then
		vpn_port = 65011
		vpn_intf = "tun0"
		ucic:set("network","omrvpn","proto","none")
	elseif default_vpn == "openvpn" then
		vpn_port = 65301
		vpn_intf = "tun0"
		ucic:set("network","omrvpn","proto","dhcp")
	elseif default_vpn == "openvpn_bonding" then
		vpn_intf = "bonding-omrvpn"
		ucic:set("network","omrvpn","proto","bonding")
	end
	--if downloadmax ~= 0 and uploadmax ~= 0 then
	--	ucic:set("sqm","omrvpn","enabled","1")
	--	ucic:set("sqm","omrvpn","max_download",downloadmax)
	--	ucic:set("sqm","omrvpn","max_upload",uploadmax)
	--	ucic:set("sqm","omrvpn","download",math.ceil(downloadmax*50/100))
	--	ucic:set("sqm","omrvpn","min_download",math.ceil(downloadmax*8/100))
	--	ucic:set("sqm","omrvpn","upload",math.ceil(uploadmax*50/100))
	--	ucic:set("sqm","omrvpn","min_upload",math.ceil(uploadmax*8/100))
	--else
	--	ucic:set("sqm","omrvpn","enabled","0")
	--end

	-- 禁用omrvpn的SQM功能
	ucic:set("sqm","omrvpn","enabled","0")
	ucic:set("sqm","omrvpn","download","0")
	ucic:set("sqm","omrvpn","upload","0")

	-- 如果VPN接口存在，更新网络和SQM配置
	if vpn_intf ~= "" then
		ucic:set("network","omrvpn","device",vpn_intf)
		ucic:set("sqm","omrvpn","interface",vpn_intf)
		ucic:save("network")
		ucic:commit("network")
		ucic:save("sqm")
		ucic:commit("sqm")
	end

	-- 获取是否强制重新获取配置的标志
	local force_retrieve = luci.http.formvalue("forceretrieve") or ""
	-- Retrieve all server settings
	local serversnb = 0
	local disablednb = 0
	-- 获取所有服务器设置
	local servers = luci.http.formvaluetable("server")
	for server, _ in pairs(servers) do
		-- 获取服务器IP列表
		local serverips = luci.http.formvaluetable("%s.serverip" % server) or {}
		local aserverips = {}
		-- 过滤有效IP地址
		for _, ip in pairs(serverips) do
			if ip ~= "" and ip ~= nil then
				table.insert(aserverips,ip)
			end
		end
		-- 如果禁用IPv6，移除第二个IP地址（通常是IPv6地址）
		if disableipv6 == "1" then
			if table.getn(aserverips) == 2 then
				table.remove(aserverips, 2)
			end
		end

		-- 获取主服务器设置
		local master = luci.http.formvalue("master") or ""

		-- OpenMPTCProuter VPS
		-- 获取OpenMPTCProuter VPS配置
		local openmptcprouter_vps_key = luci.http.formvalue("%s.openmptcprouter_vps_key" % server) or ""
		local openmptcprouter_vps_username = luci.http.formvalue("%s.openmptcprouter_vps_username" % server) or ""
		local openmptcprouter_vps_disabled = luci.http.formvalue("%s.openmptcprouter_vps_disabled" % server) or ""
		-- 如果是主服务器或第一个服务器
		if master == server or (master == "" and serversnb == 0) then
			-- 检查是否需要重新获取配置
			if ucic:get("openmptcprouter",server,"password") == "" or ucic:get("openmptcprouter",server,"password") ~= openmptcprouter_vps_key or ucic:get("openmptcprouter",server,"username") ~= openmptcprouter_vps_username or force_retrieve ~= "" then
				ucic:set("openmptcprouter",server,"get_config","1")
			end
			-- 设置主服务器标志
			ucic:set("openmptcprouter",server,"master","1")
			ucic:set("openmptcprouter",server,"current","1")
			ucic:set("openmptcprouter",server,"backup","0")
			-- 设置Xray的shadowsocks邮箱
			ucic:set("xray","omrout","s_shadowsocks_email",openmptcprouter_vps_username:gsub("%s+", ""))
		else
			-- 非主服务器设置
			ucic:set("openmptcprouter",server,"get_config","0")
			ucic:set("openmptcprouter",server,"master","0")
			ucic:set("openmptcprouter",server,"current","0")
			ucic:set("openmptcprouter",server,"backup","1")
		end
		-- 更新禁用服务器计数
		if openmptcprouter_vps_disabled == "1" then
			disablednb = disablednb + 1
		end
		-- 更新有效服务器计数
		if next(aserverips) ~= nil then
			serversnb = serversnb + 1
		end
		-- 保存服务器基本配置
		ucic:set("openmptcprouter",server,"server")
		ucic:set("openmptcprouter",server,"username",openmptcprouter_vps_username:gsub("%s+", ""))
		ucic:set("openmptcprouter",server,"password",openmptcprouter_vps_key:gsub("%s+", ""))
		ucic:set("openmptcprouter",server,"disabled",openmptcprouter_vps_disabled)
		-- 如果IP列表有变化，更新配置
		if ucic:get_list("openmptcprouter",server,"ip") ~= aserverips then
			ucic:set_list("openmptcprouter",server,"ip",aserverips)
			if ucic:get("openmptcprouter",server,"master") == "1" then
				ucic:set("openmptcprouter",server,"get_config","1")
			end
		end
		-- 设置服务器端口和防火墙标志
		ucic:set("openmptcprouter",server,"port","65500")
		ucic:set("openmptcprouter",server,"set_firewall","1")
		-- 清除检测到的IP地址
		ucic:delete("openmptcprouter",server,"detected_ss_ipv4")
		ucic:delete("openmptcprouter",server,"detected_ss_ipv6")
		ucic:delete("openmptcprouter",server,"detected_public_ipv4")
		ucic:delete("openmptcprouter",server,"detected_public_ipv6")
		ucic:save("openmptcprouter")
	end

	-- Get VPN used for MPTCP over VPN
	-- 获取MPTCP over VPN使用的VPN类型
	local mptcpovervpn_vpn = luci.http.formvalue("mptcpovervpn_vpn") or "wireguard"
	ucic:set("openmptcprouter","settings","mptcpovervpn",mptcpovervpn_vpn)
	ucic:save("openmptcprouter")

	-- Get Country
	-- 获取国家/地区设置
	local country = luci.http.formvalue("country") or "world"
	ucic:set("openmptcprouter","settings","country",country)
	ucic:save("openmptcprouter")

	-- Get DNS64
	-- 获取DNS64设置
	local dns64 = luci.http.formvalue("dns64") or "0"
	ucic:set("openmptcprouter","settings","dns64",dns64)
	ucic:save("openmptcprouter")
	if dns64 == "1" then
		-- 启用DNS64并禁用验证器
		ucic:set("unbound","ub_main","dns64","1")
		ucic:set("unbound","ub_main","validator","0")
	else
		-- 禁用DNS64
		ucic:set("unbound","ub_main","dns64","0")
	
	end
	ucic:save("unbound")
	ucic:commit("unbound")

	-- Get Proxy set by default
	-- 获取默认代理设置
	local default_proxy = luci.http.formvalue("default_proxy") or "shadowsocks-rust"
	-- 根据选择的代理类型配置相应的服务
	if default_proxy == "shadowsocks" and serversnb > 0 and serversnb > disablednb then
		--ucic:set("shadowsocks-libev","sss0","disabled","0")
		-- 配置shadowsocks-libev
		ucic:set("v2ray","main","enabled","0")
		ucic:set("xray","main","enabled","0")
		-- 启用所有shadowsocks-libev服务器
		ucic:foreach("shadowsocks-libev", "server", function(s)
			local sectionname = s[".name"]
			if sectionname:match("^sss.*") and ucic:get("shadowsocks-libev",sectionname,"server") ~= "" then
				ucic:set("shadowsocks-libev",sectionname,"disabled","0")
			end
		end)
		-- 禁用所有shadowsocks-rust服务器
		ucic:foreach("shadowsocks-rust", "server", function(s)
			local sectionname = s[".name"]
			ucic:set("shadowsocks-rust",sectionname,"disabled","1")
		end)
	elseif default_proxy == "shadowsocks-rust" and serversnb > 0 and serversnb > disablednb then
		--ucic:set("shadowsocks-libev","sss0","disabled","0")
		-- 配置shadowsocks-rust
		ucic:set("v2ray","main","enabled","0")
		ucic:set("xray","main","enabled","0")
		-- 启用所有shadowsocks-rust服务器
		ucic:foreach("shadowsocks-rust", "server", function(s)
			local sectionname = s[".name"]
			if sectionname:match("^sss.*") and ucic:get("shadowsocks-rust",sectionname,"server") ~= "" then
				ucic:set("shadowsocks-rust",sectionname,"disabled","0")
			end
		end)
		-- 禁用所有shadowsocks-libev服务器
		ucic:foreach("shadowsocks-libev", "server", function(s)
			local sectionname = s[".name"]
			ucic:set("shadowsocks-libev",sectionname,"disabled","1")
		end)
	elseif (default_proxy == "v2ray" or default_proxy == "v2ray-vmess" or default_proxy == "v2ray-trojan" or default_proxy == "v2ray-socks") and serversnb > 0 and serversnb > disablednb then
		--ucic:set("shadowsocks-libev","sss0","disabled","1")
		-- 配置v2ray
		ucic:set("xray","main","enabled","0")
		ucic:set("v2ray","main","enabled","1")
		-- 根据代理类型设置协议
		if default_proxy == "v2ray" then
			ucic:set("v2ray","omrout","protocol","vless")
		elseif default_proxy == "v2ray-vmess" then
			ucic:set("v2ray","omrout","protocol","vmess")
		elseif default_proxy == "v2ray-trojan" then
			ucic:set("v2ray","omrout","protocol","trojan")
		elseif default_proxy == "v2ray-socks" then
			ucic:set("v2ray","omrout","protocol","socks")
		end
		-- 禁用所有shadowsocks服务器
		ucic:foreach("shadowsocks-libev", "server", function(s)
			local sectionname = s[".name"]
			ucic:set("shadowsocks-libev",sectionname,"disabled","1")
		end)
		ucic:foreach("shadowsocks-rust", "server", function(s)
			local sectionname = s[".name"]
			ucic:set("shadowsocks-rust",sectionname,"disabled","1")
		end)
	elseif (default_proxy == "xray" or default_proxy == "xray-vless-reality" or default_proxy == "xray-vmess" or default_proxy == "xray-trojan" or default_proxy == "xray-shadowsocks" or default_proxy == "xray-socks") and serversnb > 0 and serversnb > disablednb then
		--ucic:set("shadowsocks-libev","sss0","disabled","1")
		-- 配置xray
		ucic:set("v2ray","main","enabled","0")
		ucic:set("xray","main","enabled","1")
		-- 根据代理类型设置协议
		if default_proxy == "xray" then
			ucic:set("xray","omrout","protocol","vless")
		elseif default_proxy == "xray-vless-reality" then
			ucic:set("xray","omrout","protocol","vless-reality")
		elseif default_proxy == "xray-vmess" then
			ucic:set("xray","omrout","protocol","vmess")
		elseif default_proxy == "xray-trojan" then
			ucic:set("xray","omrout","protocol","trojan")
		elseif default_proxy == "xray-socks" then
			ucic:set("xray","omrout","protocol","socks")
		elseif default_proxy == "xray-shadowsocks" then
			ucic:set("xray","omrout","protocol","shadowsocks")
		end
		-- 禁用所有shadowsocks服务器
		ucic:foreach("shadowsocks-libev", "server", function(s)
			local sectionname = s[".name"]
			ucic:set("shadowsocks-libev",sectionname,"disabled","1")
		end)
		ucic:foreach("shadowsocks-rust", "server", function(s)
			local sectionname = s[".name"]
			ucic:set("shadowsocks-rust",sectionname,"disabled","1")
		end)
	else
		--ucic:set("shadowsocks-libev","sss0","disabled","1")
		-- 如果没有选择代理或服务器数量不足，禁用所有代理服务
		ucic:set("v2ray","main","enabled","0")
		ucic:set("xray","main","enabled","0")
		ucic:foreach("shadowsocks-libev", "server", function(s)
			local sectionname = s[".name"]
			ucic:set("shadowsocks-libev",sectionname,"disabled","1")
		end)
		ucic:foreach("shadowsocks-rust", "server", function(s)
			local sectionname = s[".name"]
			ucic:set("shadowsocks-rust",sectionname,"disabled","1")
		end)
	end
	-- 保存代理设置
	ucic:set("openmptcprouter","settings","proxy",default_proxy)
	ucic:save("openmptcprouter")
	ucic:save("shadowsocks-libev")
	ucic:save("shadowsocks-rust")
	ucic:save("v2ray")
	ucic:save("xray")
	-- 清理shadowsocks服务器配置
	ucic:foreach("shadowsocks-libev","server", function(s)
		local sectionname = s[".name"]
		if sectionname:match("^sss.*") then
			ucic:delete("shadowsocks-libev",sectionname,"ip")
			ucic:set("shadowsocks-libev",sectionname,"disabled","1")
			ucic:delete("openmptcprouter","omr","ss_" .. sectionname)
		end
	end)
	ucic:foreach("shadowsocks-rust","server", function(s)
		local sectionname = s[".name"]
		if sectionname:match("^sss.*") then
			ucic:delete("shadowsocks-rust",sectionname,"ip")
			ucic:set("shadowsocks-rust",sectionname,"disabled","1")
			ucic:delete("openmptcprouter","omr","ss_" .. sectionname)
		end
	end)

	-- 初始化服务器列表
	local ss_servers_nginx = {}
	local ss_servers_ha = {}
	local vpn_servers = {}
	local k = 0
	local ss_ip

	-- 配置每个服务器
	for server, _ in pairs(servers) do
		local master = luci.http.formvalue("master") or ""
		local server_ips = luci.http.formvaluetable("%s.serverip" % server) or {}
		local server_ip = ""
		-- 获取第一个有效IP
		for _, ip in pairs(server_ips) do
			if server_ip == "" and ip ~= "" and ip ~= nil then
				server_ip=ip
			end
		end
		-- We have an IP, so set it everywhere
		-- 如果有有效IP且服务器未禁用
		if server_ip ~= "" and server_ip ~= nil and luci.http.formvalue("%s.openmptcprouter_vps_disabled" % server) ~= "1" then
			-- Check if we have more than one IP, in this case use Nginx HA
			-- 检查是否有多个IP，使用Nginx HA
			if serversnb > 1 then
				if master == server then
					-- 配置主服务器IP
					ss_ip=server_ip
					-- 设置各种VPN服务的主机地址
					--ucic:set("shadowsocks-libev","sss0","server",server_ip)
					ucic:set("glorytun","vpn","host",server_ip)
					ucic:set("glorytun-udp","vpn","host",server_ip)
					ucic:set("dsvpn","vpn","host",server_ip)
					ucic:set("mlvpn","general","host",server_ip)
					ucic:set("ubond","general","host",server_ip)
					-- 设置v2ray地址
					ucic:set("v2ray","omrout","s_vmess_address",server_ip)
					ucic:set("v2ray","omrout","s_vless_address",server_ip)
					ucic:set("v2ray","omrout","s_trojan_address",server_ip)
					ucic:set("v2ray","omrout","s_socks_address",server_ip)
					-- 设置xray地址
					ucic:set("xray","omrout","s_vmess_address",server_ip)
					ucic:set("xray","omrout","s_vless_address",server_ip)
					ucic:set("xray","omrout","s_vless_reality_address",server_ip)
					ucic:set("xray","omrout","s_trojan_address",server_ip)
					ucic:set("xray","omrout","s_socks_address",server_ip)
					ucic:set("xray","omrout","s_shadowsocks_address",server_ip)
					-- 更新OpenVPN远程地址
					ucic:foreach("openvpn","openvpn", function(s)
						local sectionname = s[".name"]
						if sectionname:match("^omr.*") then
							luci.sys.call("uci -q del openvpn." .. sectionname .. ".remote")
							luci.sys.call("uci -q add_list openvpn." .. sectionname .. ".remote=" .. server_ip)
						end
					end)
					--luci.sys.call("uci -q del openvpn.omr.remote")
					--luci.sys.call("uci -q add_list openvpn.omr.remote=" .. server_ip)
					-- 设置QoS主机地址
					ucic:set("qos","serverin","srchost",server_ip)
					ucic:set("qos","serverout","dsthost",server_ip)
					-- 配置shadowsocks服务器
					local nbip = 0
					for _, ssip in pairs(server_ips) do
						-- 设置shadowsocks-libev服务器
						ucic:set("shadowsocks-libev","sss" .. nbip,"server",ssip)
						if default_proxy == "shadowsocks" and serversnb > disablednb and ssip ~= "" then
							ucic:set("shadowsocks-libev","sss" .. nbip,"disabled","0")
						end
						-- 设置shadowsocks-rust服务器
						ucic:set("shadowsocks-rust","sss" .. nbip,"server",ssip)
						if default_proxy == "shadowsocks-rust" and serversnb > disablednb and ssip ~= "" then
							ucic:set("shadowsocks-rust","sss" .. nbip,"disabled","0")
						end
						nbip = nbip + 1
						-- 如果禁用IPv6且已有一个IP，跳出循环
						if disableipv6 == "1" and nbip > 0 then
							ucic:set("shadowsocks-libev","sss" .. nbip,"disabled","1")
							ucic:set("shadowsocks-rust","sss" .. nbip,"disabled","1")
							break
						end
					end
					-- 如果只有一个IP，禁用第二个服务器
					if nbip == 1 then
						--ucic:set("shadowsocks-libev","sss" .. nbip,"server",server_ip)
						ucic:set("shadowsocks-libev","sss" .. nbip,"disabled","1")
						ucic:set("shadowsocks-rust","sss" .. nbip,"disabled","1")
					end
				end
				k = k + 1
				-- 禁用Nginx HA和HAProxy
				ucic:set("nginx-ha","ShadowSocks","enable","0")
				ucic:set("nginx-ha","VPN","enable","0")
				ucic:set("haproxy-tcp","general","enable","0")
				ucic:set("openmptcprouter","settings","ha","1")
			else
				-- 单服务器配置
				ucic:set("openmptcprouter","settings","ha","0")
				ucic:set("nginx-ha","ShadowSocks","enable","0")
				ucic:set("nginx-ha","VPN","enable","0")
				--ucic:set("shadowsocks-libev","sss0","server",server_ip)
				-- 设置各种VPN服务的主机地址
				ucic:set("glorytun","vpn","host",server_ip)
				ucic:set("glorytun-udp","vpn","host",server_ip)
				ucic:set("dsvpn","vpn","host",server_ip)
				ucic:set("mlvpn","general","host",server_ip)
				ucic:set("ubond","general","host",server_ip)
				-- 设置v2ray地址
				ucic:set("v2ray","omrout","s_vmess_address",server_ip)
				ucic:set("v2ray","omrout","s_vless_address",server_ip)
				ucic:set("v2ray","omrout","s_trojan_address",server_ip)
				ucic:set("v2ray","omrout","s_socks_address",server_ip)
				-- 设置xray地址
				ucic:set("xray","omrout","s_vmess_address",server_ip)
				ucic:set("xray","omrout","s_vless_address",server_ip)
				ucic:set("xray","omrout","s_vless_reality_address",server_ip)
				ucic:set("xray","omrout","s_trojan_address",server_ip)
				ucic:set("xray","omrout","s_socks_address",server_ip)
				ucic:set("xray","omrout","s_shadowsocks_address",server_ip)
				-- 更新OpenVPN远程地址
				ucic:foreach("openvpn","openvpn", function(s)
					local sectionname = s[".name"]
					if sectionname:match("^omr.*") then
						luci.sys.call("uci -q del openvpn." .. sectionname .. ".remote")
						luci.sys.call("uci -q add_list openvpn." .. sectionname .. ".remote=" .. server_ip)
					end
				end)
				--luci.sys.call("uci -q del openvpn.omr.remote")
				--luci.sys.call("uci -q add_list openvpn.omr.remote=" .. server_ip)
				-- 设置QoS主机地址
				ucic:set("qos","serverin","srchost",server_ip)
				ucic:set("qos","serverout","dsthost",server_ip)
				local nbip = 0
				-- 配置shadowsocks服务器
				for _, ssip in pairs(server_ips) do
					-- 设置shadowsocks-libev服务器
					ucic:set("shadowsocks-libev","sss" .. nbip,"server",ssip)
					if default_proxy == "shadowsocks" and serversnb > disablednb and ssip ~= "" then
						ucic:set("shadowsocks-libev","sss" .. nbip,"disabled","0")
					end
					-- 设置shadowsocks-rust服务器
					ucic:set("shadowsocks-rust","sss" .. nbip,"server",ssip)
					if default_proxy == "shadowsocks-rust" and serversnb > disablednb and ssip ~= "" then
						ucic:set("shadowsocks-rust","sss" .. nbip,"disabled","0")
					end
					nbip = nbip + 1
					-- 如果禁用IPv6且已有一个IP，跳出循环
					if disableipv6 == "1" and nbip > 0 then
						break
					end
				end
				-- 如果只有一个IP，禁用第二个服务器
				if nbip == 1 then
				--	ucic:set("shadowsocks-libev","sss" .. nbip,"server",server_ip)
					ucic:set("shadowsocks-libev","sss" .. nbip,"disabled","1")
					ucic:set("shadowsocks-rust","sss" .. nbip,"disabled","1")
				end
			end
		end
	end

	-- 保存所有配置更改
	ucic:save("qos")
	ucic:commit("qos")
	ucic:save("nginx-ha")
	ucic:commit("nginx-ha")
	ucic:save("openvpn")
	--ucic:commit("openvpn")
	ucic:save("mlvpn")
	ucic:save("ubond")
	ucic:save("v2ray")
	ucic:save("xray")
	--ucic:commit("mlvpn")
	ucic:save("dsvpn")
	--ucic:commit("dsvpn")
	ucic:save("glorytun")
	ucic:save("glorytun-udp")
	--ucic:commit("glorytun")
	ucic:save("shadowsocks-libev")
	ucic:save("shadowsocks-rust")
	--ucic:commit("shadowsocks-libev")

	-- 获取加密设置
	local encryption = luci.http.formvalue("encryption")
	if encryption == "none" then
		-- 无加密设置
		ucic:set("openmptcprouter","settings","encryption","none")
		-- 设置shadowsocks无加密
		ucic:set("shadowsocks-libev","sss0","method","none")
		ucic:set("shadowsocks-libev","sss1","method","none")
		ucic:set("shadowsocks-rust","sss0","method","none")
		ucic:set("shadowsocks-rust","sss1","method","none")
		-- 遍历所有OpenVPN配置，将所有以omr开头的VPN连接的加密方式设置为none
		ucic:foreach("openvpn","openvpn", function(s)
			local sectionname = s[".name"]
			if sectionname:match("^omr.*") then
				ucic:set("openvpn",sectionname,"cipher","none")
			end
		end)
		--ucic:set("openvpn","omr","cipher","none")
		-- 设置MLVPN使用明文数据传输
		ucic:set("mlvpn","general","cleartext_data","1")
		-- 设置V2Ray所有协议的安全选项为none
		ucic:set("v2ray","omrout","s_vmess_user_security","none")
		ucic:set("v2ray","omrout","s_vless_user_security","none")
		ucic:set("v2ray","omrout","s_trojan_user_security","none")
		ucic:set("v2ray","omrout","s_socks_user_security","none")
		-- 设置XRay所有协议的安全选项为none
		ucic:set("xray","omrout","s_vmess_user_security","none")
		ucic:set("xray","omrout","s_vless_user_security","none")
		ucic:set("xray","omrout","s_vless_reality_user_security","none")
		ucic:set("xray","omrout","s_trojan_user_security","none")
		ucic:set("xray","omrout","s_socks_user_security","none")
		--ucic:set("xray","omrout","s_shadowsocks_method","none")
		-- 设置XRay的Shadowsocks加密方法为2022-blake3-aes-256-gcm
		ucic:set("xray","omrout","s_shadowsocks_method","2022-blake3-aes-256-gcm")
	elseif encryption == "aes-256-gcm" then
		-- 设置OpenMPTCProuter的加密设置
		ucic:set("openmptcprouter","settings","encryption","aes-256-gcm")
		-- 设置Shadowsocks-libev的加密方法
		ucic:set("shadowsocks-libev","sss0","method","aes-256-gcm")
		ucic:set("shadowsocks-libev","sss1","method","aes-256-gcm")
		-- 禁用Glorytun的chacha20加密
		ucic:set("glorytun","vpn","chacha20","0")
		ucic:set("glorytun-udp","vpn","chacha","0")
		-- 设置OpenVPN的加密方式为AES-256-GCM
		ucic:foreach("openvpn","openvpn", function(s)
			local sectionname = s[".name"]
			if sectionname:match("^omr.*") then
				ucic:set("openvpn",sectionname,"cipher","AES-256-GCM")
			end
		end)
		--ucic:set("openvpn","omr","cipher","AES-256-GCM")
		-- 禁用MLVPN的明文数据传输
		ucic:set("mlvpn","general","cleartext_data","0")
		-- 设置V2Ray所有协议的安全选项为aes-128-gcm
		ucic:set("v2ray","omrout","s_vmess_user_security","aes-128-gcm")
		ucic:set("v2ray","omrout","s_vless_user_security","aes-128-gcm")
		ucic:set("v2ray","omrout","s_trojan_user_security","aes-128-gcm")
		ucic:set("v2ray","omrout","s_socks_user_security","aes-128-gcm")
		-- 设置XRay所有协议的安全选项为aes-128-gcm
		ucic:set("xray","omrout","s_vmess_user_security","aes-128-gcm")
		ucic:set("xray","omrout","s_vless_user_security","aes-128-gcm")
		ucic:set("xray","omrout","s_vless_reality_user_security","aes-128-gcm")
		ucic:set("xray","omrout","s_trojan_user_security","aes-128-gcm")
		ucic:set("xray","omrout","s_socks_user_security","aes-128-gcm")
		-- 设置XRay和Shadowsocks-rust的加密方法
		ucic:set("xray","omrout","s_shadowsocks_method","2022-blake3-aes-256-gcm")
		ucic:set("shadowsocks-rust","sss0","method","2022-blake3-aes-256-gcm")
		ucic:set("shadowsocks-rust","sss1","method","2022-blake3-aes-256-gcm")
	elseif encryption == "aes-256-cfb" then
		-- 设置OpenMPTCProuter的加密设置
		ucic:set("openmptcprouter","settings","encryption","aes-256-cfb")
		-- 设置Shadowsocks-libev的加密方法
		ucic:set("shadowsocks-libev","sss0","method","aes-256-cfb")
		ucic:set("shadowsocks-libev","sss1","method","aes-256-cfb")
		-- 禁用Glorytun的chacha20加密
		ucic:set("glorytun","vpn","chacha20","0")
		ucic:set("glorytun-udp","vpn","chacha","0")
		-- 设置OpenVPN的加密方式为AES-256-CFB
		ucic:foreach("openvpn","openvpn", function(s)
			local sectionname = s[".name"]
			if sectionname:match("^omr.*") then
				ucic:set("openvpn",sectionname,"cipher","AES-256-CFB")
			end
		end)
		--ucic:set("openvpn","omr","cipher","AES-256-CFB")
		-- 禁用MLVPN的明文数据传输
		ucic:set("mlvpn","general","cleartext_data","0")
		-- 设置V2Ray所有协议的安全选项为aes-128-gcm
		ucic:set("v2ray","omrout","s_vmess_user_security","aes-128-gcm")
		ucic:set("v2ray","omrout","s_vless_user_security","aes-128-gcm")
		ucic:set("v2ray","omrout","s_trojan_user_security","aes-128-gcm")
		ucic:set("v2ray","omrout","s_socks_user_security","aes-128-gcm")
		-- 设置XRay所有协议的安全选项为aes-128-gcm
		ucic:set("xray","omrout","s_vmess_user_security","aes-128-gcm")
		ucic:set("xray","omrout","s_vless_user_security","aes-128-gcm")
		ucic:set("xray","omrout","s_vless_reality_user_security","aes-128-gcm")
		ucic:set("xray","omrout","s_trojan_user_security","aes-128-gcm")
		ucic:set("xray","omrout","s_socks_user_security","aes-128-gcm")
		-- 设置XRay和Shadowsocks-rust的加密方法
		ucic:set("xray","omrout","s_shadowsocks_method","2022-blake3-aes-256-gcm")
		ucic:set("shadowsocks-rust","sss0","method","2022-blake3-aes-256-gcm")
		ucic:set("shadowsocks-rust","sss1","method","2022-blake3-aes-256-gcm")
	elseif encryption == "chacha20-ietf-poly1305" then
		-- 设置OpenMPTCProuter的加密设置
		ucic:set("openmptcprouter","settings","encryption","chacha20")
		ucic:set("shadowsocks-libev","sss0","method","chacha20-ietf-poly1305")
		ucic:set("shadowsocks-libev","sss1","method","chacha20-ietf-poly1305")
		ucic:set("glorytun","vpn","chacha20","1")
		ucic:set("glorytun-udp","vpn","chacha","1")
		ucic:foreach("openvpn","openvpn", function(s)
			local sectionname = s[".name"]
			if sectionname:match("^omr.*") then
				ucic:set("openvpn",sectionname,"cipher","chacha20-poly1305")
			end
		end)
		--ucic:set("openvpn","omr","cipher","chacha20-poly1305")
		ucic:set("mlvpn","general","cleartext_data","0")
		ucic:set("v2ray","omrout","s_vmess_user_security","chacha20-poly1305")
		ucic:set("v2ray","omrout","s_vless_user_security","chacha20-poly1305")
		ucic:set("v2ray","omrout","s_trojan_user_security","chacha20-poly1305")
		ucic:set("v2ray","omrout","s_socks_user_security","chacha20-poly1305")
		ucic:set("xray","omrout","s_vmess_user_security","chacha20-poly1305")
		ucic:set("xray","omrout","s_vless_user_security","chacha20-poly1305")
		ucic:set("xray","omrout","s_vless_reality_user_security","chacha20-poly1305")
		ucic:set("xray","omrout","s_trojan_user_security","chacha20-poly1305")
		ucic:set("xray","omrout","s_socks_user_security","chacha20-poly1305")
		--ucic:set("xray","omrout","s_shadowsocks_method","2022-blake3-chacha20-poly1305")
		ucic:set("xray","omrout","s_shadowsocks_method","2022-blake3-aes-256-gcm")
		--ucic:set("shadowsocks-rust","sss0","method","2022-blake3-chacha20-poly1305")
		--ucic:set("shadowsocks-rust","sss1","method","2022-blake3-chacha20-poly1305")
		ucic:set("shadowsocks-rust","sss0","method","2022-blake3-aes-256-gcm")
		ucic:set("shadowsocks-rust","sss1","method","2022-blake3-aes-256-gcm")
	else
		ucic:set("openmptcprouter","settings","encryption","other")
	end

	-- 保存所有相关配置
	ucic:save("openvpn")
	ucic:save("glorytun")
	ucic:save("glorytun-udp")
	ucic:save("shadowsocks-libev")
	ucic:save("v2ray")
	ucic:save("xray")

	-- Set ShadowSocks settings
	-- 设置Shadowsocks配置
	local shadowsocks_key = luci.http.formvalue("shadowsocks_key")
	--local shadowsocks_disable = luci.http.formvalue("disableshadowsocks") or "0"
	--if disablednb == serversnb then
	--	shadowsocks_disable = 1
	--end
	-- 设置Shadowsocks-libev的密钥
	if shadowsocks_key ~= "" then
		ucic:set("shadowsocks-libev","sss0","key",shadowsocks_key)
		ucic:set("shadowsocks-libev","sss1","key",shadowsocks_key)
		--ucic:set("shadowsocks-libev","sss0","method","chacha20-ietf-poly1305")
		--ucic:set("shadowsocks-libev","sss0","server_port","65101")
		--ucic:set("shadowsocks-libev","sss0","disabled",shadowsocks_disable)

		-- 保存并应用Shadowsocks-libev配置
		ucic:save("shadowsocks-libev")
		ucic:commit("shadowsocks-libev")
		-- 如果Shadowsocks被禁用，则关闭防火墙规则
		if shadowsocks_disable == "1" then
			luci.sys.call("/etc/init.d/shadowsocks-libev rules_down >/dev/null 2>/dev/null")
		end
	else
		-- 如果没有服务器，则禁用Shadowsocks-libev
		if serversnb == 0 then
			ucic:set("shadowsocks-libev","sss0","disabled","1")
			ucic:set("shadowsocks-libev","sss1","disabled","1")
		end
		-- 清除Shadowsocks-libev的密钥
		ucic:set("shadowsocks-libev","sss0","key","")
		ucic:set("shadowsocks-libev","sss1","key","")
		-- 保存并应用Shadowsocks-libev配置
		ucic:save("shadowsocks-libev")
		ucic:commit("shadowsocks-libev")
		-- 关闭Shadowsocks-libev的防火墙规则
		luci.sys.call("/etc/init.d/shadowsocks-libev rules_down >/dev/null 2>/dev/null")
	end
	-- Set ShadowSocks 2022 settings
	-- 设置Shadowsocks 2022配置
	local shadowsocks2022_key = luci.http.formvalue("shadowsocks2022_key")
	-- 设置Shadowsocks-rust和XRay的密码
	if shadowsocks2022_key ~= "" then
		ucic:set("shadowsocks-rust","sss0","password",shadowsocks2022_key)
		ucic:set("shadowsocks-rust","sss1","password",shadowsocks2022_key)
		ucic:set("xray","omrout","s_shadowsocks_password",shadowsocks2022_key)
		ucic:save("shadowsocks-rust")
		ucic:commit("shadowsocks-rust")
		if shadowsocks_disable == "1" then
			luci.sys.call("/etc/init.d/shadowsocks-rust rules_down >/dev/null 2>/dev/null")
		end
	else
		-- 如果没有服务器，则禁用Shadowsocks-rust
		if serversnb == 0 then
			ucic:set("shadowsocks-rust","sss0","disabled","1")
			ucic:set("shadowsocks-rust","sss1","disabled","1")
		end
		-- 清除Shadowsocks-rust和XRay的密码
		ucic:set("shadowsocks-rust","sss0","password","")
		ucic:set("shadowsocks-rust","sss1","password","")
		ucic:set("xray","omrout","s_shadowsocks_password","")
		ucic:save("shadowsocks-rust")
		ucic:commit("shadowsocks-rust")
		-- 关闭Shadowsocks-rust的防火墙规则
		luci.sys.call("/etc/init.d/shadowsocks-rust rules_down >/dev/null 2>/dev/null")
	end

	-- Enable/disable v2ray/xray udp
	-- 启用/禁用V2Ray/XRay的UDP支持
	local v2rayudp = luci.http.formvalue("v2rayudp") or "0"
	-- 设置V2Ray的UDP重定向
	ucic:set("v2ray","main_transparent_proxy","redirect_udp",v2rayudp)
	ucic:save("v2ray")
	ucic:commit("v2ray")
	-- 设置XRay的UDP重定向
	ucic:set("xray","main_transparent_proxy","redirect_udp",v2rayudp)
	ucic:save("xray")
	ucic:commit("xray")
	-- 设置V2Ray用户ID
	local v2ray_user = luci.http.formvalue("v2ray_user")
	ucic:set("v2ray","omrout","s_vmess_user_id",v2ray_user)
	ucic:set("v2ray","omrout","s_vless_user_id",v2ray_user)
	ucic:set("v2ray","omrout","s_trojan_user_id",v2ray_user)
	ucic:set("v2ray","omrout","s_socks_user_id",v2ray_user)
	ucic:save("v2ray")
	ucic:commit("v2ray")
	-- 设置XRay用户ID
	local xray_user = luci.http.formvalue("xray_user")
	ucic:set("xray","omrout","s_vmess_user_id",xray_user)
	ucic:set("xray","omrout","s_vless_user_id",xray_user)
	ucic:set("xray","omrout","s_vless_reality_user_id",xray_user)
	ucic:set("xray","omrout","s_trojan_user_id",xray_user)
	ucic:set("xray","omrout","s_socks_user_id",xray_user)
	ucic:save("xray")
	ucic:commit("xray")

	-- 保存Shadowsocks相关配置
	ucic:save("shadowsocks-libev")
	ucic:commit("shadowsocks-libev")
	ucic:save("shadowsocks-rust")
	ucic:commit("shadowsocks-rust")


	-- Set Glorytun settings
	-- 设置Glorytun TCP配置
	if default_vpn:match("glorytun_tcp") and disablednb ~= serversnb then
		-- 如果选择Glorytun TCP且有可用服务器，则启用
		ucic:set("glorytun","vpn","enable",1)
	else
		ucic:set("glorytun","vpn","enable",0)
	end

	-- 设置Glorytun密钥和其他参数
	local glorytun_key = luci.http.formvalue("glorytun_key")
	if glorytun_key ~= "" then
		ucic:set("glorytun","vpn","port","65001")
		ucic:set("glorytun","vpn","key",glorytun_key)
		ucic:set("glorytun","vpn","mptcp",1)
		if default_vpn == "glorytun_tcp" then
			ucic:set("glorytun","vpn","proto","tcp")
			ucic:set("glorytun","vpn","localip","10.255.255.2")
			ucic:set("glorytun","vpn","remoteip","10.255.255.1")
			ucic:set("network","omr6in4","ipaddr","10.255.255.2")
			ucic:set("network","omr6in4","peeraddr","10.255.255.1")
			ucic:set("network","omrvpn","proto","none")
		end
	else
		ucic:set("glorytun","vpn","key","")
		--ucic:set("glorytun","vpn","enable",0)
		ucic:set("glorytun","vpn","proto","tcp")
	end
	ucic:save("glorytun")
	ucic:commit("glorytun")

	-- 设置Glorytun UDP配置
	if default_vpn:match("glorytun_udp") and disablednb ~= serversnb then
		ucic:set("glorytun-udp","vpn","enable",1)
	else
		ucic:set("glorytun-udp","vpn","enable",0)
	end

	local glorytun_key = luci.http.formvalue("glorytun_key")
	if glorytun_key ~= "" then
		ucic:set("glorytun-udp","vpn","port","65001")
		ucic:set("glorytun-udp","vpn","key",glorytun_key)
		if default_vpn == "glorytun_udp" then
			ucic:set("glorytun-udp","vpn","localip","10.255.254.2")
			ucic:set("glorytun-udp","vpn","remoteip","10.255.254.1")
			ucic:set("network","omr6in4","ipaddr","10.255.254.2")
			ucic:set("network","omr6in4","peeraddr","10.255.254.1")
			ucic:set("network","omrvpn","proto","none")
		end
	else
		ucic:set("glorytun-udp","vpn","key","")
	end
	ucic:save("glorytun-udp")
	ucic:commit("glorytun-udp")

	-- Set A Dead Simple VPN settings
	-- 设置DSVPN（A Dead Simple VPN）配置
	if default_vpn == "dsvpn" and disablednb ~= serversnb  then
		ucic:set("dsvpn","vpn","enable",1)
	else
		ucic:set("dsvpn","vpn","enable",0)
	end

	-- 设置DSVPN密钥和其他参数
	local dsvpn_key = luci.http.formvalue("dsvpn_key")
	if dsvpn_key ~= "" then
		ucic:set("dsvpn","vpn","port","65401")
		ucic:set("dsvpn","vpn","key",dsvpn_key)
		ucic:set("dsvpn","vpn","localip","10.255.251.2")
		ucic:set("dsvpn","vpn","remoteip","10.255.251.1")
		if default_vpn == "dsvpn" then
			ucic:set("network","omr6in4","ipaddr","10.255.251.2")
			ucic:set("network","omr6in4","peeraddr","10.255.251.1")
			ucic:set("network","omrvpn","proto","none")
		end
	else
		ucic:set("dsvpn","vpn","key","")
		--ucic:set("dsvpn","vpn","enable",0)
	end
	ucic:save("dsvpn")
	ucic:commit("dsvpn")

	-- Set MLVPN settings
	-- 设置MLVPN配置
	if default_vpn == "mlvpn" and disablednb ~= serversnb  then
		ucic:set("mlvpn","general","enable",1)
		ucic:set("network","omrvpn","proto","dhcp")
	else
		ucic:set("mlvpn","general","enable",0)
	end

	-- 设置MLVPN密码和其他参数
	local mlvpn_password = luci.http.formvalue("mlvpn_password")
	if mlvpn_password ~= "" then
		ucic:set("mlvpn","general","password",mlvpn_password)
		ucic:set("mlvpn","general","firstport","65201")
		ucic:set("mlvpn","general","interface_name","mlvpn0")
	else
		--ucic:set("mlvpn","general","enable",0)
		ucic:set("mlvpn","general","password","")
	end
	ucic:save("mlvpn")
	ucic:commit("mlvpn")

	-- Set UBOND settings
	-- 设置UBOND配置
	if default_vpn == "ubond" and disablednb ~= serversnb  then
		ucic:set("ubond","general","enable",1)
		ucic:set("network","omrvpn","proto","dhcp")
	else
		ucic:set("ubond","general","enable",0)
	end

	local ubond_password = luci.http.formvalue("ubond_password")
	if ubond_password ~= "" then
		ucic:set("ubond","general","password",ubond_password)
		ucic:set("ubond","general","firstport","65251")
		ucic:set("ubond","general","interface_name","ubond0")
	else
		--ucic:set("ubond","general","enable",0)
		ucic:set("ubond","general","password","")
	end
	ucic:save("ubond")
	ucic:commit("ubond")

	-- openvpn配置
	if default_vpn == "openvpn" and disablednb ~= serversnb  then
		if ucic:get("openmptcprouter","settings","openvpn_lb") == "0" then
			ucic:foreach("openvpn","openvpn", function(s)
				local sectionname = s[".name"]
				if sectionname:match("^omr.*") then
					ucic:set("openvpn",sectionname,"enabled",0)
					ucic:set("network",sectionname,"proto","none")
				end
			end)
			ucic:set("openvpn","omr","enabled",1)
		else
			ucic:foreach("openvpn","openvpn", function(s)
				local sectionname = s[".name"]
				if sectionname:match("^omr.*") then
					ucic:set("openvpn",sectionname,"enabled",1)
					ucic:set("network",sectionname,"proto","none")
				end
			end)
		--ucic:set("openvpn","omr","enabled",1)
		end
		--ucic:set("network","omrvpn","proto","none")
	else
		ucic:foreach("openvpn","openvpn", function(s)
			local sectionname = s[".name"]
			if sectionname:match("^omr.*") then
				ucic:delete("openvpn",sectionname,"enabled")
			end
		end)
		--ucic:delete("openvpn","omr","enabled")
	end
	ucic:save("openvpn")
	ucic:commit("openvpn")

	ucic:save("v2ray")
	ucic:commit("v2ray")
	ucic:save("xray")
	ucic:commit("xray")

	ucic:save("network")
	ucic:commit("network")

	-- OpenMPTCProuter VPS
	--local openmptcprouter_vps_key = luci.http.formvalue("openmptcprouter_vps_key") or ""
	--ucic:set("openmptcprouter","vps","username","openmptcprouter")
	--ucic:set("openmptcprouter","vps","password",openmptcprouter_vps_key)
	--ucic:set("openmptcprouter","vps","get_config","1")

	-- 设置 shadowsocks_disable 和默认VPN配置
	ucic:set("openmptcprouter","settings","shadowsocks_disable",shadowsocks_disable)
	ucic:set("openmptcprouter","settings","vpn",default_vpn)
	ucic:delete("openmptcprouter","settings","master_lcintf")
	ucic:save("openmptcprouter")
	ucic:commit("openmptcprouter")

	-- Restart all
	-- 服务重启
	menuentry = ucic:get("openmptcprouter","settings","menu") or "openmptcprouter"
	if gostatus == true then
		--luci.sys.call("/etc/init.d/macvlan restart >/dev/null 2>/dev/null")
		luci.sys.call("(env -i /bin/ubus call network reload) >/dev/null 2>/dev/null")
		luci.sys.call("ip addr flush dev tun0 >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/omr-tracker stop >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/mptcp restart >/dev/null 2>/dev/null")
		--if openmptcprouter_vps_key ~= "" then
		--	luci.sys.call("/etc/init.d/openmptcprouter-vps restart >/dev/null 2>/dev/null")
		--	luci.sys.call("sleep 2")
		--end
		luci.sys.call("/etc/init.d/shadowsocks-libev restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/shadowsocks-rust restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/glorytun restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/glorytun-udp restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/mlvpn restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/ubond restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/mptcpovervpn restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/openvpn restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/openvpnbonding restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/dsvpn restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/omr-tracker start >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/omr-6in4 restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/vnstat restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/v2ray restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/xray restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/sqm restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/omr-bypass restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/sqm-autorate restart >/dev/null 2>/dev/null")
		luci.sys.call("/etc/init.d/sysntpd restart >/dev/null 2>/dev/null")
		luci.http.redirect(luci.dispatcher.build_url("admin/system/" .. menuentry:lower() .. "/status"))
	else
		luci.http.redirect(luci.dispatcher.build_url("admin/system/" .. menuentry:lower() .. "/wizard"))
	end
	return
end

function settings_add()
	-- Redirects all ports from VPS to OpenMPTCProuter
	-- 从VPS重定向所有端口到OpenMPTCProuter
	local servers = luci.http.formvaluetable("server")
	local redirect_ports = luci.http.formvaluetable("redirect_ports")
	-- 遍历每个服务器，设置端口重定向和防火墙重定向规则
	for server, _ in pairs(servers) do
		local redirectports = luci.http.formvalue("redirect_ports.%s" % server) or "0"
		ucic:set("openmptcprouter",server,"redirect_ports",redirectports)
		local nofwredirect = luci.http.formvalue("nofwredirect.%s" % server) or "0"
		ucic:set("openmptcprouter",server,"nofwredirect",nofwredirect)
	end

	-- Set tcp_keepalive_time
	-- 设置TCP保活时间，通过sysctl设置当前运行时值，并更新配置文件以持久化设置
	local tcp_keepalive_time = luci.http.formvalue("tcp_keepalive_time")
	luci.sys.exec("sysctl -w net.ipv4.tcp_keepalive_time=%s" % tcp_keepalive_time)
	luci.sys.exec("sed -i 's:^net.ipv4.tcp_keepalive_time=[0-9]*:net.ipv4.tcp_keepalive_time=%s:' /etc/sysctl.d/zzz_openmptcprouter.conf" % tcp_keepalive_time)

	-- Set tcp_fin_timeout
	-- 设置TCP FIN超时时间，控制TCP连接关闭时FIN_WAIT_2状态的持续时间
	local tcp_fin_timeout = luci.http.formvalue("tcp_fin_timeout")
	luci.sys.exec("sysctl -w net.ipv4.tcp_fin_timeout=%s" % tcp_fin_timeout)
	luci.sys.exec("sed -i 's:^net.ipv4.tcp_fin_timeout=[0-9]*:net.ipv4.tcp_fin_timeout=%s:' /etc/sysctl.d/zzz_openmptcprouter.conf" % tcp_fin_timeout)

	-- Set tcp_syn_retries
	-- 设置TCP SYN重试次数，控制在放弃连接尝试前发送SYN包的最大次数
	local tcp_syn_retries = luci.http.formvalue("tcp_syn_retries")
	luci.sys.exec("sysctl -w net.ipv4.tcp_syn_retries=%s" % tcp_syn_retries)
	luci.sys.exec("sed -i 's:^net.ipv4.tcp_syn_retries=[0-9]*:net.ipv4.tcp_syn_retries=%s:' /etc/sysctl.d/zzz_openmptcprouter.conf" % tcp_syn_retries)

	-- Set tcp_retries1
	-- 设置TCP第一阶段重试次数，控制TCP协议在确认连接有问题前的重试次数
	local tcp_retries1 = luci.http.formvalue("tcp_retries1")
	luci.sys.exec("sysctl -w net.ipv4.tcp_retries1=%s" % tcp_retries1)
	luci.sys.exec("sed -i 's:^net.ipv4.tcp_retries1=[0-9]*:net.ipv4.tcp_retries1=%s:' /etc/sysctl.d/zzz_openmptcprouter.conf" % tcp_retries1)

	-- Set tcp_retries2
	-- 设置TCP第二阶段重试次数，控制TCP协议在完全放弃连接前的最大重试次数
	local tcp_retries2 = luci.http.formvalue("tcp_retries2")
	luci.sys.exec("sysctl -w net.ipv4.tcp_retries2=%s" % tcp_retries2)
	luci.sys.exec("sed -i 's:^net.ipv4.tcp_retries2=[0-9]*:net.ipv4.tcp_retries2=%s:' /etc/sysctl.d/zzz_openmptcprouter.conf" % tcp_retries2)

	-- Set ip_default_ttl
	-- 设置IP默认TTL值，控制IP数据包的生存时间
	local ip_default_ttl = luci.http.formvalue("ip_default_ttl")
	luci.sys.exec("sysctl -w net.ipv4.ip_default_ttl=%s" % ip_default_ttl)
	luci.sys.exec("sed -i 's:^net.ipv4.ip_default_ttl=[0-9]*:net.ipv4.ip_default_ttl=%s:' /etc/sysctl.d/zzz_openmptcprouter.conf" % ip_default_ttl)

	-- Set tcp_fastopen
	-- 设置TCP快速打开，配置TCP Fast Open功能，可以在第一个包中携带数据
	local tcp_fastopen = luci.http.formvalue("tcp_fastopen")
	local disablefastopen = luci.http.formvalue("disablefastopen") or "0"
	if disablefastopen == "1" then
		tcp_fastopen = "0"
	elseif tcp_fastopen == "0" and disablefastopen == "0" then
		tcp_fastopen = "3"
	end
	luci.sys.exec("sysctl -w net.ipv4.tcp_fastopen=%s" % tcp_fastopen)
	luci.sys.exec("sed -i 's:^net.ipv4.tcp_fastopen=[0-3]*:net.ipv4.tcp_fastopen=%s:' /etc/sysctl.d/zzz_openmptcprouter.conf" % tcp_fastopen)
	ucic:set("openmptcprouter", "settings","disable_fastopen", disablefastopen)
	
	-- Disable IPv6
	-- 禁用IPv6
	local disable_ipv6 = luci.http.formvalue("enableipv6") or "1"
	ucic:set("openmptcprouter","settings","disable_ipv6",disable_ipv6)
	--local dump = require("luci.util").ubus("openmptcprouter", "disableipv6", { disable_ipv6 = tonumber(disable_ipv6)})

	-- Disable 6in4
	-- 控制是否启用6in4隧道支持
	local disable_6in4 = luci.http.formvalue("enable6in4") or "0"
	ucic:set("openmptcprouter","settings","disable_6in4",disable_6in4)

	-- Disable ModemManager
	-- 控制是否启用调制解调器管理器
	local disable_modemmanager = luci.http.formvalue("disablemodemmanager") or "0"
	ucic:set("openmptcprouter","settings","disable_modemmanager",disable_modemmanager)
	if disable_modemmanager == "1" then
		luci.sys.exec("/etc/init.d/modemmanager stop")
	end

	-- Ban UDP IPs
	-- 设置防火墙规则以阻止特定UDP流量
	local banudpip = luci.http.formvalue("banudpip") or "0"
	ucic:set("firewall","omr_dst_udp_banip_rule_v4","enabled",banudpip)
	ucic:set("firewall","omr_dst_udp_banip_rule_v6","enabled",banudpip)
	ucic:save("firewall")
	ucic:commit("firewall")

	-- Enable/disable external check
	-- 控制是否进行外部连接性检查
	local externalcheck = luci.http.formvalue("externalcheck") or "1"
	ucic:set("openmptcprouter","settings","external_check",externalcheck)

	-- Enable/disable OpenVPN multiple clients
	-- 配置OpenVPN的负载均衡功能
	local openvpnlb = luci.http.formvalue("openvpnlb") or "1"
	if ucic:get("openmptcprouter","settings","openvpn_lb") ~= openvpnlb then
		ucic:set("openmptcprouter","settings","openvpn_lb",openvpnlb)
		ucic:foreach("openmptcprouter", "server", function(s)
			local sectionname = s[".name"]
			ucic:set("openmptcprouter",sectionname,"get_config","1")
		end)

	end

	-- Enable/disable restrict proxy to LAN
	-- 控制代理服务是否仅限于LAN网络
	local restricttolan = luci.http.formvalue("restricttolan") or "0"
	ucic:set("openmptcprouter","settings","restrict_to_lan",restricttolan)

	-- Enable/disable debug
	-- 设置全局调试模式和shadowsocks的详细日志
	local debug = luci.http.formvalue("debug") or "0"
	ucic:set("openmptcprouter","settings","debug",debug)
	ucic:foreach("shadowsocks-libev", "ss_redir", function (section)
		ucic:set("shadowsocks-libev",section[".name"],"verbose",debug)
	end)

	-- Enable/disable vnstat backup
	-- 启用/禁用vnstat备份，控制是否备份网络流量统计数据
	local savevnstat = luci.http.formvalue("savevnstat") or "0"
	luci.sys.exec("uci -q set openmptcprouter.settings.vnstat_backup=%s" % savevnstat)
	ucic:commit("vnstat")

	-- Enable/disable gateway ping
	-- 启用/禁用网关ping，控制是否允许ping网关
	local disablegwping = luci.http.formvalue("disablegwping") or "0"
	ucic:set("openmptcprouter","settings","disablegwping",disablegwping)

	-- VPS timeout
	-- VPS超时设置，设置VPS连接超时时间
	local status_vps_timeout = luci.http.formvalue("status_vps_timeout") or "1"
	ucic:set("openmptcprouter","settings","status_vps_timeout",status_vps_timeout)

	-- IP timeout
	-- IP超时设置，设置IP地址获取超时时间
	local status_getip_timeout = luci.http.formvalue("status_getip_timeout") or "1"
	ucic:set("openmptcprouter","settings","status_getip_timeout",status_getip_timeout)

	-- Whois timeout
	-- Whois超时设置
	local status_whois_timeout = luci.http.formvalue("status_whois_timeout") or "2"
	ucic:set("openmptcprouter","settings","status_whois_timeout",status_whois_timeout)

	-- Enable/disable loop detection
	-- 启用/禁用循环检测，控制是否检测网络循环
	local disableloopdetection = luci.http.formvalue("disableloopdetection") or "0"
	ucic:set("openmptcprouter","settings","disableloopdetection",disableloopdetection)

	-- Enable/disable http test
	-- 启用/禁用HTTP测试，控制是否进行服务器HTTP可用性测试
	local disableserverhttptest = luci.http.formvalue("disableserverhttptest") or "0"
	ucic:set("openmptcprouter","settings","disableserverhttptest",disableserverhttptest)

	-- Enable/disable renaming intf
	-- 启用/禁用接口重命名
	local disableintfrename = luci.http.formvalue("disableintfrename") or "0"
	ucic:set("openmptcprouter","settings","disableintfrename",disableintfrename)

	-- Enable/disable default gateway
	-- 启用/禁用默认网关
	local disabledefaultgw = luci.http.formvalue("disabledefaultgw") or "1"
	ucic:set("openmptcprouter","settings","defaultgw",disabledefaultgw)

	-- Enable/disable tracebox
	-- 启用/禁用tracebox
	local tracebox = luci.http.formvalue("disabletracebox") or "1"
	ucic:set("openmptcprouter","settings","tracebox",tracebox)

	-- Enable/disable server ping
	-- 启用/禁用服务器ping
	local disableserverping = luci.http.formvalue("disableserverping") or "0"
	ucic:set("openmptcprouter","settings","disableserverping",disableserverping)

	-- Enable/disable multipath check
	-- 启用/禁用多路径检查
	local disablemultipathtest = luci.http.formvalue("disablemultipathtest") or "0"
	ucic:set("openmptcprouter","settings","disablemultipathtest",disablemultipathtest)

	-- Enable/disable shadowsocks udp
	-- 启用/禁用shadowsocks UDP
	local shadowsocksudp = luci.http.formvalue("shadowsocksudp") or "0"
	ucic:set("openmptcprouter","settings","shadowsocksudp",shadowsocksudp)

	-- Enable/disable v2ray/xray udp
	local v2rayudp = luci.http.formvalue("v2rayudp") or "0"
	ucic:set("v2ray","main_transparent_proxy","redirect_udp",v2rayudp)
	ucic:save("v2ray")
	ucic:commit("v2ray")
	-- 启用/禁用v2ray/xray UDP
	ucic:set("xray","main_transparent_proxy","redirect_udp",v2rayudp)
	ucic:save("xray")
	ucic:commit("xray")

	-- Enable/disable nDPI
	-- 启用/禁用nDPI
	local ndpi = luci.http.formvalue("ndpi") or "1"
	ucic:set("openmptcprouter","settings","ndpi",ndpi)

	-- Enable/disable fast open
	-- 启用/禁用快速打开
	local disablefastopen = luci.http.formvalue("disablefastopen") or "0"
	if disablefastopen == "0" then
		fastopen = "1"
	else
		fastopen = "0"
	end
	ucic:foreach("shadowsocks-libev", "ss_redir", function (section)
		ucic:set("shadowsocks-libev",section[".name"],"fast_open",fastopen)
	end)
	ucic:foreach("shadowsocks-libev", "ss_local", function (section)
		ucic:set("shadowsocks-libev",section[".name"],"fast_open",fastopen)
	end)

	-- Enable/disable no delay
	-- 启用/禁用无延迟，配置TCP低延迟模式和shadowsocks的无延迟选项
	local nodelay = luci.http.formvalue("enablenodelay") or "0"
	ucic:set("openmptcprouter","settings","enable_nodelay",nodelay)
	luci.sys.exec("sysctl -w net.ipv4.tcp_low_latency=%s" % nodelay)
	luci.sys.exec("sed -i 's:^net.ipv4.tcp_low_latency=[0-9]*:net.ipv4.tcp_low_latency=%s:' /etc/sysctl.d/zzz_openmptcprouter.conf" % nodelay)
	ucic:foreach("shadowsocks-libev", "ss_redir", function (section)
		ucic:set("shadowsocks-libev",section[".name"],"no_delay",nodelay)
	end)
	ucic:foreach("shadowsocks-libev", "ss_local", function (section)
		ucic:set("shadowsocks-libev",section[".name"],"no_delay",nodelay)
	end)


	-- Enable/disable obfs
	-- 启用/禁用混淆，配置shadowsocks的混淆设置
	local obfs = luci.http.formvalue("obfs") or "0"
	local obfs_plugin = luci.http.formvalue("obfs_plugin") or "v2ray"
	local obfs_type = luci.http.formvalue("obfs_type") or "http"
	ucic:foreach("shadowsocks-libev", "server", function (section)
		ucic:set("shadowsocks-libev",section[".name"],"obfs",obfs)
		ucic:set("shadowsocks-libev",section[".name"],"obfs_plugin",obfs_plugin)
		ucic:set("shadowsocks-libev",section[".name"],"obfs_type",obfs_type)
	end)
	ucic:save("shadowsocks-libev")
	ucic:commit("shadowsocks-libev")

	-- Set master to dynamic or static
	-- 设置主接口类型（动态或静态）
	--local master_type = luci.http.formvalue("master_type") or "static"
	--ucic:set("openmptcprouter","settings","master",master_type)

	-- Set CPU scaling minimum frequency
	-- 设置CPU最小频率，配置CPU频率调节的下限
	local scaling_min_freq = luci.http.formvalue("scaling_min_freq") or ""
	if scaling_min_freq ~= "" then
		ucic:set("openmptcprouter","settings","scaling_min_freq",scaling_min_freq)
	end

	-- Set CPU scaling maximum frequency
	-- 设置CPU最大频率，配置CPU频率调节的上限
	local scaling_max_freq = luci.http.formvalue("scaling_max_freq") or ""
	if scaling_max_freq ~= "" then
		ucic:set("openmptcprouter","settings","scaling_max_freq",scaling_max_freq)
	end

	-- Set CPU governor
	-- 设置CPU调频器，配置CPU频率调节策略
	local scaling_governor = luci.http.formvalue("scaling_governor") or ""
	if scaling_governor ~= "" then
		ucic:set("openmptcprouter","settings","scaling_governor",scaling_governor)
	end

	-- Enable/disable Qualcomm Shortcut FE
	-- 启用/禁用高通快速转发引擎，配置SFE（Shortcut Forwarding Engine）功能
	local sfe_enabled = luci.http.formvalue("sfe_enabled") or "0"
	ucic:set("openmptcprouter","settings","sfe_enabled",sfe_enabled)
	local sfe_bridge = luci.http.formvalue("sfe_bridge") or "0"
	ucic:set("openmptcprouter","settings","sfe_bridge",sfe_bridge)

	-- Enable/disable SIP ALG
	-- 启用/禁用SIP ALG，配置SIP应用层网关
	local sipalg = luci.http.formvalue("sipalg") or "0"
	ucic:set("openmptcprouter","settings","sipalg",sipalg)

	ucic:save("openmptcprouter")
	ucic:commit("openmptcprouter")

	-- Apply all settings
	-- 重启相关服务使配置生效
	luci.sys.call("/etc/init.d/openmptcprouter restart >/dev/null 2>/dev/null")
	luci.sys.call("/etc/init.d/openmptcprouter-vps set_vps_firewall >/dev/null 2>/dev/null")
	luci.sys.call("/etc/init.d/omr-6in4 restart >/dev/null 2>/dev/null")
	luci.sys.call("/etc/init.d/firewall reload >/dev/null 2>/dev/null")

	-- Done, redirect
	-- 完成后重定向
    -- 获取菜单项并重定向到设置页面
	menuentry = ucic:get("openmptcprouter","settings","menu") or "openmptcprouter"
	luci.http.redirect(luci.dispatcher.build_url("admin/system/" .. menuentry:lower() .. "/settings"))
	return
end

function update_vps()
	-- Update VPS
	-- 从Web表单获取flash参数，如果未提供则设为空字符串
	local update_vps = luci.http.formvalue("flash") or ""
	if update_vps ~= "" then
		-- 导入luci.util模块以使用ubus功能
		local ut = require "luci.util"
		-- 通过ubus调用openmptcprouter的updateVPS方法来更新VPS
		local result = ut.ubus("openmptcprouter", "updateVPS", {})
	end
	return
end

function backupgr()
	-- 从Web表单获取restore参数值，如果没有则设为空字符串
	local get_backup = luci.http.formvalue("restore") or ""
	-- 如果restore参数不为空，则执行备份恢复操作
	if get_backup ~= "" then
		local dobackup = 0
		-- 遍历openmptcprouter配置中的所有服务器
		ucic:foreach("openmptcprouter","server", function(s)
			servername = s[".name"]
			-- 从Web表单获取当前服务器的备份选择值
			local get_selected_backup = luci.http.formvalue(servername .. "") or ""
			-- 如果选择了备份文件
			if get_selected_backup ~= "" then
				dobackup = 1
				-- 执行备份恢复命令，恢复指定服务器的指定备份文件
				luci.sys.call("/etc/init.d/openmptcprouter-vps backup_get " .. servername .. " " .. get_selected_backup .. ">/dev/null 2>/dev/null")
			end
		end)
		-- 如果没有选择任何服务器的备份，执行全局备份恢复命令
		if dobackup == 0 then
			luci.sys.call("/etc/init.d/openmptcprouter-vps backup_get >/dev/null 2>/dev/null")
		end
	end
	-- 从Web表单获取save参数值，如果没有则设为空字符串
	local send_backup = luci.http.formvalue("save") or ""
	-- 如果save参数不为空，则执行备份保存操作
	if send_backup ~= "" then
		-- 执行备份保存命令
		luci.sys.call("/etc/init.d/openmptcprouter-vps backup_send >/dev/null 2>/dev/null")
	end
	-- 从配置中获取菜单项设置，如果没有则默认为openmptcprouter
	menuentry = ucic:get("openmptcprouter","settings","menu") or "openmptcprouter"
	-- 重定向到备份页面
	luci.http.redirect(luci.dispatcher.build_url("admin/system/" .. menuentry:lower() .. "/backup"))
	return
end

-- 获取网络接口的设备名称
function get_device(interface)
	-- 使用ubus调用获取指定网络接口的状态信息， %s是字符串格式化占位符，会被interface参数替换
	local dump = require("luci.util").ubus("network.interface.%s" % interface, "status", {})
	-- 如果成功获取到状态信息
	if dump ~= nil then
		if dump['l3_device'] ~= nil then	-- 优先检查是否存在三层设备（如IP接口）
			return dump['l3_device']
		elseif dump['device'] ~= nil then	-- 如果没有三层设备，检查是否存在物理设备
			return dump['device']
		else
			return ""
		end
	else
		return ""
	end
end

-- This function come from modules/luci-bbase/luasrc/tools/status.lua from old OpenWrt
-- Copyright 2011 Jo-Philipp Wich <jow@openwrt.org>
-- Licensed to the public under the Apache License 2.0.

-- 获取DHCP租约信息
local function dhcp_leases_common(family)
	local rv = { }
	local nfs = require "nixio.fs"
	local sys = require "luci.sys"
	local leasefile = "/tmp/dhcp.leases"

	-- 遍历DHCP配置中的dnsmasq部分，更新租约文件路径
	ucic:foreach("dhcp", "dnsmasq",
	    function(s)
		    if s.leasefile and nfs.access(s.leasefile) then
			    leasefile = s.leasefile
			    return false
		    end
	    end)

	-- 尝试打开租约文件
	local fd = io.open(leasefile, "r")
	if fd then
		-- 循环读取文件的每一行
		while true do
			local ln = fd:read("*l")
			if not ln then
				break
			else
				-- 解析行：时间戳、MAC、IP、主机、DUID
				local ts, mac, ip, name, duid = ln:match("^(%d+) (%S+) (%S+) (%S+) (%S+)")
				local expire = tonumber(ts) or 0
				-- 所有字段都解析成功
				if ts and mac and ip and name and duid then
					-- 处理IPv4租约
					if family == 4 and not ip:match(":") then
						rv[#rv+1] = {
						    expires  = (expire ~= 0) and os.difftime(expire, os.time()),
						    macaddr  = ipc.checkmac(mac) or "00:00:00:00:00:00",
						    ipaddr   = ip,
						    hostname = (name ~= "*") and name
						}
					-- 处理IPv6租约
					elseif family == 6 and ip:match(":") then
						rv[#rv+1] = {
						    expires  = (expire ~= 0) and os.difftime(expire, os.time()),
						    ip6addr  = ip,
						    duid     = (duid ~= "*") and duid,
						    hostname = (name ~= "*") and name
						}
					end
				end
			end
		end
		fd:close()
	end

	local lease6file = "/tmp/hosts/odhcpd"
	-- 遍历DHCP配置中的odhcpd部分
	ucic:foreach("dhcp", "odhcpd",
	    function(t)
		    if t.leasefile and nfs.access(t.leasefile) then
			    lease6file = t.leasefile
			    return false
		    end
	end)
	-- DHCPv6租约文件
	local fd = io.open(lease6file, "r")
	if fd then
		while true do
			local ln = fd:read("*l")
			if not ln then
				break
			else
				local iface, duid, iaid, name, ts, id, length, ip = ln:match("^# (%S+) (%S+) (%S+) (%S+) (-?%d+) (%S+) (%S+) (.*)")
				local expire = tonumber(ts) or 0
				if ip and iaid ~= "ipv4" and family == 6 then
					rv[#rv+1] = {
					    expires  = (expire >= 0) and os.difftime(expire, os.time()),
					    duid     = duid,
					    ip6addr  = ip,
					    hostname = (name ~= "-") and name
					}
				elseif ip and iaid == "ipv4" and family == 4 then
					rv[#rv+1] = {
					    expires  = (expire >= 0) and os.difftime(expire, os.time()),
					    macaddr  = sys.net.duid_to_mac(duid) or "00:00:00:00:00:00",
					    ipaddr   = ip,
					    hostname = (name ~= "-") and name
					}
				end
			end
		end
		fd:close()
	end

	-- IPv6
	if family == 6 then
		local _, lease
		local hosts = sys.net.host_hints()
		for _, lease in ipairs(rv) do
			local mac = sys.net.duid_to_mac(lease.duid)
			local host = mac and hosts[mac]
			if host then
				if not lease.name then
					lease.host_hint = host.name or host.ipv4 or host.ipv6
				elseif host.name and lease.hostname ~= host.name then
					lease.host_hint = host.name
				end
			end
		end
	end

	return rv
end

function interfaces_status()
	local ut = require "luci.util"
	--local mArray = ut.ubus("openmptcprouter", "status", {}) or {_=0}
	-- ubus获取openmptcprouter状态
	local mArray = luci.json.decode(ut.trim(sys.exec("/bin/ubus -t 600 -S call openmptcprouter status 2>/dev/null")))

	-- 成功获取到状态信息
	if mArray ~= nil and mArray.openmptcprouter ~= nil then
		-- 获取客户端IP地址
		mArray.openmptcprouter["remote_addr"] = luci.http.getenv("REMOTE_ADDR") or ""
		-- 初始化租约状态为false
		mArray.openmptcprouter["remote_from_lease"] = false
		-- 获取IPv4的DHCP租约信息
		local leases=dhcp_leases_common(4)
		-- 遍历所有租约
		for _, value in pairs(leases) do
			-- 如果找到匹配的IP地址
			if value["ipaddr"] == mArray.openmptcprouter["remote_addr"] then
				mArray.openmptcprouter["remote_from_lease"] = true					-- 标记为来自租约
				mArray.openmptcprouter["remote_hostname"] = value["hostname"]		-- 记录主机名
			end
		end
	end

	-- 设置响应内容类型为JSON
	luci.http.prepare_content("application/json")
	-- 将状态信息转换为JSON并返回
	luci.http.write_json(mArray)
end
