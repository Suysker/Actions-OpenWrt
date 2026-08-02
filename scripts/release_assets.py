#!/usr/bin/env python3
"""Assemble and transactionally verify concise dual-profile Release assets."""

from __future__ import annotations

import fnmatch
import gzip
import hashlib
import json
import pathlib
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
from typing import Any

import source_lock as source_lock_model


class ReleaseError(RuntimeError):
    pass


RELEASE_ID_RE = re.compile(r"\d{4}\.\d{2}\.\d{2}-r\d+(?:\.\d+)?")
SHA256_RE = re.compile(r"[0-9a-f]{64}")


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
    if not separator or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", profile):
        raise ReleaseError(f"invalid profile input: {value}")
    path = pathlib.Path(directory).resolve()
    if not path.is_dir():
        raise ReleaseError(f"profile artifact directory is missing: {path}")
    return profile, path


def verify_profile_firmware(
    profile: str, directory: pathlib.Path, lock_path: pathlib.Path
) -> None:
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    subprocess.run(
        [
            "bash",
            str(repo_root / "scripts/verify-firmware-artifacts.sh"),
            profile,
            str(directory),
            str(lock_path),
        ],
        check=True,
    )


def primary_image(
    profile: str, directory: pathlib.Path, lock: dict[str, Any]
) -> pathlib.Path:
    entry = lock["profiles"].get(profile)
    pattern = entry.get("image_pattern") if isinstance(entry, dict) else None
    if not isinstance(pattern, str) or not pattern:
        raise ReleaseError(f"source-lock has no image pattern for {profile}")
    matches = sorted(
        path
        for path in directory.iterdir()
        if path.is_file() and fnmatch.fnmatch(path.name, pattern)
    )
    if len(matches) != 1:
        raise ReleaseError(
            f"expected one primary image for {profile} matching {pattern}, found {len(matches)}"
        )
    return matches[0]


def image_role(name: str) -> str:
    for role in (
        "combined-efi",
        "sysupgrade",
        "factory",
        "rootfs",
        "initramfs",
    ):
        if role in name.lower():
            return role
    return "firmware"


def image_suffix(name: str) -> str:
    for suffix in (".img.gz", ".tar.gz", ".bin", ".itb", ".ubi", ".img"):
        if name.endswith(suffix):
            return suffix
    raise ReleaseError(f"unsupported primary image extension: {name}")


def create_full_bundle(directory: pathlib.Path, target: pathlib.Path) -> None:
    files = sorted(path for path in directory.iterdir() if path.is_file())
    if not files:
        raise ReleaseError(f"profile delivery contains no files: {directory}")
    folded: set[str] = set()
    for source in files:
        key = source.name.casefold()
        if key in folded:
            raise ReleaseError(
                f"profile delivery is not portable across case-insensitive filesystems: {source.name}"
            )
        folded.add(key)
    with target.open("wb") as raw:
        with gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0) as compressed:
            with tarfile.open(
                fileobj=compressed, mode="w", format=tarfile.PAX_FORMAT
            ) as archive:
                for source in files:
                    info = archive.gettarinfo(str(source), arcname=source.name)
                    info.uid = 0
                    info.gid = 0
                    info.uname = ""
                    info.gname = ""
                    info.mtime = 0
                    with source.open("rb") as handle:
                        archive.addfile(info, handle)


def asset_record(path: pathlib.Path) -> dict[str, object]:
    return {
        "asset_name": path.name,
        "sha256": sha256(path),
        "bytes": path.stat().st_size,
    }


