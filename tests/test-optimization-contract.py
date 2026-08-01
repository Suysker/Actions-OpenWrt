#!/usr/bin/env python3
"""Exercise the generic optimization contract with real overlays and fixtures."""

from __future__ import annotations

import copy
import pathlib
import subprocess
import sys
import tempfile


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from optimization_contract import check_contract, load_contract  # noqa: E402


def render_rootfs(profile: str, destination: pathlib.Path) -> None:
    subprocess.run(
        [
            "bash",
            str(REPO_ROOT / "scripts/render-profile.sh"),
            "files",
            profile,
            str(destination),
        ],
        check=True,
    )


def fixture_path(rule: dict[str, object], kernel_series: str) -> pathlib.Path:
    template = str(rule.get("path") or rule["glob"])
    relative = template.format(kernel_series=kernel_series)
    if "glob" in rule:
        relative = relative.replace("*", "contract")
    return pathlib.Path(relative)


def materialize_source_fixture(
    contract: dict[str, object], profile: str, root: pathlib.Path, kernel_series: str
) -> None:
    contents: dict[pathlib.Path, list[str]] = {}
    scopes = contract["scopes"]
    for scope in ("common", profile):
        for rule in scopes[scope]["source"]:
            path = fixture_path(rule, kernel_series)
            values = contents.setdefault(path, [])
            for field in ("contains", "exact_lines", "line_set"):
                values.extend(rule.get(field, []))

    for relative, lines in contents.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(dict.fromkeys(lines)) + "\n", encoding="utf-8")


def assert_no_problems(label: str, problems: list[str]) -> None:
    if problems:
        raise AssertionError(f"{label} unexpectedly failed: {problems}")


def main() -> int:
    contract_path = REPO_ROOT / "profiles/optimization-contracts.json"
    contract = load_contract(contract_path)
    text = contract_path.read_text(encoding="utf-8")
    if "6.12" in text or '"commit"' in text or '"sha256"' in text:
        raise AssertionError("optimization contract contains per-run version/hash state")

    profiles = sorted(scope for scope in contract["scopes"] if scope != "common")
    if profiles != ["r4s", "x86-n5105-pve"]:
        raise AssertionError(f"unexpected maintained optimization scopes: {profiles}")

    for scope in profiles:
        for rule in contract["scopes"][scope]["source"]:
            if "glob" in rule and not str(rule["glob"]).endswith("/*.patch"):
                raise AssertionError(f"patch rule pins a filename: {rule['name']}")

    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        for profile in profiles:
            rootfs = root / f"{profile}-rootfs"
            render_rootfs(profile, rootfs)

            static_checks, static_problems = check_contract(
                contract, profile, rootfs
            )
            assert_no_problems(f"{profile} static contract", static_problems)
            if not static_checks:
                raise AssertionError(f"{profile} static contract produced no evidence")

            source = root / f"{profile}-openwrt"
            materialize_source_fixture(contract, profile, source, "9.99")
            source_checks, source_problems = check_contract(
                contract,
                profile,
                rootfs,
                openwrt_root=source,
                kernel_series="9.99",
            )
            assert_no_problems(f"{profile} source contract", source_problems)
            expected = sum(
                len(contract["scopes"][scope][section])
                for scope in ("common", profile)
                for section in ("rootfs", "source")
            )
            if len(source_checks) != expected:
                raise AssertionError(
                    f"{profile} expected {expected} checks, got {len(source_checks)}"
                )

            broken = copy.deepcopy(contract)
            rule = broken["scopes"][profile]["source"][0]
            rule.setdefault("contains", []).append("fixture-must-not-contain-this")
            _, broken_problems = check_contract(
                broken,
                profile,
                rootfs,
                openwrt_root=source,
                kernel_series="9.99",
            )
            if not any(rule["name"] in problem for problem in broken_problems):
                raise AssertionError(
                    f"{profile} did not reject a missing source optimization semantic"
                )

    print("Optimization contract tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
