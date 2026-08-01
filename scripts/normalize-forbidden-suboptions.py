#!/usr/bin/env python3
"""Normalize Kconfig child selections that outlive an exact-forbidden parent."""

from __future__ import annotations

import pathlib
import re
import sys
import tempfile

from profile_model import ProfileModelError, load_forbidden

SELECTED_RE = re.compile(r"(CONFIG_[^=]+)=(y|m)")
DISABLED_RE = re.compile(r"# (CONFIG_[^ ]+) is not set")


class NormalizeError(RuntimeError):
    pass


def exact_forbidden(path: pathlib.Path) -> tuple[str, ...]:
    try:
        packages = sorted(load_forbidden(path).exact)
    except ProfileModelError as exc:
        raise NormalizeError(str(exc)) from exc
    if not packages:
        raise NormalizeError("forbidden rules contain no exact package")
    return tuple(packages)


def parse_config(lines: list[str]) -> dict[str, str]:
    values: dict[str, str] = {}
    for line_no, line in enumerate(lines, 1):
        selected = re.fullmatch(r"(CONFIG_[^=]+)=(.*)", line)
        disabled = DISABLED_RE.fullmatch(line)
        if not selected and not disabled:
            continue
        symbol, value = selected.groups() if selected else (disabled.group(1), "n")
        if symbol in values:
            raise NormalizeError(
                f"duplicate Kconfig symbol at line {line_no}: {symbol}"
            )
        values[symbol] = value
    return values


def selected_forbidden_children(
    lines: list[str], packages: tuple[str, ...]
) -> list[tuple[int, str, str]]:
    values = parse_config(lines)
    prefixes = tuple(
        sorted(
            ((f"CONFIG_PACKAGE_{package}_", package) for package in packages),
            key=lambda item: len(item[0]),
            reverse=True,
        )
    )
    result: list[tuple[int, str, str]] = []
    for line_no, line in enumerate(lines):
        match = SELECTED_RE.fullmatch(line)
        if not match:
            continue
        symbol = match.group(1)
        matches = [
            (prefix, package)
            for prefix, package in prefixes
            if symbol.startswith(prefix)
        ]
        if not matches:
            continue
        longest = len(matches[0][0])
        owners = [package for prefix, package in matches if len(prefix) == longest]
        if len(owners) != 1:
            raise NormalizeError(
                f"ambiguous forbidden parent for Kconfig symbol: {symbol}"
            )
        package = owners[0]
        parent = f"CONFIG_PACKAGE_{package}"
        if values.get(parent) == "y":
            raise NormalizeError(
                f"exact-forbidden parent package is selected: {parent}"
            )
        result.append((line_no, package, symbol))
    return result


def write_report(
    path: pathlib.Path,
    mode: str,
    label: str,
    entries: list[tuple[int, str, str]],
    guards: list[tuple[int, str, str]] | None = None,
) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    guards = guards or []
    lines = [
        "forbidden-suboptions-v2",
        f"mode={mode}",
        f"{label}_count={len(entries)}",
        f"guard_count={len(guards)}",
    ]
    lines.extend(f"{label}\t{package}\t{symbol}" for _, package, symbol in entries)
    lines.extend(
        f"guard\t{package}\t{target}\tline={line_no + 1}"
        for line_no, package, target in guards
    )
    path.write_text("\n".join(lines) + "\n", encoding="utf-8")


def replace_lines(path: pathlib.Path, lines: list[str]) -> None:
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, delete=False, newline="\n"
    ) as handle:
        handle.write("\n".join(lines) + "\n")
        temporary = pathlib.Path(handle.name)
    temporary.replace(path)


def _active_choice(lines: list[str], declaration: int) -> int | None:
    choices: list[int] = []
    for line_no, line in enumerate(lines[: declaration + 1]):
        stripped = line.strip()
        if stripped == "choice" or stripped.startswith("choice "):
            choices.append(line_no)
        elif stripped == "endchoice":
            if not choices:
                raise NormalizeError("generated Kconfig has an unmatched endchoice")
            choices.pop()
    return choices[-1] if choices else None


def _choice_end(lines: list[str], start: int) -> int:
    depth = 0
    for line_no in range(start, len(lines)):
        stripped = lines[line_no].strip()
        if stripped == "choice" or stripped.startswith("choice "):
            depth += 1
        elif stripped == "endchoice":
            depth -= 1
            if depth == 0:
                return line_no
    raise NormalizeError(f"generated Kconfig choice at line {start + 1} is not closed")


