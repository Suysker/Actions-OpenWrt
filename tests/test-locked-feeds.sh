#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock="$repo_root/tests/fixtures/artifact-applicator/source-lock.json"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

bash "$repo_root/scripts/manage-custom-feeds.sh" apply-lock "$lock" "$tmpdir/feeds.conf.default"
mapfile -t feeds < <(grep '^src-git' "$tmpdir/feeds.conf.default")
[ "${#feeds[@]}" -eq 2 ]
[ "${feeds[0]}" = 'src-git passwall https://github.com/Openwrt-Passwall/openwrt-passwall.git^4444444444444444444444444444444444444444' ]
[ "${feeds[1]}" = 'src-git packages https://github.com/coolsnowwolf/packages^3333333333333333333333333333333333333333' ]
! grep -Eq ';(main|master)$|\^.{0,39}$' "$tmpdir/feeds.conf.default"

echo "Locked feed rendering tests passed."
