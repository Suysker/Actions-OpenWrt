#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

packages_origin="$tmpdir/openwrt-packages"
core_origin="$tmpdir/openwrt-core"
openwrt="$tmpdir/openwrt"
mkdir -p \
  "$packages_origin/lang/golang" \
  "$packages_origin/libs/libwebsockets" \
  "$packages_origin/net/nlbwmon" \
  "$packages_origin/net/unrelated" \
  "$core_origin/package/libs/gmp/patches" \
  "$core_origin/package/libs/unrelated" \
  "$openwrt/feeds/packages/lang/golang" \
  "$openwrt/feeds/packages/libs/libwebsockets" \
  "$openwrt/feeds/packages/net/nlbwmon" \
  "$openwrt/package/libs/gmp"

printf 'GO_DEFAULT_VERSION:=9.9.9\n' \
  > "$packages_origin/lang/golang/golang-values.mk"
printf 'official-libwebsockets\n' \
  > "$packages_origin/libs/libwebsockets/Makefile"
cat > "$packages_origin/net/nlbwmon/Makefile" <<'EOF'
PKG_NAME:=nlbwmon
PKG_SOURCE_VERSION:=ffffffffffffffffffffffffffffffffffffffff
PKG_MIRROR_HASH:=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
printf 'must-not-be-copied\n' > "$packages_origin/net/unrelated/Makefile"
printf 'official-gmp\n' > "$core_origin/package/libs/gmp/Makefile"
printf 'canonical-c23-fix\n' \
  > "$core_origin/package/libs/gmp/patches/001-c23.patch"
printf 'must-not-be-copied\n' > "$core_origin/package/libs/unrelated/Makefile"

printf 'old-go\n' > "$openwrt/feeds/packages/lang/golang/old"
printf 'old-libwebsockets\n' > "$openwrt/feeds/packages/libs/libwebsockets/old"
printf 'old-nlbwmon\n' > "$openwrt/feeds/packages/net/nlbwmon/old"
printf 'old-gmp\n' > "$openwrt/package/libs/gmp/old"

for origin in "$packages_origin" "$core_origin"; do
  git -C "$origin" init -q
  git -C "$origin" config user.name fixture
  git -C "$origin" config user.email fixture@example.invalid
  git -C "$origin" add .
  git -C "$origin" commit -qm fixture
done
git -C "$openwrt" init -q

packages_commit="$(git -C "$packages_origin" rev-parse HEAD)"
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
        {"source": "package/libs/gmp", "target": "package/libs/gmp"}
      ]
    },
    "openwrt-packages": {
      "url": "https://github.com/openwrt/packages.git",
      "requested_ref": "master",
      "resolved_ref": "refs/heads/master",
      "commit": "$packages_commit",
      "mappings": [
        {"source": "lang/golang", "target": "feeds/packages/lang/golang"},
        {"source": "libs/libwebsockets", "target": "feeds/packages/libs/libwebsockets"},
        {"source": "net/nlbwmon", "target": "feeds/packages/net/nlbwmon"}
      ]
    }
  }
}
EOF

git_config="$tmpdir/gitconfig"
git config --file "$git_config" \
  url."$packages_origin".insteadOf https://github.com/openwrt/packages.git
git config --file "$git_config" \
  url."$core_origin".insteadOf https://github.com/openwrt/openwrt.git

GIT_CONFIG_GLOBAL="$git_config" GIT_CONFIG_NOSYSTEM=1 \
  bash "$repo_root/scripts/sync-source-overlays.sh" \
  apply-lock "$lock" "$openwrt"

grep -Fxq 'GO_DEFAULT_VERSION:=9.9.9' \
  "$openwrt/feeds/packages/lang/golang/golang-values.mk"
grep -Fxq 'official-libwebsockets' \
  "$openwrt/feeds/packages/libs/libwebsockets/Makefile"
grep -Fxq 'PKG_SOURCE_VERSION:=ffffffffffffffffffffffffffffffffffffffff' \
  "$openwrt/feeds/packages/net/nlbwmon/Makefile"
grep -Eq '^PKG_MIRROR_HASH:=[0-9a-f]{64}$' \
  "$openwrt/feeds/packages/net/nlbwmon/Makefile"
grep -Fxq 'official-gmp' "$openwrt/package/libs/gmp/Makefile"
grep -Fxq 'canonical-c23-fix' \
  "$openwrt/package/libs/gmp/patches/001-c23.patch"
[ ! -e "$openwrt/feeds/packages/lang/golang/old" ]
[ ! -e "$openwrt/feeds/packages/libs/libwebsockets/old" ]
[ ! -e "$openwrt/feeds/packages/net/nlbwmon/old" ]
[ ! -e "$openwrt/package/libs/gmp/old" ]
[ ! -e "$openwrt/feeds/packages/net/unrelated" ]
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
