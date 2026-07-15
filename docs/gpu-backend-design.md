# GPU Backend Design Document — stwo-zig STARK Prover

## Executive Summary

This document captures the design principles, memory architecture, and implementation strategy for the stwo-zig GPU (CUDA) proving backend. The learnings are derived from building a production Ethereum block proving pipeline end-to-end: RISC-V execution → trace generation → 1,057-column STARK prove → verify, including accelerated precompile syscalls (keccak256, ecrecover, sha256) that reduced per-block cycle counts by 37x.

The core insight: **peak VRAM equals column storage**. The entire proving pipeline — FFT, Merkle commitment, quotient evaluation, FRI folding, decommitment — runs within the initial column allocation plus a small (~100 MB) workspace pool. No dynamic GPU allocation is needed during proving.

---

## Workload Profile: Real Ethereum Blocks

| Block | Era | Txs | VM Cycles | Columns | Est. Peak RAM |
|-------|-----|-----|-----------|---------|---------------|
| 46147 | Frontier (2015) | 1 | 340K (w/ precompiles) | 1,057 | ~500 MB |
| 22377000 | Cancun (2025) | 158 | 19.4M (w/ precompiles) | 1,057 | ~4.6 GB |
| Full mainnet (est.) | Cancun | 200+ | 50-100M (w/ precompiles) | 1,057 | ~8-12 GB |

The column count is **fixed at 1,057** (567 opcode-family + 490 infrastructure) regardless of block complexity. What scales with cycle count is the `log_size` per opcode family — more instructions in a family means larger trace tables for that family's component.

Without precompile acceleration, the same blocks are 37x more expensive (12.7M cycles for a single transaction). Precompiles are not optional for production viability.

---

## Phase 1: Column Allocation and Trace Upload

### What Happens

The RISC-V runner executes the guest program on the CPU, producing an execution trace. The trace is split by opcode family (16 families), and each family's columns are allocated and filled with M31 field elements. Infrastructure columns (program ROM, memory checks, clock updates, register state chains, Poseidon2 Merkle, multiplicities) are generated from the state chain tracker.

All 1,057 columns are then uploaded to GPU VRAM in a single batch transfer.

### Memory Profile

Column storage dominates total memory at ~95% of peak:

```
Per-column: 2^log_size elements × 4 bytes (M31)

Example for 19M-cycle block:
  - 16 opcode families, log_sizes ranging from 10 to 20
  - Infrastructure columns at log_sizes 13-17
  - Largest families (load_store, base_alu_reg): log_size ~18-20
  - Smallest families (div, mulh): log_size ~10-12

Aggregate: 1,057 columns × avg(2^16) elements × 4 bytes ≈ 280 MB
Peak (all at log_size=20): 1,057 × 2^20 × 4 = 4.4 GB
```

### GPU Design

```
Host                                    GPU
────                                    ───
Trace generated (CPU, ~2s)
  ↓
Allocate VRAM pool:
  per_family_columns[16] ──────────→  VRAM: contiguous M31 arrays
  infra_columns[490]     ──────────→  VRAM: contiguous M31 arrays
                                      Total: one cudaMalloc per family
```

**Allocation strategy:** Pre-allocate all column VRAM at the start of proving. Use a single `cudaMalloc` per opcode family (all columns for that family in one contiguous block). This eliminates per-column allocation overhead and enables coalesced memory access patterns.

**Upload strategy:** Use pinned host memory (`cudaMallocHost`) for the trace data, then `cudaMemcpyAsync` with overlapping transfers across families. Families with different log_sizes can overlap upload with compute on already-uploaded families.

**Key constraint:** The `SecureColumnByCoords` type stores QM31 as 4 interleaved M31 arrays in a single contiguous allocation. This layout is GPU-optimal — 4 coalesced reads per QM31 element.

### What NOT to Do

- Do not allocate columns individually — the overhead of 1,057 separate `cudaMalloc` calls is significant
- Do not use managed memory (`cudaMallocManaged`) — explicit transfers are faster and predictable
- Do not keep trace data on host after upload — free host-side column arrays immediately to reduce peak host RAM

---

## Phase 2: Batched FFT (In-Place)

### What Happens

Each column is transformed from evaluation form to coefficient form (or vice versa) via the Circle FFT. The FFT operates **in-place** on the column buffer using precomputed twiddle factors. No temporary buffer is needed per FFT.

The twiddle factors are domain-specific — all columns at the same `log_size` share the same twiddle tree.

### Memory Profile

