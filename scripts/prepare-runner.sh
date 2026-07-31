#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 [--dry-run] <runner-report.txt>" >&2
}

dry_run=0
if [ "${1:-}" = "--dry-run" ]; then
  dry_run=1
  shift
fi
report="${1:-}"
[ -n "$report" ] || { usage; exit 2; }

builder_root="${BUILDER_ROOT:-/builder}"
minimum_free_gib="${MIN_FREE_GIB:-45}"
[[ "$minimum_free_gib" =~ ^[0-9]+$ ]] || {
  echo "::error::MIN_FREE_GIB must be an integer" >&2
  exit 2
}

case "$builder_root" in
  /builder) ;;
  *)
    echo "::error::BUILDER_ROOT is restricted to /builder on production runners" >&2
    exit 2
    ;;
esac

mkdir -p "$(dirname "$report")"
{
  echo "runner-report-v1"
  echo "generated_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "dry_run=$dry_run"
  echo "uname=$(uname -a)"
  echo "nproc=$(nproc)"
  echo "memory_kib=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
  echo "os_release_begin"
  cat /etc/os-release
  echo "os_release_end"
  echo "compiler_begin"
  cc --version 2>&1 || true
  echo "compiler_end"
  echo "disk_before_begin"
  df -hT /
  echo "disk_before_end"
} > "$report"

if [ "$dry_run" -eq 0 ]; then
  sudo install -d -m 0755 -o "$(id -u)" -g "$(id -g)" "$builder_root"
fi

free_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"
minimum_kib=$((minimum_free_gib * 1024 * 1024))

cleanup_targets=(
  /usr/share/dotnet
  /usr/local/lib/android
  /opt/ghc
  /opt/hostedtoolcache/CodeQL
)

if [ "$free_kib" -lt "$minimum_kib" ]; then
  echo "cleanup_required=1" >> "$report"
  for target in "${cleanup_targets[@]}"; do
    [ -e "$target" ] || continue
    resolved="$(realpath -e -- "$target")"
    [ "$resolved" = "$target" ] || {
      echo "::error::Runner cleanup target resolved unexpectedly: $target -> $resolved" >&2
      exit 1
    }
    case "$resolved" in
      /usr/share/dotnet|/usr/local/lib/android|/opt/ghc|/opt/hostedtoolcache/CodeQL) ;;
      *)
        echo "::error::Runner cleanup target is outside the exact whitelist: $resolved" >&2
        exit 1
        ;;
    esac
    du -sh "$resolved" 2>/dev/null | sed 's/^/cleanup_candidate=/' >> "$report" || true
    if [ "$dry_run" -eq 0 ]; then
      sudo rm -rf -- "$resolved"
      echo "cleanup_removed=$resolved" >> "$report"
    fi
  done
else
  echo "cleanup_required=0" >> "$report"
fi

free_kib="$(df -Pk / | awk 'NR == 2 {print $4}')"
if [ "$dry_run" -eq 0 ] && [ "$free_kib" -lt "$minimum_kib" ]; then
  echo "::error::Runner has less than ${minimum_free_gib} GiB free after bounded cleanup" >&2
  exit 1
fi

cpu_jobs="$(nproc)"
memory_kib="$(awk '/^MemAvailable:/ {print $2}' /proc/meminfo)"
memory_jobs=$((memory_kib / (3 * 1024 * 1024)))
[ "$memory_jobs" -ge 1 ] || memory_jobs=1
build_jobs="$cpu_jobs"
[ "$memory_jobs" -lt "$build_jobs" ] && build_jobs="$memory_jobs"

{
  echo "free_kib_after=$free_kib"
  echo "build_jobs=$build_jobs"
  echo "disk_after_begin"
  df -hT /
  echo "disk_after_end"
} >> "$report"

if [ -n "${GITHUB_OUTPUT:-}" ]; then
  echo "build_jobs=$build_jobs" >> "$GITHUB_OUTPUT"
fi

echo "Runner preparation passed with BUILD_JOBS=$build_jobs. Report: $report"
