#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

core_origin="$tmpdir/openwrt-core"
openwrt="$tmpdir/openwrt"
mkdir -p \
  "$core_origin/package/libs/gmp/patches" \
  "$core_origin/package/libs/pcre2/patches" \
  "$core_origin/package/libs/unrelated" \
  "$openwrt/package/libs/gmp" \
  "$openwrt/package/libs/pcre2"

printf 'official-gmp\n' > "$core_origin/package/libs/gmp/Makefile"
printf 'canonical-c23-fix\n' \
  > "$core_origin/package/libs/gmp/patches/001-c23.patch"
printf 'official-pcre2\n' > "$core_origin/package/libs/pcre2/Makefile"
printf 'canonical-pcre2-fix\n' \
  > "$core_origin/package/libs/pcre2/patches/001-portability.patch"
printf 'must-not-be-copied\n' > "$core_origin/package/libs/unrelated/Makefile"

printf 'old-gmp\n' > "$openwrt/package/libs/gmp/old"
printf 'old-pcre2\n' > "$openwrt/package/libs/pcre2/old"

for origin in "$core_origin"; do
  git -C "$origin" init -q
  git -C "$origin" config user.name fixture
  git -C "$origin" config user.email fixture@example.invalid
  git -C "$origin" add .
  git -C "$origin" commit -qm fixture
done
git -C "$openwrt" init -q

core_commit="$(git -C "$core_origin" rev-parse HEAD)"
lock="$tmpdir/source-lock.json"
cat > "$lock" <<EOF
{
  "schema": 3,
  "source_overlays": {
    "openwrt-core": {
      "url": "https://github.com/openwrt/openwrt.git",
      "requested_ref": "master",
      "resolved_ref": "refs/heads/master",
      "commit": "$core_commit",
      "mappings": [
        {"source": "package/libs/gmp", "target": "package/libs/gmp"},
        {"source": "package/libs/pcre2", "target": "package/libs/pcre2"}
      ]
    }
  }
}
EOF

git_config="$tmpdir/gitconfig"
git config --file "$git_config" \
  url."$core_origin".insteadOf https://github.com/openwrt/openwrt.git

GIT_CONFIG_GLOBAL="$git_config" GIT_CONFIG_NOSYSTEM=1 \
  bash "$repo_root/scripts/sync-source-overlays.sh" \
  apply-lock "$lock" "$openwrt"

grep -Fxq 'official-gmp' "$openwrt/package/libs/gmp/Makefile"
grep -Fxq 'canonical-c23-fix' \
  "$openwrt/package/libs/gmp/patches/001-c23.patch"
grep -Fxq 'official-pcre2' "$openwrt/package/libs/pcre2/Makefile"
grep -Fxq 'canonical-pcre2-fix' \
  "$openwrt/package/libs/pcre2/patches/001-portability.patch"
[ ! -e "$openwrt/package/libs/gmp/old" ]
[ ! -e "$openwrt/package/libs/pcre2/old" ]
[ ! -e "$openwrt/package/libs/unrelated" ]

python3 - "$lock" "$tmpdir/unsafe-lock.json" <<'PY'
import json
import sys

lock = json.load(open(sys.argv[1], encoding="utf-8"))
lock["source_overlays"]["openwrt-core"]["mappings"][0]["target"] = "../../outside"
with open(sys.argv[2], "w", encoding="utf-8") as output:
    json.dump(lock, output)
PY
if GIT_CONFIG_GLOBAL="$git_config" GIT_CONFIG_NOSYSTEM=1 \
  bash "$repo_root/scripts/sync-source-overlays.sh" apply-lock \
  "$tmpdir/unsafe-lock.json" "$openwrt" > "$tmpdir/unsafe.out" 2>&1; then
  echo "source overlay sync accepted a lock that differs from its contract" >&2
  exit 1
fi
grep -Fq 'source overlay openwrt-core mappings differ' "$tmpdir/unsafe.out"
[ ! -e "$tmpdir/outside" ]

echo "Source overlay synchronization tests passed."
