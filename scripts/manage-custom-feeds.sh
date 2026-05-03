#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  manage-custom-feeds.sh apply <feeds.custom.conf> <feeds.conf.default>
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
      sed -i "/^src-[^[:space:]]\+[[:space:]]\+$name[[:space:]]/d" "$filtered"
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
