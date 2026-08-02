#!/usr/bin/env python3
"""Validate declared locked-upstream profile source semantics."""

from __future__ import annotations

import json
import pathlib
import re
from typing import Any


class ProfileSemanticError(RuntimeError):
    pass


ASSERTION_FIELDS = ("contains", "exact_lines", "line_set", "forbidden")
SELECTOR_FIELDS = ("path", "glob")
MATCHER_FIELDS = {*SELECTOR_FIELDS, *ASSERTION_FIELDS}
RULE_FIELDS = {"name", "alternatives", *MATCHER_FIELDS}


def _require_string_list(value: Any, label: str) -> list[str]:
    if not isinstance(value, list) or not all(
        isinstance(item, str) and item for item in value
    ):
        raise ProfileSemanticError(f"{label} must be a list of non-empty strings")
    if len(value) != len(set(value)):
        raise ProfileSemanticError(f"{label} contains duplicate values")
    return value


def _validate_relative_template(value: Any, label: str) -> str:
    if not isinstance(value, str) or not value:
        raise ProfileSemanticError(f"{label} must be a non-empty string")
    if "\\" in value:
        raise ProfileSemanticError(f"{label} must use POSIX path separators")
    probe = value.replace("{kernel_series}", "kernel-series").replace(
        "{kernel_version}", "kernel-version"
    )
    if "{" in probe or "}" in probe:
        raise ProfileSemanticError(
            f"{label} contains an unsupported template placeholder"
        )
    path = pathlib.PurePosixPath(probe)
    if path.is_absolute() or ".." in path.parts:
        raise ProfileSemanticError(f"{label} must stay below its contract root")
    return value


def _validate_matcher(matcher: Any, label: str) -> dict[str, Any]:
    if not isinstance(matcher, dict) or not set(matcher).issubset(MATCHER_FIELDS):
        raise ProfileSemanticError(f"{label} has unknown fields")
    selectors = [field for field in SELECTOR_FIELDS if field in matcher]
    if len(selectors) != 1:
        raise ProfileSemanticError(
            f"{label} must define exactly one of path or glob"
        )
    _validate_relative_template(
        matcher[selectors[0]], f"{label}.{selectors[0]}"
    )
    assertions = [field for field in ASSERTION_FIELDS if field in matcher]
    if not assertions:
        raise ProfileSemanticError(f"{label} has no content assertions")
    for field in assertions:
        _require_string_list(matcher[field], f"{label}.{field}")
    return matcher


def _load_scope(path: pathlib.Path, scope: str) -> dict[str, list[dict[str, Any]]]:
    try:
        document = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise ProfileSemanticError(f"cannot read {scope} semantics: {exc}") from exc

    if not isinstance(document, dict) or document.get("schema") != 3:
        raise ProfileSemanticError(f"{scope} semantics schema must be 3")
    if set(document) != {"schema", "source"}:
        raise ProfileSemanticError(
            f"{scope} semantics must define only schema and source"
        )

    sections = {"source": document["source"]}
    names: set[str] = set()
    for section, rules in sections.items():
        if not isinstance(rules, list):
            raise ProfileSemanticError(f"{scope}.{section} must be a list")
        for index, rule in enumerate(rules):
            label = f"{scope}.{section}[{index}]"
            if not isinstance(rule, dict) or not set(rule).issubset(RULE_FIELDS):
                raise ProfileSemanticError(f"{label} has unknown fields")
            name = rule.get("name")
            if not isinstance(name, str) or not name.startswith(f"{scope}."):
                raise ProfileSemanticError(f"{label} name must start with {scope}.")
            if not re.fullmatch(r"[a-z0-9][a-z0-9.-]*", name):
                raise ProfileSemanticError(f"{label} has invalid name {name!r}")
            if name in names:
                raise ProfileSemanticError(f"duplicate profile semantic rule: {name}")
            names.add(name)

            if "alternatives" in rule:
                if set(rule) != {"name", "alternatives"}:
                    raise ProfileSemanticError(
                        f"{name} alternatives rule cannot define direct match fields"
                    )
                alternatives = rule["alternatives"]
                if not isinstance(alternatives, list) or len(alternatives) < 2:
                    raise ProfileSemanticError(
                        f"{name}.alternatives must contain at least two matchers"
                    )
                for alternative_index, matcher in enumerate(alternatives):
                    _validate_matcher(
                        matcher, f"{name}.alternatives[{alternative_index}]"
                    )
            else:
                direct = {key: value for key, value in rule.items() if key != "name"}
                _validate_matcher(direct, name)
    return sections


