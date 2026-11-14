#!/usr/bin/env bash
# remote-build.sh — `snapcraft remote-build` for the given archs, fetching the
# artifacts with retry so a TRANSIENT network failure during the download does
# not fail an otherwise-green build.
#
# Why: the Launchpad build can SUCCEED while snapcraft's download of the artifact
# breaks mid-stream ("Connection broken: IncompleteRead"). That leaves a
# truncated .snap on disk which later fails to unsquash at upload — a passing
# build turned red by a network blip. We validate every fetched snap, drop any
# that are truncated/corrupt, and re-fetch via `--recover` (which reuses the
# existing Launchpad build — NO rebuild) until every requested arch has a VALID
# snap or the attempts are exhausted.
#
# A genuine single-arch BUILD failure stays tolerated: we keep whatever valid
# snaps exist and let the caller's completeness gate decide. So this never makes
# a previously-passing build fail; it only rescues transient download breakage.
#
# Frigate's build is much heavier than a typical Node/Python-only snap (ffmpeg,
# go2rtc, ML runtimes) — Launchpad build+fetch times are correspondingly longer.
# This is exactly why the retry/timeout behaviour here is carried over UNCHANGED
# from the source pattern rather than "optimized": a heavier build makes transient
# fetch failures on a long-lived remote-build MORE likely, not less, to matter.
# One change since (PR 9's run): fetched files are parked outside the project dir
# between attempts, because `--recover` only finds the build while the tree hashes
# as it did at attempt 1 (see park_fetched below).
#
# Usage:  remote-build.sh <comma-separated-archs>        # e.g. amd64,arm64,armhf
# Env:    MAX_ATTEMPTS (default 3), RETRY_DELAY seconds (default 15)
#         GITHUB_OUTPUT (optional) — receives "snaps=<valid-count>"
# Exit:   0 always (partial-tolerant).
set -uo pipefail

ARCHS="${1:?usage: remote-build.sh <archs>, e.g. amd64,arm64,armhf}"
MAX_ATTEMPTS="${MAX_ATTEMPTS:-3}"
RETRY_DELAY="${RETRY_DELAY:-15}"

IFS=',' read -ra WANT <<< "$ARCHS"
want="${#WANT[@]}"

# 0 iff $1 is a complete, readable squashfs. `unsquashfs -l` reads the inode and
# directory tables (near the END of the archive), so a truncated download fails
# here — unlike a superblock-only check, which a tail-truncated file would pass.
snap_ok() { unsquashfs -l "$1" >/dev/null 2>&1; }

# Drop truncated/corrupt artifacts so the next attempt re-fetches them and a bad
# file never reaches `snapcraft upload`.
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

# A retry must see the project tree exactly as attempt 1 did. snapcraft 9 derives
# the remote build id from an md5 over EVERY file in the project dir
# (craft_application remote/utils.py get_build_id), so a fetched .snap left in the
# checkout makes `--recover` look for a build that does not exist ("Could not find
# repository at path ..."). PR 9 lost a SUCCEEDED arm64 build that way after its
# download broke mid-stream. So, between attempts, every file that was not in the
# tree before attempt 1 is parked outside it, and it is restored at the end.
PARK="$(mktemp -d "${TMPDIR:-/tmp}/remote-build-park.XXXXXX")"
mkdir -p "$PARK/tree"
tree_files() { find . -path ./.git -prune -o -type f -print | LC_ALL=C sort; }
tree_files > "$PARK/baseline"

park_fetched() {
    local f n=0
    while IFS= read -r f; do
        mkdir -p "$PARK/tree/$(dirname "$f")"
        mv -f "$f" "$PARK/tree/$f"
        n=$((n + 1))
    done < <(tree_files | LC_ALL=C comm -13 "$PARK/baseline" -)
    echo "parked ${n} fetched file(s) outside the project dir (a retry must hash the tree as attempt 1 did)"
    if [ "$(tree_files)" != "$(cat "$PARK/baseline")" ]; then
        echo "::warning::project tree differs from attempt 1 (a tracked file is gone); --recover will look for a different build id"
    fi
}

# Put parked files back; a file fetched again by a later attempt wins (it was validated last).
restore_parked() {
    local f rel
    while IFS= read -r f; do
        rel="${f#"$PARK/tree/"}"
        if [ -e "$rel" ]; then rm -f "$f"; else mkdir -p "$(dirname "$rel")"; mv "$f" "$rel"; fi
    done < <(find "$PARK/tree" -type f)
    rm -rf "$PARK"
}

valid_count() {                # distinct *.snap names, in the project dir or parked
    local f
    for f in ./*.snap "$PARK"/tree/*.snap; do [ -e "$f" ] && basename "$f"; done | sort -u | wc -l | tr -d ' '
}

attempt=1
while [ "$attempt" -le "$MAX_ATTEMPTS" ]; do
    echo "::group::remote-build attempt ${attempt}/${MAX_ATTEMPTS} (${ARCHS})"
    # First pass builds + fetches; retries recover the SAME Launchpad build and
    # only re-download — no rebuild. `|| true`: a partial-arch failure must not
    # abort, and a transient fetch error is handled by the validate+retry below.
    if [ "$attempt" -eq 1 ]; then
        snapcraft remote-build -v --launchpad-accept-public-upload --build-for="$ARCHS" || true
    else
        snapcraft remote-build -v --launchpad-accept-public-upload --build-for="$ARCHS" --recover || true
    fi
    echo "::endgroup::"

    prune_corrupt
    count="$(valid_count)"
    echo "valid snaps after attempt ${attempt}: ${count}/${want}"
    [ "$count" -ge "$want" ] && break

    if [ "$attempt" -lt "$MAX_ATTEMPTS" ]; then
        park_fetched
        echo "incomplete (${count}/${want}) — re-fetching in ${RETRY_DELAY}s"
        sleep "$RETRY_DELAY"
    fi
    attempt=$((attempt + 1))
done

restore_parked
count="$(valid_count)"
ls -1 ./*.snap 2>/dev/null || echo "(no .snap files produced)"
echo "snaps=${count}"
[ -n "${GITHUB_OUTPUT:-}" ] && echo "snaps=${count}" >> "$GITHUB_OUTPUT"
exit 0
