#!/usr/bin/env python3
"""Validate one rendered profile without embedding device-specific policy."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import sys
from typing import Iterable

from profile_model import (
    ProfileModelError,
    load_forbidden,
    load_required,
    parse_config,
    validate_relationships,
)
from profile_semantics import ProfileSemanticError, check_contract, load_contract


ENVIRONMENT_FIELDS = {
    "PROFILE_NAME",
    "REPO_URL",
    "REPO_REF",
    "KERNEL_TARGET",
    "TARGET_CHECK_REGEX",
    "IMAGE_PATTERN",
}


def parse_environment(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise ProfileModelError(f"invalid profile env line in {path}:{line_no}")
        if key in values:
            raise ProfileModelError(f"duplicate rendered profile env key: {key}")
        values[key] = value
    missing = sorted(ENVIRONMENT_FIELDS - set(values))
    if missing:
        raise ProfileModelError(
            "rendered profile env misses required interface fields: "
            + ", ".join(missing)
        )
    return values


def target_matches(expression: str, values: dict[str, str]) -> bool:
    try:
        pattern = re.compile(expression)
    except re.error as exc:
        raise ProfileModelError(f"invalid TARGET_CHECK_REGEX: {exc}") from exc
    return any(
        value == "y" and pattern.search(f"{symbol}={value}")
        for symbol, value in values.items()
    )


def resolve_kernel_series(openwrt: pathlib.Path, target: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_.+-]+", target):
        raise ProfileModelError(f"invalid KERNEL_TARGET: {target!r}")
    target_makefile = openwrt / "target" / "linux" / target / "Makefile"
    if not target_makefile.is_file():
        raise ProfileModelError(f"target Makefile is missing: {target_makefile}")
    matches = re.findall(
        r"^KERNEL_PATCHVER\s*:?=\s*([0-9]+\.[0-9]+)\s*$",
        target_makefile.read_text(encoding="utf-8"),
        re.MULTILINE,
    )
    if len(matches) != 1:
        raise ProfileModelError(
            f"expected one stable KERNEL_PATCHVER in {target_makefile}, got {matches}"
        )
    return matches[0]


def load_source_lock(path: pathlib.Path) -> dict[str, object]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProfileModelError(f"invalid source lock: {exc}") from exc
    if not isinstance(value, dict):
        raise ProfileModelError("source lock must be a JSON object")
    return value


def source_lock_problems(
    lock: dict[str, object], profile: str, kernel_series: str
) -> list[str]:
    problems: list[str] = []
    profiles = lock.get("profiles")
    if not isinstance(profiles, dict) or profile not in profiles:
        return [f"source-lock does not contain profile {profile}"]
    profile_entry = profiles[profile]
    if not isinstance(profile_entry, dict):
        return [f"source-lock profile entry is invalid: {profile}"]
    if profile_entry.get("kernel_series") != kernel_series:
        problems.append("source-lock kernel series differs from target stable series")

    kernel_features = lock.get("kernel_features")
    bbr3 = kernel_features.get("bbr3") if isinstance(kernel_features, dict) else None
    ports = bbr3.get("ports") if isinstance(bbr3, dict) else None
    if not isinstance(ports, dict) or kernel_series not in ports:
        problems.append(f"source-lock has no BBRv3 port for kernel {kernel_series}")
    return problems


def run(args: argparse.Namespace) -> tuple[list[str], list[str]]:
    checks: list[str] = []
    problems: list[str] = []

    required = load_required(args.required)
    forbidden = load_forbidden(args.forbidden)
    validate_relationships(required, forbidden)
    config = parse_config(args.config)
    environment = parse_environment(args.environment)

    if environment["PROFILE_NAME"] != args.profile:
        problems.append(
            f"PROFILE_NAME {environment['PROFILE_NAME']!r} does not equal {args.profile!r}"
        )
    if not environment["REPO_URL"].startswith("https://"):
        problems.append("REPO_URL must use HTTPS")
    if not environment["REPO_REF"]:
        problems.append("REPO_REF must not be empty")
    if not environment["IMAGE_PATTERN"]:
        problems.append("IMAGE_PATTERN must not be empty")

    for package in sorted(required.packages):
        symbol = f"CONFIG_PACKAGE_{package}"
        if config.get(symbol) != "y":
            problems.append(f"rendered config lost required package symbol {symbol}")
    for symbol in sorted(required.configs):
        if config.get(symbol) != "y":
            problems.append(f"rendered config lost required symbol {symbol}")
    for package in sorted(forbidden.exact):
        symbol = f"CONFIG_PACKAGE_{package}"
        if config.get(symbol) != "n":
            problems.append(f"rendered config did not disable exact-forbidden {symbol}")

    if not target_matches(environment["TARGET_CHECK_REGEX"], config):
        problems.append("rendered target does not match TARGET_CHECK_REGEX")
    else:
        checks.append("rendered target matches profile env")

    semantic_contract = load_contract(args.semantics)
    if args.openwrt is None:
        rootfs_checks, rootfs_problems = check_contract(
            semantic_contract, args.profile, args.files
        )
        checks.extend(rootfs_checks)
        problems.extend(rootfs_problems)
        return checks, problems

    if not args.openwrt.is_dir():
        problems.append(f"OpenWrt root does not exist: {args.openwrt}")
        return checks, problems
    final_config_path = args.openwrt / ".config"
    if not final_config_path.is_file():
        problems.append(f"final OpenWrt config is missing: {final_config_path}")
        return checks, problems
    final_config = parse_config(final_config_path)
    if not target_matches(environment["TARGET_CHECK_REGEX"], final_config):
        problems.append("final OpenWrt target does not match TARGET_CHECK_REGEX")
    else:
        checks.append("final target matches profile env")

    kernel_series = resolve_kernel_series(
        args.openwrt, environment["KERNEL_TARGET"]
    )
    checks.append(f"stable kernel series {kernel_series}")
    if args.source_lock is None:
        problems.append("source lock is required with an OpenWrt tree")
    else:
        lock = load_source_lock(args.source_lock)
        lock_problems = source_lock_problems(lock, args.profile, kernel_series)
        problems.extend(lock_problems)
        if not lock_problems:
            checks.append("source-lock profile/kernel/BBRv3 mapping")

    source_checks, source_problems = check_contract(
        semantic_contract,
        args.profile,
        args.files,
        openwrt_root=args.openwrt,
        kernel_series=kernel_series,
    )
    checks.extend(source_checks)
    problems.extend(source_problems)
    if args.provider_report is not None:
        checks.append(f"provider contract {args.provider_report}")
    return checks, problems


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", required=True)
    parser.add_argument("--config", required=True, type=pathlib.Path)
    parser.add_argument("--required", required=True, type=pathlib.Path)
    parser.add_argument("--forbidden", required=True, type=pathlib.Path)
    parser.add_argument("--environment", required=True, type=pathlib.Path)
    parser.add_argument("--files", required=True, type=pathlib.Path)
    parser.add_argument("--semantics", required=True, type=pathlib.Path)
    parser.add_argument("--openwrt", type=pathlib.Path)
    parser.add_argument("--source-lock", type=pathlib.Path)
    parser.add_argument("--provider-report", type=pathlib.Path)
    parser.add_argument("--report", type=pathlib.Path)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        checks, problems = run(args)
    except (OSError, ProfileModelError, ProfileSemanticError) as exc:
        checks, problems = [], [str(exc)]

    status = "passed" if not problems else "failed"
    lines = [
        "profile-contract-v2",
        f"profile={args.profile}",
        f"status={status}",
        *[f"check={item}" for item in checks],
        *[f"problem={item}" for item in problems],
    ]
    output = "\n".join(lines) + "\n"
    if args.report:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(output, encoding="utf-8")
    print(output, end="")
    if problems:
        print("::error::Profile contract failed:", file=sys.stderr)
        for problem in problems:
            print(f"  - {problem}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
