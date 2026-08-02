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

printf 'fixture 1\n' > "$target/fixture.manifest"
printf 'CONFIG_FIXTURE=y\n' > "$openwrt/.config"
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
        "kernel_series": "6.12",
        "kernel_version": "6.12.100",
    }
}
lock["profile_digests"] = {"fixture": "sha256:" + "6" * 64}
lock["kernel_features"]["bbr3"]["profile_kernel_series"] = {
    "fixture": "6.12"
}
path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
PY

for report in artifact patch runner; do
  printf '%s report\n' "$report" > "$temporary/$report-report.txt"
done

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

output="$temporary/output"
bash "$repo_root/scripts/collect-build-provenance.sh" \
  fixture "$openwrt" "$lock_dir/source-lock.json" \
  "$temporary/artifact-report.txt" "$temporary/patch-report.txt" \
  "$temporary/runner-report.txt" "$output"

grep -Fxq 'module-report-v2' "$output/module-report.txt"
grep -Fxq 'tcp_bbr_version=3' "$output/module-report.txt"
grep -Fxq 'tcp_bbr_vermagic=6.12.100 SMP mod_unload' \
  "$output/module-report.txt"
grep -Fxq 'tcp_bbr_candidates=2' "$output/module-report.txt"
grep -Fxq 'tcp_bbr_001_version=3' "$output/module-report.txt"
grep -Fxq 'tcp_bbr_002_version=3' "$output/module-report.txt"
grep -Fxq 'gcc_version=15.2.0' "$output/toolchain-report.txt"
(
  cd "$output"
  sha256sum -c SHA256SUMS
)
python3 - "$output/provenance.json" <<'PY'
import json
import pathlib
import sys

report = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
assert report["profile"] == "fixture"
assert report["kernel_version"] == "6.12.100"
assert report["tcp_bbr_module_version"] == "3"
assert report["tcp_bbr_vermagic"] == "6.12.100 SMP mod_unload"
assert report["gcc_version"] == "15.2.0"
PY

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
