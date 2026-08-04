#!/usr/bin/env python3
"""Resolve repository compatibility patches for the selected kernel series."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import pathlib
import re
import sys


class SelectedKernelCompatibilityError(RuntimeError):
    """The capability policy or selected patch stack is ambiguous."""


@dataclass(frozen=True)
class Variant:
    series: str
    patch: pathlib.Path
    install_directory: str
    install_name: str
    origin_url: str
    origin_commit: str
    sha256: str


@dataclass(frozen=True)
class Capability:
    id: str
    semantic_rule: str
    source_path: str
    markers: tuple[str, ...]
    prerequisite_markers: tuple[str, ...]
    upstream_from: tuple[int, int]
    variants: dict[str, Variant]


@dataclass(frozen=True)
class Resolution:
    status: str
    capability: Capability
    variant: Variant | None


CAPABILITY_FIELDS = {
    "id",
    "semantic_rule",
    "source_path",
    "upstream_from",
    "prerequisite_patch_markers",
    "variants",
}
VARIANT_FIELDS = {
    "patch",
    "install_directory",
    "install_name",
    "adapted_for",
    "origin_url",
    "origin_commit",
}


def _line(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or "\n" in value or "\r" in value:
        raise SelectedKernelCompatibilityError(f"{label} must be one non-empty line")
    return value.strip()


def _series(value: object, label: str) -> tuple[int, int]:
    text = _line(value, label)
    match = re.fullmatch(r"([0-9]+)\.([0-9]+)", text)
    if not match:
        raise SelectedKernelCompatibilityError(f"invalid {label}: {text!r}")
    return int(match.group(1)), int(match.group(2))


def _normalized(value: str) -> str:
    return " ".join(value.split())


def _list_of_lines(value: object, label: str) -> tuple[str, ...]:
    if not isinstance(value, list) or not value:
        raise SelectedKernelCompatibilityError(f"{label} must be a non-empty list")
    lines = tuple(_normalized(_line(item, label)) for item in value)
    if len(set(lines)) != len(lines):
        raise SelectedKernelCompatibilityError(f"{label} contains duplicates")
    return lines


def _added_payload(paths: list[pathlib.Path]) -> str:
    added: list[str] = []
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except (OSError, UnicodeDecodeError) as exc:
            raise SelectedKernelCompatibilityError(f"cannot read kernel patch {path}: {exc}") from exc
        added.extend(
            _normalized(line[1:])
            for line in lines
            if line.startswith("+") and not line.startswith("+++")
        )
    return "\n".join(added)


def _selected_patch_stack(openwrt_root: pathlib.Path, series: str) -> list[pathlib.Path]:
    generic = openwrt_root / "target/linux/generic"
    paths: list[pathlib.Path] = []
    for layer in ("backport", "pending", "hack"):
        directory = generic / f"{layer}-{series}"
        if directory.is_dir():
            paths.extend(sorted(directory.glob("*.patch")))
    return paths


def _semantic_markers(repo_root: pathlib.Path, rule_name: str, source_path: str) -> tuple[str, ...]:
    semantics_path = repo_root / "profiles/common/semantics.json"
    try:
        document = json.loads(semantics_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SelectedKernelCompatibilityError(f"cannot read profile semantics: {exc}") from exc
    rules = document.get("source") if isinstance(document, dict) else None
    if not isinstance(rules, list):
        raise SelectedKernelCompatibilityError("profile semantics has no source list")
    matches = [item for item in rules if isinstance(item, dict) and item.get("name") == rule_name]
    if len(matches) != 1:
        raise SelectedKernelCompatibilityError(f"semantic rule {rule_name!r} is not unique")
    rule = matches[0]
    glob = rule.get("glob")
    if not isinstance(glob, str) or not glob.endswith("/" + source_path):
        raise SelectedKernelCompatibilityError(
            f"semantic rule {rule_name!r} does not target {source_path}"
        )
    return _list_of_lines(rule.get("contains"), f"{rule_name} contains")


def _validate_patch(patch: pathlib.Path, source_path: str, markers: tuple[str, ...]) -> str:
    try:
        payload = patch.read_bytes()
        text = payload.decode("utf-8")
    except (OSError, UnicodeDecodeError) as exc:
        raise SelectedKernelCompatibilityError(f"cannot read compatibility patch {patch}: {exc}") from exc
    old_paths = [line[6:] for line in text.splitlines() if line.startswith("--- a/")]
    new_paths = [line[6:] for line in text.splitlines() if line.startswith("+++ b/")]
    if old_paths != [source_path] or new_paths != [source_path]:
        raise SelectedKernelCompatibilityError(
            f"compatibility patch must modify only {source_path}"
        )
    added = _added_payload([patch])
    missing = [marker for marker in markers if marker not in added]
    if missing:
        raise SelectedKernelCompatibilityError(
            f"compatibility patch is missing semantic markers: {missing}"
        )
    return hashlib.sha256(payload).hexdigest()


def load_capability(repo_root: pathlib.Path) -> Capability:
    policy_path = repo_root / "patchsets/common/kernel/selected-kernel-compatibility.json"
    try:
        document = json.loads(policy_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise SelectedKernelCompatibilityError(f"cannot read selected-kernel policy: {exc}") from exc
    if not isinstance(document, dict) or set(document) != {"schema", "capabilities"} or document.get("schema") != 1:
        raise SelectedKernelCompatibilityError("selected-kernel policy schema must be 1")
    raw_capabilities = document.get("capabilities")
    if not isinstance(raw_capabilities, list) or len(raw_capabilities) != 1:
        raise SelectedKernelCompatibilityError("selected-kernel policy must contain exactly one capability")
    raw = raw_capabilities[0]
    if not isinstance(raw, dict) or set(raw) != CAPABILITY_FIELDS:
        raise SelectedKernelCompatibilityError("selected-kernel capability fields differ from schema")

    capability_id = _line(raw["id"], "capability id")
    if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", capability_id):
        raise SelectedKernelCompatibilityError(f"unsafe capability id: {capability_id!r}")
    semantic_rule = _line(raw["semantic_rule"], "semantic rule")
    source_path = _line(raw["source_path"], "source path")
    source = pathlib.PurePosixPath(source_path)
    if source.is_absolute() or ".." in source.parts or source.suffix != ".c":
        raise SelectedKernelCompatibilityError(f"unsafe source path: {source_path!r}")
    markers = _semantic_markers(repo_root, semantic_rule, source_path)
    prerequisites = _list_of_lines(
        raw["prerequisite_patch_markers"], "prerequisite patch markers"
    )

    raw_variants = raw["variants"]
    if not isinstance(raw_variants, dict) or not raw_variants:
        raise SelectedKernelCompatibilityError("capability variants must be a non-empty object")
    variants: dict[str, Variant] = {}
    kernel_root = (repo_root / "patchsets/common/kernel").resolve()
    for series, item in raw_variants.items():
        _series(series, "variant series")
        if not isinstance(item, dict) or set(item) != VARIANT_FIELDS:
            raise SelectedKernelCompatibilityError(f"variant {series} fields differ from schema")
        if _line(item["adapted_for"], "adapted_for") != series:
            raise SelectedKernelCompatibilityError(f"variant {series} adapted_for differs")
        patch_name = _line(item["patch"], "patch name")
        install_name = _line(item["install_name"], "install name")
        install_directory = _line(item["install_directory"], "install directory")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.patch", patch_name):
            raise SelectedKernelCompatibilityError(f"unsafe patch name: {patch_name!r}")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.patch", install_name):
            raise SelectedKernelCompatibilityError(f"unsafe install name: {install_name!r}")
        if install_directory != f"backport-{series}":
            raise SelectedKernelCompatibilityError(
                f"variant {series} must install into backport-{series}"
            )
        patch = (kernel_root / patch_name).resolve()
        if patch.parent != kernel_root or not patch.is_file():
            raise SelectedKernelCompatibilityError(f"compatibility patch is missing: {patch}")
        origin_url = _line(item["origin_url"], "origin URL")
        if not origin_url.startswith("https://"):
            raise SelectedKernelCompatibilityError("origin URL must use HTTPS")
        origin_commit = _line(item["origin_commit"], "origin commit")
        if not re.fullmatch(r"[0-9a-f]{40}", origin_commit):
            raise SelectedKernelCompatibilityError(f"invalid origin commit: {origin_commit!r}")
        variants[series] = Variant(
            series=series,
            patch=patch,
            install_directory=install_directory,
            install_name=install_name,
            origin_url=origin_url,
            origin_commit=origin_commit,
            sha256=_validate_patch(patch, source_path, markers),
        )
    return Capability(
        id=capability_id,
        semantic_rule=semantic_rule,
        source_path=source_path,
        markers=markers,
        prerequisite_markers=prerequisites,
        upstream_from=_series(raw["upstream_from"], "upstream_from"),
        variants=variants,
    )


def resolve(repo_root: pathlib.Path, openwrt_root: pathlib.Path, series: str) -> Resolution:
    parsed_series = _series(series, "kernel series")
    capability = load_capability(repo_root)
    variant = capability.variants.get(series)
    stack = _selected_patch_stack(openwrt_root, series)
    exact_compatibility_present = False

    if variant is not None:
        destination = (
            openwrt_root
            / "target/linux/generic"
            / variant.install_directory
            / variant.install_name
        )
        if destination.is_file():
            digest = hashlib.sha256(destination.read_bytes()).hexdigest()
            if digest == variant.sha256:
                exact_compatibility_present = True

    added = _added_payload(stack)
    marker_hits = [marker in added for marker in capability.markers]
    prerequisite_hits = [marker in added for marker in capability.prerequisite_markers]
    if exact_compatibility_present:
        if not all(prerequisite_hits):
            missing = [
                marker
                for marker, present in zip(
                    capability.prerequisite_markers, prerequisite_hits
                )
                if not present
            ]
            raise SelectedKernelCompatibilityError(
                f"kernel {series} patch stack lacks prerequisites for "
                f"{capability.id}: {missing}"
            )
        return Resolution("compatibility-present", capability, variant)
    if all(marker_hits):
        return Resolution("upstream-patch", capability, variant)
    if any(marker_hits):
        missing = [marker for marker, present in zip(capability.markers, marker_hits) if not present]
        raise SelectedKernelCompatibilityError(
            f"selected kernel patch stack partially implements {capability.id}; missing {missing}"
        )
    if parsed_series >= capability.upstream_from:
        return Resolution("upstream-kernel", capability, variant)
    if variant is None:
        raise SelectedKernelCompatibilityError(
            f"kernel {series} lacks {capability.id} and has no audited compatibility variant"
        )
    if not all(prerequisite_hits):
        missing = [
            marker
            for marker, present in zip(capability.prerequisite_markers, prerequisite_hits)
            if not present
        ]
        raise SelectedKernelCompatibilityError(
            f"kernel {series} patch stack lacks prerequisites for {capability.id}: {missing}"
        )
    return Resolution("compatibility-required", capability, variant)


def main(argv: list[str]) -> int:
    if len(argv) != 5 or argv[1] != "describe":
        print(
            "Usage: selected_kernel_compatibility.py describe "
            "<repo-root> <openwrt-root> <kernel-series>",
            file=sys.stderr,
        )
        return 2
    try:
        repo_root = pathlib.Path(argv[2]).resolve()
        openwrt_root = pathlib.Path(argv[3]).resolve()
        resolution = resolve(repo_root, openwrt_root, argv[4])
        variant = resolution.variant
        print(resolution.status)
        print(variant.patch if variant else "-")
        print(
            f"target/linux/generic/{variant.install_directory}/{variant.install_name}"
            if variant
            else "-"
        )
        print(variant.sha256 if variant else "-")
        print(resolution.capability.semantic_rule)
        print(variant.origin_url if variant else "-")
        print(variant.origin_commit if variant else "-")
    except (OSError, SelectedKernelCompatibilityError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
