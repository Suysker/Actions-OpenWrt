#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  patchsets/sbwml-public-mainline/apply.sh <openwrt-dir>

Restricted sbwml patch applier. It uses sbwml's public patch files as source
material, but never runs sbwml build scripts, feeds commands, or config loaders.
EOF
}

openwrt_dir="${1:-}"
[ -n "$openwrt_dir" ] || { usage; exit 2; }
[ -d "$openwrt_dir" ] || { echo "::error::OpenWrt source directory does not exist: $openwrt_dir" >&2; exit 2; }

openwrt_dir="$(cd "$openwrt_dir" && pwd)"
source_ref="${PATCHSET_SOURCE_REF:-master}"
source_repo="${PATCHSET_SOURCE_REPO:-https://github.com/sbwml/r4s_build_script.git}"
raw_base="${PATCHSET_RAW_BASE:-https://raw.githubusercontent.com/sbwml/r4s_build_script/refs/heads/$source_ref}"
raw_base="${raw_base%/}"
target_rockchip_repo="${PATCHSET_TARGET_ROCKCHIP_REPO:-}"
target_rockchip_ref="${PATCHSET_TARGET_ROCKCHIP_REF:-v6.18}"
target_generic_repo="${PATCHSET_TARGET_GENERIC_REPO:-}"
target_generic_ref="${PATCHSET_TARGET_GENERIC_REF:-openwrt-25.12}"
kernel_patch_dirs="${PATCHSET_KERNEL_PATCH_DIRS:-bbr3 lrng btf arm64 net}"
work_dir="${PATCHSET_WORK_DIR:-$openwrt_dir/.profile-patches/sbwml-public-mainline}"
source_tree="$work_dir/r4s_build_script"
rockchip_tree="$work_dir/target-linux-rockchip"
generic_tree="$work_dir/target-linux-generic"

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

clone_repo() {
  local repo="$1"
  local ref="$2"
  local dest="$3"
  local label="$4"

  rm -rf "$dest"
  git clone --depth 1 --branch "$ref" "$repo" "$dest"
  echo "Cloned $label: $repo ($ref)"
}

fetch() {
  local url="$1"
  local output="$2"

  mkdir -p "$(dirname "$output")"
  retry curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$output"
}

preflight() {
  local missing=()

  [ -d "$openwrt_dir/target/linux/generic" ] ||
    missing+=("OpenWrt source target/linux/generic")
  [ -n "$target_rockchip_repo" ] ||
    missing+=("PATCHSET_TARGET_ROCKCHIP_REPO public replacement for target_linux_rockchip-6.x")
  [ -n "$target_generic_repo" ] ||
    missing+=("PATCHSET_TARGET_GENERIC_REPO public replacement for target_linux_generic")

  if [ "${#missing[@]}" -gt 0 ]; then
    {
      echo "::error::Missing inputs for restricted sbwml patch application."
      echo "This patchset only applies patch/source-tree material under our own build flow."
      echo "It does not execute sbwml scripts or access private git.cooluc.com repositories."
      echo
      echo "Missing:"
      printf '  - %s\n' "${missing[@]}"
      echo
      echo "Expected public replacements:"
      echo "  - PATCHSET_TARGET_ROCKCHIP_REPO for git.cooluc.com/sbwml/target_linux_rockchip-6.x"
      echo "  - PATCHSET_TARGET_GENERIC_REPO for git.cooluc.com/sbwml/target_linux_generic"
    } >&2
    exit 1
  fi
}

validate_target_trees() {
  local missing=()

  [ -r "$rockchip_tree/Makefile" ] || missing+=("rockchip replacement Makefile")
  [ -r "$rockchip_tree/armv8/config-6.18" ] || missing+=("rockchip replacement armv8/config-6.18")
  [ -r "$generic_tree/config-6.18" ] || missing+=("generic replacement config-6.18")

  if [ "${#missing[@]}" -gt 0 ]; then
    {
      echo "::error::Public target replacements do not look like sbwml target trees."
      printf '  - %s\n' "${missing[@]}"
    } >&2
    exit 1
  fi
}

install_target_trees() {
  rm -rf "$openwrt_dir/target/linux/rockchip"
  mkdir -p "$openwrt_dir/target/linux/rockchip" "$openwrt_dir/target/linux/generic"

  cp -a "$rockchip_tree"/. "$openwrt_dir/target/linux/rockchip/"
  cp -a "$generic_tree"/. "$openwrt_dir/target/linux/generic/"

  echo "Installed restricted target/linux replacements:"
  echo "  - target/linux/rockchip from PATCHSET_TARGET_ROCKCHIP_REPO"
  echo "  - target/linux/generic overlay from PATCHSET_TARGET_GENERIC_REPO"
}

install_kernel_tag() {
  local kernel_tag
  kernel_tag="$work_dir/kernel-6.18"

  fetch "$raw_base/tags/kernel-6.18" "$kernel_tag"
  if [ ! -s "$kernel_tag" ]; then
    echo "::error::Downloaded kernel tag is empty: $raw_base/tags/kernel-6.18" >&2
    exit 1
  fi

  install -m 0644 "$kernel_tag" "$openwrt_dir/target/linux/generic/kernel-6.18"
  echo "Installed target/linux/generic/kernel-6.18"
}

copy_public_kernel_patch_dirs() {
  local dir source_dir target_dir patch_count

  for dir in $kernel_patch_dirs; do
    source_dir="$source_tree/openwrt/patch/kernel-6.18/$dir"
    if [ ! -d "$source_dir" ]; then
      echo "::error::Missing public sbwml kernel patch directory: $source_dir" >&2
      exit 1
    fi

    case "$dir" in
      bbr3)
        target_dir="$openwrt_dir/target/linux/generic/backport-6.18"
        ;;
      lrng|btf|arm64|net)
        target_dir="$openwrt_dir/target/linux/generic/hack-6.18"
        ;;
      *)
        echo "::error::Kernel patch directory '$dir' is not in the restricted allowlist" >&2
        exit 1
        ;;
    esac

    mkdir -p "$target_dir"
    patch_count="$(find "$source_dir" -maxdepth 1 -type f -name '*.patch' | wc -l | tr -d ' ')"
    find "$source_dir" -maxdepth 1 -type f -name '*.patch' -exec cp -f {} "$target_dir/" \;
    echo "Copied $patch_count public $dir patches into ${target_dir#$openwrt_dir/}"
  done
}

echo "Using restricted sbwml patch source: $source_repo ($source_ref)"
echo "Using sbwml raw patch source: $raw_base"
echo "Allowed kernel patch directories: $kernel_patch_dirs"
echo "No sbwml scripts, feeds commands, package lists, or .config fragments are executed."

rm -rf "$work_dir"
mkdir -p "$work_dir"

preflight
retry clone_repo "$source_repo" "$source_ref" "$source_tree" "sbwml patch source"
retry clone_repo "$target_rockchip_repo" "$target_rockchip_ref" "$rockchip_tree" "rockchip target replacement"
retry clone_repo "$target_generic_repo" "$target_generic_ref" "$generic_tree" "generic target replacement"
validate_target_trees
install_target_trees
install_kernel_tag
copy_public_kernel_patch_dirs

echo "Restricted sbwml patch application completed."
