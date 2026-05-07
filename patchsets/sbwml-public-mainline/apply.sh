#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  patchsets/sbwml-public-mainline/apply.sh <openwrt-dir>

Restricted sbwml patch applier. It reuses public sbwml patch/package material,
but never runs sbwml build scripts, feeds commands, package lists, or config
loaders.
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
kernel_version="${PATCHSET_KERNEL_VERSION:-6.18}"
work_dir="${PATCHSET_WORK_DIR:-$openwrt_dir/.profile-patches/sbwml-public-mainline}"
source_tree="$work_dir/r4s_build_script"

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
  retry git clone --depth 1 --branch "$ref" "$repo" "$dest"
  echo "Cloned $label: $repo ($ref)"
}

fetch() {
  local url="$1"
  local output="$2"

  mkdir -p "$(dirname "$output")"
  retry curl -fsSL --retry 3 --retry-delay 2 "$url" -o "$output"
}

copy_file() {
  local source="$1"
  local target="$2"
  local label="$3"

  if [ ! -r "$source" ]; then
    echo "::error::Missing public sbwml material for $label: $source" >&2
    exit 1
  fi

  mkdir -p "$(dirname "$target")"
  cp -f "$source" "$target"
  echo "Installed $label: ${target#$openwrt_dir/}"
}

apply_patch_file() {
  local patch_file="$1"
  local label="$2"
  local mode="${3:-required}"

  if [ ! -r "$patch_file" ]; then
    if [ "$mode" = "optional" ]; then
      echo "skipped-missing: $label"
      return 0
    fi
    echo "::error::Missing public sbwml patch for $label: $patch_file" >&2
    exit 1
  fi

  if git -C "$openwrt_dir" apply --check --whitespace=nowarn "$patch_file"; then
    git -C "$openwrt_dir" apply --whitespace=nowarn "$patch_file"
    echo "Applied $label"
    return 0
  fi

  if git -C "$openwrt_dir" apply --reverse --check --whitespace=nowarn "$patch_file" >/dev/null 2>&1; then
    echo "already-applied: $label"
    return 0
  fi

  if [ "$mode" = "optional" ]; then
    echo "skipped-conflict: $label"
    git -C "$openwrt_dir" apply --check --whitespace=nowarn "$patch_file" || true
    return 0
  fi

  echo "::error::Failed to apply public sbwml patch: $label" >&2
  echo "Patch file: $patch_file" >&2
  git -C "$openwrt_dir" apply --check --whitespace=nowarn "$patch_file" || true
  exit 1
}

patch_in_place() {
  local path="$1"
  local expr="$2"
  local label="$3"

  if [ ! -e "$path" ]; then
    echo "skipped-missing: $label"
    return 0
  fi

  perl -0pi -e "$expr" "$path"
  echo "Patched $label"
}

preflight() {
  local missing=()

  [ -d "$openwrt_dir/target/linux/generic" ] ||
    missing+=("OpenWrt source target/linux/generic")
  [ -d "$openwrt_dir/target/linux/rockchip" ] ||
    missing+=("OpenWrt source target/linux/rockchip")
  [ -d "$openwrt_dir/package/kernel/linux/modules" ] ||
    missing+=("OpenWrt source package/kernel/linux/modules")

  if [ "${#missing[@]}" -gt 0 ]; then
    {
      echo "::error::Missing inputs for restricted sbwml patch application."
      echo "This patchset must run inside a prepared OpenWrt tree after feeds are installed."
      echo "It does not run sbwml build scripts or use private target trees."
      printf '  - %s\n' "${missing[@]}"
    } >&2
    exit 1
  fi
}

