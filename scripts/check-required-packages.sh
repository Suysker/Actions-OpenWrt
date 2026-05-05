#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <openwrt-config> <required-rules-file> [package-list]" >&2
  exit 2
fi

config_path="$1"
rules_path="$2"
package_list="${3:-}"

if [ ! -r "$config_path" ]; then
  echo "::error::Config file not found: $config_path" >&2
  exit 2
fi

if [ ! -r "$rules_path" ]; then
  echo "::error::Required package rules not found: $rules_path" >&2
  exit 2
fi

selected_packages="$(mktemp)"
missing="$(mktemp)"
trap 'rm -f "$selected_packages" "$missing"' EXIT

if [ -n "$package_list" ] && [ -r "$package_list" ]; then
  sort -u "$package_list" > "$selected_packages"
else
  awk '
    /^CONFIG_PACKAGE_[^=]+=y$/ {
      name = $0
      sub(/^CONFIG_PACKAGE_/, "", name)
      sub(/=.*/, "", name)
      print name
    }
  ' "$config_path" | sort -u > "$selected_packages"
fi

: > "$missing"

while IFS= read -r raw_line || [ -n "$raw_line" ]; do
  line="${raw_line%$'\r'}"
  line="${line%%#*}"
  line="$(printf '%s' "$line" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"

  [ -z "$line" ] && continue

  case "$line" in
    package:*)
      name="${line#package:}"
      if ! grep -Fxq "$name" "$selected_packages"; then
        printf 'package:%s\n' "$name" >> "$missing"
      fi
      ;;
    config:*)
      symbol="${line#config:}"
      if ! grep -Fxq "${symbol}=y" "$config_path"; then
        printf 'config:%s\n' "$symbol" >> "$missing"
      fi
      ;;
    *)
      if ! grep -Fxq "$line" "$selected_packages"; then
        printf 'package:%s\n' "$line" >> "$missing"
      fi
      ;;
  esac
done < "$rules_path"

sort -u -o "$missing" "$missing"

missing_count="$(wc -l < "$missing" | tr -d '[:space:]')"

if [ "$missing_count" -gt 0 ]; then
  echo "::error::Required profile packages/config symbols are missing from the final OpenWrt config:"
  sed 's/^/  - /' "$missing"
  exit 1
fi

echo "Required package check passed."
