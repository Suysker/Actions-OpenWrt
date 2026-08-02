#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <profile> <openwrt-root> <source-lock> <artifact-report> <patch-report> <runner-report> <output-dir>" >&2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${1:-}"
openwrt="${2:-}"
source_lock="${3:-}"
artifact_report="${4:-}"
patch_report="${5:-}"
runner_report="${6:-}"
output="${7:-}"

[ "$#" -eq 7 ] || { usage; exit 2; }
for path in "$source_lock" "$artifact_report" "$patch_report" "$runner_report"; do
  [ -r "$path" ] || { echo "::error::Missing provenance input: $path" >&2; exit 2; }
done
[ -d "$openwrt/bin/targets" ] || {
  echo "::error::OpenWrt target output is missing" >&2
  exit 2
}

mapfile -t target_dirs < <(
  find "$openwrt/bin/targets" -mindepth 2 -maxdepth 2 -type d -print |
    while IFS= read -r directory; do
      find "$directory" -maxdepth 1 -type f -name '*.manifest' -print -quit | grep -q . &&
        printf '%s\n' "$directory"
    done
)
[ "${#target_dirs[@]}" -eq 1 ] || {
  echo "::error::Expected one built target directory, found ${#target_dirs[@]}" >&2
  printf '  - %s\n' "${target_dirs[@]}" >&2
  exit 1
}
target_dir="${target_dirs[0]}"

mkdir -p "$output"
while IFS= read -r -d '' file; do
  cp -a "$file" "$output/"
done < <(find "$target_dir" -maxdepth 1 -type f -print0)

cp "$source_lock" "$output/source-lock.json"
source_lock_dir="$(cd "$(dirname "$source_lock")" && pwd -P)"
[ -d "$source_lock_dir/bbr3" ] || {
  echo "::error::Materialized BBRv3 source-lock directory is missing" >&2
  exit 1
}
tar --sort=name --mtime='@0' --owner=0 --group=0 --numeric-owner \
  -C "$source_lock_dir" -cf - bbr3 | gzip -n > "$output/bbr3-patches.tar.gz"
cp "$artifact_report" "$output/artifact-override-report.json"
cp "$patch_report" "$output/patch-report.txt"
cp "$runner_report" "$output/runner-report.txt"
cp "$openwrt/.config" "$output/openwrt.config"

locked_kernel_version="$(python3 - "$source_lock" "$profile" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1], encoding="utf-8"))
entry = lock.get("profiles", {}).get(sys.argv[2], {})
print(entry.get("kernel_version", ""))
PY
)"
[ -n "$locked_kernel_version" ] || {
  echo "::error::Profile kernel version is absent from source-lock" >&2
  exit 1
}

mapfile -d '' -t bbr_modules < <(
  find "$openwrt/build_dir" -type f -name tcp_bbr.ko -print0 |
    LC_ALL=C sort -z
)
[ "${#bbr_modules[@]}" -gt 0 ] || {
  echo "::error::Build tree contains no tcp_bbr.ko" >&2
  exit 1
}
bbr_version=""
bbr_vermagic=""
declare -a bbr_relative_paths=()
declare -a bbr_versions=()
declare -a bbr_vermagics=()
declare -a bbr_sha256s=()
for module in "${bbr_modules[@]}"; do
  relative="${module#"$openwrt"/}"
  if ! version="$(
    python3 "$repo_root/scripts/kernel_module_metadata.py" "$module" version
  )"; then
    echo "::error::Cannot verify BBR module metadata: $relative" >&2
    exit 1
  fi
  if ! vermagic="$(
    python3 "$repo_root/scripts/kernel_module_metadata.py" "$module" vermagic
  )"; then
    echo "::error::Cannot verify BBR module metadata: $relative" >&2
    exit 1
  fi
  [ "$version" = "3" ] || {
    echo "::error::Built $relative reports module version '$version', expected 3" >&2
    exit 1
  }
  case "$vermagic" in
    "$locked_kernel_version"*) ;;
    *)
      echo "::error::$relative vermagic '$vermagic' does not start with locked kernel $locked_kernel_version" >&2
      exit 1
      ;;
  esac
  if [ -n "$bbr_version" ] && [ "$version" != "$bbr_version" ]; then
    echo "::error::Built tcp_bbr modules report inconsistent versions" >&2
    exit 1
  fi
  if [ -n "$bbr_vermagic" ] && [ "$vermagic" != "$bbr_vermagic" ]; then
    echo "::error::Built tcp_bbr modules report inconsistent vermagic" >&2
    exit 1
  fi
  bbr_version="$version"
  bbr_vermagic="$vermagic"
  bbr_relative_paths+=("$relative")
  bbr_versions+=("$version")
  bbr_vermagics+=("$vermagic")
  bbr_sha256s+=("$(sha256sum "$module" | awk '{print $1}')")
