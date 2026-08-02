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
    port.get("provider", ""),
    port.get("origin_url", ""),
    port.get("origin_ref", ""),
    port.get("origin_commit", ""),
    port.get("install_directory", ""),
]
if not re.fullmatch(r"[0-9]+\.[0-9]+", values[0]):
    raise SystemExit("::error::Invalid locked kernel series")
if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", values[1]):
    raise SystemExit("::error::Invalid locked kernel version")
if not re.fullmatch(r"[a-z0-9_-]+", values[2]):
    raise SystemExit("::error::Invalid locked kernel target")
if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", values[3]):
    raise SystemExit("::error::Invalid BBRv3 provider")
if not re.fullmatch(r"[0-9a-f]{40}", values[6]):
    raise SystemExit("::error::Invalid BBRv3 origin commit")
if not re.fullmatch(rf"(?:hack|backport)-{re.escape(series)}", values[7]):
    raise SystemExit("::error::Invalid BBRv3 install directory")
print("\n".join(values))
PY
)
[ "${#locked[@]}" -eq 8 ] || {
  echo "::error::Could not parse the locked patch contract for $profile" >&2
  exit 1
}

kernel_series="${locked[0]}"
kernel_version="${locked[1]}"
kernel_target="${locked[2]}"
bbr_provider="${locked[3]}"
origin_url="${locked[4]}"
origin_ref="${locked[5]}"
origin_commit="${locked[6]}"
install_directory="${locked[7]}"
source_lock_dir="$(dirname "$source_lock")"

mapfile -t module_version_contract < <(
  python3 "$repo_root/scripts/bbr3_module_version.py" \
    describe "$repo_root" "$kernel_series"
)
[ "${#module_version_contract[@]}" -eq 7 ] || {
  echo "::error::Could not load the BBRv3 module-version compatibility contract" >&2
  exit 1
}
module_version_patch="${module_version_contract[0]}"
module_version_install_directory="${module_version_contract[1]}"
module_version_install_name="${module_version_contract[2]}"
module_version_sha256="${module_version_contract[6]}"

mapfile -t locked_patches < <(python3 - "$source_lock" "$kernel_series" <<'PY'
import json
import pathlib
import re
import sys

lock = json.load(open(sys.argv[1], encoding="utf-8"))
series = sys.argv[2]
patches = lock["kernel_features"]["bbr3"]["ports"][series].get("patches", [])
if not patches:
    raise SystemExit("::error::Locked BBRv3 port contains no patches")
for order, patch in enumerate(patches, start=1):
    relative = pathlib.PurePosixPath(patch.get("artifact_path", ""))
    sha256 = patch.get("sha256", "")
    install_name = patch.get("install_name", "")
    origin_path = patch.get("origin_path", "")
    if patch.get("order") != order:
        raise SystemExit("::error::Locked BBRv3 patch order is invalid")
    if relative.is_absolute() or ".." in relative.parts or relative.parts[:2] != ("bbr3", series):
        raise SystemExit("::error::Unsafe BBRv3 artifact path")
    if not re.fullmatch(r"[0-9a-f]{64}", sha256):
        raise SystemExit("::error::Invalid BBRv3 patch SHA256")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.patch", install_name):
        raise SystemExit("::error::Unsafe BBRv3 install name")
    if any("\t" in value or "\n" in value for value in (str(relative), origin_path, patch.get("raw_url", ""))):
        raise SystemExit("::error::Unsafe control character in BBRv3 lock")
    print("\t".join((str(order), str(relative), sha256, origin_path, patch.get("raw_url", ""), install_name)))
PY
)
[ "${#locked_patches[@]}" -gt 0 ] || {
  echo "::error::Could not parse materialized BBRv3 patches" >&2
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
  echo "patch-report-v2"
  echo "profile=$profile"
  echo "source_lock_digest=$source_lock_digest"
  echo "kernel_target=$kernel_target"
  echo "kernel_series=$kernel_series"
  echo "kernel_version=$kernel_version"
} > "$report"

python3 "$repo_root/scripts/apply-source-compatibility.py" \
  "$repo_root/profiles/common/source-compatibility.json" "$openwrt_dir" "$report"
apply_series common "$repo_root/patchsets/common"
apply_series device "$repo_root/patchsets/$profile"

