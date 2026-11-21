"""Every number the W-23 spec pins (D4, D17, D19, D22, §4.1, §4.3). Stdlib only.

KEEPALIVE_FORM, KEEPALIVE_COUNT, STARTTIMEOUT_S and TIMESTAMP_MODE are set by Task 21 from gate GA's probe lines (the
63-minute sessions on both real cameras), by the plan's rules; docs/w23-findings.md section A has the lines and the
`chosen:` line these must equal (test_constants_match_findings). One part stays an estimate: KEEPALIVE_COUNT's render
cap assumes the hub is 4 x slower than the laptop at rendering the plan; S5 measures the hub's publish time.
"""
CAP_ATTEMPTS = 3
WINDOW_S = 3600
SPACING_S = 60
LADDER_S = (60, 300, 900)
LADDER_RESET_PUBLISHED_S = 3600
LADDER_RESET_IDLE_S = 3600
FIXED_WAIT_S = 60
LATCH_ROW = 3
SOCKET_TIMEOUT_S = 10.0
PUBLISH_HOLD_S = 5.0
FFMPEG_EXIT_GRACE_S = 1.0
ALARM_S = 4
STARTTIMEOUT_S = 30            # gate GA: worst first_irap_s + render_s 1.674 s <= 20 s (else 45)
KEEPALIVE_FORM = "extend"      # gate GA: 3780 s on both cameras, keepalive_failed=0
KEEPALIVE_COUNT = 4320         # gate GA: max(4320, ceil(3780.319 / 5) = 757); render 0.248 s x 4 = 0.99 s <= 3 s
TIMESTAMP_MODE = "rtp"         # gate GA: rtp_ts_monotonic 1.0000 (>= 0.999), p99_dev <= 2 (<= 360) on every probe
TRIM_KEEP_S = 7 * 86400
EXIT_STOP, EXIT_TEMP, EXIT_AUTH, EXIT_CONFIG, EXIT_USAGE = 0, 75, 77, 78, 64
NAME_RE = r"^[a-z0-9_]{1,32}$"
END_EVENTS = frozenset({"auth_fail", "net_fail", "session_end", "output_end", "stop",
                        "start_timeout", "unknown_end", "protocol_fail"})
