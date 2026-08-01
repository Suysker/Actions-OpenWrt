#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

origin="$tmpdir/official-packages"
openwrt="$tmpdir/openwrt"
mkdir -p "$origin/lang/golang" "$origin/net/nlbwmon" \
  "$origin/libs/libwebsockets" "$origin/net/unrelated" \
  "$openwrt/feeds/packages/lang/golang" \
  "$openwrt/feeds/packages/net/nlbwmon" \
  "$openwrt/feeds/packages/libs/libwebsockets"

printf 'GO_DEFAULT_VERSION:=9.9.9\n' > "$origin/lang/golang/golang-values.mk"
cat > "$origin/net/nlbwmon/Makefile" <<'EOF'
PKG_NAME:=nlbwmon
PKG_SOURCE_VERSION:=ffffffffffffffffffffffffffffffffffffffff
PKG_MIRROR_HASH:=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
EOF
printf 'must-not-be-copied\n' > "$origin/net/unrelated/Makefile"
printf 'official-libwebsockets\n' > "$origin/libs/libwebsockets/Makefile"
printf 'old-go\n' > "$openwrt/feeds/packages/lang/golang/old"
printf 'old-nlbwmon\n' > "$openwrt/feeds/packages/net/nlbwmon/old"
printf 'old-libwebsockets\n' > "$openwrt/feeds/packages/libs/libwebsockets/old"

git -C "$origin" init -q
git -C "$origin" config user.name fixture
git -C "$origin" config user.email fixture@example.invalid
git -C "$origin" add .
git -C "$origin" commit -qm fixture
commit="$(git -C "$origin" rev-parse HEAD)"
lock="$tmpdir/source-lock.json"
cat > "$lock" <<EOF
{
  "schema": 2,
  "official_packages": {
    "url": "https://github.com/openwrt/packages.git",
    "commit": "$commit",
    "subtrees": ["lang/golang", "net/nlbwmon", "libs/libwebsockets"]
  }
}
EOF
git_config="$tmpdir/gitconfig"
git config --file "$git_config" \
  url."$origin".insteadOf https://github.com/openwrt/packages.git

GIT_CONFIG_GLOBAL="$git_config" GIT_CONFIG_NOSYSTEM=1 \
  bash "$repo_root/scripts/sync-official-packages.sh" apply-lock "$lock" "$openwrt"

grep -Fxq 'GO_DEFAULT_VERSION:=9.9.9' \
  "$openwrt/feeds/packages/lang/golang/golang-values.mk"
grep -Fxq 'PKG_SOURCE_VERSION:=ffffffffffffffffffffffffffffffffffffffff' \
  "$openwrt/feeds/packages/net/nlbwmon/Makefile"
grep -Eq '^PKG_MIRROR_HASH:=[0-9a-f]{64}$' \
  "$openwrt/feeds/packages/net/nlbwmon/Makefile"
grep -Fxq 'official-libwebsockets' \
  "$openwrt/feeds/packages/libs/libwebsockets/Makefile"
[ ! -e "$openwrt/feeds/packages/lang/golang/old" ]
[ ! -e "$openwrt/feeds/packages/net/nlbwmon/old" ]
[ ! -e "$openwrt/feeds/packages/libs/libwebsockets/old" ]
[ ! -e "$openwrt/feeds/packages/net/unrelated" ]

python3 - "$lock" "$tmpdir/unsafe-lock.json" <<'PY'
import json
import sys

lock = json.load(open(sys.argv[1], encoding="utf-8"))
lock["official_packages"]["subtrees"] = ["../../outside"]
with open(sys.argv[2], "w", encoding="utf-8") as output:
    json.dump(lock, output)
PY
if GIT_CONFIG_GLOBAL="$git_config" GIT_CONFIG_NOSYSTEM=1 \
  bash "$repo_root/scripts/sync-official-packages.sh" apply-lock \
  "$tmpdir/unsafe-lock.json" "$openwrt" >"$tmpdir/unsafe.out" 2>&1; then
  echo "official package sync accepted an unsafe subtree" >&2
  exit 1
fi
grep -Fq 'Unsafe official package subtree' "$tmpdir/unsafe.out"
[ ! -e "$tmpdir/outside" ]

echo "Official package subtree sync tests passed."
