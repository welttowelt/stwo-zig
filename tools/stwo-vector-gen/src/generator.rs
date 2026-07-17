use stwo::core::circle::{M31_CIRCLE_GEN, M31_CIRCLE_LOG_ORDER};
use stwo::core::fft::{butterfly, ibutterfly};
use stwo::core::fields::FieldExpOps;
use stwo::core::vcs::blake3_hash::Blake3Hasher;

use crate::common::*;
use crate::config::*;
use crate::examples::*;
use crate::fri::*;
use crate::model::*;
use crate::pcs::*;
use crate::proof::*;
use crate::vcs::*;
use crate::UPSTREAM_COMMIT;

pub(crate) fn generate_vectors(state: &mut u64, sample_count: usize) -> FieldVectors {
    let mut m31 = Vec::with_capacity(sample_count);
    let mut cm31 = Vec::with_capacity(sample_count);
    let mut qm31 = Vec::with_capacity(sample_count);
    let mut circle_m31 = Vec::with_capacity(sample_count);
    let mut fft_m31 = Vec::with_capacity(sample_count);
    let mut blake3 = Vec::with_capacity(BLAKE3_VECTOR_COUNT);

    for _ in 0..sample_count {
        let a = sample_m31(state, true);
        let b = sample_m31(state, true);
        m31.push(M31Vector {
            a: encode_m31(a),
            b: encode_m31(b),
            add: encode_m31(a + b),
            sub: encode_m31(a - b),
            mul: encode_m31(a * b),
            inv_a: encode_m31(a.inverse()),
            div_ab: encode_m31(a / b),
        });
    }

    for _ in 0..sample_count {
        let a = sample_cm31(state, true);
        let b = sample_cm31(state, true);
        cm31.push(CM31Vector {
            a: encode_cm31(a),
            b: encode_cm31(b),
            add: encode_cm31(a + b),
            sub: encode_cm31(a - b),
            mul: encode_cm31(a * b),
            inv_a: encode_cm31(a.inverse()),
            div_ab: encode_cm31(a / b),
        });
    }

    for _ in 0..sample_count {
        let a = sample_qm31(state, true);
        let b = sample_qm31(state, true);
        qm31.push(QM31Vector {
            a: encode_qm31(a),
            b: encode_qm31(b),
            add: encode_qm31(a + b),
            sub: encode_qm31(a - b),
            mul: encode_qm31(a * b),
            inv_a: encode_qm31(a.inverse()),
            div_ab: encode_qm31(a / b),
        });
    }

    for _ in 0..sample_count {
        let a_scalar = sample_scalar(state);
        let b_scalar = sample_scalar(state);
        let a = M31_CIRCLE_GEN.mul(a_scalar as u128);
        let b = M31_CIRCLE_GEN.mul(b_scalar as u128);
        let log_order_a = a.log_order();
        debug_assert!(log_order_a <= M31_CIRCLE_LOG_ORDER);
        circle_m31.push(CircleM31Vector {
            a_scalar,
            b_scalar,
            log_order_a,
            a: encode_circle_point(a),
            b: encode_circle_point(b),
            add: encode_circle_point(a + b),
            sub: encode_circle_point(a - b),
            double_a: encode_circle_point(a.double()),
            conjugate_a: encode_circle_point(a.conjugate()),
        });
    }

    for _ in 0..sample_count {
        let a = sample_m31(state, false);
        let b = sample_m31(state, false);
        let twid = sample_m31(state, true);
        let itwid = twid.inverse();

        let mut v0 = a;
        let mut v1 = b;
        butterfly(&mut v0, &mut v1, twid);
        let butterfly_out = [encode_m31(v0), encode_m31(v1)];

        ibutterfly(&mut v0, &mut v1, itwid);
        let ibutterfly_out = [encode_m31(v0), encode_m31(v1)];

        fft_m31.push(FftM31Vector {
            a: encode_m31(a),
            b: encode_m31(b),
            twid: encode_m31(twid),
            butterfly: butterfly_out,
            ibutterfly: ibutterfly_out,
        });
    }

    let pcs_quotients = generate_pcs_quotients_vectors(state, PCS_VECTOR_COUNT);
    let fri_folds = generate_fri_fold_vectors(state, FRI_FOLD_VECTOR_COUNT);
    let fri_decommit = generate_fri_decommit_vectors(state, FRI_DECOMMIT_VECTOR_COUNT);
    let proof_extract_oods = generate_proof_extract_oods_vectors(state, PROOF_OODS_VECTOR_COUNT);
    let proof_sizes = generate_proof_size_vectors(state, PROOF_SIZE_VECTOR_COUNT);
    let prover_line = generate_prover_line_vectors(state, PROVER_LINE_VECTOR_COUNT);
    let vcs_verifier = generate_vcs_verifier_vectors(state, VCS_VERIFIER_VECTOR_COUNT);
    let vcs_prover = generate_vcs_prover_vectors(state, VCS_PROVER_VECTOR_COUNT);
    let vcs_lifted_verifier =
        generate_vcs_lifted_verifier_vectors(state, VCS_LIFTED_VERIFIER_VECTOR_COUNT);
    let vcs_lifted_prover =
        generate_vcs_lifted_prover_vectors(state, VCS_LIFTED_PROVER_VECTOR_COUNT);
    let example_state_machine_trace = generate_example_state_machine_trace_vectors(
        state,
        EXAMPLE_STATE_MACHINE_TRACE_VECTOR_COUNT,
    );
    let example_state_machine_transitions = generate_example_state_machine_transition_vectors(
        state,
        EXAMPLE_STATE_MACHINE_TRANSITION_VECTOR_COUNT,
    );
    let example_state_machine_claimed_sum = generate_example_state_machine_claimed_sum_vectors(
        state,
        EXAMPLE_STATE_MACHINE_CLAIMED_SUM_VECTOR_COUNT,
    );
    let example_state_machine_lookup_draw = generate_example_state_machine_lookup_draw_vectors(
        state,
        EXAMPLE_STATE_MACHINE_LOOKUP_DRAW_VECTOR_COUNT,
    );
    let example_state_machine_statement = generate_example_state_machine_statement_vectors(
        state,
        EXAMPLE_STATE_MACHINE_STATEMENT_VECTOR_COUNT,
    );
    let example_xor_is_first =
        generate_example_xor_is_first_vectors(state, EXAMPLE_XOR_IS_FIRST_VECTOR_COUNT);
    let example_xor_is_step_with_offset = generate_example_xor_is_step_with_offset_vectors(
        state,
        EXAMPLE_XOR_IS_STEP_WITH_OFFSET_VECTOR_COUNT,
    );
    let example_wide_fibonacci_trace = generate_example_wide_fibonacci_trace_vectors(
        state,
        EXAMPLE_WIDE_FIBONACCI_TRACE_VECTOR_COUNT,
    );
    let example_plonk_trace =
        generate_example_plonk_trace_vectors(state, EXAMPLE_PLONK_TRACE_VECTOR_COUNT);

    for _ in 0..BLAKE3_VECTOR_COUNT {
        let data_len = next_u64(state) as usize % 96;
        let mut data = vec![0u8; data_len];
        fill_bytes(state, &mut data);
        let hash = Blake3Hasher::hash(&data);

        let mut left_data = vec![0u8; next_u64(state) as usize % 64];
        fill_bytes(state, &mut left_data);
        let mut right_data = vec![0u8; next_u64(state) as usize % 64];
        fill_bytes(state, &mut right_data);
        let left = Blake3Hasher::hash(&left_data);
        let right = Blake3Hasher::hash(&right_data);
        let concat_hash = Blake3Hasher::concat_and_hash(&left, &right);

        blake3.push(Blake3Vector {
            data,
            hash: encode_blake3_hash(hash),
            left: encode_blake3_hash(left),
            right: encode_blake3_hash(right),
            concat_hash: encode_blake3_hash(concat_hash),
        });
    }

    let mut fri_layer_state = FRI_LAYER_DECOMMIT_SEED;
    let fri_layer_decommit =
        generate_fri_layer_decommit_vectors(&mut fri_layer_state, FRI_LAYER_DECOMMIT_VECTOR_COUNT);
    let mut pcs_preprocessed_query_state = PCS_PREPROCESSED_QUERY_SEED;
    let pcs_preprocessed_queries = generate_pcs_preprocessed_query_vectors(
        &mut pcs_preprocessed_query_state,
        PCS_PREPROCESSED_QUERY_VECTOR_COUNT,
    );

    FieldVectors {
        meta: Meta {
            upstream_commit: UPSTREAM_COMMIT,
            sample_count,
            schema_version: VECTOR_SCHEMA_VERSION,
            seed: VECTOR_SEED,
            seed_strategy: VECTOR_SEED_STRATEGY,
        },
        m31,
        cm31,
        qm31,
        circle_m31,
        fft_m31,
        blake3,
        pcs_quotients,
        pcs_preprocessed_queries,
        fri_folds,
        fri_decommit,
        fri_layer_decommit,
        proof_extract_oods,
        proof_sizes,
        prover_line,
        vcs_verifier,
        vcs_prover,
        vcs_lifted_verifier,
        vcs_lifted_prover,
        example_state_machine_trace,
        example_state_machine_transitions,
        example_state_machine_claimed_sum,
        example_state_machine_lookup_draw,
        example_state_machine_statement,
        example_xor_is_first,
        example_xor_is_step_with_offset,
        example_wide_fibonacci_trace,
        example_plonk_trace,
    }
}
