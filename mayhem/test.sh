#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. PATCH-grade oracle: after an agent patches the source, the grader
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

# Two upstream suites, mirroring upstream CI's `gcc` (`make test`) and `nvim-tests` (`make ntest`)
# jobs. Their counts are summed into one CTRF report; either suite failing, or not reaching its
# summary, fails the oracle.
total_passed=0 total_failed=0 total_pending=0

# 1) test/test.c on the examiner framework (build.sh built it). Every test asserts exact match
#    scores, start/end offsets and highlight positions, so a neutered library or runner reports no OK
#    lines and fails here. examiner prints one "[       OK ]" / "[  FAILED  ]" / pending line per test
#    and a final "[==========] Ran N test(s)" line.
RUNNER="$SRC/build/fzf_unit_tests"
if [ ! -x "$RUNNER" ]; then
  echo "test.sh: $RUNNER missing — mayhem/build.sh must build it" >&2
  emit_ctrf "examiner+plenary-busted" 0 1 0
  exit 1
fi
LOG="$(mktemp)"
"$RUNNER" >"$LOG" 2>&1
rc=$?
# strip ANSI colours before counting
sed -i 's/\x1b\[[0-9;]*m//g' "$LOG"
cat "$LOG"
passed=$(grep -c '^\[       OK \]' "$LOG" || true)
failed=$(grep -c '^\[  FAILED  \]' "$LOG" || true)
pending=$(grep -ci '^\[ *PENDING *\]' "$LOG" || true)
ran=$(sed -n 's/^\[==========\] Ran \([0-9]*\) test(s) across all scopes.*/\1/p' "$LOG" | tail -1)
rm -f "$LOG"
# A suite that did not run to its summary, exited non-zero, or ran nothing is a failure.
if [ -z "$ran" ] || [ "$rc" -ne 0 ] || [ "$passed" -eq 0 ] || [ $((passed + failed + pending)) -ne "$ran" ]; then
  [ "$failed" -gt 0 ] || failed=1
fi
echo "test.sh: examiner suite: passed=$passed failed=$failed pending=$pending"
total_passed=$((total_passed + passed)) total_failed=$((total_failed + failed)) total_pending=$((total_pending + pending))

# 2) test/fzf_lib_spec.lua: upstream's `make ntest` command, run by plenary's busted under headless
#    neovim against build/libfzf.so (loaded by lua/fzf_lib.lua through LuaJIT FFI). Each `it()`
#    asserts exact scores and highlight positions via `eq(...)`. plenary (pinned in the image) is put
#    on the runtimepath with --cmd, since test/minrc.vim expects it at ../plenary.nvim; HOME/XDG_*
#    point at a scratch dir so neovim writes no state into the image. busted prints, per spec file,
#    "Success: N", "Failed : N" and "Errors : N"; we sum those.
PLENARY=/opt/toolchains/deps/plenary-74b06c6
if ! command -v nvim >/dev/null || [ ! -d "$PLENARY" ] || [ ! -f "$SRC/build/libfzf.so" ]; then
  echo "test.sh: nvim, $PLENARY or build/libfzf.so missing — the image/build.sh must provide them" >&2
  emit_ctrf "examiner+plenary-busted" "$total_passed" $((total_failed + 1)) 0 "$total_pending"
  exit 1
fi
NVHOME="$(mktemp -d)"
LOG="$(mktemp)"
HOME="$NVHOME" XDG_CONFIG_HOME="$NVHOME/config" XDG_DATA_HOME="$NVHOME/data" \
XDG_STATE_HOME="$NVHOME/state" XDG_CACHE_HOME="$NVHOME/cache" \
  nvim --headless --noplugin --cmd "set rtp+=$PLENARY" -u test/minrc.vim \
    -c "PlenaryBustedDirectory test/ { minimal_init = './test/minrc.vim' }" </dev/null >"$LOG" 2>&1
rc=$?
sed -i 's/\x1b\[[0-9;]*m//g; s/\r//g' "$LOG"
cat "$LOG"
sum_field() { awk -v k="$1" '$0 ~ "^"k" *:" { sub(/^[^:]*: */, ""); n += $1; seen = 1 } END { print seen ? n : "" }' "$LOG"; }
passed=$(sum_field Success)
failed=$(sum_field Failed)
errors=$(sum_field Errors)
rm -rf "$LOG" "$NVHOME"
if [ -z "$passed" ] || [ -z "$failed" ] || [ -z "$errors" ]; then
  echo "test.sh: plenary busted printed no Success/Failed/Errors summary" >&2
  passed=${passed:-0} failed=$(( ${failed:-0} + ${errors:-0} )); [ "$failed" -gt 0 ] || failed=1
else
  failed=$((failed + errors))
fi
if [ "$rc" -ne 0 ] || [ "$passed" -eq 0 ]; then
  [ "$failed" -gt 0 ] || failed=1
fi
echo "test.sh: plenary-busted suite: passed=$passed failed=$failed"
total_passed=$((total_passed + passed)) total_failed=$((total_failed + failed))

emit_ctrf "examiner+plenary-busted" "$total_passed" "$total_failed" 0 "$total_pending"
