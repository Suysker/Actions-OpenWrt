#!/usr/bin/env python3
"""Apply declarative, semantic non-kernel source compatibility rules."""

from __future__ import annotations

import json
import os
import pathlib
import re
import sys
from typing import Any

from kernel_selection import KernelSelectionError, kernel_series_symbol


RULE_ID_RE = re.compile(r"^[a-z][a-z0-9-]*$")
MAKE_DEFINE_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_./-]*$")
KCONFIG_SYMBOL_RE = re.compile(r"^[A-Z][A-Z0-9_]*$")
KCONFIG_GUARD_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_-]*$")
KERNEL_CONDITION_RE = re.compile(
    r"^(LINUX_[0-9]+_[0-9]+)(?:\s*\|\|\s*(LINUX_[0-9]+_[0-9]+))*$"
)
STANDARD_RE = re.compile(r"(?:^|\s)-std=([A-Za-z0-9+_.-]+)")
ASSIGNMENT_RE = re.compile(
    r"^(?:TARGET_(?:C|CPP)FLAGS|PKG_(?:C|CPP)FLAGS)\s*(?::|\+|\?)?=\s*(.*)$"
)
PACKAGE_PREFIXES = ("package/", "feeds/")
SHARED_BUILD_FILES = frozenset(
    {"include/image.mk", "package/kernel/linux/modules/other.mk"}
)


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
        or not (
            (path.endswith("/Makefile") and path.startswith(PACKAGE_PREFIXES))
            or path in SHARED_BUILD_FILES
        )
    ):
        raise CompatibilityError(f"{label} is not an allowed source path: {path!r}")
    return path


def is_package_makefile(path: str) -> bool:
    return path.endswith("/Makefile") and path.startswith(PACKAGE_PREFIXES)


