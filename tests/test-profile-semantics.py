#!/usr/bin/env python3
"""Exercise generic profile semantics with real overlays and fixtures."""

from __future__ import annotations

import copy
import pathlib
import sys
import tempfile


REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO_ROOT / "scripts"))

from profile_semantics import check_contract, load_contract  # noqa: E402
from profile_model import ProfileRepository  # noqa: E402


def fixture_path(
    matcher: dict[str, object], kernel_series: str, kernel_version: str
) -> pathlib.Path:
    template = str(matcher.get("path") or matcher["glob"])
    relative = template.format(
        kernel_series=kernel_series, kernel_version=kernel_version
    )
    if "glob" in matcher:
        relative = relative.replace("*", "contract")
    return pathlib.Path(relative)


def materialize_source_fixture(
    contract: dict[str, object],
    profile: str,
    root: pathlib.Path,
    kernel_series: str,
    kernel_version: str,
) -> None:
    contents: dict[pathlib.Path, list[str]] = {}
    scopes = contract["scopes"]
    for scope in ("common", profile):
        for rule in scopes[scope]["source"]:
            matcher = rule.get("alternatives", [rule])[0]
            path = fixture_path(matcher, kernel_series, kernel_version)
            values = contents.setdefault(path, [])
            for field in ("contains", "exact_lines", "line_set"):
                values.extend(matcher.get(field, []))

    for relative, lines in contents.items():
        path = root / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("\n".join(dict.fromkeys(lines)) + "\n", encoding="utf-8")


def assert_no_problems(label: str, problems: list[str]) -> None:
    if problems:
        raise AssertionError(f"{label} unexpectedly failed: {problems}")


def main() -> int:
    profiles = list(ProfileRepository(REPO_ROOT / "profiles").profiles())
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        for profile in profiles:
            contract = load_contract(REPO_ROOT / "profiles", profile)
            semantics_text = "\n".join(
                (REPO_ROOT / "profiles" / scope / "semantics.json").read_text(
                    encoding="utf-8"
                )
                for scope in ("common", profile)
            )
            if (
                "6.12" in semantics_text
                or '"commit"' in semantics_text
                or '"sha256"' in semantics_text
            ):
                raise AssertionError(
                    f"{profile} semantics contain per-run version/hash state"
                )
            for scope in ("common", profile):
                for rule in contract["scopes"][scope]["source"]:
                    for matcher in rule.get("alternatives", [rule]):
                        glob = matcher.get("glob")
                        if (
                            glob
                            and "target/linux/" in str(glob)
                            and not str(glob).endswith("/*.patch")
                        ):
                            raise AssertionError(
                                f"patch rule pins a filename: {rule['name']}"
                            )

            source = root / f"{profile}-openwrt"
            materialize_source_fixture(
                contract, profile, source, "9.99", "9.99.1"
            )
            source_checks, source_problems = check_contract(
                contract,
                profile,
                source,
                kernel_series="9.99",
                kernel_version="9.99.1",
            )
            assert_no_problems(f"{profile} source contract", source_problems)
            expected = sum(
                len(contract["scopes"][scope]["source"])
                for scope in ("common", profile)
            )
            if len(source_checks) != expected:
                raise AssertionError(
                    f"{profile} expected {expected} checks, got {len(source_checks)}"
                )

            alternative_rules = [
                rule
                for scope in ("common", profile)
                for rule in contract["scopes"][scope]["source"]
                if "alternatives" in rule
            ]
            for rule in alternative_rules:
                first, second = rule["alternatives"][:2]
                first_path = source / fixture_path(first, "9.99", "9.99.1")
                first_path.unlink()
                second_path = source / fixture_path(second, "9.99", "9.99.1")
                second_path.parent.mkdir(parents=True, exist_ok=True)
                second_lines = [
                    value
                    for field in ("contains", "exact_lines", "line_set")
                    for value in second.get(field, [])
                ]
                second_path.write_text(
                    "\n".join(dict.fromkeys(second_lines)) + "\n",
                    encoding="utf-8",
                )
                _, alternative_problems = check_contract(
                    contract,
                    profile,
                    source,
                    kernel_series="9.99",
                    kernel_version="9.99.1",
                )
                assert_no_problems(
                    f"{profile} upstream semantic alternative",
                    alternative_problems,
                )

            broken = copy.deepcopy(contract)
            rule = broken["scopes"][profile]["source"][0]
            rule.setdefault("contains", []).append("fixture-must-not-contain-this")
            _, broken_problems = check_contract(
                broken,
                profile,
                source,
                kernel_series="9.99",
                kernel_version="9.99.1",
            )
            if not any(rule["name"] in problem for problem in broken_problems):
                raise AssertionError(
                    f"{profile} did not reject a missing source semantic"
                )

    print("Profile semantic tests passed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
