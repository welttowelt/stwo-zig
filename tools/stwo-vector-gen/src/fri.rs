use stwo::core::circle::Coset;
use stwo::core::fields::qm31::QM31;
use stwo::core::fri::{fold_circle_into_line, fold_line};
use stwo::core::poly::circle::CanonicCoset;
use stwo::core::poly::line::LineDomain;
use stwo::core::vcs::blake2_hash::Blake2sHash;
use stwo::core::vcs_lifted::blake2_merkle::Blake2sMerkleHasher as LiftedMerkleHasher;
use stwo::core::vcs_lifted::MerkleHasherLifted;

use crate::common::*;
use crate::model::*;
use crate::vcs::build_vcs_lifted_leaves;

pub(crate) fn generate_fri_fold_vectors(state: &mut u64, count: usize) -> Vec<FriFoldVector> {
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let line_log_size = 2 + ((next_u64(state) as u32) % 5);
        let line_len = 1usize << line_log_size;
        let line_eval = (0..line_len)
            .map(|_| sample_qm31(state, false))
            .collect::<Vec<_>>();

        let circle_log_size = 2 + ((next_u64(state) as u32) % 5);
        let circle_len = 1usize << circle_log_size;
        let circle_eval = (0..circle_len)
            .map(|_| sample_qm31(state, false))
            .collect::<Vec<_>>();

        let alpha = sample_qm31(state, true);
        let line_domain = LineDomain::new(Coset::half_odds(line_log_size));
        let (_, fold_line_values_raw) = fold_line(&line_eval, line_domain, alpha);

        let circle_domain = CanonicCoset::new(circle_log_size).circle_domain();
        let mut fold_circle_values_raw = vec![QM31::from(0); circle_eval.len() >> 1];
        fold_circle_into_line(
            &mut fold_circle_values_raw,
            &circle_eval,
            circle_domain,
            alpha,
        );

        out.push(FriFoldVector {
            line_log_size,
            line_eval: line_eval.into_iter().map(encode_qm31).collect(),
            alpha: encode_qm31(alpha),
            fold_line_values: fold_line_values_raw.into_iter().map(encode_qm31).collect(),
            circle_log_size,
            circle_eval: circle_eval.into_iter().map(encode_qm31).collect(),
            fold_circle_values: fold_circle_values_raw
                .into_iter()
                .map(encode_qm31)
                .collect(),
        });
    }
    out
}

pub(crate) fn generate_fri_decommit_vectors(
    state: &mut u64,
    count: usize,
) -> Vec<FriDecommitVector> {
    let mut out = Vec::with_capacity(count);
    while out.len() < count {
        let mut cases = build_fri_decommit_cases(state);
        if cases.is_empty() {
            continue;
        }
        let remaining = count - out.len();
        if cases.len() > remaining {
            cases.truncate(remaining);
        }
        out.extend(cases);
    }
    out
}

fn build_fri_decommit_cases(state: &mut u64) -> Vec<FriDecommitVector> {
    let line_log_size = 2 + ((next_u64(state) as u32) % 6);
    let line_len = 1usize << line_log_size;
    let column = (0..line_len)
        .map(|_| sample_qm31(state, false))
        .collect::<Vec<_>>();

    let max_fold_step = line_log_size.min(3);
    let fold_step = (next_u64(state) as u32) % (max_fold_step + 1);

    let mut query_positions = Vec::new();
    let n_queries = 1 + (next_u64(state) as usize % line_len.min(4));
    while query_positions.len() < n_queries {
        let q = next_u64(state) as usize % line_len;
        if !query_positions.contains(&q) {
            query_positions.push(q);
        }
    }
    query_positions.sort_unstable();

    let base_expected = compute_fri_decommit_outputs(&column, &query_positions, fold_step);
    if !matches!(base_expected, Ok(_)) {
        return vec![];
    }

    let mut out = Vec::<FriDecommitVector>::new();
    let mut push_case = |case: &str, case_fold_step: u32, case_queries: Vec<usize>| {
        let (expected, outputs) =
            match compute_fri_decommit_outputs(&column, &case_queries, case_fold_step) {
                Ok(outputs) => ("ok".to_string(), outputs),
                Err(err) => (
                    err.to_string(),
                    FriDecommitOutputs {
                        decommitment_positions: Vec::new(),
                        witness_evals: Vec::new(),
                        value_map_positions: Vec::new(),
                        value_map_values: Vec::new(),
                    },
                ),
            };

        out.push(FriDecommitVector {
            case: case.to_string(),
            fold_step: case_fold_step,
            column: column.iter().copied().map(encode_qm31).collect(),
            query_positions: case_queries,
            decommitment_positions: outputs.decommitment_positions,
            witness_evals: outputs.witness_evals.into_iter().map(encode_qm31).collect(),
            value_map_positions: outputs.value_map_positions,
            value_map_values: outputs
                .value_map_values
                .into_iter()
                .map(encode_qm31)
                .collect(),
            expected,
        });
    };

    push_case("valid", fold_step, query_positions.clone());

    let mut out_of_range_queries = query_positions.clone();
    out_of_range_queries.push(line_len + 1 + (next_u64(state) as usize % 4));
    out_of_range_queries.sort_unstable();
    push_case("query_out_of_range", fold_step, out_of_range_queries);

    push_case("fold_step_too_large", usize::BITS, query_positions);

    out
}