def require_dependency_path(value: Any, label: str) -> str:
    path = require_text(value, label)
    candidate = pathlib.PurePosixPath(path)
    if (
        candidate.is_absolute()
        or ".." in candidate.parts
        or path != candidate.as_posix()
        or len(candidate.parts) != 3
        or candidate.parts[:2] != ("scripts", "openwrt-sbom")
    ):
        raise CompatibilityError(f"{label} is not an isolated generator path: {path!r}")
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
        raise CompatibilityError(f"cannot read source compatibility policy: {exc}") from exc

    if not isinstance(policy, dict) or set(policy) != {"schema", "rules"}:
        raise CompatibilityError("source compatibility policy must contain schema and rules")
    if policy["schema"] != 3 or not isinstance(policy["rules"], list) or not policy["rules"]:
        raise CompatibilityError("source compatibility policy schema or rules are invalid")

    identifiers: set[str] = set()
    paths: set[str] = set()
    validated: list[dict[str, Any]] = []
    for index, raw_rule in enumerate(policy["rules"], start=1):
        label = f"source compatibility rule #{index}"
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
            if not is_package_makefile(path):
                raise CompatibilityError(f"{label} language-standard requires a package Makefile")
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
            if not is_package_makefile(path):
                raise CompatibilityError(f"{label} make-environment requires a package Makefile")
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
        elif operation == "make-define-block":
            expect_keys(
                raw_rule,
                {
                    "id",
                    "operation",
                    "path",
                    "define",
                    "block",
                    "accepted_semantics",
                    "required_files",
                },
                label,
            )
            define = require_text(raw_rule["define"], f"{label} define")
            if not MAKE_DEFINE_RE.fullmatch(define):
                raise CompatibilityError(f"{label} has an invalid Make define name")
            block_raw = raw_rule["block"]
            semantics_raw = raw_rule["accepted_semantics"]
            required_files_raw = raw_rule["required_files"]
            if (
                not isinstance(block_raw, list)
                or not isinstance(semantics_raw, list)
                or not isinstance(required_files_raw, list)
            ):
                raise CompatibilityError(
                    f"{label} block, accepted_semantics and required_files must be arrays"
                )
            block = [require_text(item, f"{label} block line") for item in block_raw]
            semantic_sets: list[tuple[str, ...]] = []
            for semantics_index, raw_semantics in enumerate(semantics_raw, start=1):
                if not isinstance(raw_semantics, list):
                    raise CompatibilityError(
                        f"{label} accepted semantics #{semantics_index} must be an array"
                    )
                markers = tuple(
                    require_text(
                        item,
                        f"{label} accepted semantics #{semantics_index} marker",
                    )
                    for item in raw_semantics
                )
                if len(markers) < 3 or len(markers) != len(set(markers)):
                    raise CompatibilityError(
                        f"{label} accepted semantics #{semantics_index} are invalid"
                    )
                semantic_sets.append(markers)
            if not block or not semantic_sets or len(semantic_sets) != len(set(semantic_sets)):
                raise CompatibilityError(f"{label} block or accepted semantics are invalid")
            if any(
                line.strip() == "endef" or line.strip().startswith("define ")
                for line in block
            ):
                raise CompatibilityError(f"{label} block cannot contain Make define boundaries")
            joined_block = "\n".join(block)
            missing_markers = [
                marker for marker in semantic_sets[0] if marker not in joined_block
            ]
            if missing_markers:
                raise CompatibilityError(
                    f"{label} block misses semantic markers: {', '.join(missing_markers)}"
                )
            required_paths: set[str] = set()
            for file_index, required_file in enumerate(required_files_raw, start=1):
                file_label = f"{label} required file #{file_index}"
                if not isinstance(required_file, dict) or set(required_file) != {
                    "path",
                    "executable",
                    "contains",
                }:
                    raise CompatibilityError(f"{file_label} has invalid fields")
                required_path = require_dependency_path(
                    required_file["path"], f"{file_label} path"
                )
                if required_path in required_paths:
                    raise CompatibilityError(f"{label} repeats required file {required_path}")
                required_paths.add(required_path)
                if not isinstance(required_file["executable"], bool):
                    raise CompatibilityError(f"{file_label} executable must be boolean")
                contains_raw = required_file["contains"]
                if not isinstance(contains_raw, list):
                    raise CompatibilityError(f"{file_label} contains must be an array")
                contains = [
                    require_text(item, f"{file_label} content marker")
                    for item in contains_raw
                ]
                if not contains or len(contains) != len(set(contains)):
                    raise CompatibilityError(f"{file_label} content markers are invalid")
            if not required_paths:
                raise CompatibilityError(f"{label} declares no required files")
        elif operation == "kernel-series-config-guard":
            if path != "package/kernel/linux/modules/other.mk":
                raise CompatibilityError(
                    f"{label} kernel-series-config-guard has an unsupported path"
                )
            expect_keys(
                raw_rule,
                {
                    "id",
                    "operation",
                    "path",
                    "define",
                    "config",
                    "parent_guard",
                },
                label,
            )
            define = require_text(raw_rule["define"], f"{label} define")
            config = require_text(raw_rule["config"], f"{label} config")
            parent_guard = require_text(
                raw_rule["parent_guard"], f"{label} parent_guard"
            )
            if not MAKE_DEFINE_RE.fullmatch(define):
                raise CompatibilityError(f"{label} has an invalid Make define name")
            if not KCONFIG_SYMBOL_RE.fullmatch(config):
                raise CompatibilityError(f"{label} has an invalid Kconfig symbol")
            if not KCONFIG_GUARD_RE.fullmatch(parent_guard):
                raise CompatibilityError(f"{label} has an invalid parent guard")
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
        raise CompatibilityError(f"compatibility source file is missing: {relative}")
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


def find_make_define(lines: list[str], name: str, label: str) -> tuple[int, int]:
    header = f"define {name}"
    starts = [index for index, line in enumerate(lines) if line.strip() == header]
    if len(starts) != 1:
        raise CompatibilityError(f"{label} must contain exactly one {header!r}")

    depth = 0
    for index in range(starts[0] + 1, len(lines)):
        stripped = lines[index].strip()
        if stripped.startswith("define "):
            depth += 1
        elif stripped == "endef":
            if depth == 0:
                return starts[0], index
            depth -= 1
    raise CompatibilityError(f"{label} has no matching endef for {header!r}")


