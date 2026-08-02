#!/usr/bin/env python3
"""Interpret the single BBRv3 module-version compatibility contract."""

from __future__ import annotations

from dataclasses import dataclass
import hashlib
import json
import pathlib
import re
import sys
from typing import Iterable


class BBRModuleVersionError(RuntimeError):
    """The compatibility contract or observed source state is ambiguous."""


@dataclass(frozen=True)
class ModuleVersionContract:
    patch: pathlib.Path
    install_directory: str
    install_name: str
    source_path: pathlib.PurePosixPath
    stripped_macro: str
    retained_macro: str
    sha256: str


CONTRACT_FIELDS = {
    "patch",
    "install_directory_template",
    "install_name",
    "source_path",
    "stripped_macro",
    "retained_macro",
}


def _single_line(value: object, label: str) -> str:
    if not isinstance(value, str) or not value.strip() or "\n" in value or "\r" in value:
        raise BBRModuleVersionError(f"{label} must be one non-empty line")
    return value.strip()


def validate_policy_compatibility(
    repo_root: pathlib.Path, policy: dict[str, object]
) -> dict[str, str]:
    raw = policy.get("module_version_compatibility")
    if not isinstance(raw, dict) or set(raw) != CONTRACT_FIELDS:
        raise BBRModuleVersionError(
            "BBRv3 module_version_compatibility fields differ from its schema"
        )

    patch_name = _single_line(raw["patch"], "compatibility patch")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.patch", patch_name):
        raise BBRModuleVersionError(f"unsafe compatibility patch name: {patch_name!r}")
    patch = (repo_root / "patchsets/common/kernel" / patch_name).resolve()
    kernel_root = (repo_root / "patchsets/common/kernel").resolve()
    if patch.parent != kernel_root or not patch.is_file():
        raise BBRModuleVersionError(f"compatibility patch is missing: {patch}")

    directory_template = _single_line(
        raw["install_directory_template"], "compatibility install directory"
    )
    if directory_template.count("{series}") != 1:
        raise BBRModuleVersionError(
            "compatibility install directory must contain one {series} template"
        )
    if not re.fullmatch(r"hack-\{series\}", directory_template):
        raise BBRModuleVersionError(
            f"unsafe compatibility install directory: {directory_template!r}"
        )

    install_name = _single_line(raw["install_name"], "compatibility install name")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]*\.patch", install_name):
        raise BBRModuleVersionError(
            f"unsafe compatibility install name: {install_name!r}"
        )

    source_path_text = _single_line(raw["source_path"], "compatibility source path")
    source_path = pathlib.PurePosixPath(source_path_text)
    if (
        source_path.is_absolute()
        or ".." in source_path.parts
        or len(source_path.parts) < 2
        or source_path.suffix != ".c"
    ):
        raise BBRModuleVersionError(
            f"unsafe compatibility source path: {source_path_text!r}"
        )

    stripped = _single_line(raw["stripped_macro"], "stripped module macro")
    retained = _single_line(raw["retained_macro"], "retained module macro")
    if stripped == retained:
        raise BBRModuleVersionError("stripped and retained module macros are identical")

    removed = []
    added = []
    patch_lines = patch.read_text(encoding="utf-8").splitlines()
    old_paths = [line[6:] for line in patch_lines if line.startswith("--- a/")]
    new_paths = [line[6:] for line in patch_lines if line.startswith("+++ b/")]
    if old_paths != [source_path.as_posix()] or new_paths != [source_path.as_posix()]:
        raise BBRModuleVersionError(
            "compatibility patch target differs from the declared source path"
        )
    for line in patch_lines:
        if line.startswith("-") and not line.startswith("---"):
            removed.append(line[1:].strip())
        elif line.startswith("+") and not line.startswith("+++"):
            added.append(line[1:].strip())
    if removed.count(stripped) != 1 or added.count(retained) != 1:
        raise BBRModuleVersionError(
            "compatibility patch does not uniquely replace the declared module macro"
        )

    return {
        "patch": str(patch),
        "install_directory_template": directory_template,
        "install_name": install_name,
        "source_path": source_path.as_posix(),
        "stripped_macro": stripped,
        "retained_macro": retained,
        "sha256": hashlib.sha256(patch.read_bytes()).hexdigest(),
    }


