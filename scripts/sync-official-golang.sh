#!/usr/bin/env bash
set -euo pipefail

repo="${OFFICIAL_GOLANG_REPO:-https://github.com/openwrt/packages.git}"
ref="${OFFICIAL_GOLANG_REF:-master}"

usage() {
  cat >&2 <<'EOF'
Usage:
  sync-official-golang.sh apply [openwrt-root]
  sync-official-golang.sh apply-lock <source-lock.json> [openwrt-root]
  sync-official-golang.sh refs
EOF
}

cmd="${1:-}"

case "$cmd" in
  refs)
    case "$ref" in
      refs/*) resolved_ref="$ref" ;;
      *) resolved_ref="refs/heads/$ref" ;;
    esac

    printf 'official-golang %s %s\n' "$repo" "$resolved_ref"
    ;;

  apply|apply-lock)
    if [ "$cmd" = "apply-lock" ]; then
      lock_file="${2:-}"
      openwrt_root="${3:-.}"
      [ -r "$lock_file" ] || {
        echo "::error::Source lock not found: $lock_file" >&2
        exit 2
      }
      readarray -t locked < <(python3 - "$lock_file" <<'PY'
import json
import re
import sys

lock = json.load(open(sys.argv[1], encoding="utf-8"))
entry = lock.get("official_golang", {})
url = entry.get("url", "")
commit = entry.get("commit", "")
if not url.startswith("https://") or not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("::error::Invalid official_golang source lock entry")
print(url)
print(commit)
PY
      )
      repo="${locked[0]}"
      ref="${locked[1]}"
    else
      openwrt_root="${2:-.}"
    fi

    target="$openwrt_root/feeds/packages/lang/golang"
    tmpdir="$(mktemp -d)"

    trap 'rm -rf "$tmpdir"' EXIT

    if [ ! -d "$openwrt_root/feeds/packages" ]; then
      echo "::error::Default packages feed not found: $openwrt_root/feeds/packages" >&2
      exit 2
    fi

    git -C "$tmpdir" init -q packages
    git -C "$tmpdir/packages" remote add origin "$repo"
    git -C "$tmpdir/packages" sparse-checkout init --cone
    git -C "$tmpdir/packages" sparse-checkout set lang/golang
    git -C "$tmpdir/packages" fetch --depth 1 --filter=blob:none origin "$ref"
    git -C "$tmpdir/packages" checkout -q --detach FETCH_HEAD

    if [ ! -d "$tmpdir/packages/lang/golang" ]; then
      echo "::error::Official golang package directory not found in $repo $ref" >&2
      exit 2
    fi

    target_parent="$(cd "$(dirname "$target")" && pwd -P)"
    openwrt_resolved="$(cd "$openwrt_root" && pwd -P)"
    case "$target_parent/$(basename "$target")" in
      "$openwrt_resolved"/feeds/packages/lang/golang) ;;
      *)
        echo "::error::Refusing unsafe Go subtree target: $target" >&2
        exit 2
        ;;
    esac
    rm -rf -- "$target"
    mkdir -p "$(dirname "$target")"
    cp -a "$tmpdir/packages/lang/golang" "$target"

    version="$(sed -n 's/^GO_DEFAULT_VERSION:=//p' "$target/golang-values.mk" | head -1)"
    echo "Synced official OpenWrt golang feed from $repo $ref (default Go ${version:-unknown})."
    ;;

  *)
    usage
    exit 2
    ;;
esac
