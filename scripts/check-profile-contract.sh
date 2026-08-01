#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  check-profile-contract.sh <profile> [openwrt-root] [source-lock.json] [report] [diagnostics-dir]

With only a profile, validates repository-owned static contracts. With an
OpenWrt tree, also validates the final config/package set, providers, stable
kernel series, source lock and locked-source semantics through one model.
EOF
}

[ "$#" -ge 1 ] && [ "$#" -le 5 ] || { usage; exit 2; }

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="$1"
openwrt_root="${2:-}"
source_lock="${3:-}"
report="${4:-${CONTRACT_REPORT:-}}"
diagnostics="${5:-${CONTRACT_DIAGNOSTICS_DIR:-}}"
profiles_root="${PROFILE_ROOT_OVERRIDE:-$repo_root/profiles}"

arguments=(
  --repo-root "$repo_root"
  --profiles-root "$profiles_root"
  --profile "$profile"
)

if [ -n "$openwrt_root" ]; then
  [ -d "$openwrt_root" ] || {
    echo "::error::OpenWrt root does not exist: $openwrt_root" >&2
    exit 2
  }
  [ -n "$source_lock" ] && [ -r "$source_lock" ] || {
    echo "::error::A readable source lock is required with an OpenWrt tree" >&2
    exit 2
  }
  arguments+=(--openwrt "$openwrt_root" --source-lock "$source_lock")
elif [ -n "$source_lock" ]; then
  echo "::error::source-lock cannot be supplied without an OpenWrt tree" >&2
  exit 2
fi

[ -z "$report" ] || arguments+=(--report "$report")
[ -z "$diagnostics" ] || arguments+=(--diagnostics-dir "$diagnostics")

exec python3 "$repo_root/scripts/profile_contract.py" "${arguments[@]}"
