#!/usr/bin/env python3
"""Parse profile declarations and derive the single OpenWrt config input."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import glob
import pathlib
import re
import sys
from typing import Iterable


PACKAGE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.+-]*")
CONFIG_RE = re.compile(r"CONFIG_[A-Za-z0-9_.+-]+")
SELECTED_RE = re.compile(r"(CONFIG_[A-Za-z0-9_.+-]+)=(.*)")
DISABLED_RE = re.compile(r"# (CONFIG_[A-Za-z0-9_.+-]+) is not set")


class ProfileModelError(RuntimeError):
    """A profile declaration is malformed or has conflicting ownership."""


@dataclass(frozen=True)
class RequiredRules:
    packages: frozenset[str]
    configs: frozenset[str]


@dataclass(frozen=True)
class ForbiddenRules:
    exact: frozenset[str]
    regex: tuple[str, ...]


def clean_lines(path: pathlib.Path) -> list[tuple[int, str]]:
    try:
        raw_lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ProfileModelError(f"cannot read {path}: {exc}") from exc

    result: list[tuple[int, str]] = []
    seen: dict[str, int] = {}
    for line_no, raw in enumerate(raw_lines, start=1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        if line in seen:
            raise ProfileModelError(
                f"duplicate rule in {path}:{line_no}; first declared at line "
                f"{seen[line]}: {line}"
            )
        seen[line] = line_no
        result.append((line_no, line))
    return result


def load_required(path: pathlib.Path) -> RequiredRules:
    packages: set[str] = set()
    configs: set[str] = set()
    for line_no, line in clean_lines(path):
        kind, separator, value = line.partition(":")
        if not separator or kind not in {"package", "config"}:
            raise ProfileModelError(
                f"invalid required rule in {path}:{line_no}: {line}"
            )
        if kind == "package":
            if not PACKAGE_RE.fullmatch(value):
                raise ProfileModelError(
                    f"invalid required package in {path}:{line_no}: {value!r}"
                )
            packages.add(value)
        else:
            if not CONFIG_RE.fullmatch(value):
                raise ProfileModelError(
                    f"invalid required config in {path}:{line_no}: {value!r}"
                )
            configs.add(value)
    return RequiredRules(frozenset(packages), frozenset(configs))


def load_forbidden(path: pathlib.Path) -> ForbiddenRules:
    exact: set[str] = set()
    regex: list[str] = []
    for line_no, line in clean_lines(path):
        kind, separator, value = line.partition(":")
        if not separator or kind not in {"exact", "regex"}:
            raise ProfileModelError(
                f"invalid forbidden rule in {path}:{line_no}: {line}"
            )
        if kind == "exact":
            if not PACKAGE_RE.fullmatch(value):
                raise ProfileModelError(
                    f"invalid exact forbidden package in {path}:{line_no}: {value!r}"
                )
            exact.add(value)
        else:
            if not value:
                raise ProfileModelError(
                    f"empty forbidden regex in {path}:{line_no}"
                )
            try:
                re.compile(value)
            except re.error as exc:
                raise ProfileModelError(
                    f"invalid forbidden regex in {path}:{line_no}: {exc}"
                ) from exc
            regex.append(value)
    return ForbiddenRules(frozenset(exact), tuple(regex))


def parse_config(path: pathlib.Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ProfileModelError(f"cannot read {path}: {exc}") from exc

    values: dict[str, str] = {}
    locations: dict[str, int] = {}
    for line_no, raw in enumerate(lines, start=1):
        selected = SELECTED_RE.fullmatch(raw)
        disabled = DISABLED_RE.fullmatch(raw)
        if selected:
            symbol, value = selected.groups()
        elif disabled:
            symbol, value = disabled.group(1), "n"
        else:
            continue
        if symbol in values:
            raise ProfileModelError(
                f"duplicate config symbol in {path}:{line_no}; first declared at "
                f"line {locations[symbol]}: {symbol}"
            )
        values[symbol] = value
        locations[symbol] = line_no
    return values


def _derived_symbols(
    required: RequiredRules, forbidden: ForbiddenRules
) -> dict[str, tuple[str, str]]:
    derived: dict[str, tuple[str, str]] = {}

    def own(symbol: str, value: str, owner: str) -> None:
        previous = derived.get(symbol)
        if previous:
            raise ProfileModelError(
                f"derived config symbol has multiple owners: {symbol} "
                f"({previous[1]} and {owner})"
            )
        derived[symbol] = (value, owner)

    for package in sorted(required.packages):
        own(f"CONFIG_PACKAGE_{package}", "y", f"required package:{package}")
    for symbol in sorted(required.configs):
        own(symbol, "y", f"required config:{symbol}")
    for package in sorted(forbidden.exact):
        own(f"CONFIG_PACKAGE_{package}", "n", f"forbidden exact:{package}")
    return derived


def validate_relationships(
    required: RequiredRules, forbidden: ForbiddenRules
) -> None:
    conflicts = sorted(required.packages & forbidden.exact)
    if conflicts:
        raise ProfileModelError(
            "packages are both required and exact-forbidden: " + ", ".join(conflicts)
        )
    for pattern in forbidden.regex:
        expression = re.compile(pattern)
        matches = sorted(package for package in required.packages if expression.search(package))
        if matches:
            raise ProfileModelError(
                f"required packages match forbidden regex {pattern!r}: "
                + ", ".join(matches)
            )
    _derived_symbols(required, forbidden)


def derive_config(
    seed_path: pathlib.Path,
    required_path: pathlib.Path,
    forbidden_path: pathlib.Path,
    output_path: pathlib.Path,
) -> None:
    required = load_required(required_path)
    forbidden = load_forbidden(forbidden_path)
    validate_relationships(required, forbidden)
    seed = parse_config(seed_path)
    derived = _derived_symbols(required, forbidden)
    duplicate_owners = sorted(set(seed) & set(derived))
    if duplicate_owners:
        details = ", ".join(
            f"{symbol} ({derived[symbol][1]})" for symbol in duplicate_owners
        )
        raise ProfileModelError(
            "config.seed repeats symbols owned by required/forbidden rules: " + details
        )

    source = seed_path.read_text(encoding="utf-8").rstrip()
    selected = [
        symbol for symbol, (value, _) in sorted(derived.items()) if value == "y"
    ]
    disabled = [
        symbol for symbol, (value, _) in sorted(derived.items()) if value == "n"
    ]
    chunks = [source]
    if selected:
        chunks.append(
            "# Derived from required package/config contracts.\n"
            + "\n".join(f"{symbol}=y" for symbol in selected)
        )
    if disabled:
        chunks.append(
            "# Derived from exact forbidden package contracts.\n"
            + "\n".join(f"# {symbol} is not set" for symbol in disabled)
        )
    output_path.parent.mkdir(parents=True, exist_ok=True)
    output_path.write_text("\n\n".join(chunks) + "\n", encoding="utf-8")


def selected_packages(config_path: pathlib.Path) -> set[str]:
    return {
        symbol.removeprefix("CONFIG_PACKAGE_")
        for symbol, value in parse_config(config_path).items()
        if symbol.startswith("CONFIG_PACKAGE_") and value == "y"
    }


def package_names(path: pathlib.Path) -> set[str]:
    try:
        return {
            line.strip()
            for line in path.read_text(encoding="utf-8").splitlines()
            if line.strip()
        }
    except OSError as exc:
        raise ProfileModelError(f"cannot read package list {path}: {exc}") from exc


def required_misses(
    config_path: pathlib.Path,
    rules_path: pathlib.Path,
    package_list: pathlib.Path | None = None,
) -> list[str]:
    config = parse_config(config_path)
    required = load_required(rules_path)
    packages = (
        package_names(package_list)
        if package_list is not None and package_list.is_file()
        else selected_packages(config_path)
    )
    missing = [
        f"package:{package}"
        for package in sorted(required.packages)
        if package not in packages
    ]
    missing.extend(
        f"config:{symbol}"
        for symbol in sorted(required.configs)
        if config.get(symbol) != "y"
    )
    return missing


def _known_packages(config_path: pathlib.Path) -> set[str]:
    roots = (config_path.parent, pathlib.Path.cwd())
    metadata_paths: set[pathlib.Path] = set()
    for root in roots:
        metadata_paths.add(root / "tmp/.packageinfo")
        metadata_paths.update(
            pathlib.Path(value) for value in glob.glob(str(root / "tmp/info/.packageinfo*"))
        )
    known: set[str] = set()
    for metadata in metadata_paths:
        if not metadata.is_file():
            continue
        for raw in metadata.read_text(encoding="utf-8", errors="replace").splitlines():
            if raw.startswith("Package:"):
                name = raw.removeprefix("Package:").strip()
                if name:
                    known.add(name)
    return known


def forbidden_matches(
    config_path: pathlib.Path,
    rules_path: pathlib.Path,
    output_directory: pathlib.Path,
) -> tuple[list[str], int, bool]:
    forbidden = load_forbidden(rules_path)
    selected = selected_packages(config_path)
    known = _known_packages(config_path)
    filtered = selected & known if known else selected
    matches = set(filtered & forbidden.exact)
    for pattern in forbidden.regex:
        expression = re.compile(pattern)
        matches.update(package for package in filtered if expression.search(package))

    output_directory.mkdir(parents=True, exist_ok=True)
    package_list = output_directory / "package-list.txt"
    match_list = output_directory / "forbidden-packages.detected.txt"
    package_list.write_text(
        "".join(f"{package}\n" for package in sorted(filtered)), encoding="utf-8"
    )
    match_list.write_text(
        "".join(f"{package}\n" for package in sorted(matches)), encoding="utf-8"
    )
    return sorted(matches), len(filtered), bool(known)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)
    derive = subparsers.add_parser("derive-config")
    derive.add_argument("seed", type=pathlib.Path)
    derive.add_argument("required", type=pathlib.Path)
    derive.add_argument("forbidden", type=pathlib.Path)
    derive.add_argument("output", type=pathlib.Path)

    required = subparsers.add_parser("check-required")
    required.add_argument("config", type=pathlib.Path)
    required.add_argument("rules", type=pathlib.Path)
    required.add_argument("package_list", nargs="?", type=pathlib.Path)

    forbidden = subparsers.add_parser("check-forbidden")
    forbidden.add_argument("config", type=pathlib.Path)
    forbidden.add_argument("rules", type=pathlib.Path)
    forbidden.add_argument("output_directory", type=pathlib.Path)

    package_list = subparsers.add_parser("list-required-packages")
    package_list.add_argument("rules", type=pathlib.Path)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.command == "derive-config":
            derive_config(args.seed, args.required, args.forbidden, args.output)
        elif args.command == "check-required":
            missing = required_misses(args.config, args.rules, args.package_list)
            if missing:
                print(
                    "::error::Required profile packages/config symbols are missing "
                    "from the final OpenWrt config:"
                )
                for item in missing:
                    print(f"  - {item}")
                return 1
            print("Required package check passed.")
        elif args.command == "check-forbidden":
            matches, package_count, has_metadata = forbidden_matches(
                args.config, args.rules, args.output_directory
            )
            if not has_metadata:
                print(
                    "::warning::OpenWrt package metadata not found; checking all "
                    "CONFIG_PACKAGE_* symbols.",
                    file=sys.stderr,
                )
            print(f"Resolved built-in package selections: {package_count}")
            print(
                "Package list written to: "
                f"{args.output_directory / 'package-list.txt'}"
            )
            if matches:
                print("::error::Forbidden packages were selected by the final config:")
                for package in matches:
                    print(f"  - {package}")
                return 1
            print("Forbidden package check passed.")
        elif args.command == "list-required-packages":
            for package in sorted(load_required(args.rules).packages):
                print(package)
    except ProfileModelError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
