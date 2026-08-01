#!/usr/bin/env python3
"""Materialize repository-owned dynamic contracts into source-lock fixtures."""

from __future__ import annotations

import hashlib
import json
import pathlib
import sys
from typing import Any


def current_source_overlays(repo_root: pathlib.Path) -> dict[str, Any]:
    scripts = repo_root / "scripts"
    if str(scripts) not in sys.path:
        sys.path.insert(0, str(scripts))
    import source_lock

    result: dict[str, Any] = {}
    for repository in source_lock.load_source_overlay_contracts(repo_root):
        identifier = repository["id"]
        commit = hashlib.sha256(
            f"source-overlay-fixture:{identifier}".encode()
        ).hexdigest()[:40]
        requested_ref = repository["requested_ref"]
        result[identifier] = {
            "url": repository["url"],
            "requested_ref": requested_ref,
            "resolved_ref": f"refs/heads/{requested_ref}",
            "commit": commit,
            "mappings": repository["mappings"],
        }
    return result


def inject_current_contracts(lock: dict[str, Any], repo_root: pathlib.Path) -> None:
    lock["source_overlays"] = current_source_overlays(repo_root)


def main(argv: list[str]) -> int:
    if len(argv) != 3:
        print(
            "Usage: source_lock_fixtures.py <source-lock.json> <repo-root>",
            file=sys.stderr,
        )
        return 2
    lock_path = pathlib.Path(argv[1])
    repo_root = pathlib.Path(argv[2])
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    inject_current_contracts(lock, repo_root)
    lock_path.write_text(json.dumps(lock, indent=2) + "\n", encoding="utf-8")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
