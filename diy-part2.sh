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
sed -i '4s/PKG_VERSION:=1.*/PKG_VERSION:=1.6.1/' feeds/small/xray-core/Makefile
sed -i '9s/PKG_HASH:=.*/PKG_HASH:=8b4cc89d83b0ded75630119d9e2456764530490c7fb5e8a27de0cdf9c57fef15/' feeds/small/xray-core/Makefile

#更改xray-plugin内核版本
#sed -i '8s/PKG_VERSION:=1.*/PKG_VERSION:=1.6.1/' feeds/small/xray-plugin/Makefile
#sed -i '13s/PKG_HASH:=.*/PKG_HASH:=5ae89aec07534c6bf39e2168ccf475ae481c88f650c4bc6dd542078952648b2a/' feeds/small/xray-plugin/Makefile

#更改haproxy内核版本
sed -i 's/PKG_VERSION:=2.*/PKG_VERSION:=2.6.6/' feeds/packages/haproxy/Makefile
#sed -i 's/PKG_HASH:=.*/PKG_HASH:=$(cat <(curl $(PKG_SOURCE_URL)\/$(PKG_NAME)-$(PKG_VERSION).tar.gz.sha256))/' feeds/packages/haproxy/Makefile
sed -i 's/PKG_HASH:=.*/PKG_HASH:=d0c80c90c04ae79598b58b9749d53787f00f7b515175e7d8203f2796e6a6594d/' feeds/packages/haproxy/Makefile
sed -i 's/BASE_TAG=v2.*/BASE_TAG=v2.6.6/' feeds/packages/haproxy/get-latest-patches.sh

#修复ipt2socks无法正确监听IPV6，并开启双线程
sed -i 's/-b 0.0.0.0 -s/-b 0.0.0.0 -B :: -j 2 -s/' feeds/kenzo/luci-app-passwall/root/usr/share/passwall/app.sh


#sed -i 's/daemon/daemon\n              nbproc      4\n              nbthread    2/' feeds/kenzo/luci-app-passwall/root/usr/share/passwall/app.sh
#请求失败重试次数
sed -i 's/retries                 2/retries                 1/' feeds/kenzo/luci-app-passwall/root/usr/share/passwall/app.sh
#客户端发送http请求的超时时间
sed -i 's/timeout http-request    10s/timeout http-request    1s/' feeds/kenzo/luci-app-passwall/root/usr/share/passwall/app.sh
#haproxy与后端服务器连接超时时间，如果在同一个局域网可设置较小的时间
sed -i 's/timeout connect         10s/timeout connect         1s/' feeds/kenzo/luci-app-passwall/root/usr/share/passwall/app.sh
#健康检测的时间的最大超时时间
sed -i 's/timeout check           10s/timeout check           500ms/' feeds/kenzo/luci-app-passwall/root/usr/share/passwall/app.sh
#最大并发连接数
sed -i 's/maxconn                 3000/maxconn                 6000/' feeds/kenzo/luci-app-passwall/root/usr/share/passwall/app.sh
#sed -i 's/check inter 1500 rise 1 fall 3/check inter 1500 rise 1 fall 3/' feeds/kenzo/luci-app-passwall/root/usr/share/passwall/app.sh

#socks健康检测
sed -i  's/\t\t\tEOF/&\n\t\t\t[ "$bip" = "127.0.0.1" ] \&\& {\n\t\t\t\tcat <<-EOF >> "${haproxy_file}"\n\t\t\t\t    option tcp-check\n\t\t\t\t    tcp-check connect\n\t\t\t\t    tcp-check send-binary 05020002\n\t\t\t\t    tcp-check expect binary 0500\n\t\t\t\t    tcp-check send-binary 050100030d7777772e62616964752e636f6d01bb\n\t\t\t\t    tcp-check expect binary 05000001\n\t\t\t\tEOF\n\t\t\t}/' feeds/kenzo/luci-app-passwall/root/usr/share/passwall/app.sh


#解除Adguardhome更新
sed -i '/--no-check-update/d' feeds/kenzo/adguardhome/files/adguardhome.init
#更改默认安装位置
#sed -i 's/PROG=.*/PROG=\/etc\/AdGuardHome\/AdGuardHome/' feeds/kenzo/adguardhome/files/adguardhome.init
