#!/usr/bin/env python3
"""Check the bounded timer-context rebase without altering TCP changes."""

import pathlib
import sys

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parents[1] / "scripts"))
from bbr3_patch import rebase_timer_context

original = (
    b"--- a/net/ipv4/tcp_timer.c\n+++ b/net/ipv4/tcp_timer.c\n"
    b"@@ -703,6 +703,7 @@ void tcp_write_timer_handler(struct sock\n"
    b" \t\t\t       icsk_timeout(icsk));\n"
    b" \t\treturn;\n \t}\n+\ttcp_rate_check_app_limited(sk);\n"
    b" \ttcp_mstamp_refresh(tcp_sk(sk));\n \tevent = icsk->icsk_pending;\n \n"
)
expected = original.replace(b"-703,6 +703,7", b"-704,5 +704,6").replace(
    b" \t\t\t       icsk_timeout(icsk));\n", b""
)
assert rebase_timer_context(original) == expected
assert rebase_timer_context(expected) == expected
# Refreshed upstream context is already valid and must stay byte-identical.
refreshed = original.replace(b"icsk_timeout(icsk)", b"tcp_timeout_expires(sk)")
assert rebase_timer_context(refreshed) == refreshed
# No version/line-number table; unrelated files and changed semantics stay untouched.
moved = original.replace(b"703", b"812")
assert rebase_timer_context(moved) == expected.replace(b"704", b"813")
for changed in (
    original.replace(b"tcp_timer.c", b"other.c"),
    original.replace(b"+\ttcp_rate_check_app_limited(sk);", b"+\tother(sk);"),
    original.replace(b" \tevent = icsk->icsk_pending;", b" \tevent = other;"),
):
    assert rebase_timer_context(changed) == changed
assert rebase_timer_context(b"unrelated patch\n") == b"unrelated patch\n"
print("BBRv3 timer-context rebase tests passed.")
