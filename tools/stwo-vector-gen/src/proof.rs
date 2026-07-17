use stwo::core::circle::Coset;
use stwo::core::fft::ibutterfly;
use stwo::core::fields::m31::M31;
use stwo::core::fields::qm31::QM31;
use stwo::core::fri::{FriLayerProof, FriProof};
use stwo::core::pcs::quotients::CommitmentSchemeProof;
use stwo::core::pcs::{PcsConfig, TreeVec};
use stwo::core::poly::line::{LineDomain, LinePoly};
use stwo::core::proof::StarkProof;
use stwo::core::utils::bit_reverse;
use stwo::core::vcs_lifted::blake2_merkle::Blake2sMerkleHasher as LiftedMerkleHasher;
use stwo::core::vcs_lifted::verifier::MerkleDecommitmentLifted;

use crate::common::*;
use crate::model::*;

pub(crate) fn generate_proof_extract_oods_vectors(
    state: &mut u64,
    count: usize,
) -> Vec<ProofExtractOodsVector> {
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let composition_log_size = 2 + ((next_u64(state) as u32) % 8);
        let oods_point = sample_secure_point_non_degenerate(state);

        let mut composition_values = Vec::with_capacity(2 * 4);
        for _ in 0..(2 * 4) {
            composition_values.push(sample_qm31(state, false));
        }

        let left = composition_values[0..4]
            .try_into()
            .expect("left composition coordinates length");
        let right = composition_values[4..8]
            .try_into()
            .expect("right composition coordinates length");
        let left_eval = QM31::from_partial_evals(left);
        let right_eval = QM31::from_partial_evals(right);
        let expected =
            left_eval + oods_point.repeated_double(composition_log_size - 2).x * right_eval;

        out.push(ProofExtractOodsVector {
            composition_log_size,
            oods_point: encode_secure_circle_point(oods_point),
            composition_values: composition_values.into_iter().map(encode_qm31).collect(),
            expected: encode_qm31(expected),
        });
    }
    out
}

