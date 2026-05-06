#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  apply-profile-patches.sh <profile> <openwrt-dir>

Runs the optional PROFILE_PATCHSET declared by the rendered profile env.
Profiles without PROFILE_PATCHSET are left unchanged.
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${1:-${PROFILE:-}}"
openwrt_dir="${2:-}"

if [ -z "$profile" ] || [ -z "$openwrt_dir" ]; then
  usage
  exit 2
fi

if [ ! -d "$openwrt_dir" ]; then
  echo "::error::OpenWrt source directory does not exist: $openwrt_dir" >&2
  exit 2
fi

# Allow local use without pre-exporting the rendered env. The CI workflow already
# exports these variables before calling this script. Existing environment values
# win so one-off CI overrides still work.
while IFS='=' read -r key value; do
  if [ -z "${!key+x}" ]; then
    export "$key=$value"
  fi
done < <(bash "$repo_root/scripts/render-profile.sh" env "$profile")

patchset="${PROFILE_PATCHSET:-}"
if [ -z "$patchset" ]; then
  echo "Profile $profile does not declare PROFILE_PATCHSET; skipping profile patches."
  exit 0
fi

if ! printf '%s\n' "$patchset" | grep -Eq '^[a-z0-9][a-z0-9._-]*$'; then
  echo "::error::Invalid PROFILE_PATCHSET value: $patchset" >&2
  exit 2
fi

patchset_script="$repo_root/patchsets/$patchset/apply.sh"
if [ ! -r "$patchset_script" ]; then
  echo "::error::Unknown profile patchset '$patchset': missing $patchset_script" >&2
  exit 2
fi

echo "Applying profile patchset '$patchset' for profile '$profile'."
bash "$patchset_script" "$openwrt_dir"
