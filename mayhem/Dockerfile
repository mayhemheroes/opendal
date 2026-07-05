# syntax=docker/dockerfile:1.7
#
# Commit-image Dockerfile — apache/opendal (Rust / cargo-fuzz). Builds ON TOP of the org
# base image (ghcr.io/mayhemheroes/base), adding a pinned Rust nightly + cargo-fuzz under
# /opt/toolchains/rust, then runs mayhem/build.sh (+ mayhem/test.sh) the same way the
# upstream OSS-Fuzz project (projects/opendal/) does: `cd core && cargo fuzz build`.
#
# opendal is a workspace-of-many-crates data-access layer; the actual Cargo *workspace
# root* lives at `core/` (core/Cargo.toml declares `[workspace]`; the repo has no root
# Cargo.toml). The fuzz crate is `core/fuzz` (package `opendal-fuzz`), depending on the
# facade crate `opendal` (= core/Cargo.toml's package) with features `tests,services-fs`
# (default features, incl. the reqwest/rustls HTTP transport, stay ON — same as upstream's
# unmodified build.sh) so `opendal::tests::init_test_service`/`TEST_RUNTIME` are available.
#
# Build (from the repo root, on the `mayhem` branch):
#   DOCKER_BUILDKIT=1 docker build -f mayhem/Dockerfile \
#       --build-arg COMMIT=$(git rev-parse HEAD) \
#       [--build-arg SOURCE_DATE_EPOCH=$(date +%s)] -t opendal-commit:test .

FROM ghcr.io/mayhemheroes/base:20260621

ARG COMMIT
ARG REPO_URL
# SOURCE_DATE_EPOCH stays an ARG (available to build.sh); never bake it as ENV — an empty
# value breaks clang. build.sh unsets it when empty.
ARG SOURCE_DATE_EPOCH

# Sanitizer override: the base exports SANITIZER_FLAGS (ASan+UBSan, halting) as the default,
# but cargo-fuzz drives Rust instrumentation via RUSTFLAGS (-Zsanitizer=address), NOT
# $SANITIZER_FLAGS/$CFLAGS (rustc ignores clang flags). Declared here for parity; build.sh
# wires ASan into RUSTFLAGS the cargo-fuzz way.
ARG SANITIZER_FLAGS
ARG MAYHEM_JOBS=

# Pin the nightly toolchain (cargo-fuzz needs nightly for `-Z` flags / -Zsanitizer=address).
# opendal is edition 2024 / rust-version 1.91 (core/Cargo.toml workspace.package) — pick a
# nightly dated after that MSRV shipped.
ARG RUST_TOOLCHAIN=nightly-2025-12-01
ARG CARGO_FUZZ_VERSION=0.13.1

# Shared Rust install: CARGO_HOME/RUSTUP_HOME under /opt/toolchains/rust, world-readable, so
# the non-root `mayhem` user can invoke cargo/rustc/cargo-fuzz without owning the toolchain,
# and the PATCH tier's air-gapped re-run finds the SAME absolute cache regardless of $HOME.
ENV RUSTUP_HOME=/opt/toolchains/rust/rustup \
    CARGO_HOME=/opt/toolchains/rust/cargo \
    PATH=/opt/toolchains/rust/cargo/bin:$PATH

USER root
RUN set -eux; \
    mkdir -p "$RUSTUP_HOME" "$CARGO_HOME"; \
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --no-modify-path --profile minimal --default-toolchain "$RUST_TOOLCHAIN"; \
    rustup component add rust-src --toolchain "$RUST_TOOLCHAIN"; \
    cargo install cargo-fuzz --version "$CARGO_FUZZ_VERSION" --locked; \
    # The non-root `mayhem` user runs `cargo fuzz build`, which WRITES into CARGO_HOME
    # (registry cache, git checkouts). Toolchain dirs stay read-only; the cargo home must be
    # group/other writable so the build can populate/refresh the registry (build image, not a
    # hardened runtime).
    chmod -R a+rX /opt/toolchains/rust; \
    mkdir -p "$CARGO_HOME/registry" "$CARGO_HOME/git" && chmod -R a+rwX "$CARGO_HOME/registry" "$CARGO_HOME/git"; \
    # rustup's cargo/rustc/cargo-fuzz shims are proxy binaries: EVERY invocation (not just
    # `rustup` subcommands) goes through rustup's Cfg, which writes scratch files under
    # $RUSTUP_HOME/tmp (settings-lock / atomic-write temp files) even when just dispatching to
    # the pinned toolchain. Root-only ownership here works in some container environments (the
    # dir gets created — and thus usable — as a side effect of the root-phase installs above)
    # but is not guaranteed everywhere (e.g. a fresh overlay/user-namespace mapping in CI can
    # still deny writes into an a+rX-only dir): make $RUSTUP_HOME/tmp explicitly writable by
    # the non-root `mayhem` user so every later `cargo`/`rustc`/`cargo fuzz` call — from this
    # RUN, from `mayhem/build.sh`, and from `mayhem/test.sh` — can create its scratch files.
    mkdir -p "$RUSTUP_HOME/tmp" && chmod -R a+rwX "$RUSTUP_HOME/tmp"; \
    rustc --version; cargo --version; cargo fuzz --version

