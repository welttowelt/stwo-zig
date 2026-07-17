use stwo::core::fields::m31::M31;
use stwo::core::fields::ComplexConjugate;
use stwo::core::pcs::quotients::{
    accumulate_row_partial_numerators, accumulate_row_quotients,
    build_samples_with_randomness_and_periodicity, denominator_inverses, fri_answers,
    quotient_constants, ColumnSampleBatch, PointSample,
};
use stwo::core::pcs::utils::prepare_preprocessed_query_positions;
use stwo::core::pcs::TreeVec;
use stwo::core::poly::circle::CanonicCoset;
use stwo::core::utils::bit_reverse_index;

use crate::common::*;
use crate::config::{PCS_LIFTING_LOG_SIZE, PCS_QUERY_COUNT};
use crate::model::*;

pub(crate) fn generate_pcs_preprocessed_query_vectors(
    state: &mut u64,
    count: usize,
) -> Vec<PcsPreprocessedQueryVector> {
    let mut out = Vec::with_capacity(count);
    while out.len() < count {
        let max_log_size = (next_u64(state) as u32) % 10;
        let mode = (next_u64(state) as usize) % 3;
        let pp_max_log_size = match mode {
            0 => 0,
            1 => max_log_size + 1 + ((next_u64(state) as u32) % 3),
            _ => (next_u64(state) as u32) % (max_log_size + 1),
        };

        let domain_log = std::cmp::max(max_log_size, pp_max_log_size).max(1);
        let domain_size = 1usize << domain_log;
        let n_queries = 1 + (next_u64(state) as usize % domain_size.min(8));
        let mut query_positions = Vec::with_capacity(n_queries);
        while query_positions.len() < n_queries {
            let q = next_u64(state) as usize & (domain_size - 1);
            if !query_positions.contains(&q) {
                query_positions.push(q);
            }
        }
        query_positions.sort_unstable();

        out.push(PcsPreprocessedQueryVector {
            expected: prepare_preprocessed_query_positions(
                &query_positions,
                max_log_size,
                pp_max_log_size,
            ),
            query_positions,
            max_log_size,
            pp_max_log_size,
        });
    }
    out
}

pub(crate) fn generate_pcs_quotients_vectors(
    state: &mut u64,
    count: usize,
) -> Vec<PcsQuotientsVector> {
    let mut out = Vec::with_capacity(count);
    while out.len() < count {
        if let Some(v) = try_generate_pcs_quotients_vector(state) {
            out.push(v);
        }
    }
    out
}

