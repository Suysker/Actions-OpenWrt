#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: sync-official-packages.sh apply-lock <source-lock.json> [openwrt-root]" >&2
}

[ "${1:-}" = "apply-lock" ] || {
  usage
  exit 2
}

lock_file="${2:-}"
openwrt_root="${3:-.}"
[ -r "$lock_file" ] || {
  echo "::error::Source lock not found: $lock_file" >&2
  exit 2
}
[ -d "$openwrt_root/feeds/packages" ] || {
  echo "::error::Default packages feed not found: $openwrt_root/feeds/packages" >&2
  exit 2
}

mapfile -t locked < <(python3 - "$lock_file" <<'PY'
import json
import pathlib
import re
import sys
import urllib.parse

lock = json.load(open(sys.argv[1], encoding="utf-8"))
entry = lock.get("official_packages", {})
url = entry.get("url", "")
commit = entry.get("commit", "")
subtrees = entry.get("subtrees")
parsed = urllib.parse.urlparse(url)
if lock.get("schema") != 2:
    raise SystemExit("::error::Unsupported source-lock schema")
if (
    parsed.scheme != "https"
    or parsed.hostname != "github.com"
    or parsed.params
    or parsed.query
    or parsed.fragment
    or not re.fullmatch(r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git", parsed.path)
):
    raise SystemExit("::error::official_packages is not an exact GitHub repository URL")
if not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("::error::Invalid official_packages commit")
if not isinstance(subtrees, list) or not subtrees:
    raise SystemExit("::error::official_packages has no declared subtrees")
for subtree in subtrees:
    path = pathlib.PurePosixPath(subtree) if isinstance(subtree, str) else None
    if (
        path is None
        or path.is_absolute()
        or len(path.parts) != 2
        or ".." in path.parts
        or any(not re.fullmatch(r"[A-Za-z0-9_.+-]+", part) for part in path.parts)
    ):
        raise SystemExit(f"::error::Unsafe official package subtree: {subtree!r}")
if len(subtrees) != len(set(subtrees)):
    raise SystemExit("::error::official_packages subtree list contains duplicates")
print(url)
print(commit)
print(*subtrees, sep="\n")
PY
)
[ "${#locked[@]}" -ge 3 ] || {
  echo "::error::Could not parse official_packages source lock entry" >&2
  exit 2
}

repo="${locked[0]}"
ref="${locked[1]}"
subtrees=("${locked[@]:2}")
openwrt_root="$(cd "$openwrt_root" && pwd -P)"
packages_root="$(cd "$openwrt_root/feeds/packages" && pwd -P)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

git -C "$tmpdir" init -q packages
git -C "$tmpdir/packages" remote add origin "$repo"
git -C "$tmpdir/packages" sparse-checkout init --cone
git -C "$tmpdir/packages" sparse-checkout set "${subtrees[@]}"
git -C "$tmpdir/packages" fetch --depth 1 --filter=blob:none origin "$ref"
git -C "$tmpdir/packages" checkout -q --detach FETCH_HEAD
[ "$(git -C "$tmpdir/packages" rev-parse HEAD)" = "$ref" ] || {
  echo "::error::Official package checkout differs from the source lock" >&2
  exit 1
}

for subtree in "${subtrees[@]}"; do
  source="$tmpdir/packages/$subtree"
  [ -d "$source" ] || {
    echo "::error::Official package subtree not found in $repo $ref: $subtree" >&2
    exit 2
  }

  target="$packages_root/$subtree"
  mkdir -p "$(dirname "$target")"
  target_parent="$(cd "$(dirname "$target")" && pwd -P)"
  case "$target_parent/" in
    "$packages_root/"*) ;;
    *)
      echo "::error::Refusing unsafe official package subtree target: $target" >&2
      exit 2
      ;;
  esac
  target_resolved="$target_parent/$(basename "$target")"
  rm -rf -- "$target_resolved"
  cp -a "$source" "$target_resolved"
done

echo "Synced source-locked official OpenWrt package subtrees: ${subtrees[*]} ($ref)."
