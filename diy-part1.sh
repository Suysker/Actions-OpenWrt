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

# Add custom feed sources from the repository-level single source of truth.
REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FEEDS_FILE="feeds.conf.default"
[ -f feeds.conf ] && FEEDS_FILE="feeds.conf"

bash "$REPO_DIR/scripts/manage-custom-feeds.sh" apply "$REPO_DIR/feeds.custom.conf" "$FEEDS_FILE"


#echo 'src-git opluci https://git.openwrt.org/project/luci.git' >>feeds.conf.default
#sed -i '1a src-git opluci https://git.openwrt.org/project/luci.git' feeds.conf.default
