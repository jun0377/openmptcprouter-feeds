#
# OpenMPTCProuter basestation module
# Copyright (C) 2026 Ycarus (Yannick Chabanois) <ycarus@zugaina.org>
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=basestation
PKG_VERSION:=1.0
PKG_RELEASE:=1

include $(INCLUDE_DIR)/package.mk

define Package/$(PKG_NAME)
  SECTION:=utils
  CATEGORY:=Utilities
  TITLE:=OpenMPTCProuter basestation
  PKGARCH:=all
endef

define Package/$(PKG_NAME)/description
  Basestation service for OpenMPTCProuter.
endef

# 本模块只有脚本, 无需编译
define Build/Compile
endef

define Package/$(PKG_NAME)/install
	$(INSTALL_DIR) $(1)/etc/init.d
	$(INSTALL_BIN) ./files/etc/init.d/basestation.init $(1)/etc/init.d/basestation
	$(INSTALL_DIR) $(1)/usr/bin
	$(INSTALL_BIN) ./files/usr/bin/basestation.py $(1)/usr/bin/basestation.py
endef

$(eval $(call BuildPackage,$(PKG_NAME)))
