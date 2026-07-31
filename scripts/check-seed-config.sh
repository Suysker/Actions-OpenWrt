#!/usr/bin/env bash
set -euo pipefail

if [ "$#" -lt 2 ]; then
  echo "Usage: $0 <seed-config> <resolved-openwrt-config> [output-dir]" >&2
  exit 2
fi

seed_path="$1"
config_path="$2"
output_dir="${3:-.}"

if [ ! -r "$seed_path" ]; then
  echo "::error::Seed config not found: $seed_path" >&2
  exit 2
fi

if [ ! -r "$config_path" ]; then
  echo "::error::Resolved OpenWrt config not found: $config_path" >&2
  exit 2
fi

mkdir -p "$output_dir"
mismatches="$output_dir/seed-config.mismatches.txt"
: > "$mismatches"

python3 - "$seed_path" "$config_path" "$mismatches" <<'PY'
import re
import sys

seed_path, config_path, mismatches_path = sys.argv[1:4]

resolved = {}
with open(config_path, encoding="utf-8", errors="replace") as config:
    for raw in config:
        line = raw.rstrip("\n").rstrip("\r")
        match = re.match(r"^(CONFIG_[^=]+)=(.*)$", line)
        if match:
            resolved[match.group(1)] = "=" + match.group(2)
            continue

        match = re.match(r"^# (CONFIG_[^ ]+) is not set$", line)
        if match:
            resolved[match.group(1)] = "notset"

problems = []
with open(seed_path, encoding="utf-8", errors="replace") as seed:
    for line_no, raw in enumerate(seed, start=1):
        line = raw.rstrip("\n").rstrip("\r").strip()
        if not line or line.startswith("# Generated"):
            continue

        selected = re.match(r"^(CONFIG_[^=]+)=(.*)$", line)
        if selected:
            symbol, value = selected.groups()
            expected = "=" + value
            actual = resolved.get(symbol)
            if actual is None:
                problems.append(
                    f"{line_no}: missing selected symbol: {symbol}{expected}"
                )
            elif actual != expected:
                problems.append(
                    f"{line_no}: changed selected symbol: {symbol} expected {expected} got {actual}"
                )
            continue

        disabled = re.match(r"^# (CONFIG_[^ ]+) is not set$", line)
        if disabled:
            symbol = disabled.group(1)
            actual = resolved.get(symbol)
            if actual is not None and actual != "notset":
                problems.append(
                    f"{line_no}: disabled symbol became selected: {symbol} got {actual}"
                )

with open(mismatches_path, "w", encoding="utf-8") as output:
    for problem in problems:
        output.write(problem + "\n")

if problems:
    print("::error::Rendered seed config did not survive make defconfig:")
    for problem in problems:
        print(f"  - {problem}")
    sys.exit(1)

print("Seed config check passed.")
PY
