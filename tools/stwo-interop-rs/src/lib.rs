//! Library surface for the interop crate (additive; the CLI in main.rs is
//! untouched). Exposes thin prove+verify wrappers over the crate-internal
//! machinery so external crates — the mobile bench — can run the reference
//! Rust stwo prover without reaching pub(crate) items.
//!
//! Returned proof bytes are the canonical wire JSON (`wire.rs`), i.e. the
//! same encoding the parity oracle compares against — digests over these
//! bytes are board-comparable.

mod cli;
mod components;
mod model;
mod profile;
mod proving;
mod statements;
mod traces;
mod wire;

use anyhow::Result;
use stwo::core::fri::FriConfig;
use stwo::core::pcs::PcsConfig;
use stwo::prover::backend::simd::SimdBackend;

fn pcs_config(pow_bits: u32, log_last_layer: u32, log_blowup: u32, n_queries: usize) -> PcsConfig {
    PcsConfig {
        pow_bits,
        fri_config: FriConfig::new(log_last_layer, log_blowup, n_queries),
    }
}

/// Proves wide_fibonacci on the SIMD backend, verifies the proof, and
/// returns the canonical wire-JSON bytes.
pub fn prove_wide_fibonacci(
    log_n_rows: u32,
    sequence_len: u32,
    pow_bits: u32,
    log_last_layer: u32,
    log_blowup: u32,
    n_queries: usize,
) -> Result<Vec<u8>> {
    let config = pcs_config(pow_bits, log_last_layer, log_blowup, n_queries);
    let statement = model::WideFibonacciStatement {
        log_n_rows,
        sequence_len,
    };
    let (_, proof) = proving::wide_fibonacci_prove::<SimdBackend>(
        config,
        statement,
        model::ProveMode::Prove,
        false,
    )?;
    let bytes = serde_json::to_vec(&wire::proof_to_wire(&proof)?)?;
    let restored = wire::wire_to_proof(serde_json::from_slice(&bytes)?)?;
    proving::wide_fibonacci_verify(config, statement, restored)?;
    Ok(bytes)
}

/// Proves the plonk example on the SIMD backend, verifies, returns wire
/// bytes.
pub fn prove_plonk(
    log_n_rows: u32,
    pow_bits: u32,
    log_last_layer: u32,
    log_blowup: u32,
    n_queries: usize,
) -> Result<Vec<u8>> {
    let config = pcs_config(pow_bits, log_last_layer, log_blowup, n_queries);
    let statement = model::PlonkStatement { log_n_rows };
    let (_, proof) =
        proving::plonk_prove::<SimdBackend>(config, statement, model::ProveMode::Prove, false)?;
    let bytes = serde_json::to_vec(&wire::proof_to_wire(&proof)?)?;
    let restored = wire::wire_to_proof(serde_json::from_slice(&bytes)?)?;
    proving::plonk_verify(config, statement, restored)?;
    Ok(bytes)
}
