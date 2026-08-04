#!/usr/bin/env python3
"""Resolve and validate every mutable OpenWrt build input exactly once."""

from __future__ import annotations

import copy
import datetime as dt
import hashlib
import json
import os
import pathlib
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Iterable

from bbr3_module_version import BBRModuleVersionError, validate_policy_compatibility
from kernel_patch import KernelPatchError, inspect_patch
from kernel_selection import (
    KernelSelectionError,
    apply_channel_override,
    exact_version_and_hash,
    selected_channel,
    selected_series,
)

from profile_model import ProfileModelError, ProfileRepository, parse_config


SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
FEED_RE = re.compile(r"^(src-git(?:-full)?)\s+([A-Za-z0-9_.-]+)\s+(\S+)$")
ACTION_USE_RE = re.compile(r"^\s*(?:-\s*)?uses:\s*([^@\s]+)@([^\s#]+)")
SOURCE_LOCK_SCHEMA = 5


class ResolutionError(RuntimeError):
    pass


def run(*args: str, cwd: pathlib.Path | None = None) -> str:
    result = subprocess.run(
        args,
        cwd=cwd,
        check=False,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    if result.returncode:
        raise ResolutionError(
            f"command failed ({result.returncode}): {' '.join(args)}\n{result.stderr.strip()}"
        )
    return result.stdout


def request(url: str, *, accept: str | None = None) -> urllib.response.addinfourl:
    headers = {"User-Agent": "Actions-OpenWrt-source-lock/1"}
    if accept:
        headers["Accept"] = accept
    token = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
    if token and urllib.parse.urlparse(url).hostname == "api.github.com":
        headers["Authorization"] = f"Bearer {token}"

    last_error: Exception | None = None
    for attempt in range(4):
        try:
            return urllib.request.urlopen(
                urllib.request.Request(url, headers=headers), timeout=90
            )
        except (urllib.error.URLError, TimeoutError) as exc:
            last_error = exc
            if attempt == 3:
                break
            time.sleep(2**attempt)
    raise ResolutionError(f"cannot download {url}: {last_error}")


def download_bytes(url: str) -> bytes:
    with request(url) as response:
        return response.read()


def download_text(url: str) -> str:
    try:
        return download_bytes(url).decode("utf-8")
    except UnicodeDecodeError as exc:
        raise ResolutionError(f"response from {url} is not UTF-8: {exc}") from exc


def download_sha256(url: str) -> str:
    digest = hashlib.sha256()
    with request(url) as response:
        while chunk := response.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def api_json(url: str) -> Any:
    try:
        return json.loads(
            download_bytes(url).decode("utf-8")
        )
    except json.JSONDecodeError as exc:
        raise ResolutionError(f"GitHub API returned invalid JSON for {url}: {exc}") from exc


def require_sha1(value: str, label: str) -> str:
    value = value.lower()
    if not SHA1_RE.fullmatch(value):
        raise ResolutionError(f"{label} is not a full Git SHA-1: {value!r}")
    return value


def require_sha256(value: str, label: str) -> str:
    value = value.removeprefix("sha256:").lower()
    if not SHA256_RE.fullmatch(value):
        raise ResolutionError(f"{label} is not a SHA256 digest: {value!r}")
    return value


def resolve_git_ref(url: str, requested_ref: str) -> dict[str, str]:
    if SHA1_RE.fullmatch(requested_ref):
        # Exact commits are already immutable. They are used only by consumers,
        # while resolver inputs remain branches/tags.
        return {
            "url": url,
            "requested_ref": requested_ref,
            "resolved_ref": requested_ref,
            "commit": requested_ref,
        }

    if requested_ref in ("", "HEAD"):
        output = run("git", "ls-remote", "--symref", url, "HEAD")
        resolved_ref = "HEAD"
        commit = ""
        for line in output.splitlines():
            if line.startswith("ref:") and line.endswith("\tHEAD"):
                resolved_ref = line.split()[1]
            elif line.endswith("\tHEAD"):
                commit = line.split()[0]
        return {
            "url": url,
            "requested_ref": "HEAD",
            "resolved_ref": resolved_ref,
            "commit": require_sha1(commit, f"{url} HEAD"),
        }

    if requested_ref.startswith("refs/"):
        resolved_ref = requested_ref
    elif requested_ref.startswith("v") or re.fullmatch(r"[0-9][A-Za-z0-9._-]*", requested_ref):
        # Profiles and feeds express branches. Release tags use resolve_tag_commit.
        resolved_ref = f"refs/heads/{requested_ref}"
    else:
        resolved_ref = f"refs/heads/{requested_ref}"

    output = run("git", "ls-remote", "--refs", url, resolved_ref)
    matches = [line.split()[0] for line in output.splitlines() if line.strip()]
    if len(matches) != 1:
        raise ResolutionError(
            f"expected one ref for {url} {resolved_ref}, found {len(matches)}"
        )
    return {
        "url": url,
        "requested_ref": requested_ref,
        "resolved_ref": resolved_ref,
        "commit": require_sha1(matches[0], f"{url} {resolved_ref}"),
    }


def resolve_tag_commit(url: str, tag: str) -> str:
    peeled = run("git", "ls-remote", url, f"refs/tags/{tag}^{{}}")
    values = [line.split()[0] for line in peeled.splitlines() if line.strip()]
    if not values:
        direct = run("git", "ls-remote", "--refs", url, f"refs/tags/{tag}")
        values = [line.split()[0] for line in direct.splitlines() if line.strip()]
    if len(values) != 1:
        raise ResolutionError(f"expected one Git tag {url} {tag}, found {len(values)}")
    return require_sha1(values[0], f"{url} tag {tag}")


def github_raw_url(repo_url: str, commit: str, path: str) -> str:
    parsed = urllib.parse.urlparse(repo_url)
    if parsed.hostname not in {"github.com", "www.github.com"}:
        raise ResolutionError(f"cannot form immutable raw URL for non-GitHub repo: {repo_url}")
    repo_path = parsed.path.strip("/").removesuffix(".git")
    if repo_path.count("/") != 1:
        raise ResolutionError(f"invalid GitHub repository URL: {repo_url}")
    return f"https://raw.githubusercontent.com/{repo_path}/{commit}/{path}"


def split_feed_url(spec: str) -> tuple[str, str]:
    if ";" in spec:
        url, ref = spec.rsplit(";", 1)
        if not ref:
            raise ResolutionError(f"feed has an empty branch: {spec}")
        return url, ref
    return spec, "HEAD"


def parse_feeds(text: str, label: str) -> list[dict[str, str]]:
    result = []
    names: set[str] = set()
    for line_no, raw in enumerate(text.splitlines(), start=1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = FEED_RE.fullmatch(line)
        if not match:
            raise ResolutionError(f"unsupported feed syntax in {label}:{line_no}: {raw}")
        feed_type, name, spec = match.groups()
        if name in names:
            raise ResolutionError(f"duplicate feed name {name!r} in {label}")
        names.add(name)
        url, requested_ref = split_feed_url(spec)
        result.append(
            {
                "type": feed_type,
                "name": name,
                "url": url,
                "requested_ref": requested_ref,
            }
        )
    return result


def merge_feed_specs(
    custom_specs: list[dict[str, str]], default_specs: list[dict[str, str]]
) -> list[tuple[str, int, dict[str, str]]]:
    custom_names = {spec["name"] for spec in custom_specs}
    return [
        *[("custom", order, spec) for order, spec in enumerate(custom_specs)],
        *[
            ("default", order, spec)
            for order, spec in enumerate(default_specs)
            if spec["name"] not in custom_names
        ],
    ]


def require_overlay_path(
    value: Any,
    label: str,
    *,
    target: bool = False,
    target_kind: str = "tree",
) -> str:
    if not isinstance(value, str):
        raise ResolutionError(f"{label} must be a string")
    path = pathlib.PurePosixPath(value)
    if (
        path.is_absolute()
        or path.as_posix() != value
        or len(path.parts) < 2
        or ".." in path.parts
        or any(not re.fullmatch(r"[A-Za-z0-9_.+-]+", part) for part in path.parts)
    ):
        raise ResolutionError(f"unsafe {label}: {value!r}")
    if target:
        if target_kind == "tree":
            supported = (
                path.parts[0] == "package" and len(path.parts) >= 3
            ) or (
                path.parts[0] == "feeds" and len(path.parts) >= 4
            )
        elif target_kind == "file":
            supported = (
                len(path.parts) == 3
                and path.parts[:2] == ("scripts", "openwrt-sbom")
            )
        else:
            raise ResolutionError(f"unsupported source overlay kind: {target_kind!r}")
        if not supported:
            raise ResolutionError(f"unsupported source overlay target: {value!r}")
    return value


def load_source_overlay_contracts(
    repo_root: pathlib.Path,
) -> tuple[dict[str, Any], ...]:
    path = repo_root / "profiles/common/source-overlays.json"
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ResolutionError(f"cannot read source overlay contract {path}: {exc}") from exc
    if not isinstance(document, dict) or set(document) != {"schema", "repositories"}:
        raise ResolutionError(
            "source overlay contract must contain schema and repositories"
        )
    repositories = document["repositories"]
    if document["schema"] != 2 or not isinstance(repositories, list):
        raise ResolutionError("unsupported source overlay contract schema")
    if not repositories:
        raise ResolutionError("source overlay contract declares no repositories")

    result: list[dict[str, Any]] = []
    identifiers: set[str] = set()
    targets: set[str] = set()
    for index, repository in enumerate(repositories, start=1):
        label = f"source overlay repository {index}"
        if not isinstance(repository, dict) or set(repository) != {
            "id",
            "url",
            "ref",
            "mappings",
        }:
            raise ResolutionError(f"{label} has invalid fields")
        identifier = repository["id"]
        if not isinstance(identifier, str) or not re.fullmatch(
            r"[a-z0-9]+(?:-[a-z0-9]+)*", identifier
        ):
            raise ResolutionError(f"{label} has an invalid id")
        if identifier in identifiers:
            raise ResolutionError(f"duplicate source overlay id: {identifier}")
        identifiers.add(identifier)

        url = repository["url"]
        if not isinstance(url, str):
            raise ResolutionError(f"{label} URL must be a string")
        parsed = urllib.parse.urlparse(url)
        if (
            parsed.scheme != "https"
            or parsed.hostname != "github.com"
            or parsed.username
            or parsed.password
            or parsed.port
            or parsed.params
            or parsed.query
            or parsed.fragment
            or not re.fullmatch(
                r"/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\.git", parsed.path
            )
        ):
            raise ResolutionError(f"{label} is not an exact GitHub repository URL")

        requested_ref = repository["ref"]
        if (
            not isinstance(requested_ref, str)
            or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]*", requested_ref)
            or ".." in requested_ref
            or "//" in requested_ref
        ):
            raise ResolutionError(f"{label} has an unsafe ref")

        raw_mappings = repository["mappings"]
        if not isinstance(raw_mappings, list) or not raw_mappings:
            raise ResolutionError(f"{label} has no mappings")
        sources: set[str] = set()
        mappings: list[dict[str, str]] = []
        for mapping_index, mapping in enumerate(raw_mappings, start=1):
            mapping_label = f"{label} mapping {mapping_index}"
            if not isinstance(mapping, dict) or set(mapping) != {
                "kind",
                "source",
                "target",
            }:
                raise ResolutionError(f"{mapping_label} has invalid fields")
            kind = mapping["kind"]
            if kind not in {"tree", "file"}:
                raise ResolutionError(f"{mapping_label} has an invalid kind")
            source = require_overlay_path(mapping["source"], f"{mapping_label} source")
            target_path = require_overlay_path(
                mapping["target"],
                f"{mapping_label} target",
                target=True,
                target_kind=kind,
            )
            if source in sources:
                raise ResolutionError(f"{label} repeats source path {source!r}")
            if any(
                target_path == existing
                or target_path.startswith(existing + "/")
                or existing.startswith(target_path + "/")
                for existing in targets
            ):
                raise ResolutionError(
                    f"source overlay target overlaps another mapping: {target_path}"
                )
            sources.add(source)
            targets.add(target_path)
            mappings.append(
                {"kind": kind, "source": source, "target": target_path}
            )
        result.append(
            {
                "id": identifier,
                "url": url,
                "requested_ref": requested_ref,
                "mappings": mappings,
            }
        )
    return tuple(result)


def load_geodata_contracts(repo_root: pathlib.Path) -> tuple[dict[str, str], ...]:
    path = repo_root / "profiles/common/geodata-sources.json"
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ResolutionError(f"cannot read geodata source contract {path}: {exc}") from exc

    if not isinstance(document, dict) or set(document) != {"schema", "components"}:
        raise ResolutionError("geodata source contract must contain schema and components")
    if document["schema"] != 1 or not isinstance(document["components"], list):
        raise ResolutionError("unsupported geodata source contract schema")
    if not document["components"]:
        raise ResolutionError("geodata source contract must declare at least one component")

    fields = {
        "id",
        "display_name",
        "repository",
        "release_asset",
        "override_env",
        "package_version_field",
        "package_download_block",
    }
    unique_fields = (
        "id",
        "override_env",
        "package_version_field",
        "package_download_block",
    )
    seen = {field: set() for field in unique_fields}
    contracts: list[dict[str, str]] = []

    for index, raw in enumerate(document["components"], start=1):
        if not isinstance(raw, dict) or set(raw) != fields:
            raise ResolutionError(
                f"geodata component {index} must contain exactly: {', '.join(sorted(fields))}"
            )
        if not all(isinstance(raw[field], str) and raw[field] for field in fields):
            raise ResolutionError(f"geodata component {index} contains an empty field")
        contract = {field: raw[field] for field in fields}

        if not re.fullmatch(r"[a-z][a-z0-9_-]*", contract["id"]):
            raise ResolutionError(f"invalid geodata component id: {contract['id']!r}")
        if not re.fullmatch(
            r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", contract["repository"]
        ):
            raise ResolutionError(
                f"invalid geodata GitHub repository: {contract['repository']!r}"
            )
        if not re.fullmatch(r"[A-Za-z0-9_.-]+", contract["release_asset"]):
            raise ResolutionError(
                f"invalid geodata release asset: {contract['release_asset']!r}"
            )
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", contract["override_env"]):
            raise ResolutionError(
                f"invalid geodata override environment name: {contract['override_env']!r}"
            )
        if not re.fullmatch(r"[A-Z][A-Z0-9_]*", contract["package_version_field"]):
            raise ResolutionError(
                f"invalid geodata package version field: {contract['package_version_field']!r}"
            )
        if not re.fullmatch(
            r"[A-Za-z0-9_.-]+", contract["package_download_block"]
        ):
            raise ResolutionError(
                f"invalid geodata package download block: {contract['package_download_block']!r}"
            )

        for field in unique_fields:
            value = contract[field]
            if value in seen[field]:
                raise ResolutionError(f"duplicate geodata {field}: {value!r}")
            seen[field].add(value)
        contracts.append(contract)

    return tuple(contracts)


def merged_profile_env(repo_root: pathlib.Path, profile: str) -> dict[str, str]:
    try:
        return ProfileRepository(repo_root / "profiles").environment(profile)
    except ProfileModelError as exc:
        raise ResolutionError(str(exc)) from exc


def version_tuple(value: str) -> tuple[int, int, int]:
    match = SEMVER_RE.fullmatch(value)
    if not match:
        raise ResolutionError(f"invalid semantic version: {value!r}")
    return tuple(int(part) for part in match.groups())  # type: ignore[return-value]


def select_haproxy_branch(index_html: str) -> str:
    branches = {
        match.group(1)
        for match in re.finditer(r'href=["\']([0-9]+\.[0-9]+)/["\']', index_html)
        if int(match.group(1).split(".")[1]) % 2 == 0
    }
    if not branches:
        raise ResolutionError("HAProxy download index contains no LTS branch")
    return max(branches, key=lambda item: tuple(map(int, item.split("."))))


def select_haproxy_release(releases: dict[str, Any], override: str | None) -> str:
    stable = [version for version in releases if SEMVER_RE.fullmatch(version)]
    if not stable:
        raise ResolutionError("HAProxy releases.json contains no stable release")
    if override:
        version_tuple(override)
        if override not in releases:
            raise ResolutionError(f"HAProxy override is absent from releases.json: {override}")
        return override
    return max(stable, key=version_tuple)


def resolve_haproxy() -> dict[str, Any]:
    override = os.environ.get("HAPROXY_VERSION", "").strip() or None
    if override:
        branch = ".".join(override.split(".")[:2])
        if version_tuple(override)[1] % 2:
            raise ResolutionError("HAPROXY_VERSION must select an even-numbered LTS branch")
    else:
        branch = select_haproxy_branch(download_text("https://www.haproxy.org/download/"))

    metadata_url = f"https://www.haproxy.org/download/{branch}/src/releases.json"
    metadata = json.loads(download_text(metadata_url))
    if metadata.get("branch") != branch or not isinstance(metadata.get("releases"), dict):
        raise ResolutionError(f"invalid HAProxy release metadata for branch {branch}")
    version = select_haproxy_release(metadata["releases"], override)
    release = metadata["releases"][version]
    expected = require_sha256(release.get("sha256", ""), "HAProxy release hash")
    filename = release.get("file")
    if filename != f"haproxy-{version}.tar.gz":
        raise ResolutionError(f"unexpected HAProxy release filename: {filename!r}")
    url = f"https://www.haproxy.org/download/{branch}/src/{filename}"
    actual = download_sha256(url)
    if actual != expected:
        raise ResolutionError(f"HAProxy archive hash mismatch: expected {expected}, got {actual}")
    return {
        "policy": "exact-override" if override else "latest-lts",
        "branch": branch,
        "version": version,
        "url": url,
        "sha256": expected,
        "metadata_url": metadata_url,
    }


def github_release(repo: str, override: str | None) -> dict[str, Any]:
    if override:
        tag = urllib.parse.quote(override, safe="")
        url = f"https://api.github.com/repos/{repo}/releases/tags/{tag}"
    else:
        url = f"https://api.github.com/repos/{repo}/releases/latest"
    release = api_json(url)
    if not isinstance(release, dict):
        raise ResolutionError(f"invalid GitHub release response for {repo}")
    if release.get("draft") or release.get("prerelease"):
        raise ResolutionError(f"selected release for {repo} is draft or prerelease")
    if not release.get("tag_name"):
        raise ResolutionError(f"selected release for {repo} has no tag")
    return release


def asset_by_name(release: dict[str, Any], name: str) -> dict[str, Any]:
    matches = [asset for asset in release.get("assets", []) if asset.get("name") == name]
    if len(matches) != 1:
        raise ResolutionError(
            f"release {release.get('tag_name')} must contain exactly one {name}; found {len(matches)}"
        )
    asset = matches[0]
    require_sha256(asset.get("digest", ""), f"GitHub asset digest for {name}")
    if not asset.get("browser_download_url"):
        raise ResolutionError(f"release asset {name} has no immutable URL")
    return asset


def verify_release_asset(asset: dict[str, Any]) -> str:
    expected = require_sha256(asset["digest"], f"asset {asset['name']} digest")
    actual = download_sha256(asset["browser_download_url"])
    if actual != expected:
        raise ResolutionError(
            f"asset {asset['name']} hash mismatch: expected {expected}, got {actual}"
        )
    return actual


def resolve_adguardhome() -> dict[str, Any]:
    override = os.environ.get("ADGUARDHOME_VERSION", "").strip()
    if override and not override.startswith("v"):
        override = f"v{override}"
    release = github_release("AdguardTeam/AdGuardHome", override or None)
    tag = release["tag_name"]
    if not re.fullmatch(r"v\d+\.\d+\.\d+", tag):
        raise ResolutionError(f"unexpected AdGuardHome stable tag: {tag!r}")
    version = tag.removeprefix("v")
    frontend = asset_by_name(release, "AdGuardHome_frontend.tar.gz")
    frontend_hash = verify_release_asset(frontend)
    source_url = (
        f"https://codeload.github.com/AdguardTeam/AdGuardHome/tar.gz/refs/tags/{tag}?"
    )
    source_hash = download_sha256(source_url)
    tag_commit = resolve_tag_commit(
        "https://github.com/AdguardTeam/AdGuardHome.git", tag
    )
    return {
        "policy": "exact-override" if override else "latest-stable",
        "version": version,
        "tag": tag,
        "tag_commit": tag_commit,
        "source": {"url": source_url, "sha256": source_hash},
        "frontend": {
            "url": frontend["browser_download_url"],
            "sha256": frontend_hash,
        },
    }


def parse_checksum(text: str, expected_name: str) -> str:
    matches = []
    for raw in text.splitlines():
        parts = raw.strip().split()
        if len(parts) >= 2 and parts[-1].lstrip("*") == expected_name:
            matches.append(require_sha256(parts[0], f"checksum for {expected_name}"))
    if len(matches) != 1:
        raise ResolutionError(
            f"checksum file must contain exactly one entry for {expected_name}; found {len(matches)}"
        )
    return matches[0]


def resolve_geodata(
    *, repo: str, asset_name: str, override_env: str
) -> dict[str, Any]:
    override = os.environ.get(override_env, "").strip() or None
    release = github_release(repo, override)
    tag = release["tag_name"]
    data_asset = asset_by_name(release, asset_name)
    checksum_asset = asset_by_name(release, f"{asset_name}.sha256sum")

    api_hash = verify_release_asset(data_asset)
    checksum_api_hash = require_sha256(
        checksum_asset["digest"], f"asset {checksum_asset['name']} digest"
    )
    checksum_bytes = download_bytes(checksum_asset["browser_download_url"])
    actual_checksum_asset_hash = hashlib.sha256(checksum_bytes).hexdigest()
    if actual_checksum_asset_hash != checksum_api_hash:
        raise ResolutionError(
            f"checksum asset digest mismatch for {checksum_asset['name']}"
        )
    published_hash = parse_checksum(checksum_bytes.decode("utf-8"), asset_name)
    if published_hash != api_hash:
        raise ResolutionError(
            f"GitHub digest and published checksum disagree for {repo} {asset_name}"
        )
    return {
        "policy": "exact-override" if override else "latest-stable",
        "tag": tag,
        "url": data_asset["browser_download_url"],
        "sha256": api_hash,
        "checksum_url": checksum_asset["browser_download_url"],
        "checksum_sha256": checksum_api_hash,
    }


def tree_digest(paths: Iterable[pathlib.Path], root: pathlib.Path) -> str:
    digest = hashlib.sha256()
    seen: set[str] = set()
    for base in paths:
        if not base.exists():
            raise ResolutionError(f"digest input does not exist: {base}")
        entries = [base] if base.is_file() else [p for p in base.rglob("*") if p.is_file()]
        for path in sorted(entries, key=lambda item: item.as_posix()):
            relative = path.relative_to(root).as_posix()
            if relative in seen:
                continue
            seen.add(relative)
            digest.update(relative.encode("utf-8"))
            digest.update(b"\0")
            digest.update(path.read_bytes())
            digest.update(b"\0")
    return f"sha256:{digest.hexdigest()}"


def profile_digest(repo_root: pathlib.Path, profile: str) -> str:
    try:
        device = ProfileRepository(repo_root / "profiles").device(profile)
    except ProfileModelError as exc:
        raise ResolutionError(str(exc)) from exc
    return tree_digest(
        [
            repo_root / "profiles/common",
            device,
            repo_root / "feeds.custom.conf",
        ],
        repo_root,
    )


def github_repo_slug(repo_url: str) -> str:
    parsed = urllib.parse.urlparse(repo_url.removesuffix(".git"))
    slug = parsed.path.strip("/")
    if parsed.hostname not in {"github.com", "www.github.com"} or slug.count("/") != 1:
        raise ResolutionError(f"invalid GitHub repository URL: {repo_url}")
    return slug


def github_tree_files(repo_url: str, commit: str) -> set[str]:
    slug = github_repo_slug(repo_url)
    tree = api_json(
        f"https://api.github.com/repos/{slug}/git/trees/{commit}?recursive=1"
    )
    if not isinstance(tree, dict) or not isinstance(tree.get("tree"), list):
        raise ResolutionError(f"invalid Git tree response for {repo_url}@{commit}")
    if tree.get("truncated"):
        raise ResolutionError(f"Git tree is truncated for {repo_url}@{commit}")
    return {
        entry["path"]
        for entry in tree["tree"]
        if isinstance(entry, dict)
        and entry.get("type") == "blob"
        and isinstance(entry.get("path"), str)
    }


def expand_series_template(value: str, kernel_series: str, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ResolutionError(f"BBRv3 {label} must be a non-empty string")
    expanded = value.replace("{series}", kernel_series)
    if "{" in expanded or "}" in expanded:
        raise ResolutionError(f"BBRv3 {label} contains an unknown template: {value}")
    return expanded


def load_bbr_policy(repo_root: pathlib.Path) -> dict[str, Any]:
    path = repo_root / "patchsets/common/kernel/bbr3-sources.json"
    try:
        policy = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ResolutionError(f"cannot read BBRv3 source policy {path}: {exc}") from exc
    if not isinstance(policy, dict) or policy.get("schema") != 2:
        raise ResolutionError("BBRv3 source policy schema must be 2")
    algorithm = policy.get("algorithm")
    providers = policy.get("providers")
    if not isinstance(algorithm, dict) or not isinstance(providers, list) or not providers:
        raise ResolutionError("BBRv3 source policy needs algorithm and providers")
    if algorithm.get("module_version") != 3 or algorithm.get("runtime_name") != "bbr":
        raise ResolutionError("BBRv3 algorithm identity policy is invalid")
    try:
        validate_policy_compatibility(repo_root, policy)
    except BBRModuleVersionError as exc:
        raise ResolutionError(str(exc)) from exc
    return policy


def resolve_bbr_algorithm(policy: dict[str, Any]) -> dict[str, Any]:
    algorithm = policy["algorithm"]
    resolved = resolve_git_ref(algorithm.get("url", ""), algorithm.get("ref", ""))
    resolved["module_version"] = algorithm["module_version"]
    resolved["runtime_name"] = algorithm["runtime_name"]
    return resolved


def resolve_bbr_port(policy: dict[str, Any], kernel_series: str) -> dict[str, Any]:
    if not re.fullmatch(r"[0-9]+\.[0-9]+", kernel_series):
        raise ResolutionError(f"invalid BBRv3 kernel series: {kernel_series}")

    attempted: list[str] = []
    for provider in policy["providers"]:
        if not isinstance(provider, dict):
            raise ResolutionError("BBRv3 provider entries must be objects")
        name = provider.get("name", "")
        repo_url = provider.get("url", "")
        requested_ref = provider.get("ref", "")
        mode = provider.get("mode", "")
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
            raise ResolutionError(f"invalid BBRv3 provider name: {name!r}")
        if mode not in {"single", "directory"}:
            raise ResolutionError(f"invalid BBRv3 provider mode for {name}: {mode!r}")
        resolved = resolve_git_ref(repo_url, requested_ref)
        files = github_tree_files(repo_url, resolved["commit"])
        source_path = expand_series_template(
            provider.get("path_template", ""), kernel_series, f"provider {name} path"
        ).strip("/")
        if not source_path or ".." in pathlib.PurePosixPath(source_path).parts:
            raise ResolutionError(f"unsafe BBRv3 provider path for {name}: {source_path}")

        if mode == "single":
            origin_paths = [source_path] if source_path in files else []
        else:
            try:
                pattern = re.compile(provider.get("file_pattern", ""))
            except re.error as exc:
                raise ResolutionError(
                    f"invalid BBRv3 file pattern for {name}: {exc}"
                ) from exc
            prefix = source_path + "/"
            origin_paths = sorted(
                path
                for path in files
                if path.startswith(prefix)
                and "/" not in path[len(prefix) :]
                and pattern.fullmatch(pathlib.PurePosixPath(path).name)
            )
        if not origin_paths:
            attempted.append(f"{name}:{source_path}")
            continue

        install_directory = expand_series_template(
            provider.get("install_directory_template", ""),
            kernel_series,
            f"provider {name} install directory",
        )
        if not re.fullmatch(rf"(?:hack|backport)-{re.escape(kernel_series)}", install_directory):
            raise ResolutionError(
                f"unsafe BBRv3 install directory for {name}: {install_directory}"
            )

        patches: list[dict[str, Any]] = []
        for index, origin_path in enumerate(origin_paths, start=1):
            raw_url = github_raw_url(repo_url, resolved["commit"], origin_path)
            payload = download_bytes(raw_url)
            try:
                inspect_patch(payload)
            except KernelPatchError as exc:
                raise ResolutionError(
                    f"BBRv3 provider returned an invalid patch {origin_path}: {exc}"
                ) from exc
            origin_name = pathlib.PurePosixPath(origin_path).name
            if mode == "single":
                artifact_name = expand_series_template(
                    provider.get("artifact_name_template", "0001-bbrv3.patch"),
                    kernel_series,
                    f"provider {name} artifact name",
                )
                install_name = expand_series_template(
                    provider.get("install_name_template", "995-bbrv3.patch"),
                    kernel_series,
                    f"provider {name} install name",
                )
            else:
                artifact_name = origin_name
                install_name = origin_name
            for label, value in (
                ("artifact name", artifact_name),
                ("install name", install_name),
            ):
                if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.patch", value):
                    raise ResolutionError(
                        f"unsafe BBRv3 {label} for {name}: {value!r}"
                    )
            patches.append(
                {
                    "order": index,
                    "origin_path": origin_path,
                    "raw_url": raw_url,
                    "sha256": hashlib.sha256(payload).hexdigest(),
                    "artifact_path": f"bbr3/{kernel_series}/{artifact_name}",
                    "install_name": install_name,
                }
            )

        return {
            "provider": name,
            "origin_url": repo_url,
            "origin_ref": requested_ref,
            "origin_resolved_ref": resolved["resolved_ref"],
            "origin_commit": resolved["commit"],
            "install_directory": install_directory,
            "patches": patches,
        }

    detail = ", ".join(attempted) or "no configured provider"
    raise ResolutionError(
        f"no trusted BBRv3 provider contains kernel series {kernel_series}: {detail}"
    )


def safe_artifact_path(value: str, kernel_series: str) -> pathlib.PurePosixPath:
    path = pathlib.PurePosixPath(value)
    if (
        path.is_absolute()
        or ".." in path.parts
        or path.parts[:2] != ("bbr3", kernel_series)
        or len(path.parts) != 3
    ):
        raise ResolutionError(f"unsafe BBRv3 artifact path: {value!r}")
    return path


def materialize_bbr_patches(lock: dict[str, Any], output: pathlib.Path) -> int:
    validate_lock(lock)
    output.mkdir(parents=True, exist_ok=True)
    output = output.resolve()
    count = 0
    ports = lock["kernel_features"]["bbr3"]["ports"]
    for kernel_series, port in sorted(ports.items()):
        origin_url = port["origin_url"]
        origin_commit = port["origin_commit"]
        for patch in port["patches"]:
            expected_url = github_raw_url(
                origin_url, origin_commit, patch["origin_path"]
            )
            if patch.get("raw_url") != expected_url:
                raise ResolutionError(
                    f"BBRv3 immutable URL mismatch for {patch.get('origin_path')}"
                )
            relative = safe_artifact_path(patch.get("artifact_path", ""), kernel_series)
            payload = download_bytes(expected_url)
            actual = hashlib.sha256(payload).hexdigest()
            expected = require_sha256(
                patch.get("sha256", ""), f"BBRv3 patch {patch.get('origin_path')}"
            )
            if actual != expected:
                raise ResolutionError(
                    f"BBRv3 patch hash mismatch for {patch.get('origin_path')}: "
                    f"expected {expected}, got {actual}"
                )
            try:
                inspect_patch(payload)
            except KernelPatchError as exc:
                raise ResolutionError(
                    f"materialized BBRv3 patch is invalid {patch.get('origin_path')}: {exc}"
                ) from exc
            destination = output.joinpath(*relative.parts)
            destination.parent.mkdir(parents=True, exist_ok=True)
            destination.write_bytes(payload)
            count += 1
    return count


def canonical_payload(lock: dict[str, Any]) -> bytes:
    stable = copy.deepcopy(lock)
    stable.pop("resolved_at", None)
    return json.dumps(
        stable, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")


def lock_digest(lock: dict[str, Any]) -> str:
    return f"sha256:{hashlib.sha256(canonical_payload(lock)).hexdigest()}"


def validate_upstream_artifacts(
    artifacts: Any, geodata_contracts: tuple[dict[str, str], ...]
) -> None:
    expected_components = {"haproxy", "adguardhome"} | {
        contract["id"] for contract in geodata_contracts
    }
    if not isinstance(artifacts, dict) or set(artifacts) != expected_components:
        raise ResolutionError(
            "source-lock controlled artifact set differs from the source contract"
        )

    haproxy = artifacts["haproxy"]
    version = haproxy.get("version", "")
    branch = haproxy.get("branch", "")
    if (
        haproxy.get("policy") not in {"latest-lts", "exact-override"}
        or not SEMVER_RE.fullmatch(version)
        or not re.fullmatch(r"\d+\.\d+", branch)
        or not version.startswith(branch + ".")
    ):
        raise ResolutionError("HAProxy source-lock policy/version is invalid")
    expected_haproxy_url = (
        f"https://www.haproxy.org/download/{branch}/src/haproxy-{version}.tar.gz"
    )
    if haproxy.get("url") != expected_haproxy_url:
        raise ResolutionError("HAProxy source-lock URL is not the exact official release")
    require_sha256(haproxy.get("sha256", ""), "HAProxy source")

    adguard = artifacts["adguardhome"]
    version = adguard.get("version", "")
    tag = adguard.get("tag", f"v{version}")
    if (
        adguard.get("policy") not in {"latest-stable", "exact-override"}
        or not SEMVER_RE.fullmatch(version)
        or tag != f"v{version}"
    ):
        raise ResolutionError("AdGuardHome source-lock policy/version is invalid")
    require_sha1(adguard.get("tag_commit", ""), "AdGuardHome tag commit")
    source = adguard.get("source", {})
    frontend = adguard.get("frontend", {})
    if source.get("url") != (
        f"https://codeload.github.com/AdguardTeam/AdGuardHome/tar.gz/refs/tags/{tag}?"
    ):
        raise ResolutionError("AdGuardHome source URL is not the exact official tag")
    if frontend.get("url") != (
        f"https://github.com/AdguardTeam/AdGuardHome/releases/download/{tag}/"
        "AdGuardHome_frontend.tar.gz"
    ):
        raise ResolutionError("AdGuardHome frontend URL is not the exact official asset")
    require_sha256(source.get("sha256", ""), "AdGuardHome source")
    require_sha256(frontend.get("sha256", ""), "AdGuardHome frontend")

    for contract in geodata_contracts:
        name = contract["id"]
        repo = contract["repository"]
        asset = contract["release_asset"]
        entry = artifacts[name]
        tag = entry.get("tag", "")
        policy_is_valid = entry.get("policy") in {
            "latest-stable",
            "exact-override",
        }
        if not policy_is_valid or not re.fullmatch(r"[A-Za-z0-9._-]+", tag):
            raise ResolutionError(f"{name} source-lock policy/tag is invalid")
        release_root = f"https://github.com/{repo}/releases/download/{tag}"
        if entry.get("url") != f"{release_root}/{asset}":
            raise ResolutionError(f"{name} URL is not the exact {repo} release asset")
        if entry.get("checksum_url") != f"{release_root}/{asset}.sha256sum":
            raise ResolutionError(
                f"{name} checksum URL is not the exact {repo} release asset"
            )
        require_sha256(entry.get("sha256", ""), f"{name} payload")
        require_sha256(entry.get("checksum_sha256", ""), f"{name} checksum asset")


def validate_source_overlays(value: Any, repo_root: pathlib.Path) -> None:
    overlay_contracts = load_source_overlay_contracts(repo_root)
    if not isinstance(value, dict):
        raise ResolutionError("source-lock source_overlays entry must be an object")
    expected_overlay_ids = {contract["id"] for contract in overlay_contracts}
    if set(value) != expected_overlay_ids:
        raise ResolutionError("source-lock overlay repository set differs from the contract")
    for contract in overlay_contracts:
        identifier = contract["id"]
        entry = value[identifier]
        if not isinstance(entry, dict) or set(entry) != {
            "url",
            "requested_ref",
            "resolved_ref",
            "commit",
            "mappings",
        }:
            raise ResolutionError(f"source overlay {identifier} has invalid lock fields")
        if entry["url"] != contract["url"]:
            raise ResolutionError(f"source overlay {identifier} repository differs")
        if entry["requested_ref"] != contract["requested_ref"]:
            raise ResolutionError(f"source overlay {identifier} ref differs")
        if not isinstance(entry["resolved_ref"], str) or not entry[
            "resolved_ref"
        ].startswith("refs/"):
            raise ResolutionError(f"source overlay {identifier} resolved ref is invalid")
        require_sha1(entry["commit"], f"source overlay {identifier} commit")
        if entry["mappings"] != contract["mappings"]:
            raise ResolutionError(f"source overlay {identifier} mappings differ")


def validate_locked_feeds(value: Any, repo_root: pathlib.Path) -> None:
    if not isinstance(value, dict) or not value:
        raise ResolutionError("source-lock contains no feeds")

    custom_specs = parse_feeds(
        (repo_root / "feeds.custom.conf").read_text(encoding="utf-8"),
        "feeds.custom.conf",
    )
    expected_custom = {
        spec["name"]: (order, spec) for order, spec in enumerate(custom_specs)
    }
    locked_custom: set[str] = set()
    seen_orders: dict[str, set[int]] = {"custom": set(), "default": set()}
    expected_fields = {
        "type",
        "url",
        "requested_ref",
        "resolved_ref",
        "commit",
        "origin",
        "order",
    }

    for name, feed in value.items():
        if not isinstance(name, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
            raise ResolutionError(f"invalid locked feed name: {name!r}")
        if not isinstance(feed, dict) or set(feed) != expected_fields:
            raise ResolutionError(f"feed {name} has invalid lock fields")
        if feed["type"] not in {"src-git", "src-git-full"}:
            raise ResolutionError(f"feed {name} has unsupported type")
        if not isinstance(feed["url"], str) or not feed["url"].startswith("https://"):
            raise ResolutionError(f"feed {name} has an invalid URL")
        if not isinstance(feed["requested_ref"], str) or not feed["requested_ref"]:
            raise ResolutionError(f"feed {name} has an invalid requested ref")
        resolved_ref = feed["resolved_ref"]
        if not isinstance(resolved_ref, str) or not (
            resolved_ref.startswith("refs/") or SHA1_RE.fullmatch(resolved_ref)
        ):
            raise ResolutionError(f"feed {name} has an invalid resolved ref")
        require_sha1(feed["commit"], f"feed {name} commit")
        origin = feed["origin"]
        order = feed["order"]
        if (
            origin not in seen_orders
            or isinstance(order, bool)
            or not isinstance(order, int)
            or order < 0
        ):
            raise ResolutionError(f"feed {name} has invalid origin/order")
        if order in seen_orders[origin]:
            raise ResolutionError(f"feed origin {origin} reuses order {order}")
        seen_orders[origin].add(order)

        if name in expected_custom:
            expected_order, expected = expected_custom[name]
            for field, wanted in (
                ("type", expected["type"]),
                ("url", expected["url"]),
                ("requested_ref", expected["requested_ref"]),
                ("origin", "custom"),
                ("order", expected_order),
            ):
                if feed[field] != wanted:
                    raise ResolutionError(
                        f"custom feed {name} {field} differs from feeds.custom.conf"
                    )
            locked_custom.add(name)
        elif origin != "default":
            raise ResolutionError(f"source-lock contains undeclared custom feed {name}")

    missing_custom = sorted(set(expected_custom) - locked_custom)
    if missing_custom:
        raise ResolutionError(
            "source-lock misses custom feeds: " + ", ".join(missing_custom)
        )


def ordered_locked_feeds(lock: dict[str, Any]) -> list[tuple[str, dict[str, Any]]]:
    feeds = lock["feeds"]
    return sorted(
        feeds.items(),
        key=lambda item: (
            0 if item[1]["origin"] == "custom" else 1,
            item[1]["order"],
            item[0],
        ),
    )


def render_locked_feeds(lock: dict[str, Any]) -> str:
    lines = ["# Generated from source-lock.json; every feed is immutable."]
    lines.extend(
        f"{feed['type']} {name} {feed['url']}^{feed['commit']}"
        for name, feed in ordered_locked_feeds(lock)
    )
    return "\n".join(lines) + "\n"


def render_source_overlay_manifest(lock: dict[str, Any]) -> str:
    lines: list[str] = []
    for identifier in sorted(lock["source_overlays"]):
        entry = lock["source_overlays"][identifier]
        lines.append(
            "\t".join(("R", identifier, entry["url"], entry["commit"]))
        )
        lines.extend(
            "\t".join(
                (
                    "M",
                    identifier,
                    mapping["kind"],
                    mapping["source"],
                    mapping["target"],
                )
            )
            for mapping in entry["mappings"]
        )
    return "\n".join(lines) + "\n"


def locked_profile(lock: dict[str, Any], profile: str) -> dict[str, Any]:
    entry = lock["profiles"].get(profile)
    if not isinstance(entry, dict):
        raise ResolutionError(f"profile {profile} is absent from source-lock")
    return entry


def locked_profile_string(
    lock: dict[str, Any], profile: str, field: str
) -> str:
    value = locked_profile(lock, profile).get(field)
    if not isinstance(value, str) or not value:
        raise ResolutionError(f"profile {profile} has no locked {field}")
    return value


def render_profile_identity(lock: dict[str, Any], profile: str) -> str:
    locked_profile(lock, profile)
    digest = lock["profile_digests"].get(profile)
    if not isinstance(digest, str):
        raise ResolutionError(f"profile {profile} has no source-lock digest")
    return "\n".join(
        (
            f"profile_digest={digest.removeprefix('sha256:')}",
            f"patch_digest={lock['patch_digest'].removeprefix('sha256:')}",
            f"openwrt_commit={lock['openwrt']['commit']}",
        )
    ) + "\n"


def render_profile_kernel_plan(lock: dict[str, Any], profile: str) -> str:
    """Render the fixed-order kernel/BBRv3 plan consumed by shell orchestration."""

    entry = locked_profile(lock, profile)
    series = locked_profile_string(lock, profile, "kernel_series")
    bbr = lock["kernel_features"]["bbr3"]
    if bbr["profile_kernel_series"].get(profile) != series:
        raise ResolutionError(
            f"profile and BBRv3 kernel series disagree in source-lock: {profile}"
        )
    port = bbr["ports"].get(series)
    if not isinstance(port, dict):
        raise ResolutionError(f"source-lock has no BBRv3 port for kernel {series}")
    values = (
        entry["kernel_channel"],
        series,
        entry["kernel_version"],
        entry["kernel_source_sha256"],
        entry["kernel_target"],
        port["provider"],
        port["origin_url"],
        port["origin_ref"],
        port["origin_commit"],
        port["install_directory"],
    )
    if any(not isinstance(value, str) or "\n" in value for value in values):
        raise ResolutionError(f"source-lock kernel plan is unsafe for profile {profile}")
    return "\n".join(values) + "\n"


def render_bbr_patch_plan(lock: dict[str, Any], profile: str) -> str:
    series = locked_profile_string(lock, profile, "kernel_series")
    port = lock["kernel_features"]["bbr3"]["ports"][series]
    lines: list[str] = []
    for patch in port["patches"]:
        values = (
            str(patch["order"]),
            patch["artifact_path"],
            patch["sha256"],
            patch["origin_path"],
            patch["raw_url"],
            patch["install_name"],
        )
        if any("\t" in value or "\n" in value for value in values):
            raise ResolutionError(
                f"source-lock BBRv3 patch plan is unsafe for profile {profile}"
            )
        lines.append("\t".join(values))
    return "\n".join(lines) + "\n"


def materialized_bbr_patch_paths(
    lock_path: pathlib.Path, kernel_version: str
) -> tuple[pathlib.Path, ...]:
    """Validate and return the frozen patch files for one exact Linux version."""

    lock_path = lock_path.resolve()
    lock = load_lock(lock_path)
    matching = [
        (series, port)
        for series, port in lock["kernel_features"]["bbr3"]["ports"].items()
        if port.get("version") == kernel_version
    ]
    if len(matching) != 1:
        raise ResolutionError(
            f"expected one BBRv3 port for Linux {kernel_version}, found {len(matching)}"
        )
    series, port = matching[0]
    paths: list[pathlib.Path] = []
    for patch in port["patches"]:
        relative = safe_artifact_path(patch["artifact_path"], series)
        path = lock_path.parent.joinpath(*relative.parts).resolve()
        try:
            path.relative_to(lock_path.parent)
        except ValueError as exc:
            raise ResolutionError(f"materialized BBRv3 path escapes lock: {relative}") from exc
        if not path.is_file():
            raise ResolutionError(f"materialized BBRv3 patch is missing: {relative}")
        payload = path.read_bytes()
        actual = hashlib.sha256(payload).hexdigest()
        if actual != patch["sha256"]:
            raise ResolutionError(f"materialized BBRv3 patch hash differs: {relative}")
        try:
            inspect_patch(payload)
        except KernelPatchError as exc:
            raise ResolutionError(
                f"materialized BBRv3 patch is invalid {relative}: {exc}"
            ) from exc
        paths.append(path)
    return tuple(paths)


def render_lock_summary(lock: dict[str, Any]) -> str:
    lines = [f"OpenWrt: {lock['openwrt']['commit']}"]
    lines.append(
        "Source overlays: "
        + ", ".join(
            f"{name}@{entry['commit']}"
            for name, entry in sorted(lock["source_overlays"].items())
        )
    )
    lines.extend(
        f"Feed {name}: {feed['commit']}"
        for name, feed in ordered_locked_feeds(lock)
    )
    lines.extend(
        f"Artifact {name}: {artifact.get('version', artifact.get('tag'))}"
        for name, artifact in sorted(lock["upstream_artifacts"].items())
    )
    lines.extend(
        f"{profile}: Linux {locked_profile_string(lock, profile, 'kernel_version')} "
        f"({locked_profile_string(lock, profile, 'kernel_channel')})"
        for profile in sorted(lock["profiles"])
    )
    lines.extend(
        f"BBRv3 {series}: {port['provider']}@{port['origin_commit']}"
        for series, port in sorted(
            lock["kernel_features"]["bbr3"]["ports"].items()
        )
    )
    return "\n".join(lines) + "\n"


def validate_lock(
    lock: dict[str, Any], repo_root: pathlib.Path | None = None
) -> None:
    if repo_root is None:
        repo_root = pathlib.Path(__file__).resolve().parent.parent
    geodata_contracts = load_geodata_contracts(repo_root)
    expected_fields = {
        "schema",
        "resolved_at",
        "repository_commit",
        "openwrt",
        "feeds",
        "source_overlays",
        "upstream_artifacts",
        "profiles",
        "kernel_features",
        "profile_digests",
        "patch_digest",
    }
    if set(lock) != expected_fields:
        raise ResolutionError(f"source-lock fields differ from schema {SOURCE_LOCK_SCHEMA}")
    if lock.get("schema") != SOURCE_LOCK_SCHEMA:
        raise ResolutionError(f"source-lock schema must be {SOURCE_LOCK_SCHEMA}")
    require_sha1(lock.get("repository_commit", ""), "repository commit")
    require_sha1(lock.get("openwrt", {}).get("commit", ""), "OpenWrt commit")
    validate_locked_feeds(lock.get("feeds"), repo_root)
    validate_source_overlays(lock.get("source_overlays"), repo_root)
    validate_upstream_artifacts(lock.get("upstream_artifacts"), geodata_contracts)
    profiles = lock.get("profiles")
    if not isinstance(profiles, dict) or not profiles:
        raise ResolutionError("source-lock contains no profiles")
    profile_digests = lock.get("profile_digests")
    if not isinstance(profile_digests, dict) or set(profile_digests) != set(profiles):
        raise ResolutionError("source-lock profile digests differ from profiles")
    profile_fields = {
        "kernel_target",
        "kernel_channel",
        "kernel_series",
        "kernel_version",
        "kernel_source_sha256",
        "target_check_regex",
        "image_pattern",
    }
    for name, entry in profiles.items():
        if not isinstance(name, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", name):
            raise ResolutionError(f"invalid source-lock profile name: {name!r}")
        if not isinstance(entry, dict) or set(entry) != profile_fields:
            raise ResolutionError(f"source-lock profile fields are invalid for {name}")
        if not re.fullmatch(r"[A-Za-z0-9_.+-]+", entry.get("kernel_target", "")):
            raise ResolutionError(f"invalid kernel target for profile {name}")
        if entry.get("kernel_channel") not in {"stable", "testing"}:
            raise ResolutionError(f"invalid kernel channel for profile {name}")
        series = entry.get("kernel_series", "")
        version = entry.get("kernel_version", "")
        if not re.fullmatch(r"[0-9]+\.[0-9]+", series):
            raise ResolutionError(f"invalid kernel series for profile {name}")
        if not re.fullmatch(rf"{re.escape(series)}\.[0-9]+", version):
            raise ResolutionError(f"invalid kernel version for profile {name}")
        require_sha256(
            entry.get("kernel_source_sha256", ""),
            f"profile {name} kernel source",
        )
        for field in ("target_check_regex", "image_pattern"):
            if not isinstance(entry.get(field), str) or not entry[field]:
                raise ResolutionError(f"profile {name} has invalid {field}")
    for name, value in profile_digests.items():
        require_sha256(value, f"profile {name} digest")
    require_sha256(lock.get("patch_digest", ""), "patch digest")

    bbr = lock.get("kernel_features", {}).get("bbr3", {})
    algorithm = bbr.get("algorithm", {})
    if (
        algorithm.get("requested_ref") != "v3"
        or algorithm.get("module_version") != 3
        or algorithm.get("runtime_name") != "bbr"
    ):
        raise ResolutionError("source-lock BBRv3 algorithm identity is invalid")
    require_sha1(algorithm.get("commit", ""), "BBRv3 algorithm HEAD")
    ports = bbr.get("ports")
    if not isinstance(ports, dict) or not ports:
        raise ResolutionError("source-lock contains no BBRv3 ports")
    for kernel_series, port in ports.items():
        if not re.fullmatch(r"[0-9]+\.[0-9]+", kernel_series):
            raise ResolutionError(f"invalid locked BBRv3 series: {kernel_series}")
        if not isinstance(port, dict):
            raise ResolutionError(f"invalid BBRv3 port for {kernel_series}")
        origin_url = port.get("origin_url", "")
        if not re.fullmatch(r"[a-z0-9][a-z0-9-]*", port.get("provider", "")):
            raise ResolutionError(f"invalid BBRv3 provider for {kernel_series}")
        if not isinstance(port.get("origin_ref"), str) or not port["origin_ref"]:
            raise ResolutionError(f"missing BBRv3 provider ref for {kernel_series}")
        origin_commit = require_sha1(
            port.get("origin_commit", ""), f"BBRv3 {kernel_series} provider commit"
        )
        github_repo_slug(origin_url)
        install_directory = port.get("install_directory", "")
        if not re.fullmatch(
            rf"(?:hack|backport)-{re.escape(kernel_series)}", install_directory
        ):
            raise ResolutionError(
                f"invalid BBRv3 install directory for {kernel_series}: {install_directory}"
            )
        patches = port.get("patches")
        if not isinstance(patches, list) or not patches:
            raise ResolutionError(f"BBRv3 port {kernel_series} contains no patches")
        if [patch.get("order") for patch in patches if isinstance(patch, dict)] != list(
            range(1, len(patches) + 1)
        ):
            raise ResolutionError(f"BBRv3 patch order is invalid for {kernel_series}")
        artifact_paths: set[str] = set()
        install_names: set[str] = set()
        for patch in patches:
            if not isinstance(patch, dict):
                raise ResolutionError(f"invalid BBRv3 patch entry for {kernel_series}")
            origin_path = patch.get("origin_path", "")
            if not isinstance(origin_path, str):
                raise ResolutionError(f"unsafe BBRv3 origin path: {origin_path!r}")
            origin_parts = pathlib.PurePosixPath(origin_path)
            if origin_parts.is_absolute() or ".." in origin_parts.parts:
                raise ResolutionError(f"unsafe BBRv3 origin path: {origin_path!r}")
            expected_url = github_raw_url(origin_url, origin_commit, origin_path)
            if patch.get("raw_url") != expected_url:
                raise ResolutionError(
                    f"BBRv3 immutable URL mismatch for {kernel_series}/{origin_path}"
                )
            require_sha256(
                patch.get("sha256", ""), f"BBRv3 {kernel_series}/{origin_path}"
            )
            artifact_path = patch.get("artifact_path", "")
            safe_artifact_path(artifact_path, kernel_series)
            if artifact_path in artifact_paths:
                raise ResolutionError(f"duplicate BBRv3 artifact path: {artifact_path}")
            artifact_paths.add(artifact_path)
            install_name = patch.get("install_name", "")
            if not re.fullmatch(
                r"[A-Za-z0-9][A-Za-z0-9._-]*\.patch", install_name
            ):
                raise ResolutionError(f"unsafe BBRv3 install name: {install_name!r}")
            if install_name in install_names:
                raise ResolutionError(f"duplicate BBRv3 install name: {install_name}")
            install_names.add(install_name)

    profile_kernel_series = bbr.get("profile_kernel_series")
    if not isinstance(profile_kernel_series, dict) or not profile_kernel_series:
        raise ResolutionError("source-lock contains no BBRv3 profile mapping")
    for profile, kernel_series in profile_kernel_series.items():
        profile_entry = lock.get("profiles", {}).get(profile, {})
        if kernel_series not in ports or profile_entry.get("kernel_series") != kernel_series:
            raise ResolutionError(
                f"BBRv3 profile/kernel mapping differs for {profile}: {kernel_series}"
            )
        port = ports[kernel_series]
        if (
            port.get("version") != profile_entry.get("kernel_version")
            or port.get("source_sha256")
            != profile_entry.get("kernel_source_sha256")
        ):
            raise ResolutionError(
                f"BBRv3 port/kernel metadata differs for profile {profile}"
            )
    if set(profile_kernel_series) != set(profiles):
        raise ResolutionError("BBRv3 profile mapping differs from locked profiles")


def collect_action_refs(
    workflow_paths: Iterable[pathlib.Path],
) -> dict[str, str]:
    observed: dict[str, str] = {}
    for workflow_path in workflow_paths:
        try:
            lines = workflow_path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            raise ResolutionError(f"cannot read workflow {workflow_path}: {exc}") from exc
        for line_no, line in enumerate(lines, start=1):
            match = ACTION_USE_RE.match(line)
            if not match:
                continue
            name, ref = match.groups()
            if name.startswith("./") or name.startswith("docker://"):
                continue
            if not re.fullmatch(r"actions/[A-Za-z0-9_.-]+", name):
                raise ResolutionError(
                    f"{workflow_path}:{line_no}: only official actions/* are allowed, got {name}"
                )
            if ref != "main":
                raise ResolutionError(
                    f"{workflow_path}:{line_no}: action {name} must track main, got {ref}"
                )
            previous = observed.get(name)
            if previous is not None and previous != ref:
                raise ResolutionError(
                    f"{workflow_path}:{line_no}: action {name} uses inconsistent refs"
                )
            observed[name] = ref

    if not observed:
        raise ResolutionError("workflows contain no reusable official actions")
    return dict(sorted(observed.items()))


def validate_action_refs(workflow_paths: Iterable[pathlib.Path]) -> None:
    collect_action_refs(workflow_paths)


def resolve(
    repo_root: pathlib.Path,
    profiles: list[str],
    kernel_channel: str | None = None,
) -> dict[str, Any]:
    if not profiles:
        raise ResolutionError("at least one profile is required")
    if len(profiles) != len(set(profiles)):
        raise ResolutionError("profile list contains duplicates")
    if kernel_channel is not None:
        try:
            apply_channel_override({}, kernel_channel)
        except KernelSelectionError as exc:
            raise ResolutionError(str(exc)) from exc
    validate_action_refs(sorted((repo_root / ".github/workflows").glob("*.yml")))

    geodata_contracts = load_geodata_contracts(repo_root)
    environments = {profile: merged_profile_env(repo_root, profile) for profile in profiles}
    repo_urls = {env["REPO_URL"] for env in environments.values()}
    repo_refs = {env["REPO_REF"] for env in environments.values()}
    if len(repo_urls) != 1 or len(repo_refs) != 1:
        raise ResolutionError("all maintained profiles must share one OpenWrt source/ref")
    openwrt_url = next(iter(repo_urls))
    openwrt_ref = next(iter(repo_refs))
    openwrt = resolve_git_ref(openwrt_url, openwrt_ref)

    profile_repository = ProfileRepository(repo_root / "profiles")
    rendered_configs: dict[str, dict[str, str]] = {}
    try:
        with tempfile.TemporaryDirectory(prefix="source-lock-profiles-") as temporary:
            temporary_root = pathlib.Path(temporary)
            for profile in profiles:
                config_path = profile_repository.render_config(
                    profile, temporary_root / f"{profile}.config"
                )
                rendered_configs[profile] = parse_config(config_path)
                if kernel_channel is not None:
                    apply_channel_override(
                        rendered_configs[profile], kernel_channel
                    )
    except (ProfileModelError, KernelSelectionError) as exc:
        raise ResolutionError(str(exc)) from exc

    default_feeds_text = download_text(
        github_raw_url(openwrt_url, openwrt["commit"], "feeds.conf.default")
    )
    feed_specs = parse_feeds(default_feeds_text, "locked feeds.conf.default")
    custom_specs = parse_feeds(
        (repo_root / "feeds.custom.conf").read_text(encoding="utf-8"),
        "feeds.custom.conf",
    )
    feeds: dict[str, Any] = {}
    # A same-name custom feed is an explicit replacement for the corresponding
    # Lean default. Package-level conflicts remain governed by providers.tsv.
    for origin, order, spec in merge_feed_specs(custom_specs, feed_specs):
        name = spec["name"]
        resolved = resolve_git_ref(spec["url"], spec["requested_ref"])
        resolved["type"] = spec["type"]
        resolved["origin"] = origin
        resolved["order"] = order
        feeds[name] = resolved

    source_overlays: dict[str, Any] = {}
    for contract in load_source_overlay_contracts(repo_root):
        identifier = contract["id"]
        resolved = resolve_git_ref(contract["url"], contract["requested_ref"])
        overlay_files = github_tree_files(resolved["url"], resolved["commit"])
        missing_sources = []
        for mapping in contract["mappings"]:
            source = mapping["source"]
            if mapping["kind"] == "file":
                exists = source in overlay_files
            else:
                exists = any(path.startswith(source + "/") for path in overlay_files)
            if not exists:
                missing_sources.append(source)
        if missing_sources:
            raise ResolutionError(
                f"source overlay {identifier} misses declared paths: "
                + ", ".join(missing_sources)
            )
        resolved["mappings"] = contract["mappings"]
        source_overlays[identifier] = resolved

    profile_entries: dict[str, Any] = {}
    profile_kernel_series: dict[str, str] = {}
    ports: dict[str, Any] = {}
    kernel_versions: dict[str, dict[str, str]] = {}
    bbr_policy = load_bbr_policy(repo_root)
    bbr_algorithm = resolve_bbr_algorithm(bbr_policy)
    for profile, env in environments.items():
        target = env["KERNEL_TARGET"]
        makefile = download_text(
            github_raw_url(
                openwrt_url, openwrt["commit"], f"target/linux/{target}/Makefile"
            )
        )
        try:
            selected_kernel_channel = selected_channel(rendered_configs[profile])
            kernel_series = selected_series(makefile, selected_kernel_channel)
        except KernelSelectionError as exc:
            raise ResolutionError(f"profile {profile}: {exc}") from exc
        if kernel_series not in kernel_versions:
            kernel_metadata = download_text(
                github_raw_url(
                    openwrt_url,
                    openwrt["commit"],
                    f"include/kernel-{kernel_series}",
                )
            )
            try:
                kernel_version, source_sha256 = exact_version_and_hash(
                    kernel_metadata, kernel_series
                )
            except KernelSelectionError as exc:
                raise ResolutionError(f"profile {profile}: {exc}") from exc
            kernel_versions[kernel_series] = {
                "version": kernel_version,
                "source_sha256": source_sha256,
            }
        profile_kernel_series[profile] = kernel_series
        profile_entries[profile] = {
            "kernel_target": target,
            "kernel_channel": selected_kernel_channel,
            "kernel_series": kernel_series,
            "kernel_version": kernel_versions[kernel_series]["version"],
            "kernel_source_sha256": kernel_versions[kernel_series]["source_sha256"],
            "target_check_regex": env["TARGET_CHECK_REGEX"],
            "image_pattern": env["IMAGE_PATTERN"],
        }
        if kernel_series not in ports:
            ports[kernel_series] = resolve_bbr_port(bbr_policy, kernel_series)
            ports[kernel_series].update(kernel_versions[kernel_series])

    profile_digests = {
        profile: profile_digest(repo_root, profile) for profile in profiles
    }
    patch_digest = tree_digest([repo_root / "patchsets"], repo_root)
    geodata_artifacts = {
        contract["id"]: resolve_geodata(
            repo=contract["repository"],
            asset_name=contract["release_asset"],
            override_env=contract["override_env"],
        )
        for contract in geodata_contracts
    }

    repository_commit = require_sha1(
        run("git", "rev-parse", "HEAD", cwd=repo_root).strip(), "repository commit"
    )
    lock: dict[str, Any] = {
        "schema": SOURCE_LOCK_SCHEMA,
        "resolved_at": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "repository_commit": repository_commit,
        "openwrt": openwrt,
        "feeds": dict(sorted(feeds.items())),
        "source_overlays": dict(sorted(source_overlays.items())),
        "upstream_artifacts": {
            "haproxy": resolve_haproxy(),
            "adguardhome": resolve_adguardhome(),
            **geodata_artifacts,
        },
        "profiles": profile_entries,
        "kernel_features": {
            "bbr3": {
                "algorithm": bbr_algorithm,
                "profile_kernel_series": profile_kernel_series,
                "ports": ports,
            }
        },
        "profile_digests": profile_digests,
        "patch_digest": patch_digest,
    }
    validate_lock(lock, repo_root)
    return lock


def load_lock(path: pathlib.Path) -> dict[str, Any]:
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ResolutionError(f"cannot read source lock {path}: {exc}") from exc
    if not isinstance(value, dict):
        raise ResolutionError(f"source lock {path} is not a JSON object")
    validate_lock(value)
    return value


def parse_profiles(raw: str) -> list[str]:
    return [value for value in re.split(r"[\s,]+", raw.strip()) if value]


def main(argv: list[str]) -> int:
    if len(argv) < 2:
        print(
            "Usage: source_lock.py resolve <profiles> <output> [kernel-channel] | "
            "materialize <lock> <output-dir> | digest <lock> | "
            "compare <old> <new> | list-feeds <lock> | "
            "render-feeds <lock> <output> | overlay-manifest <lock> | "
            "repository-commit <lock> | kernel-versions <lock> | "
            "profile-names <lock> | profile-identity <lock> <profile> | "
            "profile-kernel-plan <lock> <profile> | "
            "bbr-patch-plan <lock> <profile> | "
            "materialized-bbr-paths <lock> <kernel-version> | "
            "openwrt-source <lock> | summary <lock> | "
            "validate-actions <workflow>...",
            file=sys.stderr,
        )
        return 2
    command = argv[1]
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    if command == "resolve" and len(argv) in {4, 5}:
        channel = argv[4] if len(argv) == 5 else None
        lock = resolve(repo_root, parse_profiles(argv[2]), channel)
        output = pathlib.Path(argv[3])
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(
            json.dumps(lock, sort_keys=True, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(lock_digest(lock))
        return 0
    if command == "materialize" and len(argv) == 4:
        lock = load_lock(pathlib.Path(argv[2]))
        count = materialize_bbr_patches(lock, pathlib.Path(argv[3]))
        print(f"Materialized {count} locked BBRv3 patch(es).")
        return 0
    if command == "digest" and len(argv) == 3:
        print(lock_digest(load_lock(pathlib.Path(argv[2]))))
        return 0
    if command == "compare" and len(argv) == 4:
        old = load_lock(pathlib.Path(argv[2]))
        new = load_lock(pathlib.Path(argv[3]))
        old_digest = lock_digest(old)
        new_digest = lock_digest(new)
        if old_digest == new_digest:
            print(f"unchanged {old_digest}")
            return 0
        print(f"changed {old_digest} -> {new_digest}")
        return 1
    if command == "list-feeds" and len(argv) == 3:
        lock = load_lock(pathlib.Path(argv[2]))
        print("\n".join(name for name, _ in ordered_locked_feeds(lock)))
        return 0
    if command == "render-feeds" and len(argv) == 4:
        lock = load_lock(pathlib.Path(argv[2]))
        output = pathlib.Path(argv[3])
        output.parent.mkdir(parents=True, exist_ok=True)
        temporary = output.with_name(f".{output.name}.source-lock-{os.getpid()}")
        temporary.write_text(render_locked_feeds(lock), encoding="utf-8", newline="\n")
        os.replace(temporary, output)
        return 0
    if command == "overlay-manifest" and len(argv) == 3:
        lock = load_lock(pathlib.Path(argv[2]))
        print(render_source_overlay_manifest(lock), end="")
        return 0
    if command == "repository-commit" and len(argv) == 3:
        print(load_lock(pathlib.Path(argv[2]))["repository_commit"])
        return 0
    if command == "kernel-versions" and len(argv) == 3:
        lock = load_lock(pathlib.Path(argv[2]))
        print(
            "\n".join(
                sorted(
                    {
                        locked_profile_string(lock, profile, "kernel_version")
                        for profile in lock["profiles"]
                    }
                )
            )
        )
        return 0
    if command == "profile-names" and len(argv) == 3:
        print("\n".join(sorted(load_lock(pathlib.Path(argv[2]))["profiles"])))
        return 0
    if command == "profile-identity" and len(argv) == 4:
        print(
            render_profile_identity(load_lock(pathlib.Path(argv[2])), argv[3]),
            end="",
        )
        return 0
    if command == "profile-kernel-plan" and len(argv) == 4:
        print(
            render_profile_kernel_plan(load_lock(pathlib.Path(argv[2])), argv[3]),
            end="",
        )
        return 0
    if command == "bbr-patch-plan" and len(argv) == 4:
        print(
            render_bbr_patch_plan(load_lock(pathlib.Path(argv[2])), argv[3]),
            end="",
        )
        return 0
    if command == "materialized-bbr-paths" and len(argv) == 4:
        print(
            "\n".join(
                str(path)
                for path in materialized_bbr_patch_paths(
                    pathlib.Path(argv[2]), argv[3]
                )
            )
        )
        return 0
    if command == "openwrt-source" and len(argv) == 3:
        entry = load_lock(pathlib.Path(argv[2]))["openwrt"]
        url = entry.get("url")
        if not isinstance(url, str) or not url.startswith("https://"):
            raise ResolutionError("source-lock OpenWrt URL is invalid")
        print(f"{url}\n{entry['commit']}")
        return 0
    if command == "summary" and len(argv) == 3:
        print(render_lock_summary(load_lock(pathlib.Path(argv[2]))), end="")
        return 0
    if command == "validate-actions" and len(argv) >= 3:
        validate_action_refs(pathlib.Path(value) for value in argv[2:])
        print("Official actions/*@main validation passed.")
        return 0
    print("invalid source-lock command or arguments", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except ResolutionError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        raise SystemExit(1)
