#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$repo_root" <<'PY'
import importlib.util
import hashlib
import json
import pathlib
import sys
import tempfile

root = pathlib.Path(sys.argv[1])
sys.path.insert(0, str(root / "scripts"))
spec = importlib.util.spec_from_file_location("source_lock", root / "scripts/source_lock.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
fixtures = root / "tests/fixtures/source-lock"

geodata_contracts = module.load_geodata_contracts(root)
assert [item["id"] for item in geodata_contracts] == ["geoip", "geosite"]
assert [item["repository"] for item in geodata_contracts] == [
    "Loyalsoldier/geoip",
    "Loyalsoldier/v2ray-rules-dat",
]
for implementation in (
    root / "scripts/source_lock.py",
    root / "scripts/apply_source_lock_artifacts.py",
):
    source = implementation.read_text(encoding="utf-8")
    for duplicated_contract_value in (
        "Loyalsoldier/",
        "GEOIP_VER",
        "GEOSITE_VER",
        "GEOIP_TAG",
        "GEOSITE_TAG",
    ):
        assert duplicated_contract_value not in source, (
            f"{implementation.name} duplicates geodata contract value "
            f"{duplicated_contract_value}"
        )
with tempfile.TemporaryDirectory() as directory:
    temporary_root = pathlib.Path(directory)
    contract_path = temporary_root / "profiles/common/geodata-sources.json"
    contract_path.parent.mkdir(parents=True)
    invalid_contract = {
        "schema": 1,
        "components": [dict(geodata_contracts[0]), dict(geodata_contracts[0])],
    }
    contract_path.write_text(json.dumps(invalid_contract), encoding="utf-8")
    try:
        module.load_geodata_contracts(temporary_root)
    except module.ResolutionError as exc:
        assert "duplicate geodata" in str(exc)
    else:
        raise AssertionError("duplicate geodata contract entry was accepted")

overlay_contracts = module.load_source_overlay_contracts(root)
assert [item["id"] for item in overlay_contracts] == ["openwrt-core"]
assert overlay_contracts[0]["mappings"] == [
    {"source": "package/libs/gmp", "target": "package/libs/gmp"},
    {"source": "package/libs/pcre2", "target": "package/libs/pcre2"},
]
for unsafe_path in (
    "package/libs/./gmp",
    "package//libs/gmp",
    "package/libs/gmp/",
):
    try:
        module.require_overlay_path(unsafe_path, "fixture target", target=True)
    except module.ResolutionError as exc:
        assert "unsafe fixture target" in str(exc)
    else:
        raise AssertionError(f"non-canonical overlay path was accepted: {unsafe_path}")
with tempfile.TemporaryDirectory() as directory:
    temporary_root = pathlib.Path(directory)
    contract_path = temporary_root / "profiles/common/source-overlays.json"
    contract_path.parent.mkdir(parents=True)
    invalid_contract = json.loads(
        (root / "profiles/common/source-overlays.json").read_text(encoding="utf-8")
    )
    invalid_contract["repositories"][0]["mappings"][1]["target"] = "package/libs/gmp"
    contract_path.write_text(json.dumps(invalid_contract), encoding="utf-8")
    try:
        module.load_source_overlay_contracts(temporary_root)
    except module.ResolutionError as exc:
        assert "declared more than once" in str(exc)
    else:
        raise AssertionError("duplicate source overlay target was accepted")

with tempfile.TemporaryDirectory() as directory:
    digest_root = pathlib.Path(directory)
    for profile in ("common", "r4s", "x86-n5105-pve"):
        profile_root = digest_root / "profiles" / profile
        profile_root.mkdir(parents=True)
        (profile_root / "config.seed").write_text(profile, encoding="utf-8")
    common_semantics = digest_root / "profiles/common/semantics.json"
    common_semantics.write_text('{"schema":1}\n', encoding="utf-8")
    custom_feeds = digest_root / "feeds.custom.conf"
    custom_feeds.write_text(
        "src-git packages https://github.com/openwrt/packages.git;master\n",
        encoding="utf-8",
    )

    r4s_before = module.profile_digest(digest_root, "r4s")
    x86_before = module.profile_digest(digest_root, "x86-n5105-pve")
    common_semantics.write_text('{"schema":2}\n', encoding="utf-8")
    r4s_after_contract = module.profile_digest(digest_root, "r4s")
    assert r4s_after_contract != r4s_before
    assert module.profile_digest(digest_root, "x86-n5105-pve") != x86_before

    x86_after_contract = module.profile_digest(digest_root, "x86-n5105-pve")
    (digest_root / "profiles/r4s/config.seed").write_text(
        "r4s-changed", encoding="utf-8"
    )
    assert module.profile_digest(digest_root, "r4s") != r4s_after_contract
    assert module.profile_digest(digest_root, "x86-n5105-pve") == x86_after_contract

    r4s_before_feeds = module.profile_digest(digest_root, "r4s")
    x86_before_feeds = module.profile_digest(digest_root, "x86-n5105-pve")
    custom_feeds.write_text(
        "src-git packages https://github.com/openwrt/packages.git;main\n",
        encoding="utf-8",
    )
    assert module.profile_digest(digest_root, "r4s") != r4s_before_feeds
    assert module.profile_digest(digest_root, "x86-n5105-pve") != x86_before_feeds

custom_specs = module.parse_feeds(
    (root / "feeds.custom.conf").read_text(encoding="utf-8"),
    "feeds.custom.conf",
)
default_specs = module.parse_feeds(
    "\n".join(
        (
            "src-git packages https://github.com/coolsnowwolf/packages",
            "src-git luci https://github.com/coolsnowwolf/luci",
        )
    ),
    "fixture defaults",
)
merged_specs = module.merge_feed_specs(custom_specs, default_specs)
assert [(origin, spec["name"]) for origin, _, spec in merged_specs].count(
    ("custom", "packages")
) == 1
assert ("default", "packages") not in [
    (origin, spec["name"]) for origin, _, spec in merged_specs
]
assert ("default", "luci") in [
    (origin, spec["name"]) for origin, _, spec in merged_specs
]

index = (fixtures / "haproxy-index.html").read_text(encoding="utf-8")
assert module.select_haproxy_branch(index) == "3.4"
releases = json.loads((fixtures / "haproxy-releases.json").read_text(encoding="utf-8"))
assert module.select_haproxy_release(releases["releases"], None) == "3.4.2"
assert module.select_haproxy_release(releases["releases"], "3.4.1") == "3.4.1"
try:
    module.select_haproxy_release(releases["releases"], "3.4.9")
except module.ResolutionError:
    pass
else:
    raise AssertionError("unknown HAProxy override was accepted")

stable = json.loads((fixtures / "github-release-stable.json").read_text(encoding="utf-8"))
prerelease = json.loads((fixtures / "github-release-prerelease.json").read_text(encoding="utf-8"))
original_api_json = module.api_json
module.api_json = lambda _url: stable
assert module.github_release("example/project", None)["tag_name"] == "v1.2.3"
module.api_json = lambda _url: prerelease
try:
    module.github_release("example/project", None)
except module.ResolutionError:
    pass
else:
    raise AssertionError("prerelease was accepted")
module.api_json = original_api_json

assert module.parse_checksum("d" * 64 + "  geoip.dat\n", "geoip.dat") == "d" * 64
for bad in ("skip", "latest", "a" * 63):
    try:
        module.require_sha256(bad, "fixture")
    except module.ResolutionError:
        pass
    else:
        raise AssertionError(f"invalid SHA256 was accepted: {bad}")

port_commit = "9" * 40
origin_path = "6.12/0002-bbr3.patch"
raw_url = module.github_raw_url(
    "https://github.com/CachyOS/kernel-patches.git", port_commit, origin_path
)


def fixture_feeds():
    result = {}
    for order, feed in enumerate(custom_specs):
        result[feed["name"]] = {
            "type": feed["type"],
            "url": feed["url"],
            "requested_ref": feed["requested_ref"],
            "resolved_ref": (
                f"refs/heads/{feed['requested_ref']}"
                if feed["requested_ref"] != "HEAD"
                else "refs/heads/master"
            ),
            "commit": f"{order + 1:x}" * 40,
            "origin": "custom",
            "order": order,
        }
    return result


base = {
    "schema": 3,
    "resolved_at": "2026-01-01T00:00:00Z",
    "repository_commit": "1" * 40,
    "openwrt": {"commit": "2" * 40},
    "feeds": fixture_feeds(),
    "source_overlays": {
        "openwrt-core": {
            "url": "https://github.com/openwrt/openwrt.git",
            "requested_ref": "master",
            "resolved_ref": "refs/heads/master",
            "commit": "4" * 40,
            "mappings": [
                {
                    "source": "package/libs/gmp",
                    "target": "package/libs/gmp",
                },
                {
                    "source": "package/libs/pcre2",
                    "target": "package/libs/pcre2",
                },
            ],
        },
    },
    "upstream_artifacts": {
        "haproxy": {
            "policy": "latest-lts",
            "branch": "3.4",
            "version": "3.4.2",
            "url": "https://www.haproxy.org/download/3.4/src/haproxy-3.4.2.tar.gz",
            "sha256": "d" * 64,
        },
        "adguardhome": {
            "policy": "latest-stable",
            "version": "0.107.78",
            "tag": "v0.107.78",
            "tag_commit": "e" * 40,
            "source": {
                "url": "https://codeload.github.com/AdguardTeam/AdGuardHome/tar.gz/refs/tags/v0.107.78?",
                "sha256": "e" * 64,
            },
            "frontend": {
                "url": "https://github.com/AdguardTeam/AdGuardHome/releases/download/v0.107.78/AdGuardHome_frontend.tar.gz",
                "sha256": "f" * 64,
            },
        },
        "geoip": {
            "policy": "latest-stable",
            "tag": "202601010001",
            "url": "https://github.com/Loyalsoldier/geoip/releases/download/202601010001/geoip.dat",
            "sha256": "1" * 64,
            "checksum_url": "https://github.com/Loyalsoldier/geoip/releases/download/202601010001/geoip.dat.sha256sum",
            "checksum_sha256": "2" * 64,
        },
        "geosite": {
            "policy": "latest-stable",
            "tag": "202601010002",
            "url": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/202601010002/geosite.dat",
            "sha256": "3" * 64,
            "checksum_url": "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/download/202601010002/geosite.dat.sha256sum",
            "checksum_sha256": "4" * 64,
        },
    },
    "profiles": {"r4s": {"kernel_series": "6.12"}},
    "actions": {
        "actions/checkout": {
            "requested_ref": "main",
            "resolved_ref": "refs/heads/main",
            "commit": "5" * 40,
        }
    },
    "kernel_features": {
        "bbr3": {
            "algorithm": {
                "requested_ref": "v3",
                "commit": "a" * 40,
                "module_version": 3,
                "runtime_name": "bbr",
            },
            "profile_kernel_series": {"r4s": "6.12"},
            "ports": {
                "6.12": {
                    "provider": "cachyos-single",
                    "origin_url": "https://github.com/CachyOS/kernel-patches.git",
                    "origin_ref": "master",
                    "origin_commit": port_commit,
                    "install_directory": "hack-6.12",
                    "patches": [
                        {
                            "order": 1,
                            "origin_path": origin_path,
                            "raw_url": raw_url,
                            "sha256": "b" * 64,
                            "artifact_path": "bbr3/6.12/0001-bbrv3.patch",
                            "install_name": "995-bbrv3.patch",
                        }
                    ],
                }
            },
        }
    },
    "profile_digests": {"r4s": "sha256:" + "6" * 64},
    "patch_digest": "sha256:" + "7" * 64,
}
module.validate_lock(base)
wrong_packages_feed = json.loads(json.dumps(base))
wrong_packages_feed["feeds"]["packages"]["url"] = (
    "https://github.com/coolsnowwolf/packages"
)
try:
    module.validate_lock(wrong_packages_feed)
except module.ResolutionError as exc:
    assert "custom feed packages url differs" in str(exc)
else:
    raise AssertionError("incoming lock changed the canonical packages feed")

missing_custom_feed = json.loads(json.dumps(base))
del missing_custom_feed["feeds"]["sbwml"]
try:
    module.validate_lock(missing_custom_feed)
except module.ResolutionError as exc:
    assert "misses custom feeds" in str(exc)
else:
    raise AssertionError("incoming lock omitted a declared custom feed")

rollback = json.loads(json.dumps(base))
for artifact in rollback["upstream_artifacts"].values():
    artifact["policy"] = "exact-override"
module.validate_lock(rollback)
wrong_geo_owner = json.loads(json.dumps(base))
wrong_geo_owner["upstream_artifacts"]["geoip"]["url"] = (
    "https://github.com/example/geoip/releases/download/202601010001/geoip.dat"
)
try:
    module.validate_lock(wrong_geo_owner)
except module.ResolutionError as exc:
    assert "Loyalsoldier" in str(exc)
else:
    raise AssertionError("a non-Loyalsoldier GeoIP source was accepted")
changed_time = dict(base, resolved_at="2026-01-02T00:00:00Z")
assert module.lock_digest(base) == module.lock_digest(changed_time)
changed_source = json.loads(json.dumps(base))
changed_source["openwrt"]["commit"] = "8" * 40
assert module.lock_digest(base) != module.lock_digest(changed_source)

module.validate_action_refs(sorted((root / ".github/workflows").glob("*.yml")))
with tempfile.TemporaryDirectory() as directory:
    workflow = pathlib.Path(directory) / "invalid.yml"
    workflow.write_text(
        "steps:\n  - uses: actions/checkout@v7\n",
        encoding="utf-8",
    )
    try:
        module.validate_action_refs([workflow])
    except module.ResolutionError as exc:
        assert "must track main" in str(exc)
    else:
        raise AssertionError("mutable action ref was accepted")

    workflow.write_text(
        "steps:\n  - uses: example/unsafe@main\n",
        encoding="utf-8",
    )
    try:
        module.validate_action_refs([workflow])
    except module.ResolutionError as exc:
        assert "only official actions/*" in str(exc)
    else:
        raise AssertionError("third-party action was accepted")

policy = {
    "schema": 1,
    "algorithm": {
        "url": "https://github.com/google/bbr.git",
        "ref": "v3",
        "module_version": 3,
        "runtime_name": "bbr",
    },
    "providers": [
        {
            "name": "fixture-single",
            "url": "https://github.com/example/ports.git",
            "ref": "main",
            "mode": "single",
            "path_template": "{series}/bbr3.patch",
            "artifact_name_template": "0001-bbrv3.patch",
            "install_directory_template": "hack-{series}",
            "install_name_template": "995-bbrv3.patch",
        }
    ],
}
patch_payload = b"diff --git a/net/ipv4/tcp_bbr.c b/net/ipv4/tcp_bbr.c\n"
original_resolve_git_ref = module.resolve_git_ref
original_github_tree_files = module.github_tree_files
original_download_bytes = module.download_bytes
try:
    module.resolve_git_ref = lambda url, ref: {
        "url": url,
        "requested_ref": ref,
        "resolved_ref": "refs/heads/main",
        "commit": "c" * 40,
    }
    module.github_tree_files = lambda _url, _commit: {"6.12/bbr3.patch"}
    module.download_bytes = lambda _url: patch_payload
    resolved_port = module.resolve_bbr_port(policy, "6.12")
    assert resolved_port["provider"] == "fixture-single"
    assert resolved_port["patches"][0]["sha256"] == hashlib.sha256(patch_payload).hexdigest()
finally:
    module.resolve_git_ref = original_resolve_git_ref
    module.github_tree_files = original_github_tree_files
    module.download_bytes = original_download_bytes

multi_policy = json.loads(json.dumps(policy))
multi_policy["providers"] = [
    multi_policy["providers"][0],
    {
        "name": "fixture-series",
        "url": "https://github.com/example/series.git",
        "ref": "main",
        "mode": "directory",
        "path_template": "patch/kernel-{series}/bbr3",
        "file_pattern": r"010-bbr3-.*\.patch",
        "install_directory_template": "backport-{series}",
    },
]
try:
    module.resolve_git_ref = lambda url, ref: {
        "url": url,
        "requested_ref": ref,
        "resolved_ref": "refs/heads/main",
        "commit": "d" * 40,
    }
    module.github_tree_files = lambda url, _commit: (
        set()
        if url.endswith("ports.git")
        else {
            "patch/kernel-6.18/bbr3/010-bbr3-0001-first.patch",
            "patch/kernel-6.18/bbr3/010-bbr3-0002-second.patch",
        }
    )
    module.download_bytes = lambda _url: patch_payload
    resolved_multi = module.resolve_bbr_port(multi_policy, "6.18")
    assert resolved_multi["provider"] == "fixture-series"
    assert resolved_multi["install_directory"] == "backport-6.18"
    assert [item["order"] for item in resolved_multi["patches"]] == [1, 2]
    assert [item["install_name"] for item in resolved_multi["patches"]] == [
        "010-bbr3-0001-first.patch",
        "010-bbr3-0002-second.patch",
    ]
finally:
    module.resolve_git_ref = original_resolve_git_ref
    module.github_tree_files = original_github_tree_files
    module.download_bytes = original_download_bytes

materialized_lock = json.loads(json.dumps(base))
materialized_patch = materialized_lock["kernel_features"]["bbr3"]["ports"]["6.12"]["patches"][0]
materialized_patch["sha256"] = hashlib.sha256(patch_payload).hexdigest()
try:
    module.download_bytes = lambda _url: patch_payload
    with tempfile.TemporaryDirectory() as directory:
        output = pathlib.Path(directory)
        assert module.materialize_bbr_patches(materialized_lock, output) == 1
        assert (output / materialized_patch["artifact_path"]).read_bytes() == patch_payload
finally:
    module.download_bytes = original_download_bytes

print("Source-lock resolver fixture tests passed.")
PY
