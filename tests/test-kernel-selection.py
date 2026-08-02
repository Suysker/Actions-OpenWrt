#!/usr/bin/env python3
"""Exercise the shared stable/testing kernel selection interpreter."""

from __future__ import annotations

import importlib.util
import pathlib
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
SCRIPTS = ROOT / "scripts"
if str(SCRIPTS) not in sys.path:
    sys.path.insert(0, str(SCRIPTS))
SPEC = importlib.util.spec_from_file_location(
    "kernel_selection", ROOT / "scripts/kernel_selection.py"
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


TARGET = """\
KERNEL_PATCHVER:=6.12
KERNEL_TESTING_PATCHVER:=6.18
"""
METADATA_612 = """\
LINUX_VERSION-6.12 = .100
LINUX_KERNEL_HASH-6.12.100 = aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
"""
METADATA_618 = """\
LINUX_VERSION-6.18 = .38
LINUX_KERNEL_HASH-6.18.38 = bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
"""


def expect_error(callable_object, fragment: str) -> None:
    try:
        callable_object()
    except MODULE.KernelSelectionError as exc:
        assert fragment in str(exc), str(exc)
    else:
        raise AssertionError(f"expected kernel selection error containing {fragment!r}")


assert MODULE.selected_channel({"CONFIG_TESTING_KERNEL": "n"}) == "stable"
assert MODULE.selected_channel({"CONFIG_TESTING_KERNEL": "y"}) == "testing"
expect_error(lambda: MODULE.selected_channel({}), "explicitly own")
expect_error(
    lambda: MODULE.selected_channel({"CONFIG_TESTING_KERNEL": "m"}),
    "must be y or n",
)
assert MODULE.selected_series(TARGET, "stable") == "6.12"
assert MODULE.selected_series(TARGET, "testing") == "6.18"
assert MODULE.kernel_series_symbol("6.18") == "LINUX_6_18"
expect_error(lambda: MODULE.kernel_series_symbol("6.18.38"), "invalid kernel series")
expect_error(
    lambda: MODULE.selected_series(TARGET + "KERNEL_TESTING_PATCHVER:=6.19\n", "testing"),
    "expected one KERNEL_TESTING_PATCHVER",
)
assert MODULE.exact_version_and_hash(METADATA_618, "6.18") == (
    "6.18.38",
    "b" * 64,
)

testing = MODULE.resolve_from_text(
    {"CONFIG_TESTING_KERNEL": "y"}, "rockchip", TARGET, METADATA_618
)
assert testing.lock_fields() == {
    "kernel_target": "rockchip",
    "kernel_channel": "testing",
    "kernel_series": "6.18",
    "kernel_version": "6.18.38",
    "kernel_source_sha256": "b" * 64,
}

with tempfile.TemporaryDirectory() as raw_directory:
    root = pathlib.Path(raw_directory)
    (root / "target/linux/x86").mkdir(parents=True)
    (root / "include").mkdir()
    (root / "target/linux/x86/Makefile").write_text(TARGET, encoding="utf-8")
    (root / "include/kernel-6.12").write_text(METADATA_612, encoding="utf-8")
    stable = MODULE.resolve_from_tree(
        root, "x86", {"CONFIG_TESTING_KERNEL": "n"}
    )
    assert stable.channel == "stable"
    assert stable.version == "6.12.100"

print("Kernel selection tests passed.")
