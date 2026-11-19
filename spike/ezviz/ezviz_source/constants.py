"""Every number the W-23 spec pins (D4, D17, D19, D22, §4.1, §4.3). Stdlib only.

PROVISIONAL: KEEPALIVE_FORM, KEEPALIVE_COUNT, STARTTIMEOUT_S and TIMESTAMP_MODE are the plan's defaults, pending
gate GA (the long-session probe on the real cameras) and Task 21, which sets them from its lines. A build before
Task 21 runs with these values; they are not final (docs/w23-findings.md, "A ... pending gate GA").
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
STARTTIMEOUT_S = 30            # PROVISIONAL (gate GA, Task 21): may become 45
KEEPALIVE_FORM = "extend"      # PROVISIONAL (gate GA, Task 21): "extend" | "repeat"
KEEPALIVE_COUNT = 4320         # PROVISIONAL (gate GA, Task 21): >= 4320, render <= 3 s on the hub
TIMESTAMP_MODE = "wallclock"   # PROVISIONAL (gate GA, Task 21): "wallclock" | "rtp"
TRIM_KEEP_S = 7 * 86400
EXIT_STOP, EXIT_TEMP, EXIT_AUTH, EXIT_CONFIG, EXIT_USAGE = 0, 75, 77, 78, 64
NAME_RE = r"^[a-z0-9_]{1,32}$"
END_EVENTS = frozenset({"auth_fail", "net_fail", "session_end", "output_end", "stop",
                        "start_timeout", "unknown_end", "protocol_fail"})
