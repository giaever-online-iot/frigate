"""T-END (spec §4.3) and the D4 login budget as pure functions. Stdlib only.

A session starts at an "attempt" record; its login_ok, published and first end record belong to it.
Phase: P1 no login_ok, P2 login_ok but no published, P3 published. The latch row and the ladder count
only what lies after the last "unlatch" record (plan P6); the cap and the spacing count every "attempt"
record and nothing else (rev 5 nit 2), future-dated ones included (Review Focus 1).
"""
from dataclasses import dataclass

from . import constants as C


@dataclass(frozen=True)
class Decision:
    allow: bool
    cls: str                  # "ok" | "budget_wait" | "latched"
    next_allowed: float       # == now when allow
    attempts_in_window: int
    synthetic: object         # dict to append BEFORE acting (D21), or None
    latch_now: bool           # latched by auth_fail or a full row, and no "latch" record since the last unlatch


def _split(records: list) -> list:
    sessions, cur = [], None
    for r in records:
        ev = r["ev"]
        if ev == "attempt":
            cur = {"a": r["t"], "login_ok": None, "published": None, "end": None}
            sessions.append(cur)
        elif cur is not None and cur["end"] is None:
            if ev == "login_ok" and cur["login_ok"] is None:
                cur["login_ok"] = r["t"]
            elif ev == "published" and cur["published"] is None:
                cur["published"] = r["t"]
            elif ev in C.END_EVENTS:
                cur["end"] = r
    return sessions


def _phase(s: dict) -> str:
    if s["login_ok"] is None:
        return "P1"
    return "P2" if s["published"] is None else "P3"


def phase_of_open_session(records: list):
    s = _split(records)
    return _phase(s[-1]) if s and s[-1]["end"] is None else None


def _effect(s: dict) -> str:
    """T-END ladder column for an ended session: auth | rung | fixed | none."""
    ev, ph = s["end"]["ev"], _phase(s)
    if ev == "auth_fail":
        return "auth"                                  # E2
    if ph in ("P1", "P2"):
        return "rung"                                  # E3-E5, E7-E11
    if ev == "stop":
        return "none"                                  # E13
    if ev == "unknown_end":
        return "fixed"                                 # E17
    return "rung"                                      # E14-E16


def decide(records: list, now: float, *, latch_file: bool) -> Decision:
    recs = list(records)
    synthetic = None
    every = _split(recs)
    if every and every[-1]["end"] is None:             # D21: class the dead open session once, t = now
        synthetic = {"t": now, "ev": "net_fail" if _phase(every[-1]) == "P1" else "unknown_end",
                     "dur": None, "syn": True}
        recs.append(synthetic)
        every[-1]["end"] = synthetic
    attempts = sorted(s["a"] for s in every)

    cut = max((i for i, r in enumerate(recs) if r["ev"] == "unlatch"), default=-1)
    tail = recs[cut + 1:]
    sess = _split(tail)

    row, auth = 0, False
    for s in sess:
        if s["published"] is not None:
            row = 0                                     # E6
        elif s["end"] is not None and _phase(s) == "P2":
            row += 1                                    # E7-E11
        if s["end"] is not None and s["end"]["ev"] == "auth_fail":
            auth = True                                 # E2
    latched = latch_file or auth or row >= C.LATCH_ROW
    latch_now = latched and not latch_file and not any(r["ev"] == "latch" for r in tail)

    # Ladder (D4): a reset puts k back to 0 BEFORE the session's own end is counted, so the next rung
    # after a reset waits LADDER_S[0] = 60 s ("resets TO 60 s", SF1).
    k, prev_a = 0, None
    for s in sess:
        if prev_a is not None and s["a"] - prev_a >= C.LADDER_RESET_IDLE_S:
            k = 0
        prev_a = s["a"]
        if s["published"] is not None and s["end"]["t"] - s["published"] >= C.LADDER_RESET_PUBLISHED_S:
            k = 0
        if _effect(s) == "rung":
            k += 1

    wait_end = 0.0
    if sess:
        last = sess[-1]
        eff, e = _effect(last), last["end"]["t"]
        if eff == "rung":
            if attempts and now - attempts[-1] >= C.LADDER_RESET_IDLE_S:
                k = min(k, 1)                           # 60 min with no attempt: back to the 60 s rung
            if k <= len(C.LADDER_S):
                wait_end = e + C.LADDER_S[k - 1]
            elif len(attempts) >= C.CAP_ATTEMPTS:      # rung 4+: until the window allows (P7)
                wait_end = attempts[-C.CAP_ATTEMPTS] + C.WINDOW_S
        elif eff == "fixed":
            wait_end = e + C.FIXED_WAIT_S

    window = [a for a in attempts if a > now - C.WINDOW_S]
    spacing = attempts[-1] + C.SPACING_S if attempts else 0.0
    cap = attempts[-C.CAP_ATTEMPTS] + C.WINDOW_S if len(window) >= C.CAP_ATTEMPTS else 0.0
    next_allowed = max(now, spacing, cap, wait_end)
    allow = not latched and next_allowed <= now
    cls = "latched" if latched else ("ok" if allow else "budget_wait")
    return Decision(allow, cls, next_allowed, len(window), synthetic, latch_now)
