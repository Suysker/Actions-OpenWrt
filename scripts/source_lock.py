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
import time
import urllib.error
import urllib.parse
import urllib.request
from typing import Any, Iterable


SHA1_RE = re.compile(r"^[0-9a-f]{40}$")
SHA256_RE = re.compile(r"^[0-9a-f]{64}$")
SEMVER_RE = re.compile(r"^(\d+)\.(\d+)\.(\d+)$")
FEED_RE = re.compile(r"^(src-git(?:-full)?)\s+([A-Za-z0-9_.-]+)\s+(\S+)$")


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


def parse_env(path: pathlib.Path) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_no, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        key, separator, value = line.partition("=")
        if not separator or not re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", key):
            raise ResolutionError(f"invalid env syntax in {path}:{line_no}: {raw}")
        values[key] = value
    return values


def merged_profile_env(repo_root: pathlib.Path, profile: str) -> dict[str, str]:
    common = parse_env(repo_root / "profiles/common/profile.env")
    device_path = repo_root / f"profiles/{profile}/profile.env"
    if not device_path.is_file():
        raise ResolutionError(f"unknown profile: {profile}")
    common.update(parse_env(device_path))
    if common.get("PROFILE_NAME") != profile:
        raise ResolutionError(f"profile.env PROFILE_NAME mismatch for {profile}")
    return common


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


def load_bbr_port(repo_root: pathlib.Path, kernel_series: str) -> dict[str, Any]:
    directory = repo_root / f"patchsets/common/kernel/{kernel_series}"
    series_path = directory / "series"
    provenance_path = directory / "provenance.json"
    if not series_path.is_file() or not provenance_path.is_file():
        raise ResolutionError(
            f"no versioned BBRv3 patchset for stable kernel {kernel_series}"
        )
    series = [
        line.strip()
        for line in series_path.read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]
    if series != ["0001-bbrv3.patch"]:
        raise ResolutionError(
            f"kernel {kernel_series} series must contain only 0001-bbrv3.patch"
        )
    provenance = json.loads(provenance_path.read_text(encoding="utf-8"))
    if provenance.get("kernel_series") != kernel_series:
        raise ResolutionError("BBRv3 provenance kernel series mismatch")
    vendored = provenance.get("vendored", {})
    origin = provenance.get("origin", {})
    algorithm = provenance.get("algorithm", {})
    vendored_path = repo_root / vendored.get("path", "")
    if not vendored_path.is_file():
        raise ResolutionError(f"vendored BBRv3 patch is missing: {vendored_path}")
    actual = hashlib.sha256(vendored_path.read_bytes()).hexdigest()
    declared = require_sha256(vendored.get("sha256", ""), "vendored BBRv3 hash")
    origin_hash = require_sha256(origin.get("sha256", ""), "origin BBRv3 hash")
    if actual != declared or actual != origin_hash:
        raise ResolutionError(
            f"BBRv3 patch digest mismatch: actual {actual}, vendored {declared}, origin {origin_hash}"
        )
    require_sha1(origin.get("commit", ""), "BBRv3 port origin commit")
    require_sha1(algorithm.get("commit", ""), "BBRv3 algorithm commit")
    if algorithm.get("module_version") != 3 or algorithm.get("runtime_name") != "bbr":
        raise ResolutionError("BBRv3 algorithm identity contract is invalid")

    origin_repo = origin.get("url", "").removesuffix(".git")
    parsed = urllib.parse.urlparse(origin_repo)
    origin_repo_path = parsed.path.strip("/")
    origin_raw_url = (
        f"https://raw.githubusercontent.com/{origin_repo_path}/{origin['commit']}/{origin['path']}"
    )
    remote_hash = download_sha256(origin_raw_url)
    if remote_hash != origin_hash:
        raise ResolutionError(
            f"immutable BBRv3 origin changed or provenance is wrong: {remote_hash}"
        )

    return {
        "origin_url": origin["url"],
        "origin_commit": origin["commit"],
        "origin_path": origin["path"],
        "origin_sha256": origin_hash,
        "origin_raw_url": origin_raw_url,
        "vendored_path": vendored["path"],
        "vendored_sha256": declared,
    }