apply_generic_kernel_compat_fallback() {
  local phy_dir="$openwrt_dir/target/linux/generic/files/drivers/net/phy"

  if [ ! -d "$phy_dir" ]; then
    echo "::error::Cannot apply generic 6.18 compatibility fallback: missing $phy_dir" >&2
    exit 1
  fi

  find "$phy_dir" -type f -name '*.c' -print0 |
    xargs -0 perl -0pi -e '
      s/\.remove_new(\s*=)/.remove$1/g;
      s/phy_register_fixup_for_id\(PHY_ANY_ID,/phy_register_fixup_for_id("MATCH ANY PHY",/g;
      s/\bphy_driver_register\(([^,\n]+),\s*THIS_MODULE\)/phy_drivers_register($1, 1, THIS_MODULE)/g;
      s/\bphy_driver_unregister\(([^)\n]+)\)/phy_drivers_unregister($1, 1)/g;
    '

  echo "Applied generic linux-${kernel_version} compatibility fallback for PHY helpers"
}

apply_generic_kernel_metadata() {
  local patch_file="$source_tree/openwrt/patch/kernel-${kernel_version}/openwrt/linux-${kernel_version}-target-linux-generic.patch"

  if git -C "$openwrt_dir" apply --check --whitespace=nowarn "$patch_file"; then
    git -C "$openwrt_dir" apply --whitespace=nowarn "$patch_file"
    echo "Applied linux-${kernel_version} target/linux/generic metadata patch"
    return 0
  fi

  if git -C "$openwrt_dir" apply --reverse --check --whitespace=nowarn "$patch_file" >/dev/null 2>&1; then
    echo "already-applied: linux-${kernel_version} target/linux/generic metadata patch"
    return 0
  fi

  echo "Patch did not apply cleanly; using restricted compatibility fallback:"
  echo "  $patch_file"
  git -C "$openwrt_dir" apply --check --whitespace=nowarn "$patch_file" || true
  apply_generic_kernel_compat_fallback
}

install_kernel_version() {
  local kernel_tag="$work_dir/kernel-${kernel_version}"
  local generic_dir="$openwrt_dir/target/linux/generic"
  local rockchip_dir="$openwrt_dir/target/linux/rockchip"

  fetch "$raw_base/tags/kernel-${kernel_version}" "$kernel_tag"
  if [ ! -s "$kernel_tag" ]; then
    echo "::error::Downloaded kernel tag is empty: $raw_base/tags/kernel-${kernel_version}" >&2
    exit 1
  fi

  install -m 0644 "$kernel_tag" "$generic_dir/kernel-${kernel_version}"

  if [ ! -r "$generic_dir/config-${kernel_version}" ]; then
    if [ -r "$generic_dir/config-6.12" ]; then
      cp -f "$generic_dir/config-6.12" "$generic_dir/config-${kernel_version}"
    else
      echo "::error::Cannot synthesize target/linux/generic/config-${kernel_version}: missing config-6.12" >&2
      exit 1
    fi
  fi

  if [ ! -r "$rockchip_dir/armv8/config-${kernel_version}" ]; then
    if [ -r "$rockchip_dir/armv8/config-6.12" ]; then
      cp -f "$rockchip_dir/armv8/config-6.12" "$rockchip_dir/armv8/config-${kernel_version}"
    else
      echo "::error::Cannot synthesize target/linux/rockchip/armv8/config-${kernel_version}: missing config-6.12" >&2
      exit 1
    fi
  fi

  if grep -q '^KERNEL_PATCHVER:=' "$rockchip_dir/Makefile"; then
    sed -i -E "s/^(KERNEL_PATCHVER:=).*/\1${kernel_version}/" "$rockchip_dir/Makefile"
  else
    printf '\nKERNEL_PATCHVER:=%s\n' "$kernel_version" >> "$rockchip_dir/Makefile"
  fi

  if grep -q '^KERNEL_TESTING_PATCHVER:=' "$rockchip_dir/Makefile"; then
    sed -i -E 's/^(KERNEL_TESTING_PATCHVER:=).*/\16.12/' "$rockchip_dir/Makefile"
  else
    sed -i "/^KERNEL_PATCHVER:=/aKERNEL_TESTING_PATCHVER:=6.12" "$rockchip_dir/Makefile"
  fi

  echo "Installed linux-${kernel_version} kernel metadata and Rockchip target selection"
}

preserve_iptables_fullcone_module() {
  local original_netfilter="$1"
  local target_netfilter="$2"
  local package_fullcone

  if grep -q 'KernelPackage/ipt-fullconenat' "$target_netfilter"; then
    echo "Kept sbwml iptables fullcone module definition"
    return 0
  fi

  package_fullcone="$(
    find "$openwrt_dir/package" -type f -name Makefile -print0 |
      xargs -0 grep -l 'KernelPackage/ipt-fullconenat' |
      head -n 1 || true
  )"
  if [ -n "$package_fullcone" ]; then
    echo "Kept Lean iptables fullcone package definition: ${package_fullcone#$openwrt_dir/}"
    return 0
  fi

  if [ ! -r "$original_netfilter" ] || ! grep -q 'KernelPackage/ipt-fullconenat' "$original_netfilter"; then
    echo "::error::Cannot preserve Lean iptables fullcone module definition." >&2
    echo "The sbwml 6.x module set is nft/fullcone oriented, while this profile requires firewall3/iptables fullcone." >&2
    echo "Expected to find KernelPackage/ipt-fullconenat in package/network/services/fullconenat or original netfilter.mk." >&2
    exit 1
  fi

  {
    printf '\n\n# Preserved from the Lean netfilter module definitions for firewall3/iptables fullcone.\n'
    awk '
      /^define KernelPackage\/ipt-fullconenat$/ {
        emit = 1
      }

      emit {
        print
      }

      /^\$\(eval \$\(call KernelPackage,ipt-fullconenat\)\)$/ {
        found = 1
        exit
      }

      END {
        if (!found) {
          exit 3
        }
      }
    ' "$original_netfilter"
  } >> "$target_netfilter"

  echo "Preserved Lean iptables fullcone module definition"
}