```
FFT workspace per column: 0 bytes (in-place)
Twiddle tree per log_size: ~2 × 2^log_size × 4 bytes
  - log_size=18: 2 × 262,144 × 4 = 2.1 MB
  - log_size=20: 2 × 1,048,576 × 4 = 8.4 MB

Total twiddle cache (all log_sizes): ~20 MB
```

**Peak memory delta from Phase 1:** +20 MB (twiddle cache only)

### GPU Design

**Batched execution:** Group all columns by `log_size`. Launch one batched FFT kernel per group. With 16 opcode families and infrastructure, there are typically 8-12 distinct log_sizes.

```
Group by log_size:
  log_size=18: 200 columns → 1 kernel launch, 200 FFTs in parallel
  log_size=16: 150 columns → 1 kernel launch, 150 FFTs in parallel
  log_size=14: 100 columns → 1 kernel launch
  ...

Total kernel launches: ~10 (not 1,057)
```

**Twiddle memory:** Precompute all needed twiddle trees and store in a persistent VRAM buffer. The largest tree (log_size=20) is 8.4 MB — trivial. Store twiddles in GPU constant memory or L2-resident buffer for fast random access.

**Butterfly pipeline:** The CPU implementation uses a 4-way interleaved butterfly to hide pipeline latency. On GPU, this maps to warp-level parallelism — each warp handles one butterfly stage, with shared memory for the twiddle lookups within the stage.

**The FFI already has this:** `ntt_n2b_columns()` (plural) accepts multiple columns. The CUDA kernel batches them internally.

### What NOT to Do

- Do not FFT columns one at a time — batching amortizes kernel launch overhead
- Do not allocate temporary FFT buffers — the algorithm is in-place
- Do not recompute twiddles per column — cache them by log_size

---

## Phase 3: Merkle Commitment (Parallel Hashing)

### What Happens

The FFT'd columns are committed via a Merkle tree. Each leaf hashes a group of column values at the same domain position. The tree is built bottom-up, with each layer halving the number of nodes.

Three separate Merkle trees are committed:
- **Tree 0 (preprocessed):** Bitwise and range-check tables (fixed, can be precomputed)
- **Tree 1 (main trace):** All 1,057 opcode + infrastructure columns
- **Tree 2 (interaction):** LogUp interaction columns (~832 columns)

### Memory Profile

```
Merkle tree layers (Blake2s, 32-byte hashes):
  Leaf layer: max(domain_sizes) nodes × 32 bytes
  Layer i: nodes/2^i × 32 bytes
  Total: ~2 × leaf_count × 32 bytes

For log_size=20 domain: 2 × 2^20 × 32 = 64 MB per tree
Three trees: ~192 MB total hash storage
```

**Peak memory delta from Phase 2:** +192 MB (hash layers)

### GPU Design

**Compute profile:** Merkle hashing is **bandwidth-bound** on CPU but **compute-bound** on GPU. GPU Blake2s/Poseidon2 kernels can hash millions of leaves per second.

```
Hashing kernel:
  - One thread per leaf position
  - Each thread reads from 1,057 column values at that position
  - Computes Blake2s(col0[pos] || col1[pos] || ... || col1056[pos])
  - Writes 32-byte hash to leaf layer buffer

Layer reduction kernel:
  - One thread per pair of nodes
  - hash(left || right) → parent
  - Halves nodes per layer until root
```

**Tile processing:** Process leaves in tiles of 256 to maintain L2 cache residency. Each tile reads 256 positions across all 1,057 columns = 256 × 1,057 × 4 = 1.05 MB per tile — fits in GPU L2.

**Poseidon2 vs Blake2s:** For the algebraic STARK context, Poseidon2 (width-16 over M31) is significantly faster on GPU than Blake2s. The infrastructure already has Poseidon2 support in both the prover and the FFI (`poseidon252_commit_on_first_layer()`). **Recommend Poseidon2 as default hash for GPU backend.**

**Hash layer storage:** Allocate all layers in a single contiguous VRAM buffer. The total size is predictable and small relative to column storage.

### What NOT to Do

- Do not download columns to host for hashing — hash on-device
- Do not use Blake2s on GPU when Poseidon2 is available — algebraic hashes are 10-100x faster in this context
- Do not build the tree layer-by-layer with separate kernel launches — fuse leaf hashing and first few layers into a single kernel

---

## Phase 4: Quotient Evaluation (Streaming)

### What Happens

The quotient computation evaluates AIR constraints over a lifted (blowup) domain and accumulates them with a random coefficient. This is the core STARK soundness step — it checks that the trace polynomials satisfy the constraint system.

