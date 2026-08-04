#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  apply-profile-patches.sh <profile> <openwrt-dir> <source-lock.json> <report.txt>

Applies repository-owned OpenWrt common/device patches, feed-local patches, and
the BBRv3 port selected by the immutable source lock.
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

readarray -t locked < <(
  bash "$repo_root/scripts/resolve-source-lock.sh" \
    profile-kernel-plan "$source_lock" "$profile"
)
[ "${#locked[@]}" -eq 10 ] || {
  echo "::error::Could not parse the locked patch contract for $profile" >&2
  exit 1
}

kernel_channel="${locked[0]}"
kernel_series="${locked[1]}"
kernel_version="${locked[2]}"
kernel_source_sha256="${locked[3]}"
kernel_target="${locked[4]}"
bbr_provider="${locked[5]}"
origin_url="${locked[6]}"
origin_ref="${locked[7]}"
origin_commit="${locked[8]}"
install_directory="${locked[9]}"
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

mapfile -t locked_patches < <(
  bash "$repo_root/scripts/resolve-source-lock.sh" \
    bbr-patch-plan "$source_lock" "$profile"
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
actual_series="$(
  python3 "$repo_root/scripts/kernel_selection.py" \
    target-series "$target_makefile" "$kernel_channel"
)"
[ "$actual_series" = "$kernel_series" ] || {
  echo "::error::OpenWrt $kernel_channel kernel $actual_series differs from locked $kernel_series" >&2
  exit 1
}

apply_series() {
  local layer="$1" directory="$2" worktree="$3" series_file="$2/series"
  local patch_name patch_path state
  [ -f "$series_file" ] || {
    echo "::error::Missing $layer patch series: $series_file" >&2
    exit 1
  }
  git -C "$worktree" rev-parse --is-inside-work-tree >/dev/null 2>&1 || {
    echo "::error::$layer patch target is not a Git worktree: $worktree" >&2
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
    if git -C "$worktree" apply --check "$patch_path" >/dev/null 2>&1; then
      git -C "$worktree" apply "$patch_path"
      state="applied"
    elif git -C "$worktree" apply --reverse --check "$patch_path" >/dev/null 2>&1; then
      state="present"
    else
      echo "::error::$layer patch neither applies nor is already present: $patch_name" >&2
      exit 1
    fi
    printf '%s_%s=%s sha256:%s\n' "$state" "$layer" "$patch_name" \
      "$(sha256sum "$patch_path" | awk '{print $1}')" >> "$report"
  done < "$series_file"
}

source_lock_digest="$(bash "$repo_root/scripts/resolve-source-lock.sh" digest "$source_lock")"
{
  echo "patch-report-v3"
  echo "profile=$profile"
  echo "source_lock_digest=$source_lock_digest"
  echo "kernel_target=$kernel_target"
  echo "kernel_channel=$kernel_channel"
  echo "kernel_series=$kernel_series"
  echo "kernel_version=$kernel_version"
  echo "kernel_source_sha256=$kernel_source_sha256"
} > "$report"

python3 "$repo_root/scripts/apply-source-compatibility.py" \
  "$repo_root/profiles/common/source-compatibility.json" "$openwrt_dir" "$report" \
  "$kernel_series"
apply_series common "$repo_root/patchsets/common" "$openwrt_dir"
apply_series device "$repo_root/patchsets/$profile" "$openwrt_dir"
apply_series feed_passwall "$repo_root/patchsets/feeds/passwall" \
  "$openwrt_dir/feeds/passwall"
apply_series feed_kenzo "$repo_root/patchsets/feeds/kenzo" \
  "$openwrt_dir/feeds/kenzo"

destination_dir="$openwrt_dir/target/linux/generic/$install_directory"
[ -d "$destination_dir" ] || {
  echo "::error::OpenWrt generic selected-kernel patch directory is missing: $destination_dir" >&2
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
  python3 "$repo_root/scripts/kernel_patch.py" validate "$materialized_patch"
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
