#!/usr/bin/env bash
# W-23 T20 static packaging assertions (hermetic: reads snap/snapcraft.yaml and spike/ only; no network, no git show).
# Run: bash tests/w23-packaging.test.sh   (exit 0 = all ok)
set -uo pipefail
cd "$(dirname "$0")/.." || exit 1
FAILS=0
t() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then echo "ok   - $n"; else echo "FAIL - $n"; FAILS=$((FAILS+1)); fi; }
Y=${W23_YAML:-snap/snapcraft.yaml}
# The block of one top-level app / part: from "  <name>:" to the next 2-space key or section.
blk() { awk -v k="  $2:" -v s="$1:" '$0==s{on=1;next} on&&/^[a-z]/{on=0} on&&$0==k{f=1;print;next} f&&/^  [^ ]/{f=0} f{print}' "$Y"; }
app() { blk apps "$1"; }
part() { blk parts "$1"; }

t "R1: pbs release 20261110 and CPython 3.12.16 named" sh -c "grep -q 20261110 $Y && grep -q cpython-3.12.16%2B20261110 $Y"
t "R1: x86_64 pbs sha256 pinned"   grep -q '6a9e62dad033790aef722dbd370e0ce76ce17b73627ba3ae679f537049350b39' "$Y"
t "R1: aarch64 pbs sha256 pinned"  grep -q 'b6a41defec4975d94b4ff1950236e7383e5c02ba40ea48c9ec33c66087a35aab' "$Y"
t "R1: install_only_stripped flavour" grep -q 'install_only_stripped' "$Y"
t "SF5: spike/ezviz/requirements.txt is the W-20 lock" sh -c "[ \"\$(sha256sum spike/ezviz/requirements.txt | cut -d' ' -f1)\" = b3282719e5c607e53f5de0943244075708bc2948ec6b4aa130050ce033ab4921 ]"
t "R1: part ezviz-py sources spike/ezviz" sh -c "$(declare -f blk); Y=$Y; blk parts ezviz-py | grep -qx '    source: spike/ezviz'"
t "R2-N8: build-packages [wget, binutils]" sh -c "$(declare -f blk); Y=$Y; blk parts ezviz-py | grep -qx '    build-packages: \[wget, binutils\]'"
t "A: ezviz-check app has no plugs, no daemon" sh -c "$(declare -f blk); Y=$Y; b=\$(blk apps ezviz-check); echo \"\$b\" | grep -qx '    command: bin/ezviz-check' && ! echo \"\$b\" | grep -qE 'plugs|daemon|extensions'"
t "A: disk-guard app oneshot, timer every 10 min, no plugs" sh -c "$(declare -f blk); Y=$Y; b=\$(blk apps disk-guard); echo \"\$b\" | grep -qx '    command: bin/disk-guard' && echo \"\$b\" | grep -qx '    daemon: oneshot' && echo \"\$b\" | grep -qx '    timer: \"00:00-24:00/144\"' && ! echo \"\$b\" | grep -q plugs"
t "D17: go2rtc app unchanged (plugs, no stop-mode)" sh -c "$(declare -f blk); Y=$Y; b=\$(blk apps go2rtc); echo \"\$b\" | grep -qx '    plugs: \[network, network-bind\]' && ! echo \"\$b\" | grep -q stop-mode"
t "R1: import proof names pyezvizapi.streaming.local.session" grep -q 'import ezviz_source.main.*pyezvizapi.streaming.local.session.*print("ezviz-py import proof ok")' "$Y"
t "SF7: pip install line does not start with env -i" sh -c "$(declare -f blk); Y=$Y; l=\$(blk parts ezviz-py | grep -- '-m pip install'); [ -n \"\$l\" ] && ! echo \"\$l\" | grep -qE '^ *env -i'"
t "N11/N8: readelf presence guard fails closed"  grep -qF 'command -v readelf >/dev/null || { echo "ezviz-py: readelf missing" >&2; exit 1; }' "$Y"
# S2 (fix wave 1): the exact readelf -d failure guard; a generic 'exit 1' grep also matches the arch case and the presence guard.
t "N11/N8: readelf -d failure guard fails closed (exact line)" grep -qF 'NEEDED=$(readelf -d "$D/bin/python3.12") || { echo "ezviz-py: readelf -d failed" >&2; exit 1; }' "$Y"
t "N11/N8: libpython rm only after readelf -d succeeded and lacks NEEDED libpython" sh -c "$(declare -f blk); Y=$Y; b=\$(blk parts ezviz-py); echo \"\$b\" | grep -q 'readelf -d \"\$D/bin/python3.12\"' && echo \"\$b\" | grep -q 'NEEDED.*libpython' && echo \"\$b\" | grep -q 'exit 1' && ! echo \"\$b\" | grep -qE 'readelf .*\|\| *rm'"
t "R1: ezviz-source execs py3.12 -I -B -m ezviz_source.main" grep -qF 'exec "$SNAP/opt/ezviz-py/bin/python3.12" -I -B -m ezviz_source.main' spike/bin/ezviz-source
t "R1: ezviz-source unsets LD_LIBRARY_PATH" grep -qE '^unset .*LD_LIBRARY_PATH' spike/bin/ezviz-source
t "R1: no ezviz path under any prime:/stage: exclude" sh -c "! grep -nE '^ +- -.*(ezviz|bin/disk-guard)' $Y && ! grep -nE '^ +- -bin/' $Y"
t "R1: no spike/bin/ezviz-* wrapper references python3.11" sh -c "! grep -l 'python3\.11' spike/bin/ezviz-*"
t "R1: wrappers part dumps spike/bin into bin/" sh -c "$(declare -f blk); Y=$Y; b=\$(blk parts wrappers); echo \"\$b\" | grep -qx '    source: spike/bin' && echo \"\$b\" | grep -q \"'\\*': bin/\""
# N4 (fix wave 1): the copied source tree must not ship a stale __pycache__ from a dev checkout; deleted after the cp and before compileall.
t "N4: ezviz-py deletes __pycache__ from the copied ezviz_source after the cp, before compileall" sh -c "$(declare -f blk); Y=$Y; blk parts ezviz-py | awk '/cp -r .*ezviz_source/{c=NR} /find .*ezviz_source.* -name __pycache__ .*rm -rf/{d=NR} /-m compileall/{k=NR} END{exit !(c && d>c && k>d)}'"
for f in ezviz-source ezviz-rearm ezviz-check disk-guard; do
  t "wrappers: $f is mode 100755 in git" sh -c "git ls-files -s spike/bin/$f | grep -q '^100755 '"
done
echo "---"
[ "$FAILS" -eq 0 ] && echo "all ok" || echo "$FAILS FAIL"
exit "$FAILS"
