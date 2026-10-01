"""Bounded context-only rebase of the upstream BBR app-limited timer hook."""

import re


# Stable kernels moved the retransmit timer from inet_connection_sock to sock.
# That unrelated preceding call is not part of the BBR change. Keep the complete
# insertion semantics and its two leading/three trailing context lines; never
# relax the strict apply check or rewrite actual added/removed source lines.
# Retire this adaptation once the provider no longer ships this obsolete hunk.
_TIMER_HUNK = re.compile(
    rb"(--- a/net/ipv4/tcp_timer\.c\n\+\+\+ b/net/ipv4/tcp_timer\.c\n)"
    rb"@@ -(\d+),6 \+(\d+),7 @@( void tcp_write_timer_handler[^\n]*\n)"
    rb" \t\t\t       icsk_timeout\(icsk\)\);\n"
    rb"( \t\treturn;\n \t}\n\+\ttcp_rate_check_app_limited\(sk\);\n"
    rb" \ttcp_mstamp_refresh\(tcp_sk\(sk\)\);\n"
    rb" \tevent = icsk->icsk_pending;\n \n)"
)


def rebase_timer_context(payload: bytes) -> bytes:
    def replace(match: re.Match[bytes]) -> bytes:
        old_start, new_start = int(match[2]) + 1, int(match[3]) + 1
        header = f"@@ -{old_start},5 +{new_start},6 @@".encode("ascii")
        return match[1] + header + match[4] + match[5]

    return _TIMER_HUNK.sub(replace, payload)
