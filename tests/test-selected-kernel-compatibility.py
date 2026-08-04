#!/usr/bin/env python3
"""Exercise stable backport and testing/upstream selected-kernel paths."""

from __future__ import annotations

import importlib.util
import pathlib
import shutil
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "selected_kernel_compatibility",
    ROOT / "scripts/selected_kernel_compatibility.py",
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def patch_directory(root: pathlib.Path, series: str) -> pathlib.Path:
    directory = root / "target/linux/generic" / f"backport-{series}"
    directory.mkdir(parents=True)
    return directory


def write_patch(path: pathlib.Path, added_lines: list[str]) -> None:
    additions = "\n".join(f"+{line}" for line in added_lines)
    path.write_text(
        "--- a/drivers/net/ppp/ppp_generic.c\n"
        "+++ b/drivers/net/ppp/ppp_generic.c\n"
        f"@@ -1 +1,{len(added_lines) + 1} @@\n"
        " context\n"
        f"{additions}\n",
        encoding="utf-8",
    )


def expect_error(callable_object, fragment: str) -> None:
    try:
        callable_object()
    except MODULE.SelectedKernelCompatibilityError as exc:
        assert fragment in str(exc), str(exc)
    else:
        raise AssertionError(f"expected error containing {fragment!r}")


capability = MODULE.load_capability(ROOT)
assert capability.id == "ppp-tx-scatter-gather"
assert capability.semantic_rule == "common.ppp-tx-scatter-gather"
assert set(capability.variants) == {"6.12"}

with tempfile.TemporaryDirectory() as temporary:
    source = pathlib.Path(temporary)
    stable = source / "stable"
    stable_patches = patch_directory(stable, "6.12")
    write_patch(
        stable_patches / "620-ppp-direct-xmit.patch",
        ["bool direct_xmit;", "po->chan.direct_xmit = true;"],
    )
    resolution = MODULE.resolve(ROOT, stable, "6.12")
    assert resolution.status == "compatibility-required"
    assert resolution.variant is not None

    destination = stable_patches / resolution.variant.install_name
    shutil.copy2(resolution.variant.patch, destination)
    assert MODULE.resolve(ROOT, stable, "6.12").status == "compatibility-present"

    testing = source / "testing"
    testing_patches = patch_directory(testing, "6.18")
    write_patch(testing_patches / "625-native-ppp-sg.patch", list(capability.markers))
    testing_resolution = MODULE.resolve(ROOT, testing, "6.18")
    assert testing_resolution.status == "upstream-patch"
    assert testing_resolution.variant is None

    partial = source / "partial"
    partial_patches = patch_directory(partial, "6.18")
    write_patch(partial_patches / "625-partial-ppp-sg.patch", [capability.markers[0]])
    expect_error(
        lambda: MODULE.resolve(ROOT, partial, "6.18"),
        "partially implements",
    )

    unsupported = source / "unsupported"
    unsupported_patches = patch_directory(unsupported, "6.15")
    write_patch(
        unsupported_patches / "620-ppp-direct-xmit.patch",
        ["bool direct_xmit;", "po->chan.direct_xmit = true;"],
    )
    expect_error(
        lambda: MODULE.resolve(ROOT, unsupported, "6.15"),
        "no audited compatibility variant",
    )

    future = source / "future"
    patch_directory(future, "7.0")
    assert MODULE.resolve(ROOT, future, "7.0").status == "upstream-kernel"

print("selected-kernel compatibility tests passed")
