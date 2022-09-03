#!/bin/bash
#
# Copyright (c) 2019-2020 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#

# Modify default IP
#sed -i 's/192.168.1.1/192.168.50.5/g' package/base-files/files/bin/config_generate
cd package

#更改默认IP地址（150行）
sed -i 's/192.168.1.1/192.168.2.1/' base-files/files/bin/config_generate

#取消53端口防火墙规则（40-43行）
sed -i '39,43s/echo/#echo/' lean/default-settings/files/zzz-default-settings

#更改xray内核版本
sed -i '4s/PKG_VERSION:=1.*/PKG_VERSION:=1.5.5/' feeds/small/xray-core/Makefile
sed -i '9s/PKG_HASH:=.*/PKG_HASH:=3f8d04fef82a922c83bab43cac6c86a76386cf195eb510ccf1cc175982693893/' feeds/small/xray-core/Makefile

#更改xray-plugin内核版本
sed -i '8s/PKG_VERSION:=1.*/PKG_VERSION:=1.5.5/' feeds/small/xray-plugin/Makefile
sed -i '13s/PKG_HASH:=.*/PKG_HASH:=0edc575765fc3523d475f9d28d14d42facf00060fc8ef60bb50f42e0a6730496/' feeds/small/xray-plugin/Makefile

#更改haproxy内核版本
sed -i '13s/PKG_VERSION:=2.*/PKG_VERSION:=2.6.4/' feeds/packages/haproxy/Makefile
sed -i '18s/PKG_HASH:=.*/PKG_HASH:=f07d67ada2ff3a999fed4e34459c0489536331a549665ac90cb6a8df91f4a289/' feeds/packages/haproxy/Makefile
sed -i '4s/BASE_TAG=v2.*/BASE_TAG=v2.6.4/' feeds/packages/haproxy/get-latest-patches.sh

#修复ipt2socks无法正确监听IPV6
sed -i 's/-b 0.0.0.0 -s/-b 0.0.0.0 -B :: -j 2 -s/' feeds/kenzo/luci-app-passwall/root/usr/share/passwall/app.sh
