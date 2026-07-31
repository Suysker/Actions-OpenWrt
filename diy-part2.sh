#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source_lock="${1:-${SOURCE_LOCK:-}}"
report="${2:-${ARTIFACT_OVERRIDE_REPORT:-}}"
openwrt_root="${OPENWRT_ROOT:-$PWD}"

if [ -z "$source_lock" ] || [ -z "$report" ]; then
  echo "::error::Usage: diy-part2.sh <source-lock.json> <artifact-override-report.json>" >&2
  exit 2
fi

# All release selection and hashing happened in prepare. This step performs
# only deterministic, provider-checked Makefile edits in the local build tree.
bash "$repo_root/scripts/apply-source-lock-artifacts.sh" \
  "$openwrt_root" "$source_lock" "$report"
