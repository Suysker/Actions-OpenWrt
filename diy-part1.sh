#!/bin/bash
#
# https://github.com/P3TERX/Actions-OpenWrt
# File name: diy-part1.sh
# Description: OpenWrt DIY script part 1 (Before Update feeds)
#
# Copyright (c) 2019-2024 P3TERX <https://p3terx.com>
#
# This is free software, licensed under the MIT License.
# See /LICENSE for more information.
#

# Uncomment a feed source
#sed -i 's/^#\(.*helloworld\)/\1/' feeds.conf.default

# Add a feed source
#echo 'src-git helloworld https://github.com/fw876/helloworld' >>feeds.conf.default
#echo 'src-git passwall https://github.com/xiaorouji/openwrt-passwall' >>feeds.conf.default
sed -i '1i src-git golang https://github.com/kenzok8/golang' feeds/packages/lang/golang.git
sed -i '1i src-git small https://github.com/kenzok8/small' feeds.conf.default
sed -i '1i src-git kenzo https://github.com/kenzok8/openwrt-packages' feeds.conf.default
sed -i '1i src-git sbwml https://github.com/sbwml/luci-app-mosdns' feeds.conf.default
sed -i '1i src-git xiaorouji https://github.com/xiaorouji/openwrt-passwall-packages' feeds.conf.default
#sed -i '1i src-git passwall https://github.com/xiaorouji/openwrt-passwall.git;luci' feeds.conf.default
sed -i '1i src-git passwall https://github.com/xiaorouji/openwrt-passwall' feeds.conf.default


#echo 'src-git opluci https://git.openwrt.org/project/luci.git' >>feeds.conf.default
#sed -i '1a src-git opluci https://git.openwrt.org/project/luci.git' feeds.conf.default