# opendal ships its own `rust-toolchain.toml` pinning `channel = "stable"`. rustup's
# toolchain-FILE auto-detection would otherwise override our installed default and try to
# fetch/sync the "stable" channel at build time — which fails, since only the registry/git
# dirs are writable under the (mostly read-only) shared toolchain prefix. RUSTUP_TOOLCHAIN
# pins the resolved toolchain explicitly, beating the file-based override; set it only AFTER
# the toolchain is installed (an earlier ENV would confuse rustup-init itself).
ENV RUSTUP_TOOLCHAIN=${RUST_TOOLCHAIN}

# DWARF<4 gate workaround for Rust/cargo-fuzz (§6.2 item 10).
# Problem: cargo-fuzz links the Rust nightly ASan runtime archive
# (librustc-nightly_rt.asan.a) via --whole-archive, and that archive's objects (compiled by
# a recent clang with DWARF v5) land FIRST in .debug_info before any user/std CUs. The
# -Z dwarf-version=3 RUSTFLAG only controls rustc's own CUs — it cannot retroactively lower
# the precompiled runtime. Solution (the Go-canary trick, adapted for Rust): compile a tiny
# stub with clang -gdwarf-3 and inject it as the FIRST object in every link via a cc-wrapper
# linker script (-Clinker=...). The wrapper prepends anchor.o to the linker command; since
# .debug_info CUs appear in linker-argument order, anchor.o's DWARF3 CU becomes offset 0 —
# the one verify-repo's -m1 reads.
RUN set -eux; \
    mkdir -p /opt/mayhem-dwarf3-anchor; \
    printf 'void __mayhem_dwarf3_anchor(void) __attribute__((visibility("hidden"),used));\nvoid __mayhem_dwarf3_anchor(void) {}\n' \
      > /opt/mayhem-dwarf3-anchor/anchor.c; \
    clang -g -gdwarf-3 -c /opt/mayhem-dwarf3-anchor/anchor.c \
      -o /opt/mayhem-dwarf3-anchor/anchor.o; \
    printf '#!/bin/bash\nexec cc /opt/mayhem-dwarf3-anchor/anchor.o "$@"\n' \
      > /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    chmod +x /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    chmod a+rX /opt/mayhem-dwarf3-anchor /opt/mayhem-dwarf3-anchor/anchor.o \
               /opt/mayhem-dwarf3-anchor/cc-wrapper.sh; \
    echo "DWARF3 anchor ready: $(readelf --debug-dump=info /opt/mayhem-dwarf3-anchor/anchor.o | grep -m1 Version:)"

USER mayhem

# Source enters from the build CONTEXT (the CI checkout): the FULL repo (incl. .git history)
# is copied to /mayhem as `mayhem`; build.sh builds in place.
WORKDIR /mayhem
COPY --chown=2000:2000 . /mayhem

RUN bash mayhem/build.sh

# Run opendal-core's own test suite (the workspace `core` crate's unit + behavior tests) at
# build time; a failing suite fails the image build.
RUN if [ -f mayhem/test.sh ]; then bash mayhem/test.sh; else echo "no mayhem/test.sh"; fi

LABEL org.opencontainers.image.source="${REPO_URL}" \
      org.opencontainers.image.revision="${COMMIT}" \
      rlenv.tier="commit" \
      rlenv.source_date_epoch="${SOURCE_DATE_EPOCH}" \
      rlenv.user="mayhem"

USER mayhem
WORKDIR /mayhem
