#!/usr/bin/env python3
"""Validate one profile through the shared profile model and semantic rules."""

from __future__ import annotations

import argparse
import json
import pathlib
import re
import subprocess
import sys
import tempfile
from typing import Iterable

from profile_model import (
    ProfileModelError,
    ProfileRepository,
    evaluate_package_contract,
    parse_config,
    rendered_config_problems,
    write_package_contract_reports,
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


def _check_provider_contract(
    repo_root: pathlib.Path,
    openwrt: pathlib.Path,
    report: pathlib.Path,
) -> None:
    command = [
        "bash",
        str(repo_root / "scripts/select-package-providers.sh"),
        "--check",
        str(openwrt),
        str(report),
    ]
    try:
        subprocess.run(command, check=True)
    except subprocess.CalledProcessError as exc:
        raise ProfileModelError(
            f"package provider contract failed with exit code {exc.returncode}"
        ) from exc


def run(args: argparse.Namespace) -> tuple[list[str], list[str]]:
    checks: list[str] = []
    problems: list[str] = []
    repository = ProfileRepository(args.profiles_root)

    with tempfile.TemporaryDirectory(prefix="profile-contract-") as temporary:
        rendered = repository.render_bundle(
            args.profile, pathlib.Path(temporary) / "rendered"
        )
        config = parse_config(rendered.config)
        environment = rendered.environment

        missing_fields = sorted(ENVIRONMENT_FIELDS - set(environment))
        if missing_fields:
            problems.append(
                "rendered profile env misses required interface fields: "
                + ", ".join(missing_fields)
            )
            return checks, problems
        if not environment["REPO_URL"].startswith("https://"):
            problems.append("REPO_URL must use HTTPS")
        if not environment["REPO_REF"]:
            problems.append("REPO_REF must not be empty")
        if not environment["IMAGE_PATTERN"]:
            problems.append("IMAGE_PATTERN must not be empty")

        problems.extend(
            rendered_config_problems(config, rendered.required, rendered.forbidden)
        )
        if not target_matches(environment["TARGET_CHECK_REGEX"], config):
            problems.append("rendered target does not match TARGET_CHECK_REGEX")
        else:
            checks.append("rendered target matches profile env")

        semantic_contract = load_contract(args.profiles_root, args.profile)
        if args.openwrt is None:
            rootfs_checks, rootfs_problems = check_contract(
                semantic_contract, args.profile, rendered.files
            )
            checks.extend(rootfs_checks)
            problems.extend(rootfs_problems)
            return checks, problems

        openwrt = args.openwrt.resolve()
        if not openwrt.is_dir():
            problems.append(f"OpenWrt root does not exist: {openwrt}")
            return checks, problems
        final_config_path = openwrt / ".config"
        if not final_config_path.is_file():
            problems.append(f"final OpenWrt config is missing: {final_config_path}")
            return checks, problems

        diagnostics = args.diagnostics_dir or pathlib.Path(temporary) / "diagnostics"
        package_contract = evaluate_package_contract(
            final_config_path,
            rendered.required,
            rendered.forbidden,
        )
        write_package_contract_reports(package_contract, diagnostics)
        problems.extend(package_contract.problems)
        if package_contract.package_metadata_found:
            checks.append(
                f"final package contract ({len(package_contract.selected_packages)} packages)"
            )
        else:
            problems.append("OpenWrt package metadata is missing for final package checks")

        final_config = parse_config(final_config_path)
        if not target_matches(environment["TARGET_CHECK_REGEX"], final_config):
            problems.append("final OpenWrt target does not match TARGET_CHECK_REGEX")
        else:
            checks.append("final target matches profile env")

        provider_report = diagnostics / "provider-contract.txt"
        _check_provider_contract(args.repo_root, openwrt, provider_report)
        checks.append(f"provider contract {provider_report}")

        kernel_series = resolve_kernel_series(openwrt, environment["KERNEL_TARGET"])
        checks.append(f"stable kernel series {kernel_series}")
        if args.source_lock is None:
            problems.append("source lock is required with an OpenWrt tree")
        else:
            lock = load_source_lock(args.source_lock)
            lock_problems = source_lock_problems(
                lock, args.profile, kernel_series
            )
            problems.extend(lock_problems)
            if not lock_problems:
                checks.append("source-lock profile/kernel/BBRv3 mapping")

        source_checks, source_problems = check_contract(
            semantic_contract,
            args.profile,
            rendered.files,
            openwrt_root=openwrt,
            kernel_series=kernel_series,
        )
        checks.extend(source_checks)
        problems.extend(source_problems)
        return checks, problems


def build_parser() -> argparse.ArgumentParser:
    default_root = pathlib.Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo-root", type=pathlib.Path, default=default_root)
    parser.add_argument(
        "--profiles-root", type=pathlib.Path, default=default_root / "profiles"
    )
    parser.add_argument("--profile", required=True)
    parser.add_argument("--openwrt", type=pathlib.Path)
    parser.add_argument("--source-lock", type=pathlib.Path)
    parser.add_argument("--diagnostics-dir", type=pathlib.Path)
    parser.add_argument("--report", type=pathlib.Path)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    if args.source_lock is not None and args.openwrt is None:
        print("::error::source-lock cannot be supplied without an OpenWrt tree", file=sys.stderr)
        return 2
    try:
        checks, problems = run(args)
    except (OSError, ProfileModelError, ProfileSemanticError) as exc:
        checks, problems = [], [str(exc)]

    status = "passed" if not problems else "failed"
    lines = [
        "profile-contract-v3",
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
