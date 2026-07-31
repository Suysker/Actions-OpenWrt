#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

lock_dir="$tmpdir/source-input"
openwrt="$tmpdir/openwrt"
mkdir -p "$lock_dir/bbr3/6.12" \
  "$openwrt/target/linux/rockchip" \
  "$openwrt/target/linux/generic/hack-6.12" \
  "$openwrt/package/libs/libsepol" \
  "$openwrt/package/kernel/linux/modules"

cat > "$lock_dir/bbr3/6.12/0001-bbrv3.patch" <<'PATCH'
diff --git a/net/ipv4/tcp_bbr.c b/net/ipv4/tcp_bbr.c
--- a/net/ipv4/tcp_bbr.c
+++ b/net/ipv4/tcp_bbr.c
@@ -1,0 +1,3 @@
+#define BBR_VERSION 3
+MODULE_VERSION(__stringify(BBR_VERSION));
+.name = "bbr",
PATCH

patch_sha="$(sha256sum "$lock_dir/bbr3/6.12/0001-bbrv3.patch" | awk '{print $1}')"
python3 - "$lock_dir/source-lock.json" "$patch_sha" <<'PY'
import json
import sys

output, patch_sha = sys.argv[1:]
origin_commit = "9" * 40
origin_path = "6.12/bbr3.patch"
lock = {
    "schema": 2,
    "resolved_at": "2026-01-01T00:00:00Z",
    "repository_commit": "1" * 40,
    "openwrt": {"commit": "2" * 40},
    "feeds": {"packages": {"commit": "3" * 40}},
    "official_golang": {"commit": "4" * 40},
    "actions": {
        "actions/checkout": {"requested_ref": "main", "commit": "5" * 40}
    },
    "profiles": {
        "r4s": {
            "kernel_target": "rockchip",
            "kernel_series": "6.12",
            "kernel_version": "6.12.100",
        }
    },
    "kernel_features": {
        "bbr3": {
            "algorithm": {
                "requested_ref": "v3",
                "commit": "6" * 40,
                "module_version": 3,
                "runtime_name": "bbr",
            },
            "profile_kernel_series": {"r4s": "6.12"},
            "ports": {
                "6.12": {
                    "provider": "fixture-single",
                    "origin_url": "https://github.com/example/ports.git",
                    "origin_ref": "main",
                    "origin_commit": origin_commit,
                    "install_directory": "hack-6.12",
                    "patches": [
                        {
                            "order": 1,
                            "origin_path": origin_path,
                            "raw_url": f"https://raw.githubusercontent.com/example/ports/{origin_commit}/{origin_path}",
                            "sha256": patch_sha,
                            "artifact_path": "bbr3/6.12/0001-bbrv3.patch",
                            "install_name": "995-bbrv3.patch",
                        }
                    ],
                }
            },
        }
    },
    "profile_digests": {"r4s": "sha256:" + "7" * 64},
    "patch_digest": "sha256:" + "8" * 64,
}
with open(output, "w", encoding="utf-8") as handle:
    json.dump(lock, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY

git -C "$openwrt" init -q
printf 'KERNEL_PATCHVER:=6.12\n' > "$openwrt/target/linux/rockchip/Makefile"
cat > "$openwrt/package/libs/libsepol/Makefile" <<'EOF'
#
# This is free software, licensed under the GNU General Public License v2.
# See /LICENSE for more information.
#

include $(TOPDIR)/rules.mk

PKG_NAME:=libsepol
PKG_VERSION:=3.3
PKG_RELEASE:=1

PKG_SOURCE:=$(PKG_NAME)-$(PKG_VERSION).tar.gz
PKG_SOURCE_URL:=https://github.com/SELinuxProject/selinux/releases/download/$(PKG_VERSION)
PKG_HASH:=2d97df3eb8466169b389c3660acbb90c54200ac96e452eca9f41a9639f4f238b

PKG_MAINTAINER:=Thomas Petazzoni <thomas.petazzoni@bootlin.com>
PKG_CPE_ID:=cpe:/a:selinuxproject:libsepol

include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/host-build.mk

EOF
cat > "$openwrt/package/kernel/linux/modules/netsupport.mk" <<'EOF'
define KernelPackage/tcp-bbr
FILES:=$(LINUX_DIR)/net/ipv4/tcp_bbr.ko
AUTOLOAD:=$(call AutoProbe,tcp_bbr)
define KernelPackage/sched
FILES:=$(LINUX_DIR)/net/sched/sch_fq.ko
EOF

report="$tmpdir/patch-report.txt"
bash "$repo_root/scripts/apply-profile-patches.sh" \
  r4s "$openwrt" "$lock_dir/source-lock.json" "$report"

[ "$(sha256sum "$openwrt/target/linux/generic/hack-6.12/995-bbrv3.patch" | awk '{print $1}')" = "$patch_sha" ]
grep -Fxq 'TARGET_CFLAGS += -std=gnu17' "$openwrt/package/libs/libsepol/Makefile"
grep -qx 'bbrv3_provider=fixture-single' "$report"
grep -qx 'bbrv3_patch_count=1' "$report"
grep -qx 'assertion_BBR_VERSION=3' "$report"

echo "Dynamic BBRv3 patch applicator tests passed."
