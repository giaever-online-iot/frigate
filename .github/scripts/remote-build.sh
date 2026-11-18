#!/usr/bin/env bash
# remote-build.sh — `snapcraft remote-build` for the given archs. When Launchpad
# built an arch but the DOWNLOAD of its artifact broke, start a NEW remote build
# of just the archs still missing, within MAX_ATTEMPTS and BUILD_BUDGET.
#
# Why: the Launchpad build can SUCCEED while snapcraft's download of the artifact
# breaks mid-stream ("Connection broken: IncompleteRead"; PR 9 and PR 10, the
# first two two-arch runs). That leaves a truncated .snap on disk which would
# fail to unsquash at upload. Every fetched snap is validated and a truncated
# one is dropped, so a bad file never reaches `snapcraft upload`.
#
# Why a new build and not `--recover`: snapcraft 9.2.1 creates the Launchpad
# repository under its remote-build project (~<owner>/<project>/+git/<id>), but
# `--recover` looks it up without the project (~<owner>/+git/<id>), so recovery
# never finds it (PR 10: "Could not find repository" for the very id attempt 1
# had pushed). A new build walks the same path attempt 1 does on every run.
#
# Each attempt gets its own build id. snapcraft's id is an md5 over the CONTENTS
# of every file in the project dir, .git included (craft_application
# remote/utils.py _compute_hash), so the attempt number written to
# .git/remote-build-attempt changes it, while the source snapcraft pushes stays
# the PR's commit (nothing under .git is committed). Removed at exit.
#
# Exit 75 ("Timed out waiting for build.") is snapcraft's answer to ANY
# TimeoutError while it monitors the build, not only to its own deadline: a
# Launchpad API call that times out at the socket ends the attempt the same way
# (PR 10: 13 min into an 18000 s timeout). Launchpad's state is then unknown and
# nothing was fetched, so the retry builds every missing arch except one the last
# state line reported Stopped. A real deadline is never retried: it ends only once
# the whole budget is used, so the budget check below always refuses it.
#
# Not retried: an arch Launchpad reported Stopped (a genuine build failure), or,
# after any exit other than 75, an arch it did not report as Succeeded; it is left
# to the caller's completeness gate, as before.
# A rebuild only starts if the previous attempt's duration still fits in
# BUILD_BUDGET, and each attempt passes --launchpad-timeout=<budget left>, so the
# job reaches its upload step inside GitHub's 6 h job limit. No attempt starts
# with less than 1 s left: snapcraft reads --launchpad-timeout=0 as "no timeout"
# and a negative value as an internal error.
#
# Usage:  remote-build.sh <comma-separated-archs>        # e.g. amd64,arm64,armhf
# Env:    MAX_ATTEMPTS (default 3), RETRY_DELAY seconds (default 15),
#         BUILD_BUDGET seconds for all attempts (default 18000 = 5 h)
#         (a value that is not an integer in range gets a ::warning:: and the default)
#         GITHUB_OUTPUT (optional) — receives "snaps=<valid-count>"
# Exit:   0 always (partial-tolerant).
set -uo pipefail

ARCHS="${1:?usage: remote-build.sh <archs>, e.g. amd64,arm64,armhf}"
# $1 = variable name, $2 = default, $3 = smallest valid value. Keeps the variable if it
# holds an integer >= $3; otherwise warns (on stdout, where the Actions runner reads
# workflow commands) and sets the default.
int_or_default() {
    local v="${!1:-$2}"
    case "$v" in
        ''|*[!0-9]*) ;;
        *) if [ "${#v}" -le 9 ] && [ "$((10#$v))" -ge "$3" ]; then printf -v "$1" '%s' "$((10#$v))"; return; fi ;;
    esac
    echo "::warning::$1='$v' is not an integer >= $3; using $2"
    printf -v "$1" '%s' "$2"
}
int_or_default MAX_ATTEMPTS 3 1
int_or_default RETRY_DELAY 15 0
int_or_default BUILD_BUDGET 18000 1

IFS=',' read -ra WANT <<< "$ARCHS"
want="${#WANT[@]}"

# 0 iff $1 is a complete, readable squashfs. `unsquashfs -l` reads the inode and
# directory tables (near the END of the archive), so a truncated download fails
# here — unlike a superblock-only check, which a tail-truncated file would pass.
snap_ok() { unsquashfs -l "$1" >/dev/null 2>&1; }

# Drop truncated/corrupt artifacts so a bad file never reaches `snapcraft upload`.
prune_corrupt() {
    local f
    for f in ./*.snap; do
        [ -e "$f" ] || continue
        if ! snap_ok "$f"; then
            echo "discarding corrupt/truncated artifact: $f"
            rm -f "$f"
        fi
    done
}

# 0 iff a snap for arch $1 is in the project dir (run after prune_corrupt). Same suffix
# match as the workflow's upload step ("${SNAP_NAME}"*"${arch}".snap).
have_arch() { local f; for f in ./*"$1".snap; do [ -e "$f" ] && return 0; done; return 1; }

valid_count() { local a n=0; for a in "${WANT[@]}"; do have_arch "$a" && n=$((n + 1)); done; echo "$n"; }

missing_archs() { local a out=(); for a in "${WANT[@]}"; do have_arch "$a" || out+=("$a"); done; (IFS=,; echo "${out[*]}"); }

# Missing archs that Launchpad reported as built in the attempt whose output is in $1:
# the last "Succeeded: amd64, arm64" state line snapcraft printed before fetching.
rebuild_archs() {
    local a out=() built
    built=",$(sed -n 's/.*Succeeded: \([^;]*\).*/\1/p' "$1" | tail -n1 | tr -d ' '),"
    for a in "${WANT[@]}"; do
        have_arch "$a" && continue
        case "$built" in *",$a,"*) out+=("$a") ;; esac
    done
    (IFS=,; echo "${out[*]}")
}

