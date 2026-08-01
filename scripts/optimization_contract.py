#!/usr/bin/env python3
"""Validate declared runtime and locked-upstream optimization semantics."""

from __future__ import annotations

import json
import pathlib
import re
from typing import Any


class OptimizationContractError(RuntimeError):
    pass


ASSERTION_FIELDS = ("contains", "exact_lines", "line_set", "forbidden")
RULE_FIELDS = {"name", "path", "glob", *ASSERTION_FIELDS}


def _require_string_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item for item in value
    ):
        raise OptimizationContractError(f"{label} must be a list of non-empty strings")
    if len(value) != len(set(value)):
        raise OptimizationContractError(f"{label} contains duplicate values")
    return value


def _validate_relative_template(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise OptimizationContractError(f"{label} must be a non-empty string")
    if "\\" in value:
        raise OptimizationContractError(f"{label} must use POSIX path separators")
    probe = value.replace("{kernel_series}", "kernel-series")
    if "{" in probe or "}" in probe:
        raise OptimizationContractError(
            f"{label} contains an unsupported template placeholder"
        )
    path = pathlib.PurePosixPath(probe)
    if path.is_absolute() or ".." in path.parts:
        raise OptimizationContractError(f"{label} must stay below its contract root")
    return value


def load_contract(path: pathlib.Path) -> dict[str, Any]:
    try:
        contract = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise OptimizationContractError(f"cannot read optimization contract: {exc}") from exc

    if not isinstance(contract, dict) or contract.get("schema") != 1:
        raise OptimizationContractError("optimization contract schema must be 1")
    if set(contract) != {"schema", "scopes"}:
        raise OptimizationContractError("optimization contract has unknown top-level fields")

    scopes = contract.get("scopes")
    if not isinstance(scopes, dict) or "common" not in scopes:
        raise OptimizationContractError("optimization contract must define common scope")

    names: set[str] = set()
    for scope, sections in scopes.items():
        if not isinstance(scope, str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", scope):
            raise OptimizationContractError(f"invalid optimization scope: {scope!r}")
        if not isinstance(sections, dict) or set(sections) != {"rootfs", "source"}:
            raise OptimizationContractError(
                f"optimization scope {scope} must define only rootfs and source"
            )
        for section in ("rootfs", "source"):
            rules = sections[section]
            if not isinstance(rules, list):
                raise OptimizationContractError(f"{scope}.{section} must be a list")
            for index, rule in enumerate(rules):
                label = f"{scope}.{section}[{index}]"
                if not isinstance(rule, dict) or not set(rule).issubset(RULE_FIELDS):
                    raise OptimizationContractError(f"{label} has unknown fields")
                name = rule.get("name")
                if not isinstance(name, str) or not name.startswith(f"{scope}."):
                    raise OptimizationContractError(
                        f"{label} name must start with {scope}."
                    )
                if not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", name):
                    raise OptimizationContractError(f"{label} has invalid name {name!r}")
                if name in names:
                    raise OptimizationContractError(f"duplicate optimization rule: {name}")
                names.add(name)

                selectors = [field for field in ("path", "glob") if field in rule]
                if len(selectors) != 1:
                    raise OptimizationContractError(
                        f"{name} must define exactly one of path or glob"
                    )
                if section == "rootfs" and selectors[0] != "path":
                    raise OptimizationContractError(f"{name} rootfs rule must use path")
                _validate_relative_template(rule[selectors[0]], f"{name}.{selectors[0]}")

                assertions = [field for field in ASSERTION_FIELDS if field in rule]
                if not assertions:
                    raise OptimizationContractError(f"{name} has no content assertions")
                for field in assertions:
                    _require_string_list(rule[field], f"{name}.{field}")

    return contract


def _format_template(template: str, kernel_series: str | None, name: str) -> str:
    if "{kernel_series}" in template:
        if not kernel_series or not re.fullmatch(r"[0-9]+\.[0-9]+", kernel_series):
            raise OptimizationContractError(
                f"{name} requires a valid stable kernel series"
            )
        return template.format(kernel_series=kernel_series)
    return template


def _normalized_lines(content: str) -> list[str]:
    return [
        line.strip()
        for line in content.splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    ]


def _content_problems(rule: dict[str, Any], content: str) -> list[str]:
    missing: list[str] = []
    for fragment in rule.get("contains", []):
        if fragment not in content:
            missing.append(f"missing fragment {fragment!r}")

    lines = _normalized_lines(content)
    line_lookup = set(lines)
    for expected in rule.get("exact_lines", []):
        if expected not in line_lookup:
            missing.append(f"missing exact line {expected!r}")

    if "line_set" in rule and lines != rule["line_set"]:
        missing.append(
            "normalized line set differs: "
            f"expected {rule['line_set']!r}, got {lines!r}"
        )

    for fragment in rule.get("forbidden", []):
        if fragment in content:
            missing.append(f"contains forbidden fragment {fragment!r}")
    return missing


def _safe_candidate(root: pathlib.Path, relative: pathlib.Path) -> pathlib.Path:
    root = root.resolve()
    candidate = (root / relative).resolve()
    try:
        candidate.relative_to(root)
    except ValueError as exc:
        raise OptimizationContractError(
            f"optimization path escapes its contract root: {relative}"
        ) from exc
    return candidate


def _check_rule(
    rule: dict[str, Any],
    root: pathlib.Path,
    kernel_series: str | None,
) -> tuple[str | None, str | None]:
    name = rule["name"]
    if "path" in rule:
        relative = pathlib.Path(_format_template(rule["path"], kernel_series, name))
        candidate = _safe_candidate(root, relative)
        if not candidate.is_file():
            return None, f"{name}: required file is missing: {relative.as_posix()}"
        try:
            content = candidate.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            return None, f"{name}: cannot read {relative.as_posix()}: {exc}"
        failures = _content_problems(rule, content)
        if failures:
            return None, f"{name}: {relative.as_posix()}: {'; '.join(failures)}"
        return f"optimization {name} ({relative.as_posix()})", None

    pattern = _format_template(rule["glob"], kernel_series, name)
    candidates = sorted(path for path in root.glob(pattern) if path.is_file())
    if not candidates:
        return None, f"{name}: source glob matched no files: {pattern}"
    for candidate in candidates:
        safe = _safe_candidate(root, candidate.relative_to(root))
        try:
            content = safe.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if not _content_problems(rule, content):
            relative = safe.relative_to(root.resolve()).as_posix()
            return f"optimization {name} ({relative})", None
    return None, (
        f"{name}: no single file matching {pattern} satisfies every content assertion"
    )


def check_contract(
    contract: dict[str, Any],
    profile: str,
    rootfs_root: pathlib.Path,
    *,
    openwrt_root: pathlib.Path | None = None,
    kernel_series: str | None = None,
) -> tuple[list[str], list[str]]:
    scopes = contract["scopes"]
    if profile == "common" or profile not in scopes:
        raise OptimizationContractError(f"unknown maintained profile: {profile}")

    checks: list[str] = []
    problems: list[str] = []
    for scope in ("common", profile):
        for rule in scopes[scope]["rootfs"]:
            try:
                check, problem = _check_rule(rule, rootfs_root, None)
            except OptimizationContractError as exc:
                check, problem = None, f"{rule['name']}: {exc}"
            if check:
                checks.append(check)
            if problem:
                problems.append(problem)

        if openwrt_root is not None:
            for rule in scopes[scope]["source"]:
                try:
                    check, problem = _check_rule(
                        rule, openwrt_root, kernel_series
                    )
                except OptimizationContractError as exc:
                    check, problem = None, f"{rule['name']}: {exc}"
                if check:
                    checks.append(check)
                if problem:
                    problems.append(problem)
    return checks, problems
