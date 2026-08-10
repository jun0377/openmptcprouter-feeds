#
# Copyright (C) 2026
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=management-platform
PKG_VERSION:=1
PKG_RELEASE:=1

PKG_MAINTAINER:=
PKG_BUILD_DIR := $(BUILD_DIR)/$(PKG_NAME)

include $(INCLUDE_DIR)/package.mk

define Package/management-platform
  SECTION:=net
  CATEGORY:=Network
  TITLE:=Management platform status report
  DEPENDS:=+curl
  PKGARCH:=all
endef

define Package/management-platform/description
  Report router status to the management platform server.
endef

define Build/Prepare
endef

define Build/Configure
endef

define Build/Compile
endef

define Package/management-platform/install
	$(INSTALL_DIR) $(1)
	$(CP) ./files/* $(1)/
endef

$(eval $(call BuildPackage,management-platform))
