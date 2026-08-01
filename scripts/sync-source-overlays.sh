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

manifest="$(PYTHONPATH="$repo_root/scripts" python3 - "$lock_file" "$repo_root" <<'PY'
import json
import pathlib
import sys

import source_lock

lock_path = pathlib.Path(sys.argv[1])
repo_root = pathlib.Path(sys.argv[2])
try:
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    raise SystemExit(f"::error::Cannot read source lock: {exc}") from exc
if not isinstance(lock, dict) or lock.get("schema") != 3:
    raise SystemExit("::error::Unsupported source-lock schema")
try:
    source_lock.validate_source_overlays(lock.get("source_overlays"), repo_root)
except source_lock.ResolutionError as exc:
    raise SystemExit(f"::error::{exc}") from exc

for identifier in sorted(lock["source_overlays"]):
    entry = lock["source_overlays"][identifier]
    print("\t".join(("R", identifier, entry["url"], entry["commit"])))
    for mapping in entry["mappings"]:
        print("\t".join(("M", identifier, mapping["source"], mapping["target"])))
PY
)" || exit

declare -a overlay_ids=()
declare -A overlay_urls=()
declare -A overlay_commits=()
declare -A overlay_sources=()
declare -A overlay_targets=()
while IFS=$'\t' read -r kind identifier first second; do
  case "$kind" in
    R)
      overlay_ids+=("$identifier")
      overlay_urls["$identifier"]="$first"
      overlay_commits["$identifier"]="$second"
      ;;
    M)
      overlay_sources["$identifier"]+="$first"$'\n'
      overlay_targets["$identifier|$first"]="$second"
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

  git -C "$tmpdir" init -q "$identifier"
  git -C "$repo_dir" remote add origin "${overlay_urls[$identifier]}"
  git -C "$repo_dir" sparse-checkout init --cone
  git -C "$repo_dir" sparse-checkout set "${sources[@]}"
  git -C "$repo_dir" fetch --depth 1 --filter=blob:none \
    origin "${overlay_commits[$identifier]}"
  git -C "$repo_dir" checkout -q --detach FETCH_HEAD
  [ "$(git -C "$repo_dir" rev-parse HEAD)" = "${overlay_commits[$identifier]}" ] || {
    echo "::error::Source overlay checkout differs from the lock: $identifier" >&2
    exit 1
  }

  for source_relative in "${sources[@]}"; do
    source="$repo_dir/$source_relative"
    [ -d "$source" ] || {
      echo "::error::Locked source overlay subtree is missing: $identifier:$source_relative" >&2
      exit 2
    }
    mapping_key="$identifier|$source_relative"
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
    synced+=("$identifier:$source_relative->$target_relative")
  done
done

printf 'Synced source-locked overlays: %s\n' "${synced[*]}"
