use cairo_air::verifier::verify_cairo;
use cairo_air::CairoProofForRustVerifier;
use std::env;
use std::fs;
use std::panic::{catch_unwind, AssertUnwindSafe};
use stwo::core::vcs_lifted::blake2_merkle::{Blake2sMerkleChannel, Blake2sMerkleHasher};
use stwo_cairo_verifier_adapter::compact_codec::{
    reconstruct_cairo_proof_v1, CompactProtocolV1, CompactStatementV1, COMPONENT_ENABLE_COUNT,
};
use stwo_cairo_verifier_adapter::{
    hex_digest, sha256, CompactProofProvenance, SectionKind, COMPACT_PROOF_PROVENANCE_SOURCE,
    COMPACT_PROOF_SERIALIZATION, HEADER_LEN, MAGIC, REQUIRED_SECTION_COUNT, SECTION_FLAG_MANDATORY,
    VERSION,
};

fn main() -> Result<(), Box<dyn std::error::Error>> {
    let mut args = env::args_os().skip(1);
    let reference_path = args
        .next()
        .ok_or("usage: compact_reference_check <reference-proof.json> <compact-proof>")?;
    let compact_path = args
        .next()
        .ok_or("usage: compact_reference_check <reference-proof.json> <compact-proof>")?;
    let envelope_output = args.next();
    if args.next().is_some() {
        return Err("unexpected trailing argument".into());
    }

    let reference_bytes = fs::read(reference_path)?;
    let reference: CairoProofForRustVerifier<Blake2sMerkleHasher> =
        serde_json::from_slice(&reference_bytes)?;
    let compact_bytes = fs::read(compact_path)?;
    if compact_bytes.len() % 4 != 0 {
        return Err("compact proof byte length is not a u32 multiple".into());
    }

    let flat_claim = reference.claim.flatten_claim();
    let interaction_sum_count = flat_claim.component_log_sizes.len();
    let sampled_value_words: usize = reference
        .stark_proof
        .0
        .sampled_values
        .iter()
        .flat_map(|tree| tree.iter())
        .map(|column| column.len() * 4)
        .sum();
    let fixed_words = 4 * 8 + interaction_sum_count * 4 + 2 + sampled_value_words + 8 * 8 + 4 + 2;
    let total_words = compact_bytes.len() / 4;
    let decommitment_capacity_words = total_words
        .checked_sub(fixed_words)
        .ok_or("compact proof is smaller than its fixed sections")?;
    let component_enable_bits: [bool; COMPONENT_ENABLE_COUNT] = flat_claim
        .component_enable_bits
        .try_into()
        .map_err(|bits: Vec<bool>| format!("expected 83 component slots, found {}", bits.len()))?;

    if reference.preprocessed_trace_variant
        != stwo_cairo_common::preprocessed_columns::preprocessed_trace::PreProcessedTraceVariant::Canonical
    {
        return Err("compact v1 requires the canonical preprocessed trace".into());
    }
    let protocol = CompactProtocolV1::sn2(
        reference.channel_salt,
        interaction_sum_count.try_into()?,
        sampled_value_words.try_into()?,
        decommitment_capacity_words.try_into()?,
        [161, 3449, 2268, 8],
    );
    let statement = CompactStatementV1 {
        public_data: reference.claim.public_data,
        component_enable_bits,
        component_log_sizes: flat_claim.component_log_sizes,
    };
    let reconstructed = reconstruct_cairo_proof_v1(&compact_bytes, &protocol, &statement)?;
    match catch_unwind(AssertUnwindSafe(|| {
        verify_cairo::<Blake2sMerkleChannel>(reconstructed)
    })) {
        Ok(Ok(())) => {
            if let Some(output) = envelope_output.as_ref() {
                let protocol_bytes = protocol.encode()?;
                let statement_bytes = statement.encode()?;
                let diagnostic_identity = hex_digest(sha256(&reference_bytes));
                let provenance = serde_json::to_vec(&CompactProofProvenance {
                    schema_version: 1,
                    source: COMPACT_PROOF_PROVENANCE_SOURCE.to_owned(),
                    proof_serialization: COMPACT_PROOF_SERIALIZATION.to_owned(),
                    protocol_sha256: hex_digest(sha256(&protocol_bytes)),
                    statement_sha256: hex_digest(sha256(&statement_bytes)),
                    proof_sha256: hex_digest(sha256(&compact_bytes)),
                    adapted_input_sha256: diagnostic_identity.clone(),
                    artifact_manifest_sha256: diagnostic_identity.clone(),
                    runner_executable_sha256: diagnostic_identity.clone(),
                    backend_executable_sha256: diagnostic_identity,
                })?;
                fs::write(
                    output,
                    encode_envelope(&[
                        (SectionKind::Protocol, &protocol_bytes),
                        (SectionKind::Statement, &statement_bytes),
                        (SectionKind::Proof, &compact_bytes),
                        (SectionKind::Provenance, &provenance),
                    ]),
                )?;
            }
            println!(
                "verified=true interaction_sums={} sampled_words={} decommitment_words={} proof_bytes={} diagnostic_envelope={}",
                interaction_sum_count,
                sampled_value_words,
                decommitment_capacity_words,
                compact_bytes.len(),
                envelope_output.is_some()
            );
            Ok(())
        }
        Ok(Err(error)) => Err(format!("canonical verifier rejected compact proof: {error}").into()),
        Err(_) => Err("canonical verifier panicked while checking compact proof".into()),
    }
}

fn encode_envelope(sections: &[(SectionKind, &[u8])]) -> Vec<u8> {
    let mut bytes = vec![0_u8; usize::from(HEADER_LEN)];
    bytes[..8].copy_from_slice(&MAGIC);
    bytes[8..10].copy_from_slice(&VERSION.to_le_bytes());
    bytes[10..12].copy_from_slice(&HEADER_LEN.to_le_bytes());
    bytes[16..20].copy_from_slice(&REQUIRED_SECTION_COUNT.to_le_bytes());
    for (kind, payload) in sections {
        bytes.extend_from_slice(&(*kind as u16).to_le_bytes());
        bytes.extend_from_slice(&SECTION_FLAG_MANDATORY.to_le_bytes());
        bytes.extend_from_slice(&0_u32.to_le_bytes());
        bytes.extend_from_slice(&(payload.len() as u64).to_le_bytes());
        bytes.extend_from_slice(&sha256(payload));
        bytes.extend_from_slice(payload);
    }
    let len = bytes.len() as u64;
    bytes[24..32].copy_from_slice(&len.to_le_bytes());
    bytes
}
