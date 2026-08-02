#!/usr/bin/env python3
"""Read one field directly from a kernel module's ELF .modinfo section."""

from __future__ import annotations

import os
import pathlib
import re
import shutil
import subprocess
import sys


class ModuleMetadataError(RuntimeError):
    """The module cannot provide an unambiguous metadata value."""


STRING_LINE = re.compile(r"^\s*\[\s*[0-9A-Fa-f]+\]\s+(.*)$")
FIELD_NAME = re.compile(r"[A-Za-z0-9_.-]+")


def parse_string_dump(output: str) -> dict[str, list[str]]:
    metadata: dict[str, list[str]] = {}
    for raw in output.splitlines():
        match = STRING_LINE.match(raw)
        if match is None:
            continue
        entry = match.group(1)
        key, separator, value = entry.partition("=")
        if not separator or not FIELD_NAME.fullmatch(key):
            continue
        metadata.setdefault(key, []).append(value)
    return metadata


def read_modinfo(module: pathlib.Path) -> dict[str, list[str]]:
    try:
        resolved = module.resolve(strict=True)
    except OSError as exc:
        raise ModuleMetadataError(f"cannot resolve module {module}: {exc}") from exc
    if not resolved.is_file():
        raise ModuleMetadataError(f"module is not a regular file: {resolved}")

    readelf = shutil.which("readelf")
    if readelf is None:
        raise ModuleMetadataError("GNU readelf is not available on PATH")
    environment = os.environ.copy()
    environment.update({"LC_ALL": "C", "DEBUGINFOD_URLS": ""})
    completed = subprocess.run(
        [readelf, "--wide", "--string-dump=.modinfo", str(resolved)],
        check=False,
        capture_output=True,
        text=True,
        env=environment,
    )
    if completed.returncode != 0:
        detail = (completed.stderr or completed.stdout).strip()
        raise ModuleMetadataError(
            f"readelf failed for {resolved} (exit {completed.returncode}): "
            f"{detail or 'no diagnostic'}"
        )
    metadata = parse_string_dump(completed.stdout)
    if not metadata:
        detail = completed.stderr.strip()
        raise ModuleMetadataError(
            f"module {resolved} has no readable .modinfo entries"
            + (f": {detail}" if detail else "")
        )
    return metadata


def field_value(module: pathlib.Path, field: str) -> str:
    if FIELD_NAME.fullmatch(field) is None:
        raise ModuleMetadataError(f"invalid module metadata field: {field!r}")
    values = read_modinfo(module).get(field, [])
    if not values:
        raise ModuleMetadataError(f"module {module} has no .modinfo field {field!r}")
    unique = set(values)
    if len(unique) != 1:
        raise ModuleMetadataError(
            f"module {module} has conflicting .modinfo field {field!r}: "
            + ", ".join(repr(value) for value in sorted(unique))
        )
    return values[0]


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "Usage: kernel_module_metadata.py <module.ko> <field>",
            file=sys.stderr,
        )
        return 2
    try:
        value = field_value(pathlib.Path(argv[1]), argv[2])
    except ModuleMetadataError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    print(value)
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
