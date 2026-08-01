#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  manage-custom-feeds.sh apply <feeds.custom.conf> <feeds.conf.default>
  manage-custom-feeds.sh apply-lock <source-lock.json> <feeds.conf.default>
  manage-custom-feeds.sh reindex-lock <source-lock.json> <openwrt-root>
  manage-custom-feeds.sh refs <feeds.custom.conf>
EOF
}

trim() {
  sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

parse_feeds() {
  local feeds_file="$1"
  local raw_line line type name url extra

  if [ ! -r "$feeds_file" ]; then
    echo "::error::Custom feeds file not found: $feeds_file" >&2
    exit 2
  fi

  while IFS= read -r raw_line || [ -n "$raw_line" ]; do
    line="${raw_line%$'\r'}"
    line="${line%%#*}"
    line="$(printf '%s' "$line" | trim)"

    [ -z "$line" ] && continue

    read -r type name url extra <<< "$line"
    if [ -z "${type:-}" ] || [ -z "${name:-}" ] || [ -z "${url:-}" ] || [ -n "${extra:-}" ]; then
      echo "::error::Invalid feed line in $feeds_file: $raw_line" >&2
      exit 2
    fi

    case "$type" in
      src-git|src-git-full) ;;
      *)
        echo "::error::Only src-git/src-git-full feeds can be tracked: $raw_line" >&2
        exit 2
        ;;
    esac

    printf '%s\t%s\t%s\n' "$type" "$name" "$url"
  done < "$feeds_file"
}

cmd="${1:-}"
case "$cmd" in
  reindex-lock)
    lock_file="${2:-}"
    openwrt_root="${3:-}"

    if [ -z "$lock_file" ] || [ -z "$openwrt_root" ]; then
      usage
      exit 2
    fi
    if [ ! -r "$lock_file" ]; then
      echo "::error::Source lock not found: $lock_file" >&2
      exit 2
    fi
    if [ ! -x "$openwrt_root/scripts/feeds" ]; then
      echo "::error::OpenWrt feeds helper not found: $openwrt_root/scripts/feeds" >&2
      exit 2
    fi

    openwrt_root="$(cd "$openwrt_root" && pwd -P)"
    names_file="$(mktemp)"
    trap 'rm -f "$names_file"' EXIT
    python3 - "$lock_file" > "$names_file" <<'PY'
import json
import pathlib
import re
import sys

lock_path = pathlib.Path(sys.argv[1])
lock = json.loads(lock_path.read_text(encoding="utf-8"))
if lock.get("schema") != 3:
    raise SystemExit("::error::Unsupported source-lock schema")
feeds = lock.get("feeds")
if not isinstance(feeds, dict) or not feeds:
    raise SystemExit("::error::Source lock contains no feeds")
for name, feed in feeds.items():
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
        raise SystemExit(f"::error::Invalid locked feed name: {name}")
    if not isinstance(feed, dict):
        raise SystemExit(f"::error::Invalid locked feed entry: {name}")

ordered = sorted(
    feeds.items(),
    key=lambda item: (
        0 if item[1].get("origin") == "custom" else 1,
        item[1].get("order", -1),
        item[0],
    ),
)
seen_orders = {"custom": set(), "default": set()}
for name, feed in ordered:
    origin = feed.get("origin")
    order = feed.get("order")
    if (
        origin not in seen_orders
        or isinstance(order, bool)
        or not isinstance(order, int)
        or order < 0
        or order in seen_orders[origin]
    ):
        raise SystemExit(f"::error::Invalid locked feed origin/order: {name}")
    seen_orders[origin].add(order)
    print(name)
PY
    mapfile -t feed_names < "$names_file"
    [ "${#feed_names[@]}" -gt 0 ] || {
      echo "::error::Source lock contains no feeds" >&2
      exit 2
    }
    for feed in "${feed_names[@]}"; do
      (cd "$openwrt_root" && ./scripts/feeds update -i "$feed")
    done
    echo "Reindexed ${#feed_names[@]} source-locked feed(s)."
    ;;

  apply-lock)
    lock_file="${2:-}"
    target_file="${3:-}"

    if [ -z "$lock_file" ] || [ -z "$target_file" ]; then
      usage
      exit 2
    fi
    if [ ! -r "$lock_file" ]; then
      echo "::error::Source lock not found: $lock_file" >&2
      exit 2
    fi

    mkdir -p "$(dirname "$target_file")"
    python3 - "$lock_file" "$target_file" <<'PY'
import json
import pathlib
import re
import sys

lock_path, output_path = map(pathlib.Path, sys.argv[1:])
lock = json.loads(lock_path.read_text(encoding="utf-8"))
if lock.get("schema") != 3:
    raise SystemExit("::error::Unsupported source-lock schema")

lines = ["# Generated from source-lock.json; every feed is immutable."]
feeds = lock.get("feeds", {})
ordered = sorted(
    feeds.items(),
    key=lambda item: (
        0 if item[1].get("origin") == "custom" else 1,
        item[1].get("order", 9999),
        item[0],
    ),
)
for name, feed in ordered:
    feed_type = feed.get("type")
    url = feed.get("url")
    commit = feed.get("commit", "")
    if feed_type not in {"src-git", "src-git-full"}:
        raise SystemExit(f"::error::Unsupported locked feed type for {name}: {feed_type}")
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", name):
        raise SystemExit(f"::error::Invalid locked feed name: {name}")
    if not isinstance(url, str) or not url.startswith("https://"):
        raise SystemExit(f"::error::Invalid locked feed URL for {name}")
    if not re.fullmatch(r"[0-9a-f]{40}", commit):
        raise SystemExit(f"::error::Invalid locked feed commit for {name}")
    lines.append(f"{feed_type} {name} {url}^{commit}")

if not lines[1:]:
    raise SystemExit("::error::Source lock contains no feeds")
output_path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY
    ;;

  apply)
    feeds_file="${2:-}"
    target_file="${3:-}"

    if [ -z "$feeds_file" ] || [ -z "$target_file" ]; then
      usage
      exit 2
    fi

    if [ ! -e "$target_file" ]; then
      : > "$target_file"
    fi

    parsed="$(mktemp)"
    filtered="$(mktemp)"
    trap 'rm -f "$parsed" "$filtered"' EXIT

    parse_feeds "$feeds_file" > "$parsed"
    cp "$target_file" "$filtered"

    while IFS=$'\t' read -r type name url; do
      [ -z "${name:-}" ] && continue
      sed -i "/^src-[^[:space:]]\+[[:space:]]\+${name}[[:space:]]/d" "$filtered"
    done < "$parsed"

    {
      while IFS=$'\t' read -r type name url; do
        [ -z "${name:-}" ] && continue
        printf '%s %s %s\n' "$type" "$name" "$url"
      done < "$parsed"
      cat "$filtered"
    } > "$target_file"
    ;;

  refs)
    feeds_file="${2:-}"

    if [ -z "$feeds_file" ]; then
      usage
      exit 2
    fi

    parse_feeds "$feeds_file" | while IFS=$'\t' read -r type name url; do
      repo="$url"
      ref="HEAD"

      if [[ "$url" == *";"* ]]; then
        repo="${url%%;*}"
        ref="${url#*;}"
        case "$ref" in
          refs/*) ;;
          *) ref="refs/heads/$ref" ;;
        esac
      fi

      printf '%s %s %s\n' "$name" "$repo" "$ref"
    done
    ;;

  *)
    usage
    exit 2
    ;;
esac