def assemble(argv: list[str]) -> int:
    if len(argv) < 6:
        raise ReleaseError(
            "assemble requires <source-lock> <output-dir> <release-id> <profile=directory>..."
        )
    source_lock = pathlib.Path(argv[2]).resolve()
    output = pathlib.Path(argv[3]).resolve()
    release_id = argv[4]
    if not RELEASE_ID_RE.fullmatch(release_id):
        raise ReleaseError(f"invalid release id: {release_id}")
    inputs = [parse_profile_input(value) for value in argv[5:]]
    if len(inputs) != len({profile for profile, _ in inputs}):
        raise ReleaseError("duplicate profile passed to release assembler")
    if not source_lock.is_file():
        raise ReleaseError(f"source lock is missing: {source_lock}")
    lock = source_lock_model.load_lock(source_lock)
    locked_profiles = set(lock["profiles"])
    supplied_profiles = {profile for profile, _ in inputs}
    if supplied_profiles != locked_profiles:
        raise ReleaseError(
            "release profiles differ from source-lock: "
            f"extra={sorted(supplied_profiles-locked_profiles)}, "
            f"missing={sorted(locked_profiles-supplied_profiles)}"
        )
    output.mkdir(parents=True, exist_ok=True)
    if any(output.iterdir()):
        raise ReleaseError(f"release output directory is not empty: {output}")

    for profile, directory in sorted(inputs):
        verify_profile_firmware(profile, directory, source_lock)

    shutil.copy2(source_lock, output / "source-lock.json")
    lock_hash = sha256(source_lock)
    index: dict[str, object] = {
        "schema": 2,
        "release_id": release_id,
        "source_lock_sha256": lock_hash,
        "profiles": {},
    }
    used = {"source-lock.json", "release-index.json", "SHA256SUMS"}

    for profile, directory in sorted(inputs):
        embedded_lock = directory / "source-lock.json"
        if not embedded_lock.is_file() or sha256(embedded_lock) != lock_hash:
            raise ReleaseError(f"{profile} does not contain the exact aggregate source lock")
        source_image = primary_image(profile, directory, lock)
        base = f"openwrt-{profile}-{release_id}"
        image_name = f"{base}-{image_role(source_image.name)}{image_suffix(source_image.name)}"
        bundle_name = f"{base}-full.tar.gz"
        for name in (image_name, bundle_name):
            if name in used:
                raise ReleaseError(f"release asset name collision: {name}")
            used.add(name)

        image_target = output / image_name
        bundle_target = output / bundle_name
        shutil.copy2(source_image, image_target)
        create_full_bundle(directory, bundle_target)
        index["profiles"][profile] = {  # type: ignore[index]
            "primary_image": {
                "original_name": source_image.name,
                **asset_record(image_target),
            },
            "full_bundle": asset_record(bundle_target),
        }

    (output / "release-index.json").write_text(
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


def checked_asset(
    directory: pathlib.Path, record: object, label: str
) -> pathlib.Path:
    if not isinstance(record, dict):
        raise ReleaseError(f"invalid {label} record")
    name = record.get("asset_name")
    digest = record.get("sha256")
    size = record.get("bytes")
    if not isinstance(name, str) or not re.fullmatch(r"[^/]+", name):
        raise ReleaseError(f"invalid {label} asset name")
    if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
        raise ReleaseError(f"invalid {label} asset digest")
    if not isinstance(size, int) or size < 0:
        raise ReleaseError(f"invalid {label} asset size")
    path = directory / name
    if not path.is_file() or path.stat().st_size != size or sha256(path) != digest:
        raise ReleaseError(f"indexed asset is missing or changed: {name}")
    return path


def extract_full_bundle(bundle: pathlib.Path, output: pathlib.Path) -> None:
    names: set[str] = set()
    folded: set[str] = set()
    with tarfile.open(bundle, mode="r:gz") as archive:
        members = archive.getmembers()
        if not members:
            raise ReleaseError(f"full bundle is empty: {bundle.name}")
        for member in members:
            pure = pathlib.PurePosixPath(member.name)
            key = member.name.casefold()
            if (
                not member.isfile()
                or pure.name != member.name
                or member.name in names
                or key in folded
            ):
                raise ReleaseError(f"unsafe or duplicate full-bundle member: {member.name}")
            names.add(member.name)
            folded.add(key)
            source = archive.extractfile(member)
            if source is None:
                raise ReleaseError(f"cannot read full-bundle member: {member.name}")
            with source, (output / member.name).open("wb") as target:
                shutil.copyfileobj(source, target)


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
            "release asset set differs from SHA256SUMS: "
            f"extra={sorted(actual_names-expected_names)}, "
            f"missing={sorted(expected_names-actual_names)}"
        )
    for name, expected in sums.items():
        if sha256(directory / name) != expected:
            raise ReleaseError(f"release asset hash mismatch for {name}")

    index_path = directory / "release-index.json"
    source_lock = directory / "source-lock.json"
    lock = source_lock_model.load_lock(source_lock)
    index = json.loads(index_path.read_text(encoding="utf-8"))
    if not isinstance(index, dict) or index.get("schema") != 2:
        raise ReleaseError("unsupported release-index schema")
    release_id = index.get("release_id")
    if not isinstance(release_id, str) or not RELEASE_ID_RE.fullmatch(release_id):
        raise ReleaseError("release index has an invalid release id")
    if index.get("source_lock_sha256") != sha256(source_lock):
        raise ReleaseError("release index source-lock hash mismatch")

    profile_entries = index.get("profiles")
    if not isinstance(profile_entries, dict):
        raise ReleaseError("release index profiles are invalid")
    if set(profile_entries) != set(lock["profiles"]):
        raise ReleaseError("release index profiles differ from source-lock")

    indexed_assets: set[str] = set()
    with tempfile.TemporaryDirectory() as temporary:
        root = pathlib.Path(temporary)
        for profile, profile_entry in sorted(profile_entries.items()):
            if (
                not re.fullmatch(r"[a-z0-9][a-z0-9-]*", profile)
                or not isinstance(profile_entry, dict)
            ):
                raise ReleaseError(f"invalid release profile entry: {profile}")
            image_record = profile_entry.get("primary_image")
            bundle_record = profile_entry.get("full_bundle")
            image = checked_asset(directory, image_record, f"{profile} primary image")
            bundle = checked_asset(directory, bundle_record, f"{profile} full bundle")
            expected_base = f"openwrt-{profile}-{release_id}"
            original = image_record.get("original_name")  # type: ignore[union-attr]
            if not isinstance(original, str) or not re.fullmatch(r"[^/]+", original):
                raise ReleaseError(f"invalid original primary image for {profile}")
            expected_image = (
                f"{expected_base}-{image_role(original)}{image_suffix(original)}"
            )
            if image.name != expected_image or bundle.name != f"{expected_base}-full.tar.gz":
                raise ReleaseError(f"non-canonical Release asset name for {profile}")
            if image.name in indexed_assets or bundle.name in indexed_assets:
                raise ReleaseError(f"duplicate indexed Release asset for {profile}")
            indexed_assets.update((image.name, bundle.name))

            reconstructed = root / profile
            reconstructed.mkdir()
            extract_full_bundle(bundle, reconstructed)
            bundled_image = reconstructed / original
            if not bundled_image.is_file() or sha256(bundled_image) != sha256(image):
                raise ReleaseError(
                    f"direct primary image differs from the {profile} full bundle"
                )
            verify_profile_firmware(profile, reconstructed, source_lock)

    expected_indexed = actual_names - {
        "SHA256SUMS",
        "source-lock.json",
        "release-index.json",
    }
    if indexed_assets != expected_indexed:
        raise ReleaseError("release index does not cover the exact asset set")
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
    except (
        ReleaseError,
        source_lock_model.ResolutionError,
        OSError,
        ValueError,
        subprocess.CalledProcessError,
        tarfile.TarError,
    ) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        raise SystemExit(1)
