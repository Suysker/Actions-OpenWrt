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
  bash "$repo_root/scripts/render-profile.sh" files "$profile" "$tmpdir/$profile-files"
  [ -f "$tmpdir/$profile-files/etc/uci-defaults/90-common-network" ]
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