struct FriDecommitOutputs {
    decommitment_positions: Vec<usize>,
    witness_evals: Vec<QM31>,
    value_map_positions: Vec<usize>,
    value_map_values: Vec<QM31>,
}

fn compute_fri_decommit_outputs(
    column: &[QM31],
    query_positions: &[usize],
    fold_step: u32,
) -> Result<FriDecommitOutputs, &'static str> {
    if fold_step >= usize::BITS {
        return Err("FoldStepTooLarge");
    }

    let mut decommitment_positions = Vec::<usize>::new();
    let mut witness_evals = Vec::<QM31>::new();
    let mut value_map_positions = Vec::<usize>::new();
    let mut value_map_values = Vec::<QM31>::new();

    let subset_len = 1usize << fold_step;

    let mut subset_start_idx = 0usize;
    while subset_start_idx < query_positions.len() {
        let subset_key = query_positions[subset_start_idx] >> fold_step;
        let mut subset_end_idx = subset_start_idx + 1;
        while subset_end_idx < query_positions.len()
            && (query_positions[subset_end_idx] >> fold_step) == subset_key
        {
            subset_end_idx += 1;
        }

        let subset_queries = &query_positions[subset_start_idx..subset_end_idx];
        let subset_start = subset_key << fold_step;
        let mut subset_query_at = 0usize;

        for position in subset_start..subset_start + subset_len {
            if position >= column.len() {
                return Err("QueryOutOfRange");
            }
            decommitment_positions.push(position);
            let eval = column[position];
            value_map_positions.push(position);
            value_map_values.push(eval);

            if subset_query_at < subset_queries.len() && subset_queries[subset_query_at] == position
            {
                subset_query_at += 1;
            } else {
                witness_evals.push(eval);
            }
        }

        subset_start_idx = subset_end_idx;
    }

    Ok(FriDecommitOutputs {
        decommitment_positions,
        witness_evals,
        value_map_positions,
        value_map_values,
    })
}

pub(crate) fn generate_fri_layer_decommit_vectors(
    state: &mut u64,
    count: usize,
) -> Vec<FriLayerDecommitVector> {
    let mut out = Vec::with_capacity(count);
    while out.len() < count {
        let mut cases = build_fri_layer_decommit_cases(state);
        if cases.is_empty() {
            continue;
        }
        let remaining = count - out.len();
        if cases.len() > remaining {
            cases.truncate(remaining);
        }
        out.extend(cases);
    }
    out
}

