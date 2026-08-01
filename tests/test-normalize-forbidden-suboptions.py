#!/usr/bin/env python3
from __future__ import annotations

import pathlib
import subprocess
import sys
import tempfile


ROOT = pathlib.Path(__file__).resolve().parent.parent
SCRIPT = ROOT / "scripts/normalize-forbidden-suboptions.py"


def invoke(*arguments: pathlib.Path | str) -> subprocess.CompletedProcess[str]:
    return subprocess.run(
        [sys.executable, str(SCRIPT), *(str(value) for value in arguments)],
        check=False,
        text=True,
        capture_output=True,
    )


with tempfile.TemporaryDirectory() as directory:
    root = pathlib.Path(directory)
    config = root / ".config"
    forbidden = root / "forbidden.txt"
    report = root / "report.txt"
    generated_kconfig = root / ".config-package.in"
    forbidden.write_text(
        "# fixture\nexact:luci-app-ssr-plus\nregex:^unused-\n",
        encoding="utf-8",
    )
    config.write_text(
        "\n".join(
            (
                "# CONFIG_PACKAGE_luci-app-ssr-plus is not set",
                "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Http_Proxy=y",
                "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Optional=m",
                "CONFIG_PACKAGE_luci-app-passwall=y",
                "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray=y",
                "",
            )
        ),
        encoding="utf-8",
    )
    generated_kconfig.write_text(
        "\n".join(
            (
                "choice",
                '\tprompt "fixture choice"',
                "\tdefault PACKAGE_luci-app-ssr-plus_INCLUDE_Http_Proxy",
                "\tconfig PACKAGE_luci-app-ssr-plus_INCLUDE_Http_Proxy",
                '\t\tbool "HTTP"',
                "\tconfig PACKAGE_luci-app-ssr-plus_INCLUDE_Optional",
                '\t\tbool "Optional"',
                "endchoice",
                "",
            )
        ),
        encoding="utf-8",
    )

    applied = invoke("apply", config, forbidden, report, generated_kconfig)
    assert applied.returncode == 0, applied.stderr
    normalized = config.read_text(encoding="utf-8")
    assert (
        "# CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Http_Proxy is not set"
        in normalized
    )
    assert (
        "# CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Optional is not set" in normalized
    )
    assert "CONFIG_PACKAGE_luci-app-passwall_INCLUDE_Xray=y" in normalized
    assert "normalized_count=2" in report.read_text(encoding="utf-8")
    assert "guard_count=1" in report.read_text(encoding="utf-8")
    guarded = generated_kconfig.read_text(encoding="utf-8")
    assert guarded.count("depends on PACKAGE_luci-app-ssr-plus") == 1

    first_bytes = config.read_bytes()
    guarded_bytes = generated_kconfig.read_bytes()
    applied_again = invoke("apply", config, forbidden, report, generated_kconfig)
    assert applied_again.returncode == 0, applied_again.stderr
    assert config.read_bytes() == first_bytes
    assert generated_kconfig.read_bytes() == guarded_bytes
    assert "normalized_count=0" in report.read_text(encoding="utf-8")

    checked = invoke("check", config, forbidden, root / "check.txt")
    assert checked.returncode == 0, checked.stderr

    config.write_text(
        normalized.replace(
            "# CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Http_Proxy is not set",
            "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Http_Proxy=y",
        ),
        encoding="utf-8",
    )
    before_check = config.read_bytes()
    rejected = invoke("check", config, forbidden, root / "rejected.txt")
    assert rejected.returncode == 1
    assert "survived the second defconfig" in rejected.stderr
    assert config.read_bytes() == before_check

    config.write_text(
        "CONFIG_PACKAGE_luci-app-ssr-plus=y\n"
        "CONFIG_PACKAGE_luci-app-ssr-plus_INCLUDE_Http_Proxy=y\n",
        encoding="utf-8",
    )
    selected_parent = invoke("apply", config, forbidden, report)
    assert selected_parent.returncode == 1
    assert "exact-forbidden parent package is selected" in selected_parent.stderr

print("Forbidden parent suboption normalization tests passed.")
