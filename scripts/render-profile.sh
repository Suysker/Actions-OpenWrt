#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  render-profile.sh config <profile> <output>
  render-profile.sh forbidden <profile> <output>
  render-profile.sh required <profile> <output>
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

render_env() {
  local profile="$1"
  local pdir

  pdir="$(profile_dir "$profile")"

  if [ ! -r "$repo_root/profiles/common/profile.env" ]; then
    echo "::error::Missing common profile env" >&2
    exit 2
  fi

  if [ ! -r "$pdir/profile.env" ]; then
    echo "::error::Missing profile env: $pdir/profile.env" >&2
    exit 2
  fi

  awk -F= '
    /^[[:space:]]*($|#)/ { next }

    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      key = $1
      value = substr($0, index($0, "=") + 1)
      if (!(key in seen)) {
        order[++count] = key
      }
      seen[key] = value
      next
    }

    {
      printf "::error::Invalid env line in %s:%d: %s\n", FILENAME, FNR, $0 > "/dev/stderr"
      exit 2
    }

    END {
      for (i = 1; i <= count; i++) {
        key = order[i]
        print key "=" seen[key]
      }
    }
  ' "$repo_root/profiles/common/profile.env" "$pdir/profile.env"
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
    render_env "$profile"
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

  required)
    profile="${2:-}"
    output="${3:-}"
    [ -n "$profile" ] && [ -n "$output" ] || { usage; exit 2; }
    render_pair "required-packages.txt" "$profile" "$output"
    ;;

  *)
    usage
    exit 2
    ;;
esac
