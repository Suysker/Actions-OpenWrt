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

image_pattern="$(PYTHONPATH="$repo_root/scripts" python3 - "$source_lock" "$profile" <<'PY'
import pathlib
import sys

import source_lock

lock = source_lock.load_lock(pathlib.Path(sys.argv[1]))
entry = lock["profiles"].get(sys.argv[2])
if not isinstance(entry, dict) or not entry.get("image_pattern"):
    raise SystemExit(f"::error::Profile {sys.argv[2]} has no locked image pattern")
print(entry["image_pattern"])
PY
)"

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
python3 "$repo_root/scripts/firmware_image.py" "$image"

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
  source-lock.json build-provenance.json openwrt.config \
  SHA256SUMS sha256sums; do
  [ -s "$artifact_dir/$required_file" ] || {
    echo "::error::Required artifact file is missing: $required_file" >&2
    exit 1
  }
done

(
  cd "$artifact_dir"
  sha256sum -c SHA256SUMS
  sha256sum -c sha256sums
)

expected_digest="$(python3 "$repo_root/scripts/source_lock.py" digest "$source_lock")"
embedded_digest="$(python3 "$repo_root/scripts/source_lock.py" digest "$artifact_dir/source-lock.json")"
[ "$expected_digest" = "$embedded_digest" ] || {
  echo "::error::Embedded source-lock differs from the build lock" >&2
  exit 1
}

PYTHONPATH="$repo_root/scripts" python3 - \
  "$profile" "$manifest" "$config_buildinfo" "$artifact_dir" \
  "$expected_digest" "$rendered/config.seed" "$rendered/required.txt" \
  "$rendered/forbidden.txt" "${sboms[@]}" <<'PY'
import json
import pathlib
import re
import sys

import source_lock
from profile_model import (
    load_forbidden,
    load_required,
    parse_config,
    seed_config_problems,
)

profile = sys.argv[1]
manifest = pathlib.Path(sys.argv[2])
config_buildinfo = pathlib.Path(sys.argv[3])
artifacts = pathlib.Path(sys.argv[4])
expected_digest = sys.argv[5]
expected_config_path = pathlib.Path(sys.argv[6])
required_path = pathlib.Path(sys.argv[7])
forbidden_path = pathlib.Path(sys.argv[8])
sbom_paths = [pathlib.Path(value) for value in sys.argv[9:]]

lock = source_lock.load_lock(artifacts / "source-lock.json")
if source_lock.lock_digest(lock) != expected_digest:
    raise SystemExit("::error::Embedded source-lock digest changed during verification")
locked_profile = lock["profiles"].get(profile)
if not isinstance(locked_profile, dict):
    raise SystemExit(f"::error::Profile {profile} is absent from embedded source-lock")
kernel_version = locked_profile.get("kernel_version")

for sbom_path in sbom_paths:
    sbom = json.loads(sbom_path.read_text(encoding="utf-8"))
    if sbom.get("bomFormat") != "CycloneDX":
        raise SystemExit(f"::error::Invalid CycloneDX SBOM: {sbom_path.name}")

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
    matches = sorted(item for item in packages if re.search(expression, item))
    if matches:
        raise SystemExit(
            f"::error::Manifest packages match forbidden {expression}: {matches}"
        )

final_config_path = artifacts / "openwrt.config"
drift = seed_config_problems(expected_config_path, final_config_path)
if drift:
    raise SystemExit("::error::Delivered config differs from the profile seed: " + "; ".join(drift))
final_config = parse_config(final_config_path)
for symbol in required.configs:
    if final_config.get(symbol) != "y":
        raise SystemExit(f"::error::Delivered config misses required {symbol}")

expected_config = parse_config(expected_config_path)
target_optimization = expected_config.get("CONFIG_TARGET_OPTIMIZATION")
if target_optimization is None:
    raise SystemExit("::error::Rendered profile has no CONFIG_TARGET_OPTIMIZATION")
expected_optimization = f"CONFIG_TARGET_OPTIMIZATION={target_optimization}"
if expected_optimization not in config_buildinfo.read_text(
    encoding="utf-8", errors="replace"
).splitlines():
    raise SystemExit(
        f"::error::config.buildinfo misses profile optimization: {expected_optimization}"
    )

