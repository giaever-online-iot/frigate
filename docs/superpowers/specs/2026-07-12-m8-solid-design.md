# M8 Design Spec — Solid: lean artifact, production-safe verification, feature completeness

**Date:** 2026-07-12
**Status:** Approved design, pre-implementation
**Parent spec:** [`2026-07-02-frigate-snap-design.md`](2026-07-02-frigate-snap-design.md)
**Evidence base:** [`docs/m7-findings.md`](../../m7-findings.md) (§M-next backlog, R4/R5 findings, no-fresh-gate deviation, upstream candidate #4)

## 1. Goal

M8 makes the shipped snap the artifact the user stands behind publicly. Exit criterion (**gate + field-soak**, USER):

1. The full assertion gate is green on the **lean artifact** in a clean LXD VM (the only environment where purge-cycles remain allowed).
2. The lean revision reaches `latest/edge` through CI, the production NVR migrates to track it (`snap refresh frigate --channel=latest/edge --amend` — the deliberate migration step deferred from M7), and a **soak window of 3–7 days** passes: zero crash-loops, zero unexpected journal errors, detections flowing on both cameras.

Only after the soak passes do the Store-side user actions unlock (visibility flip Private→Public, declaration-request submissions). Those stay **user actions outside the milestone** — standing directive: *"Nothing visibility nor snapcraft request until solid."*

## 2. Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Milestone shape | **M8 "Solid" bundle** (USER): size + completeness + production-safe verification in one milestone; arm64 (M7c) comes after, on the lean base | A lean, complete amd64 artifact is the precondition for both the visibility flip and a sane arm64 port |
| Size approach | **Proof-gated full pass** (USER): all safe trims + the tensorflow-cpu→tflite-runtime swap, gated on an import-graph proof; if the proof fails the swap is dropped and recorded | No hard size target (rejected); no Frigate patching (standing ruling); likely outcome 600–850 MB from 1.14 GB |
| Riders | **R4 semantic-search fix + upstream #4 repro/report** (USER) | "Solid" includes the silently-missing feature; #4 is a cheap parallel community contribution |
| Exit bar | **Gate + field-soak** (USER): VM gate green AND 3–7 day production soak on the Store-tracked lean revision | M7 proved field usage catches what gates cannot (R2/R3, go2rtc bridge, /logs) |
| Sequencing principle | **R4 lands before final size numbers** | The user's own M7 rule — size reduction happens "when everything that is planned is in"; R4 is the last content-bearing amd64 item, and its sqlite rebuild may *add* content |
| Standing rulings carried | No Frigate behavior patches (0001-env-paths only); loopback-only internal ports; secrets never in argv/committed files/evidence; render-once config ownership | M2–M7 rulings, unchanged |

## 3. Components

### Lane A — the artifact (size + completeness)

**A1. R4 semantic-search fix (first).** The staged sqlite is built without `enable_load_extension`, so Frigate's semantic search (sqlite-vec) is silently unavailable (`[TRANSCRIPT: m7-vm-verify-authed.txt R4]`). Rebuild the python/sqlite staging so extension loading works, stage what sqlite-vec needs, and verify the feature actually comes up (embeddings process starts, no extension-load error). This sets the true content baseline for the size pass. Constraint: the DB backup/restore machinery (M7 hardening) uses the same staged sqlite — its proofs re-run after the rebuild.

**A2. Proof-gated size pass.** Current artifact 1 140 936 704 B. Leads, in order of expected yield:
- **ffmpeg three-tree audit** (8.0 / 7.0 / 5.0 staged): determine which trees any runtime path actually invokes (Frigate ffmpeg presets, go2rtc, probes); unused trees are dropped from stage/prime. Evidence-driven — no tree leaves until the gate proves nothing calls it.
- **tensorflow-cpu → tflite-runtime (~250 MB lead):** allowed ONLY behind an import-graph proof that no Frigate runtime path imports full tensorflow (M2's module-level-import constraint is the known hazard). Proof passes → swap + full detector gate (ov AND coral money lines) on the lean artifact; proof fails → swap dropped, finding recorded, no patching.
- **OpenVINO wheel trim** (dev tools, samples, unused device plugins) and **prime pruning** (docs, locales, headers, static libs, `__pycache__` duplication) via `prime:` excludes — never post-prime mutation, so review-tools stays clean.
- **Size-floor tripwire retuned ONCE at the end** to the new honest floor (currently 943 718 400 B — it exists to catch a gutted prime, and every content change moves it).

**A3. svc-a/b/c removal.** The three M0 ordering-spike daemons leave the shipped snap (R5: README documents four services, the snap ships seven). Spike sources may stay in the repo; the `apps:` entries and their staged payload go. Harness ordering assertions that referenced them are retired or re-pointed at the real daemon chain.

### Lane B — the harness (production-host safety)

**B1. NVR-safe gate mode.** A non-purging harness variant for production hosts — the structural answer to M7's no-fresh-gate deviation. Properties: read-only/additive assertions only (service states, ports, TLS, API health, detector inference, log/journal sweeps, config checksum); **never** `snap remove`, never config regeneration, never DB manipulation; proves its own harmlessness (config.yml/DB checksums identical before/after). This mode is the soak's measurement instrument and every future milestone's on-host verifier.

**B2. `mv -n` trap guard.** The deferred PR #3 Minor (double-abort + manual-reinstall edge in the harness stash logic).

### Lane C — docs & upstream

**C1. `/logs` full tee-parity.** Real `frigate/current` and `go2rtc/current` content in `/dev/shm/logs` (today: placeholders; nginx already symlinked). Exact mechanism is a plan-time decision (bash process substitution vs. a tee helper); the M7 constraint stands as the acceptance bar: **crash-exit propagation for `on-failure` services must survive** — a supervised child dying non-zero must still cause the service exit that snapd's restart logic sees.

**C2. detect-fps README guidance.** Field lesson (cam2 detecting at 24 fps): document `detect: fps: 5` and the detect=substream / record=mainstream role pattern.

**C3. Upstream #4 repro + report.** Docker-repro the RecordingMaintainer hot-add `KeyError` on upstream Frigate v0.17.2 (UI-wizard camera add → `self.config.cameras[camera]` KeyError every ~17 s until restart). Confirms upstream-vs-packaging; produces a draft issue (repro steps, version, traceback) the user files. No artifact change.

## 4. Verification

Harness additions above the denial marker; ALL M0–M7 assertions preserved (retuned where content legitimately moved: size floor, app count, svc ordering).

1. **R4:** with semantic search enabled in a test config, the embeddings path starts and sqlite-vec loads (no `enable_load_extension` error); staged python proves `conn.enable_load_extension(True)` works. Backup/restore proofs re-run green after the sqlite rebuild.
2. **Size:** final lean artifact size recorded in findings with a per-lead breakdown (what each trim saved); size-floor tripwire retuned; artifact still `review-tools.snap-review` pass, zero warnings.
3. **tflite swap (if proof passes):** import-graph proof documented in findings; ov AND coral money lines green on the lean artifact. (If proof fails: the recorded finding is itself the deliverable.)
4. **svc trim:** shipped snap exposes exactly the four real services + diagnostic apps; no svc-a/b/c payload in prime; README/app-list parity assertion.
5. **NVR-safe gate:** runs green on the production host; before/after checksums of config.yml and the DB prove zero mutation; zero service restarts caused by the gate itself.
6. **`/logs` tee-parity:** UI `/logs` shows live frigate and go2rtc content; forced non-zero child exit still triggers the service restart policy (crash-propagation proof).
7. **Upstream #4:** reproduced on upstream Docker v0.17.2 (or ruled packaging-ours, also a valid outcome); issue draft committed under `docs/upstream/`.
8. **Denial policy:** 0 unexpected denials; any new arms narrow + journal-quoted (standing).
9. **VM money re-run:** clean LXD VM installs the lean revision from `latest/edge` (authed while private), README-only path → authed UI over TLS, detector alive, no crash-loop — all historical money lines green on the lean artifact.
10. **Field-soak (the exit):** production NVR migrated to Store-tracked (`--amend`), 3–7 days on the lean revision; NVR-safe gate + journald sweep at window end: zero crash-loops, zero unexpected errors, detections flowing on both cameras. Soak result recorded in findings; passing it is what closes M8.

## 5. Out of scope (M8)

arm64 (M7c — next, on the lean base); per-version Store tracks; NPU userspace; visibility flip + declaration submissions (user actions, unlocked by M8's exit but outside it); ACME/auto-renewal; MQTT/HomeAssistant docs; config migration tooling.

## 6. Risks

1. **tflite proof fails** — acceptable by design: swap dropped, finding recorded; the safe trims still land. The milestone does not depend on the 250 MB.
2. **sqlite rebuild side effects** — backup/restore and Frigate's own DB path share the staged sqlite; mitigated by re-running the M7 backup/restore proofs and the full gate.
3. **Size trims break a runtime path the gate misses** — mitigated by the ffmpeg audit being evidence-driven (invocation tracing before removal), the VM money re-run, and ultimately the soak.
4. **Soak surfaces new field defects** — that is the point; they become fix-PRs (the M7 R2/R3 pattern) and the soak clock restarts on the fixed revision.
5. **Production migration (`--amend`) risk** — it is a refresh, not a reinstall (SNAP_COMMON/DB preserved), but the config-stash discipline and a pre-migration manual backup are documented in the plan before the user runs it.
6. **`/logs` tee mechanism regresses crash propagation** — the acceptance bar (verification #6) makes this unshippable rather than latent.
