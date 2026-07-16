use std::env;
use std::fs;
use std::path::PathBuf;
use std::time::Instant;

use itertools::Itertools;
use num_traits::{One, Zero};
use serde::Serialize;
use stwo::core::air::Component;
use stwo::core::channel::Blake2sM31Channel;
use stwo::core::fields::m31::BaseField;
use stwo::core::fields::qm31::SecureField;
use stwo::core::pcs::{CommitmentSchemeVerifier, PcsConfig};
use stwo::core::poly::circle::CanonicCoset;
use stwo::core::vcs_lifted::blake2_merkle::Blake2sM31MerkleChannel;
use stwo::core::verifier::verify;
use stwo::prover::backend::simd::SimdBackend;
use stwo::prover::poly::circle::PolyOps;
use stwo::prover::{prove, CommitmentSchemeProver};
use stwo_backend_metal::MetalBackend;
use stwo_constraint_framework::{FrameworkComponent, TraceLocationAllocator};
use stwo_examples::wide_fibonacci::{generate_trace, FibInput, WideFibonacciEval};

const N_COLUMNS: usize = 100;

#[derive(Serialize)]
struct Report {
    schema: &'static str,
    backend: String,
    log_n_instances: u32,
    instances: u64,
    n_columns: usize,
    warmups: usize,
    samples: usize,
    rayon_threads: usize,
    prove_samples_ms: Vec<f64>,
    verify_samples_ms: Vec<f64>,
    total_samples_ms: Vec<f64>,
    prove_median_ms: f64,
    verify_median_ms: f64,
    total_median_ms: f64,
    row_mhz: f64,
    proof_size_bytes: usize,
    commitments: usize,
    security_bits: u32,
    fri_queries: usize,
    pow_bits: u32,
    all_verified: bool,
}

struct Sample {
    prove_ms: f64,
    verify_ms: f64,
    proof_size_bytes: usize,
    commitments: usize,
    security_bits: u32,
    fri_queries: usize,
    pow_bits: u32,
}

fn test_inputs(log_n_instances: u32) -> Vec<FibInput> {
    (0..1u64 << log_n_instances)
        .map(|i| FibInput {
            a: BaseField::one(),
            b: BaseField::from_u32_unchecked(i as u32),
        })
        .collect_vec()
}

macro_rules! run_sample {
    ($backend:ty, $inputs:expr, $log_n_instances:expr) => {{
        let config = PcsConfig::default();
        let prove_start = Instant::now();
        let twiddles = <$backend>::precompute_twiddles(
            CanonicCoset::new(
                $log_n_instances + 1 + config.fri_config.log_blowup_factor,
            )
            .circle_domain()
            .half_coset,
        );
        let prover_channel = &mut Blake2sM31Channel::default();
        let mut commitment_scheme =
            CommitmentSchemeProver::<$backend, Blake2sM31MerkleChannel>::new(
                config,
                &twiddles,
            );

        let mut tree_builder = commitment_scheme.tree_builder();
        tree_builder.extend_evals(vec![]);
        tree_builder.commit(prover_channel);

        let trace = generate_trace::<N_COLUMNS, $backend>($inputs);
        let mut tree_builder = commitment_scheme.tree_builder();
        tree_builder.extend_evals(trace);
        tree_builder.commit(prover_channel);

        let component = FrameworkComponent::new(
            &mut TraceLocationAllocator::default(),
            WideFibonacciEval::<N_COLUMNS> {
                log_n_rows: $log_n_instances,
            },
            SecureField::zero(),
        );
        let proof = prove::<$backend, Blake2sM31MerkleChannel>(
            &[&component],
            prover_channel,
            commitment_scheme,
        )
        .expect("proof generation must succeed");
        let prove_ms = prove_start.elapsed().as_secs_f64() * 1000.0;

        let verify_start = Instant::now();
        let verifier_channel = &mut Blake2sM31Channel::default();
        let commitment_scheme_verifier =
            &mut CommitmentSchemeVerifier::<Blake2sM31MerkleChannel>::new(proof.config);
        let sizes = component.trace_log_degree_bounds();
        commitment_scheme_verifier.commit(proof.commitments[0], &sizes[0], verifier_channel);
        commitment_scheme_verifier.commit(proof.commitments[1], &sizes[1], verifier_channel);
        verify(
            &[&component as &dyn Component],
            verifier_channel,
            commitment_scheme_verifier,
            proof.clone(),
        )
        .expect("proof verification must succeed");
        let verify_ms = verify_start.elapsed().as_secs_f64() * 1000.0;

        Sample {
            prove_ms,
            verify_ms,
            proof_size_bytes: proof.size_estimate(),
            commitments: proof.commitments.len(),
            security_bits: proof.config.security_bits(),
            fri_queries: proof.config.fri_config.n_queries,
            pow_bits: proof.config.pow_bits,
        }
    }};
}

