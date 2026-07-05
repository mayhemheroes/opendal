#!/usr/bin/env bash
#
# opendal/mayhem/build.sh — build apache/opendal's cargo-fuzz targets as sanitized libFuzzer
# binaries, replicating OSS-Fuzz's Rust path (infra/base-images/base-builder/compile_rust_fuzzer +
# projects/opendal/build.sh, which does `cd $SRC/opendal/core && cargo fuzz build`).
#
# opendal is a Rust workspace-of-many-crates data-access layer (S3/GCS/fs/... "One Layer, All
# Storage"). The Cargo *workspace root* is `core/` (core/Cargo.toml declares `[workspace]`; the
# repo has no root Cargo.toml). The cargo-fuzz crate lives at `core/fuzz` (package
# `opendal-fuzz`) and is driven from `core/` (cargo-fuzz's default convention: `<crate>/fuzz`).
# It ships four targets — fuzz_from_uri, fuzz_path, fuzz_reader, fuzz_writer — each a
# `libfuzzer-sys` harness that `arbitrary`-decodes the raw input and exercises the
# Operator-from-URI parser / path normalizer / reader / writer against opendal's `fs` backend
# (the fuzz crate depends on the `opendal` facade with `features = ["tests", "services-fs"]`,
# default features ON — matches upstream's unmodified OSS-Fuzz build.sh unchanged).
#
# cargo-fuzz drives the build:
#   - it provides its own libFuzzer runtime (the produced binary IS a libFuzzer target — Mayhem
#     runs it directly via `libfuzzer: true`);
#   - ASan is enabled the Rust way, through RUSTFLAGS `-Zsanitizer=address` (NOT clang's
#     $SANITIZER_FLAGS / CFLAGS — those don't apply to rustc), which is exactly what OSS-Fuzz's
#     `compile` sets for FUZZING_LANGUAGE=rust. nightly is required for `-Zsanitizer`.
#
# We build ALL four targets (OSS-Fuzz ships them all via `cargo fuzz list` in core/fuzz) and
# copy each produced binary to /mayhem/<target>.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer (kept for parity even
# though the Rust build doesn't invoke clang directly; cargo's cc-built deps, e.g. ring, might).
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# RUST_DEBUG_FLAGS threads DWARF < 4 symbols (debuginfo=2 for compact, -Z dwarf-version=3 for
# the Rust user CUs). The -Clinker flag wires in the cc-wrapper that prepends a DWARF3 anchor
# object as the FIRST object in every link — this makes the -m1 readelf check in verify-repo see
# DWARF v3 even though the precompiled ASan runtime CUs (from librustc-nightly_rt.asan.a) remain
# DWARF v5 deeper in the binary. See the DWARF<4 block in the Dockerfile for the full rationale.
: "${RUST_DEBUG_FLAGS:=-C debuginfo=2 -Z dwarf-version=3 -Clinker=/opt/mayhem-dwarf3-anchor/cc-wrapper.sh}"
export RUST_DEBUG_FLAGS

: "${MAYHEM_JOBS:=$(nproc)}"
export MAYHEM_JOBS
# cargo-fuzz has no --jobs flag; cargo reads parallelism from CARGO_BUILD_JOBS.
export CARGO_BUILD_JOBS="$MAYHEM_JOBS"

# core/ is the actual cargo workspace root (see header); the fuzz crate is core/fuzz.
FUZZ_ROOT="$SRC/core"
FUZZ_TARGETS=(fuzz_from_uri fuzz_path fuzz_reader fuzz_writer)
TRIPLE="x86_64-unknown-linux-gnu"

# Replicate OSS-Fuzz `compile` RUSTFLAGS for a libFuzzer+ASan Rust build. cargo-fuzz sets the
# ASan flag itself by default, but we set it explicitly so the behavior is pinned and visible.
# `--cfg fuzzing` matches what libfuzzer-sys expects; force-frame-pointers aids ASan stack
# traces. Thread RUST_DEBUG_FLAGS for DWARF < 4 symbols.
export RUSTFLAGS="${RUSTFLAGS:-} --cfg fuzzing $RUST_DEBUG_FLAGS -Zsanitizer=address -Cforce-frame-pointers"

echo "=== cargo fuzz build (image-default nightly toolchain, ASan via RUSTFLAGS) ==="
echo "RUSTFLAGS=$RUSTFLAGS"

cd "$FUZZ_ROOT"

for t in "${FUZZ_TARGETS[@]}"; do
  echo "--- building fuzz target: $t ---"
  # Use the image's DEFAULT toolchain (Dockerfile pins it to the required nightly); a
  # `+toolchain` override would make rustup try to install a different channel into the
  # read-only shared toolchain prefix. `-O` (release w/ opt) + `--debug-assertions` mirrors
  # OSS-Fuzz fuzzing defaults (catch overflow/debug asserts during fuzzing).
  cargo fuzz build -O --debug-assertions "$t"
  # `core/fuzz` is a member of the `core` cargo workspace, so cargo-fuzz writes the binary into
  # the WORKSPACE target dir (core/target/...), NOT core/fuzz/target/.
  bin="$FUZZ_ROOT/target/$TRIPLE/release/$t"
  if [ ! -x "$bin" ]; then
    echo "ERROR: expected fuzz binary not found at $bin" >&2
    exit 1
  fi
  cp "$bin" "/mayhem/$t"
  echo "built /mayhem/$t"
done

echo "build.sh complete:"
ls -la /mayhem/fuzz_from_uri /mayhem/fuzz_path /mayhem/fuzz_reader /mayhem/fuzz_writer 2>&1 || true

# ---------------------------------------------------------------------------------------------
# Build the project's own functional TEST suite too — `core/tests/behavior`, opendal's real
# cross-backend assertion suite (read/write/list/delete/rename/copy/stat/presign/create_dir),
# run against the `fs` backend by mayhem/test.sh. Built here with the project's NORMAL flags (a
# separate, clean, non-sanitized build in its OWN target dir) so test.sh only RUNS it — it never
# compiles. `tests,services-fs` matches the feature set the fuzz crate itself depends on.
# ---------------------------------------------------------------------------------------------
echo "=== building the fs-backend 'behavior' test suite (NORMAL flags, no sanitizer) ==="
cd "$FUZZ_ROOT"
TEST_TARGET_DIR="$FUZZ_ROOT/target-test"
CARGO_TARGET_DIR="$TEST_TARGET_DIR" RUSTFLAGS="" cargo test --features tests,services-fs --test behavior --no-run

testbin="$(find "$TEST_TARGET_DIR/debug/deps" -maxdepth 1 -type f -executable -name 'behavior-*' ! -name '*.d' 2>/dev/null | head -1)"
if [ -z "$testbin" ]; then
  echo "ERROR: compiled 'behavior' test binary not found under $TEST_TARGET_DIR/debug/deps" >&2
  exit 1
fi
cp "$testbin" "$TEST_TARGET_DIR/debug/behavior"
echo "built test suite: $TEST_TARGET_DIR/debug/behavior (from $testbin)"
