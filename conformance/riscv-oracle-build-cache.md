# RISC-V Oracle Build Cache

CP-11 executes the pinned Rust Stark-V oracle at commit
`d478f783055aa0d73a93768a433a3c6c31c91d1c`. Recompiling the `cp11_dump`
adapter does not add evidence when every build input is unchanged, so the
release producer maintains a persistent content-addressed binary cache.

The cache is an acceleration layer, not an oracle substitute. Every cache hit
still executes the complete Rust/Zig corpus and compares every CP-11 boundary.
The resulting receipt remains candidate-bound and expires under the existing
release-evidence contract.

## Identity

An entry key is the canonical SHA-256 digest of:

- the exact Stark-V repository URL and commit;
- the clean Git index tree digest;
- every recursively initialized submodule path and commit;
- the root `Cargo.lock` digest;
- the aggregate digest of all checked-in `cp11_dump` overlays and the reviewed
  temporary Cargo manifest transform;
- resolved `rustc --version --verbose` and `cargo --version --verbose` output;
- the executable Rust target, effective Cargo configuration digest, and
  build-affecting Rust/C environment variables;
- the locked release build command; and
- host operating-system and architecture families.

The identity resolves Cargo's effective target and records whether it uses the
host-default or target-qualified output layout; the build selects only
`--bin cp11_dump`. A dirty checkout, missing submodule, wrong commit, malformed
toolchain identity, or unexpected manifest shape aborts before lookup or build.

## Validation

Each entry contains only `manifest.json` and `cp11_dump`. A hit is accepted only
when the strict manifest schema, recomputed identity/key, regular-file status,
executable mode, byte length, and executable SHA-256 all agree. Invalid entries
are never executed; the producer rebuilds and atomically replaces them. The
receipt records hit/miss status, the content key, manifest digest, executable
digest, and the exact validation list for auditability.

The default location is the platform cache directory. Override it for CI or a
shared persistent volume with:

```sh
export STWO_ZIG_RISCV_ORACLE_CACHE_DIR=/persistent/stwo-zig/riscv-oracle
```

The CLI also accepts `--oracle-cache-dir`. Deleting the directory is always
safe; the next CP-11 producer run performs a locked rebuild.

GitHub Actions restores this directory using a pinned `actions/cache` revision.
The outer Actions key identifies the runner platform, Stark-V/toolchain pin, and
helper sources. The repository-owned manifest performs the authoritative inner
validation. CI initializes Stark-V submodules recursively before the gate and
installs the `nightly-2026-01-29` toolchain selected by Stark-V itself.
