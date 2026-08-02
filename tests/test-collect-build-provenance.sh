#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
temporary="$(mktemp -d)"
trap 'rm -rf "$temporary"' EXIT

openwrt="$temporary/openwrt"
lock_dir="$temporary/lock"
target="$openwrt/bin/targets/fixture/device"
mkdir -p \
  "$target" \
  "$openwrt/build_dir/kernel-one" \
  "$openwrt/build_dir/kernel-two" \
  "$openwrt/staging_dir/toolchain-fixture/bin" \
  "$lock_dir/bbr3/6.12"

printf 'fixture-package 1\n' > "$target/fixture.manifest"
cat > "$openwrt/.config" <<'EOF'
CONFIG_TARGET_OPTIMIZATION="-O2"
CONFIG_KEEP=y
CONFIG_PACKAGE_fixture-package=y
EOF
printf 'fixture patch\n' > "$lock_dir/bbr3/6.12/0001-bbrv3.patch"
cp "$repo_root/tests/fixtures/artifact-applicator/source-lock.json" \
  "$lock_dir/source-lock.json"
python3 "$repo_root/tests/source_lock_fixtures.py" \
  "$lock_dir/source-lock.json" "$repo_root"
python3 - "$lock_dir/source-lock.json" <<'PY'
import json
import pathlib
import sys

path = pathlib.Path(sys.argv[1])
lock = json.loads(path.read_text(encoding="utf-8"))
lock["profiles"] = {
    "fixture": {
        "kernel_target": "fixture",
        "kernel_channel": "stable",
        "kernel_series": "6.12",
        "kernel_version": "6.12.100",
        "kernel_source_sha256": "3" * 64,
        "target_check_regex": "^CONFIG_TARGET_fixture=y$",
        "image_pattern": "fixture-*.img.gz",
    }
}
lock["profile_digests"] = {"fixture": "sha256:" + "6" * 64}
lock["kernel_features"]["bbr3"]["profile_kernel_series"] = {
    "fixture": "6.12"
}
path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
PY

lock_digest="$(python3 "$repo_root/scripts/source_lock.py" \
  digest "$lock_dir/source-lock.json")"
printf '{"schema":1,"source_lock_digest":"%s","components":{}}\n' \
  "$lock_digest" > "$temporary/artifact-report.txt"
cat > "$temporary/patch-report.txt" <<EOF
patch-report-v3
source_lock_digest=$lock_digest
kernel_channel=stable
kernel_series=6.12
kernel_version=6.12.100
kernel_source_sha256=$(printf '3%.0s' {1..64})
assertion_BBR_VERSION=3
assertion_runtime_name=bbr
assertion_module_version_metadata=retained
EOF
cat > "$temporary/runner-report.txt" <<'EOF'
runner-report-v1
generated_at=2026-01-01T00:00:00Z
build_jobs=2
EOF

cat > "$temporary/module.c" <<'C'
static const char version[]
  __attribute__((section(".modinfo"), used)) = "version=3";
static const char vermagic[]
  __attribute__((section(".modinfo"), used)) =
  "vermagic=6.12.100 SMP mod_unload";
C
cc -c "$temporary/module.c" -o "$openwrt/build_dir/kernel-one/tcp_bbr.ko"
cp "$openwrt/build_dir/kernel-one/tcp_bbr.ko" \
  "$openwrt/build_dir/kernel-two/tcp_bbr.ko"
cp "$openwrt/build_dir/kernel-one/tcp_bbr.ko" \
  "$openwrt/build_dir/kernel-one/sch_fq.ko"

toolchain="$openwrt/staging_dir/toolchain-fixture/bin/x86_64-openwrt-linux-gcc"
cat > "$toolchain" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  -dumpfullversion) printf '15.2.0\n' ;;
  --version) printf 'fixture OpenWrt GCC 15.2.0\n' ;;
  *) exit 2 ;;
esac
SH
chmod +x "$toolchain"

cat > "$target/fixture-config.buildinfo" <<'EOF'
CONFIG_TARGET_OPTIMIZATION="-O2"
EOF
printf 'fixture version\n' > "$target/fixture-version.buildinfo"
printf 'fixture feeds\n' > "$target/fixture-feeds.buildinfo"
printf '{"profiles":{}}\n' > "$target/profiles.json"
printf '{"bomFormat":"CycloneDX","specVersion":"1.4","version":1}\n' \
  > "$target/fixture.bom.cdx.json"
python3 - "$target/fixture-sysupgrade.img.gz" <<'PY'
import gzip
import os
import pathlib
import sys

