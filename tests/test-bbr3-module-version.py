#!/usr/bin/env python3
"""Exercise the single BBRv3 module-version compatibility interpreter."""

from __future__ import annotations

import importlib.util
import json
import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "bbr3_module_version", ROOT / "scripts/bbr3_module_version.py"
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def write_patch(path: pathlib.Path, *added: str) -> pathlib.Path:
    path.write_text(
        "diff --git a/net/ipv4/tcp_bbr.c b/net/ipv4/tcp_bbr.c\n"
        "--- a/net/ipv4/tcp_bbr.c\n"
        "+++ b/net/ipv4/tcp_bbr.c\n"
        "@@ -0,0 +1,%d @@\n" % len(added)
        + "".join(f"+{line}\n" for line in added),
        encoding="utf-8",
    )
    return path


def expect_error(callable_object, fragment: str) -> None:
    try:
        callable_object()
    except MODULE.BBRModuleVersionError as exc:
        assert fragment in str(exc), str(exc)
    else:
        raise AssertionError(f"expected compatibility error containing {fragment!r}")


contract = MODULE.load_contract(ROOT, "6.12")
assert contract.install_directory == "hack-6.12"
assert contract.install_name == "996-bbrv3-module-version.patch"
assert contract.source_path.as_posix() == "net/ipv4/tcp_bbr.c"
assert contract.sha256 == MODULE.hashlib.sha256(contract.patch.read_bytes()).hexdigest()

policy = json.loads(
    (ROOT / "patchsets/common/kernel/bbr3-sources.json").read_text(encoding="utf-8")
)
wrong_source_policy = json.loads(json.dumps(policy))
wrong_source_policy["module_version_compatibility"]["source_path"] = (
    "net/ipv4/not_tcp_bbr.c"
)
expect_error(
    lambda: MODULE.validate_policy_compatibility(ROOT, wrong_source_policy),
    "target differs from the declared source path",
)

with tempfile.TemporaryDirectory() as raw_directory:
    directory = pathlib.Path(raw_directory)
    required = write_patch(directory / "required.patch", contract.stripped_macro)
    upstream = write_patch(directory / "upstream.patch", contract.retained_macro)
    ambiguous = write_patch(
        directory / "ambiguous.patch",
        contract.stripped_macro,
        contract.retained_macro,
    )
    duplicate = write_patch(
        directory / "duplicate.patch",
        contract.stripped_macro,
        contract.stripped_macro,
    )
    missing = write_patch(directory / "missing.patch", "MODULE_LICENSE(\"GPL\");")

    assert MODULE.provider_state(contract, [required]) == "compatibility-required"
    assert MODULE.provider_state(contract, [upstream]) == "upstream"
    expect_error(
        lambda: MODULE.provider_state(contract, [ambiguous]),
        "stripped=1, retained=1",
    )
    expect_error(
        lambda: MODULE.provider_state(contract, [duplicate]),
        "stripped=2, retained=0",
    )
    expect_error(
        lambda: MODULE.provider_state(contract, [missing]),
        "stripped=0, retained=0",
    )

    linux = directory / "linux"
    source = linux.joinpath(*contract.source_path.parts)
    source.parent.mkdir(parents=True)
    source.write_text(
        '#define __stringify_1(value) #value\n'
        '#define __stringify(value) __stringify_1(value)\n'
        '#define __used __attribute__((used))\n'
        '#define __section(name) __attribute__((section(name)))\n'
        '#define __MODULE_INFO(tag, name, info) static const char '
        '__mod_##name[] __used __section(".modinfo") = '
        '__stringify(tag) "=" info\n'
        '#define __MODULE_INFO_DISABLED(name) struct disabled_##name {}\n'
        '#define MODULE_INFO(tag, info) __MODULE_INFO(tag, tag, info)\n'
        '#define MODULE_INFO_STRIP(tag, info) __MODULE_INFO_DISABLED(tag)\n'
        '#define MODULE_VERSION(info) MODULE_INFO_STRIP(version, info)\n'
        '#define MODULE_LICENSE(info) MODULE_INFO(license, info)\n'
        '#define MODULE_DESCRIPTION(info)\n'
        '#define BBR_VERSION 3\n\n'
        'MODULE_LICENSE("Dual BSD/GPL");\n'
        'MODULE_DESCRIPTION("TCP BBR (Bottleneck Bandwidth and RTT)");\n'
        f"{contract.stripped_macro}\n",
        encoding="utf-8",
    )
    subprocess.run(["git", "init", "-q", linux], check=True)
    subprocess.run(["git", "-C", linux, "add", "."], check=True)
    assert MODULE.source_state(contract, linux) == "stripped"
    stripped_module = directory / "stripped.ko"
    subprocess.run(["cc", "-c", source, "-o", stripped_module], check=True)
    stripped_result = subprocess.run(
        [
            sys.executable,
            ROOT / "scripts/kernel_module_metadata.py",
            stripped_module,
            "version",
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    assert stripped_result.returncode == 1
    assert "has no .modinfo field 'version'" in stripped_result.stderr
    subprocess.run(
        ["git", "-C", linux, "apply", "--check", contract.patch], check=True
    )
    subprocess.run(["git", "-C", linux, "apply", contract.patch], check=True)
    assert MODULE.source_state(contract, linux) == "retained"
    retained_module = directory / "retained.ko"
    subprocess.run(["cc", "-c", source, "-o", retained_module], check=True)
    retained_result = subprocess.run(
        [
            sys.executable,
            ROOT / "scripts/kernel_module_metadata.py",
            retained_module,
            "version",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    assert retained_result.stdout == "3\n"

    completed = subprocess.run(
        [
            sys.executable,
            ROOT / "scripts/bbr3_module_version.py",
            "provider-state",
            ROOT,
            "6.12",
            required,
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    assert completed.stdout == "compatibility-required\n"

print("BBRv3 module-version compatibility tests passed.")
