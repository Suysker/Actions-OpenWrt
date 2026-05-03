#!/usr/bin/env bash
set -euo pipefail

config_path="${1:-openwrt/.config}"
rules_path="${2:-forbidden-packages.txt}"
output_dir="${3:-.}"

if [ ! -r "$config_path" ]; then
  echo "::error::Config file not found: $config_path" >&2
  exit 2
fi

if [ ! -r "$rules_path" ]; then
  echo "::error::Forbidden package rules not found: $rules_path" >&2
  exit 2
fi

mkdir -p "$output_dir"
package_list="$output_dir/package-list.txt"
matches="$output_dir/forbidden-packages.detected.txt"

sed -n 's/^CONFIG_PACKAGE_\(.*\)=y$/\1/p' "$config_path" | sort -u > "$package_list"
: > "$matches"

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line="${raw_line%$'\r'}"
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  [ -z "$line" ] && continue

  case "$line" in
    exact:*)
      needle="${line#exact:}"
      awk -v needle="$needle" '$0 == needle { print }' "$package_list" >> "$matches"
      ;;
    regex:*)
      pattern="${line#regex:}"
      set +e
      grep -E "$pattern" "$package_list" >> "$matches"
      status=$?
      set -e
      if [ "$status" -eq 2 ]; then
        echo "::error::Invalid regex in $rules_path: $pattern" >&2
        exit 2
      fi
      ;;
    *)
      awk -v needle="$line" '$0 == needle { print }' "$package_list" >> "$matches"
      ;;
  esac
done < "$rules_path"

sort -u -o "$matches" "$matches"

package_count="$(wc -l < "$package_list" | tr -d '[:space:]')"
match_count="$(wc -l < "$matches" | tr -d '[:space:]')"

echo "Resolved built-in package selections: $package_count"
echo "Package list written to: $package_list"

if [ "$match_count" -gt 0 ]; then
  echo "::error::Forbidden packages were selected by the final OpenWrt config:"
  sed 's/^/  - /' "$matches"
  exit 1
fi

echo "Forbidden package check passed."
