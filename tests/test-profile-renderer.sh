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
  bash "$repo_root/scripts/render-profile.sh" required "$profile" "$tmpdir/$profile.required"
  bash "$repo_root/scripts/render-profile.sh" forbidden "$profile" "$tmpdir/$profile.forbidden"
  python3 - "$repo_root" "$tmpdir/$profile.config" \
    "$tmpdir/$profile.required" "$tmpdir/$profile.forbidden" <<'PY'
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "scripts"))
from profile_model import load_forbidden, load_required, parse_config

config = parse_config(pathlib.Path(sys.argv[2]))
required = load_required(pathlib.Path(sys.argv[3]))
forbidden = load_forbidden(pathlib.Path(sys.argv[4]))
for package in required.packages:
    assert config[f"CONFIG_PACKAGE_{package}"] == "y"
for symbol in required.configs:
    assert config[symbol] == "y"
for package in forbidden.exact:
    assert config[f"CONFIG_PACKAGE_{package}"] == "n"
PY
  if grep -q '^CONFIG_PACKAGE_luci-i18n-.*-zh-cn=y$' "$tmpdir/$profile.config"; then
    echo "renderer emitted a hidden per-package LuCI translation seed for $profile" >&2
    exit 1
  fi
done

# A common/device symbol collision must be rejected.
cp -a "$repo_root/profiles" "$tmpdir/profiles"
printf '\nCONFIG_DEVEL=y\n' >> "$tmpdir/profiles/r4s/config.seed"
if PROFILE_ROOT_OVERRIDE="$tmpdir/profiles" \
  bash "$repo_root/scripts/render-profile.sh" config r4s "$tmpdir/collision.config" \
  >"$tmpdir/collision.out" 2>&1; then
  echo "renderer accepted a common/device config collision" >&2
  exit 1
fi
grep -q 'both own entries' "$tmpdir/collision.out"

# A symbol derived from required rules must not be copied into config.seed.
rm -rf "$tmpdir/profiles"
cp -a "$repo_root/profiles" "$tmpdir/profiles"
printf '\nCONFIG_PACKAGE_firewall=y\n' >> "$tmpdir/profiles/common/config.seed"
if PROFILE_ROOT_OVERRIDE="$tmpdir/profiles" \
  bash "$repo_root/scripts/render-profile.sh" config r4s "$tmpdir/required-owner.config" \
  >"$tmpdir/required-owner.out" 2>&1; then
  echo "renderer accepted duplicate seed/required ownership" >&2
  exit 1
fi
grep -q 'repeats symbols owned by required/forbidden rules' \
  "$tmpdir/required-owner.out"

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
grep -q 'repeats symbols owned by required/forbidden rules' \
  "$tmpdir/forbidden.out"

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
