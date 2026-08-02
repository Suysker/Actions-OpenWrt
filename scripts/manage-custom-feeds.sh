#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  manage-custom-feeds.sh apply-lock <source-lock.json> <feeds.conf.default>
  manage-custom-feeds.sh reindex-lock <source-lock.json> <openwrt-root>
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
source_lock="$repo_root/scripts/source_lock.py"
cmd="${1:-}"

case "$cmd" in
  apply-lock)
    lock_file="${2:-}"
    target_file="${3:-}"
    if [ -z "$lock_file" ] || [ -z "$target_file" ]; then
      usage
      exit 2
    fi
    python3 "$source_lock" render-feeds "$lock_file" "$target_file"
    ;;

  reindex-lock)
    lock_file="${2:-}"
    openwrt_root="${3:-}"
    if [ -z "$lock_file" ] || [ -z "$openwrt_root" ]; then
      usage
      exit 2
    fi
    if [ ! -x "$openwrt_root/scripts/feeds" ]; then
      echo "::error::OpenWrt feeds helper not found: $openwrt_root/scripts/feeds" >&2
      exit 2
    fi

    openwrt_root="$(cd "$openwrt_root" && pwd -P)"
    mapfile -t feed_names < <(python3 "$source_lock" list-feeds "$lock_file")
    [ "${#feed_names[@]}" -gt 0 ] || {
      echo "::error::Source lock contains no feeds" >&2
      exit 2
    }
    for feed in "${feed_names[@]}"; do
      (cd "$openwrt_root" && ./scripts/feeds update -i "$feed")
    done
    echo "Reindexed ${#feed_names[@]} source-locked feed(s)."
    ;;

  *)
    usage
    exit 2
    ;;
esac