For each position in the domain, all active columns are read, constraints evaluated, and a quotient value accumulated into a `SecureColumnByCoords` (4 M31 arrays).

### Memory Profile

```
Output: SecureColumnByCoords at composition log_size
  = 4 × 2^composition_log_size × 4 bytes
  = 4 × 2^19 × 4 = 8 MB (typical)

Materialized lifting (AVOIDED):
  400 active columns × 2^20 × 4 = 1.6 GB  ← DO NOT DO THIS

Streaming approach:
  Per-position workspace: ~4 KB (column contribution accumulators)
  Total extra memory: ~0 bytes (reads directly from committed columns)
```

**Peak memory delta from Phase 3:** +8 MB (quotient output)

### GPU Design

**Streaming is mandatory.** The CPU prover already uses streaming for 400+ active columns because materialization would require 1.6+ GB. On GPU, the same principle applies but is even more important — VRAM is precious.

```
Streaming quotient kernel:
  - One thread per domain position
  - For each position:
      1. Read column values from already-committed VRAM columns
      2. Compute lifted values on-the-fly (bit-manipulation of position index)
      3. Evaluate all constraint numerators
      4. Accumulate with random coefficient
      5. Write single QM31 result to output buffer

  Thread count: 2^composition_log_size (e.g., 524,288)
  Per-thread registers: ~50 (column indices, accumulators, random coeff)
  Shared memory: random coefficient + constraint parameters
```

**Column access pattern:** Each thread reads from all 1,057 columns at a computed index. The index depends on the column's log_size relative to the composition domain:
```
For column with log_size < composition_log_size:
  index = ((position >> shift) << 1) | (position & 1)  // lifting formula
For column with log_size == composition_log_size:
  index = position  // direct read
```

This is a **gather pattern** — each thread reads from different offsets across columns. GPU global memory coalescing helps when adjacent threads read adjacent positions (which they do for direct-size columns).

**Constraint evaluation:** All 1,057 columns contribute to the quotient through their respective component constraints. The constraint structure is known at compile time (`comptime B: type` pattern), so the GPU kernel can be specialized per component.

### What NOT to Do

- Do not materialize lifted columns — this doubles VRAM usage for no benefit
- Do not use one thread per column — use one thread per position (better parallelism)
- Do not store intermediate constraint values — accumulate in registers

---

## Phase 5: FRI Folding (Shrinking, In-Place)

### What Happens

The FRI (Fast Reed-Solomon IOP) protocol folds the quotient polynomial through multiple rounds, each halving the domain size. With `fold_step=1`, each round applies a single fold; with `fold_step=4`, each round folds 4 times (16x domain reduction per round).

Each fold reads values from the current layer and writes to a new layer half the size. The folding uses the FRI random challenge (from the verifier/channel).

### Memory Profile

```
With fold_step=1 from composition_log_size=19:
  Layer 0: 2^19 QM31 = 2^19 × 16 = 8 MB
  Layer 1: 2^18 QM31 = 4 MB
  Layer 2: 2^17 QM31 = 2 MB
  ...
  Layer 19: 1 QM31 = 16 bytes

  Total (geometric sum): ~16 MB

With fold_step=4:
  Layer 0: 2^19 QM31 = 8 MB
  Layer 1: 2^15 QM31 = 512 KB
  Layer 2: 2^11 QM31 = 32 KB
  ...

  Total: ~8.5 MB, and only 5 layers instead of 19
```

**Memory delta:** FRI layers shrink rapidly. Peak is the first layer. Can reuse the quotient output buffer for layer 0, so **net delta is near zero**.

### GPU Design

**Shrinking pipeline:** Each FRI fold is a kernel that reads N elements and writes N/2 elements. The first fold is the most parallel (2^18 threads). Subsequent folds have exponentially fewer threads.

```
FRI fold pipeline:
  Layer 0 → Layer 1: 2^18 threads, each folding 2 QM31s → 1
  Layer 1 → Layer 2: 2^17 threads
  ...
  Layer 15+: transfer to CPU (too small for GPU overhead)
```

**In-place optimization:** With fold_step=4, the output of each round is 16x smaller. Allocate the output in the same VRAM region as the input (at an offset). After folding, the first 15/16ths of the buffer is dead — no explicit free needed.

**fold_step=4 is strongly recommended for GPU.** It reduces the number of kernel launches from ~19 to ~5, and each kernel does 4x more compute per element — better GPU utilization.

**Commitment during FRI:** Each FRI layer (except the last) is committed via a Merkle tree. These trees are small (the domain shrinks rapidly), so they can be hashed on GPU with the same kernel as Phase 3.

