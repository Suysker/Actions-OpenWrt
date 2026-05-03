#!/usr/bin/env bash
set -euo pipefail

list_path="${1:-prune-packages.txt}"
package_root="${2:-package}"

if [ ! -r "$list_path" ]; then
  echo "::error::Prune package list not found: $list_path" >&2
  exit 2
fi

if [ ! -d "$package_root" ]; then
  echo "::error::OpenWrt package directory not found: $package_root" >&2
  exit 2
fi

removed_count=0

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  name="${raw_line%$'\r'}"
  name="${name%%#*}"
  name="$(printf '%s' "$name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  [ -z "$name" ] && continue

  if ! printf '%s\n' "$name" | grep -Eq '^[A-Za-z0-9_.+-]+$'; then
    echo "::error::Invalid package directory name in $list_path: $name" >&2
    exit 2
  fi

  while IFS= read -r package_dir; do
    [ -n "$package_dir" ] || continue
    echo "Pruning package directory: $package_dir"
    rm -rf "$package_dir"
    removed_count=$((removed_count + 1))
  done < <(find "$package_root" -type d -name "$name" -prune -print)
done < "$list_path"

echo "Pruned package directories: $removed_count"