install_kernel_module_makefiles() {
  local source_dir="$source_tree/openwrt/patch/openwrt-6.x/modules"
  local target_dir="$openwrt_dir/package/kernel/linux/modules"
  local original_netfilter="$work_dir/original-netfilter.mk"

  if [ ! -d "$source_dir" ]; then
    echo "::error::Missing public sbwml module definitions: $source_dir" >&2
    exit 1
  fi

  if [ -r "$target_dir/netfilter.mk" ]; then
    cp -f "$target_dir/netfilter.mk" "$original_netfilter"
  fi

  rm -f "$target_dir"/[a-z]*.mk
  cp -f "$source_dir"/*.mk "$target_dir/"
  preserve_iptables_fullcone_module "$original_netfilter" "$target_dir/netfilter.mk"
  echo "Installed linux-${kernel_version} kernel module definitions"
}

copy_kernel_patches() {
  local source_dir="$source_tree/openwrt/patch/kernel-${kernel_version}"
  local backport_dir="$openwrt_dir/target/linux/generic/backport-${kernel_version}"
  local hack_dir="$openwrt_dir/target/linux/generic/hack-${kernel_version}"
  local patch_file name

  mkdir -p "$backport_dir" "$hack_dir"

  find "$source_dir/bbr3" -maxdepth 1 -type f -name '*.patch' -exec cp -f {} "$backport_dir/" \;
  find "$source_dir/lrng" -maxdepth 1 -type f -name '*.patch' -exec cp -f {} "$hack_dir/" \;
  find "$source_dir/btf" -maxdepth 1 -type f -name '*.patch' -exec cp -f {} "$hack_dir/" \;
  find "$source_dir/arm64" -maxdepth 1 -type f -name '*.patch' -exec cp -f {} "$hack_dir/" \;

  while IFS= read -r -d '' patch_file; do
    name="$(basename "$patch_file")"
    case "$name" in
      *nft*|*nftables*)
        echo "skipped-conflict: nft/firewall4-only kernel patch $name"
        ;;
      *conntrack-events-support-multiple-registrant*)
        if find "$hack_dir" -maxdepth 1 -type f -name '*conntrack-events-support-multiple-registrant*.patch' | grep -q .; then
          echo "skipped-duplicate: existing conntrack event multi-registrant patch for $name"
        else
          cp -f "$patch_file" "$hack_dir/"
        fi
        ;;
      *support-shortcut-fe*)
        if find "$hack_dir" -maxdepth 1 -type f -name '*support-shortcut-fe*.patch' | grep -q .; then
          echo "skipped-duplicate: existing shortcut-fe kernel patch for $name"
        else
          cp -f "$patch_file" "$hack_dir/"
        fi
        ;;
      *bcm-fullcone*|*bcm-fullconenat*)
        if find "$hack_dir" -maxdepth 1 -type f \( -name '*bcm-fullcone*.patch' -o -name '*bcm-fullconenat*.patch' \) | grep -q .; then
          echo "skipped-duplicate: existing bcm fullcone kernel patch for $name"
        else
          cp -f "$patch_file" "$hack_dir/"
        fi
        ;;
      *)
        cp -f "$patch_file" "$hack_dir/"
        ;;
    esac
  done < <(find "$source_dir/net" -maxdepth 1 -type f -name '*.patch' -print0)

  echo "Installed public linux-${kernel_version} BBR3/LRNG/BTF/arm64/netfilter patches"
}

apply_generic_build_patches() {
  local patch_dir="$source_tree/openwrt/patch/generic-25.12"
  local patch_file

  for patch_file in "$patch_dir"/*.patch; do
    apply_patch_file "$patch_file" "generic build support $(basename "$patch_file")" optional
  done
}

apply_target_and_performance_tuning() {
  apply_patch_file \
    "$source_tree/openwrt/patch/target-modify_for_aarch64_x86_64.patch" \
    "aarch64/x86 target optimization" \
    optional

  patch_in_place \
    "$openwrt_dir/include/package.mk" \
    's/-flto=auto/-flto=jobserver/g' \
    "LTO jobserver"

  patch_in_place \
    "$openwrt_dir/package/libs/libubox/Makefile" \
    's/(TARGET_CFLAGS[^\n]*)/$1 -O2/g' \
    "libubox O2 target flags"
}

install_public_package_replacements() {
  clone_repo https://github.com/sbwml/autocore-arm.git openwrt-25.12 "$openwrt_dir/package/system/autocore" "autocore-arm"
  clone_repo https://github.com/sbwml/package_boot_uboot-rockchip.git v2023.04 "$openwrt_dir/package/boot/uboot-rockchip" "Rockchip U-Boot"
  clone_repo https://github.com/sbwml/arm-trusted-firmware-rockchip.git 0419 "$openwrt_dir/package/boot/arm-trusted-firmware-rockchip" "Rockchip ARM Trusted Firmware"
  clone_repo https://github.com/sbwml/package_kernel_r8168.git master "$openwrt_dir/package/kernel/r8168" "Realtek R8168"
  clone_repo https://github.com/sbwml/package_kernel_r8152.git master "$openwrt_dir/package/kernel/r8152" "Realtek RTL8152 vendor"
  clone_repo https://github.com/sbwml/package_firmware_linux-firmware.git main "$openwrt_dir/package/firmware/linux-firmware" "linux-firmware"
  clone_repo https://github.com/sbwml/package_kernel_mac80211.git v6.18 "$openwrt_dir/package/kernel/mac80211" "mac80211 linux-${kernel_version}"
  clone_repo https://github.com/sbwml/package_kernel_ath10k-ct.git v6.18 "$openwrt_dir/package/kernel/ath10k-ct" "ath10k-ct linux-${kernel_version}"
  clone_repo https://github.com/sbwml/package_system_fstools.git openwrt-25.12 "$openwrt_dir/package/system/fstools" "fstools"
  clone_repo https://github.com/sbwml/package_utils_util-linux.git openwrt-25.12 "$openwrt_dir/package/utils/util-linux" "util-linux"
}

install_6_18_build_fixes() {
  local patch_base="$source_tree/openwrt/patch/packages-patches"

  if [ -r "$openwrt_dir/package/kernel/bpf-headers/Makefile" ]; then
    sed -i -E "s/^(PKG_PATCHVER:=).*/\1${kernel_version}/" "$openwrt_dir/package/kernel/bpf-headers/Makefile"
    copy_file "$patch_base/bpf-headers/900-fix-build.patch" \
      "$openwrt_dir/package/kernel/bpf-headers/patches/900-fix-build.patch" \
      "bpf-headers linux-${kernel_version} build fix"
  else
    echo "skipped-missing: bpf-headers linux-${kernel_version} build fix"
  fi

  [ -d "$openwrt_dir/package/kernel/cryptodev-linux" ] &&
    copy_file "$patch_base/cryptodev-linux/${kernel_version}/900-fix-linux-${kernel_version}.patch" \
      "$openwrt_dir/package/kernel/cryptodev-linux/patches/900-fix-linux-${kernel_version}.patch" \
      "cryptodev-linux linux-${kernel_version} build fix" ||
    echo "skipped-missing: cryptodev-linux linux-${kernel_version} build fix"

  apply_patch_file "$patch_base/gpio-button-hotplug/fix-linux-${kernel_version}.patch" "gpio-button-hotplug linux-${kernel_version} build fix" optional
  apply_patch_file "$patch_base/gpio-nct5104d/fix-linux-${kernel_version}.patch" "gpio-nct5104d linux-${kernel_version} build fix" optional
  apply_patch_file "$patch_base/ubootenv-nvram/010-fix-build-for-linux-${kernel_version}.patch" "ubootenv-nvram linux-${kernel_version} build fix" optional

  if [ -d "$openwrt_dir/package/kernel/nat46" ]; then
    copy_file "$patch_base/nat46/102-fix-build-with-kernel-${kernel_version}.patch" \
      "$openwrt_dir/package/kernel/nat46/patches/102-fix-build-with-kernel-${kernel_version}.patch" \
      "nat46 linux-${kernel_version} build fix"
  else
    echo "skipped-missing: nat46 linux-${kernel_version} build fix"
  fi
}

