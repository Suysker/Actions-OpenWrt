#!/usr/bin/env bash
set -euo pipefail

rules_path="${1:-forbidden-packages.txt}"
package_root="${2:-package}"

if [ ! -r "$rules_path" ]; then
  echo "::error::Forbidden package rules not found: $rules_path" >&2
  exit 2
fi

if [ ! -d "$package_root" ]; then
  echo "::error::OpenWrt package directory not found: $package_root" >&2
  exit 2
fi

removed_count=0
names="$(mktemp)"
trap 'rm -f "$names"' EXIT

add_name() {
  local name="$1"

  if ! printf '%s\n' "$name" | grep -Eq '^[A-Za-z0-9_.+-]+$'; then
    echo "::error::Invalid package directory name: $name" >&2
    exit 2
  fi

  printf '%s\n' "$name" >> "$names"
}

# Exact forbidden package rules are pruned when their package directory basename
# matches the package/source name. Regex rules remain check-only.
while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line="${raw_line%$'\r'}"
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  [ -z "$line" ] && continue

  case "$line" in
    exact:*)
      add_name "${line#exact:}"
      ;;
    regex:*)
      ;;
    *)
      add_name "$line"
      ;;
  esac
done < "$rules_path"

sort -u -o "$names" "$names"

while IFS= read -r name || [ -n "$name" ]; do
  while IFS= read -r package_dir; do
    [ -n "$package_dir" ] || continue
    echo "Pruning package entry: $package_dir"
    rm -rf "$package_dir"
    removed_count=$((removed_count + 1))
  done < <(find "$package_root" \( -type d -o -type l \) -name "$name" -prune -print)
done < "$names"

echo "Pruned package entries: $removed_count"
