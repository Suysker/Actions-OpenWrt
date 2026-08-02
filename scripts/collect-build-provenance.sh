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
[ -r "$openwrt/.config" ] || {
  echo "::error::Final OpenWrt config is missing" >&2
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
cp "$openwrt/.config" "$output/openwrt.config"

locked_kernel_version="$(PYTHONPATH="$repo_root/scripts" python3 - "$source_lock" "$profile" <<'PY'
import pathlib
import sys

import source_lock

lock = source_lock.load_lock(pathlib.Path(sys.argv[1]))
entry = lock["profiles"].get(sys.argv[2])
if not isinstance(entry, dict) or not entry.get("kernel_version"):
    raise SystemExit("::error::Profile kernel version is absent from source-lock")
print(entry["kernel_version"])
PY
)"

module_records="$(mktemp)"
gcc_banner="$(mktemp)"
sums_tmp="$(mktemp)"
trap 'rm -f "$module_records" "$gcc_banner" "$sums_tmp"' EXIT

mapfile -d '' -t bbr_modules < <(
  find "$openwrt/build_dir" -type f -name tcp_bbr.ko -print0 | LC_ALL=C sort -z
)
[ "${#bbr_modules[@]}" -gt 0 ] || {
  echo "::error::Build tree contains no tcp_bbr.ko" >&2
  exit 1
}
bbr_vermagic=""
for module in "${bbr_modules[@]}"; do
  relative="${module#"$openwrt"/}"
  version="$(python3 "$repo_root/scripts/kernel_module_metadata.py" "$module" version)" || {
    echo "::error::Cannot verify BBR module metadata: $relative" >&2
    exit 1
  }
  vermagic="$(python3 "$repo_root/scripts/kernel_module_metadata.py" "$module" vermagic)" || {
    echo "::error::Cannot verify BBR module metadata: $relative" >&2
    exit 1
  }
  [ "$version" = 3 ] || {
    echo "::error::Built $relative reports module version '$version', expected 3" >&2
    exit 1
  }
  case "$vermagic" in
    "$locked_kernel_version"*) ;;
    *) echo "::error::$relative vermagic '$vermagic' does not start with locked kernel $locked_kernel_version" >&2; exit 1 ;;
  esac
  [ -z "$bbr_vermagic" ] || [ "$vermagic" = "$bbr_vermagic" ] || {
    echo "::error::Built tcp_bbr modules report inconsistent vermagic" >&2
    exit 1
  }
  bbr_vermagic="$vermagic"
  printf 'tcp_bbr\t%s\t%s\t%s\t%s\n' \
    "$relative" "$(sha256sum "$module" | awk '{print $1}')" \
    "$version" "$vermagic" >> "$module_records"
done

mapfile -d '' -t sch_fq_modules < <(
  find "$openwrt/build_dir" -type f -name sch_fq.ko -print0 | LC_ALL=C sort -z
)
[ "${#sch_fq_modules[@]}" -gt 0 ] || {
  echo "::error::Build tree contains no sch_fq.ko" >&2
  exit 1
}
for module in "${sch_fq_modules[@]}"; do
  relative="${module#"$openwrt"/}"
  vermagic="$(python3 "$repo_root/scripts/kernel_module_metadata.py" "$module" vermagic)" || {
    echo "::error::Cannot verify sch_fq module metadata: $relative" >&2
    exit 1
  }
  case "$vermagic" in
    "$locked_kernel_version"*) ;;
    *) echo "::error::$relative vermagic '$vermagic' does not start with locked kernel $locked_kernel_version" >&2; exit 1 ;;
  esac
  printf 'sch_fq\t%s\t%s\t\t%s\n' \
    "$relative" "$(sha256sum "$module" | awk '{print $1}')" \
    "$vermagic" >> "$module_records"
done

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
"$toolchain_gcc" --version > "$gcc_banner"

source_lock_digest="$(python3 "$repo_root/scripts/source_lock.py" digest "$source_lock")"
PYTHONPATH="$repo_root/scripts" python3 - \
  "$profile" "$source_lock" "$source_lock_digest" "$locked_kernel_version" \
  "${toolchain_gcc#"$openwrt"/}" "$gcc_version" "$gcc_banner" \
  "$artifact_report" "$patch_report" "$runner_report" "$module_records" \
  "$output/build-provenance.json" <<'PY'