fn try_generate_pcs_quotients_vector(state: &mut u64) -> Option<PcsQuotientsVector> {
    let n_trees = 2usize;
    let cols_per_tree = 2usize;
    let domain_size = 1usize << PCS_LIFTING_LOG_SIZE;

    let mut query_positions = Vec::with_capacity(PCS_QUERY_COUNT);
    while query_positions.len() < PCS_QUERY_COUNT {
        let q = (next_u64(state) as usize) & (domain_size - 1);
        if !query_positions.contains(&q) {
            query_positions.push(q);
        }
    }

    let mut column_log_sizes: Vec<Vec<u32>> = Vec::with_capacity(n_trees);
    let mut samples_raw: Vec<Vec<Vec<PointSample>>> = Vec::with_capacity(n_trees);
    let mut queried_values_raw: Vec<Vec<Vec<M31>>> = Vec::with_capacity(n_trees);

    for _ in 0..n_trees {
        let mut tree_sizes = Vec::with_capacity(cols_per_tree);
        let mut tree_samples = Vec::with_capacity(cols_per_tree);
        let mut tree_queries = Vec::with_capacity(cols_per_tree);

        for _ in 0..cols_per_tree {
            let log_size = 4 + ((next_u64(state) as u32) % (PCS_LIFTING_LOG_SIZE - 3));
            tree_sizes.push(log_size);

            let n_samples = if (next_u64(state) & 1) == 0 { 1 } else { 2 };
            let mut col_samples = Vec::with_capacity(n_samples);
            for _ in 0..n_samples {
                col_samples.push(PointSample {
                    point: sample_secure_point_non_degenerate(state),
                    value: sample_qm31(state, false),
                });
            }
            tree_samples.push(col_samples);

            let mut qvals = Vec::with_capacity(query_positions.len());
            for _ in 0..query_positions.len() {
                qvals.push(sample_m31(state, false));
            }
            tree_queries.push(qvals);
        }

        column_log_sizes.push(tree_sizes);
        samples_raw.push(tree_samples);
        queried_values_raw.push(tree_queries);
    }

    let random_coeff = sample_qm31(state, true);

    let sample_y_non_degenerate = samples_raw
        .iter()
        .flatten()
        .flatten()
        .all(|sample| sample.point.y != sample.point.y.complex_conjugate());
    if !sample_y_non_degenerate {
        return None;
    }

    let size_iters = column_log_sizes
        .iter()
        .cloned()
        .map(|v| v.into_iter())
        .collect::<Vec<_>>();
    let samples_with_randomness = build_samples_with_randomness_and_periodicity(
        &TreeVec(samples_raw.clone()),
        size_iters,
        PCS_LIFTING_LOG_SIZE,
        random_coeff,
    );

    let flattened_samples_with_randomness =
        samples_with_randomness.iter().flatten().collect::<Vec<_>>();
    let sample_batches = ColumnSampleBatch::new_vec(&flattened_samples_with_randomness);

    let sample_points = sample_batches.iter().map(|b| b.point).collect::<Vec<_>>();
    let lifting_domain = CanonicCoset::new(PCS_LIFTING_LOG_SIZE).circle_domain();
    for &position in &query_positions {
        let domain_point = lifting_domain.at(bit_reverse_index(position, PCS_LIFTING_LOG_SIZE));
        for sample_point in &sample_points {
            let prx = sample_point.x.0;
            let pry = sample_point.y.0;
            let pix = sample_point.x.1;
            let piy = sample_point.y.1;
            let denom = (prx - domain_point.x) * piy - (pry - domain_point.y) * pix;
            if encode_cm31(denom) == [0, 0] {
                return None;
            }
        }
    }

    let q_consts = quotient_constants(&sample_batches);
    let line_coeffs_raw = q_consts.line_coeffs.clone();
    let queried_values_flat = queried_values_raw
        .iter()
        .flatten()
        .cloned()
        .collect::<Vec<_>>();

    let mut denominator_inverses_out: Vec<Vec<[u32; 2]>> =
        Vec::with_capacity(query_positions.len());
    let mut partial_numerators_out: Vec<Vec<[u32; 4]>> = Vec::with_capacity(query_positions.len());
    let mut row_quotients_out: Vec<[u32; 4]> = Vec::with_capacity(query_positions.len());

    for (row_idx, &position) in query_positions.iter().enumerate() {
        let queried_values_at_row = queried_values_flat
            .iter()
            .map(|column| column[row_idx])
            .collect::<Vec<_>>();
        let domain_point = lifting_domain.at(bit_reverse_index(position, PCS_LIFTING_LOG_SIZE));

        let den_inv = denominator_inverses(&sample_points, domain_point);
        denominator_inverses_out.push(den_inv.into_iter().map(encode_cm31).collect());

        let partials = sample_batches
            .iter()
            .zip(line_coeffs_raw.iter())
            .map(|(batch, coeffs)| {
                encode_qm31(accumulate_row_partial_numerators(
                    batch,
                    &queried_values_at_row,
                    coeffs,
                ))
            })
            .collect::<Vec<_>>();
        partial_numerators_out.push(partials);

        row_quotients_out.push(encode_qm31(accumulate_row_quotients(
            &sample_batches,
            &queried_values_at_row,
            &q_consts,
            domain_point,
        )));
    }

    let fri_answers_raw = fri_answers(
        TreeVec(column_log_sizes.clone()),
        TreeVec(samples_raw.clone()),
        random_coeff,
        &query_positions,
        TreeVec(queried_values_raw.clone()),
        PCS_LIFTING_LOG_SIZE,
    )
    .ok()?;

    let samples_encoded = samples_raw
        .iter()
        .map(|tree| {
            tree.iter()
                .map(|col| col.iter().map(encode_point_sample).collect())
                .collect()
        })
        .collect();
    let queried_encoded = queried_values_raw
        .iter()
        .map(|tree| {
            tree.iter()
                .map(|col| col.iter().map(|v| encode_m31(*v)).collect())
                .collect()
        })
        .collect();
    let samples_with_randomness_encoded = samples_with_randomness
        .iter()
        .map(|tree| {
            tree.iter()
                .map(|col| {
                    col.iter()
                        .map(|(sample, random_coeff)| SampleWithRandomnessVector {
                            sample: encode_point_sample(sample),
                            random_coeff: encode_qm31(*random_coeff),
                        })
                        .collect()
                })
                .collect()
        })
        .collect();
    let sample_batches_encoded = sample_batches
        .iter()
        .map(|batch| ColumnSampleBatchVector {
            point: encode_secure_circle_point(batch.point),
            cols_vals_randpows: batch
                .cols_vals_randpows
                .iter()
                .map(|data| NumeratorDataVector {
                    column_index: data.column_index,
                    sample_value: encode_qm31(data.sample_value),
                    random_coeff: encode_qm31(data.random_coeff),
                })
                .collect(),
        })
        .collect();
    let line_coeffs_encoded = line_coeffs_raw
        .iter()
        .map(|batch_coeffs| {
            batch_coeffs
                .iter()
                .map(|(a, b, c)| LineCoeffVector {
                    a: encode_qm31(*a),
                    b: encode_qm31(*b),
                    c: encode_qm31(*c),
                })
                .collect()
        })
        .collect();

    Some(PcsQuotientsVector {
        lifting_log_size: PCS_LIFTING_LOG_SIZE,
        column_log_sizes,
        samples: samples_encoded,
        random_coeff: encode_qm31(random_coeff),
        query_positions,
        queried_values: queried_encoded,
        samples_with_randomness: samples_with_randomness_encoded,
        sample_batches: sample_batches_encoded,
        line_coeffs: line_coeffs_encoded,
        denominator_inverses: denominator_inverses_out,
        partial_numerators: partial_numerators_out,
        row_quotients: row_quotients_out,
        fri_answers: fri_answers_raw.into_iter().map(encode_qm31).collect(),
    })
}
