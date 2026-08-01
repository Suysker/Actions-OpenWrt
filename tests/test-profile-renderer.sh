#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

mapfile -t profiles < <(bash "$repo_root/scripts/render-profile.sh" list)
[ "${#profiles[@]}" -gt 0 ]
fixture_profile="${profiles[0]}"

for profile in "${profiles[@]}"; do
  bash "$repo_root/scripts/check-profile-contract.sh" "$profile" \
    > "$tmpdir/$profile.contract.txt"
  bundle="$tmpdir/$profile.bundle"
  bash "$repo_root/scripts/render-profile.sh" bundle "$profile" "$bundle"
  python3 - "$repo_root" "$bundle/config.seed" \
    "$bundle/required.txt" "$bundle/forbidden.txt" <<'PY'
import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(sys.argv[1]) / "scripts"))
from profile_model import load_forbidden, load_required, parse_config

config = parse_config(pathlib.Path(sys.argv[2]))
required = load_required(pathlib.Path(sys.argv[3]))
forbidden = load_forbidden(pathlib.Path(sys.argv[4]))
for package in required.packages:
    assert config[f"CONFIG_PACKAGE_{package}"] == "y"
for symbol in required.configs:
    assert config[symbol] == "y"
for package in forbidden.exact:
    assert config[f"CONFIG_PACKAGE_{package}"] == "n"
PY
  if grep -q '^CONFIG_PACKAGE_luci-i18n-.*-zh-cn=y$' "$bundle/config.seed"; then
    echo "renderer emitted a hidden per-package LuCI translation seed for $profile" >&2
    exit 1
  fi
done

# A new profile directory is discovered and checked without changing checker code.
cp -a "$repo_root/profiles" "$tmpdir/discovery-profiles"
cp -a "$tmpdir/discovery-profiles/$fixture_profile" \
  "$tmpdir/discovery-profiles/generic-test"
sed -i "s/^PROFILE_NAME=$fixture_profile$/PROFILE_NAME=generic-test/" \
  "$tmpdir/discovery-profiles/generic-test/profile.env"
sed -i "s/\"$fixture_profile\\./\"generic-test./g" \
  "$tmpdir/discovery-profiles/generic-test/semantics.json"
mapfile -t discovered < <(
  PROFILE_ROOT_OVERRIDE="$tmpdir/discovery-profiles" \
    bash "$repo_root/scripts/render-profile.sh" list
)
printf '%s\n' "${discovered[@]}" | grep -qx 'generic-test'
PROFILE_ROOT_OVERRIDE="$tmpdir/discovery-profiles" \
  bash "$repo_root/scripts/check-profile-contract.sh" generic-test \
  > "$tmpdir/generic-test.contract.txt"
grep -q '^status=passed$' "$tmpdir/generic-test.contract.txt"

# A common/device symbol collision must be rejected.
cp -a "$repo_root/profiles" "$tmpdir/profiles"
printf '\nCONFIG_DEVEL=y\n' >> "$tmpdir/profiles/$fixture_profile/config.seed"
if PROFILE_ROOT_OVERRIDE="$tmpdir/profiles" \
  bash "$repo_root/scripts/render-profile.sh" config "$fixture_profile" "$tmpdir/collision.config" \
  >"$tmpdir/collision.out" 2>&1; then
  echo "renderer accepted a common/device config collision" >&2
  exit 1
fi
grep -q 'both own entries' "$tmpdir/collision.out"

# A symbol derived from required rules must not be copied into config.seed.
rm -rf "$tmpdir/profiles"
cp -a "$repo_root/profiles" "$tmpdir/profiles"
printf '\nCONFIG_PACKAGE_firewall=y\n' >> "$tmpdir/profiles/common/config.seed"
if PROFILE_ROOT_OVERRIDE="$tmpdir/profiles" \
  bash "$repo_root/scripts/render-profile.sh" config "$fixture_profile" "$tmpdir/required-owner.config" \
  >"$tmpdir/required-owner.out" 2>&1; then
  echo "renderer accepted duplicate seed/required ownership" >&2
  exit 1
fi
grep -q 'repeats symbols owned by required/forbidden rules' \
  "$tmpdir/required-owner.out"

# An exact-forbidden package must never be selected by either seed layer.
rm -rf "$tmpdir/profiles"
cp -a "$repo_root/profiles" "$tmpdir/profiles"
printf '\nCONFIG_PACKAGE_luci-app-ssr-plus=y\n' >> "$tmpdir/profiles/common/config.seed"
if PROFILE_ROOT_OVERRIDE="$tmpdir/profiles" \
  bash "$repo_root/scripts/render-profile.sh" config "$fixture_profile" "$tmpdir/forbidden.config" \
  >"$tmpdir/forbidden.out" 2>&1; then
  echo "renderer accepted an exact-forbidden selected package" >&2
  exit 1
fi
grep -q 'repeats symbols owned by required/forbidden rules' \
  "$tmpdir/forbidden.out"

# A rootfs collision must be rejected instead of silently overriding common.
rm -rf "$tmpdir/profiles"
cp -a "$repo_root/profiles" "$tmpdir/profiles"
mkdir -p "$tmpdir/profiles/$fixture_profile/files/etc/uci-defaults"
cp "$tmpdir/profiles/common/files/etc/uci-defaults/90-common-network" \
  "$tmpdir/profiles/$fixture_profile/files/etc/uci-defaults/90-common-network"
if PROFILE_ROOT_OVERRIDE="$tmpdir/profiles" \
  bash "$repo_root/scripts/render-profile.sh" files "$fixture_profile" "$tmpdir/collision-files" \
  >"$tmpdir/files-collision.out" 2>&1; then
  echo "renderer accepted a common/device rootfs collision" >&2
  exit 1
fi
grep -q 'rootfs files overlap' "$tmpdir/files-collision.out"

# Required and forbidden rules are evaluated together by the shared model.
python3 - "$repo_root" "$tmpdir/package-contract" <<'PY'
import pathlib
import sys

root = pathlib.Path(sys.argv[1])
fixture = pathlib.Path(sys.argv[2])
sys.path.insert(0, str(root / "scripts"))
from profile_model import (  # noqa: E402
    ForbiddenRules,
    RequiredRules,
    evaluate_package_contract,
    write_package_contract_reports,
)

(fixture / "tmp").mkdir(parents=True)
config = fixture / ".config"
config.write_text(
    "CONFIG_PACKAGE_alpha=y\nCONFIG_PACKAGE_forbidden-item=y\nCONFIG_FEATURE=y\n",
    encoding="utf-8",
)
(fixture / "tmp/.packageinfo").write_text(
    "Package: alpha\nPackage: forbidden-item\n", encoding="utf-8"
)
result = evaluate_package_contract(
    config,
    RequiredRules(frozenset({"alpha"}), frozenset({"CONFIG_FEATURE"})),
    ForbiddenRules(frozenset(), (r"^forbidden-",)),
)
assert result.missing_required == ()
assert result.forbidden_matches == ("forbidden-item",)
assert result.package_metadata_found
write_package_contract_reports(result, fixture / "reports")
assert (fixture / "reports/package-list.txt").read_text(encoding="utf-8") == (
    "alpha\nforbidden-item\n"
)
assert (fixture / "reports/forbidden-packages.detected.txt").read_text(
    encoding="utf-8"
) == "forbidden-item\n"
PY

echo "Profile renderer tests passed."
