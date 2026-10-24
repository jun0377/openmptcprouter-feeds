# -*- coding: utf-8 -*-
# vim: set noexpandtab tabstop=4 shiftwidth=4 softtabstop=4 :
#
# 4G / 5G 基站状态的采集层: 与 siminfo.py 同一定位, 只提供数据, 不生成串口指令
#
# 目前是模拟数据: 模组作为终端, AT 指令里拿不到基站的物理小区 ID 与连接用户数,
# 先按 3 秒一个时间片生成动态样例值, 供屏幕 01(直连)与屏幕 02(聚合)右侧的基站卡片联调;
# 后续接入真实数据源时只改 read_bts() 的实现, 两个页面模块不用动
#
# 字段与 docs/018-屏幕.md 3.1 / 3.2 一致:
#   online  是否在线   在线 Pic*Online.pic=43 / 离线 42
#   pci     物理小区 ID -> NumLteID / Num5GID
#   ue      连接用户数  -> NumLteUser / Num5GUser
#

import random
import time

# 模拟值的变化周期(秒): 时间片序号变化一次, 两个基站的四个数值就换一批
CHANGE_INTERVAL = 3

# 模拟数据: (制式, 基准物理小区 ID, 基准连接用户数, 随机种子)
# 每次在基准值附近小幅波动, 看起来像真实的小区重选, 而不是完全随机跳变
_MOCK = (
	("4G", 123, 10, 1),
	("5G", 208, 12, 2),
)

PCI_SPAN = 20								# 物理小区 ID 的波动幅度(3GPP 取值 0~1007)
UE_SPAN = 8									# 连接用户数的波动幅度


# 单个基站的实时状态
class BtsInfo:

	def __init__(self, label, online, pci, ue):
		self.label = label			# 制式, "4G" / "5G"
		self.online = online		# 是否在线
		self.pci = pci				# 物理小区 ID
		self.ue = ue				# 当前连接用户数


# 读全部基站状态: 顺序固定为 4G、5G, 与屏上两张卡片一致
# 每 CHANGE_INTERVAL 秒换一批数值, 同一时间片内多次调用结果相同(便于页面刷新时数值稳定)
def read_bts():
	step = int(time.time() // CHANGE_INTERVAL)		# 时间片序号, 每 3 秒加一
	bts = []
	for label, pci, ue, seed in _MOCK:
		rnd = random.Random((step << 8) | seed)		# 用时间片与制式做种子, 两台基站各自独立变化
		bts.append(BtsInfo(
			label,
			True,									# 始终在线: 离线态由页面模块统一置零, 这里只模拟有读数的场景
			rnd.randint(pci - PCI_SPAN, pci + PCI_SPAN),
			rnd.randint(ue - UE_SPAN, ue + UE_SPAN),
		))
	return bts
