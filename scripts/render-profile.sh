#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  render-profile.sh config <profile> <output>
  render-profile.sh forbidden <profile> <output>
  render-profile.sh env <profile>
  render-profile.sh list
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cmd="${1:-}"

profile_dir() {
  local profile="$1"

  if ! printf '%s\n' "$profile" | grep -Eq '^[a-z0-9_-]+$'; then
    echo "::error::Invalid profile name: $profile" >&2
    exit 2
  fi

  if [ ! -d "$repo_root/profiles/$profile" ]; then
    echo "::error::Unknown profile: $profile" >&2
    exit 2
  fi

  printf '%s/profiles/%s\n' "$repo_root" "$profile"
}

render_pair() {
  local kind="$1"
  local profile="$2"
  local output="$3"
  local pdir

  pdir="$(profile_dir "$profile")"

  if [ ! -r "$repo_root/profiles/common/$kind" ]; then
    echo "::error::Missing common $kind" >&2
    exit 2
  fi

  if [ ! -r "$pdir/$kind" ]; then
    echo "::error::Missing $profile $kind" >&2
    exit 2
  fi

  mkdir -p "$(dirname "$output")"
  {
    printf '# Generated from profiles/common/%s and profiles/%s/%s\n\n' "$kind" "$profile" "$kind"
    cat "$repo_root/profiles/common/$kind"
    printf '\n'
    cat "$pdir/$kind"
  } > "$output"
}

case "$cmd" in
  list)
    find "$repo_root/profiles" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' |
      grep -v '^common$' |
      sort
    ;;

  env)
    profile="${2:-}"
    [ -n "$profile" ] || { usage; exit 2; }
    pdir="$(profile_dir "$profile")"
    if [ ! -r "$pdir/profile.env" ]; then
      echo "::error::Missing profile env: $pdir/profile.env" >&2
      exit 2
    fi
    cat "$pdir/profile.env"
    ;;

  config)
    profile="${2:-}"
    output="${3:-}"
    [ -n "$profile" ] && [ -n "$output" ] || { usage; exit 2; }
    render_pair "config.seed" "$profile" "$output"
    ;;

  forbidden)
    profile="${2:-}"
    output="${3:-}"
    [ -n "$profile" ] && [ -n "$output" ] || { usage; exit 2; }
    render_pair "forbidden-packages.txt" "$profile" "$output"
    ;;

  *)
    usage
    exit 2
    ;;
esac
