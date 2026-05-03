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

cd package

#sed -i '$anet.core.rmem_max=2097152' base-files/files/etc/sysctl.d/10-default.conf

#更改默认IP地址（150行）
sed -i 's/192.168.1.1/192.168.2.1/' base-files/files/bin/config_generate

#取消53端口防火墙规则（40-43行）
sed -i '39,45s/echo/#echo/' lean/default-settings/files/zzz-default-settings
sed -i '/REDIRECT --to-ports 53/d'  lean/default-settings/files/zzz-default-settings

#防止不解析本机域名
sed -i '/conf_out:write("no-resolv\\n")/d; /tinsert(conf_lines, "no-resolv")/d' feeds/passwall/luci-app-passwall/root/usr/share/passwall/helper_dnsmasq.lua

#更改默认geoip和geosite
sed -i 's/github.com\/v2fly\/geoip\/releases\/download\/$(GEOIP_VER)\//github.com\/Loyalsoldier\/v2ray-rules-dat\/releases\/latest\/download\//' feeds/xiaorouji/v2ray-geodata/Makefile
sed -i 's/github.com\/v2fly\/domain-list-community\/releases\/download\/$(GEOSITE_VER)\//github.com\/Loyalsoldier\/v2ray-rules-dat\/releases\/latest\/download\//' feeds/xiaorouji/v2ray-geodata/Makefile
sed -i 's/dlc.dat/geosite.dat/' feeds/xiaorouji/v2ray-geodata/Makefile
sed -i 's/HASH:=.*/HASH:=skip/' feeds/xiaorouji/v2ray-geodata/Makefile

# 自动使用 HAProxy 官方下载目录里的最新 LTS 版。
# HAProxy 偶数小版本分支是 LTS；奇数小版本 stable 分支自动跳过。
# 如遇上游新版本编译失败，可在 workflow 里临时设置 HAPROXY_VERSION=3.2.x 固定版本。
latest_haproxy_lts_version() {
  local branch minor version

  curl -fsSL https://www.haproxy.org/download/ |
    sed -nE 's/.*href="([0-9]+\.[0-9]+)\/".*/\1/p' |
    sort -Vr |
    while read -r branch; do
      minor="${branch#*.}"
      if [ $((minor % 2)) -ne 0 ]; then
        continue
      fi

      version="$(
        curl -fsSL "https://www.haproxy.org/download/${branch}/src/" 2>/dev/null |
          sed -nE 's/.*haproxy-([0-9]+\.[0-9]+\.[0-9]+)\.tar\.gz".*/\1/p' |
          sort -V |
          tail -n 1
      )"

      if [ -n "$version" ]; then
        printf '%s\n' "$version"
        return 0
      fi
    done
}

update_haproxy_package() {
  local makefile="feeds/packages/haproxy/Makefile"
  local patch_script="feeds/packages/haproxy/get-latest-patches.sh"
  local version="${HAPROXY_VERSION:-}"
  local branch

  if [ ! -f "$makefile" ]; then
    echo "HAProxy Makefile not found: $makefile" >&2
    exit 1
  fi

  if [ -z "$version" ]; then
    version="$(latest_haproxy_lts_version)"
  fi

  if ! printf '%s\n' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
    echo "Unable to resolve latest HAProxy LTS version, got: $version" >&2
    exit 1
  fi

  branch="${version%.*}"
  echo "Using HAProxy ${version} from ${branch} branch"

  sed -Ei "s#^PKG_VERSION:=.*#PKG_VERSION:=${version}#" "$makefile"
  sed -Ei "s#^PKG_SOURCE_URL:=.*#PKG_SOURCE_URL:=https://www.haproxy.org/download/${branch}/src#" "$makefile"
  sed -Ei 's#^PKG_HASH:=.*#PKG_HASH:=skip#' "$makefile"

  if [ -f "$patch_script" ]; then
    sed -Ei "s#^BASE_TAG=v.*#BASE_TAG=v${version}#" "$patch_script"
  fi
}

update_haproxy_package

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

sed -i '/domain:bing.com/d' feeds/sbwml/luci-app-mosdns/root/etc/mosdns/rule/whitelist.txt
echo "domain:bing.com" >> feeds/sbwml/luci-app-mosdns/root/etc/mosdns/rule/greylist.txt

#解除Adguardhome更新
sed -i '/--no-check-update/d' feeds/kenzo/adguardhome/files/adguardhome.init
sed -i 's/PKG_HASH:=.*/PKG_HASH:=skip/' feeds/kenzo/adguardhome/Makefile
