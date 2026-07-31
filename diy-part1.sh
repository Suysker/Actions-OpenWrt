#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_lock="${1:-${SOURCE_LOCK:-}}"
feeds_file="${2:-feeds.conf.default}"

[ -n "$source_lock" ] || {
  echo "::error::Usage: diy-part1.sh <source-lock.json> [feeds.conf.default]" >&2
  exit 2
}

# Replace every floating default/custom feed with the exact commits resolved by
# the prepare job. No build job reads a branch HEAD.
bash "$repo_root/scripts/manage-custom-feeds.sh" apply-lock \
  "$source_lock" "$feeds_file"

echo "Installed immutable feed configuration from source-lock.json."
