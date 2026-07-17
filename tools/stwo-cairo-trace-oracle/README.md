# Stwo Cairo Trace Oracle

This isolated Rust tool turns a canonical `STWZCPI/1` adapted Cairo input into
deterministic base-trace checkpoints. It calls the pinned Rust
`CairoClaimGenerator::write_trace::<SimdBackend>` implementation and emits
`stwo-cairo-base-trace-checkpoint-v1` JSON for Zig conformance comparisons.

```sh
cargo run --release --locked -- \
  /private/tmp/cairo-fib-25000.stwzcpi \
  /private/tmp/cairo-fib-25000.base-checkpoint.json
```

Columns retain the committed `CircleEvaluation` value order
(`BitReversedOrder`). Every M31 value is encoded as canonical `u32` little
endian. Column and cumulative component hashes use the domain-separated
SHA-256 contract named in `src/checkpoint.rs`.

The source tuple is explicit because `stwo-cairo@dcd58345` contains an
absolute development patch and does not compile against its manifest's older
Stwo revision. Cargo's exact replacements make the clean build reproducible:

- `stwo-cairo`: `dcd5834565b7a26a27a614e353c9c60109ebc1d9`
- companion Stwo performance revision: `3fe684648ff31e55b71525ad689fab7dfbd88880`
