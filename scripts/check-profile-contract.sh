#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  check-profile-contract.sh <profile> [openwrt-root] [source-lock.json] [report]

With only a profile, validates repository-owned static contracts. When an
OpenWrt tree is supplied it also validates selected providers, final config,
stable kernel series and the optional source lock.
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${1:-}"
openwrt_root="${2:-}"
source_lock="${3:-}"
report="${4:-${CONTRACT_REPORT:-}}"

[ -n "$profile" ] || { usage; exit 2; }

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

config="$tmpdir/config.seed"
required="$tmpdir/required.txt"
forbidden="$tmpdir/forbidden.txt"
env_file="$tmpdir/profile.env"
files="$tmpdir/files"

bash "$repo_root/scripts/render-profile.sh" config "$profile" "$config"
bash "$repo_root/scripts/render-profile.sh" required "$profile" "$required"
bash "$repo_root/scripts/render-profile.sh" forbidden "$profile" "$forbidden"
bash "$repo_root/scripts/render-profile.sh" env "$profile" "$env_file"
bash "$repo_root/scripts/render-profile.sh" files "$profile" "$files"

if [ -n "$openwrt_root" ]; then
  [ -d "$openwrt_root" ] || {
    echo "::error::OpenWrt root does not exist: $openwrt_root" >&2
    exit 2
  }
  openwrt_root="$(cd "$openwrt_root" && pwd -P)"
fi
if [ -n "$source_lock" ] && [ ! -r "$source_lock" ]; then
  echo "::error::Source lock does not exist: $source_lock" >&2
  exit 2
fi

python3 - "$repo_root" "$profile" "$config" "$required" "$forbidden" \
  "$env_file" "$files" "$openwrt_root" "$source_lock" "$report" <<'PY'
import json
import pathlib
import re
import sys

(
    repo_root_s,
    profile,
    config_s,
    required_s,
    forbidden_s,
    env_s,
    files_s,
    openwrt_s,
    source_lock_s,
    report_s,
) = sys.argv[1:]

repo_root = pathlib.Path(repo_root_s)
sys.path.insert(0, str(repo_root / "scripts"))
from optimization_contract import (  # noqa: E402
    OptimizationContractError,
    check_contract,
    load_contract,
)

config_path = pathlib.Path(config_s)
required_path = pathlib.Path(required_s)
forbidden_path = pathlib.Path(forbidden_s)
env_path = pathlib.Path(env_s)
files_root = pathlib.Path(files_s)
problems: list[str] = []
checks: list[str] = []


def clean_lines(path: pathlib.Path) -> list[str]:
    result = []
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.split("#", 1)[0].strip()
        if line:
            result.append(line)
    return result


