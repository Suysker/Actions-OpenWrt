#!/usr/bin/env python3
"""Apply declarative, semantic package-recipe compatibility rules."""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys
from typing import Any


RULE_ID_RE = re.compile(r"^[a-z][a-z0-9-]*$")
STANDARD_RE = re.compile(r"(?:^|\s)-std=([A-Za-z0-9+_.-]+)")
ASSIGNMENT_RE = re.compile(
    r"^(?:TARGET_(?:C|CPP)FLAGS|PKG_(?:C|CPP)FLAGS)\s*(?::|\+|\?)?=\s*(.*)$"
)
ALLOWED_PREFIXES = ("package/", "feeds/")


class CompatibilityError(RuntimeError):
    """Raised when a compatibility rule cannot be safely applied."""


def require_text(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value or "\n" in value or "\r" in value:
        raise CompatibilityError(f"{label} must be one non-empty line")
    return value


def require_relative_path(value: Any, label: str) -> str:
    path = require_text(value, label)
    candidate = pathlib.PurePosixPath(path)
    if (
        candidate.is_absolute()
        or ".." in candidate.parts
        or path != candidate.as_posix()
        or not path.endswith("/Makefile")
        or not path.startswith(ALLOWED_PREFIXES)
    ):
        raise CompatibilityError(f"{label} is not a safe package Makefile path: {path!r}")
    return path


def expect_keys(rule: dict[str, Any], expected: set[str], label: str) -> None:
    actual = set(rule)
    if actual != expected:
        raise CompatibilityError(
            f"{label} has unexpected fields: expected {sorted(expected)}, got {sorted(actual)}"
        )


def load_rules(policy_path: pathlib.Path) -> list[dict[str, Any]]:
    try:
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CompatibilityError(f"cannot read package compatibility policy: {exc}") from exc

    if not isinstance(policy, dict) or set(policy) != {"schema", "rules"}:
        raise CompatibilityError("package compatibility policy must contain schema and rules")
    if policy["schema"] != 1 or not isinstance(policy["rules"], list) or not policy["rules"]:
        raise CompatibilityError("package compatibility policy schema or rules are invalid")

    identifiers: set[str] = set()
    paths: set[str] = set()
    validated: list[dict[str, Any]] = []
    for index, raw_rule in enumerate(policy["rules"], start=1):
        label = f"package compatibility rule #{index}"
        if not isinstance(raw_rule, dict):
            raise CompatibilityError(f"{label} must be an object")
        identifier = require_text(raw_rule.get("id"), f"{label} id")
        if not RULE_ID_RE.fullmatch(identifier) or identifier in identifiers:
            raise CompatibilityError(f"{label} has an invalid or duplicate id: {identifier!r}")
        identifiers.add(identifier)

        operation = require_text(raw_rule.get("operation"), f"{label} operation")
        path = require_relative_path(raw_rule.get("path"), f"{label} path")
        if path in paths:
            raise CompatibilityError(f"{label} duplicates package path {path!r}")
        paths.add(path)

        if operation == "language-standard":
            expect_keys(
                raw_rule,
                {"id", "operation", "path", "anchor", "line", "standard"},
                label,
            )
            anchor = require_text(raw_rule["anchor"], f"{label} anchor")
            line = require_text(raw_rule["line"], f"{label} line")
            standard = require_text(raw_rule["standard"], f"{label} standard")
            if STANDARD_RE.findall(line) != [standard]:
                raise CompatibilityError(
                    f"{label} line must declare exactly its requested language standard"
                )
        elif operation == "make-environment":
            expect_keys(
                raw_rule,
                {
                    "id",
                    "operation",
                    "path",
                    "anchor",
                    "token",
                    "accepted_tokens",
                    "required_fragments",
                    "upstream_default_marker",
                },
                label,
            )
            anchor = require_text(raw_rule["anchor"], f"{label} anchor")
            token = require_text(raw_rule["token"], f"{label} token")
            marker = require_text(
                raw_rule["upstream_default_marker"],
                f"{label} upstream_default_marker",
            )
            accepted_raw = raw_rule["accepted_tokens"]
            fragments_raw = raw_rule["required_fragments"]
            if not isinstance(accepted_raw, list) or not isinstance(fragments_raw, list):
                raise CompatibilityError(f"{label} token lists must be arrays")
            accepted = [
                require_text(item, f"{label} accepted token") for item in accepted_raw
            ]
            fragments = [
                require_text(item, f"{label} required fragment") for item in fragments_raw
            ]
            if token not in accepted or len(accepted) != len(set(accepted)):
                raise CompatibilityError(
                    f"{label} accepted_tokens must uniquely include the inserted token"
                )
            if not fragments or len(fragments) != len(set(fragments)):
                raise CompatibilityError(f"{label} required_fragments are invalid")
        else:
            raise CompatibilityError(f"{label} has unsupported operation {operation!r}")

        validated.append(raw_rule)
    return validated


def target_path(openwrt_root: pathlib.Path, relative: str) -> pathlib.Path:
    root = openwrt_root.resolve()
    candidate = (root / pathlib.PurePosixPath(relative)).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise CompatibilityError(f"compatibility target escapes OpenWrt root: {relative}") from exc
    if not candidate.is_file():
        raise CompatibilityError(f"compatibility package Makefile is missing: {relative}")
    return candidate


def find_unique_anchor(lines: list[str], anchor: str, label: str) -> int:
    occurrences = [
        (index, line.count(anchor))
        for index, line in enumerate(lines)
        if anchor in line
    ]
    if len(occurrences) != 1 or occurrences[0][1] != 1:
        raise CompatibilityError(
            f"{label} must contain exactly one unambiguous anchor {anchor!r}"
        )
    return occurrences[0][0]


def write_if_changed(path: pathlib.Path, original: str, changed: str) -> None:
    if changed == original:
        return
    temporary = path.with_name(f".{path.name}.compatibility-{os.getpid()}")
    temporary.write_text(changed, encoding="utf-8", newline="\n")
    os.chmod(temporary, path.stat().st_mode)
    os.replace(temporary, path)


def language_standards(text: str) -> list[str]:
    standards: list[str] = []
    for line in text.splitlines():
        match = ASSIGNMENT_RE.fullmatch(line)
        if match:
            standards.extend(STANDARD_RE.findall(match.group(1)))
    return standards


def apply_language_standard(rule: dict[str, Any], path: pathlib.Path) -> tuple[str, str]:
    original = path.read_text(encoding="utf-8")
    standards = language_standards(original)
    if len(standards) > 1:
        raise CompatibilityError(
            f"{rule['id']} declares multiple language standards; refusing an ambiguous override"
        )
    if standards:
        return "upstream", standards[0]

    lines = original.splitlines()
    index = find_unique_anchor(lines, rule["anchor"], rule["id"])
    lines[index + 1 : index + 1] = ["", rule["line"]]
    changed = "\n".join(lines) + "\n"
    write_if_changed(path, original, changed)

    final_standards = language_standards(path.read_text(encoding="utf-8"))
    if final_standards != [rule["standard"]]:
        raise CompatibilityError(f"{rule['id']} language-standard postcondition failed")
    return "inserted", rule["standard"]


def make_statement_end(lines: list[str], start: int, label: str) -> int:
    end = start
    while lines[end].rstrip().endswith("\\"):
        end += 1
        if end == len(lines):
            raise CompatibilityError(f"{label} has an unterminated make recipe continuation")
    return end


def apply_make_environment(rule: dict[str, Any], path: pathlib.Path) -> tuple[str, str]:
    original = path.read_text(encoding="utf-8")
    lines = original.splitlines()
    if not any(rule["anchor"] in line for line in lines):
        if rule["upstream_default_marker"] not in original:
            return "upstream-default", "default-build-compile"
        raise CompatibilityError(
            f"{rule['id']} retains a custom Build/Compile but no longer has its required anchor"
        )

    index = find_unique_anchor(lines, rule["anchor"], rule["id"])
    end = make_statement_end(lines, index, rule["id"])
    statement = "\n".join(lines[index : end + 1])

    for accepted in rule["accepted_tokens"]:
        if accepted in statement:
            return "upstream", accepted

    missing = [
        fragment for fragment in rule["required_fragments"] if fragment not in statement
    ]
    if missing:
        raise CompatibilityError(
            f"{rule['id']} recipe no longer contains required fragments: {', '.join(missing)}"
        )

    lines[index] = lines[index].replace(
        rule["anchor"], f"{rule['anchor']} {rule['token']}", 1
    )
    changed = "\n".join(lines) + "\n"
    write_if_changed(path, original, changed)

    final_lines = path.read_text(encoding="utf-8").splitlines()
    final_index = find_unique_anchor(final_lines, rule["anchor"], rule["id"])
    final_end = make_statement_end(final_lines, final_index, rule["id"])
    final_statement = "\n".join(final_lines[final_index : final_end + 1])
    if rule["token"] not in final_statement:
        raise CompatibilityError(f"{rule['id']} target make environment postcondition failed")
    return "inserted", rule["token"]


def report_key(identifier: str) -> str:
    return identifier.replace("-", "_")


def apply_rule(rule: dict[str, Any], openwrt_root: pathlib.Path) -> tuple[str, str]:
    path = target_path(openwrt_root, rule["path"])
    if rule["operation"] == "language-standard":
        return apply_language_standard(rule, path)
    if rule["operation"] == "make-environment":
        return apply_make_environment(rule, path)
    raise CompatibilityError(f"unsupported validated operation: {rule['operation']}")


def main(argv: list[str]) -> int:
    if len(argv) != 4:
        print(
            "Usage: apply-package-compatibility.py <policy.json> <openwrt-root> <report>",
            file=sys.stderr,
        )
        return 2

    policy_path = pathlib.Path(argv[1])
    openwrt_root = pathlib.Path(argv[2])
    report_path = pathlib.Path(argv[3])
    try:
        rules = load_rules(policy_path)
        root = openwrt_root.resolve()
        if not root.is_dir():
            raise CompatibilityError(f"OpenWrt root does not exist: {openwrt_root}")
        results = [(rule["id"], *apply_rule(rule, root)) for rule in rules]
    except CompatibilityError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1

    with report_path.open("a", encoding="utf-8") as report:
        for identifier, status, detail in results:
            key = report_key(identifier)
            report.write(f"compatibility_{key}_status={status}\n")
            report.write(f"compatibility_{key}_detail={detail}\n")
    print("Applied package compatibility rules: " + ", ".join(identifier for identifier, *_ in results))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