pathlib.Path(sys.argv[1]).write_bytes(gzip.compress(os.urandom(2 * 1024 * 1024), mtime=0))
PY
(
  cd "$target"
  find . -maxdepth 1 -type f ! -name sha256sums -printf '%P\0' |
    sort -z | xargs -0 sha256sum > sha256sums
)

output="$temporary/output"
bash "$repo_root/scripts/collect-build-provenance.sh" \
  fixture "$openwrt" "$lock_dir/source-lock.json" \
  "$temporary/artifact-report.txt" "$temporary/patch-report.txt" \
  "$temporary/runner-report.txt" "$output"

[ ! -e "$output/module-report.txt" ]
[ ! -e "$output/toolchain-report.txt" ]
[ ! -e "$output/artifact-override-report.json" ]
[ ! -e "$output/patch-report.txt" ]
[ ! -e "$output/runner-report.txt" ]
[ ! -e "$output/sha256sums" ]
[ -s "$output/openwrt-sha256sums" ]
(
  cd "$output"
  sha256sum -c SHA256SUMS
)
python3 - "$output/build-provenance.json" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert report["schema"] == 2
assert report["profile"] == "fixture"
assert report["kernel"] == {
    "channel": "stable",
    "series": "6.12",
    "version": "6.12.100",
    "source_sha256": "3" * 64,
}
assert len(report["kernel_modules"]["tcp_bbr"]) == 2
assert {entry["version"] for entry in report["kernel_modules"]["tcp_bbr"]} == {"3"}
assert {entry["vermagic"] for entry in report["kernel_modules"]["tcp_bbr"]} == {
    "6.12.100 SMP mod_unload"
}
assert len(report["kernel_modules"]["sch_fq"]) == 1
assert report["toolchain"]["gcc_version"] == "15.2.0"
assert report["toolchain"]["external_prebuilt"] is False
assert report["build_inputs"]["patches"]["format"] == "patch-report-v3"
assert report["build_inputs"]["runner"]["format"] == "runner-report-v1"
PY

profiles="$temporary/profiles"
mkdir -p "$profiles/common/files" "$profiles/fixture/files"
cat > "$profiles/common/config.seed" <<'EOF'
CONFIG_TARGET_OPTIMIZATION="-O2"
EOF
cat > "$profiles/common/required-packages.txt" <<'EOF'
package:fixture-package
config:CONFIG_KEEP
EOF
printf 'exact:forbidden-package\n' > "$profiles/common/forbidden-packages.txt"
: > "$profiles/common/profile.env"
: > "$profiles/fixture/config.seed"
: > "$profiles/fixture/required-packages.txt"
: > "$profiles/fixture/forbidden-packages.txt"
printf 'PROFILE_NAME=fixture\n' > "$profiles/fixture/profile.env"

PROFILE_ROOT_OVERRIDE="$profiles" \
  bash "$repo_root/scripts/verify-firmware-artifacts.sh" \
  fixture "$output" "$lock_dir/source-lock.json"

release="$temporary/release"
PROFILE_ROOT_OVERRIDE="$profiles" \
  bash "$repo_root/scripts/assemble-release.sh" \
  "$lock_dir/source-lock.json" "$release" 2026.08.02-r1 "fixture=$output"
[ -s "$release/openwrt-fixture-2026.08.02-r1-sysupgrade.img.gz" ]
[ -s "$release/openwrt-fixture-2026.08.02-r1-full.tar.gz" ]
[ "$(find "$release" -maxdepth 1 -type f | wc -l)" -eq 5 ]
PROFILE_ROOT_OVERRIDE="$profiles" \
  bash "$repo_root/scripts/verify-release-assets.sh" "$release"

cat > "$temporary/inconsistent.c" <<'C'
static const char version[]
  __attribute__((section(".modinfo"), used)) = "version=3";
static const char vermagic[]
  __attribute__((section(".modinfo"), used)) =
  "vermagic=6.12.100 SMP mod_unload fixture-different";
C
cc -c "$temporary/inconsistent.c" \
  -o "$openwrt/build_dir/kernel-two/tcp_bbr.ko"
if bash "$repo_root/scripts/collect-build-provenance.sh" \
  fixture "$openwrt" "$lock_dir/source-lock.json" \
  "$temporary/artifact-report.txt" "$temporary/patch-report.txt" \
  "$temporary/runner-report.txt" "$temporary/rejected" \
  > "$temporary/rejected.log" 2>&1; then
  echo "Provenance collector accepted inconsistent module candidates" >&2
  exit 1
fi
grep -Fq 'modules report inconsistent vermagic' "$temporary/rejected.log"

echo "Build provenance collection tests passed."
