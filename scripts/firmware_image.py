#!/usr/bin/env python3
"""Validate a gzip payload followed by OpenWrt fwtool image metadata."""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import json
import pathlib
import struct
import sys
from typing import Any, Iterable
import zlib


FWIMAGE_MAGIC = 0x46577830
FWIMAGE_SIGNATURE = 0
FWIMAGE_INFO = 1
FWIMAGE_HEADER_SIZE = 8
FWIMAGE_TRAILER = struct.Struct(">IIB3sI")
METADATA_MAXLEN = 30 * 1024
SIGNATURE_MAXLEN = 1024
READ_SIZE = 1024 * 1024
DECOMPRESS_SIZE = 1024 * 1024


class FirmwareImageError(RuntimeError):
    """The image does not satisfy the gzip + fwtool byte contract."""


@dataclass(frozen=True)
class GzipStream:
    compressed_size: int
    uncompressed_size: int


@dataclass(frozen=True)
class FwtoolChunk:
    type: int
    data_start: int
    trailer_offset: int
    end: int
    size: int
    crc32: int

    @property
    def data_size(self) -> int:
        return self.size - FWIMAGE_TRAILER.size

    @property
    def name(self) -> str:
        return "info" if self.type == FWIMAGE_INFO else "signature"


@dataclass(frozen=True)
class FirmwareImage:
    path: pathlib.Path
    size: int
    gzip: GzipStream
    chunks: tuple[FwtoolChunk, ...]
    metadata: dict[str, Any] | None

    @property
    def has_signature(self) -> bool:
        return any(chunk.type == FWIMAGE_SIGNATURE for chunk in self.chunks)


def _inspect_gzip(path: pathlib.Path) -> GzipStream:
    decompressor = zlib.decompressobj(zlib.MAX_WBITS | 16)
    uncompressed_size = 0
    file_offset = 0

    try:
        handle = path.open("rb")
    except OSError as exc:
        raise FirmwareImageError(f"cannot open image: {exc}") from exc

    with handle:
        while True:
            chunk_start = file_offset
            block = handle.read(READ_SIZE)
            if not block:
                raise FirmwareImageError("gzip stream is truncated before its trailer")
            file_offset += len(block)
            pending = block
            pending_offset = chunk_start

            while pending:
                try:
                    output = decompressor.decompress(pending, DECOMPRESS_SIZE)
                except zlib.error as exc:
                    raise FirmwareImageError(f"gzip stream is invalid: {exc}") from exc
                uncompressed_size += len(output)

                if decompressor.eof:
                    compressed_size = (
                        pending_offset
                        + len(pending)
                        - len(decompressor.unused_data)
                    )
                    try:
                        uncompressed_size += len(decompressor.flush())
                    except zlib.error as exc:
                        raise FirmwareImageError(
                            f"gzip stream cannot be finalized: {exc}"
                        ) from exc
                    if compressed_size <= 0 or uncompressed_size <= 0:
                        raise FirmwareImageError("gzip stream has an empty payload")
                    return GzipStream(
                        compressed_size=compressed_size,
                        uncompressed_size=uncompressed_size,
                    )

                tail = decompressor.unconsumed_tail
                if not tail:
                    break
                consumed = len(pending) - len(tail)
                if consumed <= 0 and not output:
                    raise FirmwareImageError("gzip decoder made no forward progress")
                pending_offset += consumed
                pending = tail


def _parse_fwtool_chunks(
    path: pathlib.Path, gzip_end: int, image_size: int
) -> tuple[FwtoolChunk, ...]:
    cursor = image_size
    reverse_chunks: list[FwtoolChunk] = []

    try:
        handle = path.open("rb")
    except OSError as exc:
        raise FirmwareImageError(f"cannot open image trailer: {exc}") from exc

    with handle:
        while cursor > gzip_end:
            remaining = cursor - gzip_end
            if remaining < FWIMAGE_TRAILER.size:
                raise FirmwareImageError(
                    f"{remaining} unexplained byte(s) follow the gzip stream"
                )
            trailer_offset = cursor - FWIMAGE_TRAILER.size
            handle.seek(trailer_offset)
            raw = handle.read(FWIMAGE_TRAILER.size)
            if len(raw) != FWIMAGE_TRAILER.size:
                raise FirmwareImageError("fwtool trailer is truncated")
            magic, crc32, chunk_type, padding, size = FWIMAGE_TRAILER.unpack(raw)
            if magic != FWIMAGE_MAGIC:
                raise FirmwareImageError(
                    f"fwtool magic is invalid at offset {trailer_offset}"
                )
            if padding != b"\0\0\0":
                raise FirmwareImageError("fwtool trailer padding is not zero")
            if chunk_type not in (FWIMAGE_SIGNATURE, FWIMAGE_INFO):
                raise FirmwareImageError(f"unknown fwtool chunk type {chunk_type}")
            if size < FWIMAGE_TRAILER.size:
                raise FirmwareImageError(f"fwtool chunk size is too small: {size}")

            data_size = size - FWIMAGE_TRAILER.size
            maximum = (
                FWIMAGE_HEADER_SIZE + METADATA_MAXLEN
                if chunk_type == FWIMAGE_INFO
                else SIGNATURE_MAXLEN
            )
            if data_size > maximum:
                raise FirmwareImageError(
                    f"fwtool {'metadata' if chunk_type == FWIMAGE_INFO else 'signature'} "
                    f"exceeds {maximum} bytes"
                )
            if chunk_type == FWIMAGE_INFO and data_size <= FWIMAGE_HEADER_SIZE:
                raise FirmwareImageError("fwtool metadata payload is empty")
            if chunk_type == FWIMAGE_SIGNATURE and data_size == 0:
                raise FirmwareImageError("fwtool signature payload is empty")

            data_start = cursor - size
            if data_start < gzip_end:
                raise FirmwareImageError("fwtool chunk overlaps the gzip stream")
            reverse_chunks.append(
                FwtoolChunk(
                    type=chunk_type,
                    data_start=data_start,
                    trailer_offset=trailer_offset,
                    end=cursor,
                    size=size,
                    crc32=crc32,
                )
            )
            cursor = data_start

    chunks = tuple(reversed(reverse_chunks))
    types = tuple(chunk.type for chunk in chunks)
    if types not in (
        (FWIMAGE_INFO,),
        (FWIMAGE_SIGNATURE,),
        (FWIMAGE_INFO, FWIMAGE_SIGNATURE),
    ):
        raise FirmwareImageError(
            "fwtool chunks must be unique info/signature chunks in canonical order"
        )
    return chunks


