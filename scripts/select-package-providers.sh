#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--check] <openwrt-root> [report]" >&2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mode="apply"
if [ "${1:-}" = "--check" ]; then
  mode="check"
  shift
fi
openwrt_root="${1:-}"
report="${2:-$openwrt_root/provider-selection-report.txt}"
contract="$repo_root/profiles/common/providers.tsv"

[ -n "$openwrt_root" ] || { usage; exit 2; }
[ -d "$openwrt_root/feeds" ] || {
  echo "::error::OpenWrt feeds directory is missing: $openwrt_root/feeds" >&2
  exit 2
}
[ -r "$contract" ] || {
  echo "::error::Provider contract is missing: $contract" >&2
  exit 2
}

openwrt_root="$(cd "$openwrt_root" && pwd -P)"
mkdir -p "$(dirname "$report")"
{
  echo "provider-contract-v3"
  echo "mode=$mode"
  echo "openwrt_root=$openwrt_root"
} > "$report"

declare -A removed=()
declare -A components=()
while IFS=$'\t' read -r component package expected_makefile conflicts extra; do
  [[ "$component" =~ ^[[:space:]]*(#|$) ]] && continue
  [ -n "${conflicts:-}" ] && [ -z "${extra:-}" ] || {
    echo "::error::Invalid provider contract row for $component" >&2
    exit 2
  }
  [[ "$component" =~ ^[A-Za-z0-9_.+-]+$ ]] || {
    echo "::error::Invalid provider component: $component" >&2
    exit 2
  }
  [[ "$package" =~ ^[A-Za-z0-9_.+-]+$ ]] || {
    echo "::error::Invalid provider package: $package" >&2
    exit 2
  }
  [ -z "${components[$component]+x}" ] || {
    echo "::error::Duplicate provider component: $component" >&2
    exit 2
  }
  components[$component]=1
  [[ "$expected_makefile" =~ ^feeds/[A-Za-z0-9_.+-]+(/[A-Za-z0-9_.+-]+)+/Makefile$ ]] || {
    echo "::error::Unsafe expected provider path: $expected_makefile" >&2
    exit 2
  }

  expected="$openwrt_root/$expected_makefile"
  [ -f "$expected" ] || {
    echo "::error::Expected $component provider is missing: $expected_makefile" >&2
    exit 1
  }
  package_pattern="$(printf '%s' "$package" | sed 's/[][\\.^$*+?{}|()]/\\&/g')"
  if ! grep -Eq "^define Package/${package_pattern}([/[:space:]]|$)" "$expected" && \
     ! grep -Eq "^PKG_NAME[[:space:]]*:?=[[:space:]]*${package_pattern}[[:space:]]*$" "$expected"; then
    echo "::error::Expected provider does not define $package: $expected_makefile" >&2
    exit 1
  fi

  printf 'selected\t%s\t%s\t%s\n' "$component" "$package" "$expected_makefile" >> "$report"
  [ "$conflicts" = "-" ] && continue

  IFS=',' read -r -a paths <<< "$conflicts"
  for relative in "${paths[@]}"; do
    [ -n "$relative" ] || continue
    [[ "$relative" == feeds/* ]] || {
      echo "::error::Unsafe provider conflict path: $relative" >&2
      exit 2
    }
    [ "$relative" != "feeds" ] || {
      echo "::error::Refusing broad provider conflict path: $relative" >&2
      exit 2
    }
    [ "$relative/Makefile" != "$expected_makefile" ] || {
      echo "::error::Provider conflict equals selected provider: $relative" >&2
      exit 2
    }

    candidate="$openwrt_root/$relative"
    [ -e "$candidate" ] || continue
    resolved_parent="$(cd "$(dirname "$candidate")" && pwd -P)"
    case "$resolved_parent/$(basename "$candidate")" in
      "$openwrt_root"/feeds/*) ;;
      *)
        echo "::error::Provider conflict path escapes OpenWrt feeds: $relative" >&2
        exit 2
        ;;
    esac

    if [ "$mode" = "check" ]; then
      echo "::error::Conflicting $component provider still exists: $relative" >&2
      exit 1
    fi
    if [ -z "${removed[$relative]+x}" ]; then
      rm -rf -- "$candidate"
      removed[$relative]=1
      printf 'removed\t%s\n' "$relative" >> "$report"
    fi
  done
done < "$contract"

echo "Package provider selection passed. Report: $report"
