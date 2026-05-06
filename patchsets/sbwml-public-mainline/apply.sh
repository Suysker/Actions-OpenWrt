#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  patchsets/sbwml-public-mainline/apply.sh <openwrt-dir>

Applies the public portion of sbwml's mainline kernel patch chain.
Private git.cooluc.com target trees are intentionally not used.
EOF
}

openwrt_dir="${1:-}"
[ -n "$openwrt_dir" ] || { usage; exit 2; }
[ -d "$openwrt_dir" ] || { echo "::error::OpenWrt source directory does not exist: $openwrt_dir" >&2; exit 2; }

openwrt_dir="$(cd "$openwrt_dir" && pwd)"
source_ref="${PATCHSET_SOURCE_REF:-master}"
script_repo="${PATCHSET_SOURCE_REPO:-https://github.com/sbwml/r4s_build_script.git}"
raw_base="${PATCHSET_RAW_BASE:-https://raw.githubusercontent.com/sbwml/r4s_build_script/refs/heads/$source_ref}"
raw_base="${raw_base%/}"
work_dir="${PATCHSET_WORK_DIR:-$openwrt_dir/.profile-patches/sbwml-public-mainline}"
script_tree="$work_dir/r4s_build_script"

retry() {
  local attempt max_attempts delay
  max_attempts=3
  delay=5

  for attempt in $(seq 1 "$max_attempts"); do
    if "$@"; then
      return 0
    fi
    if [ "$attempt" -lt "$max_attempts" ]; then
      echo "Command failed; retrying in ${delay}s: $*" >&2
      sleep "$delay"
    fi
  done

  return 1
}

clone_script_repo() {
  rm -rf "$script_tree"
  git clone --depth 1 --branch "$source_ref" "$script_repo" "$script_tree"
}

fetch() {
  local url="$1"
  local output="$2"

  mkdir -p "$(dirname "$output")"
  retry curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$output"
}

apply_git_patch() {
  local patch_file="$1"
  local label="$2"

  if git -C "$openwrt_dir" apply --check "$patch_file"; then
    git -C "$openwrt_dir" apply "$patch_file"
    echo "Applied $label"
    return 0
  fi

  if git -C "$openwrt_dir" apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    echo "Patch already applied: $label"
    return 0
  fi

  echo "::error::Failed to apply public sbwml patch: $label" >&2
  echo "Patch file: $patch_file" >&2
  git -C "$openwrt_dir" apply --check "$patch_file" || true
  exit 1
}

copy_patch_dir() {
  local source_dir="$1"
  local target_dir="$2"
  local label="$3"

  if [ ! -d "$source_dir" ]; then
    echo "::error::Missing public sbwml patch directory: $source_dir" >&2
    exit 1
  fi

  mkdir -p "$target_dir"
  find "$source_dir" -maxdepth 1 -type f -name '*.patch' -print0 |
    while IFS= read -r -d '' patch_file; do
      cp -f "$patch_file" "$target_dir/"
    done
  echo "Copied $label patches into ${target_dir#$openwrt_dir/}"
}

require_public_mainline_target() {
  local missing=()

  [ -r "$openwrt_dir/target/linux/generic/config-6.18" ] || missing+=("target/linux/generic/config-6.18")
  [ -r "$openwrt_dir/target/linux/rockchip/armv8/config-6.18" ] || missing+=("target/linux/rockchip/armv8/config-6.18")

  if [ "${#missing[@]}" -gt 0 ]; then
    {
      echo "::error::sbwml public patchset is incomplete for this Lean tree."
      echo "The public scripts require target files normally supplied by private git.cooluc.com repositories."
      echo "Missing after applying public patches:"
      printf '  - %s\n' "${missing[@]}"
      echo
      echo "Intentionally not used:"
      echo "  - https://git.cooluc.com/sbwml/target_linux_generic"
      echo "  - https://git.cooluc.com/sbwml/target_linux_rockchip-6.x"
      echo "  - https://git.cooluc.com/sbwml/target_linux_armsr"
      echo
      echo "Stopping here instead of silently producing a partial or fake 6.18 R4S build."
    } >&2
    exit 1
  fi
}

echo "Using public sbwml script repository: $script_repo"
echo "Using public sbwml source ref: $source_ref"
echo "Using public sbwml raw source: $raw_base"
echo "Private git.cooluc.com target repositories are not accessed by this patchset."

rm -rf "$work_dir"
mkdir -p "$work_dir"
retry clone_script_repo

kernel_tag="$work_dir/kernel-6.18"
fetch "$raw_base/tags/kernel-6.18" "$kernel_tag"

if [ ! -s "$kernel_tag" ]; then
  echo "::error::Downloaded kernel-6.18 tag is empty: $raw_base/tags/kernel-6.18" >&2
  exit 1
fi

if [ ! -d "$openwrt_dir/target/linux/generic" ]; then
  echo "::error::OpenWrt tree has no target/linux/generic directory" >&2
  exit 1
fi

install -m 0644 "$kernel_tag" "$openwrt_dir/target/linux/generic/kernel-6.18"
echo "Installed public kernel version metadata: target/linux/generic/kernel-6.18"

generic_patch="$script_tree/openwrt/patch/kernel-6.18/openwrt/linux-6.18-target-linux-generic.patch"
[ -r "$generic_patch" ] || { echo "::error::Missing public sbwml generic patch: $generic_patch" >&2; exit 1; }
apply_git_patch "$generic_patch" "linux-6.18 target/linux/generic metadata"

require_public_mainline_target

copy_patch_dir "$script_tree/openwrt/patch/kernel-6.18/bbr3" "$openwrt_dir/target/linux/generic/backport-6.18" "BBR3"
copy_patch_dir "$script_tree/openwrt/patch/kernel-6.18/lrng" "$openwrt_dir/target/linux/generic/hack-6.18" "LRNG"
copy_patch_dir "$script_tree/openwrt/patch/kernel-6.18/linux-rt" "$openwrt_dir/target/linux/generic/hack-6.18" "PREEMPT_RT"
copy_patch_dir "$script_tree/openwrt/patch/kernel-6.18/btf" "$openwrt_dir/target/linux/generic/hack-6.18" "BTF"
copy_patch_dir "$script_tree/openwrt/patch/kernel-6.18/arm64" "$openwrt_dir/target/linux/generic/hack-6.18" "arm64"
copy_patch_dir "$script_tree/openwrt/patch/kernel-6.18/net" "$openwrt_dir/target/linux/generic/hack-6.18" "netfilter/network"

echo "sbwml public mainline patchset applied."
