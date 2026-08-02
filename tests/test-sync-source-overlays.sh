#!/usr/bin/env bash
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

contract="$repo_root/profiles/common/source-overlays.json"
origins="$tmpdir/origins"
openwrt="$tmpdir/openwrt"
mkdir -p "$origins" "$openwrt"

python3 - "$contract" "$origins" "$openwrt" <<'PY'
import json
import pathlib
import sys

contract = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
origins = pathlib.Path(sys.argv[2])
openwrt = pathlib.Path(sys.argv[3])
for repository in contract["repositories"]:
    identifier = repository["id"]
    origin = origins / identifier
    for mapping in repository["mappings"]:
        source = origin / mapping["source"]
        target = openwrt / mapping["target"]
        marker = f'{identifier}:{mapping["source"]}->{mapping["target"]}\n'
        if mapping["kind"] == "tree":
            source.mkdir(parents=True, exist_ok=True)
            target.mkdir(parents=True, exist_ok=True)
            (source / "overlay-fixture.txt").write_text(marker, encoding="utf-8")
            (target / "old-fixture.txt").write_text(
                "must-be-removed\n", encoding="utf-8"
            )
        elif mapping["kind"] == "file":
            source.parent.mkdir(parents=True, exist_ok=True)
            target.parent.mkdir(parents=True, exist_ok=True)
            source.write_text(marker, encoding="utf-8")
            source.chmod(0o755)
            target.write_text("must-be-replaced\n", encoding="utf-8")
            target.chmod(0o600)
        else:
            raise AssertionError(f'unsupported fixture kind: {mapping["kind"]}')
    unrelated = origin / "fixture-unrelated" / identifier
    unrelated.mkdir(parents=True, exist_ok=True)
    (unrelated / "must-not-copy.txt").write_text("unrelated\n", encoding="utf-8")
PY

mapfile -t overlay_ids < <(
  python3 - "$contract" <<'PY'
import json
import pathlib
import sys

contract = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for repository in contract["repositories"]:
    print(repository["id"])
PY
)

commits="$tmpdir/commits.tsv"
: > "$commits"
for identifier in "${overlay_ids[@]}"; do
  origin="$origins/$identifier"
  git -C "$origin" init -q
  git -C "$origin" config user.name fixture
  git -C "$origin" config user.email fixture@example.invalid
  git -C "$origin" add .
  git -C "$origin" commit -qm fixture
  printf '%s\t%s\n' "$identifier" "$(git -C "$origin" rev-parse HEAD)" \
    >> "$commits"
done
git -C "$openwrt" init -q

lock="$tmpdir/source-lock.json"
python3 - "$contract" "$commits" "$lock" <<'PY'
import json
import pathlib
import sys

contract = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
commits = dict(
    line.split("\t", 1)
    for line in pathlib.Path(sys.argv[2]).read_text(encoding="utf-8").splitlines()
)
lock = {"schema": 3, "source_overlays": {}}
for repository in contract["repositories"]:
    identifier = repository["id"]
    lock["source_overlays"][identifier] = {
        "url": repository["url"],
        "requested_ref": repository["ref"],
        "resolved_ref": f'refs/heads/{repository["ref"]}',
        "commit": commits[identifier],
        "mappings": repository["mappings"],
    }
pathlib.Path(sys.argv[3]).write_text(
    json.dumps(lock, indent=2) + "\n", encoding="utf-8"
)
PY

git_config="$tmpdir/gitconfig"
while IFS=$'\t' read -r identifier url; do
  git config --file "$git_config" \
    url."$origins/$identifier".insteadOf "$url"
done < <(
  python3 - "$contract" <<'PY'
import json
import pathlib
import sys

contract = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
for repository in contract["repositories"]:
    print(f'{repository["id"]}\t{repository["url"]}')
PY
)

GIT_CONFIG_GLOBAL="$git_config" GIT_CONFIG_NOSYSTEM=1 \
  bash "$repo_root/scripts/sync-source-overlays.sh" \
  apply-lock "$lock" "$openwrt"

python3 - "$contract" "$openwrt" <<'PY'
import json
import pathlib
import stat
import sys

contract = json.loads(pathlib.Path(sys.argv[1]).read_text(encoding="utf-8"))
openwrt = pathlib.Path(sys.argv[2])
for repository in contract["repositories"]:
    identifier = repository["id"]
    for mapping in repository["mappings"]:
        target = openwrt / mapping["target"]
        expected = f'{identifier}:{mapping["source"]}->{mapping["target"]}\n'
        observed = target / "overlay-fixture.txt" if mapping["kind"] == "tree" else target
        actual = observed.read_text(encoding="utf-8")
        if actual != expected:
            raise AssertionError(f"incorrect overlay marker for {mapping['target']}")
        if mapping["kind"] == "tree" and (target / "old-fixture.txt").exists():
            raise AssertionError(f"old overlay target survived: {mapping['target']}")
        if mapping["kind"] == "file" and stat.S_IMODE(target.stat().st_mode) != 0o755:
            raise AssertionError(f"file mode was not preserved: {mapping['target']}")
    if (openwrt / "fixture-unrelated" / identifier).exists():
        raise AssertionError(f"unrelated source was copied: {identifier}")
PY

python3 - "$lock" "$tmpdir/unsafe-lock.json" <<'PY'
import json
import sys

lock = json.load(open(sys.argv[1], encoding="utf-8"))
identifier = next(iter(lock["source_overlays"]))
lock["source_overlays"][identifier]["mappings"][0]["target"] = "../../outside"
with open(sys.argv[2], "w", encoding="utf-8") as output:
    json.dump(lock, output)
PY
unsafe_identifier="$(
  python3 - "$lock" <<'PY'
import json
import sys

lock = json.load(open(sys.argv[1], encoding="utf-8"))
print(next(iter(lock["source_overlays"])))
PY
)"
if GIT_CONFIG_GLOBAL="$git_config" GIT_CONFIG_NOSYSTEM=1 \
  bash "$repo_root/scripts/sync-source-overlays.sh" apply-lock \
  "$tmpdir/unsafe-lock.json" "$openwrt" > "$tmpdir/unsafe.out" 2>&1; then
  echo "source overlay sync accepted a lock that differs from its contract" >&2
  exit 1
fi
grep -Fq "source overlay $unsafe_identifier mappings differ" "$tmpdir/unsafe.out"
[ ! -e "$tmpdir/outside" ]

echo "Source overlay synchronization tests passed."
