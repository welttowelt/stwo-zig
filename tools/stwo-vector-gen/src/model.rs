use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub(crate) struct Meta {
    pub(crate) upstream_commit: &'static str,
    pub(crate) sample_count: usize,
    pub(crate) schema_version: u32,
    pub(crate) seed: u64,
    pub(crate) seed_strategy: &'static str,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct M31Vector {
    pub(crate) a: u32,
    pub(crate) b: u32,
    pub(crate) add: u32,
    pub(crate) sub: u32,
    pub(crate) mul: u32,
    pub(crate) inv_a: u32,
    pub(crate) div_ab: u32,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct CM31Vector {
    pub(crate) a: [u32; 2],
    pub(crate) b: [u32; 2],
    pub(crate) add: [u32; 2],
    pub(crate) sub: [u32; 2],
    pub(crate) mul: [u32; 2],
    pub(crate) inv_a: [u32; 2],
    pub(crate) div_ab: [u32; 2],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct QM31Vector {
    pub(crate) a: [u32; 4],
    pub(crate) b: [u32; 4],
    pub(crate) add: [u32; 4],
    pub(crate) sub: [u32; 4],
    pub(crate) mul: [u32; 4],
    pub(crate) inv_a: [u32; 4],
    pub(crate) div_ab: [u32; 4],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct CircleM31Vector {
    pub(crate) a_scalar: u64,
    pub(crate) b_scalar: u64,
    pub(crate) log_order_a: u32,
    pub(crate) a: [u32; 2],
    pub(crate) b: [u32; 2],
    pub(crate) add: [u32; 2],
    pub(crate) sub: [u32; 2],
    pub(crate) double_a: [u32; 2],
    pub(crate) conjugate_a: [u32; 2],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct FftM31Vector {
    pub(crate) a: u32,
    pub(crate) b: u32,
    pub(crate) twid: u32,
    pub(crate) butterfly: [u32; 2],
    pub(crate) ibutterfly: [u32; 2],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct Blake3Vector {
    pub(crate) data: Vec<u8>,
    pub(crate) hash: [u8; 32],
    pub(crate) left: [u8; 32],
    pub(crate) right: [u8; 32],
    pub(crate) concat_hash: [u8; 32],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct PointSampleVector {
    pub(crate) point: [[u32; 4]; 2],
    pub(crate) value: [u32; 4],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct SampleWithRandomnessVector {
    pub(crate) sample: PointSampleVector,
    pub(crate) random_coeff: [u32; 4],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct NumeratorDataVector {
    pub(crate) column_index: usize,
    pub(crate) sample_value: [u32; 4],
    pub(crate) random_coeff: [u32; 4],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ColumnSampleBatchVector {
    pub(crate) point: [[u32; 4]; 2],
    pub(crate) cols_vals_randpows: Vec<NumeratorDataVector>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct LineCoeffVector {
    pub(crate) a: [u32; 4],
    pub(crate) b: [u32; 4],
    pub(crate) c: [u32; 4],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct PcsQuotientsVector {
    pub(crate) lifting_log_size: u32,
    pub(crate) column_log_sizes: Vec<Vec<u32>>,
    pub(crate) samples: Vec<Vec<Vec<PointSampleVector>>>,
    pub(crate) random_coeff: [u32; 4],
    pub(crate) query_positions: Vec<usize>,
    pub(crate) queried_values: Vec<Vec<Vec<u32>>>,
    pub(crate) samples_with_randomness: Vec<Vec<Vec<SampleWithRandomnessVector>>>,
    pub(crate) sample_batches: Vec<ColumnSampleBatchVector>,
    pub(crate) line_coeffs: Vec<Vec<LineCoeffVector>>,
    pub(crate) denominator_inverses: Vec<Vec<[u32; 2]>>,
    pub(crate) partial_numerators: Vec<Vec<[u32; 4]>>,
    pub(crate) row_quotients: Vec<[u32; 4]>,
    pub(crate) fri_answers: Vec<[u32; 4]>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct PcsPreprocessedQueryVector {
    pub(crate) query_positions: Vec<usize>,
    pub(crate) max_log_size: u32,
    pub(crate) pp_max_log_size: u32,
    pub(crate) expected: Vec<usize>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct FriFoldVector {
    pub(crate) line_log_size: u32,
    pub(crate) line_eval: Vec<[u32; 4]>,
    pub(crate) alpha: [u32; 4],
    pub(crate) fold_line_values: Vec<[u32; 4]>,
    pub(crate) circle_log_size: u32,
    pub(crate) circle_eval: Vec<[u32; 4]>,
    pub(crate) fold_circle_values: Vec<[u32; 4]>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct FriDecommitVector {
    pub(crate) case: String,
    pub(crate) fold_step: u32,
    pub(crate) column: Vec<[u32; 4]>,
    pub(crate) query_positions: Vec<usize>,
    pub(crate) decommitment_positions: Vec<usize>,
    pub(crate) witness_evals: Vec<[u32; 4]>,
    pub(crate) value_map_positions: Vec<usize>,
    pub(crate) value_map_values: Vec<[u32; 4]>,
    pub(crate) expected: String,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct FriLayerDecommitVector {
    pub(crate) case: String,
    pub(crate) fold_step: u32,
    pub(crate) column: Vec<[u32; 4]>,
    pub(crate) query_positions: Vec<usize>,
    pub(crate) commitment: [u8; 32],
    pub(crate) decommitment_positions: Vec<usize>,
    pub(crate) fri_witness: Vec<[u32; 4]>,
    pub(crate) hash_witness: Vec<[u8; 32]>,
    pub(crate) value_map_positions: Vec<usize>,
    pub(crate) value_map_values: Vec<[u32; 4]>,
    pub(crate) expected: String,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ProofExtractOodsVector {
    pub(crate) composition_log_size: u32,
    pub(crate) oods_point: [[u32; 4]; 2],
    pub(crate) composition_values: Vec<[u32; 4]>,
    pub(crate) expected: [u32; 4],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ProofSizeBreakdownVector {
    pub(crate) oods_samples: usize,
    pub(crate) queries_values: usize,
    pub(crate) fri_samples: usize,
    pub(crate) fri_decommitments: usize,
    pub(crate) trace_decommitments: usize,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ProofSizeInnerLayerVector {
    pub(crate) fri_witness: Vec<[u32; 4]>,
    pub(crate) decommitment: Vec<[u8; 32]>,
    pub(crate) commitment: [u8; 32],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ProofSizeVector {
    pub(crate) commitments: Vec<[u8; 32]>,
    pub(crate) sampled_values: Vec<Vec<Vec<[u32; 4]>>>,
    pub(crate) decommitments: Vec<Vec<[u8; 32]>>,
    pub(crate) queried_values: Vec<Vec<Vec<u32>>>,
    pub(crate) proof_of_work: u64,
    pub(crate) first_layer_witness: Vec<[u32; 4]>,
    pub(crate) first_layer_decommitment: Vec<[u8; 32]>,
    pub(crate) first_layer_commitment: [u8; 32],
    pub(crate) inner_layers: Vec<ProofSizeInnerLayerVector>,
    pub(crate) last_layer_poly: Vec<[u32; 4]>,
    pub(crate) expected_breakdown: ProofSizeBreakdownVector,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ProverLineVector {
    pub(crate) line_log_size: u32,
    pub(crate) values: Vec<[u32; 4]>,
    pub(crate) coeffs_bit_reversed: Vec<[u32; 4]>,
    pub(crate) coeffs_ordered: Vec<[u32; 4]>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct VcsLogSizeQueriesVector {
    pub(crate) log_size: u32,
    pub(crate) queries: Vec<usize>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct VcsVerifierVector {
    pub(crate) case: String,
    pub(crate) root: [u8; 32],
    pub(crate) column_log_sizes: Vec<u32>,
    pub(crate) queries_per_log_size: Vec<VcsLogSizeQueriesVector>,
    pub(crate) queried_values: Vec<u32>,
    pub(crate) hash_witness: Vec<[u8; 32]>,
    pub(crate) column_witness: Vec<u32>,
    pub(crate) expected: String,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct VcsProverVector {
    pub(crate) root: [u8; 32],
    pub(crate) column_log_sizes: Vec<u32>,
    pub(crate) columns: Vec<Vec<u32>>,
    pub(crate) queries_per_log_size: Vec<VcsLogSizeQueriesVector>,
    pub(crate) queried_values: Vec<u32>,
    pub(crate) hash_witness: Vec<[u8; 32]>,
    pub(crate) column_witness: Vec<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct VcsLiftedProverVector {
    pub(crate) root: [u8; 32],
    pub(crate) column_log_sizes: Vec<u32>,
    pub(crate) columns: Vec<Vec<u32>>,
    pub(crate) query_positions: Vec<usize>,
    pub(crate) queried_values: Vec<Vec<u32>>,
    pub(crate) hash_witness: Vec<[u8; 32]>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct VcsLiftedVerifierVector {
    pub(crate) case: String,
    pub(crate) root: [u8; 32],
    pub(crate) column_log_sizes: Vec<u32>,
    pub(crate) query_positions: Vec<usize>,
    pub(crate) queried_values: Vec<Vec<u32>>,
    pub(crate) hash_witness: Vec<[u8; 32]>,
    pub(crate) expected: String,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ExampleStateMachineTraceVector {
    pub(crate) log_size: u32,
    pub(crate) initial_state: [u32; 2],
    pub(crate) inc_index: usize,
    pub(crate) columns: Vec<Vec<u32>>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ExampleStateMachineTransitionVector {
    pub(crate) log_n_rows: u32,
    pub(crate) initial_state: [u32; 2],
    pub(crate) intermediate_state: [u32; 2],
    pub(crate) final_state: [u32; 2],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ExampleStateMachineClaimedSumVector {
    pub(crate) log_size: u32,
    pub(crate) initial_state: [u32; 2],
    pub(crate) inc_index: usize,
    pub(crate) z: [u32; 4],
    pub(crate) alpha: [u32; 4],
    pub(crate) claimed_sum: [u32; 4],
    pub(crate) telescoping_claim: [u32; 4],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ExampleStateMachineLookupDrawVector {
    pub(crate) mix_u64: u64,
    pub(crate) mix_u32s: Vec<u32>,
    pub(crate) z: [u32; 4],
    pub(crate) alpha: [u32; 4],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ExampleStateMachineStatementVector {
    pub(crate) log_n_rows: u32,
    pub(crate) initial_state: [u32; 2],
    pub(crate) z: [u32; 4],
    pub(crate) alpha: [u32; 4],
    pub(crate) intermediate_state: [u32; 2],
    pub(crate) final_state: [u32; 2],
    pub(crate) x_axis_claimed_sum: [u32; 4],
    pub(crate) y_axis_claimed_sum: [u32; 4],
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ExampleXorIsFirstVector {
    pub(crate) log_size: u32,
    pub(crate) values: Vec<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ExampleXorIsStepWithOffsetVector {
    pub(crate) log_size: u32,
    pub(crate) log_step: u32,
    pub(crate) offset: usize,
    pub(crate) values: Vec<u32>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ExampleWideFibonacciTraceVector {
    pub(crate) log_n_rows: u32,
    pub(crate) sequence_len: u32,
    pub(crate) columns: Vec<Vec<u32>>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct ExamplePlonkTraceVector {
    pub(crate) log_n_rows: u32,
    pub(crate) preprocessed: Vec<Vec<u32>>,
    pub(crate) main: Vec<Vec<u32>>,
}

#[derive(Debug, Clone, Serialize)]
pub(crate) struct FieldVectors {
    pub(crate) meta: Meta,
    pub(crate) m31: Vec<M31Vector>,
    pub(crate) cm31: Vec<CM31Vector>,
    pub(crate) qm31: Vec<QM31Vector>,
    pub(crate) circle_m31: Vec<CircleM31Vector>,
    pub(crate) fft_m31: Vec<FftM31Vector>,
    pub(crate) blake3: Vec<Blake3Vector>,
    pub(crate) pcs_quotients: Vec<PcsQuotientsVector>,
    pub(crate) pcs_preprocessed_queries: Vec<PcsPreprocessedQueryVector>,
    pub(crate) fri_folds: Vec<FriFoldVector>,
    pub(crate) fri_decommit: Vec<FriDecommitVector>,
    pub(crate) fri_layer_decommit: Vec<FriLayerDecommitVector>,
    pub(crate) proof_extract_oods: Vec<ProofExtractOodsVector>,
    pub(crate) proof_sizes: Vec<ProofSizeVector>,
    pub(crate) prover_line: Vec<ProverLineVector>,
    pub(crate) vcs_verifier: Vec<VcsVerifierVector>,
    pub(crate) vcs_prover: Vec<VcsProverVector>,
    pub(crate) vcs_lifted_verifier: Vec<VcsLiftedVerifierVector>,
    pub(crate) vcs_lifted_prover: Vec<VcsLiftedProverVector>,
    pub(crate) example_state_machine_trace: Vec<ExampleStateMachineTraceVector>,
    pub(crate) example_state_machine_transitions: Vec<ExampleStateMachineTransitionVector>,
    pub(crate) example_state_machine_claimed_sum: Vec<ExampleStateMachineClaimedSumVector>,
    pub(crate) example_state_machine_lookup_draw: Vec<ExampleStateMachineLookupDrawVector>,
    pub(crate) example_state_machine_statement: Vec<ExampleStateMachineStatementVector>,
    pub(crate) example_xor_is_first: Vec<ExampleXorIsFirstVector>,
    pub(crate) example_xor_is_step_with_offset: Vec<ExampleXorIsStepWithOffsetVector>,
    pub(crate) example_wide_fibonacci_trace: Vec<ExampleWideFibonacciTraceVector>,
    pub(crate) example_plonk_trace: Vec<ExamplePlonkTraceVector>,
}
