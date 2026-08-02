#!/usr/bin/env python3
"""Parse Git/OpenWrt kernel patches through one strict path-safety contract."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import pathlib
import re
import sys
from typing import Iterable


class KernelPatchError(RuntimeError):
    """A patch is malformed, empty or contains an unsafe target path."""


@dataclass(frozen=True)
class KernelPatch:
    format: str
    touched_paths: tuple[str, ...]


def _safe_relative(raw: str, prefix: str, label: str) -> str | None:
    token = raw.split("\t", 1)[0]
    if " " in token:
        raise KernelPatchError(f"{label} contains an unsupported space: {raw!r}")
    if token == "/dev/null":
        return None
    expected_prefix = prefix + "/"
    if not token.startswith(expected_prefix):
        raise KernelPatchError(
            f"{label} must use {expected_prefix!r} or /dev/null: {raw!r}"
        )
    value = token[len(expected_prefix) :]
    if not value or "\\" in value or any(ord(char) < 32 for char in value):
        raise KernelPatchError(f"{label} is unsafe: {raw!r}")
    path = pathlib.PurePosixPath(value)
    if (
        path.is_absolute()
        or ".." in path.parts
        or "." in path.parts
        or str(path) != value
    ):
        raise KernelPatchError(f"{label} escapes or is not normalized: {raw!r}")
    return value


def inspect_patch(payload: bytes | str) -> KernelPatch:
    if isinstance(payload, bytes):
        if b"\x00" in payload:
            raise KernelPatchError("patch contains NUL")
        try:
            text = payload.decode("utf-8")
        except UnicodeDecodeError as exc:
            raise KernelPatchError(f"patch is not UTF-8: {exc}") from exc
    else:
        if "\x00" in payload:
            raise KernelPatchError("patch contains NUL")
        text = payload

    declared: set[str] = set()
    paired: set[str] = set()
    git_headers = 0
    pairs = 0
    pending_old: str | None | object = _MISSING

    for line_no, line in enumerate(text.splitlines(), 1):
        if line.startswith("diff --git "):
            if pending_old is not _MISSING:
                raise KernelPatchError(
                    f"line {line_no}: diff header interrupts an unpaired --- header"
                )
            fields = line.split()
            if len(fields) != 4:
                raise KernelPatchError(f"line {line_no}: malformed diff --git header")
            old = _safe_relative(fields[2], "a", f"line {line_no} old Git path")
            new = _safe_relative(fields[3], "b", f"line {line_no} new Git path")
            if old is None or new is None:
                raise KernelPatchError(f"line {line_no}: Git header cannot use /dev/null")
            declared.update((old, new))
            git_headers += 1
            continue

        if line.startswith("--- "):
            if pending_old is not _MISSING:
                raise KernelPatchError(f"line {line_no}: previous --- header is unpaired")
            pending_old = _safe_relative(
                line[4:], "a", f"line {line_no} old unified path"
            )
            continue

        if line.startswith("+++ "):
            if pending_old is _MISSING:
                raise KernelPatchError(f"line {line_no}: +++ header has no paired --- header")
            new = _safe_relative(
                line[4:], "b", f"line {line_no} new unified path"
            )
            if pending_old is None and new is None:
                raise KernelPatchError(f"line {line_no}: both unified paths are /dev/null")
            if pending_old is not None:
                paired.add(pending_old)
            if new is not None:
                paired.add(new)
            pending_old = _MISSING
            pairs += 1

    if pending_old is not _MISSING:
        raise KernelPatchError("patch ends with an unpaired --- header")
    if not pairs or not paired:
        raise KernelPatchError("patch contains no paired unified file headers")
    if git_headers and declared != paired:
        missing = sorted(declared - paired)
        extra = sorted(paired - declared)
        raise KernelPatchError(
            f"Git and unified paths differ (missing={missing}, extra={extra})"
        )
    return KernelPatch("git" if git_headers else "quilt", tuple(sorted(paired)))


_MISSING = object()


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("command", choices=("paths", "format", "validate"))
    parser.add_argument("patches", nargs="+", type=pathlib.Path)
    return parser


def main(argv: Iterable[str] | None = None) -> int:
    args = _build_parser().parse_args(argv)
    try:
        inspected = [inspect_patch(path.read_bytes()) for path in args.patches]
        if args.command == "paths":
            paths = sorted(
                {path for patch in inspected for path in patch.touched_paths}
            )
            print("\n".join(paths))
        elif args.command == "format":
            print("\n".join(patch.format for patch in inspected))
        else:
            print(f"Validated {len(inspected)} kernel patch(es).")
        return 0
    except (OSError, KernelPatchError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
