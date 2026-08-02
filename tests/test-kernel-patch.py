#!/usr/bin/env python3
"""Exercise shared Git/quilt kernel patch parsing and path rejection."""

from __future__ import annotations

import importlib.util
import pathlib
import sys


ROOT = pathlib.Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location(
    "kernel_patch", ROOT / "scripts/kernel_patch.py"
)
assert SPEC is not None and SPEC.loader is not None
MODULE = importlib.util.module_from_spec(SPEC)
sys.modules[SPEC.name] = MODULE
SPEC.loader.exec_module(MODULE)


def expect_error(payload: bytes | str, fragment: str) -> None:
    try:
        MODULE.inspect_patch(payload)
    except MODULE.KernelPatchError as exc:
        assert fragment in str(exc), str(exc)
    else:
        raise AssertionError(f"unsafe patch was accepted: {payload!r}")


git_patch = """\
From 0000000000000000000000000000000000000000 Mon Sep 17 00:00:00 2001
diff --git a/net/ipv4/tcp_bbr.c b/net/ipv4/tcp_bbr.c
--- a/net/ipv4/tcp_bbr.c
+++ b/net/ipv4/tcp_bbr.c
@@ -1 +1 @@
-old
+new
"""
quilt_patch = """\
--- a/include/net/tcp.h
+++ b/include/net/tcp.h
@@ -1 +1 @@
-old
+new
--- a/net/ipv4/tcp_output.c
+++ b/net/ipv4/tcp_output.c
@@ -1 +1 @@
-old
+new
"""

git = MODULE.inspect_patch(git_patch)
assert git.format == "git"
assert git.touched_paths == ("net/ipv4/tcp_bbr.c",)
quilt = MODULE.inspect_patch(quilt_patch)
assert quilt.format == "quilt"
assert quilt.touched_paths == ("include/net/tcp.h", "net/ipv4/tcp_output.c")

expect_error(b"--- a/file\x00\n+++ b/file\n", "NUL")
expect_error("--- /etc/passwd\n+++ b/file\n", "must use")
expect_error("--- a/../escape\n+++ b/../escape\n", "escapes")
expect_error("--- a/file\n", "unpaired")
expect_error(
    "diff --git a/net/a.c b/net/a.c\n",
    "no paired unified file headers",
)
expect_error(
    "diff --git a/net/a.c b/net/a.c\n--- a/net/b.c\n+++ b/net/b.c\n",
    "paths differ",
)

print("Kernel patch tests passed.")