install_runtime_tuning_files() {
  local source_dir="$source_tree/openwrt/files/etc/sysctl.d"
  local target_dir="$openwrt_dir/files/etc/sysctl.d"

  mkdir -p "$target_dir"
  copy_file "$source_dir/10-default.conf" "$target_dir/10-default.conf" "sbwml sysctl defaults"
  copy_file "$source_dir/15-vm-swappiness.conf" "$target_dir/15-vm-swappiness.conf" "sbwml vm swappiness tuning"
  copy_file "$source_dir/16-udp-buffer-size.conf" "$target_dir/16-udp-buffer-size.conf" "sbwml UDP buffer tuning"
}

apply_small_web_ui_fixes() {
  apply_patch_file "$source_tree/openwrt/patch/luci/0001-luci-mod-system-add-modal-overlay-dialog-to-reboot.patch" "LuCI reboot dialog fix" optional
  apply_patch_file "$source_tree/openwrt/patch/luci/0002-luci-mod-status-displays-actual-process-memory-usage.patch" "LuCI memory display fix" optional
  apply_patch_file "$source_tree/openwrt/patch/luci/0003-luci-mod-status-storage-index-applicable-only-to-val.patch" "LuCI storage display fix" optional
  apply_patch_file "$source_tree/openwrt/patch/luci/0005-luci-mod-system-add-refresh-interval-setting.patch" "LuCI status refresh setting" optional
  apply_patch_file "$source_tree/openwrt/patch/luci/0007-luci-mod-system-add-ucitrack-luci-mod-system-zram.js.patch" "LuCI zram ucitrack fix" optional
  apply_patch_file "$source_tree/openwrt/patch/luci/applications/luci-app-package-manager/0001-luci-app-package-manager-support-installing-uploaded.patch" "LuCI package upload install fix" optional

  patch_in_place "$openwrt_dir/feeds/luci/applications/luci-app-ttyd/root/usr/share/luci/menu.d/luci-app-ttyd.json" \
    's/services/system/g; s/("title"[^\n]*\n)/$1\t\t"order": 50,\n/s' \
    "ttyd LuCI menu"
  patch_in_place "$openwrt_dir/feeds/packages/utils/ttyd/files/ttyd.init" \
    's/procd_set_param stdout 1/procd_set_param stdout 0/g; s/procd_set_param stderr 1/procd_set_param stderr 0/g' \
    "ttyd quiet init logging"
  patch_in_place "$openwrt_dir/package/system/rpcd/files/rpcd.config" \
    's/option timeout 30/option timeout 60/g' \
    "rpcd timeout"
  patch_in_place "$openwrt_dir/feeds/luci/modules/luci-base/htdocs/luci-static/resources/rpc.js" \
    's/20\) \* 1000/60) * 1000/g' \
    "LuCI RPC timeout"
}