done
[ "$bbr_version" = "3" ] || {
  echo "::error::Built tcp_bbr.ko module version is '$bbr_version', expected 3" >&2
  exit 1
}

mapfile -d '' -t sch_fq_modules < <(
  find "$openwrt/build_dir" -type f -name sch_fq.ko -print0 |
    LC_ALL=C sort -z
)
[ "${#sch_fq_modules[@]}" -gt 0 ] || {
  echo "::error::Build tree contains no sch_fq.ko" >&2
  exit 1
}
sch_fq_module="${sch_fq_modules[0]}"

{
  echo "module-report-v2"
  echo "tcp_bbr_version=$bbr_version"
  echo "tcp_bbr_vermagic=$bbr_vermagic"
  echo "tcp_bbr_candidates=${#bbr_modules[@]}"
  echo "sch_fq_present=1"
  echo "sch_fq_path=${sch_fq_module#"$openwrt"/}"
  for index in "${!bbr_modules[@]}"; do
    printf -v field '%03d' "$((index + 1))"
    echo "tcp_bbr_${field}_path=${bbr_relative_paths[$index]}"
    echo "tcp_bbr_${field}_sha256=${bbr_sha256s[$index]}"
    echo "tcp_bbr_${field}_version=${bbr_versions[$index]}"
    echo "tcp_bbr_${field}_vermagic=${bbr_vermagics[$index]}"
  done
} > "$output/module-report.txt"

toolchain_gcc="$(find "$openwrt/staging_dir" \( -type f -o -type l \) -path '*/bin/*-openwrt-*-gcc' -print -quit)"
[ -n "$toolchain_gcc" ] || toolchain_gcc="$(find "$openwrt/staging_dir" \( -type f -o -type l \) -path '*/bin/*-gcc' -print -quit)"
[ -n "$toolchain_gcc" ] || {
  echo "::error::Built cross GCC was not found" >&2
  exit 1
}
gcc_version="$($toolchain_gcc -dumpfullversion -dumpversion)"
case "$gcc_version" in
  15.*) ;;
  *) echo "::error::Expected GCC 15, built $gcc_version" >&2; exit 1 ;;
esac
{
  echo "toolchain-report-v1"
  echo "gcc_path=${toolchain_gcc#"$openwrt"/}"
  echo "gcc_version=$gcc_version"
  echo "external_prebuilt_toolchain=0"
  "$toolchain_gcc" --version
} > "$output/toolchain-report.txt"

source_lock_digest="$(bash "$repo_root/scripts/resolve-source-lock.sh" digest "$source_lock")"
python3 - "$profile" "$source_lock_digest" "$locked_kernel_version" \
  "$bbr_version" "$bbr_vermagic" "$gcc_version" "$output/provenance.json" <<'PY'
import datetime as dt
import json
import sys

profile, lock_digest, kernel, bbr, vermagic, gcc, output = sys.argv[1:]
report = {
    "schema": 1,
    "profile": profile,
    "source_lock_digest": lock_digest,
    "kernel_version": kernel,
    "tcp_bbr_module_version": bbr,
    "tcp_bbr_vermagic": vermagic,
    "sch_fq_module_present": True,
    "gcc_version": gcc,
    "generated_at": dt.datetime.now(dt.timezone.utc).replace(microsecond=0).isoformat().replace("+00:00", "Z"),
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(report, handle, ensure_ascii=False, indent=2, sort_keys=True)
    handle.write("\n")
PY

sums_tmp="$(mktemp)"
trap 'rm -f "$sums_tmp"' EXIT
(
  cd "$output"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' |
    sort -z |
    xargs -0 sha256sum > "$sums_tmp"
)
mv "$sums_tmp" "$output/SHA256SUMS"
trap - EXIT

echo "Build provenance collected for $profile: $output"
