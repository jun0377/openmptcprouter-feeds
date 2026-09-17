#
# OpenMPTCProuter LCD display module
# Copyright (C) 2026 Ycarus (Yannick Chabanois) <ycarus@zugaina.org>
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=lcd
PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=OpenMPTCProuter LCD display
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  LCD display service for OpenMPTCProuter.
endef

# 本模块只有脚本, 无需编译
define Build/Compile
endef

# pics/fonts/proj/design.html 仅界面设计时使用, 不打包;
# 源码中的 lcd.init 按 OpenWrt 惯例安装为 /etc/init.d/lcd, 服务名即 lcd
define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/lcd.init $(1)/etc/init.d/lcd
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/lcd.py $(1)/usr/bin/lcd.py
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
