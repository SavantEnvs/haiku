#!/usr/bin/env bash
#
# mayhem/test.sh — behavioral oracle for the Haiku BFS file system (fs_shell build of bfs_shell).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

BFS="$SRC/mayhem/build/bfs_shell"
[ -x "$BFS" ] || { echo "missing $BFS (mayhem/build.sh builds it)" >&2; emit_ctrf "bfs_shell" 0 1; exit 1; }

W="$(mktemp -d "${TMPDIR:-/tmp}/bfs-oracle.XXXXXX")"
trap 'rm -rf "$W"' EXIT
cd "$W"

PASS=0; FAIL=0
check() {  # check <name> <expected> <actual>
  if [ "$2" == "$3" ]; then PASS=$((PASS+1)); else
    FAIL=$((FAIL+1)); echo "FAIL $1: expected [$2] got [$3]" >&2; fi
}

seq 1 20000 > big.txt
echo "hello world" > hw.txt
dd if=/dev/zero of=v.img bs=1k count=2048 2>/dev/null

"$BFS" --initialize v.img katvol >init.txt 2>&1
check "initialize exit" "0" "$?"

# One scripted session: build a tree, read it back, check the volume, copy a file out.
"$BFS" v.img >session.txt 2>&1 <<'CMDS'
mkdir /myfs/d
cp :hw.txt /myfs/d/hw
cp :big.txt /myfs/big
ln -s d/hw /myfs/sl
mkindex -t int32 num
cat /myfs/d/hw
ls /myfs
ls /myfs/d
cp /myfs/big :out.txt
query name==hw
checkfs
info
rm /myfs/big
ls /myfs
quit
CMDS
S="$(sed 's/fssh:\/> //g' session.txt)"
line() { grep -m1 -- "$1" <<<"$S" | sed -E 's/[[:space:]]+/ /g; s/^ //; s/ +$//'; }

check "cat" "hello world" "$(grep -x 'hello world' <<<"$S")"
check "ls big size"   "-rw-r--r-- 0 0 108894 big"   "$(grep -E ' big$' <<<"$S" | head -1 | awk '{print $1,$2,$3,$4,$7}')"
check "ls symlink"    "sl -> d/hw"                  "$(grep -oE 'sl -> .*' <<<"$S" | head -1)"
check "ls dir"        "d"                           "$(grep -E '^drwxr-xr-x .* d$' <<<"$S" | head -1 | awk '{print $NF}')"
check "ls nested file size" "12" "$(awk '/^\/myfs\/d:/{f=1} f&&/ hw$/{print $4; exit}' <<<"$S")"
check "query" "/myfs/d/hw" "$(grep -x '[[:space:]]*/myfs/d/hw' <<<"$S" | head -1 | tr -d ' ')"
check "checkfs nodes"  "11 nodes checked," "$(line 'nodes checked')"
check "checkfs clean"  "0 blocks not allocated," "$(line 'blocks not allocated')"
check "checkfs files"  "files 3" "$(line 'files')"
check "checkfs dirs"   "directories 3" "$(line 'directories')"
check "checkfs indices" "indices 5" "$(line 'indices')"
check "info block size" "block size: 2048" "$(line 'block size:')"
check "info name"       "volume name: katvol" "$(line 'volume name:')"
check "info fs"         "fs name: bfs" "$(line 'fs name:')"
check "copy-out size"   "108894" "$(stat -c %s out.txt 2>/dev/null)"
check "copy-out digest" "$(sha256sum < big.txt)" "$(sha256sum < out.txt 2>/dev/null)"
check "rm" "0" "$(awk '/^\/myfs:/{n++} n==2&&/ big$/{c++} END{print c+0}' <<<"$S")"

# Remount from the saved image: the data must have survived an unmount.
"$BFS" v.img >again.txt 2>&1 <<'CMDS'
cat /myfs/d/hw
checkfs
quit
CMDS
A="$(sed 's/fssh:\/> //g' again.txt)"
check "remount cat" "hello world" "$(grep -x 'hello world' <<<"$A")"
check "remount checkfs" "files 2" "$(grep -m1 'files' <<<"$A" | sed -E 's/[[:space:]]+/ /g; s/^ //')"

echo "bfs oracle: passed=$PASS failed=$FAIL"
emit_ctrf "bfs_shell-kat" "$PASS" "$FAIL"
