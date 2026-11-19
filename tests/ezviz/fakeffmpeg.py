"""Stand-in for ffmpeg (W-23 T10): drains stdin into /dev/null, dumps argv and env as JSON to $FAKEFF_DUMP.

Knobs (env, set by a generated wrapper script, see fixtures.fake_ffmpeg): FAKEFF_EXIT_AFTER_S, FAKEFF_IGNORE_TERM,
FAKEFF_LINGER (keep running after stdin EOF, so only pdeathsig/SIGTERM can end it).
"""
import json
import os
import select
import signal
import sys
import time

dump = os.environ.get("FAKEFF_DUMP")
if dump:
    with open(dump, "w") as f:
        json.dump({"argv": sys.argv, "env": dict(os.environ)}, f)
if os.environ.get("FAKEFF_IGNORE_TERM"):
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
exit_after = os.environ.get("FAKEFF_EXIT_AFTER_S")
deadline = time.monotonic() + float(exit_after) if exit_after else None
eof = False
sink = open(os.devnull, "wb")
while True:
    if deadline is not None and time.monotonic() >= deadline:
        sys.exit(0)
    if eof:
        if os.environ.get("FAKEFF_IGNORE_TERM") or os.environ.get("FAKEFF_LINGER"):
            time.sleep(0.1)
            continue
        sys.exit(0)
    r, _, _ = select.select([0], [], [], 0.1)
    if r:
        data = os.read(0, 65536)
        if not data:
            eof = True
        else:
            sink.write(data)