### What NOT to Do

- Do not launch separate kernels for each fold_step=1 fold — use fold_step=4 to batch
- Do not keep all FRI layers in VRAM simultaneously — free each layer after the next layer's commitment
- Do not transfer small FRI layers to host for folding — the transfer latency exceeds CPU compute time for layers < 2^12

---

## Phase 6: Decommitment (Sparse Reads)

### What Happens

The verifier sends query positions (typically 3-70 positions depending on security level). For each query, the prover must provide:
1. Column values at the query positions
2. Merkle authentication paths from leaves to root

This requires reading specific column values and computing Merkle proofs.

### Memory Profile

```
Per query:
  - 1,057 column values × 4 bytes = 4.2 KB per position
  - Merkle path: ~20 hashes × 32 bytes = 640 bytes per query

For 70 queries (production security):
  - Column reads: 70 × 4.2 KB = 294 KB
  - Merkle paths: 70 × 640 bytes = 44.8 KB
  - Total download: ~340 KB
```

**Memory delta:** Negligible — this is a sparse read phase.

### GPU Design

**Sparse gather:** Launch one thread per (query_position, column_index) pair. Each thread reads one M31 value from VRAM and writes to a compact output buffer.

```
Decommit kernel:
  Total threads: n_queries × n_columns = 70 × 1,057 = 73,990
  Each thread: output[q * n_cols + c] = columns[c][query_positions[q]]

  Then: cudaMemcpy output buffer → host (73,990 × 4 = 296 KB)
```

**Merkle proof computation:** For each query, traverse the Merkle tree from leaf to root, collecting sibling hashes. This is a sequential traversal per query but independent across queries — launch 70 threads, each walking the tree.

**This is the only phase that downloads data from GPU to host.** The download is tiny (~340 KB) relative to the upload in Phase 1.

### What NOT to Do

- Do not download entire columns for decommitment — only query positions are needed
- Do not recompute Merkle trees — keep the committed layers in VRAM from Phase 3
- Do not serialize query processing — all 70 queries can be processed in parallel

---

## Phase 7: Proof Assembly and Verification (CPU)

### What Happens

The host assembles the proof from:
- Merkle roots (from Phase 3)
- FRI layer commitments (from Phase 5)
- Decommitment values and paths (from Phase 6)
- Last FRI layer coefficients

Verification runs entirely on CPU and is fast (~95ms for a real block).

### Memory Profile

```
Proof size (typical):
  - 3 Merkle roots: 96 bytes
  - FRI commitments: ~5 roots = 160 bytes
  - Decommitment values: ~300 KB
  - Merkle paths: ~50 KB
  - Last layer: ~64 bytes
  - Total proof: ~400 KB
```

### GPU Design

**No GPU involvement.** Proof assembly and verification are pure CPU operations. The GPU has already finished its work in Phase 6.

**GPU cleanup:** After Phase 6, free all VRAM:
```zig
// Single cudaFree for each family's column pool
for (family_pools) |pool| pool.free();
// Free twiddle cache, Merkle layers, FRI layers
workspace_pool.free();
```

### Verification

Verification is inherently sequential (Fiat-Shamir transcript replay). It runs on CPU at ~95ms for a full Ethereum block. No GPU acceleration needed or beneficial.

---

## Cross-Phase Architecture Summary

```
Phase    Operation              VRAM Delta    Cumulative    GPU Utilization
─────    ─────────              ──────────    ──────────    ───────────────
  1      Column upload          +4.4 GB       4.4 GB        PCIe bandwidth
  2      Batched FFT            +20 MB        4.42 GB       Compute-bound ★★★
  3      Merkle commit          +192 MB       4.6 GB        Compute-bound ★★★
  4      Quotient (streaming)   +8 MB         4.6 GB        Bandwidth-bound ★★
  5      FRI folding            ~0 (reuse)    4.6 GB        Compute-bound ★★
  6      Decommitment           ~0 (reads)    4.6 GB        Sparse reads ★
  7      Proof assembly (CPU)   -4.6 GB       0             N/A
```

**Peak VRAM: 4.6 GB** — achieved at Phase 3 and sustained through Phase 6.

**Total GPU↔Host transfers:**
- Upload: ~4.4 GB (once, Phase 1)
- Download: ~340 KB (once, Phase 6)

**Ratio: 13,000:1 compute-to-transfer.** The GPU backend is not PCIe-bottlenecked.

---

## Multi-GPU Partitioning Strategy