def canonical_payload(lock: dict[str, Any]) -> bytes:
    stable = copy.deepcopy(lock)
    stable.pop("resolved_at", None)
    return json.dumps(
        stable, sort_keys=True, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8")


def lock_digest(lock: dict[str, Any]) -> str:
    return f"sha256:{hashlib.sha256(canonical_payload(lock)).hexdigest()}"


def validate_lock(lock: dict[str, Any]) -> None:
    if lock.get("schema") != 1:
        raise ResolutionError("source-lock schema must be 1")
    require_sha1(lock.get("repository_commit", ""), "repository commit")
    require_sha1(lock.get("openwrt", {}).get("commit", ""), "OpenWrt commit")
    for name, feed in lock.get("feeds", {}).items():
        require_sha1(feed.get("commit", ""), f"feed {name} commit")
    require_sha1(
        lock.get("official_golang", {}).get("commit", ""),
        "official Go feed commit",
    )
    for name, value in lock.get("actions", {}).items():
        require_sha1(value, f"action {name}")
    for name, value in lock.get("profile_digests", {}).items():
        require_sha256(value, f"profile {name} digest")
    require_sha256(lock.get("patch_digest", ""), "patch digest")


def resolve(repo_root: pathlib.Path, profiles: list[str]) -> dict[str, Any]:
    if not profiles:
        raise ResolutionError("at least one profile is required")
    if len(profiles) != len(set(profiles)):
        raise ResolutionError("profile list contains duplicates")

    environments = {profile: merged_profile_env(repo_root, profile) for profile in profiles}
    repo_urls = {env["REPO_URL"] for env in environments.values()}
    repo_refs = {env["REPO_REF"] for env in environments.values()}
    if len(repo_urls) != 1 or len(repo_refs) != 1:
        raise ResolutionError("all maintained profiles must share one OpenWrt source/ref")
    openwrt_url = next(iter(repo_urls))
    openwrt_ref = next(iter(repo_refs))
    openwrt = resolve_git_ref(openwrt_url, openwrt_ref)

    default_feeds_text = download_text(
        github_raw_url(openwrt_url, openwrt["commit"], "feeds.conf.default")
    )
    feed_specs = parse_feeds(default_feeds_text, "locked feeds.conf.default")
    custom_specs = parse_feeds(
        (repo_root / "feeds.custom.conf").read_text(encoding="utf-8"),
        "feeds.custom.conf",
    )
    all_names: set[str] = set()
    feeds: dict[str, Any] = {}
    # Custom feeds intentionally precede defaults, matching the repository's
    # historical provider priority. Critical duplicates are still resolved by
    # the explicit provider contract rather than relying on this order alone.
    for origin, specs in (("custom", custom_specs), ("default", feed_specs)):
        for order, spec in enumerate(specs):
            name = spec["name"]
            if name in all_names:
                raise ResolutionError(f"default/custom feeds reuse name {name!r}")
            all_names.add(name)
            resolved = resolve_git_ref(spec["url"], spec["requested_ref"])
            resolved["type"] = spec["type"]
            resolved["origin"] = origin
            resolved["order"] = order
            feeds[name] = resolved

    common_env = parse_env(repo_root / "profiles/common/profile.env")
    golang = resolve_git_ref(
        common_env["OFFICIAL_GOLANG_REPO"], common_env["OFFICIAL_GOLANG_REF"]
    )
    golang["subtree"] = "lang/golang"

    profile_entries: dict[str, Any] = {}
    profile_kernel_series: dict[str, str] = {}
    ports: dict[str, Any] = {}
    kernel_versions: dict[str, dict[str, str]] = {}
    for profile, env in environments.items():
        target = env["KERNEL_TARGET"]
        makefile = download_text(
            github_raw_url(
                openwrt_url, openwrt["commit"], f"target/linux/{target}/Makefile"
            )
        )
        matches = re.findall(
            r"^KERNEL_PATCHVER\s*:?=\s*([0-9]+\.[0-9]+)\s*$",
            makefile,
            re.MULTILINE,
        )
        if len(matches) != 1:
            raise ResolutionError(
                f"expected one stable KERNEL_PATCHVER for profile {profile}, found {matches}"
            )
        kernel_series = matches[0]
        if kernel_series not in kernel_versions:
            kernel_metadata = download_text(
                github_raw_url(
                    openwrt_url,
                    openwrt["commit"],
                    f"include/kernel-{kernel_series}",
                )
            )
            suffix_match = re.search(
                rf"^LINUX_VERSION-{re.escape(kernel_series)}\s*=\s*(\.[0-9]+)\s*$",
                kernel_metadata,
                re.MULTILINE,
            )
            if not suffix_match:
                raise ResolutionError(
                    f"cannot resolve exact stable Linux version for {kernel_series}"
                )
            kernel_version = kernel_series + suffix_match.group(1)
            hash_match = re.search(
                rf"^LINUX_KERNEL_HASH-{re.escape(kernel_version)}\s*=\s*([0-9a-f]{{64}})\s*$",
                kernel_metadata,
                re.MULTILINE,
            )
            if not hash_match:
                raise ResolutionError(
                    f"cannot resolve stable Linux source hash for {kernel_version}"
                )
            kernel_versions[kernel_series] = {
                "version": kernel_version,
                "source_sha256": hash_match.group(1),
            }
        profile_kernel_series[profile] = kernel_series
        profile_entries[profile] = {
            "kernel_target": target,
            "kernel_series": kernel_series,
            "kernel_version": kernel_versions[kernel_series]["version"],
            "kernel_source_sha256": kernel_versions[kernel_series]["source_sha256"],
            "target_check_regex": env["TARGET_CHECK_REGEX"],
            "image_pattern": env["IMAGE_PATTERN"],
        }
        if kernel_series not in ports:
            ports[kernel_series] = load_bbr_port(repo_root, kernel_series)
            ports[kernel_series].update(kernel_versions[kernel_series])

    profile_digests = {
        profile: tree_digest(
            [repo_root / "profiles/common", repo_root / f"profiles/{profile}"],
            repo_root,
        )
        for profile in profiles
    }
    patch_digest = tree_digest([repo_root / "patchsets"], repo_root)
    actions = json.loads(
        (repo_root / ".github/actions.lock.json").read_text(encoding="utf-8")
    )

    repository_commit = require_sha1(
        run("git", "rev-parse", "HEAD", cwd=repo_root).strip(), "repository commit"
    )
    algorithm = json.loads(
        (repo_root / f"patchsets/common/kernel/{next(iter(ports))}/provenance.json").read_text(
            encoding="utf-8"
        )
    )["algorithm"]

    lock: dict[str, Any] = {
        "schema": 1,
        "resolved_at": dt.datetime.now(dt.timezone.utc)
        .replace(microsecond=0)
        .isoformat()
        .replace("+00:00", "Z"),
        "repository_commit": repository_commit,
        "openwrt": openwrt,
        "feeds": dict(sorted(feeds.items())),
        "official_golang": golang,
        "upstream_artifacts": {
            "haproxy": resolve_haproxy(),
            "adguardhome": resolve_adguardhome(),
            "geoip": resolve_geodata(
                repo="Loyalsoldier/geoip",
                asset_name="geoip.dat",
                override_env="GEOIP_TAG",
            ),
            "geosite": resolve_geodata(
                repo="Loyalsoldier/v2ray-rules-dat",
                asset_name="geosite.dat",
                override_env="GEOSITE_TAG",
            ),
        },
        "profiles": profile_entries,
        "kernel_features": {
            "bbr3": {
                "algorithm": algorithm,
                "profile_kernel_series": profile_kernel_series,
                "ports": ports,
            }
        },
        "profile_digests": profile_digests,
        "patch_digest": patch_digest,
        "actions": actions,
    }
    validate_lock(lock)
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
            "Usage: source_lock.py resolve <profiles> <output> | digest <lock> | compare <old> <new>",
            file=sys.stderr,
        )
        return 2
    command = argv[1]
    repo_root = pathlib.Path(__file__).resolve().parent.parent
    if command == "resolve" and len(argv) == 4:
        lock = resolve(repo_root, parse_profiles(argv[2]))
        output = pathlib.Path(argv[3])
        output.parent.mkdir(parents=True, exist_ok=True)
        output.write_text(
            json.dumps(lock, sort_keys=True, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        print(lock_digest(lock))
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
    print("invalid source-lock command or arguments", file=sys.stderr)
    return 2


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except ResolutionError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        raise SystemExit(1)