patch_turboacc_for_bbr3() {
  local makefile="$openwrt_dir/package/feeds/luci/luci-app-turboacc/Makefile"

  if [ ! -r "$makefile" ]; then
    echo "skipped-missing: Turbo ACC BBRv3 dependency patch"
    return 0
  fi

  if ! grep -Rqs 'KernelPackage/tcp-bbr3' "$openwrt_dir/package/kernel/linux/modules"; then
    echo "skipped-missing: Turbo ACC BBRv3 dependency patch because kmod-tcp-bbr3 is unavailable"
    return 0
  fi

  perl -0pi -e 's/kmod-tcp-bbr\b/kmod-tcp-bbr3/g' "$makefile"
  echo "Patched Turbo ACC BBR dependency for sbwml BBRv3"
}

echo "Using restricted sbwml patch source: $source_repo ($source_ref)"
echo "Using sbwml raw patch source: $raw_base"
echo "Using kernel patch version: $kernel_version"
echo "No sbwml scripts, feeds commands, package lists, or .config fragments are executed."
echo "Private target trees are not accessed; public material is applied onto the current OpenWrt tree."

rm -rf "$work_dir"
mkdir -p "$work_dir"

preflight
clone_repo "$source_repo" "$source_ref" "$source_tree" "sbwml public patch source"

apply_generic_build_patches
apply_generic_kernel_metadata
install_kernel_version
install_kernel_module_makefiles
copy_kernel_patches
apply_target_and_performance_tuning
install_public_package_replacements
install_6_18_build_fixes
install_runtime_tuning_files
apply_small_web_ui_fixes
patch_turboacc_for_bbr3

echo "Restricted sbwml R4S public optimization patchset completed."
