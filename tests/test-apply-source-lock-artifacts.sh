#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture="$repo_root/tests/fixtures/artifact-applicator"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

cp -a "$fixture/openwrt" "$tmpdir/openwrt"
cp "$fixture/source-lock.json" "$tmpdir/source-lock.json"
bash "$repo_root/scripts/apply-source-lock-artifacts.sh" \
  "$tmpdir/openwrt" "$tmpdir/source-lock.json" "$tmpdir/report.json"

grep -Fxq 'PKG_VERSION:=3.4.2' "$tmpdir/openwrt/feeds/packages/net/haproxy/Makefile"
grep -Fxq 'PKG_HASH:=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' \
  "$tmpdir/openwrt/feeds/packages/net/haproxy/Makefile"
grep -Fxq 'PKG_VERSION:=0.107.78' "$tmpdir/openwrt/feeds/kenzo/adguardhome/Makefile"
grep -Fxq 'FRONTEND_HASH:=cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc' \
  "$tmpdir/openwrt/feeds/kenzo/adguardhome/Makefile"
grep -Fxq 'GEOIP_VER:=202601010001' "$tmpdir/openwrt/feeds/xiaorouji/v2ray-geodata/Makefile"
grep -Fxq 'GEOSITE_VER:=202601010002' "$tmpdir/openwrt/feeds/xiaorouji/v2ray-geodata/Makefile"
python3 - "$tmpdir/report.json" <<'PY'
import json
import sys
report = json.load(open(sys.argv[1], encoding="utf-8"))
assert report["schema"] == 1
assert report["source_lock_digest"].startswith("sha256:")
assert set(report["components"]) == {"haproxy", "adguardhome", "v2ray-geodata"}
PY

# Multiple matching metadata fields must fail instead of editing ambiguously.
cp -a "$fixture/openwrt" "$tmpdir/ambiguous"
printf '\nPKG_HASH:=9999999999999999999999999999999999999999999999999999999999999999\n' \
  >> "$tmpdir/ambiguous/feeds/packages/net/haproxy/Makefile"
if bash "$repo_root/scripts/apply-source-lock-artifacts.sh" \
  "$tmpdir/ambiguous" "$tmpdir/source-lock.json" "$tmpdir/ambiguous-report.json" \
  >"$tmpdir/ambiguous.out" 2>&1; then
  echo "artifact applicator accepted ambiguous package metadata" >&2
  exit 1
fi
grep -q 'expected one field' "$tmpdir/ambiguous.out"

# Invalid hashes are never treated as a request to skip verification.
python3 - "$tmpdir/source-lock.json" "$tmpdir/invalid-lock.json" <<'PY'
import json
import sys
lock = json.load(open(sys.argv[1], encoding="utf-8"))
lock["upstream_artifacts"]["haproxy"]["sha256"] = "skip"
json.dump(lock, open(sys.argv[2], "w", encoding="utf-8"))
PY
cp -a "$fixture/openwrt" "$tmpdir/invalid-hash"
if bash "$repo_root/scripts/apply-source-lock-artifacts.sh" \
  "$tmpdir/invalid-hash" "$tmpdir/invalid-lock.json" "$tmpdir/invalid-report.json" \
  >"$tmpdir/invalid.out" 2>&1; then
  echo "artifact applicator accepted PKG_HASH:=skip semantics" >&2
  exit 1
fi
grep -q 'not an exact SHA256' "$tmpdir/invalid.out"

# A known competing provider must be removed before metadata application.
cp -a "$fixture/openwrt" "$tmpdir/conflict"
mkdir -p "$tmpdir/conflict/feeds/packages/net/adguardhome"
touch "$tmpdir/conflict/feeds/packages/net/adguardhome/Makefile"
if bash "$repo_root/scripts/apply-source-lock-artifacts.sh" \
  "$tmpdir/conflict" "$tmpdir/source-lock.json" "$tmpdir/conflict-report.json" \
  >"$tmpdir/conflict.out" 2>&1; then
  echo "artifact applicator accepted conflicting providers" >&2
  exit 1
fi
grep -q 'conflicting adguardhome provider' "$tmpdir/conflict.out"

echo "Locked artifact applicator tests passed."