def apply_make_define_block(
    rule: dict[str, Any], path: pathlib.Path, openwrt_root: pathlib.Path
) -> tuple[str, str]:
    original = path.read_text(encoding="utf-8")
    lines = original.splitlines()
    start, end = find_make_define(lines, rule["define"], rule["id"])
    body = "\n".join(lines[start + 1 : end])
    semantic_sets = rule["accepted_semantics"]
    if any(all(marker in body for marker in markers) for markers in semantic_sets):
        return "upstream", rule["define"]
    all_markers = {marker for markers in semantic_sets for marker in markers}
    if any(marker in body for marker in all_markers):
        raise CompatibilityError(
            f"{rule['id']} has a partial semantic block; no accepted semantic set is complete"
        )

    root = openwrt_root.resolve()
    for required_file in rule["required_files"]:
        raw_candidate = root / required_file["path"]
        candidate = raw_candidate.resolve()
        try:
            candidate.relative_to(root)
        except ValueError as exc:
            raise CompatibilityError(
                f"{rule['id']} required file escapes OpenWrt root"
            ) from exc
        if not candidate.is_file() or raw_candidate.is_symlink():
            raise CompatibilityError(
                f"{rule['id']} required file is missing: {required_file['path']}"
            )
        if required_file["executable"] and not os.access(candidate, os.X_OK):
            raise CompatibilityError(
                f"{rule['id']} required file is not executable: {required_file['path']}"
            )
        try:
            required_text = candidate.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            raise CompatibilityError(
                f"{rule['id']} required file cannot be read: {required_file['path']}"
            ) from exc
        missing_content = [
            marker for marker in required_file["contains"] if marker not in required_text
        ]
        if missing_content:
            raise CompatibilityError(
                f"{rule['id']} required file misses declared semantics: "
                f"{required_file['path']}"
            )

    insertion = list(rule["block"])
    if end > start + 1 and lines[end - 1].strip():
        insertion.insert(0, "")
    lines[end:end] = insertion
    changed = "\n".join(lines) + "\n"
    write_if_changed(path, original, changed)

    final_lines = path.read_text(encoding="utf-8").splitlines()
    final_start, final_end = find_make_define(
        final_lines, rule["define"], rule["id"]
    )
    final_body = "\n".join(final_lines[final_start + 1 : final_end])
    if not all(marker in final_body for marker in semantic_sets[0]):
        raise CompatibilityError(f"{rule['id']} make-define-block postcondition failed")
    return "inserted", rule["define"]


def kernel_series_token(kernel_series: str) -> str:
    try:
        return kernel_series_symbol(kernel_series)
    except KernelSelectionError as exc:
        raise CompatibilityError(str(exc)) from exc


def parse_kernel_condition(expression: str) -> tuple[str, ...] | None:
    if not KERNEL_CONDITION_RE.fullmatch(expression):
        return None
    return tuple(part.strip() for part in expression.split("||"))


def locate_config_series_guard(
    lines: list[str],
    start: int,
    end: int,
    config: str,
    parent_guard: str,
    label: str,
) -> tuple[int, tuple[str, ...]] | None:
    stack: list[tuple[int, str]] = []
    declarations: list[tuple[int, tuple[tuple[int, str], ...]]] = []
    declaration = f"config {config}"

    for index in range(start + 1, end):
        stripped = lines[index].strip()
        if stripped.startswith("if "):
            expression = stripped[3:].strip()
            if not expression:
                raise CompatibilityError(f"{label} contains an empty Kconfig guard")
            stack.append((index, expression))
        elif stripped == "endif":
            if not stack:
                raise CompatibilityError(f"{label} contains an unmatched endif")
            stack.pop()
        elif stripped == declaration:
            declarations.append((index, tuple(stack)))

    if stack:
        raise CompatibilityError(f"{label} contains an unclosed Kconfig guard")
    if len(declarations) != 1:
        raise CompatibilityError(
            f"{label} must declare {config} exactly once, found {len(declarations)}"
        )

    _, guards = declarations[0]
    parent_matches = [item for item in guards if item[1] == parent_guard]
    if len(parent_matches) != 1:
        raise CompatibilityError(
            f"{label} must place {config} under exactly one {parent_guard} guard"
        )
    residual = [item for item in guards if item[1] != parent_guard]
    if not residual:
        return None
    if len(residual) != 1:
        raise CompatibilityError(
            f"{label} has ambiguous nested guards around {config}"
        )
    guard_index, expression = residual[0]
    tokens = parse_kernel_condition(expression)
    if tokens is None or len(tokens) != len(set(tokens)):
        raise CompatibilityError(
            f"{label} has a non-canonical kernel-series guard around {config}"
        )
    return guard_index, tokens


