#!/usr/bin/env python3
from __future__ import annotations

import importlib.util
import pathlib
import shutil
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "kernel_module_metadata", ROOT / "scripts/kernel_module_metadata.py"
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def compile_object(directory: pathlib.Path, name: str, declarations: str) -> pathlib.Path:
    source = directory / f"{name}.c"
    output = directory / f"{name}.ko"
    source.write_text(declarations, encoding="utf-8")
    subprocess.run(
        ["cc", "-c", str(source), "-o", str(output)],
        check=True,
        capture_output=True,
        text=True,
    )
    return output


def expect_error(module: pathlib.Path, field: str, fragment: str) -> None:
    try:
        MODULE.field_value(module, field)
    except MODULE.ModuleMetadataError as exc:
        assert fragment in str(exc), str(exc)
    else:
        raise AssertionError(f"metadata failure was accepted: {module} {field}")


with tempfile.TemporaryDirectory() as raw_directory:
    directory = pathlib.Path(raw_directory)
    valid = compile_object(
        directory,
        "valid",
        """
        static const char version[]
          __attribute__((section(".modinfo"), used)) = "version=3";
        static const char vermagic[]
          __attribute__((section(".modinfo"), used)) =
          "vermagic=6.12.100 SMP mod_unload";
        static const char alias_one[]
          __attribute__((section(".modinfo"), used)) = "alias=fixture-one";
        static const char alias_two[]
          __attribute__((section(".modinfo"), used)) = "alias=fixture-two";
        """,
    )
    assert MODULE.field_value(valid, "version") == "3"
    assert MODULE.field_value(valid, "vermagic") == "6.12.100 SMP mod_unload"
    assert set(MODULE.read_modinfo(valid)["alias"]) == {
        "fixture-one",
        "fixture-two",
    }

    clang = shutil.which("clang")
    if clang is not None:
        arm64_source = directory / "arm64.c"
        arm64 = directory / "arm64.ko"
        arm64_source.write_text(
            'static const char version[] '
            '__attribute__((section(".modinfo"), used)) = "version=3";\n',
            encoding="utf-8",
        )
        subprocess.run(
            [clang, "--target=aarch64-linux-gnu", "-c", arm64_source, "-o", arm64],
            check=True,
            capture_output=True,
            text=True,
        )
        assert MODULE.field_value(arm64, "version") == "3"

    missing = compile_object(
        directory,
        "missing",
        """
        static const char vermagic[]
          __attribute__((section(".modinfo"), used)) = "vermagic=6.12.100";
        """,
    )
    expect_error(missing, "version", "has no .modinfo field")

    conflicting = compile_object(
        directory,
        "conflicting",
        """
        static const char version_three[]
          __attribute__((section(".modinfo"), used)) = "version=3";
        static const char version_two[]
          __attribute__((section(".modinfo"), used)) = "version=2";
        """,
    )
    expect_error(conflicting, "version", "conflicting .modinfo field")

    no_section = compile_object(directory, "no_section", "int fixture;\n")
    expect_error(no_section, "version", "has no readable .modinfo entries")

    completed = subprocess.run(
        [sys.executable, str(ROOT / "scripts/kernel_module_metadata.py"), valid, "version"],
        check=True,
        capture_output=True,
        text=True,
    )
    assert completed.stdout == "3\n"

print("Kernel module metadata tests passed.")