# Missing archs to rebuild after an exit 75, whose output is in $1: every missing arch
# except one the last "Stopped: amd64" state line reported (a build failure stays final).
timeout_archs() {
    local a out=() stopped
    stopped=",$(sed -n 's/.*Stopped: \([^;]*\).*/\1/p' "$1" | tail -n1 | tr -d ' '),"
    for a in "${WANT[@]}"; do
        have_arch "$a" && continue
        case "$stopped" in *",$a,"*) ;; *) out+=("$a") ;; esac
    done
    (IFS=,; echo "${out[*]}")
}

MARK=.git/remote-build-attempt
# snapcraft's output (D5 parses its state lines) must stay OUT of the project dir:
# snapcraft copies the whole dir and auto-commits every file that is not ignored,
# so a file here would be pushed to the public Launchpad repository and change the
# build id. `tee` (no -a) truncates it, so each attempt is parsed on its own.
LOG="$(mktemp "${TMPDIR:-/tmp}/remote-build-out.XXXXXX")"
rm -f "$MARK"
trap 'rm -f "$MARK" "$LOG"' EXIT
[ -d .git ] || echo "::warning::.git is not a directory; a rebuild would reuse attempt 1's build id"

start="$(date +%s)"
build_for="$ARCHS"
attempt=1
while :; do
    left=$((BUILD_BUDGET - ($(date +%s) - start)))
    if [ "$left" -lt 1 ]; then
        echo "::warning::not starting attempt ${attempt}: the ${BUILD_BUDGET}s budget is used up"
        break
    fi
    echo "::group::remote-build attempt ${attempt}/${MAX_ATTEMPTS} (${build_for}; ${left}s of budget left)"
    # A new build every time (never --recover); attempts 2+ write their number into
    # .git so snapcraft computes a new build id. A failed attempt does not abort the
    # script: its exit code is kept (75 = timed out) and what was fetched is validated
    # below.
    if [ "$attempt" -gt 1 ] && [ -d .git ]; then echo "$attempt" > "$MARK"; fi
    t0="$(date +%s)"
    rc=0
    snapcraft remote-build -v --launchpad-accept-public-upload --build-for="$build_for" \
        --launchpad-timeout="$left" 2>&1 | tee "$LOG" || rc="${PIPESTATUS[0]}"
    t1="$(date +%s)"
    echo "::endgroup::"
    took=$((t1 - t0)); used=$((t1 - start))
    if [ "$rc" -eq 75 ]; then
        # snapcraft sets its deadline after t0, so the deadline cannot end an attempt
        # shorter than `left`; a shorter one ended on a Launchpad call that timed out.
        if [ "$took" -lt "$left" ]; then kind="a Launchpad call timed out, not the deadline"; else kind="the deadline, or a timeout too close to it to tell"; fi
        echo "::warning::attempt ${attempt}: snapcraft exited 75 after ${took}s of its ${left}s --launchpad-timeout: ${kind}"
    fi

    prune_corrupt
    count="$(valid_count)"
    echo "valid snaps after attempt ${attempt}: ${count}/${want}"
    [ "$count" -ge "$want" ] && break
    if [ "$attempt" -ge "$MAX_ATTEMPTS" ]; then
        echo "::warning::still missing $(missing_archs) after ${MAX_ATTEMPTS} attempts"
        break
    fi
    if [ "$rc" -eq 75 ]; then
        rebuild="$(timeout_archs "$LOG")"
        why="Launchpad reported it Stopped in attempt ${attempt} (a build failure)"
    else
        rebuild="$(rebuild_archs "$LOG")"
        why="Launchpad did not report it Succeeded in attempt ${attempt} (a build failure or an error before the build, not a broken download)"
    fi
    if [ -z "$rebuild" ]; then
        echo "::warning::not rebuilding $(missing_archs): ${why}"
        break
    fi
    if [ $((used + RETRY_DELAY + took)) -gt "$BUILD_BUDGET" ]; then
        echo "::warning::not rebuilding ${rebuild}: attempt ${attempt} took ${took}s, ${used}s of the ${BUILD_BUDGET}s budget are used"
        break
    fi
    echo "incomplete (${count}/${want}) — new remote build of ${rebuild} in ${RETRY_DELAY}s"
    sleep "$RETRY_DELAY"
    build_for="$rebuild"
    attempt=$((attempt + 1))
done

count="$(valid_count)"
ls -1 ./*.snap 2>/dev/null || echo "(no .snap files produced)"
echo "snaps=${count}"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "snaps=${count}" >> "$GITHUB_OUTPUT"
exit 0
