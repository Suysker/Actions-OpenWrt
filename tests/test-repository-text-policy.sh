#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

assert_lf_policy() {
  local path="$1" attribute
  attribute="$(git -C "$repo_root" check-attr eol -- "$path")"
  [ "$attribute" = "$path: eol: lf" ] || {
    echo "Expected LF policy for $path, got: $attribute" >&2
    exit 1
  }
}

# Cover both conventional extensions and OpenWrt's extensionless configuration
# scripts; the repository policy must not depend on an exhaustive suffix list.
assert_lf_policy "README.md"
assert_lf_policy "feeds.custom.conf"
assert_lf_policy "patchsets/common/series"
assert_lf_policy "profiles/common/files/etc/uci-defaults/90-common-network"
assert_lf_policy "profiles/common/files/etc/uci-defaults/zz-common-turboacc"

echo "Repository text policy tests passed."
