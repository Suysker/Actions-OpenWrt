#!/usr/bin/env python3
"""Apply already-resolved release metadata to selected OpenWrt package recipes."""

from __future__ import annotations

import importlib.util
import json
import os
import pathlib
import re
import sys
import tempfile
from typing import Any


class ApplyError(RuntimeError):
    pass


def load_source_lock_module(script_dir: pathlib.Path):
    spec = importlib.util.spec_from_file_location("source_lock", script_dir / "source_lock.py")
    module = importlib.util.module_from_spec(spec)
    if spec.loader is None:
        raise ApplyError("cannot load source-lock implementation")
    spec.loader.exec_module(module)
    return module


def replace_unique(
    text: str, pattern: str, replacement: str, label: str
) -> tuple[str, str, str]:
    regex = re.compile(pattern, re.MULTILINE)
    matches = list(regex.finditer(text))
    if len(matches) != 1:
        raise ApplyError(f"{label}: expected one field, found {len(matches)}")
    match = matches[0]
    old = match.group(0)
    new_text = text[: match.start()] + replacement + text[match.end() :]
    return new_text, old, replacement


def replace_block_field(
    text: str, block_name: str, field: str, value: str
) -> tuple[str, str, str]:
    block_pattern = re.compile(
        rf"(^define Download/{re.escape(block_name)}\s*$)(.*?)(^endef\s*$)",
        re.MULTILINE | re.DOTALL,
    )
    blocks = list(block_pattern.finditer(text))
    if len(blocks) != 1:
        raise ApplyError(
            f"Download/{block_name}: expected one block, found {len(blocks)}"
        )
    block = blocks[0]
    body = block.group(2)
    updated, old, new = replace_unique(
        body,
        rf"^[ \t]*{re.escape(field)}:=[^\r\n]*$",
        f"  {field}:={value}",
        f"Download/{block_name} {field}",
    )
    output = text[: block.start(2)] + updated + text[block.end(2) :]
    return output, old, new


def atomic_write(path: pathlib.Path, text: str) -> None:
    mode = path.stat().st_mode
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", newline="\n", dir=path.parent, delete=False
    ) as handle:
        handle.write(text)
        temporary = pathlib.Path(handle.name)
    os.chmod(temporary, mode)
    os.replace(temporary, path)


def require_sha(value: Any, label: str) -> str:
    if not isinstance(value, str):
        raise ApplyError(f"{label} is not a string")
    value = value.removeprefix("sha256:").lower()
    if not re.fullmatch(r"[0-9a-f]{64}", value):
        raise ApplyError(f"{label} is not an exact SHA256")
    return value


