#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <kernel-version> [bbrv3.patch]" >&2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kernel_version="${1:-}"
patch="${2:-$repo_root/patchsets/common/kernel/${kernel_version%.*}/0001-bbrv3.patch}"

[[ "$kernel_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { usage; exit 2; }
[ -r "$patch" ] || {
  echo "::error::BBRv3 patch not found: $patch" >&2
  exit 2
}

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
linux_dir="$tmpdir/linux"
paths="$tmpdir/paths"

sed -n 's#^diff --git a/\([^ ]*\) b/.*#\1#p' "$patch" > "$paths"
[ -s "$paths" ] || {
  echo "::error::BBRv3 patch does not contain git paths" >&2
  exit 1
}

git clone --quiet --depth 1 --filter=blob:none --no-checkout \
  --branch "v$kernel_version" https://github.com/gregkh/linux.git "$linux_dir"
git -C "$linux_dir" sparse-checkout init --no-cone
git -C "$linux_dir" sparse-checkout set --no-cone --stdin < "$paths"
git -C "$linux_dir" checkout --quiet
git -C "$linux_dir" apply --check "$patch"

grep -Fq '#define BBR_VERSION' "$patch"
grep -Eq '^\+.*BBR_VERSION[[:space:]]+3$' "$patch"
grep -Fq 'MODULE_VERSION(__stringify(BBR_VERSION));' "$patch"
grep -Eq '^[ +].*\.name[[:space:]]*=[[:space:]]*"bbr"' "$patch"

echo "BBRv3 port applies cleanly to pristine Linux v$kernel_version and preserves module/runtime identity."