pub(crate) fn generate_proof_size_vectors(state: &mut u64, count: usize) -> Vec<ProofSizeVector> {
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let commitments_len = 1 + (next_u64(state) as usize % 3);
        let commitments = (0..commitments_len)
            .map(|_| sample_hash(state))
            .collect::<Vec<_>>();

        let sampled_tree_count = 1 + (next_u64(state) as usize % 3);
        let mut sampled_values = Vec::with_capacity(sampled_tree_count);
        for _ in 0..sampled_tree_count {
            let cols = 1 + (next_u64(state) as usize % 3);
            let mut tree = Vec::with_capacity(cols);
            for _ in 0..cols {
                let rows = 1 + (next_u64(state) as usize % 3);
                tree.push(
                    (0..rows)
                        .map(|_| sample_qm31(state, false))
                        .collect::<Vec<_>>(),
                );
            }
            sampled_values.push(tree);
        }

        let decommitment_count = 1 + (next_u64(state) as usize % 3);
        let mut decommitments = Vec::with_capacity(decommitment_count);
        for _ in 0..decommitment_count {
            let witness_len = next_u64(state) as usize % 4;
            decommitments.push(MerkleDecommitmentLifted::<LiftedMerkleHasher> {
                hash_witness: (0..witness_len).map(|_| sample_hash(state)).collect(),
            });
        }

        let queried_tree_count = 1 + (next_u64(state) as usize % 3);
        let mut queried_values = Vec::with_capacity(queried_tree_count);
        for _ in 0..queried_tree_count {
            let cols = 1 + (next_u64(state) as usize % 3);
            let mut tree = Vec::with_capacity(cols);
            for _ in 0..cols {
                let rows = 1 + (next_u64(state) as usize % 3);
                tree.push(
                    (0..rows)
                        .map(|_| sample_m31(state, false))
                        .collect::<Vec<_>>(),
                );
            }
            queried_values.push(tree);
        }

        let first_layer_witness = (0..(next_u64(state) as usize % 4))
            .map(|_| sample_qm31(state, false))
            .collect::<Vec<_>>();
        let first_layer_decommitment = MerkleDecommitmentLifted::<LiftedMerkleHasher> {
            hash_witness: (0..(next_u64(state) as usize % 4))
                .map(|_| sample_hash(state))
                .collect(),
        };
        let first_layer_commitment = sample_hash(state);

        let inner_count = next_u64(state) as usize % 3;
        let mut inner_layers = Vec::with_capacity(inner_count);
        for _ in 0..inner_count {
            inner_layers.push(FriLayerProof {
                fri_witness: (0..(next_u64(state) as usize % 4))
                    .map(|_| sample_qm31(state, false))
                    .collect(),
                decommitment: MerkleDecommitmentLifted::<LiftedMerkleHasher> {
                    hash_witness: (0..(next_u64(state) as usize % 4))
                        .map(|_| sample_hash(state))
                        .collect(),
                },
                commitment: sample_hash(state),
            });
        }

        let last_layer_len = 1usize << (next_u64(state) as usize % 4);
        let last_layer_poly = (0..last_layer_len)
            .map(|_| sample_qm31(state, false))
            .collect::<Vec<_>>();

        let proof = StarkProof::<LiftedMerkleHasher>(CommitmentSchemeProof {
            config: PcsConfig::default(),
            commitments: TreeVec(commitments.clone()),
            sampled_values: TreeVec(sampled_values.clone()),
            decommitments: TreeVec(decommitments.clone()),
            queried_values: TreeVec(queried_values.clone()),
            proof_of_work: next_u64(state),
            fri_proof: FriProof {
                first_layer: FriLayerProof {
                    fri_witness: first_layer_witness.clone(),
                    decommitment: first_layer_decommitment.clone(),
                    commitment: first_layer_commitment,
                },
                inner_layers: inner_layers.clone(),
                last_layer_poly: LinePoly::new(last_layer_poly.clone()),
            },
        });

        let breakdown = proof.size_breakdown_estimate();
        out.push(ProofSizeVector {
            commitments: commitments.into_iter().map(encode_hash).collect(),
            sampled_values: sampled_values
                .into_iter()
                .map(|tree| {
                    tree.into_iter()
                        .map(|col| col.into_iter().map(encode_qm31).collect())
                        .collect()
                })
                .collect(),
            decommitments: decommitments
                .into_iter()
                .map(|decommitment| {
                    decommitment
                        .hash_witness
                        .into_iter()
                        .map(encode_hash)
                        .collect()
                })
                .collect(),
            queried_values: queried_values
                .into_iter()
                .map(|tree| {
                    tree.into_iter()
                        .map(|col| col.into_iter().map(encode_m31).collect())
                        .collect()
                })
                .collect(),
            proof_of_work: proof.0.proof_of_work,
            first_layer_witness: first_layer_witness.into_iter().map(encode_qm31).collect(),
            first_layer_decommitment: first_layer_decommitment
                .hash_witness
                .into_iter()
                .map(encode_hash)
                .collect(),
            first_layer_commitment: encode_hash(first_layer_commitment),
            inner_layers: inner_layers
                .into_iter()
                .map(|layer| ProofSizeInnerLayerVector {
                    fri_witness: layer.fri_witness.into_iter().map(encode_qm31).collect(),
                    decommitment: layer
                        .decommitment
                        .hash_witness
                        .into_iter()
                        .map(encode_hash)
                        .collect(),
                    commitment: encode_hash(layer.commitment),
                })
                .collect(),
            last_layer_poly: last_layer_poly.into_iter().map(encode_qm31).collect(),
            expected_breakdown: ProofSizeBreakdownVector {
                oods_samples: breakdown.oods_samples,
                queries_values: breakdown.queries_values,
                fri_samples: breakdown.fri_samples,
                fri_decommitments: breakdown.fri_decommitments,
                trace_decommitments: breakdown.trace_decommitments,
            },
        });
    }
    out
}

pub(crate) fn generate_prover_line_vectors(state: &mut u64, count: usize) -> Vec<ProverLineVector> {
    let mut out = Vec::with_capacity(count);
    for _ in 0..count {
        let line_log_size = 1 + ((next_u64(state) as u32) % 6);
        let line_len = 1usize << line_log_size;
        let mut values = (0..line_len)
            .map(|_| sample_qm31(state, false))
            .collect::<Vec<_>>();
        let coeffs_bit_reversed = interpolate_line_values(values.clone(), line_log_size);

        let mut coeffs_ordered = coeffs_bit_reversed.clone();
        bit_reverse(&mut coeffs_ordered);

        out.push(ProverLineVector {
            line_log_size,
            values: values.drain(..).map(encode_qm31).collect(),
            coeffs_bit_reversed: coeffs_bit_reversed.into_iter().map(encode_qm31).collect(),
            coeffs_ordered: coeffs_ordered.into_iter().map(encode_qm31).collect(),
        });
    }
    out
}

pub(crate) fn interpolate_line_values(mut values: Vec<QM31>, line_log_size: u32) -> Vec<QM31> {
    bit_reverse(&mut values);
    line_ifft(
        &mut values,
        LineDomain::new(Coset::half_odds(line_log_size)),
    );
    let len_inv = M31::from(values.len() as u32).inverse();
    values.iter_mut().for_each(|v| *v *= len_inv);
    values
}

pub(crate) fn line_ifft(values: &mut [QM31], mut domain: LineDomain) {
    assert_eq!(values.len(), domain.size());
    while domain.size() > 1 {
        for chunk in values.chunks_exact_mut(domain.size()) {
            let (l, r) = chunk.split_at_mut(domain.size() / 2);
            for (i, x) in domain.iter().take(domain.size() / 2).enumerate() {
                ibutterfly(&mut l[i], &mut r[i], x.inverse());
            }
        }
        domain = domain.double();
    }
}
