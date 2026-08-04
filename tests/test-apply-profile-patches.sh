#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

lock_dir="$tmpdir/source-input"
openwrt="$tmpdir/openwrt"
mkdir -p "$lock_dir/bbr3/6.12" \
  "$openwrt/target/linux/rockchip" \
  "$openwrt/target/linux/generic/backport-6.12" \
  "$openwrt/target/linux/generic/hack-6.12" \
  "$openwrt/feeds/passwall/luci-app-passwall/root/usr/share/passwall" \
  "$openwrt/feeds/kenzo/luci-app-adguardhome/root/etc/init.d" \
  "$openwrt/package/network/services/dnsmasq/files" \
  "$openwrt/package/libs/libsepol" \
  "$openwrt/package/lean/wol" \
  "$openwrt/feeds/small/tcping" \
  "$openwrt/include" \
  "$openwrt/scripts/openwrt-sbom" \
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
python3 - "$lock_dir/source-lock.json" "$patch_sha" "$repo_root" <<'PY'
import json
import pathlib
import sys

output, patch_sha, repo_root_s = sys.argv[1:]
repo_root = pathlib.Path(repo_root_s)
sys.path.insert(0, str(repo_root / "tests"))
from source_lock_fixtures import current_source_overlays

feeds = {}
feed_order = 0
for raw in (repo_root / "feeds.custom.conf").read_text(
    encoding="utf-8"
).splitlines():
    line = raw.split("#", 1)[0].strip()
    if not line:
        continue
    feed_type, name, spec = line.split()
    url, separator, requested_ref = spec.rpartition(";")
    if not separator:
        url, requested_ref = spec, "HEAD"
    feeds[name] = {
        "type": feed_type,
        "url": url,
        "requested_ref": requested_ref,
        "resolved_ref": (
            f"refs/heads/{requested_ref}"
            if requested_ref != "HEAD"
            else "refs/heads/master"
        ),
        "commit": f"{feed_order + 1:x}" * 40,
        "origin": "custom",
        "order": feed_order,
    }
    feed_order += 1
