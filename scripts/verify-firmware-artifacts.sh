#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 <profile> <artifact-directory> <source-lock.json>" >&2
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profile="${1:-}"
artifact_dir="${2:-}"
source_lock="${3:-}"
[ "$#" -eq 3 ] || { usage; exit 2; }
[ -d "$artifact_dir" ] || { echo "::error::Artifact directory missing: $artifact_dir" >&2; exit 2; }
[ -r "$source_lock" ] || { echo "::error::Source lock missing: $source_lock" >&2; exit 2; }

artifact_dir="$(cd "$artifact_dir" && pwd -P)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
rendered="$tmpdir/rendered"
bash "$repo_root/scripts/render-profile.sh" bundle "$profile" "$rendered"
image_pattern="$(python3 - "$source_lock" "$profile" <<'PY'
import json, sys
lock = json.load(open(sys.argv[1], encoding="utf-8"))
entry = lock.get("profiles", {}).get(sys.argv[2])
if not isinstance(entry, dict):
    raise SystemExit(f"::error::Profile {sys.argv[2]} is absent from source-lock")
print(entry.get("image_pattern", ""))
PY
)"
[ -n "$image_pattern" ] || { echo "::error::Locked image pattern is empty" >&2; exit 1; }

mapfile -t images < <(find "$artifact_dir" -maxdepth 1 -type f -name "$image_pattern" -print)
[ "${#images[@]}" -eq 1 ] || {
  echo "::error::Expected one $profile image matching $image_pattern, found ${#images[@]}" >&2
  exit 1
}
image="${images[0]}"
[ "$(stat -c %s "$image")" -gt 1048576 ] || {
  echo "::error::Firmware image is unexpectedly small: $image" >&2
  exit 1
}
gzip -t "$image"

require_one() {
  local pattern="$1" label="$2"
  mapfile -t matches < <(find "$artifact_dir" -maxdepth 1 -type f -name "$pattern" -print)
  [ "${#matches[@]}" -eq 1 ] || {
    echo "::error::Expected one $label ($pattern), found ${#matches[@]}" >&2
    exit 1
  }
  printf '%s\n' "${matches[0]}"
}

manifest="$(require_one '*.manifest' manifest)"
config_buildinfo="$(require_one '*config.buildinfo' config.buildinfo)"
require_one '*version.buildinfo' version.buildinfo >/dev/null
require_one '*feeds.buildinfo' feeds.buildinfo >/dev/null
require_one 'profiles.json' profiles.json >/dev/null
mapfile -t sboms < <(find "$artifact_dir" -maxdepth 1 -type f \( -name '*.bom.cdx.json' -o -name '*sbom*.json' \) -print)
[ "${#sboms[@]}" -ge 1 ] || {
  echo "::error::CycloneDX SBOM is missing" >&2
  exit 1
}

for required_file in \
  source-lock.json artifact-override-report.json patch-report.txt runner-report.txt \
  bbr3-patches.tar.gz toolchain-report.txt module-report.txt provenance.json \
  openwrt.config SHA256SUMS sha256sums; do
  [ -s "$artifact_dir/$required_file" ] || {
    echo "::error::Required artifact/provenance file is missing: $required_file" >&2
    exit 1
  }
done

(
  cd "$artifact_dir"
  sha256sum -c SHA256SUMS
  sha256sum -c sha256sums
)

expected_digest="$(bash "$repo_root/scripts/resolve-source-lock.sh" digest "$source_lock")"
embedded_digest="$(bash "$repo_root/scripts/resolve-source-lock.sh" digest "$artifact_dir/source-lock.json")"
[ "$expected_digest" = "$embedded_digest" ] || {
  echo "::error::Embedded source-lock differs from the build lock" >&2
  exit 1
}

python3 - "$repo_root" "$profile" "$manifest" "$config_buildinfo" \
  "$artifact_dir" "$expected_digest" "$rendered/config.seed" \
  "$rendered/required.txt" "$rendered/forbidden.txt" <<'PY'
import json
import hashlib
import pathlib
import re
import sys
import tarfile