def load_contract(profiles_root: pathlib.Path, profile: str) -> dict[str, Any]:
    """Load common and device semantics from their owning profile directories."""

    if profile == "common" or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", profile):
        raise ProfileSemanticError(f"invalid device profile for semantics: {profile!r}")
    scopes = {
        "common": _load_scope(profiles_root / "common/semantics.json", "common"),
        profile: _load_scope(profiles_root / profile / "semantics.json", profile),
    }
    names = [
        rule["name"]
        for sections in scopes.values()
        for rule in sections["source"]
    ]
    if len(names) != len(set(names)):
        raise ProfileSemanticError("common/device semantics contain duplicate rule names")
    return {"schema": 3, "scopes": scopes}


def _format_template(
    template: str,
    kernel_series: str | None,
    kernel_version: str | None,
    name: str,
) -> str:
    if "{kernel_series}" in template:
        if not kernel_series or not re.fullmatch(r"[0-9]+\.[0-9]+", kernel_series):
            raise ProfileSemanticError(
                f"{name} requires a valid selected kernel series"
            )
        template = template.replace("{kernel_series}", kernel_series)
    if "{kernel_version}" in template:
        if not kernel_version or not re.fullmatch(
            r"[0-9]+\.[0-9]+\.[0-9]+", kernel_version
        ):
            raise ProfileSemanticError(
                f"{name} requires a valid selected kernel version"
            )
        template = template.replace("{kernel_version}", kernel_version)
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
        raise ProfileSemanticError(
            f"profile semantic path escapes its contract root: {relative}"
        ) from exc
    return candidate


def _check_matcher(
    name: str,
    matcher: dict[str, Any],
    root: pathlib.Path,
    kernel_series: str | None,
    kernel_version: str | None,
) -> tuple[str | None, str | None]:
    if "path" in matcher:
        relative = pathlib.Path(
            _format_template(
                matcher["path"], kernel_series, kernel_version, name
            )
        )
        candidate = _safe_candidate(root, relative)
        if not candidate.is_file():
            return None, f"{name}: required file is missing: {relative.as_posix()}"
        try:
            content = candidate.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError) as exc:
            return None, f"{name}: cannot read {relative.as_posix()}: {exc}"
        failures = _content_problems(matcher, content)
        if failures:
            return None, f"{name}: {relative.as_posix()}: {'; '.join(failures)}"
        return f"semantic {name} ({relative.as_posix()})", None

    pattern = _format_template(
        matcher["glob"], kernel_series, kernel_version, name
    )
    candidates = sorted(path for path in root.glob(pattern) if path.is_file())
    if not candidates:
        return None, f"{name}: source glob matched no files: {pattern}"
    for candidate in candidates:
        safe = _safe_candidate(root, candidate.relative_to(root))
        try:
            content = safe.read_text(encoding="utf-8")
        except (OSError, UnicodeDecodeError):
            continue
        if not _content_problems(matcher, content):
            relative = safe.relative_to(root.resolve()).as_posix()
            return f"semantic {name} ({relative})", None
    return None, (
        f"{name}: no single file matching {pattern} satisfies every content assertion"
    )


def _check_rule(
    rule: dict[str, Any],
    root: pathlib.Path,
    kernel_series: str | None,
    kernel_version: str | None,
) -> tuple[str | None, str | None]:
    name = rule["name"]
    alternatives = rule.get("alternatives")
    if alternatives is None:
        matcher = {key: value for key, value in rule.items() if key != "name"}
        return _check_matcher(
            name, matcher, root, kernel_series, kernel_version
        )

    failures: list[str] = []
    for index, matcher in enumerate(alternatives, start=1):
        check, problem = _check_matcher(
            name, matcher, root, kernel_series, kernel_version
        )
        if check:
            return check, None
        failures.append(f"alternative {index}: {problem}")
    return None, f"{name}: no semantic alternative matched: {' | '.join(failures)}"


def check_contract(
    contract: dict[str, Any],
    profile: str,
    openwrt_root: pathlib.Path,
    *,
    kernel_series: str,
    kernel_version: str,
) -> tuple[list[str], list[str]]:
    scopes = contract["scopes"]
    if profile == "common" or profile not in scopes:
        raise ProfileSemanticError(f"unknown maintained profile: {profile}")

    checks: list[str] = []
    problems: list[str] = []
    for scope in ("common", profile):
        for rule in scopes[scope]["source"]:
            try:
                check, problem = _check_rule(
                    rule, openwrt_root, kernel_series, kernel_version
                )
            except ProfileSemanticError as exc:
                check, problem = None, f"{rule['name']}: {exc}"
            if check:
                checks.append(check)
            if problem:
                problems.append(problem)
    return checks, problems
