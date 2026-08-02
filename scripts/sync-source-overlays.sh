#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: sync-source-overlays.sh apply-lock <source-lock.json> [openwrt-root]" >&2
}

[ "${1:-}" = "apply-lock" ] || {
  usage
  exit 2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
lock_file="${2:-}"
openwrt_root="${3:-.}"
[ -r "$lock_file" ] || {
  echo "::error::Source lock not found: $lock_file" >&2
  exit 2
}
[ -d "$openwrt_root/.git" ] || {
  echo "::error::OpenWrt source is not a Git checkout: $openwrt_root" >&2
  exit 2
}

manifest="$(python3 "$repo_root/scripts/source_lock.py" \
  overlay-manifest "$lock_file")" || exit

declare -a overlay_ids=()
declare -A overlay_urls=()
declare -A overlay_commits=()
declare -A overlay_sources=()
declare -A overlay_kinds=()
declare -A overlay_targets=()
while IFS=$'\t' read -r record identifier first second third; do
  case "$record" in
    R)
      overlay_ids+=("$identifier")
      overlay_urls["$identifier"]="$first"
      overlay_commits["$identifier"]="$second"
      ;;
    M)
      overlay_sources["$identifier"]+="$second"$'\n'
      overlay_kinds["$identifier|$second"]="$first"
      overlay_targets["$identifier|$second"]="$third"
      ;;
    *)
      echo "::error::Invalid source overlay manifest record" >&2
      exit 2
      ;;
  esac
done <<< "$manifest"
[ "${#overlay_ids[@]}" -gt 0 ] || {
  echo "::error::Source lock contains no overlay repositories" >&2
  exit 2
}

openwrt_root="$(cd "$openwrt_root" && pwd -P)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
synced=()

for identifier in "${overlay_ids[@]}"; do
  repo_dir="$tmpdir/$identifier"
  sources_text="${overlay_sources[$identifier]:-}"
  [ -n "$sources_text" ] || {
    echo "::error::Source overlay $identifier has no mappings" >&2
    exit 2
  }
  sources_text="${sources_text%$'\n'}"
  readarray -t sources <<< "$sources_text"
  sparse_paths=()
  for source_relative in "${sources[@]}"; do
    mapping_key="$identifier|$source_relative"
    source_kind="${overlay_kinds[$mapping_key]:-}"
    case "$source_kind" in
      tree) sparse_path="$source_relative" ;;
      file) sparse_path="${source_relative%/*}" ;;
      *)
        echo "::error::Source overlay mapping has an invalid kind: $identifier:$source_relative" >&2
        exit 2
        ;;
    esac
    if [[ " ${sparse_paths[*]} " != *" $sparse_path "* ]]; then
      sparse_paths+=("$sparse_path")
    fi
  done

  git -C "$tmpdir" init -q "$identifier"
  git -C "$repo_dir" remote add origin "${overlay_urls[$identifier]}"
  git -C "$repo_dir" sparse-checkout init --cone
  git -C "$repo_dir" sparse-checkout set "${sparse_paths[@]}"
  git -C "$repo_dir" fetch --depth 1 --filter=blob:none \
    origin "${overlay_commits[$identifier]}"
  git -C "$repo_dir" checkout -q --detach FETCH_HEAD
  [ "$(git -C "$repo_dir" rev-parse HEAD)" = "${overlay_commits[$identifier]}" ] || {
    echo "::error::Source overlay checkout differs from the lock: $identifier" >&2
    exit 1
  }

  for source_relative in "${sources[@]}"; do
    source="$repo_dir/$source_relative"
    mapping_key="$identifier|$source_relative"
    source_kind="${overlay_kinds[$mapping_key]:-}"
    case "$source_kind" in
      tree) [ -d "$source" ] ;;
      file) [ -f "$source" ] && [ ! -L "$source" ] ;;
      *) false ;;
    esac || {
      echo "::error::Locked source overlay $source_kind is missing: $identifier:$source_relative" >&2
      exit 2
    }
    target_relative="${overlay_targets[$mapping_key]:-}"
    [ -n "$target_relative" ] || {
      echo "::error::Source overlay mapping has no target: $identifier:$source_relative" >&2
      exit 2
    }
    target="$openwrt_root/$target_relative"
    mkdir -p "$(dirname "$target")"
    target_parent="$(cd "$(dirname "$target")" && pwd -P)"
    case "$target_parent/" in
      "$openwrt_root/"*) ;;
      *)
        echo "::error::Refusing source overlay target outside OpenWrt: $target_relative" >&2
        exit 2
        ;;
    esac
    target_resolved="$target_parent/$(basename "$target")"
    rm -rf -- "$target_resolved"
    cp -a "$source" "$target_resolved"
    synced+=("$identifier:$source_kind:$source_relative->$target_relative")
  done
done

printf 'Synced source-locked overlays: %s\n' "${synced[*]}"