def load_contract(repo_root: pathlib.Path, kernel_series: str) -> ModuleVersionContract:
    if not re.fullmatch(r"[0-9]+\.[0-9]+", kernel_series):
        raise BBRModuleVersionError(f"invalid kernel series: {kernel_series!r}")
    policy_path = repo_root / "patchsets/common/kernel/bbr3-sources.json"
    try:
        policy = json.loads(policy_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise BBRModuleVersionError(f"cannot read BBRv3 policy: {exc}") from exc
    if not isinstance(policy, dict) or policy.get("schema") != 2:
        raise BBRModuleVersionError("BBRv3 source policy schema must be 2")
    values = validate_policy_compatibility(repo_root, policy)
    install_directory = values["install_directory_template"].replace(
        "{series}", kernel_series
    )
    if not re.fullmatch(rf"hack-{re.escape(kernel_series)}", install_directory):
        raise BBRModuleVersionError(
            f"unsafe expanded compatibility directory: {install_directory!r}"
        )
    return ModuleVersionContract(
        patch=pathlib.Path(values["patch"]),
        install_directory=install_directory,
        install_name=values["install_name"],
        source_path=pathlib.PurePosixPath(values["source_path"]),
        stripped_macro=values["stripped_macro"],
        retained_macro=values["retained_macro"],
        sha256=values["sha256"],
    )


def _provider_added_lines(paths: Iterable[pathlib.Path]) -> list[str]:
    added: list[str] = []
    for path in paths:
        try:
            lines = path.read_text(encoding="utf-8").splitlines()
        except OSError as exc:
            raise BBRModuleVersionError(
                f"cannot read provider patch {path}: {exc}"
            ) from exc
        for line in lines:
            if line.startswith("+") and not line.startswith("+++"):
                added.append(line[1:].strip())
    return added


def provider_state(
    contract: ModuleVersionContract, patches: Iterable[pathlib.Path]
) -> str:
    added = _provider_added_lines(patches)
    stripped = added.count(contract.stripped_macro)
    retained = added.count(contract.retained_macro)
    if stripped == 1 and retained == 0:
        return "compatibility-required"
    if stripped == 0 and retained == 1:
        return "upstream"
    raise BBRModuleVersionError(
        "provider patches have ambiguous module-version semantics: "
        f"stripped={stripped}, retained={retained}"
    )


def source_state(contract: ModuleVersionContract, linux_root: pathlib.Path) -> str:
    source = linux_root.joinpath(*contract.source_path.parts)
    try:
        lines = [
            line.strip() for line in source.read_text(encoding="utf-8").splitlines()
        ]
    except OSError as exc:
        raise BBRModuleVersionError(f"cannot read BBRv3 source {source}: {exc}") from exc
    stripped = lines.count(contract.stripped_macro)
    retained = lines.count(contract.retained_macro)
    if stripped == 1 and retained == 0:
        return "stripped"
    if stripped == 0 and retained == 1:
        return "retained"
    raise BBRModuleVersionError(
        "BBRv3 source has ambiguous module-version semantics: "
        f"stripped={stripped}, retained={retained}"
    )


def main(argv: list[str]) -> int:
    if len(argv) < 4:
        print(
            "Usage: bbr3_module_version.py describe|provider-state|source-state "
            "<repo-root> <kernel-series> [paths...]",
            file=sys.stderr,
        )
        return 2
    command = argv[1]
    repo_root = pathlib.Path(argv[2]).resolve()
    try:
        contract = load_contract(repo_root, argv[3])
        if command == "describe" and len(argv) == 4:
            print(contract.patch)
            print(contract.install_directory)
            print(contract.install_name)
            print(contract.source_path.as_posix())
            print(contract.stripped_macro)
            print(contract.retained_macro)
            print(contract.sha256)
        elif command == "provider-state" and len(argv) > 4:
            print(provider_state(contract, map(pathlib.Path, argv[4:])))
        elif command == "source-state" and len(argv) == 5:
            print(source_state(contract, pathlib.Path(argv[4])))
        else:
            raise BBRModuleVersionError(f"invalid {command!r} arguments")
    except BBRModuleVersionError as exc:
        print(f"::error::{exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
