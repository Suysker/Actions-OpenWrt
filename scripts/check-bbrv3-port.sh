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

mapfile -t locked_patches < <(python3 - "$source_lock" "$kernel_series" "$kernel_version" <<'PY'
import hashlib
import json
import pathlib
import re
import sys

lock_path = pathlib.Path(sys.argv[1])
series = sys.argv[2]
version = sys.argv[3]
lock = json.loads(lock_path.read_text(encoding="utf-8"))
port = lock.get("kernel_features", {}).get("bbr3", {}).get("ports", {}).get(series)
if not isinstance(port, dict) or port.get("version") != version:
    raise SystemExit(f"::error::Source lock has no BBRv3 port for Linux {version}")
patches = port.get("patches")
if not isinstance(patches, list) or not patches:
    raise SystemExit(f"::error::Locked BBRv3 port for {series} has no patches")
for expected_order, patch in enumerate(patches, start=1):
    if patch.get("order") != expected_order:
        raise SystemExit("::error::Locked BBRv3 patch order is not contiguous")
    relative = pathlib.PurePosixPath(patch.get("artifact_path", ""))
    if relative.is_absolute() or ".." in relative.parts or relative.parts[:2] != ("bbr3", series):
        raise SystemExit("::error::Unsafe locked BBRv3 artifact path")
    path = lock_path.parent.joinpath(*relative.parts)
    if not path.is_file():
        raise SystemExit(f"::error::Materialized BBRv3 patch is missing: {relative}")
    actual = hashlib.sha256(path.read_bytes()).hexdigest()
    if actual != patch.get("sha256") or not re.fullmatch(r"[0-9a-f]{64}", actual):
        raise SystemExit(f"::error::Materialized BBRv3 patch hash differs: {relative}")
    print(path)
PY
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

for patch in "${locked_patches[@]}"; do
  sed -n 's#^diff --git a/\([^ ]*\) b/.*#\1#p' "$patch"
done | sort -u > "$paths"
printf '%s\n' "$module_version_source" >> "$paths"
sort -u -o "$paths" "$paths"
[ -s "$paths" ] || {
  echo "::error::BBRv3 patches do not contain git paths" >&2
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
