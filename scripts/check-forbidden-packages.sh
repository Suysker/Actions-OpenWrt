#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
  echo "Usage: $0 <openwrt-config> <forbidden-rules-file> [output-dir]" >&2
  exit 2
fi

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${3:-.}"
python3 "$repo_root/scripts/profile_model.py" check-forbidden \
  "$1" "$2" "$output_dir"