def require_url(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value.startswith("https://"):
        raise ApplyError(f"{label} is not an HTTPS URL")
    if "latest/download" in value or "${" in value or "$(" in value:
        raise ApplyError(f"{label} is mutable: {value}")
    return value


def provider_contract(repo_root: pathlib.Path) -> dict[str, dict[str, Any]]:
    result: dict[str, dict[str, Any]] = {}
    path = repo_root / "profiles/common/providers.tsv"
    for raw in path.read_text(encoding="utf-8").splitlines():
        if not raw or raw.startswith("#"):
            continue
        component, package, makefile, conflicts = raw.split("\t")
        result[component] = {
            "package": package,
            "makefile": makefile,
            "conflicts": [] if conflicts == "-" else conflicts.split(","),
        }
    return result


def assert_provider(
    openwrt: pathlib.Path, component: str, contract: dict[str, dict[str, Any]]
) -> pathlib.Path:
    if component not in contract:
        raise ApplyError(f"no provider contract for {component}")
    entry = contract[component]
    path = openwrt / entry["makefile"]
    if not path.is_file():
        raise ApplyError(f"selected {component} provider is missing: {entry['makefile']}")
    text = path.read_text(encoding="utf-8")
    pattern = rf"^define Package/{re.escape(entry['package'])}(?:/[^\r\n]*)?\s*$"
    if len(re.findall(pattern, text, re.MULTILINE)) < 1:
        raise ApplyError(
            f"selected provider does not define package {entry['package']}: {entry['makefile']}"
        )
    for relative in entry["conflicts"]:
        if (openwrt / relative).exists():
            raise ApplyError(f"conflicting {component} provider still exists: {relative}")
    return path


def record_change(
    changes: list[dict[str, str]], field: str, old: str, new: str
) -> None:
    changes.append({"field": field, "old": old.strip(), "new": new.strip()})


def apply_haproxy(path: pathlib.Path, entry: dict[str, Any]) -> list[dict[str, str]]:
    version = entry.get("version", "")
    branch = entry.get("branch", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ApplyError("HAProxy version is invalid")
    if branch != ".".join(version.split(".")[:2]):
        raise ApplyError("HAProxy branch/version mismatch")
    url = require_url(entry.get("url"), "HAProxy URL")
    expected_url = f"https://www.haproxy.org/download/{branch}/src/haproxy-{version}.tar.gz"
    if url != expected_url:
        raise ApplyError(f"unexpected immutable HAProxy URL: {url}")
    sha = require_sha(entry.get("sha256"), "HAProxy hash")

    text = path.read_text(encoding="utf-8")
    changes: list[dict[str, str]] = []
    for field, pattern, replacement in (
        ("PKG_VERSION", r"^PKG_VERSION:=[^\r\n]*$", f"PKG_VERSION:={version}"),
        (
            "PKG_SOURCE_URL",
            r"^PKG_SOURCE_URL:=[^\r\n]*$",
            f"PKG_SOURCE_URL:=https://www.haproxy.org/download/{branch}/src",
        ),
        ("PKG_HASH", r"^PKG_HASH:=[^\r\n]*$", f"PKG_HASH:={sha}"),
    ):
        text, old, new = replace_unique(text, pattern, replacement, f"HAProxy {field}")
        record_change(changes, field, old, new)
    atomic_write(path, text)
    return changes


def apply_adguardhome(
    path: pathlib.Path, entry: dict[str, Any]
) -> list[dict[str, str]]:
    version = entry.get("version", "")
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise ApplyError("AdGuardHome version is invalid")
    tag = entry.get("tag")
    if tag != f"v{version}":
        raise ApplyError("AdGuardHome tag/version mismatch")
    source = entry.get("source", {})
    frontend = entry.get("frontend", {})
    source_url = require_url(source.get("url"), "AdGuardHome source URL")
    source_hash = require_sha(source.get("sha256"), "AdGuardHome source hash")
    frontend_url = require_url(frontend.get("url"), "AdGuardHome frontend URL")
    frontend_hash = require_sha(frontend.get("sha256"), "AdGuardHome frontend hash")
    if f"/refs/tags/{tag}" not in source_url:
        raise ApplyError("AdGuardHome source URL does not contain its exact tag")
    expected_frontend_suffix = f"/releases/download/{tag}/AdGuardHome_frontend.tar.gz"
    if not frontend_url.endswith(expected_frontend_suffix):
        raise ApplyError("AdGuardHome frontend URL does not contain its exact tag/asset")
    frontend_base = frontend_url.rsplit("/", 1)[0] + "/"

    text = path.read_text(encoding="utf-8")
    changes: list[dict[str, str]] = []
    for field, pattern, replacement in (
        ("PKG_VERSION", r"^PKG_VERSION:=[^\r\n]*$", f"PKG_VERSION:={version}"),
        ("PKG_SOURCE_URL", r"^PKG_SOURCE_URL:=[^\r\n]*$", f"PKG_SOURCE_URL:={source_url}"),
        ("PKG_HASH", r"^PKG_HASH:=[^\r\n]*$", f"PKG_HASH:={source_hash}"),
        ("FRONTEND_URL", r"^FRONTEND_URL:=[^\r\n]*$", f"FRONTEND_URL:={frontend_base}"),
        ("FRONTEND_HASH", r"^FRONTEND_HASH:=[^\r\n]*$", f"FRONTEND_HASH:={frontend_hash}"),
    ):
        text, old, new = replace_unique(text, pattern, replacement, f"AdGuardHome {field}")
        record_change(changes, field, old, new)
    atomic_write(path, text)
    return changes


def apply_geodata(
    path: pathlib.Path,
    artifacts: dict[str, Any],
    contracts: tuple[dict[str, str], ...],
) -> list[dict[str, str]]:
    text = path.read_text(encoding="utf-8")
    changes: list[dict[str, str]] = []
    for contract in contracts:
        component_id = contract["id"]
        component = contract["display_name"]
        entry = artifacts[component_id]
        version_field = contract["package_version_field"]
        block = contract["package_download_block"]
        repo = contract["repository"]
        asset = contract["release_asset"]
        tag = entry.get("tag", "")
        if not re.fullmatch(r"[A-Za-z0-9._-]+", tag):
            raise ApplyError(f"{component} tag is invalid")
        url = require_url(entry.get("url"), f"{component} URL")
        sha = require_sha(entry.get("sha256"), f"{component} hash")
        expected_url = f"https://github.com/{repo}/releases/download/{tag}/{asset}"
        if url != expected_url:
            raise ApplyError(f"{component} URL is not the exact {repo} release asset")
        base_url = url.rsplit("/", 1)[0] + "/"

        text, old, new = replace_unique(
            text,
            rf"^{version_field}:=[^\r\n]*$",
            f"{version_field}:={tag}",
            version_field,
        )
        record_change(changes, version_field, old, new)
        text, old, new = replace_block_field(text, block, "URL", base_url)
        record_change(changes, f"Download/{block}.URL", old, new)
        text, old, new = replace_block_field(text, block, "HASH", sha)
        record_change(changes, f"Download/{block}.HASH", old, new)
    atomic_write(path, text)
    return changes


def assert_no_mutable_metadata(paths: list[pathlib.Path]) -> None:
    forbidden = re.compile(r"(?:PKG_)?HASH:=skip|releases/latest/download")
    for path in paths:
        text = path.read_text(encoding="utf-8")
        match = forbidden.search(text)
        if match:
            raise ApplyError(f"mutable or unchecked metadata remains in {path}: {match.group(0)}")


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(
            "Usage: apply_source_lock_artifacts.py <openwrt-root> <source-lock.json> <report.json>",
            file=sys.stderr,
        )
        return 2
    openwrt = pathlib.Path(argv[1]).resolve()
    lock_path = pathlib.Path(argv[2]).resolve()
    report_path = pathlib.Path(argv[3]).resolve()
    if not openwrt.is_dir():
        raise ApplyError(f"OpenWrt root does not exist: {openwrt}")
    if not lock_path.is_file():
        raise ApplyError(f"source lock does not exist: {lock_path}")

    script_dir = pathlib.Path(__file__).resolve().parent
    repo_root = script_dir.parent
    source_lock = load_source_lock_module(script_dir)
    lock = source_lock.load_lock(lock_path)
    geodata_contracts = source_lock.load_geodata_contracts(repo_root)
    artifacts = lock.get("upstream_artifacts", {})
    expected_artifacts = {"haproxy", "adguardhome"} | {
        item["id"] for item in geodata_contracts
    }
    if set(artifacts) != expected_artifacts:
        raise ApplyError("source lock artifacts differ from the declared source contract")

    provider_selection = provider_contract(repo_root)
    haproxy_path = assert_provider(openwrt, "haproxy", provider_selection)
    adguard_path = assert_provider(openwrt, "adguardhome", provider_selection)
    geodata_paths = {
        item["id"]: assert_provider(openwrt, item["id"], provider_selection)
        for item in geodata_contracts
    }
    if len(set(geodata_paths.values())) != 1:
        raise ApplyError("all Geo data roles must share one selected package provider")
    geodata_path = next(iter(geodata_paths.values()))

    report = {
        "schema": 1,
        "source_lock_digest": source_lock.lock_digest(lock),
        "components": {},
    }
    report["components"]["haproxy"] = {
        "provider": str(haproxy_path.relative_to(openwrt)),
        "changes": apply_haproxy(haproxy_path, artifacts["haproxy"]),
    }
    report["components"]["adguardhome"] = {
        "provider": str(adguard_path.relative_to(openwrt)),
        "changes": apply_adguardhome(adguard_path, artifacts["adguardhome"]),
    }
    report["components"]["v2ray-geodata"] = {
        "provider": str(geodata_path.relative_to(openwrt)),
        "changes": apply_geodata(geodata_path, artifacts, geodata_contracts),
    }
    assert_no_mutable_metadata([haproxy_path, adguard_path, geodata_path])

    report_path.parent.mkdir(parents=True, exist_ok=True)
    report_path.write_text(
        json.dumps(report, ensure_ascii=False, sort_keys=True, indent=2) + "\n",
        encoding="utf-8",
    )
    print(f"Locked artifact metadata applied. Report: {report_path}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except (RuntimeError, OSError, ValueError, KeyError, json.JSONDecodeError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        raise SystemExit(1)
