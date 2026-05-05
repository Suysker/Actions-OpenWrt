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

set -e

cd package

sed_if_file() {
  local file="$1"
  shift

  if [ -f "$file" ]; then
    sed -i "$@" "$file"
  else
    echo "Skipping missing file: $file"
  fi
}

sed_ext_if_file() {
  local file="$1"
  shift

  if [ -f "$file" ]; then
    sed -Ei "$@" "$file"
  else
    echo "Skipping missing file: $file"
  fi
}

first_existing_file() {
  local file

  for file in "$@"; do
    if [ -f "$file" ]; then
      printf '%s\n' "$file"
      return 0
    fi
  done

  return 1
}

# Default LAN IP for both public-source profiles.
sed_if_file base-files/files/bin/config_generate 's/192.168.1.1/192.168.2.1/g; s/10.0.0.1/192.168.2.1/g'

# Lean-only default DNS redirect rules are absent in the R4S tree, so these are
# guarded for branch portability.
sed_if_file lean/default-settings/files/zzz-default-settings '39,45s/echo/#echo/'
sed_if_file lean/default-settings/files/zzz-default-settings '/REDIRECT --to-ports 53/d'

# Prevent PassWall from disabling local hostname resolution when the helper
# exists in the selected feed.
sed_if_file feeds/passwall/luci-app-passwall/root/usr/share/passwall/helper_dnsmasq.lua \
  '/conf_out:write("no-resolv\\n")/d; /tinsert(conf_lines, "no-resolv")/d'

# Use Loyalsoldier geodata mirrors and skip hash churn.
v2ray_geodata_makefile="$(
  first_existing_file \
    feeds/xiaorouji/v2ray-geodata/Makefile \
    feeds/packages/v2ray-geodata/Makefile \
    new/helloworld/v2ray-geodata/Makefile || true
)"
if [ -n "$v2ray_geodata_makefile" ]; then
  sed -i 's#github.com/v2fly/geoip/releases/download/$(GEOIP_VER)/#github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/#' "$v2ray_geodata_makefile"
  sed -i 's#github.com/v2fly/domain-list-community/releases/download/$(GEOSITE_VER)/#github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/#' "$v2ray_geodata_makefile"
  sed -i 's/dlc.dat/geosite.dat/' "$v2ray_geodata_makefile"
  sed -i 's/HASH:=.*/HASH:=skip/' "$v2ray_geodata_makefile"
else
  echo "Skipping missing v2ray-geodata Makefile"
fi

# Automatically use the latest HAProxy official LTS release.
# HAProxy even minor branches are LTS; odd minor stable branches are skipped.
# Set HAPROXY_VERSION in the workflow only to pin or roll back temporarily.
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
  local makefile patch_script version branch

  makefile="$(
    first_existing_file \
      feeds/packages/haproxy/Makefile \
      feeds/packages/net/haproxy/Makefile || true
  )"

  if [ -z "$makefile" ]; then
    echo "Skipping missing HAProxy Makefile"
    return 0
  fi

  patch_script="$(dirname "$makefile")/get-latest-patches.sh"
  version="${HAPROXY_VERSION:-}"

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

# PassWall runtime tuning.
sed_if_file feeds/passwall/luci-app-passwall/root/usr/share/passwall/app.sh \
  's/-b 0.0.0.0 -s/-b 0.0.0.0 -B :: -j 2 -s/'

passwall_haproxy_lua="feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy.lua"
sed_if_file "$passwall_haproxy_lua" '/^[[:space:]]*option[[:space:]]\+tcplog/a\    option tcp-check'
sed_ext_if_file "$passwall_haproxy_lua" 's/([[:space:]]retries[[:space:]]+)2/\11/'
sed_ext_if_file "$passwall_haproxy_lua" 's/(timeout[[:space:]]+client[[:space:]]+)1m/\130m/'
sed_ext_if_file "$passwall_haproxy_lua" 's/(timeout[[:space:]]+server[[:space:]]+)1m/\16m/'
sed_if_file "$passwall_haproxy_lua" 's/rise[[:space:]]\+1[[:space:]]\+fall[[:space:]]\+3[[:space:]]\+{{backup}}/rise 6 fall 1 {{backup}}  on-marked-down shutdown-sessions/'
sed_ext_if_file feeds/passwall/luci-app-passwall/root/usr/share/passwall/haproxy_check.sh \
  's/--connect-timeout 3 --retry +[0-9]+/--connect-timeout 3 --retry 1/'

# MosDNS rule tweak when the sbwml LuCI package is present.
mosdns_root="$(
  for dir in feeds/sbwml/luci-app-mosdns new/mosdns; do
    if [ -d "$dir/root/etc/mosdns/rule" ]; then
      printf '%s\n' "$dir/root/etc/mosdns"
      break
    fi
  done
)"
if [ -n "$mosdns_root" ]; then
  sed_if_file "$mosdns_root/rule/whitelist.txt" '/domain:bing.com/d'
  echo "domain:bing.com" >> "$mosdns_root/rule/greylist.txt"
else
  echo "Skipping missing MosDNS rule directory"
fi

# Allow AdGuardHome in-firmware updater and follow current upstream binary hash.
sed_if_file feeds/kenzo/adguardhome/files/adguardhome.init '/--no-check-update/d'
sed_if_file feeds/kenzo/adguardhome/Makefile 's/PKG_HASH:=.*/PKG_HASH:=skip/'
