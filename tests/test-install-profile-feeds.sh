#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

openwrt="$tmpdir/openwrt"
mkdir -p "$openwrt/scripts"
cat > "$openwrt/scripts/feeds" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$@" > "$FEEDS_RECORD"
EOF
chmod +x "$openwrt/scripts/feeds"

required="$tmpdir/required.txt"
bash "$repo_root/scripts/render-profile.sh" required r4s "$required"
FEEDS_RECORD="$tmpdir/feeds-arguments.txt" \
  bash "$repo_root/scripts/install-profile-feeds.sh" \
    "$openwrt" "$required" "$tmpdir/report.txt"

python3 - "$repo_root" "$required" "$tmpdir/feeds-arguments.txt" \
  "$tmpdir/report.txt" <<'PY'
import pathlib
import sys

repo, required_path, arguments_path, report_path = map(pathlib.Path, sys.argv[1:])
sys.path.insert(0, str(repo / "scripts"))
from profile_model import load_required

expected = sorted(load_required(required_path).packages)
arguments = arguments_path.read_text(encoding="utf-8").splitlines()
assert arguments[0] == "install"
assert "-a" not in arguments
assert arguments[1:] == expected
report = report_path.read_text(encoding="utf-8")
assert f"requested_count={len(expected)}" in report
assert len([line for line in report.splitlines() if line.startswith("requested\t")]) == len(expected)
PY

printf '# no required packages\n' > "$tmpdir/empty-required.txt"
if FEEDS_RECORD="$tmpdir/empty-arguments.txt" \
  bash "$repo_root/scripts/install-profile-feeds.sh" \
    "$openwrt" "$tmpdir/empty-required.txt" "$tmpdir/empty-report.txt" \
    > "$tmpdir/empty.out" 2>&1; then
  echo "profile feed installer accepted an empty requirement set" >&2
  exit 1
fi
grep -Fq 'Profile declares no required packages' "$tmpdir/empty.out"

echo "Profile feed installer tests passed."
