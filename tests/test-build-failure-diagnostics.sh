#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

openwrt="$tmpdir/openwrt"
mkdir -p "$openwrt"
cat > "$openwrt/Makefile" <<'EOF'
all:
	@printf '%s\n' "$@" >> "$$TRACE"
	@false

package/feeds/small/tcping/compile:
	@printf '%s\n' "$@" >> "$$TRACE"
	@false
EOF

parallel_log="$tmpdir/parallel.log"
serial_log="$tmpdir/serial.log"
trace="$tmpdir/trace.log"
printf '%s\n' 'ERROR: package/feeds/small/tcping failed to build.' > "$parallel_log"
TRACE="$trace" bash "$repo_root/scripts/collect-build-failure-diagnostics.sh" \
  "$openwrt" "$parallel_log" "$serial_log"
grep -qx 'package/feeds/small/tcping/compile' "$trace"
grep -qx 'diagnostic_target=package/feeds/small/tcping' "$serial_log"
grep -qx 'diagnostic_result=target-failed' "$serial_log"

: > "$trace"
printf '%s\n' 'parallel failure without a recognized package target' > "$parallel_log"
TRACE="$trace" bash "$repo_root/scripts/collect-build-failure-diagnostics.sh" \
  "$openwrt" "$parallel_log" "$serial_log"
grep -qx 'all' "$trace"
grep -qx 'diagnostic_target=whole-world-fallback' "$serial_log"
grep -qx 'diagnostic_result=fallback-failed' "$serial_log"

echo "Build failure diagnostic tests passed."
