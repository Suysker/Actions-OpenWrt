#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

python3 - "$repo_root" <<'PY'
import importlib.util
import json
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
spec = importlib.util.spec_from_file_location("source_lock", root / "scripts/source_lock.py")
module = importlib.util.module_from_spec(spec)
assert spec.loader is not None
spec.loader.exec_module(module)
fixtures = root / "tests/fixtures/source-lock"

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

base = {
    "schema": 1,
    "resolved_at": "2026-01-01T00:00:00Z",
    "repository_commit": "1" * 40,
    "openwrt": {"commit": "2" * 40},
    "feeds": {"packages": {"commit": "3" * 40}},
    "official_golang": {"commit": "4" * 40},
    "actions": {"actions/checkout": "5" * 40},
    "profile_digests": {"r4s": "sha256:" + "6" * 64},
    "patch_digest": "sha256:" + "7" * 64,
}
module.validate_lock(base)
changed_time = dict(base, resolved_at="2026-01-02T00:00:00Z")
assert module.lock_digest(base) == module.lock_digest(changed_time)
changed_source = json.loads(json.dumps(base))
changed_source["openwrt"]["commit"] = "8" * 40
assert module.lock_digest(base) != module.lock_digest(changed_source)

print("Source-lock resolver fixture tests passed.")
PY
