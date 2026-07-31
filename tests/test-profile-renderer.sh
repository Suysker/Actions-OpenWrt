#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mapfile -t profiles < <(bash "$repo_root/scripts/render-profile.sh" list)
[ "${profiles[*]}" = "r4s x86-n5105-pve" ]

for profile in "${profiles[@]}"; do
  bash "$repo_root/scripts/check-profile-contract.sh" "$profile" \
    > "$tmpdir/$profile.contract.txt"
  bash "$repo_root/scripts/render-profile.sh" config "$profile" "$tmpdir/$profile.config"
  grep -qx 'CONFIG_LUCI_LANG_zh_Hans=y' "$tmpdir/$profile.config"
  grep -qx '# CONFIG_PACKAGE_luci-app-ssr-plus is not set' "$tmpdir/$profile.config"
  grep -qx '# CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Mihomo is not set' "$tmpdir/$profile.config"
  grep -qx '# CONFIG_PACKAGE_block-mount is not set' "$tmpdir/$profile.config"
  if grep -q '^CONFIG_PACKAGE_luci-i18n-.*-zh-cn=y$' "$tmpdir/$profile.config"; then
    echo "renderer emitted a hidden per-package LuCI translation seed for $profile" >&2
    exit 1
  fi
  bash "$repo_root/scripts/render-profile.sh" files "$profile" "$tmpdir/$profile-files"
  network_defaults="$tmpdir/$profile-files/etc/uci-defaults/90-common-network"
  [ -f "$network_defaults" ]
  for expected in \
    "set dhcp.lan.start='32'" \
    "set dhcp.lan.limit='232'" \
    "set dhcp.lan.ra='server'" \
    "set dhcp.lan.dhcpv6='relay'" \
    "set dhcp.lan.ndp='relay'" \
    "set dhcp.wan.ra='relay'" \
    "set dhcp.wan.dhcpv6='relay'" \
    "set dhcp.wan.ndp='relay'" \
    "set dhcp.wan.master='1'"; do
    grep -Fqx "$expected" "$network_defaults"
  done
  if grep -Fqx "set dhcp.lan.dhcpv6='server'" "$network_defaults"; then
    echo "renderer retained the unwanted LAN DHCPv6 server default for $profile" >&2
    exit 1
  fi
done

# A common/device symbol collision must be rejected.
cp -a "$repo_root/profiles" "$tmpdir/profiles"
printf '\nCONFIG_PACKAGE_firewall=y\n' >> "$tmpdir/profiles/r4s/config.seed"
if PROFILE_ROOT_OVERRIDE="$tmpdir/profiles" \
  bash "$repo_root/scripts/render-profile.sh" config r4s "$tmpdir/collision.config" \
  >"$tmpdir/collision.out" 2>&1; then
  echo "renderer accepted a common/device config collision" >&2
  exit 1
fi
grep -q 'both own entries' "$tmpdir/collision.out"

# An exact-forbidden package must never be selected by either seed layer.
rm -rf "$tmpdir/profiles"
cp -a "$repo_root/profiles" "$tmpdir/profiles"
printf '\nCONFIG_PACKAGE_luci-app-ssr-plus=y\n' >> "$tmpdir/profiles/common/config.seed"
if PROFILE_ROOT_OVERRIDE="$tmpdir/profiles" \
  bash "$repo_root/scripts/render-profile.sh" config r4s "$tmpdir/forbidden.config" \
  >"$tmpdir/forbidden.out" 2>&1; then
  echo "renderer accepted an exact-forbidden selected package" >&2
  exit 1
fi
grep -q 'Forbidden exact package is selected' "$tmpdir/forbidden.out"

# A rootfs collision must be rejected instead of silently overriding common.
rm -rf "$tmpdir/profiles"
cp -a "$repo_root/profiles" "$tmpdir/profiles"
mkdir -p "$tmpdir/profiles/r4s/files/etc/uci-defaults"
cp "$tmpdir/profiles/common/files/etc/uci-defaults/90-common-network" \
  "$tmpdir/profiles/r4s/files/etc/uci-defaults/90-common-network"
if PROFILE_ROOT_OVERRIDE="$tmpdir/profiles" \
  bash "$repo_root/scripts/render-profile.sh" files r4s "$tmpdir/collision-files" \
  >"$tmpdir/files-collision.out" 2>&1; then
  echo "renderer accepted a common/device rootfs collision" >&2
  exit 1
fi
grep -q 'rootfs files overlap' "$tmpdir/files-collision.out"

echo "Profile renderer tests passed."
