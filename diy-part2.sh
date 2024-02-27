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

#sed -i '$anet.core.rmem_max=2097152' base-files/files/etc/sysctl.d/10-default.conf

#更改默认IP地址（150行）
sed -i 's/192.168.1.1/192.168.2.1/' base-files/files/bin/config_generate

#取消53端口防火墙规则（40-43行）
sed -i '39,45s/echo/#echo/' lean/default-settings/files/zzz-default-settings
sed -i '/REDIRECT --to-ports 53/d'  lean/default-settings/files/zzz-default-settings

#更改xray内核版本
#sed -i '4s/PKG_VERSION:=1.*/PKG_VERSION:=1.6.1/' feeds/small/xray-core/Makefile
#sed -i '9s/PKG_HASH:=.*/PKG_HASH:=8b4cc89d83b0ded75630119d9e2456764530490c7fb5e8a27de0cdf9c57fef15/' feeds/small/xray-core/Makefile

#更改xray-plugin内核版本
#sed -i '8s/PKG_VERSION:=1.*/PKG_VERSION:=1.6.1/' feeds/small/xray-plugin/Makefile
#sed -i '13s/PKG_HASH:=.*/PKG_HASH:=5ae89aec07534c6bf39e2168ccf475ae481c88f650c4bc6dd542078952648b2a/' feeds/small/xray-plugin/Makefile

#更改默认geoip和geosite
sed -i 's/github.com\/v2fly\/geoip\/releases\/download\/$(GEOIP_VER)\//github.com\/Loyalsoldier\/v2ray-rules-dat\/releases\/latest\/download\//' feeds/xiaorouji/v2ray-geodata/Makefile
sed -i 's/github.com\/v2fly\/domain-list-community\/releases\/download\/$(GEOSITE_VER)\//github.com\/Loyalsoldier\/v2ray-rules-dat\/releases\/latest\/download\//' feeds/xiaorouji/v2ray-geodata/Makefile
sed -i 's/dlc.dat/geosite.dat/' feeds/xiaorouji/v2ray-geodata/Makefile
sed -i 's/HASH:=.*/HASH:=skip/' feeds/xiaorouji/v2ray-geodata/Makefile

#更改haproxy内核版本
sed -i 's/PKG_VERSION:=2.*/PKG_VERSION:=2.8.6/' feeds/packages/haproxy/Makefile
#sed -i 's/PKG_HASH:=.*/PKG_HASH:=$(cat <(curl $(PKG_SOURCE_URL)\/$(PKG_NAME)-$(PKG_VERSION).tar.gz.sha256))/' feeds/packages/haproxy/Makefile
#sed -i 's/PKG_HASH:=.*/PKG_HASH:=a02ad64550dd30a94b25fd0e225ba699649d0c4037bca3b36b20e8e3235bb86f/' feeds/packages/haproxy/Makefile
sed -i 's/PKG_HASH:=.*/PKG_HASH:=skip/' feeds/packages/haproxy/Makefile
sed -i 's/BASE_TAG=v2.*/BASE_TAG=v2.8.6/' feeds/packages/haproxy/get-latest-patches.sh

#修复ipt2socks无法正确监听IPV6，并开启双线程
sed -i 's/-b 0.0.0.0 -s/-b 0.0.0.0 -B :: -j 2 -s/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/app.sh


sed -i '/log                     global/a\	option                  tcp-check' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
#sed -i 's/daemon/daemon\n              nbproc      4\n              nbthread    2/' feeds/kenzo/luci-app-passwall/root/usr/share/passwall/app.sh
#请求失败重试次数
sed -i 's/retries                 2/retries                 1/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
#客户端发送http请求的超时时间
#sed -i 's/timeout http-request    10s/timeout http-request    1s/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/app.sh
#haproxy与后端服务器连接超时时间，如果在同一个局域网可设置较小的时间
#sed -i 's/timeout connect         10s/timeout connect         1s/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/app.sh
#健康检测的时间的最大超时时间
#sed -i 's/timeout check           10s/timeout check           500ms/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/app.sh
#健康检测的时间的最大超时时间
sed -i 's/timeout client          1m/timeout client          30m/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
#健康检测的时间的最大超时时间
sed -i 's/timeout server          1m/timeout server          6m/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
#最大并发连接数
#sed -i 's/maxconn                 3000/maxconn                 6000/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
#rise 3是3次正确认为服务器可用，fall 3是3次失败认为服务器不可用
#sed -i 's/inter 1500 rise 1 fall 3/inter 1000 rise 30 fall 3/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
sed -i 's/rise 1 fall 3 {{backup}}/rise 6 fall 1 {{backup}}  on-marked-down shutdown-sessions/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
sed -i 's/--connect-timeout 3 --retry 3/--connect-timeout 3 --retry 1/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy_check.sh
#sed -i 's/rise 1 fall 3 {{backup}}/& on-marked-down shutdown-sessions/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
#sed -i 's/server \$remark:\$bport \$bip:\$bport weight \$lbweight check inter 1000 rise 30 fall 3 \$bbackup/& on-marked-down shutdown-sessions/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua

