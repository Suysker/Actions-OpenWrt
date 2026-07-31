#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  apply-profile-patches.sh <profile> <openwrt-dir> <source-lock.json> <report.txt>

Applies repository-owned common/device patches and installs the BBRv3 port
selected by the immutable source lock into OpenWrt's stable-kernel patch stack.
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${1:-${PROFILE:-}}"
openwrt_dir="${2:-}"
source_lock="${3:-${SOURCE_LOCK:-}}"
report="${4:-}"

if [ -z "$profile" ] || [ -z "$openwrt_dir" ] || [ -z "$source_lock" ] || [ -z "$report" ]; then
  usage
  exit 2
fi
[ -d "$openwrt_dir/.git" ] || {
  echo "::error::OpenWrt source is not a Git checkout: $openwrt_dir" >&2
  exit 2
}
[ -r "$source_lock" ] || {
  echo "::error::Source lock not found: $source_lock" >&2
  exit 2
}

openwrt_dir="$(cd "$openwrt_dir" && pwd -P)"
source_lock="$(cd "$(dirname "$source_lock")" && pwd -P)/$(basename "$source_lock")"
mkdir -p "$(dirname "$report")"

readarray -t locked < <(python3 - "$source_lock" "$profile" <<'PY'
import json
import re
import sys

lock = json.load(open(sys.argv[1], encoding="utf-8"))
profile = sys.argv[2]
entry = lock.get("profiles", {}).get(profile)
if not isinstance(entry, dict):
    raise SystemExit(f"::error::Profile {profile} is absent from source-lock")
series = entry.get("kernel_series", "")
version = entry.get("kernel_version", "")
bbr = lock.get("kernel_features", {}).get("bbr3", {})
if bbr.get("profile_kernel_series", {}).get(profile) != series:
    raise SystemExit("::error::Profile and BBRv3 kernel series disagree in source-lock")
port = bbr.get("ports", {}).get(series)
if not isinstance(port, dict):
    raise SystemExit(f"::error::No BBRv3 port is locked for kernel {series}")
values = [
    series,
    version,
    entry.get("kernel_target", ""),
    port.get("vendored_path", ""),
    port.get("vendored_sha256", ""),
    port.get("origin_url", ""),
    port.get("origin_commit", ""),
    port.get("origin_path", ""),
    port.get("origin_sha256", ""),
]
if not re.fullmatch(r"[0-9]+\.[0-9]+", values[0]):
    raise SystemExit("::error::Invalid locked kernel series")
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", values[1]):
    raise SystemExit("::error::Invalid locked kernel version")
if not re.fullmatch(r"[a-z0-9_-]+", values[2]):
    raise SystemExit("::error::Invalid locked kernel target")
if not re.fullmatch(r"patchsets/common/kernel/[0-9]+\.[0-9]+/[A-Za-z0-9._-]+\.patch", values[3]):
    raise SystemExit("::error::Unsafe vendored BBRv3 path")
for value in (values[4], values[8]):
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise SystemExit("::error::Invalid locked BBRv3 SHA256")
if values[4] != values[8]:
    raise SystemExit("::error::Origin and vendored BBRv3 hashes differ")
if not re.fullmatch(r"[0-9a-f]{40}", values[6]):
    raise SystemExit("::error::Invalid BBRv3 origin commit")
print("\n".join(values))
PY
)
[ "${#locked[@]}" -eq 9 ] || {
  echo "::error::Could not parse the locked patch contract for $profile" >&2
  exit 1
}

kernel_series="${locked[0]}"
kernel_version="${locked[1]}"
kernel_target="${locked[2]}"
vendored_relative="${locked[3]}"
vendored_sha256="${locked[4]}"
origin_url="${locked[5]}"
origin_commit="${locked[6]}"
origin_path="${locked[7]}"
origin_sha256="${locked[8]}"

vendored_patch="$repo_root/$vendored_relative"
[ -f "$vendored_patch" ] || {
  echo "::error::Locked BBRv3 patch is missing: $vendored_relative" >&2
  exit 1
}
actual_sha256="$(sha256sum "$vendored_patch" | awk '{print $1}')"
[ "$actual_sha256" = "$vendored_sha256" ] || {
  echo "::error::Vendored BBRv3 digest differs from source-lock" >&2
  exit 1
}

