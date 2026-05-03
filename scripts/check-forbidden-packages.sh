#!/usr/bin/env bash
set -euo pipefail

config_path="${1:-openwrt/.config}"
rules_path="${2:-forbidden-packages.txt}"
output_dir="${3:-.}"

if [ ! -r "$config_path" ]; then
  echo "::error::Config file not found: $config_path" >&2
  exit 2
fi

config_dir="$(cd "$(dirname "$config_path")" && pwd -P)"

if [ ! -r "$rules_path" ]; then
  echo "::error::Forbidden package rules not found: $rules_path" >&2
  exit 2
fi

mkdir -p "$output_dir"
package_list="$output_dir/package-list.txt"
matches="$output_dir/forbidden-packages.detected.txt"
selected_config="$(mktemp)"
known_packages="$(mktemp)"
trap 'rm -f "$selected_config" "$known_packages"' EXIT

awk '
  /^CONFIG_PACKAGE_[^=]+=/ {
    name = $0
    sub(/^CONFIG_PACKAGE_/, "", name)
    sub(/=.*/, "", name)
    value = $0
    sub(/^[^=]+=/, "", value)
    selected[name] = (value == "y")
    next
  }

  /^# CONFIG_PACKAGE_[^[:space:]]+ is not set$/ {
    name = $0
    sub(/^# CONFIG_PACKAGE_/, "", name)
    sub(/ is not set$/, "", name)
    selected[name] = 0
    next
  }

  END {
    for (name in selected) {
      if (selected[name]) {
        print name
      }
    }
  }
' "$config_path" | sort -u > "$selected_config"
: > "$matches"

for metadata in \
  "$config_dir/tmp/.packageinfo" \
  "$config_dir/tmp/info/.packageinfo"* \
  tmp/.packageinfo \
  tmp/info/.packageinfo*; do
  if [ -r "$metadata" ]; then
    sed -n 's/^Package:[[:space:]]*//p' "$metadata" >> "$known_packages"
  fi
done

sort -u -o "$known_packages" "$known_packages"

if [ -s "$known_packages" ]; then
  awk 'NR == FNR { known[$0] = 1; next } known[$0]' "$known_packages" "$selected_config" > "$package_list"
else
  cp "$selected_config" "$package_list"
  echo "::warning::OpenWrt package metadata not found; checking all CONFIG_PACKAGE_* symbols." >&2
fi

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line="${raw_line%$'\r'}"
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  [ -z "$line" ] && continue

  case "$line" in
    prune:*)
      needle="${line#prune:}"
      awk -v needle="$needle" '$0 == needle { print }' "$package_list" >> "$matches"
      ;;
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
