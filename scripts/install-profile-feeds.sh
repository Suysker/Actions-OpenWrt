#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <openwrt-root> <rendered-required-rules> [report]" >&2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
openwrt_root="${1:-}"
required_rules="${2:-}"
report="${3:-$openwrt_root/profile-feed-install-report.txt}"

[ "$#" -ge 2 ] && [ "$#" -le 3 ] || { usage; exit 2; }
[ -x "$openwrt_root/scripts/feeds" ] || {
  echo "::error::OpenWrt feeds tool is missing: $openwrt_root/scripts/feeds" >&2
  exit 2
}
[ -r "$required_rules" ] || {
  echo "::error::Rendered required rules are missing: $required_rules" >&2
  exit 2
}

mapfile -t packages < <(
  python3 "$repo_root/scripts/profile_model.py" \
    list-required-packages "$required_rules"
)
[ "${#packages[@]}" -gt 0 ] || {
  echo "::error::Profile declares no required packages" >&2
  exit 1
}

(
  cd "$openwrt_root"
  ./scripts/feeds install "${packages[@]}"
)

mkdir -p "$(dirname "$report")"
{
  echo "profile-feed-install-v1"
  echo "requested_count=${#packages[@]}"
  printf 'requested\t%s\n' "${packages[@]}"
} > "$report"

echo "Installed the profile feed closure for ${#packages[@]} required package(s)."