target_makefile="$openwrt_dir/target/linux/$kernel_target/Makefile"
[ -f "$target_makefile" ] || {
  echo "::error::Locked target Makefile is missing: $target_makefile" >&2
  exit 1
}
actual_series="$(sed -nE 's/^KERNEL_PATCHVER[[:space:]]*:=[[:space:]]*([0-9]+\.[0-9]+)[[:space:]]*$/\1/p' "$target_makefile")"
[ "$actual_series" = "$kernel_series" ] || {
  echo "::error::OpenWrt stable kernel $actual_series differs from locked $kernel_series" >&2
  exit 1
}

apply_series() {
  local layer="$1" directory="$2" series_file="$2/series" patch_name patch_path
  [ -f "$series_file" ] || {
    echo "::error::Missing $layer patch series: $series_file" >&2
    exit 1
  }
  while IFS= read -r patch_name || [ -n "$patch_name" ]; do
    patch_name="${patch_name%%#*}"
    patch_name="$(printf '%s' "$patch_name" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    [ -n "$patch_name" ] || continue
    [[ "$patch_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*\.patch$ ]] || {
      echo "::error::Unsafe patch name in $series_file: $patch_name" >&2
      exit 2
    }
    patch_path="$directory/$patch_name"
    [ -f "$patch_path" ] || {
      echo "::error::Missing patch listed by $series_file: $patch_name" >&2
      exit 1
    }
    git -C "$openwrt_dir" apply --check "$patch_path"
    git -C "$openwrt_dir" apply "$patch_path"
    printf 'applied_%s=%s sha256:%s\n' "$layer" "$patch_name" \
      "$(sha256sum "$patch_path" | awk '{print $1}')" >> "$report"
  done < "$series_file"
}

source_lock_digest="$(bash "$repo_root/scripts/resolve-source-lock.sh" digest "$source_lock")"
{
  echo "patch-report-v1"
  echo "profile=$profile"
  echo "source_lock_digest=$source_lock_digest"
  echo "kernel_target=$kernel_target"
  echo "kernel_series=$kernel_series"
  echo "kernel_version=$kernel_version"
} > "$report"

apply_series common "$repo_root/patchsets/common"
apply_series device "$repo_root/patchsets/$profile"

destination_dir="$openwrt_dir/target/linux/generic/hack-$kernel_series"
[ -d "$destination_dir" ] || {
  echo "::error::OpenWrt generic stable-kernel patch directory is missing: $destination_dir" >&2
  exit 1
}
destination="$destination_dir/995-bbrv3.patch"
if [ -e "$destination" ]; then
  destination_hash="$(sha256sum "$destination" | awk '{print $1}')"
  [ "$destination_hash" = "$vendored_sha256" ] || {
    echo "::error::Refusing to overwrite a different OpenWrt BBRv3 patch" >&2
    exit 1
  }
else
  install -m 0644 "$vendored_patch" "$destination"
fi

grep -Eq '^\+.*BBR_VERSION[[:space:]]+3$' "$destination"
grep -Fq 'MODULE_VERSION(__stringify(BBR_VERSION));' "$destination"
grep -Eq '^[ +].*\.name[[:space:]]*=[[:space:]]*"bbr"' "$destination"

netsupport="$openwrt_dir/package/kernel/linux/modules/netsupport.mk"
grep -Fq 'define KernelPackage/tcp-bbr' "$netsupport"
grep -Fq 'net/ipv4/tcp_bbr.ko' "$netsupport"
grep -Fq 'AutoProbe,tcp_bbr' "$netsupport"
grep -Fq 'define KernelPackage/sched' "$netsupport"
grep -Fq 'sch_fq' "$netsupport"

{
  echo "bbrv3_status=installed-into-openwrt-kernel-patch-stack"
  echo "bbrv3_destination=${destination#$openwrt_dir/}"
  echo "bbrv3_vendored_path=$vendored_relative"
  echo "bbrv3_vendored_sha256=$vendored_sha256"
  echo "bbrv3_origin_url=$origin_url"
  echo "bbrv3_origin_commit=$origin_commit"
  echo "bbrv3_origin_path=$origin_path"
  echo "bbrv3_origin_sha256=$origin_sha256"
  echo "assertion_BBR_VERSION=3"
  echo "assertion_runtime_name=bbr"
  echo "assertion_MODULE_VERSION=present"
  echo "assertion_kernel_package=tcp-bbr"
  echo "assertion_qdisc_provider=kmod-sched:sch_fq"
} >> "$report"

echo "Profile patches prepared for $profile. Report: $report"
