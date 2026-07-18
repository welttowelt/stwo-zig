# Native Interchange Evidence

`scripts/e2e_interop.py` writes immutable Native Rust/Zig interchange evidence here by default.
The directory is intentionally tracked so a clean formal run can commit the exact artifacts that
were accepted or rejected, rather than a regenerated proxy.

```text
objects/sha256/<prefix>/<artifact-sha256>.json
receipts/native_e2e_interop_receipt_v2/<receipt-sha256>.json
```

Each object preserves the exact artifact bytes passed to a verifier. The receipt binds every
artifact and decoded proof SHA-256, mutation class, rejection class, command and outcome, source
hash, candidate binary, pinned Rust oracle binary, Cargo lockfile, toolchain, platform, and
repository state. Absolute output paths are normalized before receipt hashing, so equivalent runs
produce the same receipt identity.

Generate the complete six-example receipt with:

```console
python3 scripts/e2e_interop.py
```

The gate fails closed if an artifact changes after verification, a content-address collision is
observed, a required mutation is accepted, or a run exceeds its checked-in evidence size bounds.
Do not hand-edit archived objects or receipts.
