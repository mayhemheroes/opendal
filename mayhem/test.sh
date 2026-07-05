#!/usr/bin/env bash
#
# opendal/mayhem/test.sh — RUN apache/opendal's own `behavior` test suite (core/tests/behavior)
# against the real `fs` backend, and emit a CTRF summary. exit 0 iff no test failed.
#
# PATCH-grade oracle: `behavior` is opendal's own cross-backend functional/assertion suite
# (core/tests/behavior/{async_read,async_write,async_list,async_delete,async_rename,async_copy,
# async_stat,async_create_dir,async_presign}.rs) — it writes real bytes to a real filesystem
# path, reads them back and asserts byte-for-byte equality, asserts directory listings/renames/
# copies/deletes/stat metadata against expected values, etc. It is opendal's *own* correctness
# suite (the same one every OSS-Fuzz-adjacent CI run exercises per-backend), NOT a smoke test —
# a no-op/"exit(0)" patch to opendal's fs backend (e.g. a write that silently drops data, or a
# read that returns garbage/empty) makes these assert_eq!-style checks fail loudly.
#
# `behavior` uses `libtest_mimic` (harness = false in core/Cargo.toml) instead of the default
# libtest harness, but it deliberately MIMICS libtest's "test result: N passed; M failed; ..."
# summary line, so we parse it exactly like a normal `cargo test` run.
#
# We run with the crate's NORMAL flags (default feature resolution, no sanitizer RUSTFLAGS) to
# keep the oracle honest and fast — build.sh already built this test binary with the project's
# normal flags in a separate, clean build (see the "build the fs-backend test suite" block);
# this script only RUNS it.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
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

BIN="$SRC/core/target-test/debug/behavior"

if [ ! -x "$BIN" ]; then
  echo "behavior test binary not found at $BIN (build.sh should have built it) — cannot run test suite" >&2
  emit_ctrf "opendal-behavior" 0 1 0; exit 2
fi

# Select the `fs` backend against a fresh, writable scratch root (never /mayhem — the image is
# read-only at fuzz time; a build-time test.sh run can write under /tmp regardless).
export OPENDAL_TEST=fs
export OPENDAL_FS_ROOT="$(mktemp -d /tmp/opendal-behavior-fs.XXXXXX)"

echo "=== running opendal core/tests/behavior (fs backend, OPENDAL_FS_ROOT=$OPENDAL_FS_ROOT) ==="
out="$("$BIN" --test-threads 1 2>&1)"; rc=$?
echo "$out"
rm -rf "$OPENDAL_FS_ROOT"

# libtest(-mimic) prints one summary line:
#   test result: ok. 123 passed; 0 failed; 0 ignored; 0 measured; 0 filtered out; ...
PASSED=0; FAILED=0; IGNORED=0
while read -r p f i; do
  PASSED=$(( PASSED + p )); FAILED=$(( FAILED + f )); IGNORED=$(( IGNORED + i ))
done < <(printf '%s\n' "$out" \
  | sed -n 's/^test result:.* \([0-9][0-9]*\) passed; \([0-9][0-9]*\) failed; \([0-9][0-9]*\) ignored.*/\1 \2 \3/p')

if [ "$(( PASSED + FAILED + IGNORED ))" -eq 0 ]; then
  echo "could not parse any 'test result:' line; using process exit code $rc" >&2
  [ "$rc" -eq 0 ] && { emit_ctrf "opendal-behavior" 1 0 0; exit 0; }
  emit_ctrf "opendal-behavior" 0 1 0; exit 1
fi

emit_ctrf "opendal-behavior" "$PASSED" "$FAILED" "$IGNORED"
