# W-24 Design Spec — CI remote build: rebuild instead of recover when the artifact download breaks

**Date:** 2026-11-15
**Status:** Draft for review (the maintainer's decision D1 is binding; D2–D11 are the design)
**Class:** bounded. Only `.github/**` and its tests change; no `snap/**` change.
**Branch:** `fix/remote-build-fetch-recover` (PR #10), on top of `ae00129`
**Evidence base:** snapcraft 9.2.1 source as installed (`/snap/snapcraft/current/lib/python3.12/site-packages/`, cited below as `ca/` for `craft_application/` and `sc/` for `snapcraft/`), the CI logs of runs 43754974815 (PR #10), 43520710606 (PR #9) and 43377971262 (a single-arch run), and an offline probe that ran snapcraft's own `get_build_id` and `GitRepo` (§3.7).

## 1. Problem

`.github/scripts/remote-build.sh` builds every arch on Launchpad and downloads the snaps. When a download breaks, it drops the truncated file and retries with `snapcraft remote-build --recover`, which is meant to download again without rebuilding. **`--recover` cannot work in this setup.** Both two-arch CI runs so far lost an arch this way:

| Run | Launchpad | Download | Retries | Result |
|---|---|---|---|---|
| PR #9, 43520710606 (head 9a2e833) | both archs `Succeeded` at 02:46:59Z | arm64 cut: `IncompleteRead(763316 bytes read, 915982924 more expected)` | `--recover` looked up a different id (`4dd85c1b…`; attempt 1 had pushed `4c2583f0…`) → `Could not find repository` | amd64 uploaded; the gate passed (`REQUIRED_ARCHS=amd64`); arm64 lost |
| PR #10, 43754974815 (head ae00129) | both archs `Succeeded` at 20:22:04Z | amd64 cut: `IncompleteRead(578594 bytes read, 1109240798 more expected)` | `--recover` looked up the **same** id `de46977b…` → still `Could not find repository` | arm64 uploaded (Store rev 10, `latest/edge/PR10` only); `Fail if build/upload incomplete` red; amd64 lost |

bea5564 (PR #10's first commit) parked fetched files outside the tree so that `--recover` would compute the same id. On PR #10 it did compute the same id, and recovery still failed. The CI log shows why. Attempt 1 pushed to `…/~<owner>/<project>/+git/snapcraft-frigate-de46977b…` (log line 573). The recovery looked up `~<owner>/+git/snapcraft-frigate-de46977b…` (line 640): the same id without the project segment. The source shows the same thing (§3.4). bea5564's message ("the build stays recoverable") and the PR #10 body are wrong on this point (§8).

The maintainer's answer to "What should PR #10 do?" was option 1: start a fresh full remote build when a fetch fails, up to 3 times.

## 2. Goal

When Launchpad built an arch but its artifact did not arrive whole, start a NEW remote build for that arch. Never use `--recover`. Use at most 3 attempts in total, and finish inside GitHub's 6 h job limit so that the upload step and the completeness gate still run.

## 3. snapcraft 9.2.1 facts (read in the installed source; §3.7 also ran part of it)

### 3.1 Build id (brief question a)
`ca/remote/utils.py:49-63` `get_build_id` = `snapcraft-<project name>-<_compute_hash(project_dir)>`. `_compute_hash` (`:66-102`) takes `directory.glob("**/*")`, keeps the regular files and sorts them by path (`:90`). It computes an md5 of each file's **contents** (`:93-99`), then an md5 of the concatenated hex digests (`:101-102`). Consequences:
- **Everything** under the project dir counts, `.git/` included (pathlib's glob does not skip dot-dirs; proven in §3.7).
- **File names do not count, only contents.** Two empty marker files with different names give the same id (§3.7). Any per-attempt marker must therefore differ in *content*.
- The id is computed afresh on every invocation (`ca/commands/remote.py:154`), for a new build and for `--recover` alike.

### 3.2 A new build whose id already exists on Launchpad (question a)
`start_builds` (`ca/services/remotebuild.py:117-153`) → `_ensure_repository` (`:284-316`): `lp.new_repository(name, project=…)` and, **on `HTTPError`, `lp.get_repository(name, project=…)`** (`:294-299`), i.e. it reuses the repository. It then force-pushes (`ca/git/_git_repo.py:467`, `"--force"`, commented "in case this repository already exists"). `_ensure_recipe` (`:341-352`) **deletes an existing recipe of that name and creates a new one**. So a repeated id is not an error by design: the repository is reused and the recipe is replaced. That fallback path has **never run in our CI**: every attempt 1 so far hit a fresh id. Whether Launchpad answers a duplicate name with an `HTTPError` was not checked (it would need Launchpad).

### 3.3 Untracked and uncommitted files (question a)
The only repository checks are "is a git repo" and "is not shallow" (`ca/remote/git.py:24-43`). `WorkTree.init_repo` copies the whole project dir, untracked files included (`ca/remote/worktree.py:54`). If `git status` is not clean it runs `add_all` and commits (`:62-64`), and that auto-commit is pushed. Ignored files do not make the copy unclean. In §3.7, a fetched `frigate_0.18.2_arm64.snap` (ignored by `/frigate_*.snap` in `.gitignore`) left `is_clean()` True, while a non-ignored file made it False. So snapcraft does not object to untracked files. It **pushes** untracked files that are not ignored, and it hashes all files, ignored ones included. PR #9's and PR #10's attempts raised no git error.

### 3.4 `--recover` (why it is dead here)
`resume_builds` (`ca/services/remotebuild.py:155-163`) → `_get_repository` (`:337-339`) = `lp.get_repository(name=…, owner=lp.username)` with **no project**. The path then becomes `~<owner>/+git/<id>` (`ca/launchpad/launchpad.py:220-228`). `_ensure_repository` creates the repository **under** the project `<owner>-craft-remote-build` (`:270-282`, `:295`), at `~<owner>/<project>/+git/<id>`. Recovery therefore cannot find a repository that snapcraft itself created. PR #10's log shows both paths for the same id (§1).

### 3.5 `--build-for` takes a subset (question a)
`sc/commands/remote.py:73-82` parses a comma list. When the project has `platforms:` (ours: amd64, arm64), `--build-for` **filters** the build plan (`:149-162`, "the project has platforms, then `--build-for` acts as a filter"). `--build-for=amd64` builds amd64 only. `fetch_artifacts` downloads only the artifacts of the builds this invocation started (`ca/services/remotebuild.py:210-223`, `:418-424`).

### 3.6 Cleanup, fetch and timeouts (question a)
- `cleanup()` (delete the recipe and the repository, `ca/services/remotebuild.py:241-246`) runs only after a normal return (`ca/commands/remote.py:181`) or a confirmed Ctrl-C (`:171`). A broken download raises out of `_monitor_and_complete` (`:224`) as an internal error, so nothing is cleaned up. The repository and recipe of every failed attempt stay on Launchpad. That is true today and was true before bea5564.
- Artifacts and build logs are written to the **current directory**, i.e. the project dir (`:224`, `:227`). Logs are fetched only after every artifact arrived, so an attempt with a cut download writes no log files.
- Downloads run one file at a time, in set order (`ca/services/request.py:79-113`). A cut on one file leaves the files already finished intact (PR #10: arm64 arrived whole) and the files not yet started missing.
- The fetch starts only once **every** build has stopped. The state line printed just before it is `Succeeded: amd64, arm64`, or for example `Stopped: amd64; Succeeded: arm64` (`ca/commands/remote.py:200-221`; order Stopped, Building, Uploading, Succeeded, Pending).
- `--launchpad-timeout=<s>` (default 0 = none, `:81-86`) sets a local deadline (`:150-152`). When it passes, snapcraft prints `Timed out waiting for build`, returns 75 without fetching anything (`:173-178`), and the Launchpad builds continue.

### 3.7 Offline probe (run, not just read)
Run with snapcraft's own bundled Python (`/snap/snapcraft/current/bin/python3 -I`) against a throwaway git repo. No network.

```
base            snapcraft-frigate-a799b822b14c3e20fdc728e117de1643
marker=2        snapcraft-frigate-b1beb4d9c92a6ac01d8fcc13556c83a1   (.git/remote-build-attempt = "2")
marker=3        snapcraft-frigate-271f18b3bc197b0e1122d517bf72183e   (= "3")
marker removed  snapcraft-frigate-a799b822b14c3e20fdc728e117de1643   (back to base)
empty x == empty y: True                                              (names do not count)
ignored snap -> is_clean: True
plus log file -> is_clean: False
```

## 4. Decisions

**D1 (the maintainer's, option 1). When the download leaves an arch without a valid snap, start a NEW remote build for it. Never use `--recover`. At most `MAX_ATTEMPTS` (default 3) attempts in total.**
Reason: recovery cannot find snapcraft's own project-housed repository (§3.4, PR #10's log), so it is dead code. A new build takes the code path that every CI run's attempt 1 already takes.

**D2 (confirms the controller's proposal). A retry builds only the archs still missing (`--build-for=<missing>`). The valid snaps already fetched stay in the project dir.**
Reason: `--build-for` is a filter on the platforms (§3.5) and the fetch covers only the builds this invocation started, so a subset works. Nothing in snapcraft makes a subset worse (the recipe is created per invocation with the subset's archs, `ca/services/remotebuild.py:144-149`). Rebuilding an arch whose file is already good costs Launchpad time and adds one more large download that could be cut. Two of two two-arch runs so far had one cut download.

**D3 (keeps the controller's goal, changes its mechanism). Every attempt gets a build id of its own. Attempts 2 and later write their attempt number into `.git/remote-build-attempt` before calling snapcraft. The file is removed at exit (and any stale copy at start).**
Reasons:
- Without a change the id can repeat. With nothing valid fetched (a single-arch run, or every file cut) the tree is unchanged, so the id equals attempt 1's (§3.1).
- A repeated id is legal in snapcraft (§3.2), but it would take the reuse fallback, which our CI has never exercised. A fresh id keeps every attempt on the new-repository path that every attempt 1 has proven.
- `.git/` is hashed (§3.1, §3.7) but never committed, so the source snapcraft pushes stays the PR's commit. A marker in the tree would be untracked, not ignored, and auto-committed into the pushed source (§3.3). Ignoring it would need a `.gitignore` change outside `.github/**`.
- The content, not the name, must vary (§3.1), hence the attempt number as content.
- Cost accepted: each failed attempt leaves its repository and recipe on Launchpad (§3.6). That already happens today for every failed attempt. Clearing them is out of scope (recorded as a follow-up).
- If `.git` is not a directory (a linked worktree; never the case for `actions/checkout`), the script prints a `::warning::` and the id may repeat (the §3.2 fallback).

**D4 (answers the controller's D4). Remove bea5564's parking (`PARK`, `tree_files`, `park_fetched`, `restore_parked`, the park-aware `valid_count`) and its two tests (`lastbreak`, the `parked …` checks).**
Reasons:
- Parking existed only so that `--recover` would see attempt 1's id, and `--recover` is gone (D1).
- D3 gives every attempt its own id whatever is in the tree, so parking is not needed for the id either.
- A valid snap left in the tree does not enter the pushed source: `/frigate_*.snap` is ignored (§3.3, §3.7). snapcraft does copy it into its local cache (`worktree.py:54`), a local copy of about 1 GB, which is acceptable.
- Removing the parking also removes its `::warning::` about a changed tree, which only mattered for `--recover`.

**D5 (new). Rebuild only archs that Launchpad reported as `Succeeded` in the attempt just finished and that have no valid snap.** The script tees snapcraft's output and reads the last `Succeeded: …` state line (§3.6). An arch that failed to build, or that never reached `Succeeded` before a timeout, is not rebuilt. It stays missing and the completeness gate decides, as today.
Reasons:
- The maintainer's option is about broken downloads.
- A genuine build failure is likely to repeat. Run 43377971262 shows an attempt that ran 3 h 36 min and never reached `Succeeded`, so rebuilding there would burn the 6 h job limit.
- If GitHub kills the job at 6 h, the upload step and the gate never run, and even the valid arch is lost. Today's outcome (upload what is valid, gate red) is better than that.
- This keeps the script's existing promise: "a genuine single-arch BUILD failure stays tolerated".

**D6 (new). A time budget, `BUILD_BUDGET` (default 18000 s = 5 h) for all attempts together.**
- Every attempt passes `--launchpad-timeout=<budget left>`.
- A retry starts only if `time used + RETRY_DELAY + the last attempt's duration ≤ BUILD_BUDGET`.
Reasons:
- "Three attempts at about 25 min" holds for PR #10's run, not for PR #9's (§6). Two PR #9-length attempts would exceed 6 h.
- The previous attempt's duration is a conservative estimate: a retry builds a subset, and the archs build in parallel, so a retry should take no longer.
- 5 h leaves 60 min for the steps before and after this one. The most observed is 18 min (§6).
- `--launchpad-timeout` caps an attempt that runs longer than estimated. On timeout snapcraft exits 75 and fetches nothing (§3.6). The script then stops, because the time is used up.
- Attempt 1 gets the timeout too. That only matters past 5 h, where the job used to be killed at 6 h before uploading anything.

**D7 (the controller's D5). The channel-close fix in ae00129 stays unchanged.** That covers dropping `--yes`, the fallback printing the real exit status as a `::warning::`, and `snapcraft-close.test.sh`. Neither W-24 task touches `release-on-merge.yml` or `snapcraft-close.test.sh`.

**D8 (the controller's D6). Exit 0 always; `prune_corrupt` stays; the completeness gate downstream decides.** A truncated file never reaches `snapcraft upload`. One small change: `snaps=` now counts the **requested archs that have a valid snap** (`*_<arch>.snap`, as the upload step matches). Before, it counted distinct `*.snap` files. The two agree whenever only requested archs are fetched, which is always the case with `--build-for`.

**D9. Stop retrying, with a `::warning::` that names the reason, when:** every requested arch has a valid snap (success, no warning); or `MAX_ATTEMPTS` is reached; or no missing arch was `Succeeded` (D5); or the budget does not fit (D6). The script never loops on anything except its own attempt counter.

**D10. The test stub models snapcraft 9.2.1 as read and probed.** It reproduces `_compute_hash` with the same algorithm: md5 of each file's contents, sorted paths, `.git` included, then md5 of the concatenated hex. Its `--recover` fails with the text from PR #10's log. It prints the state lines and the `IncompleteRead` error as snapcraft does. A stub `date +%s` and a fake clock (each snapcraft call advances it by `STUB_COST`) make the time budget testable without sleeping. Known limit: the stub sorts paths with `LC_ALL=C sort -z`, where Python sorts `PosixPath` parts. The orders can differ for unusual names, which does not matter for the "same tree ⇔ same id" property the tests use.

**D11. History is corrected forward, not rewritten.** bea5564 and ae00129 are already on `origin/fix/remote-build-fetch-recover`: PR #10's CI ran on ae00129. The W-24 card's remark that nothing is pushed yet is therefore not right, and amending bea5564 would rewrite pushed history. The implementation commit's message states what bea5564 got wrong. The PR #10 body is replaced (§8).

## 5. Behaviour after the change

```
attempt 1: snapcraft remote-build --build-for=<all> --launchpad-timeout=<budget>   (no marker; id as today)
           prune truncated files; count requested archs with a valid snap
           all present            -> done
           attempt == MAX         -> ::warning:: still missing ... ; done
           rebuild = missing ∩ last "Succeeded:" set
           rebuild empty          -> ::warning:: not rebuilding <missing>: Launchpad did not report it Succeeded ... ; done
           used+delay+took > budget -> ::warning:: not rebuilding <rebuild>: attempt N took Ns ... ; done
attempt N: echo N > .git/remote-build-attempt; snapcraft remote-build --build-for=<rebuild> --launchpad-timeout=<left>
...
end:       remove marker and output copy; list snaps; snaps=<count> (stdout and GITHUB_OUTPUT); exit 0
```

The workflow comment above the build step in `.github/workflows/pr-build-snap.yml` (which promises "re-fetches via --recover (no rebuild)" and "retry/timeout behaviour … carried over UNCHANGED") is rewritten to match. The step's name and `id: build` stay.

## 6. Timing (brief question e)

From the run metadata (`gh run view <id> --json jobs`) and the step log timestamps:

| Run | Job | Build step, attempt 1 | Launchpad | After the build step |
|---|---|---|---|---|
| PR #10, 43754974815 | 19:53:59 → 20:37:01 = **43 min 02 s** | 19:54:14 → 20:23:00 = **28 min 46 s (1726 s)** | Pending 19:56:44 → both Succeeded 20:22:04 = 25 min 20 s | 20:23:38 → 20:37:01 = 13 min 23 s |
| PR #9, 43520710606 | 22:36:54 → 03:06:04 = **4 h 29 min 10 s** | 22:37:18 → 02:47:40 = **4 h 10 min 22 s (15022 s)** | Building 22:40:15; both in Launchpad's `Uploading` state from 23:02:49 to about 02:45; both Succeeded 02:46:59 | 02:48:21 → 03:06:04 = 17 min 43 s |
| 43377971262 (amd64 only) | — | 12:21:45 → 15:57:35 = 3 h 35 min 50 s | amd64 `Uploading` from 12:55:30 until snapcraft printed `Timed out waiting for build` (no `--launchpad-timeout` was set; cause not determined) | — |

PR #9's long time was not compilation: the builds finished in about 22 min, and the archs then sat in **Launchpad's own "Uploading" state for about 3 h 44 min**. The "about 4.5 h of Launchpad" in the PR #10 body is PR #9's whole job, not PR #10's.

Arithmetic, 6 h = 21600 s:
- **PR #10 speed, 3 full attempts:** 15 s before + 3 × 1726 s + 2 × 15 s delay + 803 s after = **6026 s ≈ 1 h 40 min**. This fits easily, and retries build only the missing arch.
- **PR #9 speed, 3 full attempts:** 3 × 15022 s = 45066 s ≈ **12 h 31 min. It does not fit.** Even 2 attempts (30044 s ≈ 8 h 21 min) would not. Hence D6.
- **With D6 at PR #9 speed:** after attempt 1, 15022 + 15 + 15022 = 30059 > 18000, so there is no rebuild. The job is then about 24 s + 15022 s + 1063 s ≈ 4 h 29 min, as PR #9 was.
- **Worst case with D6:** the build step is bounded by about 18000 s plus the last push and fetch (minutes), and the job by about 5 h 25 min. That is under 6 h with the observed 18 min after the step.

## 7. What the test must prove

`.github/scripts/remote-build.test.sh`, stub-driven, no network:

| Case | Must hold |
|---|---|
| `cut`, amd64+arm64, STUB_COST=1726, BUILD_BUDGET=18000 (PR #10's case) | snaps=2; exactly 2 snapcraft calls; no `--recover`; call 2 `--build-for=amd64`; call 2's id ≠ call 1's; both files on disk, none corrupt; `--launchpad-timeout` 18000 then 16274; marker and output copy removed |
| `cut`, amd64 only (nothing valid fetched) | snaps=1; 2 calls; call 2's id ≠ call 1's (only the marker can do that) |
| `alwayscut`, amd64+arm64 | exactly 3 calls (bounded); snaps=1; exit 0; 3 distinct ids; calls 2 and 3 build amd64 only; only the valid arm64 on disk |
| `buildfail`, amd64+arm64+armhf (amd64 `Stopped`) | 1 call; snaps=2; exit 0; `::warning::not rebuilding amd64: Launchpad did not report it Succeeded` |
| `cut`, STUB_COST=15022 (PR #9's attempt length) | 1 call; snaps=1; `::warning::not rebuilding amd64: attempt 1 took 15022s` |
| GITHUB_OUTPUT | receives `snaps=2` |

The suite must be **red on the current script** (ae00129) and green after. Each mutation below, applied to the new script, must turn it red (checked by a mutation runner in the plan):

| Mutation | Killed by |
|---|---|
| M1 re-add `--recover` on retries | `cut`: snaps, `--recover` and calls checks |
| M2 drop the marker (same id) | the single-arch and `alwayscut` distinct-id checks |
| M3 rebuild all archs on retry | the `--build-for` checks |
| M4 drop `prune_corrupt` | the snaps, corrupt and call-count checks |
| M5 unbounded attempts | `alwayscut`: exactly 3 calls (the stub stops a runaway after 10 calls; `timeout 120` stops a hang) |
| M6 rebuild arches that failed to build | `buildfail`: 1 call and the warning |
| M7 drop the budget guard | the budget case: 1 call and the warning |
| M8 drop `--launchpad-timeout` | the `cut` timeout checks |

Also: every `.github/scripts/*.test.sh` and both shellcheck steps of `lint-test.yml` pass. The baseline is green on ae00129 (checked 2026-11-15: all six suites passed, shellcheck 0.9.0 clean).

## 8. Records to correct

- **bea5564's message** says "snapcraft does not run cleanup() and the build stays recoverable". The first half is right (§3.6); the conclusion is wrong (§3.4). PR #10's run computed the same id and still could not find the repository. This is corrected by the implementation commit's message (D11).
- **PR #10's body**:
  - Section 1 describes parking, which this change removes.
  - "The premise … recomputed on `--recover`" was checked, but `--recover` cannot work for a second reason (§3.4).
  - "(about 4.5 h of Launchpad, both arches)" is PR #9's job time. It is replaced by the measured numbers (§6).
  - The plan carries the replacement body. The controller edits the PR.
- **The workflow comment** (§5).

## 9. What stays unchanged

ae00129's channel-close fix and `snapcraft-close.test.sh` (D7); `prune_corrupt` and `snap_ok` (D8); exit 0 and the `snaps=` output contract (D8); `MAX_ATTEMPTS=3` and `RETRY_DELAY=15` defaults; attempt 1's command line except the added `--launchpad-timeout`; the workflow's upload step, the snapcraft-log dump step and the `Fail if build/upload incomplete` gate; `.github/release-archs.env`; everything under `snap/**`.

## 10. NOT PROVEN (and what would prove it)

- **The real rebuild against Launchpad.** It runs only when a download is cut. The one push of this branch starts a two-arch build, so PR #10's own CI run is the first real test. If no download is cut there, the rebuild path stays unproven. Report it faithfully either way.
- **A rebuild is not guaranteed to avoid another cut download.** It is a bet that the cut is transient. Both two-arch runs so far had one large-file download cut, and neither had both cut. If all attempts end incomplete, the pipeline does what it does today: upload the valid snaps to `latest/edge/PR<N>`, then `Fail if build/upload incomplete` goes red when a required arch (`REQUIRED_ARCHS=amd64`) is missing. That is kept.
- **The same-id reuse path (§3.2) is not exercised.** D3 avoids depending on it, except when `.git` is not a directory.
- **`--launchpad-timeout` was read in the source, not run.** Its behaviour on Launchpad (exit 75, builds continue) is unproven.
- **The `Succeeded:` line format** was read in the source (`ca/commands/remote.py:218`) and seen in three 9.2.1 CI logs. A future snapcraft could change it. The failure mode is safe: D5 then rebuilds nothing, which is today's outcome.
- **Why Launchpad's `Uploading` state took about 3 h 44 min on PR #9** (and why 43377971262 ended with `Timed out waiting for build` without a timeout set) was not determined. A plausible explanation for the latter is a socket timeout, since Python's `socket.timeout` is `TimeoutError` and is caught at `:173`. That is not proven.
- **Launchpad clean-up of the per-attempt repositories and recipes** (D3 cost) is not addressed.
