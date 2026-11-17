#!/usr/bin/env bash
#
# mayhem/build.sh — build telescope-fzf-native.nvim's fuzz harnesses and its unit suite.
#
# Upstream is a single C99 file (src/fzf.c) that its Makefile/CMake only turn into a shared
# library for LuaJIT FFI. The fuzz build compiles that same source, sanitized, straight into each
# harness; the test build compiles upstream's test/test.c against the source with upstream's normal
# flags (Makefile: -Og -Wall -std=gnu99), linked to the pinned examiner library from the image.
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
: "${SRC:=/mayhem}"
EXAMINER=/opt/toolchains/deps/examiner-4fa86cb

cd "$SRC"
OBJ="$SRC/build/mayhem"          # build/ is gitignored upstream, so `git clean -ffdX` resets it
mkdir -p "$OBJ"

CFLAGS_FUZZ="-std=gnu99 $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -Isrc"

# 1) The library itself, instrumented: once with SanCov for the libFuzzer link (fuzz/), once
#    without for the -standalone reproducers (standalone/), which carry no libFuzzer runtime.
mkdir -p "$OBJ/fuzz" "$OBJ/standalone"
$CC $CFLAGS_FUZZ -fsanitize=fuzzer-no-link -c src/fzf.c -o "$OBJ/fuzz/fzf.o"
$CC $CFLAGS_FUZZ -c src/fzf.c -o "$OBJ/standalone/fzf.o"
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c mayhem/lsan_off.cc -o "$OBJ/lsan_off.o"
$CC $CFLAGS_FUZZ -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone/standalone_main.o"

# 2) Each harness: a libFuzzer binary and a run-once -standalone reproducer.
for h in fuzz_fzf_pattern fuzz_fzf_matchers; do
  $CC $CFLAGS_FUZZ -fsanitize=fuzzer-no-link -c "mayhem/harnesses/$h.c" -o "$OBJ/fuzz/$h.o"
  $CC $CFLAGS_FUZZ -c "mayhem/harnesses/$h.c" -o "$OBJ/standalone/$h.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE \
      "$OBJ/fuzz/$h.o" "$OBJ/fuzz/fzf.o" "$OBJ/lsan_off.o" -o "$SRC/$h"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS \
      "$OBJ/standalone/standalone_main.o" "$OBJ/standalone/$h.o" "$OBJ/standalone/fzf.o" \
      "$OBJ/lsan_off.o" -o "$SRC/$h-standalone"
done

# 3) Upstream's unit suite with its normal flags (no sanitizers), run by mayhem/test.sh.
$CC -Og -ggdb3 -Wall -std=gnu99 $COVERAGE_FLAGS -Isrc -I"$EXAMINER/include" \
    test/test.c src/fzf.c "$EXAMINER/lib/libexaminer.a" -o "$SRC/build/fzf_unit_tests"

# 4) Upstream's FFI library exactly as its Makefile builds it (`make` → build/libfzf.so), which
#    lua/fzf_lib.lua loads and test/fzf_lib_spec.lua (the neovim suite, run by mayhem/test.sh) drives.
$CC -O3 -Wall -fpic -std=gnu99 -shared src/fzf.c -o "$SRC/build/libfzf.so"
