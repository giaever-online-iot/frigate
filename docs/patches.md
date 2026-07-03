# Carried patches (downstream deviations from upstream Frigate)

| Patch | Introduced | Purpose | Rebase notes |
|---|---|---|---|
| `spike/patches/0001-env-driven-paths.patch` | M2 (v0.17.2) | Make `frigate/const.py` base paths env-overridable (`FRIGATE_CONFIG_DIR`/`FRIGATE_BASE_DIR`/`FRIGATE_CACHE_DIR`; defaults unchanged ⇒ upstream no-op). Required because snapd layouts cannot target `/config` (root-level) or `/media/*` (denied allow-list entry) — see docs/m2-findings.md. | Re-diff against each new tag; constants may move/rename. Upstreaming candidate: yes — a small, defaults-preserving env override is upstreamable; consider a PR after M3 proves it in production shape. |

A second patch (shm name prefix, `snap.<instance>.*`) is planned for M3 — see docs/spike-findings.md (A1).