def _raw_crc32_checkpoints(
    path: pathlib.Path, offsets: Iterable[int]
) -> dict[int, int]:
    ordered = sorted(set(offsets))
    results: dict[int, int] = {}
    standard_crc = 0
    position = 0

    try:
        handle = path.open("rb")
    except OSError as exc:
        raise FirmwareImageError(f"cannot read image for CRC validation: {exc}") from exc

    with handle:
        for target in ordered:
            if target < position:
                raise FirmwareImageError("fwtool CRC offsets are not monotonic")
            remaining = target - position
            while remaining:
                block = handle.read(min(READ_SIZE, remaining))
                if not block:
                    raise FirmwareImageError("image ended during fwtool CRC validation")
                standard_crc = zlib.crc32(block, standard_crc)
                position += len(block)
                remaining -= len(block)
            results[target] = standard_crc ^ 0xFFFFFFFF
    return results


def _read_metadata(
    path: pathlib.Path, chunk: FwtoolChunk
) -> dict[str, Any]:
    try:
        with path.open("rb") as handle:
            handle.seek(chunk.data_start)
            payload = handle.read(chunk.data_size)
    except OSError as exc:
        raise FirmwareImageError(f"cannot read fwtool metadata: {exc}") from exc
    if len(payload) != chunk.data_size:
        raise FirmwareImageError("fwtool metadata is truncated")
    if payload[:4] != b"\0" * 4:
        raise FirmwareImageError("fwtool metadata header version is unsupported")
    try:
        decoded = payload[FWIMAGE_HEADER_SIZE:].decode("utf-8")
    except UnicodeDecodeError as exc:
        raise FirmwareImageError("fwtool metadata is not UTF-8") from exc
    try:
        metadata = json.loads(decoded)
    except json.JSONDecodeError as exc:
        raise FirmwareImageError(f"fwtool metadata is not valid JSON: {exc}") from exc
    if not isinstance(metadata, dict) or not metadata:
        raise FirmwareImageError("fwtool metadata must be a non-empty JSON object")
    return metadata


def inspect_image(path: pathlib.Path) -> FirmwareImage:
    resolved = path.resolve()
    if not resolved.is_file():
        raise FirmwareImageError(f"image is not a regular file: {resolved}")
    try:
        image_size = resolved.stat().st_size
    except OSError as exc:
        raise FirmwareImageError(f"cannot stat image: {exc}") from exc

    gzip = _inspect_gzip(resolved)
    if gzip.compressed_size == image_size:
        return FirmwareImage(
            path=resolved,
            size=image_size,
            gzip=gzip,
            chunks=(),
            metadata=None,
        )
    if gzip.compressed_size > image_size:
        raise FirmwareImageError("gzip stream extends beyond the image")

    chunks = _parse_fwtool_chunks(resolved, gzip.compressed_size, image_size)
    checkpoints = _raw_crc32_checkpoints(
        resolved, (chunk.trailer_offset for chunk in chunks)
    )
    for chunk in chunks:
        observed = checkpoints[chunk.trailer_offset]
        if chunk.crc32 != observed:
            raise FirmwareImageError(
                f"fwtool {chunk.name} CRC mismatch: "
                f"stored={chunk.crc32:08x}, computed={observed:08x}"
            )

    info = next((chunk for chunk in chunks if chunk.type == FWIMAGE_INFO), None)
    metadata = _read_metadata(resolved, info) if info is not None else None
    return FirmwareImage(
        path=resolved,
        size=image_size,
        gzip=gzip,
        chunks=chunks,
        metadata=metadata,
    )


def report_lines(image: FirmwareImage) -> list[str]:
    metadata_version_value = (
        image.metadata.get("metadata_version", "unknown")
        if image.metadata is not None
        else "none"
    )
    metadata_version = json.dumps(
        str(metadata_version_value), ensure_ascii=True
    )[1:-1]
    return [
        "firmware-image-v1",
        f"image={image.path.name}",
        f"image_bytes={image.size}",
        f"gzip_compressed_bytes={image.gzip.compressed_size}",
        f"gzip_uncompressed_bytes={image.gzip.uncompressed_size}",
        f"fwtool_chunks={len(image.chunks)}",
        f"fwtool_info={int(image.metadata is not None)}",
        f"fwtool_signature={int(image.has_signature)}",
        f"fwtool_metadata_version={metadata_version}",
    ]


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("image", type=pathlib.Path)
    return parser


def main(argv: list[str] | None = None) -> int:
    args = build_parser().parse_args(argv)
    try:
        image = inspect_image(args.image)
    except FirmwareImageError as exc:
        print(f"::error::Firmware image contract failed: {exc}", file=sys.stderr)
        return 1
    print("\n".join(report_lines(image)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