def apply_kernel_series_config_guard(
    rule: dict[str, Any], path: pathlib.Path, kernel_series: str
) -> tuple[str, str]:
    selected = kernel_series_token(kernel_series)
    original = path.read_text(encoding="utf-8")
    lines = original.splitlines()
    start, end = find_make_define(lines, rule["define"], rule["id"])
    located = locate_config_series_guard(
        lines,
        start,
        end,
        rule["config"],
        rule["parent_guard"],
        rule["id"],
    )
    detail = f"{rule['config']}@{selected}"
    if located is None:
        return "upstream-unconditional", detail
    guard_index, tokens = located
    if selected in tokens:
        return "upstream", detail

    indentation = lines[guard_index][
        : len(lines[guard_index]) - len(lines[guard_index].lstrip())
    ]
    lines[guard_index] = f"{indentation}if {' || '.join((*tokens, selected))}"
    changed = "\n".join(lines) + "\n"
    write_if_changed(path, original, changed)

    final_lines = path.read_text(encoding="utf-8").splitlines()
    final_start, final_end = find_make_define(
        final_lines, rule["define"], rule["id"]
    )
    final_located = locate_config_series_guard(
        final_lines,
        final_start,
        final_end,
        rule["config"],
        rule["parent_guard"],
        rule["id"],
    )
    if final_located is None or selected not in final_located[1]:
        raise CompatibilityError(
            f"{rule['id']} kernel-series guard postcondition failed"
        )
    return "inserted", detail


def report_key(identifier: str) -> str:
    return identifier.replace("-", "_")


def apply_rule(
    rule: dict[str, Any], openwrt_root: pathlib.Path, kernel_series: str
) -> tuple[str, str]:
    path = target_path(openwrt_root, rule["path"])
    if rule["operation"] == "language-standard":
        return apply_language_standard(rule, path)
    if rule["operation"] == "make-environment":
        return apply_make_environment(rule, path)
    if rule["operation"] == "make-define-block":
        return apply_make_define_block(rule, path, openwrt_root)
    if rule["operation"] == "kernel-series-config-guard":
        return apply_kernel_series_config_guard(rule, path, kernel_series)
    raise CompatibilityError(f"unsupported validated operation: {rule['operation']}")


def main(argv: list[str]) -> int:
    if len(argv) != 5:
        print(
            "Usage: apply-source-compatibility.py "
            "<policy.json> <openwrt-root> <report> <kernel-series>",
            file=sys.stderr,
        )
        return 2

    policy_path = pathlib.Path(argv[1])
    openwrt_root = pathlib.Path(argv[2])
    report_path = pathlib.Path(argv[3])
    kernel_series = argv[4]
    try:
        kernel_series_token(kernel_series)
        rules = load_rules(policy_path)
        root = openwrt_root.resolve()
        if not root.is_dir():
            raise CompatibilityError(f"OpenWrt root does not exist: {openwrt_root}")
        results = [
            (rule["id"], *apply_rule(rule, root, kernel_series)) for rule in rules
        ]
    except CompatibilityError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1

    with report_path.open("a", encoding="utf-8") as report:
        for identifier, status, detail in results:
            key = report_key(identifier)
            report.write(f"source_compatibility_{key}_status={status}\n")
            report.write(f"source_compatibility_{key}_detail={detail}\n")
    print("Applied source compatibility rules: " + ", ".join(identifier for identifier, *_ in results))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
