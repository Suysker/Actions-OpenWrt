#!/usr/bin/env python3
"""Resolve one OpenWrt profile's selected kernel from config and target metadata."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import pathlib
import re
import sys
from typing import Iterable, Mapping

from profile_model import ProfileModelError, parse_config


CHANNEL_SYMBOL = "CONFIG_TESTING_KERNEL"
CHANNEL_VARIABLES = {
    "stable": "KERNEL_PATCHVER",
    "testing": "KERNEL_TESTING_PATCHVER",
}
TARGET_RE = re.compile(r"[A-Za-z0-9_.+-]+")
SERIES_RE = re.compile(r"[0-9]+\.[0-9]+")
VERSION_RE = re.compile(r"[0-9]+\.[0-9]+\.[0-9]+")
SHA256_RE = re.compile(r"[0-9a-f]{64}")


class KernelSelectionError(RuntimeError):
    """The rendered config and selected Lean target metadata are inconsistent."""


@dataclass(frozen=True)
class KernelSelection:
    channel: str
    target: str
    series: str
    version: str
    source_sha256: str

    def lock_fields(self) -> dict[str, str]:
        return {
            "kernel_target": self.target,
            "kernel_channel": self.channel,
            "kernel_series": self.series,
            "kernel_version": self.version,
            "kernel_source_sha256": self.source_sha256,
        }


def selected_channel(config: Mapping[str, str]) -> str:
    """Map the one rendered Kconfig owner to a stable/testing channel."""

    value = config.get(CHANNEL_SYMBOL)
    if value == "y":
        return "testing"
    if value == "n":
        return "stable"
    if value is None:
        raise KernelSelectionError(
            f"rendered config must explicitly own {CHANNEL_SYMBOL}"
        )
    raise KernelSelectionError(
        f"{CHANNEL_SYMBOL} must be y or n, got {value!r}"
    )


def selected_series(target_makefile: str, channel: str) -> str:
    """Resolve exactly one channel-specific kernel series from a target Makefile."""

    variable = CHANNEL_VARIABLES.get(channel)
    if variable is None:
        raise KernelSelectionError(f"unsupported kernel channel: {channel!r}")
    matches = re.findall(
        rf"^{re.escape(variable)}\s*:?=\s*([0-9]+\.[0-9]+)\s*(?:#.*)?$",
        target_makefile,
        re.MULTILINE,
    )
    if len(matches) != 1:
        raise KernelSelectionError(
            f"expected one {variable} for {channel} channel, found {matches}"
        )
    return matches[0]


def exact_version_and_hash(kernel_metadata: str, series: str) -> tuple[str, str]:
    """Resolve Lean's exact point release and source hash for a selected series."""

    if not SERIES_RE.fullmatch(series):
        raise KernelSelectionError(f"invalid kernel series: {series!r}")
    suffixes = re.findall(
        rf"^LINUX_VERSION-{re.escape(series)}\s*:?=\s*(\.[0-9]+)\s*(?:#.*)?$",
        kernel_metadata,
        re.MULTILINE,
    )
    if len(suffixes) != 1:
        raise KernelSelectionError(
            f"expected one exact Linux version suffix for {series}, found {suffixes}"
        )
    version = series + suffixes[0]
    if not VERSION_RE.fullmatch(version):
        raise KernelSelectionError(f"invalid selected kernel version: {version!r}")
    hashes = re.findall(
        rf"^LINUX_KERNEL_HASH-{re.escape(version)}\s*:?=\s*([0-9a-f]{{64}})\s*(?:#.*)?$",
        kernel_metadata,
        re.MULTILINE,
    )
    if len(hashes) != 1 or not SHA256_RE.fullmatch(hashes[0]):
        raise KernelSelectionError(
            f"expected one Linux source hash for {version}, found {hashes}"
        )
    return version, hashes[0]


def resolve_from_text(
    config: Mapping[str, str],
    target: str,
    target_makefile: str,
    kernel_metadata: str,
) -> KernelSelection:
    if not TARGET_RE.fullmatch(target):
        raise KernelSelectionError(f"invalid kernel target: {target!r}")
    channel = selected_channel(config)
    series = selected_series(target_makefile, channel)
    version, source_sha256 = exact_version_and_hash(kernel_metadata, series)
    return KernelSelection(channel, target, series, version, source_sha256)


def resolve_from_tree(
    openwrt_root: pathlib.Path,
    target: str,
    config: Mapping[str, str],
) -> KernelSelection:
    """Resolve a selection from one checked-out Lean tree without network access."""

    if not TARGET_RE.fullmatch(target):
        raise KernelSelectionError(f"invalid kernel target: {target!r}")
    root = openwrt_root.resolve()
    target_path = root / "target" / "linux" / target / "Makefile"
    if not target_path.is_file():
        raise KernelSelectionError(f"target Makefile is missing: {target_path}")
    try:
        target_text = target_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise KernelSelectionError(f"cannot read target Makefile {target_path}: {exc}") from exc
    channel = selected_channel(config)
    series = selected_series(target_text, channel)
    metadata_path = root / "include" / f"kernel-{series}"
    if not metadata_path.is_file():
        raise KernelSelectionError(f"kernel metadata is missing: {metadata_path}")
    try:
        metadata = metadata_path.read_text(encoding="utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise KernelSelectionError(
            f"cannot read kernel metadata {metadata_path}: {exc}"
        ) from exc
    version, source_sha256 = exact_version_and_hash(metadata, series)
    return KernelSelection(channel, target, series, version, source_sha256)


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    target = subparsers.add_parser("target-series")
    target.add_argument("target_makefile", type=pathlib.Path)
    target.add_argument("channel", choices=tuple(CHANNEL_VARIABLES))

    tree = subparsers.add_parser("tree")
    tree.add_argument("openwrt_root", type=pathlib.Path)
    tree.add_argument("target")
    tree.add_argument("config", type=pathlib.Path)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        if args.command == "target-series":
            print(
                selected_series(
                    args.target_makefile.read_text(encoding="utf-8"), args.channel
                )
            )
            return 0
        selection = resolve_from_tree(
            args.openwrt_root, args.target, parse_config(args.config)
        )
        print(json.dumps(selection.lock_fields(), sort_keys=True))
        return 0
    except (
        OSError,
        UnicodeDecodeError,
        KernelSelectionError,
        ProfileModelError,
    ) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