fn build_fri_layer_decommit_cases(state: &mut u64) -> Vec<FriLayerDecommitVector> {
    let line_log_size = 2 + ((next_u64(state) as u32) % 6);
    let line_len = 1usize << line_log_size;
    let column = (0..line_len)
        .map(|_| sample_qm31(state, false))
        .collect::<Vec<_>>();

    let max_fold_step = line_log_size.min(3);
    let fold_step = (next_u64(state) as u32) % (max_fold_step + 1);

    let mut query_positions = Vec::new();
    let n_queries = 1 + (next_u64(state) as usize % line_len.min(4));
    while query_positions.len() < n_queries {
        let q = next_u64(state) as usize % line_len;
        if !query_positions.contains(&q) {
            query_positions.push(q);
        }
    }
    query_positions.sort_unstable();

    let base_commitment =
        match compute_fri_layer_decommit_outputs(&column, &query_positions, fold_step) {
            Ok(outputs) => outputs.commitment,
            Err(_) => return vec![],
        };

    let mut out = Vec::<FriLayerDecommitVector>::new();
    let mut push_case = |case: &str, case_fold_step: u32, case_queries: Vec<usize>| {
        let (expected, outputs) =
            match compute_fri_layer_decommit_outputs(&column, &case_queries, case_fold_step) {
                Ok(outputs) => ("ok".to_string(), outputs),
                Err(err) => (
                    err.to_string(),
                    FriLayerDecommitOutputs {
                        commitment: base_commitment,
                        decommitment_positions: Vec::new(),
                        fri_witness: Vec::new(),
                        hash_witness: Vec::new(),
                        value_map_positions: Vec::new(),
                        value_map_values: Vec::new(),
                    },
                ),
            };

        out.push(FriLayerDecommitVector {
            case: case.to_string(),
            fold_step: case_fold_step,
            column: column.iter().copied().map(encode_qm31).collect(),
            query_positions: case_queries,
            commitment: encode_hash(outputs.commitment),
            decommitment_positions: outputs.decommitment_positions,
            fri_witness: outputs.fri_witness.into_iter().map(encode_qm31).collect(),
            hash_witness: outputs.hash_witness.into_iter().map(encode_hash).collect(),
            value_map_positions: outputs.value_map_positions,
            value_map_values: outputs
                .value_map_values
                .into_iter()
                .map(encode_qm31)
                .collect(),
            expected,
        });
    };

    push_case("valid", fold_step, query_positions.clone());

    let mut out_of_range_queries = query_positions.clone();
    out_of_range_queries.push(line_len + 1 + (next_u64(state) as usize % 4));
    out_of_range_queries.sort_unstable();
    push_case("query_out_of_range", fold_step, out_of_range_queries);

    push_case("fold_step_too_large", usize::BITS, query_positions);

    out
}

struct FriLayerDecommitOutputs {
    commitment: Blake2sHash,
    decommitment_positions: Vec<usize>,
    fri_witness: Vec<QM31>,
    hash_witness: Vec<Blake2sHash>,
    value_map_positions: Vec<usize>,
    value_map_values: Vec<QM31>,
}

fn compute_fri_layer_decommit_outputs(
    column: &[QM31],
    query_positions: &[usize],
    fold_step: u32,
) -> Result<FriLayerDecommitOutputs, &'static str> {
    let helper = compute_fri_decommit_outputs(column, query_positions, fold_step)?;

    let mut base_columns = vec![Vec::with_capacity(column.len()); 4];
    for value in column {
        let coords = value.to_m31_array();
        for coord in 0..4 {
            base_columns[coord].push(coords[coord]);
        }
    }
    let sorted_columns = base_columns.iter().collect::<Vec<_>>();
    let leaves = build_vcs_lifted_leaves(&sorted_columns);
    let mut layers = vec![leaves];
    while layers.last().expect("at least one layer").len() > 1 {
        let prev = layers.last().expect("previous layer");
        layers.push(
            (0..(prev.len() >> 1))
                .map(|i| LiftedMerkleHasher::hash_children((prev[2 * i], prev[2 * i + 1])))
                .collect(),
        );
    }
    layers.reverse();
    let commitment = layers
        .first()
        .expect("root layer")
        .first()
        .copied()
        .expect("root hash");

    let mut hash_witness = Vec::<Blake2sHash>::new();
    let mut prev_layer_queries = helper.decommitment_positions.clone();
    prev_layer_queries.dedup();
    for layer_log_size in (0..layers.len() - 1).rev() {
        let prev_layer_hashes = layers
            .get(layer_log_size + 1)
            .expect("previous layer hashes");
        let mut curr_layer_queries = Vec::<usize>::new();
        let mut p: usize = 0;
        while p < prev_layer_queries.len() {
            let first = prev_layer_queries[p];
            let mut chunk_len = 1;
            if p + 1 < prev_layer_queries.len() && ((first ^ 1) == prev_layer_queries[p + 1]) {
                chunk_len = 2;
            }
            if chunk_len == 1 {
                hash_witness.push(prev_layer_hashes[first ^ 1]);
            }
            curr_layer_queries.push(first >> 1);
            p += chunk_len;
        }
        prev_layer_queries = curr_layer_queries;
    }

    Ok(FriLayerDecommitOutputs {
        commitment,
        decommitment_positions: helper.decommitment_positions,
        fri_witness: helper.witness_evals,
        hash_witness,
        value_map_positions: helper.value_map_positions,
        value_map_values: helper.value_map_values,
    })
}