fn median(values: &[f64]) -> f64 {
    let mut ordered = values.to_vec();
    ordered.sort_by(|a, b| a.total_cmp(b));
    let middle = ordered.len() / 2;
    if ordered.len() % 2 == 0 {
        (ordered[middle - 1] + ordered[middle]) / 2.0
    } else {
        ordered[middle]
    }
}

fn parse_arg<T: std::str::FromStr>(value: Option<String>, name: &str) -> T {
    value
        .unwrap_or_else(|| panic!("missing {name}"))
        .parse()
        .unwrap_or_else(|_| panic!("invalid {name}"))
}

fn main() {
    let mut args = env::args().skip(1);
    let backend = args.next().expect("usage: BACKEND LOG WARMUPS SAMPLES OUTPUT");
    let log_n_instances: u32 = parse_arg(args.next(), "log_n_instances");
    let warmups: usize = parse_arg(args.next(), "warmups");
    let samples: usize = parse_arg(args.next(), "samples");
    let output = PathBuf::from(args.next().expect("missing output path"));
    assert!(args.next().is_none(), "unexpected arguments");
    assert!(matches!(backend.as_str(), "simd" | "metal"));
    assert!(samples > 0);

    let inputs = test_inputs(log_n_instances);
    for _ in 0..warmups {
        match backend.as_str() {
            "simd" => {
                let _ = run_sample!(SimdBackend, &inputs, log_n_instances);
            }
            "metal" => {
                let _ = run_sample!(MetalBackend, &inputs, log_n_instances);
            }
            _ => unreachable!(),
        }
    }

    let mut measured = Vec::with_capacity(samples);
    for _ in 0..samples {
        measured.push(match backend.as_str() {
            "simd" => run_sample!(SimdBackend, &inputs, log_n_instances),
            "metal" => run_sample!(MetalBackend, &inputs, log_n_instances),
            _ => unreachable!(),
        });
    }

    let prove_samples_ms = measured.iter().map(|sample| sample.prove_ms).collect_vec();
    let verify_samples_ms = measured
        .iter()
        .map(|sample| sample.verify_ms)
        .collect_vec();
    let total_samples_ms = measured
        .iter()
        .map(|sample| sample.prove_ms + sample.verify_ms)
        .collect_vec();
    let prove_median_ms = median(&prove_samples_ms);
    let last = measured.last().expect("at least one sample");
    let report = Report {
        schema: "current-stwo-wide-fibonacci-backend-v1",
        backend,
        log_n_instances,
        instances: 1u64 << log_n_instances,
        n_columns: N_COLUMNS,
        warmups,
        samples,
        rayon_threads: rayon::current_num_threads(),
        prove_samples_ms,
        verify_samples_ms: verify_samples_ms.clone(),
        total_samples_ms: total_samples_ms.clone(),
        prove_median_ms,
        verify_median_ms: median(&verify_samples_ms),
        total_median_ms: median(&total_samples_ms),
        row_mhz: (1u64 << log_n_instances) as f64 / prove_median_ms / 1000.0,
        proof_size_bytes: last.proof_size_bytes,
        commitments: last.commitments,
        security_bits: last.security_bits,
        fri_queries: last.fri_queries,
        pow_bits: last.pow_bits,
        all_verified: true,
    };
    fs::write(output, serde_json::to_string_pretty(&report).unwrap() + "\n").unwrap();
}
