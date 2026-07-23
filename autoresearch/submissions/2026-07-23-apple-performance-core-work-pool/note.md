# Size the Apple work pool to performance cores

## Model and harness

Claude Fable 5, operating as lane MERSENNE-B, authored the mechanism, branch,
and submission note, with CODEX ANVIL providing an independent source and
verdict review. The repo-resident `stwo-perf` harness is
`7efe3b1abd72`; the immutable candidate is
`9888ea2a4da0cae00a7b1e525d1d4ebf762ef583` over clean current-main
predecessor `799efe87a9eccd6ae9a2e19c815e82bfbf1d4198`. The claimed result is
Native CPU `wide/time` at S3, measured ReleaseFast on a quiet Apple M4 Max
Studio. The canonical launch preflight bound both SHAs and candidate tree
`b64a60125bc5b18b4dae73a6c94ce5c9f4b6fe29` before timing. Every sample
verified, proof digests matched across arms, and the pinned Rust Stwo oracle
accepted the workload.

## Hypothesis

Static worker spans finish at the speed of their slowest participating core.
On asymmetric Apple CPUs, adding efficiency cores can therefore extend the
critical path even though it raises the logical-core count. A direct worker
sweep showed eight workers beating twelve on an 8P+4E host. Hardcoding eight
would be a transfer error on a larger judge, so the portable mechanism is to
size the process-global pool from the machine's performance-core cluster.

## Changes

On macOS, work-pool initialization queries
`hw.perflevel0.logicalcpu` through `sysctlbyname` and uses that positive value
as the worker count, bounded by the existing maximum. Probe failure, invalid
values, and non-Apple systems fall back to the prior total-logical-CPU query.
The existing `STWO_ZIG_WORKERS` override retains priority, so testing and
operator control are unchanged. No workload, statement, benchmark size, or
proof input is special-cased.

## Results

Native wide proving improves from median 4.588584 ms to 4.408292 ms:
**R=0.962604**, workload 95% CI **[0.954890, 0.968034]**. The deterministic
portfolio CI is **[0.955241, 0.967628]**, clearing theta 0.029290.
Verified-request ratio is 0.965901.

G1-G5 pass, including all **13/13 regression guards** under their 1.05
upper-CI budgets. Proof-byte ratio is exactly 1.0. Peak RSS falls to ratio
0.888580 with upper CI 0.889829. The pinned Rust oracle passes, and every
timed proof digest is byte-identical across arms. The 380-source closure,
three independent Native proof identities, and a forced-worker-count digest
stability check were also green.

## Caveats

Energy increased to ratio 1.010550 with 95% CI [1.007874, 1.028698], within
the named gate but a real measured tradeoff. Several guards are mildly slower
while remaining below budget; the largest upper CIs are Poseidon-10 1.037991,
Plonk-16 1.032914, and state-machine-16 1.032259. Only Native CPU wide is
claimed here; no timing claim is inferred for small, deep, Metal, RISC-V, or a
different Apple topology.

The performance-core query is transfer-safe by construction, but the exact
gain on the locked M5 judge remains for authenticated measurement. This is a
local claimed verdict, not a judged or promoted record. The separate PR6
all-cell matrix, log22 oracle vector, both timing boundaries, and locked-M5
judged verdict remain incomplete. **PR6 Supremacy: not achieved.**
