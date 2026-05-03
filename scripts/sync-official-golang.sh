#!/usr/bin/env bash
set -euo pipefail

repo="${OFFICIAL_GOLANG_REPO:-https://github.com/openwrt/packages.git}"
ref="${OFFICIAL_GOLANG_REF:-master}"

usage() {
  cat >&2 <<'EOF'
Usage:
  sync-official-golang.sh apply [openwrt-root]
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

  apply)
    openwrt_root="${2:-.}"
    target="$openwrt_root/feeds/packages/lang/golang"
    tmpdir="$(mktemp -d)"
    checkout_ref="$ref"

    trap 'rm -rf "$tmpdir"' EXIT

    case "$checkout_ref" in
      refs/heads/*) checkout_ref="${checkout_ref#refs/heads/}" ;;
      refs/tags/*) checkout_ref="${checkout_ref#refs/tags/}" ;;
    esac

    if [ ! -d "$openwrt_root/feeds/packages" ]; then
      echo "::error::Default packages feed not found: $openwrt_root/feeds/packages" >&2
      exit 2
    fi

    git clone --depth 1 --filter=blob:none --sparse --branch "$checkout_ref" "$repo" "$tmpdir/packages"
    git -C "$tmpdir/packages" sparse-checkout set lang/golang

    if [ ! -d "$tmpdir/packages/lang/golang" ]; then
      echo "::error::Official golang package directory not found in $repo $ref" >&2
      exit 2
    fi

    rm -rf "$target"
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
