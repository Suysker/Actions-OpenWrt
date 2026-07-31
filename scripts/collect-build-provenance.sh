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
cp "$artifact_report" "$output/artifact-override-report.json"
cp "$patch_report" "$output/patch-report.txt"
cp "$runner_report" "$output/runner-report.txt"
cp "$openwrt/.config" "$output/openwrt.config"

mapfile -t bbr_modules < <(find "$openwrt/build_dir" -type f -name tcp_bbr.ko -print)
[ "${#bbr_modules[@]}" -gt 0 ] || {
  echo "::error::Build tree contains no tcp_bbr.ko" >&2
  exit 1
}
bbr_version=""
for module in "${bbr_modules[@]}"; do
  version="$(modinfo -F version "$module" 2>/dev/null || true)"
  [ -n "$version" ] || continue
  if [ -n "$bbr_version" ] && [ "$version" != "$bbr_version" ]; then
    echo "::error::Built tcp_bbr modules report inconsistent versions" >&2
    exit 1
  fi
  bbr_version="$version"
done
[ "$bbr_version" = "3" ] || {
  echo "::error::Built tcp_bbr.ko module version is '${bbr_version:-missing}', expected 3" >&2
  exit 1
}

sch_fq_module="$(find "$openwrt/build_dir" -type f -name sch_fq.ko -print -quit)"
[ -n "$sch_fq_module" ] || {
  echo "::error::Build tree contains no sch_fq.ko" >&2
  exit 1
}

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
vermagic="$(modinfo -F vermagic "${bbr_modules[0]}" 2>/dev/null || true)"
case "$vermagic" in
  "$locked_kernel_version"*) ;;
  *)
    echo "::error::tcp_bbr vermagic '$vermagic' does not start with locked kernel $locked_kernel_version" >&2
    exit 1
    ;;
esac

{
  echo "module-report-v1"
  echo "tcp_bbr_version=$bbr_version"
  echo "tcp_bbr_vermagic=$vermagic"
  echo "tcp_bbr_candidates=${#bbr_modules[@]}"
  echo "sch_fq_present=1"
  echo "sch_fq_path=${sch_fq_module#$openwrt/}"
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
  echo "gcc_path=${toolchain_gcc#$openwrt/}"
  echo "gcc_version=$gcc_version"
  echo "external_prebuilt_toolchain=0"
  "$toolchain_gcc" --version
} > "$output/toolchain-report.txt"

source_lock_digest="$(bash "$repo_root/scripts/resolve-source-lock.sh" digest "$source_lock")"
python3 - "$profile" "$source_lock_digest" "$locked_kernel_version" \
  "$bbr_version" "$vermagic" "$gcc_version" "$output/provenance.json" <<'PY'
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

(
  cd "$output"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' |
    sort -z |
    xargs -0 sha256sum > SHA256SUMS
)

echo "Build provenance collected for $profile: $output"