#socks健康检测
#sed -i  's/\t\t\tEOF/&\n\t\t\t[ "$bip" = "127.0.0.1" ] \&\& {\n\t\t\t\tcat <<-EOF >> "${haproxy_file}"\n\t\t\t\t    option tcp-check\n\t\t\t\t    tcp-check connect\n\t\t\t\t    tcp-check send-binary 05020002\n\t\t\t\t    tcp-check expect binary 0500\n\t\t\t\t    tcp-check send-binary 050100030d7777772e62616964752e636f6d01bb\n\t\t\t\t    tcp-check expect binary 05000001\n\t\t\t\tEOF\n\t\t\t}/' feeds/kenzo/luci-app-passwall/root/usr/share/passwall/haproxy.lua


#解除Adguardhome更新
#sed -i 's/PKG_VERSION:=.*/PKG_VERSION:=0.107.27' feeds/kenzo/adguardhome/Makefile
#解除Adguardhome更新
#sed -i 's/PKG_HASH:=.*/PKG_HASH:=skip/' feeds/kenzo/adguardhome/Makefile
#解除Adguardhome更新
sed -i '/--no-check-update/d' feeds/kenzo/adguardhome/files/adguardhome.init
#更改默认安装位置
#sed -i 's/PROG=.*/PROG=\/etc\/AdGuardHome\/AdGuardHome/' feeds/kenzo/adguardhome/files/adguardhome.init

sed -i 's/PKG_HASH:=.*/PKG_HASH:=skip/' feeds/kenzo/adguardhome/Makefile
#sed -i '/^\t\$(call Build\/Prepare\/Default)/a \\tif [ -d "$(BUILD_DIR)\/AdGuardHome-$(PKG_VERSION)" ]; then \\\n\t\tmv "$(BUILD_DIR)\/AdGuardHome-$(PKG_VERSION)\/"* "$(BUILD_DIR)\/adguardhome-$(PKG_VERSION)\/"; \\\n\tfi' feeds/kenzo/adguardhome/Makefile
#sed -i '/gzip -dc $(DL_DIR)\/$(FRONTEND_FILE) | $(HOST_TAR) -C $(PKG_BUILD_DIR)\/ $(TAR_OPTIONS)/a \\t( cd "$(BUILD_DIR)\/adguardhome-$(PKG_VERSION)"; go mod tidy )' feeds/kenzo/adguardhome/Makefile


#mosdns默认配置
#取消默认IPV4
#sed -i '/_prefer_ipv4/d' feeds/sbwml/luci-app-mosdns/root/usr/share/mosdns/default.yaml
#国外+ecs
#sed -i 's/_prefer_ipv4/add_ecs/' feeds/sbwml/luci-app-mosdns/root/usr/share/mosdns/default.yaml
#sed -i 's/        - primary:\n            - forward_local/        - primary:\n            - add_ecs\n            - forward_remote/' feeds/sbwml/luci-app-mosdns/root/usr/share/mosdns/default.yaml
#sed -i 's/        - secondary:\n            - add_ecs\n            - forward_remote/        - secondary:\n            - forward_local/' feeds/sbwml/luci-app-mosdns/root/usr/share/mosdns/default.yaml
#国外+ecs
#sed -i 's/            - forward_remote/            - add_ecs\n            - forward_remote/' feeds/sbwml/luci-app-mosdns/root/usr/share/mosdns/default.yaml
#ecs
#sed -i  's/plugins:/plugins:\n  - tag: "add_ecs"\n    type: "ecs"\n    args:\n      auto: false\n      ipv4: "133.1.0.0"\n      ipv6: "2001:268:83b::"\n      force_overwrite: true\n      mask4: 24\n      mask6: 48\n/' feeds/sbwml/luci-app-mosdns/root/usr/share/mosdns/default.yaml
#fallback
#sed -i 's/          fast_fallback: 200/          fast_fallback: 500\n          always_standby: true/' feeds/sbwml/luci-app-mosdns/root/usr/share/mosdns/default.yaml
#本地dns
#sed -i 's/    type: forward/    type: fast_forward/' feeds/sbwml/luci-app-mosdns/root/usr/share/mosdns/default.yaml
#sed -i 's/      bootstrap:/      #bootstrap:/' feeds/sbwml/luci-app-mosdns/root/usr/share/mosdns/default.yaml
#sed -i 's/        - "bootstrap_dns"/        #- "bootstrap_dns"/' feeds/sbwml/luci-app-mosdns/root/usr/share/mosdns/default.yaml
#sed -i 's/        - addr: local_dns/        - addr: local_dns\n          trusted: true/' feeds/sbwml/luci-app-mosdns/root/usr/share/mosdns/default.yaml
#sed -i 's/        - addr: remote_dns/        - addr: remote_dns\n          trusted: true/' feeds/sbwml/luci-app-mosdns/root/usr/share/mosdns/default.yaml
