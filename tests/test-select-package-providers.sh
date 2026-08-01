#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

openwrt="$tmpdir/openwrt"
mkdir -p "$openwrt/feeds"
python3 - "$repo_root/profiles/common/providers.tsv" "$openwrt" <<'PY'
import pathlib
import sys

contract, openwrt = map(pathlib.Path, sys.argv[1:])
rows = []
for raw in contract.read_text(encoding="utf-8").splitlines():
    if not raw or raw.startswith("#"):
        continue
    component, package, expected, conflicts = raw.split("\t")
    rows.append((component, package, expected, conflicts))

expected_paths = {expected for _, _, expected, _ in rows}
for _, package, expected, _ in rows:
    path = openwrt / expected
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as output:
        output.write(f"define Package/{package}\nendef\n")

for _, _, _, conflicts in rows:
    if conflicts == "-":
        continue
    for conflict in conflicts.split(","):
        if f"{conflict}/Makefile" in expected_paths:
            raise AssertionError(f"fixture conflict overlaps expected provider: {conflict}")
        path = openwrt / conflict
        path.mkdir(parents=True, exist_ok=True)
        (path / "Makefile").write_text("conflicting-provider\n", encoding="utf-8")

untouched = openwrt / "feeds/example/untouched/Makefile"
untouched.parent.mkdir(parents=True)
untouched.write_text("must-remain\n", encoding="utf-8")
PY

report="$tmpdir/provider-report.txt"
bash "$repo_root/scripts/select-package-providers.sh" "$openwrt" "$report"
grep -Fxq 'provider-contract-v3' "$report"
grep -Fxq 'mode=apply' "$report"
bash "$repo_root/scripts/select-package-providers.sh" --check \
  "$openwrt" "$tmpdir/check-report.txt"
grep -Fxq 'mode=check' "$tmpdir/check-report.txt"

python3 - "$repo_root/profiles/common/providers.tsv" "$openwrt" "$report" <<'PY'
import pathlib
import sys

contract, openwrt, report = map(pathlib.Path, sys.argv[1:])
rows = [
    raw.split("\t")
    for raw in contract.read_text(encoding="utf-8").splitlines()
    if raw and not raw.startswith("#")
]
for component, package, expected, conflicts in rows:
    if not (openwrt / expected).is_file():
        raise AssertionError(f"selected provider disappeared: {component}/{package}")
    if conflicts != "-":
        for conflict in conflicts.split(","):
            if (openwrt / conflict).exists():
                raise AssertionError(f"conflicting provider survived: {conflict}")

if (openwrt / "feeds/example/untouched/Makefile").read_text(encoding="utf-8") != "must-remain\n":
    raise AssertionError("provider selection changed an undeclared directory")

lines = report.read_text(encoding="utf-8").splitlines()
if len([line for line in lines if line.startswith("selected\t")]) != len(rows):
    raise AssertionError("provider report omitted a selected contract row")
PY

mkdir -p "$openwrt/feeds/packages/net/adguardhome"
printf 'conflicting-provider\n' \
  > "$openwrt/feeds/packages/net/adguardhome/Makefile"
if bash "$repo_root/scripts/select-package-providers.sh" --check \
  "$openwrt" "$tmpdir/conflict-report.txt" > "$tmpdir/conflict.out" 2>&1; then
  echo "provider check accepted a declared conflict" >&2
  exit 1
fi
grep -Fq 'Conflicting adguardhome provider still exists' "$tmpdir/conflict.out"
rm -rf "$openwrt/feeds/packages/net/adguardhome"

printf 'PKG_NAME:=wrong-provider\n' \
  > "$openwrt/feeds/packages/net/haproxy/Makefile"
if bash "$repo_root/scripts/select-package-providers.sh" \
  "$openwrt" "$tmpdir/invalid-report.txt" > "$tmpdir/invalid.out" 2>&1; then
  echo "provider selector accepted a Makefile that does not define the package" >&2
  exit 1
fi
grep -Fq 'Expected provider does not define haproxy' "$tmpdir/invalid.out"

echo "Package provider selection tests passed."
