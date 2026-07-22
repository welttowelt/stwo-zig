//! Library surface for the interop crate (additive; the CLI in main.rs is
//! untouched). Exposes a bench session over the reference Rust stwo prover
//! for external crates — the mobile bench — with a timing contract that
//! matches the Zig bench's `prove_seconds` region:
//!
//! - twiddles are precomputed ONCE per session and reused across samples
//!   (the Zig session-twiddle analog) — untimed;
//! - trace material generation (`gen_*_trace`, statement-only) — untimed
//!   (the Zig `prepareInput` analog);
//! - the timed region is the channel-coupled transcript machine: config
//!   mix, column conversion + commits, statement mix, and `prove` itself;
//! - wire encoding and verification run OUTSIDE the timed region.
//!
//! Returned proof bytes are the canonical wire JSON (`wire.rs`) — the same
//! encoding the parity oracle compares — so digests are board-comparable
//! (measured equal to the Zig flavor's: see mobile/PARITY.md).

mod cli;
mod components;
mod model;
mod profile;
mod proving;
mod statements;
mod traces;
mod wire;

use anyhow::Result;
use std::time::Instant;
use stwo::core::channel::Blake2sChannel;
use stwo::core::fri::FriConfig;
use stwo::core::pcs::PcsConfig;
use stwo::core::poly::circle::CanonicCoset;
use stwo::core::vcs_lifted::blake2_merkle::Blake2sMerkleChannel;
use stwo::prover::backend::simd::SimdBackend;
use stwo::prover::poly::circle::PolyOps;
use stwo::prover::poly::twiddles::TwiddleTree;
use stwo::prover::{prove, CommitmentSchemeProver};

use model::{PlonkComponent, PlonkStatement, WideFibonacciComponent, WideFibonacciStatement};
use statements::{mix_plonk_statement, mix_wide_fibonacci_statement};
use traces::{backend_eval, gen_plonk_trace, gen_wide_fibonacci_trace};
use wire::proof_to_wire;

fn pcs_config(pow_bits: u32, log_last_layer: u32, log_blowup: u32, n_queries: usize) -> PcsConfig {
    PcsConfig {
        pow_bits,
        fri_config: FriConfig::new(log_last_layer, log_blowup, n_queries),
    }
}

/// Session-scoped twiddle cache, keyed by the (single) domain log size a
/// bench run uses. Mirrors the Zig session's retained twiddle tower.
pub struct BenchSession {
    config: PcsConfig,
    twiddle_log: u32,
    twiddles: TwiddleTree<SimdBackend>,
}

impl BenchSession {
    pub fn new(
        workload_log_n_rows: u32,
        pow_bits: u32,
        log_last_layer: u32,
        log_blowup: u32,
        n_queries: usize,
    ) -> Self {
        let config = pcs_config(pow_bits, log_last_layer, log_blowup, n_queries);
        let twiddle_log = workload_log_n_rows + config.fri_config.log_blowup_factor + 1;
        let twiddles = <SimdBackend as PolyOps>::precompute_twiddles(
            CanonicCoset::new(twiddle_log).circle_domain().half_coset,
        );
        Self {
            config,
            twiddle_log,
            twiddles,
        }
    }

    fn assert_log(&self, log_n_rows: u32) {
        let expect = log_n_rows + self.config.fri_config.log_blowup_factor + 1;
        assert_eq!(
            expect, self.twiddle_log,
            "BenchSession built for a different workload size"
        );
    }
}

/// Proves wide_fibonacci reusing the session twiddles; returns
/// (canonical wire bytes, prove_seconds over the transcript region only).
/// The proof is verified (untimed) before returning.
pub fn bench_wide_fibonacci(
    session: &BenchSession,
    log_n_rows: u32,
    sequence_len: u32,
) -> Result<(Vec<u8>, f64)> {
    session.assert_log(log_n_rows);
    let statement = WideFibonacciStatement {
        log_n_rows,
        sequence_len,
    };
    // Untimed: statement-only trace material (Zig prepareInput analog).
    let trace = gen_wide_fibonacci_trace(log_n_rows, sequence_len)?;

    // Timed: the channel-coupled transcript machine.
    let timer = Instant::now();
    let mut channel = Blake2sChannel::default();
    session.config.mix_into(&mut channel);
    let mut scheme = CommitmentSchemeProver::<SimdBackend, Blake2sMerkleChannel>::new(
        session.config,
        &session.twiddles,
    );
    scheme.set_store_polynomials_coefficients();
    let mut builder = scheme.tree_builder();
    builder.extend_evals(vec![]);
    builder.commit(&mut channel);
    let mut builder = scheme.tree_builder();
    builder.extend_evals(
        trace
            .into_iter()
            .map(|col| backend_eval::<SimdBackend>(log_n_rows, col))
            .collect(),
    );
    builder.commit(&mut channel);
    mix_wide_fibonacci_statement(&mut channel, statement);
    let component = WideFibonacciComponent { statement };
    let proof = prove::<SimdBackend, Blake2sMerkleChannel>(&[&component], &mut channel, scheme)?;
    let prove_seconds = timer.elapsed().as_secs_f64();

    // Untimed: encode + independent verify.
    let bytes = serde_json::to_vec(&proof_to_wire(&proof)?)?;
    let restored = wire::wire_to_proof(serde_json::from_slice(&bytes)?)?;
    proving::wide_fibonacci_verify(session.config, statement, restored)?;
    Ok((bytes, prove_seconds))
}

/// Plonk analog of `bench_wide_fibonacci`, same timing contract.
pub fn bench_plonk(session: &BenchSession, log_n_rows: u32) -> Result<(Vec<u8>, f64)> {
    session.assert_log(log_n_rows);
    let statement = PlonkStatement { log_n_rows };
    let (preprocessed, main) = gen_plonk_trace(log_n_rows)?;

    let timer = Instant::now();
    let mut channel = Blake2sChannel::default();
    session.config.mix_into(&mut channel);
    let mut scheme = CommitmentSchemeProver::<SimdBackend, Blake2sMerkleChannel>::new(
        session.config,
        &session.twiddles,
    );
    let mut builder = scheme.tree_builder();
    builder.extend_evals(
        preprocessed
            .into_iter()
            .map(|col| backend_eval::<SimdBackend>(log_n_rows, col))
            .collect(),
    );
    builder.commit(&mut channel);
    let mut builder = scheme.tree_builder();
    builder.extend_evals(
        main.into_iter()
            .map(|col| backend_eval::<SimdBackend>(log_n_rows, col))
            .collect(),
    );
    builder.commit(&mut channel);
    mix_plonk_statement(&mut channel, statement);
    let component = PlonkComponent { statement };
    let proof = prove::<SimdBackend, Blake2sMerkleChannel>(&[&component], &mut channel, scheme)?;
    let prove_seconds = timer.elapsed().as_secs_f64();

    let bytes = serde_json::to_vec(&proof_to_wire(&proof)?)?;
    let restored = wire::wire_to_proof(serde_json::from_slice(&bytes)?)?;
    proving::plonk_verify(session.config, statement, restored)?;
    Ok((bytes, prove_seconds))
}
