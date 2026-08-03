#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
fixture_lock="$repo_root/tests/fixtures/artifact-applicator/source-lock.json"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT
lock="$tmpdir/source-lock.json"
cp "$fixture_lock" "$lock"
python3 "$repo_root/tests/source_lock_fixtures.py" "$lock" "$repo_root"

bash "$repo_root/scripts/manage-custom-feeds.sh" apply-lock "$lock" "$tmpdir/feeds.conf.default"
mapfile -t feeds < <(grep '^src-git' "$tmpdir/feeds.conf.default")
[ "${#feeds[@]}" -eq 6 ]
[ "${feeds[0]}" = 'src-git small https://github.com/kenzok8/small.git^3333333333333333333333333333333333333333' ]
[ "${feeds[1]}" = 'src-git kenzo https://github.com/kenzok8/openwrt-packages.git^4444444444444444444444444444444444444444' ]
[ "${feeds[2]}" = 'src-git sbwml https://github.com/sbwml/luci-app-mosdns.git^5555555555555555555555555555555555555555' ]
[ "${feeds[3]}" = 'src-git xiaorouji https://github.com/Openwrt-Passwall/openwrt-passwall-packages.git^6666666666666666666666666666666666666666' ]
[ "${feeds[4]}" = 'src-git passwall https://github.com/Openwrt-Passwall/openwrt-passwall.git^7777777777777777777777777777777777777777' ]
[ "${feeds[5]}" = 'src-git packages https://github.com/openwrt/packages.git^8888888888888888888888888888888888888888' ]
! grep -Eq ';(main|master)$|\^.{0,39}$' "$tmpdir/feeds.conf.default"

openwrt="$tmpdir/openwrt"
mkdir -p "$openwrt/scripts"
cat > "$openwrt/scripts/feeds" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$FEED_LOG"
EOF
chmod +x "$openwrt/scripts/feeds"
FEED_LOG="$tmpdir/reindex.log" \
  bash "$repo_root/scripts/manage-custom-feeds.sh" reindex-lock "$lock" "$openwrt"
cat > "$tmpdir/expected-reindex.log" <<'EOF'
update -i small
update -i kenzo
update -i sbwml
update -i xiaorouji
update -i passwall
update -i packages
EOF
cmp "$tmpdir/expected-reindex.log" "$tmpdir/reindex.log"

python3 - "$lock" "$tmpdir/invalid-order.json" <<'PY'
import json
import pathlib
import sys

source, output = map(pathlib.Path, sys.argv[1:])
lock = json.loads(source.read_text(encoding="utf-8"))
lock["feeds"]["packages"]["order"] = 4
output.write_text(json.dumps(lock), encoding="utf-8")
PY
if FEED_LOG="$tmpdir/invalid-reindex.log" \
  bash "$repo_root/scripts/manage-custom-feeds.sh" reindex-lock \
  "$tmpdir/invalid-order.json" "$openwrt" > "$tmpdir/invalid.out" 2>&1; then
  echo "feed reindex accepted duplicate origin/order" >&2
  exit 1
fi
grep -Fq 'feed origin custom reuses order 4' "$tmpdir/invalid.out"
[ ! -s "$tmpdir/invalid-reindex.log" ]

echo "Locked feed rendering tests passed."
