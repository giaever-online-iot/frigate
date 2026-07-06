# M4 Task 5 Report — findings document + patches.md nits

**Status: DONE** — commit pending on `m4-nginx-webui` (HEAD was 6bd536d at task start).
Files touched: `docs/m4-findings.md` (new), `docs/patches.md` (two nits).

---

## Files written

### docs/m4-findings.md (new)

Verdict table (6 rows), 9 story sections, denial arms table (2 new arms), deviations table
(8 rows), M5 unlock notes (3 bullets), raw evidence index (11 files).

Sourcing per section:

| Section | Source |
|---|---|
| M4-1 nginx verdict | task-1-report.md (nginx -V, sha256 table, GCC-15 verbatim, fix rounds); m4-final-run.txt |
| M4-2 web-ui verdict | task-3-report.md (build deviation, dist verify); m4-final-run.txt PASS + finding lines |
| M4-3 API / auth verdict | m4-final-run.txt nginx finding lines (verbatim: `/api/version=0.17.2-3d4dd3a`, `/auth status=202`) |
| M4-4 vod verdict | task-4-report.md (manifest shape verbatim, chain documented); m4-final-run.txt; spike/results/vod-manifest.txt |
| M4-5 go2rtc verdict | task-4-report.md (proxy path selection); m4-final-run.txt go2rtc proxy finding |
| M4-6 gate verdict | spike/results/m4-final-run.txt (`SPIKE SMOKE: ALL PASS`, 366 total 0 unexpected) |
| GCC-15 story | task-1-report.md (error verbatim, fix rounds, tarball sha256); spike/patches/nginx/0003-… |
| ENXIO story | m4-final-run.txt FINDING line verbatim |
| `user root;` story | task-4-report.md (setgid/setuid denial context); adjudicated ground truth |
| STALE-CACHE WEDGE story | task-4-report.md (KeyError journal line verbatim, fix, counterfactual, layout-token side effect) |
| STASH INCIDENT story | task-4-report.md §Fix round (wedge + stash) |
| UPSTREAM BUG story | task-4-report.md §Two live-system bugs found |
| e2e:build story | task-3-report.md §Build Script Findings (package.json scripts block verbatim) |
| Upstream limitation | docs/m3-findings.md §Decisions (upstream ffmpeg argv behaviour) |
| Denial arms | task-3-report.md (setgid pre-existing); task-4-report.md (setuid journal verbatim); m4-final-run.txt finding lines |
| Deviations | task-3-report.md §Deviations; task-4-report.md §Refinement + §Fix round; m4-final-run.txt finding line |
| M5 unlock notes | m0-findings.md §A2 (letsencrypt layout); m4-final-run.txt nginx finding |
| Raw evidence index | spike/results/ directory enumeration; brief ground truth |

### Self-review

- No placeholder cells in the verdict table.
- All claims verified against the cited evidence files and task reports before writing.
- Denial arm journal lines quoted verbatim from task-4-report.md.
- Denial count (366) matches m4-final-run.txt `== denials: 366 total, 0 unexpected ==`.
- SKIP count (3) and wording matches m4-final-run.txt verbatim.
- Gate transcript quote (`SPIKE SMOKE: ALL PASS`) matches m4-final-run.txt last line.
- Prior findings docs (m0–m3) not touched; harness not touched; code not touched.

---

## docs/patches.md changes

**(a) Intro reworded** to draw the boundary between 0001/0002 (upstream-recipe patches) and
0003 (snap portability patch not in upstream recipe). Before: "they are carried verbatim from
Frigate's own Docker build recipe" applied to all three patches. After: sentence explicitly
scopes the recipe claim to 0001 and 0002; 0003 is called out separately.

**(b) Erratum documented** for the 0003 patch header comment: the header says
"implicit-function-declaration warning" but the correct diagnostic is
`-Wincompatible-pointer-types`. Erratum documented in `docs/patches.md` (new "Erratum" note
appended after the rebase block); patch file not touched (header lines are ignored by
`patch`; docs-only constraint honoured).

---

## Concerns

None blocking.

One observation: task-5-report.md previously contained the M3 Task 5 (money-test harness)
report. That content is preserved in git history and its canonical record lives in
docs/m3-findings.md (closed record). This file is the M4 Task 5 findings-wrap report per
controller directive.
