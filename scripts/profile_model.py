#!/usr/bin/env python3
"""Own profile discovery, rendering and package/config contract evaluation."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import glob
import os
import pathlib
import re
import shutil
import sys
import tempfile
from typing import Iterable


PACKAGE_RE = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.+-]*")
CONFIG_RE = re.compile(r"CONFIG_[A-Za-z0-9_.+-]+")
PROFILE_RE = re.compile(r"[a-z0-9][a-z0-9-]*")
ENV_KEY_RE = re.compile(r"[A-Za-z_][A-Za-z0-9_]*")
SELECTED_RE = re.compile(r"(CONFIG_[A-Za-z0-9_.+-]+)=(.*)")
DISABLED_RE = re.compile(r"# (CONFIG_[A-Za-z0-9_.+-]+) is not set")
PAIR_INPUTS = (
    "config.seed",
    "required-packages.txt",
    "forbidden-packages.txt",
)


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


@dataclass(frozen=True)
class RenderedProfile:
    """Paths and parsed values for one immutable common+device snapshot."""

    name: str
    root: pathlib.Path
    config: pathlib.Path
    required_path: pathlib.Path
    forbidden_path: pathlib.Path
    environment_path: pathlib.Path
    files: pathlib.Path
    required: RequiredRules
    forbidden: ForbiddenRules
    environment: dict[str, str]


@dataclass(frozen=True)
class PackageContractResult:
    """One evaluation of required and forbidden rules against a final config."""

    selected_packages: tuple[str, ...]
    missing_required: tuple[str, ...]
    forbidden_matches: tuple[str, ...]
    package_metadata_found: bool

    @property
    def problems(self) -> tuple[str, ...]:
        return tuple(
            [f"final config misses required {item}" for item in self.missing_required]
            + [
                f"final config selects forbidden package:{item}"
                for item in self.forbidden_matches
            ]
        )


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


def parse_environment(path: pathlib.Path) -> dict[str, str]:
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        raise ProfileModelError(f"cannot read {path}: {exc}") from exc

    values: dict[str, str] = {}
    for line_no, raw in enumerate(lines, start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not ENV_KEY_RE.fullmatch(key):
            raise ProfileModelError(f"invalid profile env line in {path}:{line_no}")
        if key in values:
            raise ProfileModelError(
                f"duplicate profile env key in {path}:{line_no}: {key}"
            )
        values[key] = value
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
        matches = sorted(
            package for package in required.packages if expression.search(package)
        )
        if matches:
            raise ProfileModelError(
                f"required packages match forbidden regex {pattern!r}: "
                + ", ".join(matches)
            )
    _derived_symbols(required, forbidden)


def rendered_config_problems(
    config: dict[str, str],
    required: RequiredRules,
    forbidden: ForbiddenRules,
) -> list[str]:
    """Validate every Kconfig value mechanically derived by the model."""

    problems: list[str] = []
    for symbol, (expected, owner) in sorted(
        _derived_symbols(required, forbidden).items()
    ):
        actual = config.get(symbol)
        if actual != expected:
            problems.append(
                f"rendered config lost {owner}: {symbol} expected {expected}, got {actual}"
            )
    return problems


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


def _known_packages(config_path: pathlib.Path) -> set[str]:
    roots = (config_path.parent, pathlib.Path.cwd())
    metadata_paths: set[pathlib.Path] = set()
    for root in roots:
        metadata_paths.add(root / "tmp/.packageinfo")
        metadata_paths.update(
            pathlib.Path(value)
            for value in glob.glob(str(root / "tmp/info/.packageinfo*"))
        )
    known: set[str] = set()
    for metadata in metadata_paths:
        if not metadata.is_file():
            continue
        for raw in metadata.read_text(
            encoding="utf-8", errors="replace"
        ).splitlines():
            if raw.startswith("Package:"):
                name = raw.removeprefix("Package:").strip()
                if name:
                    known.add(name)
    return known


def evaluate_package_contract(
    config_path: pathlib.Path,
    required: RequiredRules,
    forbidden: ForbiddenRules,
    *,
    package_list: pathlib.Path | None = None,
) -> PackageContractResult:
    """Evaluate both rule sets once, using final package metadata when available."""

    validate_relationships(required, forbidden)
    config = parse_config(config_path)
    if package_list is not None:
        packages = package_names(package_list)
        has_metadata = True
    else:
        selected = selected_packages(config_path)
        known = _known_packages(config_path)
        packages = selected & known if known else selected
        has_metadata = bool(known)

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

    forbidden_matches = set(packages & forbidden.exact)
    for pattern in forbidden.regex:
        expression = re.compile(pattern)
        forbidden_matches.update(
            package for package in packages if expression.search(package)
        )

    return PackageContractResult(
        selected_packages=tuple(sorted(packages)),
        missing_required=tuple(missing),
        forbidden_matches=tuple(sorted(forbidden_matches)),
        package_metadata_found=has_metadata,
    )


def write_package_contract_reports(
    result: PackageContractResult, output_directory: pathlib.Path
) -> None:
    output_directory.mkdir(parents=True, exist_ok=True)
    (output_directory / "package-list.txt").write_text(
        "".join(f"{package}\n" for package in result.selected_packages),
        encoding="utf-8",
    )
    (output_directory / "forbidden-packages.detected.txt").write_text(
        "".join(f"{package}\n" for package in result.forbidden_matches),
        encoding="utf-8",
    )


class ProfileRepository:
    """Discover and render common+device declarations through one implementation."""

    def __init__(self, root: pathlib.Path):
        self.root = root.resolve()
        self.common = self.root / "common"
        if not self.common.is_dir():
            raise ProfileModelError(
                f"profile repository has no common directory: {self.common}"
            )

    def profiles(self) -> tuple[str, ...]:
        names: list[str] = []
        try:
            candidates = sorted(self.root.iterdir(), key=lambda path: path.name)
        except OSError as exc:
            raise ProfileModelError(f"cannot list profiles in {self.root}: {exc}") from exc
        for candidate in candidates:
            if candidate.name == "common" or not candidate.is_dir():
                continue
            if not (candidate / "config.seed").is_file():
                continue
            self._validate_name(candidate.name)
            names.append(candidate.name)
        if not names:
            raise ProfileModelError(f"profile repository has no device profiles: {self.root}")
        return tuple(names)

    @staticmethod
    def _validate_name(profile: str) -> None:
        if not PROFILE_RE.fullmatch(profile):
            raise ProfileModelError(f"invalid profile name: {profile}")
        if profile == "common":
            raise ProfileModelError("common is not a device profile")

    def device(self, profile: str) -> pathlib.Path:
        self._validate_name(profile)
        device = self.root / profile
        if not device.is_dir() or not (device / "config.seed").is_file():
            raise ProfileModelError(f"unknown device profile: {profile}")
        return device

    def _pair(self, profile: str, kind: str) -> tuple[pathlib.Path, pathlib.Path]:
        if kind not in PAIR_INPUTS:
            raise ProfileModelError(f"unsupported paired profile input: {kind}")
        paths = self.common / kind, self.device(profile) / kind
        for path in paths:
            if not path.is_file():
                raise ProfileModelError(f"missing profile input: {path}")
        return paths

    @staticmethod
    def _pair_keys(kind: str, path: pathlib.Path) -> set[str]:
        if kind == "config.seed":
            return set(parse_config(path))
        return {line for _, line in clean_lines(path)}

    def render_pair(
        self, profile: str, kind: str, output: pathlib.Path
    ) -> pathlib.Path:
        common, device = self._pair(profile, kind)
        duplicates = sorted(
            self._pair_keys(kind, common) & self._pair_keys(kind, device)
        )
        if duplicates:
            raise ProfileModelError(
                f"common and device profile both own entries in {kind}: "
                + ", ".join(duplicates)
            )
        output.parent.mkdir(parents=True, exist_ok=True)
        text = (
            f"# Generated from profiles/common/{kind} and "
            f"profiles/{profile}/{kind}\n\n"
            + common.read_text(encoding="utf-8").rstrip()
            + "\n\n"
            + device.read_text(encoding="utf-8").rstrip()
            + "\n"
        )
        output.write_text(text, encoding="utf-8")
        return output

    def environment(self, profile: str) -> dict[str, str]:
        common_path = self.common / "profile.env"
        device_path = self.device(profile) / "profile.env"
        if not common_path.is_file() or not device_path.is_file():
            missing = common_path if not common_path.is_file() else device_path
            raise ProfileModelError(f"missing profile env: {missing}")
        values = parse_environment(common_path)
        values.update(parse_environment(device_path))
        if values.get("PROFILE_NAME") != profile:
            raise ProfileModelError(
                f"profile.env PROFILE_NAME mismatch for {profile}: "
                f"{values.get('PROFILE_NAME')!r}"
            )
        return values

    def render_environment(
        self, profile: str, output: pathlib.Path | None = None
    ) -> str:
        text = "".join(
            f"{key}={value}\n" for key, value in self.environment(profile).items()
        )
        if output is not None:
            output.parent.mkdir(parents=True, exist_ok=True)
            output.write_text(text, encoding="utf-8")
        return text

    def render_config(self, profile: str, output: pathlib.Path) -> pathlib.Path:
        with tempfile.TemporaryDirectory(prefix="profile-config-") as temporary:
            temp = pathlib.Path(temporary)
            seed = self.render_pair(profile, "config.seed", temp / "config.seed")
            required = self.render_pair(
                profile, "required-packages.txt", temp / "required.txt"
            )
            forbidden = self.render_pair(
                profile, "forbidden-packages.txt", temp / "forbidden.txt"
            )
            derive_config(seed, required, forbidden, output)
        return output

    @staticmethod
    def _profile_files(root: pathlib.Path) -> dict[pathlib.PurePosixPath, pathlib.Path]:
        if not root.is_dir():
            return {}
        result: dict[pathlib.PurePosixPath, pathlib.Path] = {}
        for directory, dirnames, filenames in os.walk(root, followlinks=False):
            directory_path = pathlib.Path(directory)
            symlink_dirs = [
                name for name in dirnames if (directory_path / name).is_symlink()
            ]
            dirnames[:] = [name for name in dirnames if name not in symlink_dirs]
            for name in [*symlink_dirs, *filenames]:
                source = directory_path / name
                relative = pathlib.PurePosixPath(source.relative_to(root).as_posix())
                result[relative] = source
        return result

    def render_files(
        self, profile: str, output_directory: pathlib.Path
    ) -> pathlib.Path:
        common_files = self._profile_files(self.common / "files")
        device_files = self._profile_files(self.device(profile) / "files")
        duplicates = sorted(set(common_files) & set(device_files))
        if duplicates:
            raise ProfileModelError(
                "common and device rootfs files overlap: "
                + ", ".join(path.as_posix() for path in duplicates)
            )
        output_directory.mkdir(parents=True, exist_ok=True)
        for source_map in (common_files, device_files):
            for relative, source in source_map.items():
                target = output_directory.joinpath(*relative.parts)
                if target.exists() or target.is_symlink():
                    raise ProfileModelError(
                        f"refusing to overwrite existing rootfs path: {target}"
                    )
                target.parent.mkdir(parents=True, exist_ok=True)
                if source.is_symlink():
                    target.symlink_to(os.readlink(source))
                else:
                    shutil.copy2(source, target)
        return output_directory

    def render_bundle(
        self, profile: str, output_directory: pathlib.Path
    ) -> RenderedProfile:
        if output_directory.exists():
            raise ProfileModelError(
                f"rendered profile bundle already exists: {output_directory}"
            )
        output_directory.mkdir(parents=True)
        try:
            config = self.render_config(profile, output_directory / "config.seed")
            required_path = self.render_pair(
                profile,
                "required-packages.txt",
                output_directory / "required.txt",
            )
            forbidden_path = self.render_pair(
                profile,
                "forbidden-packages.txt",
                output_directory / "forbidden.txt",
            )
            environment_path = output_directory / "profile.env"
            self.render_environment(profile, environment_path)
            files = self.render_files(profile, output_directory / "files")
            required = load_required(required_path)
            forbidden = load_forbidden(forbidden_path)
            validate_relationships(required, forbidden)
            environment = parse_environment(environment_path)
            problems = rendered_config_problems(
                parse_config(config), required, forbidden
            )
            if problems:
                raise ProfileModelError("; ".join(problems))
            return RenderedProfile(
                name=profile,
                root=output_directory,
                config=config,
                required_path=required_path,
                forbidden_path=forbidden_path,
                environment_path=environment_path,
                files=files,
                required=required,
                forbidden=forbidden,
                environment=environment,
            )
        except Exception:
            shutil.rmtree(output_directory, ignore_errors=True)
            raise


def _profile_repository_from_environment() -> ProfileRepository:
    default = pathlib.Path(__file__).resolve().parents[1] / "profiles"
    return ProfileRepository(
        pathlib.Path(os.environ.get("PROFILE_ROOT_OVERRIDE", str(default)))
    )


def _render_profile_command(args: argparse.Namespace) -> None:
    repository = _profile_repository_from_environment()
    if args.kind == "list":
        if args.profile is not None or args.output is not None:
            raise ProfileModelError("render-profile list accepts no profile/output")
        print("\n".join(repository.profiles()))
        return
    if args.profile is None:
        raise ProfileModelError(f"render-profile {args.kind} requires a profile")
    output = pathlib.Path(args.output) if args.output is not None else None
    if args.kind == "env":
        text = repository.render_environment(args.profile, output)
        if output is None:
            print(text, end="")
    elif output is None:
        raise ProfileModelError(f"render-profile {args.kind} requires an output")
    elif args.kind == "config":
        repository.render_config(args.profile, output)
    elif args.kind == "required":
        repository.render_pair(
            args.profile, "required-packages.txt", output
        )
    elif args.kind == "forbidden":
        repository.render_pair(
            args.profile, "forbidden-packages.txt", output
        )
    elif args.kind == "files":
        repository.render_files(args.profile, output)
    elif args.kind == "bundle":
        repository.render_bundle(args.profile, output)
    else:  # pragma: no cover - argparse owns this boundary
        raise ProfileModelError(f"unknown render kind: {args.kind}")


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    render = subparsers.add_parser("render-profile")
    render.add_argument(
        "kind",
        choices=("list", "env", "config", "required", "forbidden", "files", "bundle"),
    )
    render.add_argument("profile", nargs="?")
    render.add_argument("output", nargs="?")

    derive = subparsers.add_parser("derive-config")
    derive.add_argument("seed", type=pathlib.Path)
    derive.add_argument("required", type=pathlib.Path)
    derive.add_argument("forbidden", type=pathlib.Path)
    derive.add_argument("output", type=pathlib.Path)

    package_list = subparsers.add_parser("list-required-packages")
    package_list.add_argument("rules", type=pathlib.Path)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.command == "render-profile":
            _render_profile_command(args)
        elif args.command == "derive-config":
            derive_config(args.seed, args.required, args.forbidden, args.output)
        elif args.command == "list-required-packages":
            for package in sorted(load_required(args.rules).packages):
                print(package)
    except ProfileModelError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