def parse_config(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for raw in path.read_text(encoding="utf-8").splitlines():
        selected = re.fullmatch(r"(CONFIG_[^=]+)=(.*)", raw)
        disabled = re.fullmatch(r"# (CONFIG_[^ ]+) is not set", raw)
        if selected:
            symbol, value = selected.groups()
            if symbol in values:
                problems.append(f"duplicate rendered config symbol: {symbol}")
            values[symbol] = value
        elif disabled:
            symbol = disabled.group(1)
            if symbol in values:
                problems.append(f"duplicate rendered config symbol: {symbol}")
            values[symbol] = "n"
    return values


def require_value(values: dict[str, str], symbol: str, expected: str) -> None:
    actual = values.get(symbol)
    if actual != expected:
        problems.append(f"{symbol}: expected {expected!r}, got {actual!r}")
    else:
        checks.append(f"config {symbol}={expected}")


config = parse_config(config_path)
required = clean_lines(required_path)
forbidden = clean_lines(forbidden_path)
env = {}
for line in clean_lines(env_path):
    key, sep, value = line.partition("=")
    if not sep or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
        problems.append(f"invalid rendered env line: {line}")
    elif key in env:
        problems.append(f"duplicate rendered env key: {key}")
    else:
        env[key] = value

if env.get("PROFILE_NAME") != profile:
    problems.append(f"PROFILE_NAME does not equal {profile}")
if env.get("REPO_REF") != "master":
    problems.append("profiles must continue tracking Lean master")
if env.get("FEEDS_UPDATE_MODE") != "locked":
    problems.append("feeds must be consumed from source-lock")

required_packages = {
    line.removeprefix("package:")
    for line in required
    if line.startswith("package:")
}
required_configs = {
    line.removeprefix("config:")
    for line in required
    if line.startswith("config:")
}
exact_forbidden = {
    line.removeprefix("exact:")
    for line in forbidden
    if line.startswith("exact:")
}
regex_forbidden = [
    line.removeprefix("regex:")
    for line in forbidden
    if line.startswith("regex:")
]
if any(line.startswith("prune:") for line in forbidden):
    problems.append("ordinary profile forbidden rules must not contain prune directives")

for package in sorted(required_packages):
    if package in exact_forbidden:
        problems.append(f"required package is also forbidden: {package}")
    for pattern in regex_forbidden:
        try:
            if re.search(pattern, package):
                problems.append(
                    f"required package {package} matches forbidden regex {pattern}"
                )
        except re.error as exc:
            problems.append(f"invalid forbidden regex {pattern!r}: {exc}")

for symbol in sorted(required_configs):
    if config.get(symbol) != "y":
        problems.append(f"required config is not selected in seed: {symbol}")

for symbol in (
    "CONFIG_PACKAGE_firewall",
    "CONFIG_PACKAGE_iptables",
    "CONFIG_PACKAGE_dnsmasq-full",
    "CONFIG_PACKAGE_kmod-tcp-bbr",
    "CONFIG_PACKAGE_kmod-sched",
    "CONFIG_PACKAGE_luci-app-turboacc",
    "CONFIG_PACKAGE_TURBOACC_INCLUDE_FLOW_OFFLOADING",
    "CONFIG_PACKAGE_TURBOACC_INCLUDE_BBR_CCA",
):
    require_value(config, symbol, "y")
for symbol in (
    "CONFIG_PACKAGE_firewall4",
    "CONFIG_PACKAGE_nftables",
    "CONFIG_PACKAGE_iptables-nft",
    "CONFIG_PACKAGE_ip6tables-nft",
    "CONFIG_PACKAGE_default-settings",
    "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Mihomo",
    "CONFIG_TESTING_KERNEL",
    "CONFIG_USE_APK",
    "CONFIG_USE_GC_SECTIONS",
    "CONFIG_USE_LTO",
    "CONFIG_USE_MOLD",
):
    require_value(config, symbol, "n")

if "default-settings" not in exact_forbidden:
    problems.append("default-settings must be explicitly forbidden")

for relative in (
    "etc/uci-defaults/90-common-system",
    "etc/uci-defaults/90-common-network",
):
    if not (files_root / relative).is_file():
        problems.append(f"missing common rootfs contract: {relative}")

network_defaults = files_root / "etc/uci-defaults/90-common-network"
if network_defaults.is_file():
    content = network_defaults.read_text(encoding="utf-8")
    for expected in (
        "set dhcp.lan.start='32'",
        "set dhcp.lan.limit='232'",
        "set dhcp.lan.ra='server'",
        "set dhcp.lan.dhcpv6='relay'",
        "set dhcp.lan.ndp='relay'",
        "set dhcp.wan.ra='relay'",
        "set dhcp.wan.dhcpv6='relay'",
        "set dhcp.wan.ndp='relay'",
        "set dhcp.wan.master='1'",
    ):
        if expected not in content:
            problems.append(f"common network defaults miss {expected}")
    if "set dhcp.lan.dhcpv6='server'" in content:
        problems.append("common network defaults still enable LAN DHCPv6 server")

bbr_policy_path = repo_root / "patchsets/common/kernel/bbr3-sources.json"
try:
    bbr_policy = json.loads(bbr_policy_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError) as exc:
    problems.append(f"invalid BBRv3 source policy: {exc}")
else:
    algorithm = bbr_policy.get("algorithm", {})
    providers = bbr_policy.get("providers", [])
    if bbr_policy.get("schema") != 1:
        problems.append("BBRv3 source policy schema must be 1")
    if algorithm.get("ref") != "v3" or algorithm.get("module_version") != 3 or algorithm.get("runtime_name") != "bbr":
        problems.append("BBRv3 algorithm policy identity is invalid")
    if [provider.get("name") for provider in providers if isinstance(provider, dict)] != [
        "cachyos-single",
        "sbwml-series",
    ]:
        problems.append("BBRv3 provider order differs from the architecture contract")
    def nested_keys(value):
        if isinstance(value, dict):
            for key, child in value.items():
                yield key
                yield from nested_keys(child)
        elif isinstance(value, list):
            for child in value:
                yield from nested_keys(child)

    if {"commit", "sha256"}.intersection(nested_keys(bbr_policy)):
        problems.append("BBRv3 source policy contains a per-run commit/hash lock")

if profile == "r4s":
    require_value(config, "CONFIG_TARGET_rockchip_armv8_DEVICE_friendlyarm_nanopi-r4s", "y")
    require_value(
        config,
        "CONFIG_TARGET_OPTIMIZATION",
        '"-O2 -pipe -march=armv8-a+crc+crypto -mtune=cortex-a72.cortex-a53"',
    )
    require_value(config, "CONFIG_KERNEL_ZRAM_BACKEND_LZ4", "y")
    require_value(config, "CONFIG_KERNEL_ZRAM_DEF_COMP_LZ4", "y")
    require_value(config, "CONFIG_COREMARK_NUMBER_OF_THREADS", "6")
    require_value(config, "CONFIG_PACKAGE_irqbalance", "n")
    require_value(config, "CONFIG_PACKAGE_kmod-usb-net", "n")
    for package in ("irqbalance", "kmod-usb-net", "kmod-usb-net-rtl8152"):
        if package not in exact_forbidden:
            problems.append(f"R4S must forbid {package}")
elif profile == "x86-n5105-pve":
    require_value(config, "CONFIG_TARGET_x86_64_DEVICE_generic", "y")
    require_value(
        config,
        "CONFIG_TARGET_OPTIMIZATION",
        '"-O2 -pipe -march=x86-64-v2 -mtune=tremont"',
    )
    require_value(config, "CONFIG_GRUB_EFI_IMAGES", "y")
    require_value(config, "CONFIG_GRUB_IMAGES", "n")
    require_value(config, "CONFIG_COREMARK_NUMBER_OF_THREADS", "4")
    require_value(config, "CONFIG_PACKAGE_kmod-igc", "y")
    require_value(config, "CONFIG_PACKAGE_irqbalance", "y")
    require_value(config, "CONFIG_PACKAGE_autocore-x86", "n")
    require_value(config, "CONFIG_PACKAGE_kmod-zram", "n")
    if "CONFIG_VIRTIO_SUPPORT" in config:
        problems.append(
            "CONFIG_VIRTIO_SUPPORT is an invisible target symbol and must not be seeded"
        )
    for package in ("autocore-x86", "zram-swap", "kmod-zram"):
        if package not in exact_forbidden:
            problems.append(f"N5105 PVE must forbid {package}")
else:
    problems.append(f"unsupported maintained profile: {profile}")

openwrt = pathlib.Path(openwrt_s) if openwrt_s else None
lock = None
if source_lock_s:
    try:
        lock = json.loads(pathlib.Path(source_lock_s).read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        problems.append(f"invalid source lock: {exc}")

kernel_series = None
if openwrt:
    providers = repo_root / "profiles/common/providers.tsv"
    for raw in providers.read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        component, package, expected, conflicts = raw.split("\t")
        if not (openwrt / expected).is_file():
            problems.append(f"selected {component} provider is missing: {expected}")
        if conflicts != "-":
            for conflict in conflicts.split(","):
                if (openwrt / conflict).exists():
                    problems.append(
                        f"conflicting {component} provider still exists: {conflict}"
                    )

    final_config_path = openwrt / ".config"
    if final_config_path.is_file():
        final = parse_config(final_config_path)
        expected_target = env.get("TARGET_CHECK_REGEX", "")
        if expected_target and not any(
            re.search(expected_target, f"{key}={value}")
            for key, value in final.items()
            if value == "y"
        ):
            problems.append("final OpenWrt target does not match profile contract")
        for symbol in (
            "CONFIG_PACKAGE_firewall",
            "CONFIG_PACKAGE_iptables",
            "CONFIG_PACKAGE_kmod-tcp-bbr",
            "CONFIG_PACKAGE_kmod-sched",
        ):
            if final.get(symbol) != "y":
                problems.append(f"final OpenWrt config lost {symbol}")
        for symbol in (
            "CONFIG_PACKAGE_firewall4",
            "CONFIG_PACKAGE_nftables",
            "CONFIG_TESTING_KERNEL",
        ):
            if final.get(symbol) not in (None, "n"):
                problems.append(f"final OpenWrt config selected forbidden {symbol}")

    kernel_target = env.get("KERNEL_TARGET")
    target_makefile = openwrt / f"target/linux/{kernel_target}/Makefile"
    if target_makefile.is_file():
        match = re.search(
            r"^KERNEL_PATCHVER\s*:?=\s*([0-9]+\.[0-9]+)\s*$",
            target_makefile.read_text(encoding="utf-8"),
            re.MULTILINE,
        )
        if match:
            kernel_series = match.group(1)
        else:
            problems.append(f"cannot resolve stable KERNEL_PATCHVER from {target_makefile}")
    else:
        problems.append(f"target Makefile is missing: {target_makefile}")

    if lock and kernel_series:
        locked_profile = lock.get("profiles", {}).get(profile, {})
        if locked_profile.get("kernel_series") != kernel_series:
            problems.append("source-lock kernel series differs from target stable series")
        bbr = (
            lock.get("kernel_features", {})
            .get("bbr3", {})
            .get("ports", {})
            .get(kernel_series)
        )
        if not bbr:
            problems.append(f"source-lock has no BBRv3 port for kernel {kernel_series}")

    turboacc = openwrt / "feeds/luci/applications/luci-app-turboacc/Makefile"
    if turboacc.is_file():
        content = turboacc.read_text(encoding="utf-8")
        if "kmod-tcp-bbr" not in content:
            problems.append("TurboACC no longer depends on the shared kmod-tcp-bbr provider")
        if "TURBOACC_INCLUDE_FLOW_OFFLOADING" not in content:
            problems.append("TurboACC no longer exposes the locked flow-offload symbol")
    else:
        problems.append("selected TurboACC Makefile is missing")

optimization_contract_path = repo_root / "profiles/optimization-contracts.json"
try:
    optimization_contract = load_contract(optimization_contract_path)
    optimization_checks, optimization_problems = check_contract(
        optimization_contract,
        profile,
        files_root,
        openwrt_root=openwrt,
        kernel_series=kernel_series,
    )
except OptimizationContractError as exc:
    problems.append(f"invalid optimization contract: {exc}")
else:
    checks.extend(optimization_checks)
    problems.extend(optimization_problems)

if lock and profile not in lock.get("profiles", {}):
    problems.append(f"source-lock does not contain profile {profile}")

status = "passed" if not problems else "failed"
output = [
    "profile-contract-v1",
    f"profile={profile}",
    f"status={status}",
    *[f"check={item}" for item in checks],
    *[f"problem={item}" for item in problems],
]
text = "\n".join(output) + "\n"
if report_s:
    path = pathlib.Path(report_s)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text, encoding="utf-8")
print(text, end="")

if problems:
    print("::error::Profile contract failed:", file=sys.stderr)
    for problem in problems:
        print(f"  - {problem}", file=sys.stderr)
    raise SystemExit(1)
PY

echo "Profile contract passed for $profile."
