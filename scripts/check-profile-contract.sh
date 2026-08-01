#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  check-profile-contract.sh <profile> [openwrt-root] [source-lock.json] [report]

With only a profile, validates repository-owned static contracts. When an
OpenWrt tree is supplied it also validates the final config, selected package
providers, stable kernel series, source lock and locked-source semantics.
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${1:-}"
openwrt_root="${2:-}"
source_lock="${3:-}"
report="${4:-${CONTRACT_REPORT:-}}"

[ -n "$profile" ] || { usage; exit 2; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

config="$tmpdir/config.seed"
required="$tmpdir/required.txt"
forbidden="$tmpdir/forbidden.txt"
environment="$tmpdir/profile.env"
files="$tmpdir/files"
provider_report="$tmpdir/provider-contract.txt"

bash "$repo_root/scripts/render-profile.sh" config "$profile" "$config"
bash "$repo_root/scripts/render-profile.sh" required "$profile" "$required"
bash "$repo_root/scripts/render-profile.sh" forbidden "$profile" "$forbidden"
bash "$repo_root/scripts/render-profile.sh" env "$profile" "$environment"
bash "$repo_root/scripts/render-profile.sh" files "$profile" "$files"

arguments=(
  --profile "$profile"
  --config "$config"
  --required "$required"
  --forbidden "$forbidden"
  --environment "$environment"
  --files "$files"
  --semantics "$repo_root/profiles/profile-semantics.json"
)

if [ -n "$openwrt_root" ]; then
  [ -d "$openwrt_root" ] || {
    echo "::error::OpenWrt root does not exist: $openwrt_root" >&2
    exit 2
  }
  openwrt_root="$(cd "$openwrt_root" && pwd -P)"
  [ -n "$source_lock" ] && [ -r "$source_lock" ] || {
    echo "::error::A readable source lock is required with an OpenWrt tree" >&2
    exit 2
  }
  source_lock="$(cd "$(dirname "$source_lock")" && pwd -P)/$(basename "$source_lock")"

  bash "$repo_root/scripts/select-package-providers.sh" --check \
    "$openwrt_root" "$provider_report"
  bash "$repo_root/scripts/check-forbidden-packages.sh" \
    "$openwrt_root/.config" "$forbidden" "$tmpdir/forbidden-check"
  bash "$repo_root/scripts/check-required-packages.sh" \
    "$openwrt_root/.config" "$required" \
    "$tmpdir/forbidden-check/package-list.txt"

  arguments+=(
    --openwrt "$openwrt_root"
    --source-lock "$source_lock"
    --provider-report "$provider_report"
  )
elif [ -n "$source_lock" ]; then
  echo "::error::source-lock cannot be supplied without an OpenWrt tree" >&2
  exit 2
fi

if [ -n "$report" ]; then
  arguments+=(--report "$report")
fi

python3 "$repo_root/scripts/profile_contract.py" "${arguments[@]}"
echo "Profile contract passed for $profile."
