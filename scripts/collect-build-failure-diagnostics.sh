#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  collect-build-failure-diagnostics.sh <openwrt-root> <parallel-log> <serial-log>

Replays the first package failure from an OpenWrt parallel build with one job
and V=sc. If the parallel log has no safe package target, it falls back to the
whole build with V=s. This script always returns success after collecting the
diagnostic; the caller retains responsibility for failing the original build.
EOF
}

openwrt_root="${1:-}"
parallel_log="${2:-}"
serial_log="${3:-}"

if [ "$#" -ne 3 ]; then
  usage
  exit 2
fi
[ -d "$openwrt_root" ] || {
  echo "::error::OpenWrt root does not exist: $openwrt_root" >&2
  exit 2
}
[ -r "$parallel_log" ] || {
  echo "::error::Parallel build log does not exist: $parallel_log" >&2
  exit 2
}

failed_package=""
while IFS= read -r line; do
  if [[ "$line" =~ ERROR:\ (package/[A-Za-z0-9._/-]+)\ failed\ to\ build ]]; then
    failed_package="${BASH_REMATCH[1]}"
    break
  fi
done < "$parallel_log"

mkdir -p "$(dirname "$serial_log")"
: > "$serial_log"
cd "$openwrt_root"

if [[ "$failed_package" =~ ^package(/[A-Za-z0-9._-]+)+$ ]]; then
  printf 'diagnostic_target=%s\n' "$failed_package" | tee -a "$serial_log"
  if make -j1 V=sc "$failed_package/compile" 2>&1 | tee -a "$serial_log"; then
    printf 'diagnostic_result=target-succeeded-after-parallel-failure\n' | tee -a "$serial_log"
  else
    printf 'diagnostic_result=target-failed\n' | tee -a "$serial_log"
  fi
else
  printf 'diagnostic_target=whole-world-fallback\n' | tee -a "$serial_log"
  if make -j1 V=s 2>&1 | tee -a "$serial_log"; then
    printf 'diagnostic_result=fallback-succeeded-after-parallel-failure\n' | tee -a "$serial_log"
  else
    printf 'diagnostic_result=fallback-failed\n' | tee -a "$serial_log"
  fi
fi