def guard_generated_kconfig(
    path: pathlib.Path, entries: list[tuple[int, str, str]]
) -> list[tuple[int, str, str]]:
    if not path.is_file():
        raise NormalizeError(f"generated package Kconfig does not exist: {path}")
    lines = path.read_text(encoding="utf-8").splitlines()
    anchors: dict[int, tuple[str, str]] = {}
    for _, package, symbol in entries:
        kconfig_symbol = symbol.removeprefix("CONFIG_")
        declarations = [
            line_no
            for line_no, line in enumerate(lines)
            if re.fullmatch(rf"\s*config\s+{re.escape(kconfig_symbol)}\s*", line)
        ]
        if len(declarations) != 1:
            raise NormalizeError(
                f"expected one generated Kconfig declaration for {symbol}, "
                f"found {len(declarations)}"
            )
        declaration = declarations[0]
        choice = _active_choice(lines, declaration)
        anchor = choice if choice is not None else declaration
        target = "choice" if choice is not None else kconfig_symbol
        previous = anchors.get(anchor)
        if previous and previous[0] != package:
            raise NormalizeError(
                f"generated Kconfig {target} mixes forbidden parents "
                f"{previous[0]} and {package}"
            )
        anchors[anchor] = (package, target)

    guards: list[tuple[int, str, str]] = []
    insertions: list[tuple[int, str]] = []
    for anchor, (package, target) in sorted(anchors.items()):
        parent = f"PACKAGE_{package}"
        indentation = re.match(r"^(\s*)", lines[anchor]).group(1) + "\t"
        end = _choice_end(lines, anchor) if target == "choice" else anchor + 1
        if target != "choice":
            while end < len(lines):
                if re.match(r"^\s*(config|choice|endchoice)\b", lines[end]):
                    break
                end += 1
        dependency = re.compile(rf"^\s*depends\s+on\s+{re.escape(parent)}(?:\s|$)")
        if any(dependency.search(line) for line in lines[anchor + 1 : end]):
            continue
        insertions.append((anchor + 1, f"{indentation}depends on {parent}"))
        guards.append((anchor, package, target))

    for line_no, dependency in reversed(insertions):
        lines.insert(line_no, dependency)
    if insertions:
        replace_lines(path, lines)
    return guards


def run(
    mode: str,
    config: pathlib.Path,
    forbidden: pathlib.Path,
    report: pathlib.Path,
    generated_kconfig: pathlib.Path | None = None,
) -> int:
    if mode not in {"apply", "check"}:
        raise NormalizeError(f"unsupported mode: {mode}")
    if not config.is_file():
        raise NormalizeError(f"OpenWrt config does not exist: {config}")

    lines = config.read_text(encoding="utf-8").splitlines()
    entries = selected_forbidden_children(lines, exact_forbidden(forbidden))
    if mode == "check":
        write_report(report, mode, "violation", entries)
        if entries:
            symbols = ", ".join(symbol for _, _, symbol in entries)
            raise NormalizeError(
                "forbidden parent suboptions survived the second defconfig: " + symbols
            )
        print("Forbidden parent suboption check passed.")
        return 0

    guards = (
        guard_generated_kconfig(generated_kconfig, entries)
        if generated_kconfig is not None and entries
        else []
    )
    for line_no, _, symbol in entries:
        lines[line_no] = f"# {symbol} is not set"
    if entries:
        replace_lines(config, lines)
    write_report(report, mode, "normalized", entries, guards)
    print(
        f"Normalized {len(entries)} forbidden parent suboption(s) and added "
        f"{len(guards)} parent guard(s)."
    )
    return 0


def main(argv: list[str]) -> int:
    if len(argv) not in {5, 6}:
        print(
            "Usage: normalize-forbidden-suboptions.py "
            "<apply|check> <.config> <rendered-forbidden> <report> "
            "[tmp/.config-package.in]",
            file=sys.stderr,
        )
        return 2
    return run(
        argv[1],
        pathlib.Path(argv[2]),
        pathlib.Path(argv[3]),
        pathlib.Path(argv[4]),
        pathlib.Path(argv[5]) if len(argv) == 6 else None,
    )


if __name__ == "__main__":
    try:
        raise SystemExit(main(sys.argv))
    except (NormalizeError, OSError, UnicodeError) as exc:
        print(f"::error::{exc}", file=sys.stderr)
        raise SystemExit(1)
