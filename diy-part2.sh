#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part2.sh
# Description: OpenWrt DIY script part 2 (After Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

#rm -rf feeds/packages/lang/golang
#git clone https://github.com/sbwml/packages_lang_golang -b 22.x feeds/packages/lang/golang
#git clone https://github.com/kenzok8/golang feeds/packages/lang/golang

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

#防止不解析本机域名
sed -i '/conf_out:write("no-resolv\\n")/d; /tinsert(conf_lines, "no-resolv")/d' feeds/passwall/luci-app-passwall/root/usr/share/passwall/helper_dnsmasq.lua

#更改xray-plugin内核版本
#sed -i '8s/PKG_VERSION:=1.*/PKG_VERSION:=1.6.1/' feeds/small/xray-plugin/Makefile
#sed -i '13s/PKG_HASH:=.*/PKG_HASH:=5ae89aec07534c6bf39e2168ccf475ae481c88f650c4bc6dd542078952648b2a/' feeds/small/xray-plugin/Makefile

#更改默认geoip和geosite
sed -i 's/github.com\/v2fly\/geoip\/releases\/download\/$(GEOIP_VER)\//github.com\/Loyalsoldier\/v2ray-rules-dat\/releases\/latest\/download\//' feeds/xiaorouji/v2ray-geodata/Makefile
sed -i 's/github.com\/v2fly\/domain-list-community\/releases\/download\/$(GEOSITE_VER)\//github.com\/Loyalsoldier\/v2ray-rules-dat\/releases\/latest\/download\//' feeds/xiaorouji/v2ray-geodata/Makefile
sed -i 's/dlc.dat/geosite.dat/' feeds/xiaorouji/v2ray-geodata/Makefile
sed -i 's/HASH:=.*/HASH:=skip/' feeds/xiaorouji/v2ray-geodata/Makefile

#sed -i 's/PKG_VERSION:=2024.03.07/PKG_VERSION:=2023.10.28/' feeds/xiaorouji/chinadns-ng/Makefile
#sed -i 's/PKG_HASH:=.*/PKG_HASH:=skip/' feeds/xiaorouji/chinadns-ng/Makefile

#更改haproxy内核版本
sed -i 's/www.haproxy.org\/download\/2.8\/src/www.haproxy.org\/download\/3.2\/src/' feeds/packages/haproxy/Makefile
sed -i 's/PKG_VERSION:=2.*/PKG_VERSION:=3.2.1/' feeds/packages/haproxy/Makefile
#sed -i 's/PKG_HASH:=.*/PKG_HASH:=$(cat <(curl $(PKG_SOURCE_URL)\/$(PKG_NAME)-$(PKG_VERSION).tar.gz.sha256))/' feeds/packages/haproxy/Makefile
#sed -i 's/PKG_HASH:=.*/PKG_HASH:=a02ad64550dd30a94b25fd0e225ba699649d0c4037bca3b36b20e8e3235bb86f/' feeds/packages/haproxy/Makefile
sed -i 's/PKG_HASH:=.*/PKG_HASH:=skip/' feeds/packages/haproxy/Makefile
sed -i 's/BASE_TAG=v2.*/BASE_TAG=v3.2.1/' feeds/packages/haproxy/get-latest-patches.sh

#修复ipt2socks无法正确监听IPV6，并开启双线程
sed -i 's/-b 0.0.0.0 -s/-b 0.0.0.0 -B :: -j 2 -s/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/app.sh


# ① 在 defaults 段落里插入 `option tcp-check`
sed -i '/^[[:space:]]*option[[:space:]]\+tcplog/a\    option tcp-check' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
# ② 把 retries 2 → 1（允许任意空格）
sed -Ei 's/([[:space:]]retries[[:space:]]+)2/\11/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
# ③ 把 timeout client 1m → 30m
sed -Ei 's/(timeout[[:space:]]+client[[:space:]]+)1m/\130m/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
# ④ 把 timeout server 1m → 6m
sed -Ei 's/(timeout[[:space:]]+server[[:space:]]+)1m/\16m/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
# ⑤ 保持原有 rise/fall 改写（仍然能匹配，留作备份）
sed -i 's/rise[[:space:]]\+1[[:space:]]\+fall[[:space:]]\+3[[:space:]]\+{{backup}}/rise 6 fall 1 {{backup}}  on-marked-down shutdown-sessions/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua
# ⑥ haproxy_check.sh 里已经是 --retry 1，可不再改；
#    若想保持脚本向后兼容，可写成“只要不是 1 就替换”
sed -Ei 's/--connect-timeout 3 --retry +[0-9]+/--connect-timeout 3 --retry 1/' feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy_check.sh

#sed -i 's/,"bing.com"//g' feeds/passwall/luci-app-passwall/root/usr/share/passwall/rule_update.lua

sed -i '/domain:bing.com/d' feeds/sbwml/luci-app-mosdns/root/etc/mosdns/rule/whitelist.txt
echo "domain:bing.com" >> feeds/sbwml/luci-app-mosdns/root/etc/mosdns/rule/greylist.txt


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