provenance = json.loads(
    (artifacts / "build-provenance.json").read_text(encoding="utf-8")
)
if provenance.get("schema") != 1 or provenance.get("profile") != profile:
    raise SystemExit("::error::Build provenance identity is invalid")
if provenance.get("source_lock_digest") != expected_digest:
    raise SystemExit("::error::Build provenance has the wrong source-lock digest")
if provenance.get("kernel_version") != kernel_version:
    raise SystemExit("::error::Build provenance has the wrong kernel version")

toolchain = provenance.get("toolchain", {})
if not str(toolchain.get("gcc_version", "")).startswith("15."):
    raise SystemExit("::error::Build provenance does not prove GCC 15")
if toolchain.get("external_prebuilt") is not False:
    raise SystemExit("::error::Build provenance reports an external prebuilt toolchain")

inputs = provenance.get("build_inputs", {})
if not isinstance(inputs, dict):
    raise SystemExit("::error::Build provenance inputs are invalid")
overrides = inputs.get("artifact_overrides", {})
if not isinstance(overrides, dict):
    raise SystemExit("::error::Artifact override evidence is invalid")
if overrides.get("source_lock_digest") != expected_digest:
    raise SystemExit("::error::Artifact override evidence has the wrong source-lock digest")
patches = inputs.get("patches", {})
if not isinstance(patches, dict):
    raise SystemExit("::error::Build provenance patch evidence is invalid")
if patches.get("format") != "patch-report-v2":
    raise SystemExit("::error::Build provenance has an unsupported patch report")
patch_values = patches.get("values", {})
if not isinstance(patch_values, dict):
    raise SystemExit("::error::Build provenance patch values are invalid")
for key, expected in (
    ("source_lock_digest", expected_digest),
    ("assertion_BBR_VERSION", "3"),
    ("assertion_runtime_name", "bbr"),
    ("assertion_module_version_metadata", "retained"),
):
    if patch_values.get(key) != expected:
        raise SystemExit(f"::error::Build provenance patch evidence misses {key}={expected}")
runner = inputs.get("runner", {})
if not isinstance(runner, dict) or runner.get("format") != "runner-report-v1":
    raise SystemExit("::error::Build provenance has an unsupported runner report")

sha_re = re.compile(r"[0-9a-f]{64}")


def validate_module(entry: object, *, versioned: bool) -> str:
    if not isinstance(entry, dict):
        raise SystemExit("::error::Build provenance has an invalid module entry")
    path = str(entry.get("path", ""))
    pure = pathlib.PurePosixPath(path)
    if not path or pure.is_absolute() or ".." in pure.parts:
        raise SystemExit(f"::error::Build provenance has an unsafe module path: {path}")
    if not sha_re.fullmatch(str(entry.get("sha256", ""))):
        raise SystemExit(f"::error::Build provenance has an invalid module hash: {path}")
    if versioned and entry.get("version") != "3":
        raise SystemExit(f"::error::Build provenance does not prove BBRv3: {path}")
    vermagic = str(entry.get("vermagic", ""))
    if not vermagic.startswith(str(kernel_version)):
        raise SystemExit(f"::error::Module vermagic differs from locked kernel: {path}")
    return vermagic


modules = provenance.get("kernel_modules", {})
if not isinstance(modules, dict):
    raise SystemExit("::error::Build provenance module evidence is invalid")
bbr_modules = modules.get("tcp_bbr", [])
sch_fq_modules = modules.get("sch_fq", [])
if not isinstance(bbr_modules, list) or not isinstance(sch_fq_modules, list):
    raise SystemExit("::error::Build provenance module lists are invalid")
if not bbr_modules or not sch_fq_modules:
    raise SystemExit("::error::Build provenance does not contain BBRv3 and sch_fq modules")
vermagics = {validate_module(entry, versioned=True) for entry in bbr_modules}
if len(vermagics) != 1:
    raise SystemExit("::error::Build provenance contains inconsistent BBR module vermagic")
for entry in sch_fq_modules:
    validate_module(entry, versioned=False)
PY

echo "Firmware artifact contract passed for $profile: $(basename "$image")"