origin_commit = "9" * 40
origin_path = "6.12/bbr3.patch"
lock = {
    "schema": 5,
    "resolved_at": "2026-01-01T00:00:00Z",
    "repository_commit": "1" * 40,
    "openwrt": {"commit": "2" * 40},
    "feeds": feeds,
    "source_overlays": current_source_overlays(repo_root),
    "upstream_artifacts": {
        "haproxy": {
            "policy": "latest-lts",
            "branch": "3.4",
            "version": "3.4.2",
            "url": "https://www.haproxy.org/download/3.4/src/haproxy-3.4.2.tar.gz",
            "sha256": "a" * 64,
        },
        "adguardhome": {
            "policy": "latest-stable",
            "version": "0.107.78",
            "tag": "v0.107.78",
            "tag_commit": "a" * 40,
            "source": {
                "url": "https://codeload.github.com/AdguardTeam/AdGuardHome/tar.gz/refs/tags/v0.107.78?",
                "sha256": "b" * 64,
            },
            "frontend": {
                "url": "https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.78/AdGuardHome_frontend.tar.gz",
                "sha256": "c" * 64,
            },
        },
        "geoip": {
            "policy": "latest-stable",
            "tag": "202601010001",
            "url": "https://github.com/Loyalsoldier/geoip/releases/download/202601010001/geoip.dat",
            "sha256": "d" * 64,
            "checksum_url": "https://github.com/Loyalsoldier/geoip/releases/download/202601010001/geoip.dat.sha256sum",
            "checksum_sha256": "e" * 64,
        },
        "geosite": {
            "policy": "latest-stable",
            "tag": "202601010002",
            "url": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/202601010002/geosite.dat",
            "sha256": "f" * 64,
            "checksum_url": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/202601010002/geosite.dat.sha256sum",
            "checksum_sha256": "0" * 64,
        },
    },
    "profiles": {
        "r4s": {
            "kernel_target": "rockchip",
            "kernel_channel": "stable",
            "kernel_series": "6.12",
            "kernel_version": "6.12.100",
            "kernel_source_sha256": "3" * 64,
            "target_check_regex": "^CONFIG_TARGET_rockchip=y$",
            "image_pattern": "*sysupgrade.img.gz",
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
                    "version": "6.12.100",
                    "source_sha256": "3" * 64,
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
git -C "$openwrt/feeds/passwall" init -q
git -C "$openwrt/feeds/kenzo" init -q
printf 'KERNEL_PATCHVER:=6.12\n' > "$openwrt/target/linux/rockchip/Makefile"
cat > "$openwrt/target/linux/generic/backport-6.12/620-ppp-direct-xmit.patch" <<'PATCH'
--- a/include/linux/ppp_channel.h
+++ b/include/linux/ppp_channel.h
@@ -1 +1,2 @@
 struct ppp_channel {
+	bool direct_xmit;
--- a/drivers/net/ppp/pppoe.c
+++ b/drivers/net/ppp/pppoe.c
@@ -1 +1,2 @@
 context
+	po->chan.direct_xmit = true;
PATCH
cat > "$openwrt/package/libs/libsepol/Makefile" <<'EOF'
include $(TOPDIR)/rules.mk
PKG_NAME:=libsepol
include $(INCLUDE_DIR)/package.mk
include $(INCLUDE_DIR)/host-build.mk
EOF
cat > "$openwrt/package/lean/wol/Makefile" <<'EOF'
include $(TOPDIR)/rules.mk
PKG_NAME:=wol
include $(INCLUDE_DIR)/package.mk
EOF
cat > "$openwrt/package/network/services/dnsmasq/files/dnsmasq.init" <<'EOF'
append_addnhosts() {
	ismounted "$1" || append EXTRA_MOUNT "$1"
	xappend "--addn-hosts=$1"
}

append_bogusnxdomain() {
	xappend "--bogus-nxdomain=$1"
}

dnsmasq_start()
{
	if [ "$ignore_hosts_dir" = "1" ]; then
		xappend "--addn-hosts=$HOSTFILE"
		append EXTRA_MOUNT "$HOSTFILE"
	else
		xappend "--addn-hosts=$HOSTFILE_DIR"
		append EXTRA_MOUNT "$HOSTFILE_DIR"
	fi
	config_list_foreach "$cfg" "addnhosts" append_addnhosts
	config_list_foreach "$cfg" "bogusnxdomain" append_bogusnxdomain
	append_parm "$cfg" "leasefile" "--dhcp-leasefile" "/tmp/dhcp.leases"
	append_parm "$cfg" "serversfile" "--servers-file"
}
EOF
cat > "$openwrt/feeds/passwall/luci-app-passwall/root/usr/share/passwall/app.sh" <<'EOF'
run_ipt2socks() {
	case "$proto" in
	*)
		flag="${flag}_TCP_UDP"
	;;
	esac
	_extra_param="${_extra_param} -o 60 -n 65535 -v"
	ln_run "$(first_type ipt2socks)" "ipt2socks_${flag}" $log_file -l $local_port -b 0.0.0.0 -s $socks_address -p $socks_port ${_extra_param}
}

run_singbox() {
	:
}

start_dns() {
	if [ "$RUN_NEW_DNSMASQ" = "0" ]; then
		lua $APP_PATH/helper_dnsmasq.lua add_rule \
			-USE_DIRECT_LIST "${USE_DIRECT_LIST}" -USE_PROXY_LIST "${USE_PROXY_LIST}" -USE_BLOCK_LIST "${USE_BLOCK_LIST}" -USE_GFW_LIST "${USE_GFW_LIST}" -CHN_LIST "${CHN_LIST}" \
			-TCP_NODE ${TCP_NODE} -DEFAULT_PROXY_MODE ${TCP_PROXY_MODE} -NO_PROXY_IPV6 ${DNSMASQ_FILTER_PROXY_IPV6:-0} -NFTFLAG ${nftflag:-0} \
			-NO_LOGIC_LOG ${NO_LOGIC_LOG:-0}
		uci -q add_list dhcp.@dnsmasq[0].addnmount=${GLOBAL_DNSMASQ_CONF_PATH}
		uci -q commit dhcp
		lua $APP_PATH/helper_dnsmasq.lua logic_restart -LOG 1
	else
		:
	fi
}

stop() {
	unset SS_SYSTEM_DNS_RESOLVER_FORCE_BUILTIN
	stop_crontab
	source $APP_PATH/helper_smartdns.sh del
	rm -rf $GLOBAL_DNSMASQ_CONF
	rm -rf $GLOBAL_DNSMASQ_CONF_PATH
	[ "1" = "1" ] && {
		bak_dnsmasq_dns_redirect=$(config_t_get global dnsmasq_dns_redirect)
		[ -n "${bak_dnsmasq_dns_redirect}" ] && {
			uci -q commit ${CONFIG}
		}
		if [ -z "${ACL_default_dns_port}" ] || [ -n "${bak_dnsmasq_dns_redirect}" ]; then
			uci -q del_list dhcp.@dnsmasq[0].addnmount="${GLOBAL_DNSMASQ_CONF_PATH}"
			uci -q commit dhcp
			lua $APP_PATH/helper_dnsmasq.lua restart -LOG 0
		fi
		[ -n "${bak_bridge_nf_ipt}" ] && sysctl -w net.bridge.bridge-nf-call-iptables=${bak_bridge_nf_ipt} >/dev/null 2>&1
	}
}
EOF
git -C "$openwrt/feeds/passwall" add luci-app-passwall/root/usr/share/passwall/app.sh
git -C "$openwrt/feeds/passwall" \
  -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture PassWall source'
cat > "$openwrt/feeds/kenzo/luci-app-adguardhome/root/etc/init.d/AdGuardHome" <<'EOF'
set_iptable()
{
	local ipv6_server="$1"
	local tcp_server="$2"

	[ "$ipv6_server" = "0" ] && return

	IPS="$(ip -6 addr show | grep inet6 | grep -v 'fe80::' | grep -v '::1' | grep 'Global' | awk '{print $2}' | cut -d'/' -f1)"
	for IP in $IPS; do
		[ -z "$IP" ] && continue
		ip6tables -t nat -I PREROUTING -p udp -d "$IP" --dport 53 -j REDIRECT --to-ports "$AdGuardHome_PORT" >/dev/null 2>&1
		[ "$tcp_server" = "1" ] && ip6tables -t nat -I PREROUTING -p tcp -d "$IP" --dport 53 -j REDIRECT --to-ports "$AdGuardHome_PORT" >/dev/null 2>&1
	done
}

clear_iptable()
{
	local OLD_PORT="$1"
	local ipv6_server="$2"

	[ "$ipv6_server" = "0" ] && return
	echo "warn ip6tables nat mod is needed"
	IPS="$(ip -6 addr show | grep inet6 | grep -v 'fe80::' | grep -v '::1' | grep 'Global' | awk '{print $2}' | cut -d'/' -f1)"
	for IP in $IPS; do
		[ -z "$IP" ] && continue
		ip6tables -t nat -D PREROUTING -p udp -d "$IP" --dport 53 -j REDIRECT --to-ports "$OLD_PORT" >/dev/null 2>&1
		ip6tables -t nat -D PREROUTING -p tcp -d "$IP" --dport 53 -j REDIRECT --to-ports "$OLD_PORT" >/dev/null 2>&1
	done
}

_do_redirect()
{
	local section="$CONFIGURATION"
	ipv6_server=1
	tcp_server=0
	local enabled="$1"

	if [ "$enabled" = "1" ]; then
		:
	fi
}
EOF
git -C "$openwrt/feeds/kenzo" add \
  luci-app-adguardhome/root/etc/init.d/AdGuardHome
git -C "$openwrt/feeds/kenzo" \
  -c user.name=fixture -c user.email=fixture@example.invalid \
  commit -qm 'fixture Kenzo source'
cat > "$openwrt/feeds/small/tcping/Makefile" <<'EOF'
include $(TOPDIR)/rules.mk
PKG_NAME:=tcping
include $(INCLUDE_DIR)/package.mk

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) CC="$(TARGET_CC)" CFLAGS="$(TARGET_CFLAGS) -Wall" LDFLAGS="$(TARGET_LDFLAGS)"
endef
EOF
cat > "$openwrt/include/image.mk" <<'EOF'
define Image/Manifest
	@echo fixture-manifest
endef
EOF
python3 - "$repo_root/profiles/common/source-compatibility.json" "$openwrt" <<'PY'
import json
import pathlib
import sys

policy = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
root = pathlib.Path(sys.argv[2])
rule = next(item for item in policy["rules"] if item["id"] == "image-cyclonedx-sbom")
for required_file in rule["required_files"]:
    path = root / required_file["path"]
    path.write_text("\n".join(required_file["contains"]) + "\n", encoding="utf-8")
    path.chmod(0o755 if required_file["executable"] else 0o644)
PY
cat > "$openwrt/package/kernel/linux/modules/netsupport.mk" <<'EOF'
define KernelPackage/tcp-bbr
FILES:=$(LINUX_DIR)/net/ipv4/tcp_bbr.ko
AUTOLOAD:=$(call AutoProbe,tcp_bbr)
define KernelPackage/sched
FILES:=$(LINUX_DIR)/net/sched/sch_fq.ko
EOF
cat > "$openwrt/package/kernel/linux/modules/other.mk" <<'EOF'
define KernelPackage/zram/config
  if PACKAGE_kmod-zram
    if LINUX_6_12
        config KERNEL_ZRAM_BACKEND_LZO
                bool "lzo and lzo-rle compression support"

        config KERNEL_ZRAM_BACKEND_LZ4
                bool "lz4 compression support"

    endif
    choice
      prompt "ZRAM Default compressor"
    endchoice
  endif
endef
EOF

report="$tmpdir/patch-report.txt"
bash "$repo_root/scripts/apply-profile-patches.sh" \
  r4s "$openwrt" "$lock_dir/source-lock.json" "$report"

[ "$(sha256sum "$openwrt/target/linux/generic/hack-6.12/995-bbrv3.patch" | awk '{print $1}')" = "$patch_sha" ]
module_version_patch="$openwrt/target/linux/generic/hack-6.12/996-bbrv3-module-version.patch"
[ -f "$module_version_patch" ]
[ "$(sha256sum "$module_version_patch" | awk '{print $1}')" = "$(
  sha256sum "$repo_root/patchsets/common/kernel/bbr3-module-version.patch" | awk '{print $1}'
)" ]
ppp_sg_patch="$openwrt/target/linux/generic/backport-6.12/625-v7.0-ppp-enable-TX-scatter-gather.patch"
[ -f "$ppp_sg_patch" ]
[ "$(sha256sum "$ppp_sg_patch" | awk '{print $1}')" = "$(
  sha256sum "$repo_root/patchsets/common/kernel/ppp-tx-scatter-gather-6.12.patch" | awk '{print $1}'
)" ]
grep -Fxq 'TARGET_CFLAGS += -std=gnu17' "$openwrt/package/libs/libsepol/Makefile"
if grep -Eq '^PKG_(VERSION|HASH):=' "$openwrt/package/libs/libsepol/Makefile"; then
  echo "libsepol compatibility fixture unexpectedly depends on version/hash fields" >&2
  exit 1
fi
grep -Fxq 'TARGET_CFLAGS += -std=gnu17' "$openwrt/package/lean/wol/Makefile"
if grep -Eq '^PKG_(VERSION|HASH):=' "$openwrt/package/lean/wol/Makefile"; then
  echo "wol compatibility fixture unexpectedly depends on version/hash fields" >&2
  exit 1
fi
grep -Fqx 'append_addnmount() {' \
  "$openwrt/package/network/services/dnsmasq/files/dnsmasq.init"
grep -Fqx $'\t[ -e "$1" ] || return 0' \
  "$openwrt/package/network/services/dnsmasq/files/dnsmasq.init"
grep -Fqx $'\tconfig_list_foreach "$cfg" "addnmount" append_addnmount' \
  "$openwrt/package/network/services/dnsmasq/files/dnsmasq.init"
grep -Eq '^applied_common=dnsmasq-addnmount-jail\.patch sha256:[0-9a-f]{64}$' \
  "$report"
grep -Fqx $'\tln_run "$(first_type ipt2socks)" "ipt2socks_${flag}" $log_file -l $local_port -b 0.0.0.0 -B :: -j 2 -s $socks_address -p $socks_port ${_extra_param}' \
  "$openwrt/feeds/passwall/luci-app-passwall/root/usr/share/passwall/app.sh"
grep -Eq '^applied_feed_passwall=ipt2socks-dualstack\.patch sha256:[0-9a-f]{64}$' \
  "$report"
grep -Fqx $'\t\tuci -q del_list dhcp.@dnsmasq[0].addnmount="${GLOBAL_DNSMASQ_CONF_PATH}"' \
  "$openwrt/feeds/passwall/luci-app-passwall/root/usr/share/passwall/app.sh"
grep -Fqx $'\t\t[ ! -e "${GLOBAL_DNSMASQ_CONF_PATH}" ] || \\' \
  "$openwrt/feeds/passwall/luci-app-passwall/root/usr/share/passwall/app.sh"
[ "$(grep -Fc 'del_list dhcp.@dnsmasq[0].addnmount=' \
  "$openwrt/feeds/passwall/luci-app-passwall/root/usr/share/passwall/app.sh")" -eq 2 ]
grep -Eq '^applied_feed_passwall=dnsmasq-addnmount-lifecycle\.patch sha256:[0-9a-f]{64}$' \
  "$report"
grep -Fqx $'\ttcp_server=1' \
  "$openwrt/feeds/kenzo/luci-app-adguardhome/root/etc/init.d/AdGuardHome"
[ "$(grep -Fc 'ip -6 addr show scope global' \
  "$openwrt/feeds/kenzo/luci-app-adguardhome/root/etc/init.d/AdGuardHome")" -eq 2 ]
grep -Eq '^applied_feed_kenzo=adguardhome-dns-redirect-dualstack\.patch sha256:[0-9a-f]{64}$' \
  "$report"
grep -Fxq $'\t$(MAKE) -C $(PKG_BUILD_DIR) $(TARGET_CONFIGURE_OPTS) CC="$(TARGET_CC)" CFLAGS="$(TARGET_CFLAGS) -Wall" LDFLAGS="$(TARGET_LDFLAGS)"' \
  "$openwrt/feeds/small/tcping/Makefile"
if grep -Eq '^PKG_(VERSION|HASH):=' "$openwrt/feeds/small/tcping/Makefile"; then
  echo "tcping compatibility fixture unexpectedly depends on version/hash fields" >&2
  exit 1
fi
grep -qx 'source_compatibility_libsepol_gnu17_status=inserted' "$report"
grep -qx 'source_compatibility_libsepol_gnu17_detail=gnu17' "$report"
grep -qx 'source_compatibility_wol_gnu17_status=inserted' "$report"
grep -qx 'source_compatibility_wol_gnu17_detail=gnu17' "$report"
grep -qx 'source_compatibility_tcping_target_make_environment_status=inserted' "$report"
grep -qx 'source_compatibility_tcping_target_make_environment_detail=$(TARGET_CONFIGURE_OPTS)' "$report"
grep -qx 'source_compatibility_zram_selected_kernel_backend_status=upstream' "$report"
grep -qx 'source_compatibility_zram_selected_kernel_backend_detail=KERNEL_ZRAM_BACKEND_LZ4@LINUX_6_12' "$report"
grep -qx 'source_compatibility_image_cyclonedx_sbom_status=inserted' "$report"
grep -qx 'source_compatibility_image_cyclonedx_sbom_detail=Image/Manifest' "$report"
python3 - "$repo_root/profiles/common/source-compatibility.json" \
  "$openwrt/include/image.mk" <<'PY'
import json
import pathlib
import sys

policy = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
rule = next(item for item in policy["rules"] if item["id"] == "image-cyclonedx-sbom")
text = pathlib.Path(sys.argv[2]).read_text(encoding="utf-8")
assert text.count("\n".join(rule["block"])) == 1
assert all(marker in text for marker in rule["accepted_semantics"][0])
PY
grep -qx 'bbrv3_provider=fixture-single' "$report"
grep -qx 'bbrv3_patch_count=1' "$report"
grep -qx 'patch-report-v3' "$report"
grep -qx 'selected_kernel_ppp_tx_scatter_gather_status=compatibility-installed' "$report"
grep -qx 'selected_kernel_ppp_tx_scatter_gather_semantic_rule=common.ppp-tx-scatter-gather' "$report"
grep -qx 'selected_kernel_ppp_tx_scatter_gather_destination=target/linux/generic/backport-6.12/625-v7.0-ppp-enable-TX-scatter-gather.patch' "$report"
grep -Eq '^selected_kernel_ppp_tx_scatter_gather_patch_sha256=[0-9a-f]{64}$' "$report"
grep -qx 'bbrv3_module_version_status=compatibility-installed' "$report"
grep -qx 'bbrv3_module_version_destination=target/linux/generic/hack-6.12/996-bbrv3-module-version.patch' "$report"
grep -qx 'assertion_BBR_VERSION=3' "$report"
grep -qx 'assertion_module_version_metadata=retained' "$report"

# The same semantic rule extends whatever selected kernel series the lock
# provides; neither the policy nor the implementation enumerates 6.18.
zram_618_report="$tmpdir/source-compatibility-zram-618.txt"
python3 "$repo_root/scripts/apply-source-compatibility.py" \
  "$repo_root/profiles/common/source-compatibility.json" "$openwrt" \
  "$zram_618_report" 6.18
grep -Fqx '    if LINUX_6_12 || LINUX_6_18' \
  "$openwrt/package/kernel/linux/modules/other.mk"
grep -qx 'source_compatibility_zram_selected_kernel_backend_status=inserted' \
  "$zram_618_report"
grep -qx 'source_compatibility_zram_selected_kernel_backend_detail=KERNEL_ZRAM_BACKEND_LZ4@LINUX_6_18' \
  "$zram_618_report"

zram_618_second_report="$tmpdir/source-compatibility-zram-618-second.txt"
python3 "$repo_root/scripts/apply-source-compatibility.py" \
  "$repo_root/profiles/common/source-compatibility.json" "$openwrt" \
  "$zram_618_second_report" 6.18
grep -qx 'source_compatibility_zram_selected_kernel_backend_status=upstream' \
  "$zram_618_second_report"

# A changed conditional must not be mistaken for an unconditional upstream
# implementation; ambiguous semantics remain a hard failure.
cp "$openwrt/package/kernel/linux/modules/other.mk" "$tmpdir/other.mk.valid"
sed -i 's/if LINUX_6_12 || LINUX_6_18/if LINUX_6_12 \&\& EXPERIMENTAL_ZRAM/' \
  "$openwrt/package/kernel/linux/modules/other.mk"
if python3 "$repo_root/scripts/apply-source-compatibility.py" \
  "$repo_root/profiles/common/source-compatibility.json" "$openwrt" \
  "$tmpdir/source-compatibility-zram-drift.txt" 6.18 \
  >"$tmpdir/source-compatibility-zram-drift.out" 2>&1; then
  echo "zram compatibility accepted a non-canonical kernel guard" >&2
  exit 1
fi
grep -Fq 'non-canonical kernel-series guard' \
  "$tmpdir/source-compatibility-zram-drift.out"
cp "$tmpdir/other.mk.valid" "$openwrt/package/kernel/linux/modules/other.mk"

second_report="$tmpdir/patch-report-second.txt"
bash "$repo_root/scripts/apply-profile-patches.sh" \
  r4s "$openwrt" "$lock_dir/source-lock.json" "$second_report"
[ "$(grep -Fxc 'TARGET_CFLAGS += -std=gnu17' "$openwrt/package/libs/libsepol/Makefile")" -eq 1 ]
[ "$(grep -Fxc 'TARGET_CFLAGS += -std=gnu17' "$openwrt/package/lean/wol/Makefile")" -eq 1 ]
[ "$(grep -Fo '$(TARGET_CONFIGURE_OPTS)' "$openwrt/feeds/small/tcping/Makefile" | wc -l)" -eq 1 ]
grep -qx 'source_compatibility_libsepol_gnu17_status=upstream' "$second_report"
grep -qx 'source_compatibility_wol_gnu17_status=upstream' "$second_report"
grep -qx 'source_compatibility_tcping_target_make_environment_status=upstream' "$second_report"
grep -qx 'source_compatibility_zram_selected_kernel_backend_status=upstream' "$second_report"
grep -qx 'source_compatibility_image_cyclonedx_sbom_status=upstream' "$second_report"
grep -Eq '^present_common=dnsmasq-addnmount-jail\.patch sha256:[0-9a-f]{64}$' \
  "$second_report"
grep -Eq '^present_feed_passwall=ipt2socks-dualstack\.patch sha256:[0-9a-f]{64}$' \
  "$second_report"
grep -Eq '^present_feed_passwall=dnsmasq-addnmount-lifecycle\.patch sha256:[0-9a-f]{64}$' \
  "$second_report"
grep -Eq '^present_feed_kenzo=adguardhome-dns-redirect-dualstack\.patch sha256:[0-9a-f]{64}$' \
  "$second_report"
grep -qx 'selected_kernel_ppp_tx_scatter_gather_status=compatibility-present' "$second_report"
grep -qx 'bbrv3_module_version_status=compatibility-present' "$second_report"

# Prove that a future provider retaining the field itself does not require a
# second profile-specific rule or leave the repository companion installed.
rm "$openwrt/target/linux/generic/hack-6.12/995-bbrv3.patch" \
  "$openwrt/target/linux/generic/hack-6.12/996-bbrv3-module-version.patch"
sed -i \
  's/MODULE_VERSION(__stringify(BBR_VERSION));/MODULE_INFO(version, __stringify(BBR_VERSION));/' \
  "$lock_dir/bbr3/6.12/0001-bbrv3.patch"
python3 - "$lock_dir/source-lock.json" \
  "$lock_dir/bbr3/6.12/0001-bbrv3.patch" <<'PY'
import hashlib
import json
import sys

lock_path, patch_path = sys.argv[1:]
with open(lock_path, encoding="utf-8") as handle:
    lock = json.load(handle)
with open(patch_path, "rb") as handle:
    digest = hashlib.sha256(handle.read()).hexdigest()
lock["kernel_features"]["bbr3"]["ports"]["6.12"]["patches"][0]["sha256"] = digest
with open(lock_path, "w", encoding="utf-8") as handle:
    json.dump(lock, handle, indent=2, sort_keys=True)
    handle.write("\n")
PY
upstream_module_report="$tmpdir/patch-report-upstream-module.txt"
bash "$repo_root/scripts/apply-profile-patches.sh" \
  r4s "$openwrt" "$lock_dir/source-lock.json" "$upstream_module_report"
[ ! -e "$openwrt/target/linux/generic/hack-6.12/996-bbrv3-module-version.patch" ]
grep -qx 'bbrv3_module_version_status=upstream' "$upstream_module_report"

cat > "$openwrt/feeds/small/tcping/Makefile" <<'EOF'
include $(TOPDIR)/rules.mk
PKG_NAME:=tcping
include $(INCLUDE_DIR)/package.mk

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) $(MAKE_FLAGS)
endef
EOF
third_report="$tmpdir/source-compatibility-upstream.txt"
python3 "$repo_root/scripts/apply-source-compatibility.py" \
  "$repo_root/profiles/common/source-compatibility.json" "$openwrt" "$third_report" 6.12
grep -qx 'source_compatibility_tcping_target_make_environment_status=upstream' "$third_report"
grep -qx 'source_compatibility_tcping_target_make_environment_detail=$(MAKE_FLAGS)' "$third_report"

# A future Lean-native generator is an equivalent complete semantic set and
# does not depend on the isolated overlay files.
python3 - "$repo_root/profiles/common/source-compatibility.json" \
  "$openwrt/include/image.mk" <<'PY'
import json
import pathlib
import sys

policy = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
rule = next(item for item in policy["rules"] if item["id"] == "image-cyclonedx-sbom")
block = "\n".join(rule["block"])
isolated_generator = "$(TOPDIR)/" + rule["accepted_semantics"][0][1]
native_generator = rule["accepted_semantics"][1][1]
native_block = block.replace(isolated_generator, native_generator)
assert native_block != block
pathlib.Path(sys.argv[2]).write_text(
    "define Image/Manifest\n\t@echo fixture-manifest\n\n"
    + native_block
    + "\nendef\n",
    encoding="utf-8",
)
PY
rm "$openwrt/scripts/openwrt-sbom/package-metadata.pl" \
  "$openwrt/scripts/openwrt-sbom/metadata.pm"
native_report="$tmpdir/source-compatibility-native.txt"
python3 "$repo_root/scripts/apply-source-compatibility.py" \
  "$repo_root/profiles/common/source-compatibility.json" "$openwrt" "$native_report" 6.12
grep -qx 'source_compatibility_image_cyclonedx_sbom_status=upstream' "$native_report"

cat > "$openwrt/feeds/small/tcping/Makefile" <<'EOF'
include $(TOPDIR)/rules.mk
PKG_NAME:=tcping
include $(INCLUDE_DIR)/package.mk

define Build/Compile
	$(MAKE) -C $(PKG_BUILD_DIR) CC="$(TARGET_CC)"
endef
EOF
if python3 "$repo_root/scripts/apply-source-compatibility.py" \
  "$repo_root/profiles/common/source-compatibility.json" "$openwrt" \
  "$tmpdir/source-compatibility-drift.txt" 6.12 \
  >"$tmpdir/source-compatibility-drift.out" 2>&1; then
  echo "tcping compatibility unexpectedly accepted a changed custom recipe" >&2
  exit 1
fi
grep -Fq 'recipe no longer contains required fragments' "$tmpdir/source-compatibility-drift.out"

# A partially copied upstream SBOM block is ambiguous and must fail instead of
# being duplicated or accepted. The fixture derives its marker from the policy.
cat > "$openwrt/feeds/small/tcping/Makefile" <<'EOF'
include $(TOPDIR)/rules.mk
PKG_NAME:=tcping
include $(INCLUDE_DIR)/package.mk
EOF
python3 - "$repo_root/profiles/common/source-compatibility.json" \
  "$openwrt/include/image.mk" <<'PY'
import json
import pathlib
import sys

policy = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
rule = next(item for item in policy["rules"] if item["id"] == "image-cyclonedx-sbom")
path = pathlib.Path(sys.argv[2])
path.write_text(
    "define Image/Manifest\n\t@echo fixture-manifest\n\n"
    + rule["block"][0]
    + "\n"
    + rule["block"][-1]
    + "\nendef\n",
    encoding="utf-8",
)
PY
if python3 "$repo_root/scripts/apply-source-compatibility.py" \
  "$repo_root/profiles/common/source-compatibility.json" "$openwrt" \
  "$tmpdir/source-compatibility-partial.txt" 6.12 \
  >"$tmpdir/source-compatibility-partial.out" 2>&1; then
  echo "image SBOM compatibility unexpectedly accepted a partial semantic block" >&2
  exit 1
fi
grep -Fq 'has a partial semantic block' "$tmpdir/source-compatibility-partial.out"

# With no native block, insertion must prove that both isolated generator
# files exist; it may not leave a Make rule pointing at a missing tool.
cat > "$openwrt/include/image.mk" <<'EOF'
define Image/Manifest
	@echo fixture-manifest
endef
EOF
if python3 "$repo_root/scripts/apply-source-compatibility.py" \
  "$repo_root/profiles/common/source-compatibility.json" "$openwrt" \
  "$tmpdir/source-compatibility-missing-generator.txt" 6.12 \
  >"$tmpdir/source-compatibility-missing-generator.out" 2>&1; then
  echo "image SBOM compatibility accepted a missing generator" >&2
  exit 1
fi
grep -Fq 'required file is missing' \
  "$tmpdir/source-compatibility-missing-generator.out"

echo "Dynamic BBRv3 patch applicator tests passed."