The 16 opcode families have independent trace tables that can be processed in parallel across GPUs.

```
4-GPU Configuration:
  GPU 0: Families 0-3   (base_alu_reg, base_alu_imm, shifts_reg, shifts_imm)
         + preprocessed tables (tree 0)
  GPU 1: Families 4-7   (lt_reg, lt_imm, branch_eq, branch_lt)
  GPU 2: Families 8-11  (lui, auipc, jalr, jal)
  GPU 3: Families 12-15 (load_store, mul, mulh, div)
         + infrastructure (program, memory, clock, Poseidon2, Merkle)

Cross-GPU synchronization points:
  - After Phase 3: Exchange Merkle roots (96 bytes per tree per GPU)
  - After Phase 5: Exchange FRI commitments
  - After Phase 6: Gather decommitment values

All other phases are fully independent per GPU.
```

**Load balancing:** The `load_store` family is typically the largest (most memory instructions). Place it on the GPU with the most VRAM, paired with the smallest families to balance.

---

## Precompile Impact on GPU Sizing

Accelerated syscalls (keccak256, ecrecover, sha256) run on the host CPU during guest execution. They reduce the trace size before it ever reaches the GPU:

```
Without precompiles (1 tx block):  12,706,246 cycles → log_size ~24
With precompiles (1 tx block):        339,715 cycles → log_size ~19

VRAM impact:
  Without: 1,057 × 2^24 × 4 = 70 GB  (needs multi-H100)
  With:    1,057 × 2^19 × 4 = 2.2 GB  (fits RTX 4090)
```

**Precompiles are not optional for GPU viability.** Without them, even a single-transaction block exceeds consumer GPU VRAM. With them, full mainnet blocks fit on a 24 GB card.

---

## Hardware Recommendations

| GPU | VRAM | Bandwidth | Target Workload |
|-----|------|-----------|-----------------|
| RTX 4090 | 24 GB | 1,008 GB/s | 1-50 tx blocks with precompiles |
| A100 | 80 GB | 2,039 GB/s | Full mainnet blocks |
| H100 | 80 GB | 3,350 GB/s | Full mainnet blocks, production |
| Multi-4090 (4x) | 96 GB | 4,032 GB/s | Full mainnet, consumer hardware |

**Minimum viable:** Single RTX 4090 with precompile acceleration.
**Production target:** Single H100 or 4x RTX 4090 with family-level partitioning.

---

## Implementation Priority

| Priority | Kernel | Impact | Complexity |
|----------|--------|--------|------------|
| 1 | Batched FFT | Core bottleneck | Medium (existing FFI) |
| 2 | Parallel Merkle hash (Poseidon2) | Second bottleneck | Medium (existing FFI) |
| 3 | Streaming quotient evaluation | Largest parallelism | High (constraint-specific) |
| 4 | FRI folding (fold_step=4) | Moderate speedup | Low (simple kernels) |
| 5 | Sparse decommitment gather | Small but necessary | Low |
| 6 | Multi-GPU partitioning | Linear scaling | Medium (DeviceContext exists) |

The FFI layer (`src/backends/cuda/ffi.zig`) already declares all 68 kernel entry points. The GPU kernels in stwo-cuda implement the compute. The remaining work is **orchestration** — wiring the 7 phases together with the correct memory management and kernel launch parameters.

---

## Key Files

| File | Role in GPU Backend |
|------|-------------------|
| `src/backends/cuda/mod.zig` | CudaBackend — all kernel dispatch |
| `src/backends/cuda/ffi.zig` | 68 extern "C" declarations to stwo-cuda |
| `src/backends/cuda/device_column.zig` | DeviceColumn(F) — VRAM pointer wrapper |
| `src/backends/cuda/device_context.zig` | Multi-GPU device management |
| `src/prover/prove.zig` | Proving orchestration (`comptime B: type`) |
| `src/prover/secure_column.zig` | QM31 column layout (4 × M31 contiguous) |
| `src/prover/poly/circle/poly.zig` | Circle FFT algorithm (butterfly pipeline) |
| `src/prover/pcs/quotient_ops.zig` | Quotient evaluation (streaming threshold) |
| `src/prover/vcs_lifted/prover.zig` | Merkle tree construction |
| `src/core/fri.zig` | FRI protocol configuration |
| `src/prover/fft_pool.zig` | Bump allocator pattern (reusable for GPU workspace) |
| `src/prover/mmap_alloc.zig` | Memory-mapped allocation with OS hints |
| `src/prover/work_pool.zig` | Thread pool (CPU-side orchestration) |
