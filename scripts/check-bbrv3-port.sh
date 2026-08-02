#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

usage() {
  echo "Usage: $0 <source-lock.json> <kernel-version>" >&2
}

source_lock="${1:-}"
kernel_version="${2:-}"

[ -r "$source_lock" ] || { usage; exit 2; }
[[ "$kernel_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { usage; exit 2; }
source_lock="$(cd "$(dirname "$source_lock")" && pwd -P)/$(basename "$source_lock")"
kernel_series="${kernel_version%.*}"

mapfile -t locked_patches < <(
  bash "$repo_root/scripts/resolve-source-lock.sh" \
    materialized-bbr-paths "$source_lock" "$kernel_version"
)
[ "${#locked_patches[@]}" -gt 0 ] || {
  echo "::error::No materialized BBRv3 patches were selected" >&2
  exit 1
}

mapfile -t module_version_contract < <(
  python3 "$repo_root/scripts/bbr3_module_version.py" \
    describe "$repo_root" "$kernel_series"
)
[ "${#module_version_contract[@]}" -eq 7 ] || {
  echo "::error::Could not load the BBRv3 module-version compatibility contract" >&2
  exit 1
}
module_version_patch="${module_version_contract[0]}"
module_version_source="${module_version_contract[3]}"
provider_module_version_state="$(
  python3 "$repo_root/scripts/bbr3_module_version.py" \
    provider-state "$repo_root" "$kernel_series" "${locked_patches[@]}"
)"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
linux_dir="$tmpdir/linux"
paths="$tmpdir/paths"

python3 "$repo_root/scripts/kernel_patch.py" paths \
  "${locked_patches[@]}" > "$paths"
printf '%s\n' "$module_version_source" >> "$paths"
sort -u -o "$paths" "$paths"
[ -s "$paths" ] || {
  echo "::error::BBRv3 patches do not contain safe source paths" >&2
  exit 1
}

git clone --quiet --depth 1 --filter=blob:none --no-checkout \
  --branch "v$kernel_version" https://github.com/gregkh/linux.git "$linux_dir"
git -C "$linux_dir" sparse-checkout init --no-cone
git -C "$linux_dir" sparse-checkout set --no-cone --stdin < "$paths"
git -C "$linux_dir" checkout --quiet
for patch in "${locked_patches[@]}"; do
  git -C "$linux_dir" apply --check "$patch"
  git -C "$linux_dir" apply "$patch"
done

source_module_version_state="$(
  python3 "$repo_root/scripts/bbr3_module_version.py" \
    source-state "$repo_root" "$kernel_series" "$linux_dir"
)"
case "$provider_module_version_state:$source_module_version_state" in
  compatibility-required:stripped)
    git -C "$linux_dir" apply --check "$module_version_patch"
    git -C "$linux_dir" apply "$module_version_patch"
    module_version_status="compatibility-applied"
    ;;
  upstream:retained)
    module_version_status="upstream"
    ;;
  *)
    echo "::error::Provider/source module-version states disagree: $provider_module_version_state/$source_module_version_state" >&2
    exit 1
    ;;
esac
[ "$(
  python3 "$repo_root/scripts/bbr3_module_version.py" \
    source-state "$repo_root" "$kernel_series" "$linux_dir"
)" = retained ] || {
  echo "::error::BBRv3 final source does not retain module version metadata" >&2
  exit 1
}

grep -Fq '#define BBR_VERSION' "${locked_patches[@]}"
grep -Eq '^\+.*BBR_VERSION[[:space:]]+3$' "${locked_patches[@]}"
grep -Eq '^[ +].*\.name[[:space:]]*=[[:space:]]*"bbr"' "${locked_patches[@]}"

echo "BBRv3 port (${#locked_patches[@]} provider patch(es), module-version=$module_version_status) applies cleanly to pristine Linux v$kernel_version and preserves module/runtime identity."