destination_dir="$openwrt_dir/target/linux/generic/$install_directory"
[ -d "$destination_dir" ] || {
  echo "::error::OpenWrt generic stable-kernel patch directory is missing: $destination_dir" >&2
  exit 1
}
installed_bbr_patches=()
for record in "${locked_patches[@]}"; do
  IFS=$'\t' read -r order artifact_relative patch_sha256 origin_path raw_url install_name <<< "$record"
  materialized_patch="$source_lock_dir/$artifact_relative"
  [ -f "$materialized_patch" ] || {
    echo "::error::Materialized BBRv3 patch is missing: $artifact_relative" >&2
    exit 1
  }
  materialized_patch="$(realpath -e "$materialized_patch")"
  case "$materialized_patch" in
    "$source_lock_dir"/*) ;;
    *)
      echo "::error::Materialized BBRv3 patch escapes source-lock: $artifact_relative" >&2
      exit 1
      ;;
  esac
  actual_sha256="$(sha256sum "$materialized_patch" | awk '{print $1}')"
  [ "$actual_sha256" = "$patch_sha256" ] || {
    echo "::error::Materialized BBRv3 digest differs from source-lock: $artifact_relative" >&2
    exit 1
  }
  destination="$destination_dir/$install_name"
  if [ -e "$destination" ]; then
    destination_hash="$(sha256sum "$destination" | awk '{print $1}')"
    [ "$destination_hash" = "$patch_sha256" ] || {
      echo "::error::Refusing to overwrite a different OpenWrt BBRv3 patch: $install_name" >&2
      exit 1
    }
  else
    install -m 0644 "$materialized_patch" "$destination"
  fi
  installed_bbr_patches+=("$destination")
  {
    printf 'bbrv3_patch_%03d_artifact=%s\n' "$order" "$artifact_relative"
    printf 'bbrv3_patch_%03d_origin_path=%s\n' "$order" "$origin_path"
    printf 'bbrv3_patch_%03d_raw_url=%s\n' "$order" "$raw_url"
    printf 'bbrv3_patch_%03d_sha256=%s\n' "$order" "$patch_sha256"
    printf 'bbrv3_patch_%03d_destination=%s\n' "$order" "${destination#"$openwrt_dir"/}"
  } >> "$report"
done

provider_module_version_state="$(
  python3 "$repo_root/scripts/bbr3_module_version.py" \
    provider-state "$repo_root" "$kernel_series" "${installed_bbr_patches[@]}"
)"
module_version_destination_dir="$openwrt_dir/target/linux/generic/$module_version_install_directory"
[ -d "$module_version_destination_dir" ] || {
  echo "::error::OpenWrt module-version patch directory is missing: $module_version_install_directory" >&2
  exit 1
}
module_version_destination="$module_version_destination_dir/$module_version_install_name"
case "$provider_module_version_state" in
  compatibility-required)
    if [ -e "$module_version_destination" ]; then
      [ "$(sha256sum "$module_version_destination" | awk '{print $1}')" = "$module_version_sha256" ] || {
        echo "::error::Refusing to overwrite a different BBRv3 module-version patch" >&2
        exit 1
      }
      module_version_status="compatibility-present"
    else
      install -m 0644 "$module_version_patch" "$module_version_destination"
      module_version_status="compatibility-installed"
    fi
    ;;
  upstream)
    [ ! -e "$module_version_destination" ] || {
      echo "::error::Provider already retains module version but a companion patch is present" >&2
      exit 1
    }
    module_version_status="upstream"
    ;;
  *)
    echo "::error::Unsupported BBRv3 module-version state: $provider_module_version_state" >&2
    exit 1
    ;;
esac
{
  echo "bbrv3_module_version_status=$module_version_status"
  echo "bbrv3_module_version_patch=${module_version_patch#"$repo_root"/}"
  echo "bbrv3_module_version_patch_sha256=$module_version_sha256"
  echo "bbrv3_module_version_destination=${module_version_destination#"$openwrt_dir"/}"
} >> "$report"

grep -Eq '^\+.*BBR_VERSION[[:space:]]+3$' "${installed_bbr_patches[@]}"
grep -Eq '^[ +].*\.name[[:space:]]*=[[:space:]]*"bbr"' "${installed_bbr_patches[@]}"

netsupport="$openwrt_dir/package/kernel/linux/modules/netsupport.mk"
grep -Fq 'define KernelPackage/tcp-bbr' "$netsupport"
grep -Fq 'net/ipv4/tcp_bbr.ko' "$netsupport"
grep -Fq 'AutoProbe,tcp_bbr' "$netsupport"
grep -Fq 'define KernelPackage/sched' "$netsupport"
grep -Fq 'sch_fq' "$netsupport"

{
  echo "bbrv3_status=installed-into-openwrt-kernel-patch-stack"
  echo "bbrv3_provider=$bbr_provider"
  echo "bbrv3_origin_url=$origin_url"
  echo "bbrv3_origin_ref=$origin_ref"
  echo "bbrv3_origin_commit=$origin_commit"
  echo "bbrv3_patch_count=${#installed_bbr_patches[@]}"
  echo "bbrv3_install_directory=target/linux/generic/$install_directory"
  echo "assertion_BBR_VERSION=3"
  echo "assertion_runtime_name=bbr"
  echo "assertion_module_version_metadata=retained"
  echo "assertion_kernel_package=tcp-bbr"
  echo "assertion_qdisc_provider=kmod-sched:sch_fq"
} >> "$report"

echo "Profile patches prepared for $profile. Report: $report"