import datetime as dt
import json
import pathlib
import sys

import source_lock

(
    profile,
    lock_path,
    lock_digest,
    kernel_version,
    gcc_path,
    gcc_version,
    gcc_banner_path,
    artifact_path,
    patch_path,
    runner_path,
    modules_path,
    output_path,
) = sys.argv[1:]


def text_report(path: str) -> dict[str, object]:
    lines = pathlib.Path(path).read_text(encoding="utf-8", errors="replace").splitlines()
    if not lines or "=" in lines[0]:
        raise SystemExit(f"::error::Structured report has no format header: {path}")
    values: dict[str, object] = {}
    blocks: dict[str, list[str]] = {}
    active: str | None = None
    for line in lines[1:]:
        if active is not None:
            if line == f"{active}_end":
                active = None
            else:
                blocks[active].append(line)
            continue
        if line.endswith("_begin") and "=" not in line:
            active = line.removesuffix("_begin")
            blocks[active] = []
            continue
        key, separator, value = line.partition("=")
        if not separator:
            if line:
                raise SystemExit(f"::error::Invalid structured report line in {path}: {line}")
            continue
        previous = values.get(key)
        if previous is None:
            values[key] = value
        elif isinstance(previous, list):
            previous.append(value)
        else:
            values[key] = [previous, value]
    if active is not None:
        raise SystemExit(f"::error::Unterminated {active} block in {path}")
    return {"format": lines[0], "values": values, "blocks": blocks}


lock = source_lock.load_lock(pathlib.Path(lock_path))
if source_lock.lock_digest(lock) != lock_digest:
    raise SystemExit("::error::Source-lock digest changed during provenance collection")
artifact_overrides = json.loads(pathlib.Path(artifact_path).read_text(encoding="utf-8"))
if not isinstance(artifact_overrides, dict):
    raise SystemExit("::error::Artifact override report is not a JSON object")
if artifact_overrides.get("source_lock_digest") != lock_digest:
    raise SystemExit("::error::Artifact override report has the wrong source-lock digest")
patches = text_report(patch_path)
runner = text_report(runner_path)
if patches["format"] != "patch-report-v2":
    raise SystemExit("::error::Unsupported patch report format")
if runner["format"] != "runner-report-v1":
    raise SystemExit("::error::Unsupported runner report format")

modules: dict[str, list[dict[str, str]]] = {"tcp_bbr": [], "sch_fq": []}
for raw in pathlib.Path(modules_path).read_text(encoding="utf-8").splitlines():
    kind, path, digest, version, vermagic = raw.split("\t")
    entry = {"path": path, "sha256": digest, "vermagic": vermagic}
    if version:
        entry["version"] = version
    modules[kind].append(entry)

report = {
    "schema": 1,
    "profile": profile,
    "generated_at": dt.datetime.now(dt.timezone.utc)
    .replace(microsecond=0)
    .isoformat()
    .replace("+00:00", "Z"),
    "source_lock_digest": lock_digest,
    "kernel_version": kernel_version,
    "build_inputs": {
        "artifact_overrides": artifact_overrides,
        "patches": patches,
        "runner": runner,
    },
    "toolchain": {
        "gcc_path": gcc_path,
        "gcc_version": gcc_version,
        "external_prebuilt": False,
        "version_banner": pathlib.Path(gcc_banner_path)
        .read_text(encoding="utf-8", errors="replace")
        .splitlines(),
    },
    "kernel_modules": modules,
}
pathlib.Path(output_path).write_text(
    json.dumps(report, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

(
  cd "$output"
  find . -maxdepth 1 -type f ! -name SHA256SUMS -printf '%P\0' |
    sort -z | xargs -0 sha256sum > "$sums_tmp"
)
mv "$sums_tmp" "$output/SHA256SUMS"
trap - EXIT
rm -f "$module_records" "$gcc_banner"

echo "Build provenance collected for $profile: $output"
