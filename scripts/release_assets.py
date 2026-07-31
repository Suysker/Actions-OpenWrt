#!/usr/bin/env python3
"""Assemble and transactionally verify collision-free dual-profile assets."""

from __future__ import annotations

import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile


class ReleaseError(RuntimeError):
    pass


def sha256(path: pathlib.Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def write_sums(directory: pathlib.Path) -> None:
    files = sorted(
        path for path in directory.iterdir() if path.is_file() and path.name != "SHA256SUMS"
    )
    (directory / "SHA256SUMS").write_text(
        "".join(f"{sha256(path)}  {path.name}\n" for path in files),
        encoding="utf-8",
    )


def parse_profile_input(value: str) -> tuple[str, pathlib.Path]:
    profile, separator, directory = value.partition("=")
    if not separator or not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", profile):
        raise ReleaseError(f"invalid profile input: {value}")
    path = pathlib.Path(directory).resolve()
    if not path.is_dir():
        raise ReleaseError(f"profile artifact directory is missing: {path}")
    return profile, path


def assemble(argv: list[str]) -> int:
    if len(argv) < 5:
        raise ReleaseError(
            "assemble requires <source-lock> <output-dir> <profile=directory>..."
        )
    source_lock = pathlib.Path(argv[2]).resolve()
    output = pathlib.Path(argv[3]).resolve()
    inputs = [parse_profile_input(value) for value in argv[4:]]
    if len(inputs) != len({profile for profile, _ in inputs}):
        raise ReleaseError("duplicate profile passed to release assembler")
    if not source_lock.is_file():
        raise ReleaseError(f"source lock is missing: {source_lock}")
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ReleaseError(f"release output directory is not empty: {output}")

    shutil.copy2(source_lock, output / "source-lock.json")
    lock_hash = sha256(source_lock)
    index: dict[str, object] = {
        "schema": 1,
        "source_lock_sha256": lock_hash,
        "profiles": {},
    }
    used = {"source-lock.json", "delivery-index.json", "SHA256SUMS"}

    for profile, directory in sorted(inputs):
        embedded_lock = directory / "source-lock.json"
        if not embedded_lock.is_file() or sha256(embedded_lock) != lock_hash:
            raise ReleaseError(f"{profile} does not contain the exact aggregate source lock")
        entries = []
        for source in sorted(path for path in directory.iterdir() if path.is_file()):
            if source.name == "source-lock.json":
                continue
            asset_name = f"{profile}--{source.name}"
            if asset_name in used:
                raise ReleaseError(f"release asset name collision: {asset_name}")
            used.add(asset_name)
            target = output / asset_name
            shutil.copy2(source, target)
            entries.append(
                {
                    "original_name": source.name,
                    "asset_name": asset_name,
                    "sha256": sha256(target),
                    "bytes": target.stat().st_size,
                }
            )
        if not entries:
            raise ReleaseError(f"profile {profile} has no release files")
        index["profiles"][profile] = {"files": entries}  # type: ignore[index]

    (output / "delivery-index.json").write_text(
        json.dumps(index, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    write_sums(output)
    print(f"Release asset set assembled: {output}")
    return 0


def read_top_sums(directory: pathlib.Path) -> dict[str, str]:
    path = directory / "SHA256SUMS"
    if not path.is_file():
        raise ReleaseError("top-level SHA256SUMS is missing")
    values: dict[str, str] = {}
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        match = re.fullmatch(r"([0-9a-f]{64})  ([^/]+)", raw)
        if not match:
            raise ReleaseError(f"invalid SHA256SUMS line {line_no}: {raw}")
        digest, name = match.groups()
        if name in values:
            raise ReleaseError(f"duplicate SHA256SUMS entry: {name}")
        values[name] = digest
    return values


def verify(argv: list[str]) -> int:
    if len(argv) != 3:
        raise ReleaseError("verify requires <release-directory>")
    directory = pathlib.Path(argv[2]).resolve()
    if not directory.is_dir():
        raise ReleaseError(f"release directory is missing: {directory}")
    sums = read_top_sums(directory)
    actual_names = {path.name for path in directory.iterdir() if path.is_file()}
    expected_names = set(sums) | {"SHA256SUMS"}
    if actual_names != expected_names:
        raise ReleaseError(
            f"release asset set differs from SHA256SUMS: extra={sorted(actual_names-expected_names)}, missing={sorted(expected_names-actual_names)}"
        )
    for name, expected in sums.items():
        actual = sha256(directory / name)
        if actual != expected:
            raise ReleaseError(f"release asset hash mismatch for {name}")

    index_path = directory / "delivery-index.json"
    source_lock = directory / "source-lock.json"
    index = json.loads(index_path.read_text(encoding="utf-8"))
    if index.get("schema") != 1:
        raise ReleaseError("unsupported delivery-index schema")
    if index.get("source_lock_sha256") != sha256(source_lock):
        raise ReleaseError("delivery index source-lock hash mismatch")

    indexed_assets: set[str] = set()
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        for profile, profile_entry in sorted(index.get("profiles", {}).items()):
            if not re.fullmatch(r"[a-z0-9][a-z0-9_-]*", profile):
                raise ReleaseError(f"invalid indexed profile: {profile}")
            reconstructed = root / profile
            reconstructed.mkdir()
            shutil.copy2(source_lock, reconstructed / "source-lock.json")
            original_names: set[str] = set()
            for entry in profile_entry.get("files", []):
                original = entry.get("original_name", "")
                asset = entry.get("asset_name", "")
                expected = entry.get("sha256", "")
                if not re.fullmatch(r"[^/]+", original) or not re.fullmatch(r"[^/]+", asset):
                    raise ReleaseError(f"unsafe delivery index path for {profile}")
                if original in original_names or asset in indexed_assets:
                    raise ReleaseError(f"duplicate delivery index name for {profile}: {original}/{asset}")
                original_names.add(original)
                indexed_assets.add(asset)
                source = directory / asset
                if not source.is_file() or sha256(source) != expected:
                    raise ReleaseError(f"indexed asset is missing or changed: {asset}")
                if source.stat().st_size != entry.get("bytes"):
                    raise ReleaseError(f"indexed asset size changed: {asset}")
                shutil.copy2(source, reconstructed / original)

            subprocess.run(
                [
                    "bash",
                    str(repo_root / "scripts/verify-firmware-artifacts.sh"),
                    profile,
                    str(reconstructed),
                    str(source_lock),
                ],
                check=True,
            )

    expected_indexed = actual_names - {
        "SHA256SUMS",
        "source-lock.json",
        "delivery-index.json",
    }
    if indexed_assets != expected_indexed:
        raise ReleaseError("delivery index does not cover the exact profile asset set")
    print(f"Release asset transaction verified: {directory}")
    return 0


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        raise ReleaseError("Usage: release_assets.py assemble|verify ...")
    if argv[1] == "assemble":
        return assemble(argv)
    if argv[1] == "verify":
        return verify(argv)
    raise ReleaseError(f"unknown release asset command: {argv[1]}")


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except (ReleaseError, OSError, ValueError, subprocess.CalledProcessError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        raise SystemExit(1)
