# W-24 Design Spec — CI remote build: rebuild instead of recover when the artifact download breaks

**Date:** 2026-11-15
**Status:** Amendment 1 for review. The maintainer approved this spec at `5c526e3`; Amendment 1 (below) needs approval again. D1 and Amendment 1's rule are the maintainer's decisions; the rest is the design.
**Class:** bounded. Only `.github/**` and its tests change; no `snap/**` change.
**Branch:** `fix/remote-build-fetch-recover` (PR #10), on top of `ae00129`; built as `e089f48`; Amendment 1 goes on top of `e089f48`
**Evidence base:** snapcraft 9.2.1 source as installed (`/snap/snapcraft/current/lib/python3.12/site-packages/`, cited below as `ca/` for `craft_application/` and `sc/` for `snapcraft/`), the CI logs of runs 43754974815 and 43838113093 (PR #10), 43520710606 (PR #9) and 43377971262 (a single-arch run), and an offline probe that ran snapcraft's own `get_build_id` and `GitRepo` (§3.7).

## Amendment 1 (2026-11-16): an exit 75 before the deadline is retried

- **What happened.** PR #10's first CI run of the built script (`e089f48`, run 43838113093) ended with `snaps=0`. snapcraft printed `Timed out waiting for build.` and exited 75 869 s into attempt 1, although it had been given `--launchpad-timeout=18000`. Both archs were still `Building`, and nothing was fetched. The script read the 75 as the deadline. No arch was `Succeeded`, so D5 rebuilt nothing, and the completeness gate went red (§3.8).
- **Why.** snapcraft returns 75 for *any* `TimeoutError` while it monitors the build, not only for its own deadline (§3.8). That run's deadline was still more than 4 h away.
- **The maintainer's decision** (W-24 Q1, answered 2026-11-16, option 1, "Fix it in W-24: retry on an early timeout"): when snapcraft exits 75 long before the budget is used up, start a NEW build of the requested archs, inside the same `MAX_ATTEMPTS` and `BUILD_BUDGET`. A real deadline stays final.
- **What changes:**
  - D5: after an exit 75, the retry builds every missing arch except one that the last state line reported `Stopped`. The `Stopped` exception is the design's addition to the maintainer's rule. Other exit codes keep D5 as it was.
  - D6: no new threshold. The existing budget check already refuses any retry after a real deadline (the proof is in D6).
  - New D12: every exit 75 prints a `::warning::` with the attempt's duration against its timeout.
  - D9, D10, §3.6, §5, §6, §7 (new cases, mutants M17–M21) and §10 are updated to match. §3.8 holds the evidence.
  - D13 writes down a broader, state-based rule as an option. It is **not** chosen.
- **What stays:** D1–D4, D5a, D7, D8, D11, the defaults, and everything already built in `e089f48` except the lines this amendment changes.

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

### Beyond the maintainer's option 1

The maintainer chose "start a fresh full remote build when a fetch fails, up to 3 times". The design adds the following. Each needs the maintainer's explicit approval:

1. **D5:** an arch that Launchpad reported `Stopped` (a build failure) is never rebuilt. After any exit other than 75, an arch it did not report `Succeeded` is not rebuilt either. Only cut downloads are rebuilt, and since Amendment 1 also the missing archs after an exit 75 before the deadline.
2. **D6:** a 5 h budget for all attempts. Every attempt, **attempt 1 included**, passes `--launchpad-timeout=<budget left>`, and a retry starts only if the previous attempt's duration still fits.
3. **D6, the cutoff:** an attempt still running at the 5 h mark now stops there with nothing fetched. Before, it could still have finished and uploaded between about 5 h and 5 h 40 min.
4. **D8:** `snaps=` now counts the requested archs that have a valid snap, not distinct `.snap` files.
5. **D3:** attempts 2 and 3 write their number into `.git/remote-build-attempt`, so each gets a fresh Launchpad build id. Each failed attempt leaves its repository and recipe on Launchpad.

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
- **Every download is opened up front, then drained one file after another.** `download_files_with_progress` (`ca/services/request.py:79-113`) first calls `next(dl)` on every download (`:103`). Each such call has already done the GET with `stream=True` and opened the destination file for writing (`:68-70`). Only then are the files drained one after another, in set order (`:107-111`). So while the first ~1 GB file downloads, the connection for the second sits open and idle. A cut leaves the files already drained intact (PR #10: arm64 arrived whole). Files not yet drained exist as empty or partial files, and `prune_corrupt` already drops those.
- The fetch starts only once **every** build has stopped. The state line printed just before it is `Succeeded: amd64, arm64`, or for example `Stopped: amd64; Succeeded: arm64` (`ca/commands/remote.py:200-221`; order Stopped, Building, Uploading, Succeeded, Pending).
- `--launchpad-timeout=<s>` (default 0, `:81-86`) sets a local deadline only when the value is truthy (`:150` `if parsed_args.launchpad_timeout:`). **`0` therefore means no timeout at all.**
  - A **negative** value sets a deadline in the past. `start_builds` then raises `TimeoutError` from `_check_timeout` (`ca/services/remotebuild.py:150`, `:428-431`). That happens outside the `try` (`ca/commands/remote.py:162` vs `:164`), so it becomes an internal error, not exit 75.
  - When the deadline passes while monitoring, `monitor_builds` yields the states **once more** (`ca/services/remotebuild.py:183`) before raising (`:184`). A `Succeeded: …` line can therefore be printed with nothing fetched. snapcraft then prints `Timed out waiting for build` and returns 75 (`ca/commands/remote.py:173-178`), and the Launchpad builds continue.
  - The `except TimeoutError` at `:173` wraps the whole of `_monitor_and_complete`, status polls and fetch included. So **any** `TimeoutError` raised there exits 75 with the same message, not only the deadline's. §3.8 says where one can come from.

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

A second probe ran snapcraft's own `WorkTree(...).init_repo()`, the copy that is pushed, under a throwaway `XDG_CACHE_HOME`. The independent reviewer also ran it.

```
ignored snap + .git marker:     HEAD files=['.gitignore', 'snapcraft.yaml']  pushed commit == checkout commit: True
plus a non-ignored output file: HEAD files=['.gitignore', 'remote-build-out.abc', 'snapcraft.yaml']  pushed commit == checkout commit: False
```

### 3.8 Exit 75 before the deadline (Amendment 1)
From PR #10's run 43838113093 (head `e089f48`): the step log and snapcraft's own log, which the workflow dumps.

| Time (UTC) | Event |
|---|---|
| 09:16:03.8 | `remote-build attempt 1/3 (amd64,arm64; 18000s of budget left)` (the script's `t0`) |
| 09:17:30.5 | snapcraft: `Setting timeout to 18000 seconds`, 86.7 s after `t0`. The deadline is about 14:17:30. |
| 09:17:30.6 | `Starting new build` |
| 09:20:18.1 | `Pending: amd64, arm64` |
| 09:20:52.0 – 09:27:49.1 | `Building: amd64, arm64`, 12 lines, 31.4–48.9 s apart |
| 09:30:32.8 | `Timed out waiting for build.`, exit 75, 163.7 s after the last state line |
| 09:30:33.1 | the script: `valid snaps after attempt 1: 0/2`, `not rebuilding amd64,arm64: Launchpad did not report it Succeeded in attempt 1`, `snaps=0` |

Source facts:
- The deadline is set once: `set_timeout` = `monotonic_ns()` + the seconds (`ca/services/remotebuild.py:113-115`), called at `ca/commands/remote.py:150-152`. It is checked in only two places. One is the monitor loop's `while` (`remotebuild.py:176`); after it, `:183-184` yield once more and raise. The other is `_check_timeout`, before the builds are created (`:150`, `:428-431`). 782 s into an 18000 s deadline, neither can fire. **This exit 75 was not the deadline (proven from the source and the log).**
- `except TimeoutError` (`ca/commands/remote.py:173-178`) covers every status poll: `monitor_builds` → `_get_build_states` → `_refresh_builds` → `build.lp_refresh()` for each build (`remotebuild.py:409-416`), a Launchpad API call.
- The Launchpad client sets no socket timeout. `Launchpad.login` (`remotebuild.py:264-268`) passes none, and launchpadlib's default is `timeout=None`. So a `socket.timeout` from a slow read cannot occur. What remains is the kernel's `ETIMEDOUT`:
  - Python raises `OSError(ETIMEDOUT)` as `TimeoutError` (checked in snapcraft's own Python);
  - httplib2 re-raises socket errors unchanged (`httplib2/__init__.py:1192-1208` on connect, `:1399-1409` on a request).
- Artifact downloads use `requests` (`ca/services/request.py:43`), which wraps every `OSError` in its own `ConnectionError` (`requests/adapters.py:710-711`). A network timeout during the fetch is therefore an internal error, as the cut downloads were, not exit 75.
- **Hypothesis, NOT PROVEN:** a Launchpad API connect that got no answer.
  - With Linux's default `tcp_syn_retries=6`, a connect gives up with `ETIMEDOUT` after about 127 s. 30 s of poll sleep + about 127 s + the request fits the 163.7 s gap.
  - The log has no traceback, and the runner's `tcp_syn_retries` was not checked.
- An earlier run fits the same pattern: 43377971262 (§6) printed `Timed out waiting for build` after 3 h 36 min with no `--launchpad-timeout` set, so it had no deadline at all.

## 4. Decisions

**D1 (the maintainer's, option 1). When the download leaves an arch without a valid snap, start a NEW remote build for it. Never use `--recover`. At most `MAX_ATTEMPTS` (default 3) attempts in total.**
Reason: recovery cannot find snapcraft's own project-housed repository (§3.4, PR #10's log), so it is dead code. A new build takes the code path that every CI run's attempt 1 already takes.

**D2 (confirms the controller's proposal). A retry builds only the archs still missing (`--build-for=<missing>`). The valid snaps already fetched stay in the project dir.**
Reason: `--build-for` is a filter on the platforms (§3.5) and the fetch covers only the builds this invocation started, so a subset works. Nothing in snapcraft makes a subset worse (the recipe is created per invocation with the subset's archs, `ca/services/remotebuild.py:144-149`). Rebuilding an arch whose file is already good costs Launchpad time and adds one more large download that could be cut. Two of two two-arch runs so far had one cut download.
A further reason (hypothesis, not proven): a one-arch retry opens **one** connection, so the idle-second-connection mechanism of §3.6 cannot repeat on it (see §10).

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

**D5 (new; amended by Amendment 1). Which missing archs a retry builds depends on how the attempt ended.**
- **Any exit other than 75:** rebuild only archs that Launchpad reported as `Succeeded` in the attempt just finished and that have no valid snap. The script tees snapcraft's output and reads the last `Succeeded: …` state line (§3.6). An arch that failed to build is not rebuilt. It stays missing and the completeness gate decides, as before.
- **Exit 75 (Amendment 1):** rebuild every requested arch that has no valid snap, except one that the attempt's last `Stopped: …` state line reported. Whether the retry may start at all is D6's budget check, which never lets a real deadline through.

Reasons:
- The maintainer's option 1 is about broken downloads. Amendment 1 adds the maintainer's rule for an early exit 75.
- A genuine build failure is likely to repeat. Run 43377971262 shows an attempt that ran 3 h 36 min and never reached `Succeeded`, so rebuilding there would burn the 6 h job limit.
- If GitHub kills the job at 6 h, the upload step and the gate never run, and even the valid arch is lost. Today's outcome (upload what is valid, gate red) is better than that.
- This keeps the script's existing promise: "a genuine single-arch BUILD failure stays tolerated".
- After an exit 75 the last state line is stale. The monitor was interrupted (§3.8), and Launchpad goes on building, but the script cannot reach those builds again (`--recover` is dead, §3.4). An arch still `Pending`, `Building` or `Uploading`, or already `Succeeded` but not fetched, is therefore built anew.
  - Nothing is fetched in an attempt that ends with 75: snapcraft fetches only after every build has stopped, and a download timeout is not a 75 (§3.8).
  - A valid snap already on disk from an earlier attempt is kept (D2).
- `Stopped` is final on Launchpad. snapcraft prints it for every state that is not running, `Succeeded`, `Uploading` or `Pending` (`ca/commands/remote.py:199-213`). So the rule that a real build failure is not rebuilt holds after a 75 too. This exclusion is the design's addition to the maintainer's rule. Without it, a deterministic failure seen just before the timeout would cost another full build.
- Cost accepted: the builds of an attempt that ended with an early 75 keep running on Launchpad and are abandoned. That is about 25 min of Launchpad time each, and their repository and recipe stay (§3.6).

**D5a. snapcraft's output, which D5 parses, is captured outside the project dir.** Three rules:
- (i) The output file is created with `mktemp` under `TMPDIR` (`/tmp` on the runner), never in the project dir.
- (ii) stderr is captured with stdout (`2>&1`), because snapcraft prints its state lines on stderr.
- (iii) The file is truncated at each attempt (`tee` without `-a`), so D5 parses only the attempt just finished.

Reason: snapcraft copies the whole project dir (`worktree.py:54`) and auto-commits every file that is not ignored (`:62-64`). An output file in the tree would be pushed to a public Launchpad repository, and it would change the build id. The test's stub therefore fails when the project dir holds an untracked, non-ignored file at call time.

**D6 (new). A time budget, `BUILD_BUDGET` (default 18000 s = 5 h) for all attempts together.**
- Every attempt passes `--launchpad-timeout=<budget left>`.
- A retry starts only if `time used + RETRY_DELAY + the last attempt's duration ≤ BUILD_BUDGET`.
Reasons:
- "Three attempts at about 25 min" holds for PR #10's run, not for PR #9's (§6). Two PR #9-length attempts would exceed 6 h.
- The previous attempt's duration is a conservative estimate: a retry builds a subset, and the archs build in parallel, so a retry should take no longer.
- 5 h leaves 60 min for the steps before and after this one. The most observed is 18 min (§6).
- `--launchpad-timeout` caps an attempt that runs longer than estimated. At its deadline snapcraft exits 75 and fetches nothing (§3.6).
- **A real deadline is never retried, and no new threshold is needed (Amendment 1).** The proof:
  - Let `s` be the script's start, `t0` and `t1` the attempt's start and end, and `left = BUILD_BUDGET − (t0 − s)`.
  - snapcraft sets its deadline, `left` seconds ahead, at `Setting timeout`, which comes after `t0` (86.7 s after it in run 43838113093, §3.8).
  - A deadline exit therefore has `took = t1 − t0 ≥ left` and `used = t1 − s ≥ (t0 − s) + left = BUILD_BUDGET`.
  - The retry check `used + RETRY_DELAY + took ≤ BUILD_BUDGET` would then need `RETRY_DELAY + took ≤ 0`, which cannot hold, since `took ≥ left ≥ 1`.
  - snapcraft's late start, and its noticing the deadline up to one poll cycle late, only make `took` larger.
  - So the existing check alone separates the two cases. An early 75 is retried exactly when a retry of the same length still fits, and a real deadline never is.
  - The one gap: the script reads the wall clock (`date +%s`) and snapcraft a monotonic clock. A backward wall-clock step of more than `RETRY_DELAY + left` seconds during the attempt would let a retry through. That is not handled.
- An early 75 that took too long for another attempt of the same length is not retried either. It is the same check, with `::warning::not rebuilding … attempt N took Ns`.
- Attempt 1 gets the timeout too. **This is an accepted trade, stated honestly.** Between about 5 h and 5 h 40 min, the old script could still have finished an attempt and uploaded it. With the timeout on attempt 1, it now exits 75 at 5 h and fetches nothing. That is accepted because it keeps the upload step and the gate reachable inside 6 h. Past about 5 h 40 min the old script lost the upload anyway, because GitHub killed the job.
- **Invariant: no attempt starts with `left` < 1.** The script prints `::warning::not starting attempt <n>: the <budget>s budget is used up` and stops. `--launchpad-timeout=0` would mean no timeout, and a negative value is an internal error (§3.6). Clamping to 1 s was considered and dropped (plan review P3), because it would start a Launchpad build only to abandon it.
- **Input validation:** `BUILD_BUDGET` and `MAX_ATTEMPTS` must be integers ≥ 1, and `RETRY_DELAY` an integer ≥ 0. Any other value (`0`, `-100`, `5h`, `x`) gives a `::warning::` and the default (18000, 3, 15). The warning goes to stdout, where the Actions runner reads workflow commands.

**D7 (the controller's D5). The channel-close fix in ae00129 stays unchanged.** That covers dropping `--yes`, the fallback printing the real exit status as a `::warning::`, and `snapcraft-close.test.sh`. Neither W-24 task touches `release-on-merge.yml` or `snapcraft-close.test.sh`.

**D8 (the controller's D6). Exit 0 always; `prune_corrupt` stays; the completeness gate downstream decides.** A truncated file never reaches `snapcraft upload`. One small change: `snaps=` now counts the **requested archs that have a valid snap**. The match is the same suffix match the upload step uses, `*<arch>.snap` (`pr-build-snap.yml:126`: `"${SNAP_NAME}"*"${arch}".snap`, which fits `name_version_arch.snap`). No requested arch name is a suffix of another, so `amd64`, `arm64` and `armhf` cannot be confused. Before, it counted distinct `*.snap` files. The two agree whenever only requested archs are fetched, which is always the case with `--build-for`.

**D9. Stop retrying, with a `::warning::` that names the reason, when:** every requested arch has a valid snap (success, no warning); or `MAX_ATTEMPTS` is reached; or D5 leaves nothing to rebuild (no missing arch was `Succeeded`, or after an exit 75 every missing arch was `Stopped`); or the budget does not fit (D6). The script never loops on anything except its own attempt counter.

**D10. The test stub models snapcraft 9.2.1 as read and probed.** It reproduces `_compute_hash` with the same algorithm: md5 of each file's contents, sorted paths, `.git` included, then md5 of the concatenated hex. Its `--recover` fails with the text from PR #10's log. It prints the state lines **on stderr**, where snapcraft's verbose `emit.progress` puts them (`craft_cli/messages.py:645-648`), and the `IncompleteRead` error. In its timeout mode it prints one more `Succeeded:` line (stderr), then `Timed out waiting for build.` (stdout, `emit.message`, `:553`), and exits 75 (§3.6). Its early-75 modes (Amendment 1) print `Pending` and `Building` lines on stderr, or `Stopped: <first arch>` for one mode. They then print `Timed out waiting for build.` on stdout and exit 75 after `STUB_COST` seconds, whatever `--launchpad-timeout` says, with nothing fetched. For D5a it uses a name allowlist rather than `.gitignore`: when called, it records and fails on any file outside `.git` other than `snapcraft.yaml` and `frigate_*.snap`, as a stand-in for snapcraft committing and pushing that file. A `sleep` stub records the retry delay and returns at once. A stub `date +%s` and a fake clock (each snapcraft call advances it by `STUB_COST`) make the time budget testable without sleeping. Known limit: the stub sorts paths with `LC_ALL=C sort -z`, where Python sorts `PosixPath` parts. The orders can differ for unusual names, which does not matter for the "same tree ⇔ same id" property the tests use.

**D11. History is corrected forward, not rewritten.** bea5564 and ae00129 are already on `origin/fix/remote-build-fetch-recover`: PR #10's CI ran on ae00129. The W-24 card's remark that nothing is pushed yet is therefore not right, and amending bea5564 would rewrite pushed history. The implementation commit's message states what bea5564 got wrong. The PR #10 body is replaced (§8).

**D12 (Amendment 1). Every exit 75 prints `::warning::attempt <n>: snapcraft exited 75 after <took>s of its <left>s --launchpad-timeout: <kind>`.** `<kind>` is `the deadline` when `took ≥ left`, and otherwise `a Launchpad call timed out, not the deadline`.
Reasons:
- The next occurrence then shows at once which case it was, without reading timestamps out of two logs (§3.8 had to).
- The test is exact: the deadline cannot end an attempt shorter than `left` (D6), so `took < left` proves an early 75. The warning does not say which call timed out, because that is not proven (§10).
- It is printed whether or not a retry follows, so a 75 on the last attempt is visible too.

**D13 (an option, NOT chosen; for the maintainer's decision). A state-based rule: after an attempt that printed at least one state line, rebuild every missing arch that the last state line did not report `Stopped`, whatever snapcraft's exit code.**
- What it would add: an attempt that ends on another error while monitoring would be retried too, for example a connection reset or a Launchpad 5xx (an internal error, not 75). The chosen rule does not retry it.
- Evidence for it: none observed. Of the four runs in this spec, the early ends were cut downloads or exit 75 (43838113093, and 43377971262, which had no deadline). Both rules retry those.
- Its cost:
  - a crash in snapcraft while monitoring (a deterministic bug) would cost up to two more full builds and their Launchpad time;
  - the "at least one state line" condition must be pinned, so that an auth failure or an attempt that fails before building (`authfail`, `cutthenfail`) is still not retried. That means about three more tests and two more mutants.
- Default: the maintainer's narrower rule, exit 75 only. Revisit if a run ends on an error other than 75 after `Building` lines.

## 5. Behaviour after the change

```
attempt 1: snapcraft remote-build --build-for=<all> --launchpad-timeout=<budget>   (no marker; id as today)
           exit 75                -> ::warning:: attempt N: snapcraft exited 75 after Ns of its Ns --launchpad-timeout: <kind> (D12)
           prune truncated files; count requested archs with a valid snap
           all present            -> done
           attempt == MAX         -> ::warning:: still missing ... ; done
           rebuild = exit 75 ? missing − last "Stopped:" set : missing ∩ last "Succeeded:" set   (D5)
           rebuild empty          -> ::warning:: not rebuilding <missing>: Launchpad reported it Stopped / did not report it Succeeded ... ; done
           used+delay+took > budget -> ::warning:: not rebuilding <rebuild>: attempt N took Ns ... ; done   (always so after a real deadline, D6)
attempt N: echo N > .git/remote-build-attempt; snapcraft remote-build --build-for=<rebuild> --launchpad-timeout=<left>
...
end:       remove marker and output copy; list snaps; snaps=<count> (stdout and GITHUB_OUTPUT); exit 0
```

The workflow comment above the build step in `.github/workflows/pr-build-snap.yml` (which promises "re-fetches via --recover (no rebuild)" and "retry/timeout behaviour … carried over UNCHANGED") is rewritten to match. Amendment 1 adds the early exit 75 to it. The step's name and `id: build` stay.

## 6. Timing (brief question e)

From the run metadata (`gh run view <id> --json jobs`) and the step log timestamps:

| Run | Job | Build step, attempt 1 | Launchpad | After the build step |
|---|---|---|---|---|
| PR #10, 43754974815 | 19:53:59 → 20:37:01 = **43 min 02 s** | 19:54:14 → 20:23:00 = **28 min 46 s (1726 s)** | Pending 19:56:44 → both Succeeded 20:22:04 = 25 min 20 s | 20:23:38 → 20:37:01 = 13 min 23 s |
| PR #9, 43520710606 | 22:36:54 → 03:06:04 = **4 h 29 min 10 s** | 22:37:18 → 02:47:40 = **4 h 10 min 22 s (15022 s)** | Building 22:40:15; both in Launchpad's `Uploading` state from 23:02:49 to about 02:45; both Succeeded 02:46:59 | 02:48:21 → 03:06:04 = 17 min 43 s |
| 43377971262 (amd64 only) | — | 12:21:45 → 15:57:35 = 3 h 35 min 50 s | amd64 `Uploading` from 12:55:30 until snapcraft printed `Timed out waiting for build` (no `--launchpad-timeout` was set; cause not determined) | — |
| PR #10, 43838113093 (head e089f48) | — | 09:16:03.8 → 09:30:33.1 = **869 s**, ended by an exit 75 before the deadline (§3.8) | Pending 09:20:18; Building 09:20:52, still Building at 09:27:49; no state line after it | — |

PR #9's long time was not compilation: the builds finished in about 22 min, and the archs then sat in **Launchpad's own "Uploading" state for about 3 h 44 min**. The "about 4.5 h of Launchpad" in the PR #10 body is PR #9's whole job, not PR #10's.

Arithmetic, 6 h = 21600 s:
- **PR #10 speed, 3 full attempts:** 15 s before + 3 × 1726 s + 2 × 15 s delay + 803 s after = **6026 s ≈ 1 h 40 min**. This fits easily, and retries build only the missing arch.
- **PR #9 speed, 3 full attempts:** 3 × 15022 s = 45066 s ≈ **12 h 31 min. It does not fit.** Even 2 attempts (30044 s ≈ 8 h 21 min) would not. Hence D6.
- **With D6 at PR #9 speed:** after attempt 1, 15022 + 15 + 15022 = 30059 > 18000, so there is no rebuild. The job is then about 24 s + 15022 s + 1063 s ≈ 4 h 29 min, as PR #9 was.
- **PR #10's second run under Amendment 1:** 869 + 15 + 869 = 1753 ≤ 18000, so attempt 2 would start with about 17116 s left and build both archs.
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
| the stub's tree check (every case; asserted in `cut` and `alwayscut`) | when called, the stub records and fails on any untracked file in the project dir that is not ignored. Only `snapcraft.yaml` and `frigate_*.snap` are allowed outside `.git`. This keeps the output file out of the tree (D5a) |
| `cutthenfail`: call 1 cut, call 2 fails before any state line | exactly 2 calls; `::warning::not rebuilding amd64: … in attempt 2` (the output is parsed per attempt) |
| `BUILD_BUDGET` = `0`, `-100`, `5h`; `MAX_ATTEMPTS=x` | `::warning::` and the default: call 1 gets `--launchpad-timeout=18000`; at most 3 calls |
| `RETRY_DELAY=x` | `::warning::` and the default: the `sleep` stub records `15`; snaps=2; exit 0 (unvalidated, the script dies on `x: unbound variable` with no `snaps=` line) |
| state lines on stderr (every `cut` case) | the rebuild happens only if stderr is captured (D5a ii) |
| `timeout` stub: prints `Succeeded: amd64`, then exits 75 with `Timed out waiting for build` and nothing fetched; the budget is used up | exactly 1 call; no rebuild; snaps=0; `::warning::not rebuilding amd64,arm64: attempt 1 took 18000s` (after a 75 every missing arch is a candidate, so both are named); the D12 warning names `the deadline` |
| `early75`, amd64+arm64, STUB_COST=869 (PR #10's second run) | 2 calls; call 2 `--build-for=amd64,arm64`; call 2's id ≠ call 1's (nothing was fetched, so only the marker can do that); call 2 `--launchpad-timeout=17131`; snaps=2; the D12 warning names `a Launchpad call timed out, not the deadline` |
| `early75stopped`, amd64+arm64 (amd64 `Stopped`, arm64 `Building`) | 2 calls; call 2 `--build-for=arm64`; snaps=1 |
| `early75stopped`, amd64 only | 1 call; `::warning::not rebuilding amd64: Launchpad reported it Stopped in attempt 1` |
| `alwaysearly75`, amd64+arm64 | exactly 3 calls; 3 distinct ids; snaps=0; exit 0; `::warning::still missing amd64,arm64 after 3 attempts` |
| `early75`, STUB_COST=10000 | 1 call; `::warning::not rebuilding amd64,arm64: attempt 1 took 10000s` (D6's budget check) |
| `no budget left` (the clock runs out between attempts) | 1 call; `::warning::not starting attempt 2 …`; no call gets `--launchpad-timeout` below 1 |
| attempt 1's build id | equals the test's own hash of the clean tree (no marker on attempt 1; plan review P5) |

The suite must be **red on the current script** (ae00129) and green after. Amendment 1's cases must be red on `e089f48`'s script and green after. Each mutation below, applied to the new script, must turn it red (checked by a mutation runner in the plan):

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
| M9 keep a stale marker from an earlier run | the stale-marker check |
| M10 write snapcraft's output into the project dir (`./`) | the stub's tree check |
| M11a drop the input validation | the `BUILD_BUDGET=…` cases |
| M11b start an attempt with `left` < 1 | the `no budget left` case |
| M12 `tee -a` (parse earlier attempts' output) | `cutthenfail` |
| M13 parse the first state line instead of the last | the `cut` cases (the stub prints `Building: amd64; Succeeded: arm64` before the final line) |
| M14 write the marker on attempt 1 too | attempt 1's id check |
| M15 drop `2>&1` (stderr not captured) | every case that needs a rebuild (the state lines are on stderr) |
| M16 leave `RETRY_DELAY` unvalidated | the `RETRY_DELAY=x` case |
| M17 handle exit 75 like any other exit (Amendment 1) | the `early75` and `alwaysearly75` cases |
| M18 after a 75, rebuild a `Stopped` arch too | the `early75stopped` cases |
| M19 do not keep snapcraft's exit code (`true` in place of `rc="${PIPESTATUS[0]}"`) | the same cases as M17 |
| M20 drop the D12 warning | the two D12 warning checks |
| M21 count `took = left` as early (`-le` in place of `-lt`) | `timeout`: the warning must name the deadline |

Two more mutants survive and are equivalent, according to the plan review, so they need no test. X4: a `./*"$1"*` glob, because no real arch name is a substring of another. X8: dropping the `[ -d .git ]` guard, which differs only when `.git` is a file.

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

- **The real rebuild against Launchpad.** It runs only when a download is cut or, since Amendment 1, after an early exit 75. PR #10's first run of `e089f48` (43838113093) did not reach it (§3.8). The next push's CI run is the next chance. If neither happens there, the rebuild path stays unproven. Report it faithfully either way.
- **Why the early exit 75 happened (Amendment 1).** It is proven that it was not the deadline (§3.8). Which Launchpad call raised the `TimeoutError`, and why, is NOT PROVEN. The hypothesis is an unanswered connect, given up after the kernel's SYN retries (§3.8).
  - What would prove it: a traceback, which snapcraft does not log for a caught `TimeoutError`; or a record, on the runner during the build, of its connections to the Launchpad API (for example `ss -tn state syn-sent` sampled every few seconds, or a packet capture of the SYNs), together with the runner's `tcp_syn_retries`.
  - D12's warning will show the next occurrence's timing at once, but not its cause.
- **A retry after an early 75, against Launchpad,** is unproven, like the cut-download rebuild. If early 75s come from a recurring network fault between the runner and Launchpad, a retry can meet the same fault. `MAX_ATTEMPTS` and the budget bound it.
- **A rebuild is not guaranteed to avoid another cut download.** The cut may be the idle second connection (§3.6) being dropped while the first ~1 GB file downloads. Both cuts hit under 1 MB into a file: 578594 and 763316 bytes read. **This is NOT PROVEN.**
  - If it is true, two-arch first attempts will often take the rebuild path, at about +25–30 min of Launchpad time per such run, and the single-arch retry (one connection) is likely to succeed.
  - If it is false, the cut is network luck and a retry may be cut again.
  - Either way, if all attempts end incomplete, the pipeline does what it does today. It uploads the valid snaps to `latest/edge/PR<N>`, and `Fail if build/upload incomplete` goes red when a required arch (`REQUIRED_ARCHS=amd64`) is missing. That is kept.
- **Follow-up, not in this PR:** fetch the artifacts without an idle second connection, for example by fetching one file at a time ourselves. That needs a way to reach a finished build again, which is the maintainer's option 2 from the PR #10 question.
- **Follow-up, not in this PR (plan review P8):** snapcraft's build-log files (`snapcraft-frigate-<id>_<arch>_<time>.txt`, `ca/commands/remote.py:227`) land in the project dir, and they are **not** ignored. They appear only after every artifact of an attempt has downloaded. A later attempt therefore follows only if a fully downloaded snap then failed `snap_ok`. In that rare case, the log would be auto-committed into the pushed source of the next attempt. A `.gitignore` entry or moving the logs out before a retry would close this. Both are outside this PR's scope.
- **The same-id reuse path (§3.2) is not exercised.** D3 avoids depending on it, except when `.git` is not a directory.
- **`--launchpad-timeout` was read in the source, not run** (0 means none, a negative value is an internal error, one more state line is printed after the deadline; §3.6). Its behaviour on Launchpad (exit 75, builds continue) is unproven.
- **The `Succeeded:` line format** was read in the source (`ca/commands/remote.py:218`) and seen in three 9.2.1 CI logs. A future snapcraft could change it. The failure mode is safe: D5 then rebuilds nothing, which is today's outcome.
- **Why Launchpad's `Uploading` state took about 3 h 44 min on PR #9** (and why 43377971262 ended with `Timed out waiting for build` without a timeout set) was not determined. The latter fits §3.8: a `TimeoutError` from a Launchpad call, since there was no deadline to reach. That is not proven.
- **Launchpad clean-up of the per-attempt repositories and recipes** (D3 cost) is not addressed.