root = pathlib.Path(sys.argv[1])
profile = sys.argv[2]
manifest = pathlib.Path(sys.argv[3])
config_buildinfo = pathlib.Path(sys.argv[4])
artifacts = pathlib.Path(sys.argv[5])
expected_digest = sys.argv[6]
expected_config_path = pathlib.Path(sys.argv[7])
required_path = pathlib.Path(sys.argv[8])
forbidden_path = pathlib.Path(sys.argv[9])

sys.path.insert(0, str(root / "scripts"))
from profile_model import load_forbidden, load_required, parse_config

lock = json.loads((artifacts / "source-lock.json").read_text(encoding="utf-8"))
expected_bbr_patches = {
    patch["artifact_path"]: patch["sha256"]
    for port in lock["kernel_features"]["bbr3"]["ports"].values()
    for patch in port["patches"]
}
observed_bbr_patches = {}
with tarfile.open(artifacts / "bbr3-patches.tar.gz", "r:gz") as archive:
    for member in archive.getmembers():
        if member.isdir():
            continue
        unsafe = (
            not member.isfile()
            or member.name.startswith("/")
            or ".." in pathlib.PurePosixPath(member.name).parts
        )
        if unsafe:
            raise SystemExit(f"::error::Unsafe BBRv3 archive member: {member.name}")
        handle = archive.extractfile(member)
        if handle is None:
            raise SystemExit(f"::error::Cannot read BBRv3 archive member: {member.name}")
        observed_bbr_patches[member.name] = hashlib.sha256(handle.read()).hexdigest()
if observed_bbr_patches != expected_bbr_patches:
    raise SystemExit("::error::Materialized BBRv3 archive differs from source-lock")

packages = {
    line.split()[0]
    for line in manifest.read_text(encoding="utf-8").splitlines()
    if line.strip()
}
required = load_required(required_path)
for package in required.packages:
    if package not in packages:
        raise SystemExit(f"::error::Manifest misses required package {package}")

forbidden = load_forbidden(forbidden_path)
for package in forbidden.exact:
    if package in packages:
        raise SystemExit(f"::error::Manifest contains forbidden package {package}")
for expression in forbidden.regex:
    pattern = re.compile(expression)
    matches = sorted(item for item in packages if pattern.search(item))
    if matches:
        raise SystemExit(
            f"::error::Manifest packages match forbidden {pattern.pattern}: {matches}"
        )

config = config_buildinfo.read_text(encoding="utf-8", errors="replace")
expected_config = parse_config(expected_config_path)
target_optimization = expected_config.get("CONFIG_TARGET_OPTIMIZATION")
if target_optimization is None:
    raise SystemExit("::error::Rendered profile has no CONFIG_TARGET_OPTIMIZATION")
expected_optimization = f"CONFIG_TARGET_OPTIMIZATION={target_optimization}"
if expected_optimization not in config.splitlines():
    raise SystemExit(
        f"::error::config.buildinfo misses profile optimization: {expected_optimization}"
    )

override = json.loads((artifacts / "artifact-override-report.json").read_text(encoding="utf-8"))
provenance = json.loads((artifacts / "provenance.json").read_text(encoding="utf-8"))
if override.get("source_lock_digest") != expected_digest:
    raise SystemExit("::error::Artifact override report has the wrong source-lock digest")
if provenance.get("source_lock_digest") != expected_digest:
    raise SystemExit("::error::Build provenance has the wrong source-lock digest")
if provenance.get("profile") != profile:
    raise SystemExit("::error::Build provenance has the wrong profile")
if provenance.get("tcp_bbr_module_version") != "3":
    raise SystemExit("::error::Build provenance does not prove BBRv3 module version 3")
if provenance.get("sch_fq_module_present") is not True:
    raise SystemExit("::error::Build provenance does not prove sch_fq")

patch = (artifacts / "patch-report.txt").read_text(encoding="utf-8")
for expected in (
    f"source_lock_digest={expected_digest}",
    "assertion_BBR_VERSION=3",
    "assertion_runtime_name=bbr",
    "assertion_MODULE_VERSION=present",
):
    if expected not in patch:
        raise SystemExit(f"::error::Patch report misses {expected}")

module = (artifacts / "module-report.txt").read_text(encoding="utf-8")
if "tcp_bbr_version=3" not in module or "sch_fq_present=1" not in module:
    raise SystemExit("::error::Module report does not prove BBRv3 and sch_fq")
PY

echo "Firmware artifact contract passed for $profile: $(basename "$image")"
