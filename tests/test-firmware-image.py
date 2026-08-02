#!/usr/bin/env python3
"""Exercise the shared gzip + OpenWrt fwtool image validator."""

from __future__ import annotations

import gzip
import importlib.util
import json
import pathlib
import struct
import subprocess
import sys
import tempfile
import zlib


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "firmware_image", ROOT / "scripts/firmware_image.py"
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def append_chunk(image: bytes, chunk_type: int, payload: bytes) -> bytes:
    crc32 = zlib.crc32(image + payload) ^ 0xFFFFFFFF
    trailer = struct.pack(
        ">IIB3sI",
        MODULE.FWIMAGE_MAGIC,
        crc32,
        chunk_type,
        b"\0\0\0",
        len(payload) + MODULE.FWIMAGE_TRAILER.size,
    )
    return image + payload + trailer


def metadata_payload(value: object) -> bytes:
    encoded = json.dumps(value, separators=(",", ":"), sort_keys=True).encode()
    return b"\0" * MODULE.FWIMAGE_HEADER_SIZE + encoded


def write(path: pathlib.Path, value: bytes) -> pathlib.Path:
    path.write_bytes(value)
    return path


def expect_error(path: pathlib.Path, fragment: str) -> None:
    try:
        MODULE.inspect_image(path)
    except MODULE.FirmwareImageError as exc:
        assert fragment in str(exc), str(exc)
    else:
        raise AssertionError(f"accepted invalid image; expected {fragment!r}")


payload = (b"OpenWrt firmware payload\n" * 4096) + bytes(range(256))
gzip_payload = gzip.compress(payload, compresslevel=6, mtime=0)
metadata = {
    "metadata_version": "1.0",
    "supported_devices": ["fixture,router"],
    "version": {"dist": "OpenWrt", "target": "fixture/device"},
}

with tempfile.TemporaryDirectory(prefix="firmware-image-") as raw_directory:
    directory = pathlib.Path(raw_directory)

    crc_fixture = write(directory / "crc.bin", b"123456789")
    assert MODULE._raw_crc32_checkpoints(crc_fixture, [9])[9] == 0x340BC6D9

    info_image = append_chunk(
        gzip_payload, MODULE.FWIMAGE_INFO, metadata_payload(metadata)
    )
    info_path = write(directory / "info.img.gz", info_image)
    inspected = MODULE.inspect_image(info_path)
    assert inspected.gzip.compressed_size == len(gzip_payload)
    assert inspected.gzip.uncompressed_size == len(payload)
    assert [chunk.name for chunk in inspected.chunks] == ["info"]
    assert inspected.metadata == metadata
    assert not inspected.has_signature

    signed_image = append_chunk(
        info_image, MODULE.FWIMAGE_SIGNATURE, b"fixture-ucert"
    )
    signed_path = write(directory / "signed.img.gz", signed_image)
    signed = MODULE.inspect_image(signed_path)
    assert [chunk.name for chunk in signed.chunks] == ["info", "signature"]
    assert signed.has_signature

    completed = subprocess.run(
        [sys.executable, ROOT / "scripts/firmware_image.py", signed_path],
        check=True,
        capture_output=True,
        text=True,
    )
    assert completed.stdout.startswith("firmware-image-v1\n")
    assert "fwtool_signature=1\n" in completed.stdout
    assert "fwtool_metadata_version=1.0\n" in completed.stdout

    pure = MODULE.inspect_image(write(directory / "pure-gzip.img.gz", gzip_payload))
    assert pure.chunks == ()
    assert pure.metadata is None
    assert not pure.has_signature
    expect_error(
        write(directory / "truncated-gzip.img.gz", gzip_payload[:-4]),
        "gzip stream is truncated",
    )
    expect_error(
        write(directory / "garbage.img.gz", gzip_payload + b"x" * 16),
        "fwtool magic is invalid",
    )

    bad_crc = bytearray(info_image)
    bad_crc[-12] ^= 1
    expect_error(
        write(directory / "bad-crc.img.gz", bytes(bad_crc)),
        "CRC mismatch",
    )

    bad_padding = bytearray(info_image)
    bad_padding[-7] = 1
    expect_error(
        write(directory / "bad-padding.img.gz", bytes(bad_padding)),
        "padding is not zero",
    )

    unknown_type = bytearray(info_image)
    unknown_type[-8] = 9
    expect_error(
        write(directory / "unknown-type.img.gz", bytes(unknown_type)),
        "unknown fwtool chunk type 9",
    )

    bad_size = bytearray(info_image)
    bad_size[-4:] = struct.pack(">I", len(info_image) + 1)
    expect_error(
        write(directory / "bad-size.img.gz", bytes(bad_size)),
        "overlaps the gzip stream",
    )

    invalid_json = append_chunk(
        gzip_payload,
        MODULE.FWIMAGE_INFO,
        b"\0" * MODULE.FWIMAGE_HEADER_SIZE + b"{not-json}",
    )
    expect_error(
        write(directory / "invalid-json.img.gz", invalid_json),
        "not valid JSON",
    )

    bad_header = append_chunk(
        gzip_payload,
        MODULE.FWIMAGE_INFO,
        b"\1" + b"\0" * (MODULE.FWIMAGE_HEADER_SIZE - 1) + b"{}",
    )
    expect_error(
        write(directory / "bad-header.img.gz", bad_header),
        "header version is unsupported",
    )

    # Match official fwtool extraction semantics: version 0 is required,
    # while flags are opaque format data covered by the cumulative CRC.
    flagged_header = append_chunk(
        gzip_payload,
        MODULE.FWIMAGE_INFO,
        b"\0" * 4 + b"\0\0\0\1" + json.dumps(metadata).encode(),
    )
    assert MODULE.inspect_image(
        write(directory / "flagged-header.img.gz", flagged_header)
    ).metadata == metadata

    signature_only = append_chunk(
        gzip_payload, MODULE.FWIMAGE_SIGNATURE, b"fixture-ucert"
    )
    signature_only_result = MODULE.inspect_image(
        write(directory / "signature-only.img.gz", signature_only)
    )
    assert [chunk.name for chunk in signature_only_result.chunks] == ["signature"]
    assert signature_only_result.metadata is None
    assert signature_only_result.has_signature

    duplicate_info = append_chunk(
        info_image, MODULE.FWIMAGE_INFO, metadata_payload(metadata)
    )
    expect_error(
        write(directory / "duplicate-info.img.gz", duplicate_info),
        "canonical order",
    )

    signature_then_info = append_chunk(
        signature_only, MODULE.FWIMAGE_INFO, metadata_payload(metadata)
    )
    expect_error(
        write(directory / "signature-then-info.img.gz", signature_then_info),
        "canonical order",
    )

    oversized_metadata = append_chunk(
        gzip_payload,
        MODULE.FWIMAGE_INFO,
        b"\0" * MODULE.FWIMAGE_HEADER_SIZE
        + b" " * (MODULE.METADATA_MAXLEN + 1),
    )
    expect_error(
        write(directory / "oversized-metadata.img.gz", oversized_metadata),
        "exceeds",
    )

print("Firmware image contract tests passed.")
