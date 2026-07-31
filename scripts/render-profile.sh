#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  render-profile.sh env       <profile> [output]
  render-profile.sh config    <profile> <output>
  render-profile.sh required  <profile> <output>
  render-profile.sh forbidden <profile> <output>
  render-profile.sh files     <profile> <output-directory>
  render-profile.sh list
EOF
}

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
profiles_root="${PROFILE_ROOT_OVERRIDE:-$repo_root/profiles}"
cmd="${1:-}"

profile_dir() {
  local profile="$1"

  if ! printf '%s\n' "$profile" | grep -Eq '^[a-z0-9][a-z0-9_-]*$'; then
    echo "::error::Invalid profile name: $profile" >&2
    exit 2
  fi

  if [ ! -d "$profiles_root/$profile" ] || [ "$profile" = "common" ]; then
    echo "::error::Unknown device profile: $profile" >&2
    exit 2
  fi

  printf '%s/%s\n' "$profiles_root" "$profile"
}

config_symbols() {
  sed -nE \
    -e 's/^(CONFIG_[A-Za-z0-9_+-]+)=.*/\1/p' \
    -e 's/^# (CONFIG_[A-Za-z0-9_+-]+) is not set$/\1/p' \
    "$1" | sort
}

normalized_rules() {
  sed -E 's/[[:space:]]*#.*$//; s/^[[:space:]]+//; s/[[:space:]]+$//' "$1" |
    sed '/^$/d' |
    sort
}

assert_pair_has_no_duplicates() (
  local kind="$1"
  local common_file="$2"
  local device_file="$3"
  local common_values device_values duplicates

  common_values="$(mktemp)"
  device_values="$(mktemp)"
  duplicates="$(mktemp)"
  trap 'rm -f "$common_values" "$device_values" "$duplicates"' EXIT

  case "$kind" in
    config.seed)
      config_symbols "$common_file" > "$common_values"
      config_symbols "$device_file" > "$device_values"
      ;;
    required-packages.txt|forbidden-packages.txt)
      normalized_rules "$common_file" > "$common_values"
      normalized_rules "$device_file" > "$device_values"
      ;;
    *)
      echo "::error::Unsupported profile input kind: $kind" >&2
      exit 2
      ;;
  esac

  comm -12 "$common_values" "$device_values" > "$duplicates"
  if [ -s "$duplicates" ]; then
    echo "::error::common and device profile both own entries in $kind:" >&2
    sed 's/^/  - /' "$duplicates" >&2
    exit 1
  fi
)

render_pair() {
  local kind="$1"
  local profile="$2"
  local output="$3"
  local pdir common_file device_file

  pdir="$(profile_dir "$profile")"
  common_file="$profiles_root/common/$kind"
  device_file="$pdir/$kind"

  for input in "$common_file" "$device_file"; do
    if [ ! -r "$input" ]; then
      echo "::error::Missing profile input: $input" >&2
      exit 2
    fi
  done

  assert_pair_has_no_duplicates "$kind" "$common_file" "$device_file"
  mkdir -p "$(dirname "$output")"
  {
    printf '# Generated from profiles/common/%s and profiles/%s/%s\n\n' "$kind" "$profile" "$kind"
    cat "$common_file"
    printf '\n'
    cat "$device_file"
  } > "$output"
}

render_env() (
  local profile="$1"
  local output="${2:-}"
  local pdir common_file device_file rendered

  pdir="$(profile_dir "$profile")"
  common_file="$profiles_root/common/profile.env"
  device_file="$pdir/profile.env"
  rendered="$(mktemp)"
  trap 'rm -f "$rendered"' EXIT

  for input in "$common_file" "$device_file"; do
    if [ ! -r "$input" ]; then
      echo "::error::Missing profile env: $input" >&2
      exit 2
    fi
  done

  awk -F= '
    /^[[:space:]]*($|#)/ { next }
    /^[A-Za-z_][A-Za-z0-9_]*=/ {
      key = $1
      value = substr($0, index($0, "=") + 1)
      if (!(key in seen)) order[++count] = key
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
  ' "$common_file" "$device_file" > "$rendered"

  if [ -n "$output" ]; then
    mkdir -p "$(dirname "$output")"
    cp "$rendered" "$output"
  else
    cat "$rendered"
  fi
)

list_profile_files() {
  local root="$1"
  [ -d "$root" ] || return 0
  (
    cd "$root"
    find . \( -type f -o -type l \) -print | sed 's#^\./##' | sort
  )
}

render_files() (
  local profile="$1"
  local output_dir="$2"
  local pdir common_root device_root common_list device_list duplicates relative source target

  pdir="$(profile_dir "$profile")"
  common_root="$profiles_root/common/files"
  device_root="$pdir/files"
  common_list="$(mktemp)"
  device_list="$(mktemp)"
  duplicates="$(mktemp)"
  trap 'rm -f "$common_list" "$device_list" "$duplicates"' EXIT

  list_profile_files "$common_root" > "$common_list"
  list_profile_files "$device_root" > "$device_list"
  comm -12 "$common_list" "$device_list" > "$duplicates"
  if [ -s "$duplicates" ]; then
    echo "::error::common and device rootfs files overlap:" >&2
    sed 's/^/  - /' "$duplicates" >&2
    exit 1
  fi

  mkdir -p "$output_dir"
  for root in "$common_root" "$device_root"; do
    [ -d "$root" ] || continue
    while IFS= read -r relative; do
      [ -n "$relative" ] || continue
      source="$root/$relative"
      target="$output_dir/$relative"
      if [ -e "$target" ] || [ -L "$target" ]; then
        echo "::error::Refusing to overwrite existing rootfs path: $target" >&2
        exit 1
      fi
      mkdir -p "$(dirname "$target")"
      cp -a "$source" "$target"
    done < <(list_profile_files "$root")
  done
)

case "$cmd" in
  list)
    find "$profiles_root" -mindepth 2 -maxdepth 2 -type f -name config.seed -printf '%h\n' |
      sed 's#.*/##' |
      grep -v '^common$' |
      sort
    ;;
  env)
    [ -n "${2:-}" ] || { usage; exit 2; }
    render_env "$2" "${3:-}"
    ;;
  config)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { usage; exit 2; }
    render_pair config.seed "$2" "$3"
    ;;
  forbidden)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { usage; exit 2; }
    render_pair forbidden-packages.txt "$2" "$3"
    ;;
  required)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { usage; exit 2; }
    render_pair required-packages.txt "$2" "$3"
    ;;
  files)
    [ -n "${2:-}" ] && [ -n "${3:-}" ] || { usage; exit 2; }
    render_files "$2" "$3"
    ;;
  *)
    usage
    exit 2
    ;;
esac
