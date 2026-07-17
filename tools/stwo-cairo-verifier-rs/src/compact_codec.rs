//! Strict codecs and typed reconstruction for the compact Metal proof boundary.
//!
//! Authenticated protocol, statement, and proof bytes are validated before a
//! pinned `StarkProof` and Cairo verifier input are constructed.

use cairo_air::air::{
    MemorySmallValue, PublicData, PublicMemory, PublicSegmentRanges, SegmentRange,
};
use cairo_air::cairo_components::CairoComponents;
use cairo_air::claims::{CairoClaim, CairoInteractionClaim};
use cairo_air::relations::CommonLookupElements;
use cairo_air::CairoProofForRustVerifier;
use serde_json::{Map, Value};
use std::fmt;
use stwo::core::air::Components;
use stwo::core::channel::Blake2sChannel;
use stwo::core::circle::CirclePoint;
use stwo::core::fields::m31::M31;
use stwo::core::fields::qm31::QM31;
use stwo::core::fri::{FriConfig, FriLayerProof, FriProof};
use stwo::core::pcs::quotients::CommitmentSchemeProof;
use stwo::core::pcs::{PcsConfig, TreeVec};
use stwo::core::poly::line::LinePoly;
use stwo::core::proof::StarkProof;
use stwo::core::vcs::blake2_hash::Blake2sHash;
use stwo::core::vcs_lifted::blake2_merkle::Blake2sMerkleHasher;
use stwo::core::vcs_lifted::verifier::MerkleDecommitmentLifted;
use stwo_cairo_common::preprocessed_columns::preprocessed_trace::PreProcessedTraceVariant;
use stwo_cairo_common::prover_types::cpu::CasmState;

pub const PROTOCOL_MAGIC: [u8; 8] = *b"STWZCP1\0";
pub const STATEMENT_MAGIC: [u8; 8] = *b"STWZCS1\0";
pub const CODEC_VERSION: u16 = 1;
pub const PROTOCOL_HEADER_LEN: u16 = 112;
pub const STATEMENT_HEADER_LEN: u16 = 80;
pub const COMPONENT_ENABLE_COUNT: usize = 83;
pub const MEMORY_BIG_START: usize = 49;
pub const MEMORY_BIG_COUNT: usize = 16;
pub const PUBLIC_SEGMENT_COUNT: usize = 11;
pub const MEMORY_ENTRY_WORDS: usize = 9;
pub const HASH_WORDS: usize = 8;
pub const NONCE_WORDS: usize = 2;
pub const M31_PRIME: u32 = 0x7fff_ffff;
pub const DECOMMIT_MAGIC: u32 = 0x4457_5453;
pub const DECOMMIT_VERSION: u32 = 1;
pub const DECOMMIT_HEADER_WORDS: usize = 8;
pub const DECOMMIT_TREE_META_WORDS: usize = 16;
pub const DECOMMIT_AUX_NODE_WORDS: usize = 10;

const BLAKE2S_CHANNEL: u32 = 1;
const RESIDENT_SN2_BUNDLE_V1: u32 = 1;
const PREPROCESSED_CANONICAL: u32 = 1;
const PREPROCESSED_CANONICAL_WITHOUT_PEDERSEN: u32 = 2;
const PREPROCESSED_CANONICAL_SMALL: u32 = 3;
#[cfg(test)]
const EXPECTED_TRACE_COLUMNS: [u32; 4] = [161, 3449, 2268, 8];
const TRACE_TREE_COUNT: u32 = 4;
const LEGACY_MAX_LOG_DEGREE_BOUND: u32 = 24;
const MAX_RUNTIME_LOG_DEGREE_BOUND: u32 = 31;
const MAX_QUERY_COUNT: u32 = 1 << 20;

// Pinned to cairo-air's CairoClaim field order at STWO_CAIRO_REVISION. The
// compact statement stores the flattened 83-slot representation, so this is
// the inverse mapping back to the canonical typed claim.
const CLAIM_FIELD_NAMES: [&str; 68] = [
    "add_opcode",
    "add_opcode_small",
    "add_ap_opcode",
    "assert_eq_opcode",
    "assert_eq_opcode_imm",
    "assert_eq_opcode_double_deref",
    "blake_compress_opcode",
    "call_opcode_abs",
    "call_opcode_rel_imm",
    "generic_opcode",
    "jnz_opcode_non_taken",
    "jnz_opcode_taken",
    "jump_opcode_abs",
    "jump_opcode_double_deref",
    "jump_opcode_rel",
    "jump_opcode_rel_imm",
    "mul_opcode",
    "mul_opcode_small",
    "qm_31_add_mul_opcode",
    "ret_opcode",
    "verify_instruction",
    "blake_round",
    "blake_g",
    "blake_round_sigma",
    "triple_xor_32",
    "verify_bitwise_xor_12",
    "add_mod_builtin",
    "bitwise_builtin",
    "mul_mod_builtin",
    "pedersen_builtin",
    "pedersen_builtin_narrow_windows",
    "poseidon_builtin",
    "range_check96_builtin",
    "range_check_builtin",
    "ec_op_builtin",
    "partial_ec_mul_generic",
    "pedersen_aggregator_window_bits_18",
    "partial_ec_mul_window_bits_18",
    "pedersen_points_table_window_bits_18",
    "pedersen_aggregator_window_bits_9",
    "partial_ec_mul_window_bits_9",
    "pedersen_points_table_window_bits_9",
    "poseidon_aggregator",
    "poseidon_3_partial_rounds_chain",
    "poseidon_full_round_chain",
    "cube_252",
    "poseidon_round_keys",
    "range_check_252_width_27",
    "memory_address_to_id",
    "memory_id_to_big",
    "memory_id_to_small",
    "range_check_6",
    "range_check_8",
    "range_check_11",
    "range_check_12",
    "range_check_18",
    "range_check_20",
    "range_check_4_3",
    "range_check_4_4",
    "range_check_9_9",
    "range_check_7_2_5",
    "range_check_3_6_6_3",
    "range_check_4_4_4_4",
    "range_check_3_3_3_3_3",
    "verify_bitwise_xor_4",
    "verify_bitwise_xor_7",
    "verify_bitwise_xor_8",
    "verify_bitwise_xor_9",
];

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompactCodecError {
    pub code: &'static str,
    pub message: String,
}

impl CompactCodecError {
    fn invalid(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }
}

impl fmt::Display for CompactCodecError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", self.code, self.message)
    }
}

impl std::error::Error for CompactCodecError {}

/// Authenticated protocol and compact-layout geometry for version 1.
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompactProtocolV1 {
    pub preprocessed_trace_variant: PreProcessedTraceVariant,
    pub channel_salt: u32,
    pub query_pow_bits: u32,
    pub log_blowup_factor: u32,
    pub query_count: u32,
    pub log_last_layer_degree_bound: u32,
    pub fri_fold_step: u32,
    pub fri_lifting_log_size: Option<u32>,
    pub interaction_pow_bits: u32,
    pub commitment_count: u32,
    pub sampled_tree_count: u32,
    pub fri_tree_count: u32,
    pub final_line_coefficient_count: u32,
    pub decommitment_record_count: u32,
    pub max_log_degree_bound: u32,
    pub interaction_sum_count: u32,
    pub sampled_value_words: u32,
    pub decommitment_capacity_words: u32,
    pub trace_tree_column_counts: [u32; 4],
}

impl CompactProtocolV1 {
    pub fn sn2(
        channel_salt: u32,
        interaction_sum_count: u32,
        sampled_value_words: u32,
        decommitment_capacity_words: u32,
        trace_tree_column_counts: [u32; 4],
    ) -> Self {
        Self::sn2_for_preprocessed_trace(
            PreProcessedTraceVariant::Canonical,
            channel_salt,
            interaction_sum_count,
            sampled_value_words,
            decommitment_capacity_words,
            trace_tree_column_counts,
        )
    }

    pub fn sn2_for_preprocessed_trace(
        preprocessed_trace_variant: PreProcessedTraceVariant,
        channel_salt: u32,
        interaction_sum_count: u32,
        sampled_value_words: u32,
        decommitment_capacity_words: u32,
        trace_tree_column_counts: [u32; 4],
    ) -> Self {
        Self {
            preprocessed_trace_variant,
            channel_salt,
            query_pow_bits: 26,
            log_blowup_factor: 1,
            query_count: 70,
            log_last_layer_degree_bound: 0,
            fri_fold_step: 3,
            fri_lifting_log_size: None,
            interaction_pow_bits: 24,
            commitment_count: TRACE_TREE_COUNT,
            sampled_tree_count: TRACE_TREE_COUNT,
            fri_tree_count: 8,
            final_line_coefficient_count: 1,
            decommitment_record_count: 12,
            max_log_degree_bound: LEGACY_MAX_LOG_DEGREE_BOUND,
            interaction_sum_count,
            sampled_value_words,
            decommitment_capacity_words,
            trace_tree_column_counts,
        }
    }

    pub fn decode(bytes: &[u8]) -> Result<Self, CompactCodecError> {
        require_exact_len(bytes, usize::from(PROTOCOL_HEADER_LEN), "protocol")?;
        if bytes[..8] != PROTOCOL_MAGIC {
            return Err(invalid_protocol("invalid compact protocol magic"));
        }
        expect_u16(bytes, 8, CODEC_VERSION, "protocol version")?;
        expect_u16(bytes, 10, PROTOCOL_HEADER_LEN, "protocol header length")?;
        expect_u32(bytes, 12, 0, "protocol flags")?;
        expect_u32(bytes, 16, BLAKE2S_CHANNEL, "channel")?;
        expect_u32(bytes, 20, RESIDENT_SN2_BUNDLE_V1, "proof serialization")?;
        let preprocessed_trace_variant =
            decode_preprocessed_trace_variant(read_u32(bytes, 24, "preprocessed variant")?)?;
        let lifting_word = read_u32(bytes, 52, "FRI lifting log size")?;
        let max_log_word = read_u32(bytes, 108, "maximum log degree bound")?;

        let interaction_sum_count = read_u32(bytes, 80, "interaction sum count")?;
        if interaction_sum_count == 0 || interaction_sum_count > COMPONENT_ENABLE_COUNT as u32 {
            return Err(invalid_protocol(format!(
                "interaction sum count {interaction_sum_count} is outside 1..={COMPONENT_ENABLE_COUNT}"
            )));
        }
        let sampled_value_words = read_u32(bytes, 84, "sampled value words")?;
        if sampled_value_words == 0 || sampled_value_words % 4 != 0 {
            return Err(invalid_protocol(
                "sampled value word count must be a nonzero QM31 multiple",
            ));
        }
        let decommitment_capacity_words = read_u32(bytes, 88, "decommitment words")?;
        let mut trace_tree_column_counts = [0_u32; 4];
        for (index, value) in trace_tree_column_counts.iter_mut().enumerate() {
            *value = read_u32(bytes, 92 + index * 4, "trace tree column count")?;
        }
        let protocol = Self {
            preprocessed_trace_variant,
            channel_salt: read_u32(bytes, 28, "channel salt")?,
            query_pow_bits: read_u32(bytes, 32, "query PoW bits")?,
            log_blowup_factor: read_u32(bytes, 36, "log blowup factor")?,
            query_count: read_u32(bytes, 40, "query count")?,
            log_last_layer_degree_bound: read_u32(bytes, 44, "last-layer degree bound")?,
            fri_fold_step: read_u32(bytes, 48, "FRI fold step")?,
            fri_lifting_log_size: if lifting_word == u32::MAX {
                None
            } else {
                Some(lifting_word)
            },
            interaction_pow_bits: read_u32(bytes, 56, "interaction PoW bits")?,
            commitment_count: read_u32(bytes, 60, "commitment count")?,
            sampled_tree_count: read_u32(bytes, 64, "sampled tree count")?,
            fri_tree_count: read_u32(bytes, 68, "FRI tree count")?,
            final_line_coefficient_count: read_u32(bytes, 72, "final line coefficient count")?,
            decommitment_record_count: read_u32(bytes, 76, "decommitment record count")?,
            max_log_degree_bound: if max_log_word == 0 {
                LEGACY_MAX_LOG_DEGREE_BOUND
            } else {
                max_log_word
            },
            interaction_sum_count,
            sampled_value_words,
            decommitment_capacity_words,
            trace_tree_column_counts,
        };
        protocol.validate_geometry()?;
        Ok(protocol)
    }

    pub fn validate_geometry(&self) -> Result<(), CompactCodecError> {
        let expected_preprocessed_columns =
            preprocessed_trace_column_count(self.preprocessed_trace_variant);
        if self.trace_tree_column_counts[0] != expected_preprocessed_columns {
            return Err(invalid_protocol(
                format!(
                    "preprocessed trace variant requires {expected_preprocessed_columns} trace-tree-0 columns, found {}",
                    self.trace_tree_column_counts[0]
                ),
            ));
        }
        if self.query_pow_bits > 64 || self.interaction_pow_bits > 64 {
            return Err(invalid_protocol(
                "proof-of-work bits exceed the nonce width",
            ));
        }
        if !(1..=16).contains(&self.log_blowup_factor)
            || self.query_count == 0
            || self.query_count > MAX_QUERY_COUNT
            || self.log_last_layer_degree_bound > 10
            || self.max_log_degree_bound > MAX_RUNTIME_LOG_DEGREE_BOUND
            || self.max_log_degree_bound <= self.log_last_layer_degree_bound
        {
            return Err(invalid_protocol(
                "PCS runtime geometry is outside supported bounds",
            ));
        }
        if let Some(log_size) = self.fri_lifting_log_size {
            if log_size == 0 || log_size > MAX_RUNTIME_LOG_DEGREE_BOUND {
                return Err(invalid_protocol("FRI lifting log size is outside 1..=31"));
            }
        }
        let expected_fri_layers = fri_layer_count(
            self.max_log_degree_bound,
            self.log_last_layer_degree_bound,
            self.fri_fold_step,
        )?;
        if self.commitment_count != TRACE_TREE_COUNT
            || self.sampled_tree_count != TRACE_TREE_COUNT
            || self.fri_tree_count != expected_fri_layers
            || self.decommitment_record_count
                != self
                    .commitment_count
                    .checked_add(self.fri_tree_count)
                    .ok_or_else(length_overflow)?
        {
            return Err(invalid_protocol(
                "commitment, sampled, FRI, and decommitment counts are inconsistent",
            ));
        }
        let maximum_coefficients = 1_u32 << self.log_last_layer_degree_bound;
        if self.final_line_coefficient_count == 0
            || self.final_line_coefficient_count > maximum_coefficients
        {
            return Err(invalid_protocol(
                "final-line coefficient count exceeds its authenticated degree bound",
            ));
        }
        if self
            .trace_tree_column_counts
            .iter()
            .any(|&count| count == 0)
        {
            return Err(invalid_protocol("trace tree column counts must be nonzero"));
        }
        let minimum_decommit_words = DECOMMIT_HEADER_WORDS
            .checked_add(
                usize::try_from(self.decommitment_record_count)
                    .map_err(|_| length_overflow())?
                    .checked_mul(DECOMMIT_TREE_META_WORDS)
                    .ok_or_else(length_overflow)?,
            )
            .and_then(|value| {
                value.checked_add(usize::try_from(self.query_count).ok()?.checked_mul(2)?)
            })
            .ok_or_else(length_overflow)?;
        if usize::try_from(self.decommitment_capacity_words).map_err(|_| length_overflow())?
            < minimum_decommit_words
        {
            return Err(invalid_protocol(format!(
                "decommitment capacity is smaller than the authenticated minimum {minimum_decommit_words}"
            )));
        }
        Ok(())
    }

    pub fn validate_max_log_degree_bound(&self, derived: u32) -> Result<(), CompactCodecError> {
        self.validate_geometry()?;
        if derived != self.max_log_degree_bound {
            return Err(invalid_protocol(format!(
                "AIR maximum log degree bound {derived} does not match authenticated value {}",
                self.max_log_degree_bound
            )));
        }
        Ok(())
    }

    pub fn proof_word_count(&self) -> Result<usize, CompactCodecError> {
        self.validate_geometry()?;
        let terms = [
            usize_from_u32(self.commitment_count, "commitment count")?
                .checked_mul(HASH_WORDS)
                .ok_or_else(length_overflow)?,
            usize_from_u32(self.interaction_sum_count, "interaction sum count")?
                .checked_mul(4)
                .ok_or_else(length_overflow)?,
            NONCE_WORDS,
            usize_from_u32(self.sampled_value_words, "sampled value words")?,
            usize_from_u32(self.fri_tree_count, "FRI tree count")?
                .checked_mul(HASH_WORDS)
                .ok_or_else(length_overflow)?,
            usize_from_u32(
                self.final_line_coefficient_count,
                "final line coefficient count",
            )?
            .checked_mul(4)
            .ok_or_else(length_overflow)?,
            NONCE_WORDS,
            usize_from_u32(
                self.decommitment_capacity_words,
                "decommitment capacity words",
            )?,
        ];
        terms.into_iter().try_fold(0_usize, |total, term| {
            total.checked_add(term).ok_or_else(length_overflow)
        })
    }

    pub fn encode(&self) -> Result<Vec<u8>, CompactCodecError> {
        self.validate_geometry()?;
        let mut bytes = vec![0_u8; usize::from(PROTOCOL_HEADER_LEN)];
        bytes[..8].copy_from_slice(&PROTOCOL_MAGIC);
        write_u16(&mut bytes, 8, CODEC_VERSION);
        write_u16(&mut bytes, 10, PROTOCOL_HEADER_LEN);
        for (offset, value) in [
            (16, BLAKE2S_CHANNEL),
            (20, RESIDENT_SN2_BUNDLE_V1),
            (
                24,
                encode_preprocessed_trace_variant(self.preprocessed_trace_variant),
            ),
            (28, self.channel_salt),
            (32, self.query_pow_bits),
            (36, self.log_blowup_factor),
            (40, self.query_count),
            (44, self.log_last_layer_degree_bound),
            (48, self.fri_fold_step),
            (52, self.fri_lifting_log_size.unwrap_or(u32::MAX)),
            (56, self.interaction_pow_bits),
            (60, self.commitment_count),
            (64, self.sampled_tree_count),
            (68, self.fri_tree_count),
            (72, self.final_line_coefficient_count),
            (76, self.decommitment_record_count),
            (80, self.interaction_sum_count),
            (84, self.sampled_value_words),
            (88, self.decommitment_capacity_words),
            (92, self.trace_tree_column_counts[0]),
            (96, self.trace_tree_column_counts[1]),
            (100, self.trace_tree_column_counts[2]),
            (104, self.trace_tree_column_counts[3]),
            (
                108,
                if self.max_log_degree_bound == LEGACY_MAX_LOG_DEGREE_BOUND {
                    0
                } else {
                    self.max_log_degree_bound
                },
            ),
        ] {
            write_u32(&mut bytes, offset, value);
        }
        Self::decode(&bytes)?;
        Ok(bytes)
    }
}

fn decode_preprocessed_trace_variant(
    tag: u32,
) -> Result<PreProcessedTraceVariant, CompactCodecError> {
    match tag {
        PREPROCESSED_CANONICAL => Ok(PreProcessedTraceVariant::Canonical),
        PREPROCESSED_CANONICAL_WITHOUT_PEDERSEN => {
            Ok(PreProcessedTraceVariant::CanonicalWithoutPedersen)
        }
        PREPROCESSED_CANONICAL_SMALL => Ok(PreProcessedTraceVariant::CanonicalSmall),
        _ => Err(invalid_protocol(format!(
            "unknown preprocessed trace variant tag {tag}"
        ))),
    }
}

fn encode_preprocessed_trace_variant(variant: PreProcessedTraceVariant) -> u32 {
    match variant {
        PreProcessedTraceVariant::Canonical => PREPROCESSED_CANONICAL,
        PreProcessedTraceVariant::CanonicalWithoutPedersen => {
            PREPROCESSED_CANONICAL_WITHOUT_PEDERSEN
        }
        PreProcessedTraceVariant::CanonicalSmall => PREPROCESSED_CANONICAL_SMALL,
    }
}

fn preprocessed_trace_column_count(variant: PreProcessedTraceVariant) -> u32 {
    match variant {
        PreProcessedTraceVariant::Canonical => 161,
        PreProcessedTraceVariant::CanonicalWithoutPedersen => 105,
        PreProcessedTraceVariant::CanonicalSmall => 156,
    }
}

fn fri_layer_count(
    max_log_degree_bound: u32,
    final_log: u32,
    fold_step: u32,
) -> Result<u32, CompactCodecError> {
    let folds = max_log_degree_bound
        .checked_sub(final_log)
        .filter(|&value| value > 0)
        .ok_or_else(|| invalid_protocol("FRI degree bound does not exceed the final layer"))?;
    if fold_step == 0 || fold_step > folds {
        return Err(invalid_protocol(
            "FRI fold step is outside the folding range",
        ));
    }
    Ok(1 + (folds - 1) / fold_step)
}

/// Statement geometry plus the actual pinned Rust verifier `PublicData` type.
pub struct CompactStatementV1 {
    pub public_data: PublicData,
    pub component_enable_bits: [bool; COMPONENT_ENABLE_COUNT],
    pub component_log_sizes: Vec<u32>,
}

impl CompactStatementV1 {
    pub fn decode(bytes: &[u8]) -> Result<Self, CompactCodecError> {
        if bytes.len() < usize::from(STATEMENT_HEADER_LEN) {
            return Err(invalid_statement("truncated compact statement header"));
        }
        if bytes[..8] != STATEMENT_MAGIC {
            return Err(invalid_statement("invalid compact statement magic"));
        }
        expect_statement_u16(bytes, 8, CODEC_VERSION, "statement version")?;
        expect_statement_u16(bytes, 10, STATEMENT_HEADER_LEN, "statement header length")?;
        expect_statement_u32(bytes, 12, 0, "statement flags")?;
        expect_statement_u32(
            bytes,
            56,
            COMPONENT_ENABLE_COUNT as u32,
            "component enable count",
        )?;
        expect_statement_u32(
            bytes,
            64,
            PUBLIC_SEGMENT_COUNT as u32,
            "public segment count",
        )?;
        expect_statement_u32(bytes, 68, MEMORY_ENTRY_WORDS as u32, "memory entry words")?;
        expect_statement_u32(bytes, 72, 0, "statement reserved field 0")?;
        expect_statement_u32(bytes, 76, 0, "statement reserved field 1")?;

        let program_count = usize_from_u32(
            read_statement_u32(bytes, 48, "program count")?,
            "program count",
        )?;
        let output_count = usize_from_u32(
            read_statement_u32(bytes, 52, "output count")?,
            "output count",
        )?;
        let active_count = usize_from_u32(
            read_statement_u32(bytes, 60, "active component count")?,
            "active component count",
        )?;
        if active_count == 0 || active_count > COMPONENT_ENABLE_COUNT {
            return Err(invalid_statement(format!(
                "active component count {active_count} is outside 1..={COMPONENT_ENABLE_COUNT}"
            )));
        }

        let segments_bytes = PUBLIC_SEGMENT_COUNT
            .checked_mul(5 * 4)
            .ok_or_else(length_overflow)?;
        let memory_count = program_count
            .checked_add(output_count)
            .ok_or_else(length_overflow)?;
        let memory_bytes = memory_count
            .checked_mul(MEMORY_ENTRY_WORDS * 4)
            .ok_or_else(length_overflow)?;
        let expected_len = usize::from(STATEMENT_HEADER_LEN)
            .checked_add(segments_bytes)
            .and_then(|value| value.checked_add(memory_bytes))
            .and_then(|value| value.checked_add(COMPONENT_ENABLE_COUNT * 4))
            .and_then(|value| value.checked_add(active_count * 4))
            .ok_or_else(length_overflow)?;
        require_exact_len(bytes, expected_len, "statement")?;

        let initial_state = decode_state(bytes, 16, "initial state")?;
        let final_state = decode_state(bytes, 28, "final state")?;
        let safe_call_ids = [
            read_m31_word(bytes, 40, "safe call id 0")?,
            read_m31_word(bytes, 44, "safe call id 1")?,
        ];

        let mut cursor = usize::from(STATEMENT_HEADER_LEN);
        let mut segments = Vec::with_capacity(PUBLIC_SEGMENT_COUNT);
        for index in 0..PUBLIC_SEGMENT_COUNT {
            segments.push(decode_segment(bytes, cursor, index)?);
            cursor += 5 * 4;
        }
        if segments[0].is_none() {
            return Err(invalid_statement("the output segment is mandatory"));
        }

        let program = decode_memory_section(bytes, &mut cursor, program_count, "program")?;
        let output = decode_memory_section(bytes, &mut cursor, output_count, "output")?;

        let mut component_enable_bits = [false; COMPONENT_ENABLE_COUNT];
        for (index, enabled) in component_enable_bits.iter_mut().enumerate() {
            *enabled = match read_statement_u32(bytes, cursor, "component enable bit")? {
                0 => false,
                1 => true,
                value => {
                    return Err(invalid_statement(format!(
                        "component enable bit {index} has non-binary value {value}"
                    )))
                }
            };
            cursor += 4;
        }
        let enabled_count = component_enable_bits.iter().filter(|&&value| value).count();
        if enabled_count != active_count {
            return Err(invalid_statement(format!(
                "{enabled_count} enabled components do not match active count {active_count}"
            )));
        }
        let memory_big =
            &component_enable_bits[MEMORY_BIG_START..MEMORY_BIG_START + MEMORY_BIG_COUNT];
        if memory_big.windows(2).any(|pair| !pair[0] && pair[1]) {
            return Err(invalid_statement(
                "memory_id_to_big enable bits are not a contiguous active prefix",
            ));
        }

        let mut component_log_sizes = Vec::with_capacity(active_count);
        for index in 0..active_count {
            let log_size = read_statement_u32(bytes, cursor, "component log size")?;
            if !(1..=30).contains(&log_size) {
                return Err(invalid_statement(format!(
                    "component log size {index} is outside 1..=30 ({log_size})"
                )));
            }
            component_log_sizes.push(log_size);
            cursor += 4;
        }
        debug_assert_eq!(cursor, bytes.len());

        let take = |index: usize| segments[index];
        let public_segments = PublicSegmentRanges {
            output: take(0).expect("mandatory output segment checked above"),
            pedersen: take(1),
            range_check_128: take(2),
            ecdsa: take(3),
            bitwise: take(4),
            ec_op: take(5),
            keccak: take(6),
            poseidon: take(7),
            range_check_96: take(8),
            add_mod: take(9),
            mul_mod: take(10),
        };
        Ok(Self {
            public_data: PublicData {
                public_memory: PublicMemory {
                    program,
                    public_segments,
                    output,
                    safe_call_ids,
                },
                initial_state,
                final_state,
            },
            component_enable_bits,
            component_log_sizes,
        })
    }

    pub fn encode(&self) -> Result<Vec<u8>, CompactCodecError> {
        let active_count = self
            .component_enable_bits
            .iter()
            .filter(|&&bit| bit)
            .count();
        if active_count != self.component_log_sizes.len() {
            return Err(invalid_statement(
                "enabled components do not match the provided log sizes",
            ));
        }
        let program_count: u32 = self
            .public_data
            .public_memory
            .program
            .len()
            .try_into()
            .map_err(|_| length_overflow())?;
        let output_count: u32 = self
            .public_data
            .public_memory
            .output
            .len()
            .try_into()
            .map_err(|_| length_overflow())?;
        let mut bytes = vec![0_u8; usize::from(STATEMENT_HEADER_LEN)];
        bytes[..8].copy_from_slice(&STATEMENT_MAGIC);
        write_u16(&mut bytes, 8, CODEC_VERSION);
        write_u16(&mut bytes, 10, STATEMENT_HEADER_LEN);
        let initial = self.public_data.initial_state;
        let final_state = self.public_data.final_state;
        for (offset, value) in [
            (16, initial.pc.0),
            (20, initial.ap.0),
            (24, initial.fp.0),
            (28, final_state.pc.0),
            (32, final_state.ap.0),
            (36, final_state.fp.0),
            (40, self.public_data.public_memory.safe_call_ids[0]),
            (44, self.public_data.public_memory.safe_call_ids[1]),
            (48, program_count),
            (52, output_count),
            (56, COMPONENT_ENABLE_COUNT as u32),
            (60, active_count as u32),
            (64, PUBLIC_SEGMENT_COUNT as u32),
            (68, MEMORY_ENTRY_WORDS as u32),
        ] {
            write_u32(&mut bytes, offset, value);
        }

        let segments = &self.public_data.public_memory.public_segments;
        for segment in [
            Some(segments.output),
            segments.pedersen,
            segments.range_check_128,
            segments.ecdsa,
            segments.bitwise,
            segments.ec_op,
            segments.keccak,
            segments.poseidon,
            segments.range_check_96,
            segments.add_mod,
            segments.mul_mod,
        ] {
            match segment {
                Some(range) => {
                    push_u32(&mut bytes, 1);
                    push_u32(&mut bytes, range.start_ptr.id);
                    push_u32(&mut bytes, range.start_ptr.value);
                    push_u32(&mut bytes, range.stop_ptr.id);
                    push_u32(&mut bytes, range.stop_ptr.value);
                }
                None => bytes.extend_from_slice(&[0_u8; 20]),
            }
        }
        for (id, value) in self
            .public_data
            .public_memory
            .program
            .iter()
            .chain(&self.public_data.public_memory.output)
        {
            push_u32(&mut bytes, *id);
            for limb in value {
                push_u32(&mut bytes, *limb);
            }
        }
        for enabled in self.component_enable_bits {
            push_u32(&mut bytes, u32::from(enabled));
        }
        for &log_size in &self.component_log_sizes {
            push_u32(&mut bytes, log_size);
        }
        Self::decode(&bytes)?;
        Ok(bytes)
    }
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct CompactProofGeometryV1 {
    pub total_words: usize,
    pub interaction_claim_words: usize,
    pub sampled_value_words: usize,
    pub decommitment_offset_words: usize,
    pub decommitment_used_words: usize,
    pub raw_query_count: u32,
    pub unique_query_count: u32,
}

/// Fully decoded compact sections prior to claim/STARK reconstruction.
pub struct ValidatedCompactSectionsV1 {
    pub protocol: CompactProtocolV1,
    pub statement: CompactStatementV1,
    pub proof_geometry: CompactProofGeometryV1,
}

/// Canonical Cairo claim types reconstructed from the compact Metal boundary.
pub struct ReconstructedClaimsV1 {
    pub cairo_claim: CairoClaim,
    pub interaction_pow: u64,
    pub interaction_claim: CairoInteractionClaim,
}

pub type ReconstructedStarkProofV1 = StarkProof<Blake2sMerkleHasher>;
pub type ReconstructedCairoProofV1 = CairoProofForRustVerifier<Blake2sMerkleHasher>;

#[derive(Clone, Copy)]
struct CompactProofOffsetsV1 {
    interaction_start: usize,
    interaction_pow_start: usize,
    sampled_start: usize,
    fri_commitments_start: usize,
    final_line_start: usize,
    query_pow_start: usize,
    decommitment_start: usize,
}

#[derive(Clone, Copy)]
struct DecommitTreeMetaV1 {
    values_offset: usize,
    values_count: usize,
    fri_witness_offset: usize,
    fri_witness_count: usize,
    hash_witness_offset: usize,
    hash_witness_count: usize,
    query_count: usize,
}

pub fn validate_compact_sections_v1(
    protocol_bytes: &[u8],
    statement_bytes: &[u8],
    proof_bytes: &[u8],
) -> Result<ValidatedCompactSectionsV1, CompactCodecError> {
    let protocol = CompactProtocolV1::decode(protocol_bytes)?;
    let statement = CompactStatementV1::decode(statement_bytes)?;
    let proof_geometry = validate_compact_proof_v1(proof_bytes, &protocol, &statement)?;
    Ok(ValidatedCompactSectionsV1 {
        protocol,
        statement,
        proof_geometry,
    })
}

/// Inverts cairo-air's flattened claim representation and decodes the compact
/// interaction sums into the exact pinned Rust verifier types.
pub fn reconstruct_claims_v1(
    proof_bytes: &[u8],
    protocol: &CompactProtocolV1,
    statement: &CompactStatementV1,
) -> Result<ReconstructedClaimsV1, CompactCodecError> {
    validate_compact_proof_v1(proof_bytes, protocol, statement)?;

    let mut claim_fields = Map::new();
    claim_fields.insert(
        "public_data".to_owned(),
        serde_json::to_value(&statement.public_data).map_err(|error| {
            invalid_statement(format!("failed to encode canonical public data: {error}"))
        })?,
    );
    let mut interaction_fields = Map::new();
    let mut expected_claimed_sums = Vec::with_capacity(protocol.interaction_sum_count as usize);
    let mut active_index = 0_usize;
    let offsets = compact_proof_offsets(protocol);
    let mut interaction_word = offsets.interaction_start;

    for (field_index, name) in CLAIM_FIELD_NAMES.iter().enumerate() {
        let first_slot = claim_field_first_slot(field_index);
        if field_index == 49 {
            let slot_count = statement.component_enable_bits
                [MEMORY_BIG_START..MEMORY_BIG_START + MEMORY_BIG_COUNT]
                .iter()
                .take_while(|&&enabled| enabled)
                .count();
            let mut log_sizes = Vec::with_capacity(slot_count);
            let mut claimed_sums = Vec::with_capacity(slot_count);
            for _ in 0..slot_count {
                log_sizes.push(statement.component_log_sizes[active_index]);
                active_index += 1;
                claimed_sums.push(read_qm31(proof_bytes, interaction_word)?);
                expected_claimed_sums.push(*claimed_sums.last().unwrap());
                interaction_word += 4;
            }
            let claimed_sum = claimed_sums
                .iter()
                .copied()
                .fold(QM31::default(), |total, value| total + value);
            claim_fields.insert(
                (*name).to_owned(),
                object_with("big_log_sizes", serde_json::to_value(log_sizes).unwrap()),
            );
            let mut interaction = Map::new();
            interaction.insert(
                "big_claimed_sums".to_owned(),
                serde_json::to_value(claimed_sums).unwrap(),
            );
            interaction.insert(
                "claimed_sum".to_owned(),
                serde_json::to_value(claimed_sum).unwrap(),
            );
            interaction_fields.insert((*name).to_owned(), Value::Object(interaction));
            continue;
        }

        if !statement.component_enable_bits[first_slot] {
            claim_fields.insert((*name).to_owned(), Value::Null);
            interaction_fields.insert((*name).to_owned(), Value::Null);
            continue;
        }

        let log_size = statement.component_log_sizes[active_index];
        active_index += 1;
        let claim = match fixed_log_size(field_index) {
            Some(expected) if log_size != expected => {
                return Err(invalid_statement(format!(
                    "component {name} has fixed log size {expected}, found {log_size}"
                )))
            }
            Some(_) => Value::Object(Map::new()),
            None => object_with("log_size", Value::from(log_size)),
        };
        claim_fields.insert((*name).to_owned(), claim);

        let claimed_sum = read_qm31(proof_bytes, interaction_word)?;
        expected_claimed_sums.push(claimed_sum);
        interaction_word += 4;
        interaction_fields.insert(
            (*name).to_owned(),
            object_with("claimed_sum", serde_json::to_value(claimed_sum).unwrap()),
        );
    }

    if active_index != statement.component_log_sizes.len()
        || interaction_word != offsets.interaction_pow_start
    {
        return Err(invalid_proof(
            "claim reconstruction did not consume the authenticated component geometry",
        ));
    }

    let cairo_claim: CairoClaim =
        serde_json::from_value(Value::Object(claim_fields)).map_err(|error| {
            invalid_statement(format!(
                "failed to reconstruct canonical CairoClaim: {error}"
            ))
        })?;
    let interaction_claim: CairoInteractionClaim =
        serde_json::from_value(Value::Object(interaction_fields)).map_err(|error| {
            invalid_proof(format!(
                "failed to reconstruct canonical CairoInteractionClaim: {error}"
            ))
        })?;
    let flat_claim = cairo_claim.flatten_claim();
    if flat_claim.component_enable_bits != statement.component_enable_bits
        || flat_claim.component_log_sizes != statement.component_log_sizes
    {
        return Err(invalid_statement(
            "canonical CairoClaim does not re-flatten to the authenticated statement",
        ));
    }
    if interaction_claim.flatten_interaction_claim() != expected_claimed_sums {
        return Err(invalid_proof(
            "canonical CairoInteractionClaim does not re-flatten to the compact proof",
        ));
    }
    let interaction_pow = read_proof_word(proof_bytes, offsets.interaction_pow_start)? as u64
        | (read_proof_word(proof_bytes, offsets.interaction_pow_start + 1)? as u64) << 32;

    Ok(ReconstructedClaimsV1 {
        cairo_claim,
        interaction_pow,
        interaction_claim,
    })
}

/// Translates the compact proof payload into Stwo's exact pinned proof type.
/// `sample_shape` is authenticated statement/AIR metadata: one sample count per
/// column in each authenticated commitment tree. Callers must derive it from the
/// canonical Cairo component graph, never from the flattened proof payload.
pub fn reconstruct_stark_proof_v1(
    proof_bytes: &[u8],
    protocol: &CompactProtocolV1,
    statement: &CompactStatementV1,
    sample_shape: &[Vec<usize>],
) -> Result<ReconstructedStarkProofV1, CompactCodecError> {
    validate_compact_proof_v1(proof_bytes, protocol, statement)?;
    validate_sample_shape(protocol, sample_shape)?;
    let offsets = compact_proof_offsets(protocol);

    let commitments = (0..protocol.commitment_count as usize)
        .map(|index| read_hash(proof_bytes, index * HASH_WORDS))
        .collect::<Result<Vec<_>, _>>()?;

    let mut sampled_values = Vec::with_capacity(protocol.sampled_tree_count as usize);
    let mut sample_word = offsets.sampled_start;
    for tree in sample_shape {
        let mut columns = Vec::with_capacity(tree.len());
        for &count in tree {
            let mut samples = Vec::with_capacity(count);
            for _ in 0..count {
                samples.push(read_qm31(proof_bytes, sample_word)?);
                sample_word += 4;
            }
            columns.push(samples);
        }
        sampled_values.push(columns);
    }
    if sample_word != offsets.fri_commitments_start {
        return Err(invalid_proof(
            "sample shape did not consume the authenticated sampled-value payload",
        ));
    }

    let mut decommitments = Vec::with_capacity(protocol.commitment_count as usize);
    let mut queried_values = Vec::with_capacity(protocol.commitment_count as usize);
    for tree_index in 0..protocol.commitment_count as usize {
        let meta = read_decommit_meta(proof_bytes, offsets.decommitment_start, tree_index)?;
        let expected_columns = protocol.trace_tree_column_counts[tree_index] as usize;
        if meta.values_count != meta.query_count * expected_columns {
            return Err(invalid_proof(format!(
                "trace tree {tree_index} opening shape drifted during reconstruction"
            )));
        }
        let mut columns = Vec::with_capacity(expected_columns);
        for column_index in 0..expected_columns {
            let mut column = Vec::with_capacity(meta.query_count);
            for query_index in 0..meta.query_count {
                let relative = meta.values_offset + column_index * meta.query_count + query_index;
                column.push(read_decommit_m31(
                    proof_bytes,
                    offsets.decommitment_start,
                    relative,
                )?);
            }
            columns.push(column);
        }
        queried_values.push(columns);
        decommitments.push(MerkleDecommitmentLifted {
            hash_witness: read_decommit_hashes(
                proof_bytes,
                offsets.decommitment_start,
                meta.hash_witness_offset,
                meta.hash_witness_count,
            )?,
        });
    }

    let mut fri_layers = Vec::with_capacity(protocol.fri_tree_count as usize);
    for round in 0..protocol.fri_tree_count as usize {
        let meta = read_decommit_meta(
            proof_bytes,
            offsets.decommitment_start,
            protocol.commitment_count as usize + round,
        )?;
        let mut fri_witness = Vec::with_capacity(meta.fri_witness_count);
        for index in 0..meta.fri_witness_count {
            fri_witness.push(read_decommit_qm31(
                proof_bytes,
                offsets.decommitment_start,
                meta.fri_witness_offset + index * 4,
            )?);
        }
        fri_layers.push(FriLayerProof {
            fri_witness,
            decommitment: MerkleDecommitmentLifted {
                hash_witness: read_decommit_hashes(
                    proof_bytes,
                    offsets.decommitment_start,
                    meta.hash_witness_offset,
                    meta.hash_witness_count,
                )?,
            },
            commitment: read_hash(
                proof_bytes,
                offsets.fri_commitments_start + round * HASH_WORDS,
            )?,
        });
    }
    let first_layer = fri_layers.remove(0);
    let mut final_coefficients = Vec::with_capacity(protocol.final_line_coefficient_count as usize);
    for index in 0..protocol.final_line_coefficient_count as usize {
        final_coefficients.push(read_qm31(
            proof_bytes,
            offsets.final_line_start + index * 4,
        )?);
    }
    let last_layer_poly = LinePoly::new(final_coefficients);
    let proof_of_work = read_proof_word(proof_bytes, offsets.query_pow_start)? as u64
        | (read_proof_word(proof_bytes, offsets.query_pow_start + 1)? as u64) << 32;

    Ok(StarkProof(CommitmentSchemeProof {
        config: PcsConfig {
            pow_bits: protocol.query_pow_bits,
            fri_config: FriConfig::new(
                protocol.log_last_layer_degree_bound,
                protocol.log_blowup_factor,
                protocol.query_count as usize,
                protocol.fri_fold_step,
            ),
            lifting_log_size: protocol.fri_lifting_log_size,
        },
        commitments: TreeVec::new(commitments),
        sampled_values: TreeVec::new(sampled_values),
        decommitments: TreeVec::new(decommitments),
        queried_values: TreeVec::new(queried_values),
        proof_of_work,
        fri_proof: FriProof {
            first_layer,
            inner_layers: fri_layers,
            last_layer_poly,
        },
    }))
}

/// Derives the OODS sample cardinalities from the pinned Cairo AIR component
/// graph. Only the cardinalities are used; challenge values cannot affect the
/// component masks' shape.
pub fn derive_sample_shape_v1(
    protocol: &CompactProtocolV1,
    claim: &CairoClaim,
    interaction_claim: &CairoInteractionClaim,
    preprocessed_trace_variant: PreProcessedTraceVariant,
) -> Result<Vec<Vec<usize>>, CompactCodecError> {
    let mut shape_channel = Blake2sChannel::default();
    let lookup_elements = CommonLookupElements::draw(&mut shape_channel);
    let preprocessed = preprocessed_trace_variant.to_preprocessed_trace();
    let cairo_components = CairoComponents::new(
        claim,
        &lookup_elements,
        interaction_claim,
        &preprocessed.ids(),
    );
    let components = Components {
        components: cairo_components.components(),
        n_preprocessed_columns: protocol.trace_tree_column_counts[0] as usize,
    };
    let max_log_degree_bound = components
        .composition_log_degree_bound()
        .checked_sub(1)
        .ok_or_else(|| invalid_statement("invalid Cairo composition degree bound"))?;
    let point = CirclePoint::<QM31>::get_random_point(&mut shape_channel);
    let mut shape: Vec<Vec<usize>> = components
        .mask_points(point, max_log_degree_bound, false)
        .0
        .into_iter()
        .map(|tree| tree.into_iter().map(|samples| samples.len()).collect())
        .collect();
    protocol.validate_max_log_degree_bound(max_log_degree_bound)?;
    shape.push(vec![1; protocol.trace_tree_column_counts[3] as usize]);
    validate_sample_shape(protocol, &shape)?;
    Ok(shape)
}

/// Reconstructs the complete canonical Cairo proof object. This function does
/// not itself verify the proof; callers must pass the result to pinned
/// `verify_cairo` and fail closed on any panic or verification error.
pub fn reconstruct_cairo_proof_v1(
    proof_bytes: &[u8],
    protocol: &CompactProtocolV1,
    statement: &CompactStatementV1,
) -> Result<ReconstructedCairoProofV1, CompactCodecError> {
    let claims = reconstruct_claims_v1(proof_bytes, protocol, statement)?;
    let sample_shape = derive_sample_shape_v1(
        protocol,
        &claims.cairo_claim,
        &claims.interaction_claim,
        protocol.preprocessed_trace_variant,
    )?;
    let stark_proof = reconstruct_stark_proof_v1(proof_bytes, protocol, statement, &sample_shape)?;
    Ok(CairoProofForRustVerifier {
        claim: claims.cairo_claim,
        interaction_pow: claims.interaction_pow,
        interaction_claim: claims.interaction_claim,
        stark_proof,
        channel_salt: protocol.channel_salt,
        preprocessed_trace_variant: protocol.preprocessed_trace_variant,
    })
}

fn validate_sample_shape(
    protocol: &CompactProtocolV1,
    sample_shape: &[Vec<usize>],
) -> Result<(), CompactCodecError> {
    if sample_shape.len() != protocol.sampled_tree_count as usize {
        return Err(invalid_statement(
            "sample shape tree count does not match the authenticated protocol",
        ));
    }
    let mut samples = 0_usize;
    for (tree_index, tree) in sample_shape.iter().enumerate() {
        let expected = protocol.trace_tree_column_counts[tree_index] as usize;
        if tree.len() != expected {
            return Err(invalid_statement(format!(
                "sample tree {tree_index} has {} columns, expected {expected}",
                tree.len()
            )));
        }
        samples = tree.iter().try_fold(samples, |total, &count| {
            total.checked_add(count).ok_or_else(length_overflow)
        })?;
    }
    if samples.checked_mul(4).ok_or_else(length_overflow)? != protocol.sampled_value_words as usize
    {
        return Err(invalid_statement(
            "sample shape does not match the authenticated sampled-value word count",
        ));
    }
    Ok(())
}

fn compact_proof_offsets(protocol: &CompactProtocolV1) -> CompactProofOffsetsV1 {
    let interaction_start = protocol.commitment_count as usize * HASH_WORDS;
    let interaction_pow_start = interaction_start + protocol.interaction_sum_count as usize * 4;
    let sampled_start = interaction_pow_start + NONCE_WORDS;
    let fri_commitments_start = sampled_start + protocol.sampled_value_words as usize;
    let final_line_start = fri_commitments_start + protocol.fri_tree_count as usize * HASH_WORDS;
    let query_pow_start = final_line_start + protocol.final_line_coefficient_count as usize * 4;
    CompactProofOffsetsV1 {
        interaction_start,
        interaction_pow_start,
        sampled_start,
        fri_commitments_start,
        final_line_start,
        query_pow_start,
        decommitment_start: query_pow_start + NONCE_WORDS,
    }
}

fn read_decommit_meta(
    bytes: &[u8],
    decommitment_start: usize,
    tree_index: usize,
) -> Result<DecommitTreeMetaV1, CompactCodecError> {
    let base = decommitment_start + DECOMMIT_HEADER_WORDS + tree_index * DECOMMIT_TREE_META_WORDS;
    Ok(DecommitTreeMetaV1 {
        query_count: read_proof_word(bytes, base + 3)? as usize,
        values_offset: read_proof_word(bytes, base + 4)? as usize,
        values_count: read_proof_word(bytes, base + 5)? as usize,
        fri_witness_offset: read_proof_word(bytes, base + 6)? as usize,
        fri_witness_count: read_proof_word(bytes, base + 7)? as usize,
        hash_witness_offset: read_proof_word(bytes, base + 8)? as usize,
        hash_witness_count: read_proof_word(bytes, base + 9)? as usize,
    })
}

fn read_hash(bytes: &[u8], word_index: usize) -> Result<Blake2sHash, CompactCodecError> {
    let mut hash = [0_u8; 32];
    for index in 0..HASH_WORDS {
        hash[index * 4..index * 4 + 4]
            .copy_from_slice(&read_proof_word(bytes, word_index + index)?.to_le_bytes());
    }
    Ok(Blake2sHash(hash))
}

fn read_decommit_hashes(
    bytes: &[u8],
    decommitment_start: usize,
    offset: usize,
    count: usize,
) -> Result<Vec<Blake2sHash>, CompactCodecError> {
    (0..count)
        .map(|index| read_hash(bytes, decommitment_start + offset + index * HASH_WORDS))
        .collect()
}

fn read_decommit_m31(
    bytes: &[u8],
    decommitment_start: usize,
    offset: usize,
) -> Result<M31, CompactCodecError> {
    let value = read_proof_word(bytes, decommitment_start + offset)?;
    if value >= M31_PRIME {
        return Err(invalid_proof(format!(
            "decommitment M31 word is not canonical ({value})"
        )));
    }
    Ok(M31::from_u32_unchecked(value))
}

fn read_decommit_qm31(
    bytes: &[u8],
    decommitment_start: usize,
    offset: usize,
) -> Result<QM31, CompactCodecError> {
    Ok(QM31::from_m31(
        read_decommit_m31(bytes, decommitment_start, offset)?,
        read_decommit_m31(bytes, decommitment_start, offset + 1)?,
        read_decommit_m31(bytes, decommitment_start, offset + 2)?,
        read_decommit_m31(bytes, decommitment_start, offset + 3)?,
    ))
}

fn claim_field_first_slot(field_index: usize) -> usize {
    if field_index <= 49 {
        field_index
    } else {
        field_index + MEMORY_BIG_COUNT - 1
    }
}

fn fixed_log_size(field_index: usize) -> Option<u32> {
    match field_index {
        23 => Some(4),
        25 => Some(20),
        38 => Some(23),
        41 => Some(15),
        46 => Some(6),
        51 => Some(6),
        52 => Some(8),
        53 => Some(11),
        54 => Some(12),
        55 => Some(18),
        56 => Some(20),
        57 => Some(7),
        58 => Some(8),
        59 => Some(18),
        60 => Some(14),
        61 => Some(18),
        62 => Some(16),
        63 => Some(15),
        64 => Some(8),
        65 => Some(14),
        66 => Some(16),
        67 => Some(18),
        _ => None,
    }
}

fn object_with(name: &str, value: Value) -> Value {
    let mut object = Map::new();
    object.insert(name.to_owned(), value);
    Value::Object(object)
}

fn read_qm31(bytes: &[u8], word_index: usize) -> Result<QM31, CompactCodecError> {
    Ok(QM31::from_u32_unchecked(
        read_proof_word(bytes, word_index)?,
        read_proof_word(bytes, word_index + 1)?,
        read_proof_word(bytes, word_index + 2)?,
        read_proof_word(bytes, word_index + 3)?,
    ))
}

/// Validates compact resident bundle words against authenticated geometry.
pub fn validate_compact_proof_v1(
    bytes: &[u8],
    protocol: &CompactProtocolV1,
    statement: &CompactStatementV1,
) -> Result<CompactProofGeometryV1, CompactCodecError> {
    if protocol.interaction_sum_count as usize != statement.component_log_sizes.len() {
        return Err(invalid_proof(
            "interaction sum count does not match the statement active-component count",
        ));
    }
    let expected_words = protocol.proof_word_count()?;
    let expected_bytes = expected_words.checked_mul(4).ok_or_else(length_overflow)?;
    require_exact_len(bytes, expected_bytes, "proof")
        .map_err(|error| CompactCodecError::invalid("invalid_compact_proof", error.message))?;

    let offsets = compact_proof_offsets(protocol);
    let interaction_start = offsets.interaction_start;
    let interaction_words = protocol.interaction_sum_count as usize * 4;
    let sampled_start = interaction_start + interaction_words + NONCE_WORDS;
    let sampled_words = protocol.sampled_value_words as usize;
    let final_line_start = offsets.final_line_start;
    let final_line_words = protocol.final_line_coefficient_count as usize * 4;
    let decommitment_offset = offsets.decommitment_start;
    validate_canonical_m31(
        bytes,
        interaction_start,
        interaction_words,
        "interaction claim",
    )?;
    validate_canonical_m31(bytes, sampled_start, sampled_words, "sampled values")?;
    validate_canonical_m31(
        bytes,
        final_line_start,
        final_line_words,
        "final line polynomial",
    )?;

    let capacity = protocol.decommitment_capacity_words as usize;
    let word = |index: usize| read_proof_word(bytes, decommitment_offset + index);
    if word(0)? != DECOMMIT_MAGIC || word(1)? != DECOMMIT_VERSION {
        return Err(invalid_proof("invalid versioned decommitment header"));
    }
    if word(2)? != protocol.decommitment_record_count {
        return Err(invalid_proof(format!(
            "decommitment tree count {} does not match authenticated count {}",
            word(2)?,
            protocol.decommitment_record_count
        )));
    }
    let raw_query_count = word(3)?;
    let unique_query_count = word(4)?;
    if raw_query_count != protocol.query_count
        || unique_query_count == 0
        || unique_query_count > raw_query_count
    {
        return Err(invalid_proof(
            "decommitment query counts do not match the authenticated query geometry",
        ));
    }
    let used = word(7)? as usize;
    let record_count = protocol.decommitment_record_count as usize;
    let metadata_end = DECOMMIT_HEADER_WORDS
        .checked_add(
            record_count
                .checked_mul(DECOMMIT_TREE_META_WORDS)
                .ok_or_else(length_overflow)?,
        )
        .ok_or_else(length_overflow)?;
    if used < metadata_end || used > capacity {
        return Err(invalid_proof(
            "decommitment used-word count is outside its authenticated capacity",
        ));
    }
    checked_word_range(
        word(5)? as usize,
        raw_query_count as usize,
        used,
        "raw queries",
    )?;
    checked_word_range(
        word(6)? as usize,
        unique_query_count as usize,
        used,
        "unique queries",
    )?;

    for index in 0..record_count {
        let base = DECOMMIT_HEADER_WORDS + index * DECOMMIT_TREE_META_WORDS;
        let kind = word(base)?;
        let role = word(base + 1)?;
        let expected_kind = u32::from(index >= protocol.commitment_count as usize);
        if kind != expected_kind || role != index as u32 {
            return Err(invalid_proof(format!(
                "decommitment record {index} has kind/role {kind}/{role}, expected {expected_kind}/{index}"
            )));
        }
        let query_count = word(base + 3)? as usize;
        let leaf_log_size = word(base + 14)?;
        let tree_used_words = word(base + 15)?;
        if query_count == 0
            || query_count > unique_query_count as usize
            || leaf_log_size == 0
            || leaf_log_size > 30
            || tree_used_words == 0
        {
            return Err(invalid_proof(format!(
                "decommitment record {index} has invalid query/log/used geometry"
            )));
        }
        if index >= protocol.commitment_count as usize && word(base + 5)? != 0 {
            return Err(invalid_proof(format!(
                "FRI decommitment record {index} unexpectedly contains trace values"
            )));
        }
        if index < protocol.commitment_count as usize {
            if word(base + 7)? != 0 {
                return Err(invalid_proof(format!(
                    "trace decommitment record {index} unexpectedly contains FRI witnesses"
                )));
            }
            let expected_values = query_count
                .checked_mul(protocol.trace_tree_column_counts[index] as usize)
                .ok_or_else(length_overflow)?;
            if word(base + 5)? as usize != expected_values {
                return Err(invalid_proof(format!(
                    "trace decommitment record {index} has {} values, expected {expected_values}",
                    word(base + 5)?
                )));
            }
        }
        checked_meta_range(&word, base + 2, base + 3, 1, used, "queries")?;
        checked_meta_range(&word, base + 4, base + 5, 1, used, "values")?;
        checked_meta_range(&word, base + 6, base + 7, 4, used, "FRI witnesses")?;
        checked_meta_range(
            &word,
            base + 8,
            base + 9,
            HASH_WORDS,
            used,
            "hash witnesses",
        )?;
        checked_meta_range(
            &word,
            base + 10,
            base + 11,
            DECOMMIT_AUX_NODE_WORDS,
            used,
            "auxiliary nodes",
        )?;
        checked_meta_range(&word, base + 12, base + 13, 5, used, "all-values rows")?;
    }

    Ok(CompactProofGeometryV1 {
        total_words: expected_words,
        interaction_claim_words: interaction_words,
        sampled_value_words: sampled_words,
        decommitment_offset_words: decommitment_offset,
        decommitment_used_words: used,
        raw_query_count,
        unique_query_count,
    })
}

fn decode_state(bytes: &[u8], offset: usize, label: &str) -> Result<CasmState, CompactCodecError> {
    Ok(CasmState {
        pc: M31::from_u32_unchecked(read_m31_word(bytes, offset, label)?),
        ap: M31::from_u32_unchecked(read_m31_word(bytes, offset + 4, label)?),
        fp: M31::from_u32_unchecked(read_m31_word(bytes, offset + 8, label)?),
    })
}

fn decode_segment(
    bytes: &[u8],
    offset: usize,
    index: usize,
) -> Result<Option<SegmentRange>, CompactCodecError> {
    let present = read_statement_u32(bytes, offset, "segment presence")?;
    let fields = [
        read_statement_u32(bytes, offset + 4, "segment start id")?,
        read_statement_u32(bytes, offset + 8, "segment start value")?,
        read_statement_u32(bytes, offset + 12, "segment stop id")?,
        read_statement_u32(bytes, offset + 16, "segment stop value")?,
    ];
    match present {
        0 if fields == [0; 4] && index != 0 => Ok(None),
        0 => Err(invalid_statement(format!(
            "absent segment {index} is not canonically zero"
        ))),
        1 => {
            for value in fields {
                require_m31(value, "segment pointer")?;
            }
            Ok(Some(SegmentRange {
                start_ptr: MemorySmallValue {
                    id: fields[0],
                    value: fields[1],
                },
                stop_ptr: MemorySmallValue {
                    id: fields[2],
                    value: fields[3],
                },
            }))
        }
        value => Err(invalid_statement(format!(
            "segment {index} has invalid presence value {value}"
        ))),
    }
}

fn decode_memory_section(
    bytes: &[u8],
    cursor: &mut usize,
    count: usize,
    label: &str,
) -> Result<Vec<(u32, [u32; 8])>, CompactCodecError> {
    let mut result = Vec::with_capacity(count);
    for index in 0..count {
        let id = read_statement_u32(bytes, *cursor, "public memory id")?;
        require_m31(id, "public memory id")?;
        let mut value = [0_u32; 8];
        for (limb_index, limb) in value.iter_mut().enumerate() {
            *limb = read_statement_u32(bytes, *cursor + 4 + limb_index * 4, "felt limb")?;
        }
        result.push((id, value));
        *cursor += MEMORY_ENTRY_WORDS * 4;
        let _ = (label, index);
    }
    Ok(result)
}

fn validate_canonical_m31(
    bytes: &[u8],
    start_word: usize,
    count: usize,
    label: &str,
) -> Result<(), CompactCodecError> {
    for index in 0..count {
        let value = read_proof_word(bytes, start_word + index)?;
        if value >= M31_PRIME {
            return Err(invalid_proof(format!(
                "{label} word {index} is not canonical M31 ({value})"
            )));
        }
    }
    Ok(())
}

fn checked_meta_range<F>(
    word: &F,
    offset_index: usize,
    count_index: usize,
    stride: usize,
    used: usize,
    label: &str,
) -> Result<(), CompactCodecError>
where
    F: Fn(usize) -> Result<u32, CompactCodecError>,
{
    let offset = word(offset_index)? as usize;
    let count = (word(count_index)? as usize)
        .checked_mul(stride)
        .ok_or_else(length_overflow)?;
    checked_word_range(offset, count, used, label)
}

fn checked_word_range(
    offset: usize,
    count: usize,
    used: usize,
    label: &str,
) -> Result<(), CompactCodecError> {
    if count == 0 && offset == 0 {
        return Ok(());
    }
    let end = offset.checked_add(count).ok_or_else(length_overflow)?;
    if end > used {
        return Err(invalid_proof(format!(
            "{label} range {offset}..{end} exceeds decommitment used words {used}"
        )));
    }
    Ok(())
}

fn read_proof_word(bytes: &[u8], word_index: usize) -> Result<u32, CompactCodecError> {
    read_u32(
        bytes,
        word_index.checked_mul(4).ok_or_else(length_overflow)?,
        "proof word",
    )
    .map_err(|error| CompactCodecError::invalid("invalid_compact_proof", error.message))
}

fn read_m31_word(bytes: &[u8], offset: usize, label: &str) -> Result<u32, CompactCodecError> {
    let value = read_statement_u32(bytes, offset, label)?;
    require_m31(value, label)?;
    Ok(value)
}

fn require_m31(value: u32, label: &str) -> Result<(), CompactCodecError> {
    if value >= M31_PRIME {
        return Err(invalid_statement(format!(
            "{label} is not canonical M31 ({value})"
        )));
    }
    Ok(())
}

fn write_u16(bytes: &mut [u8], offset: usize, value: u16) {
    bytes[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
}

fn write_u32(bytes: &mut [u8], offset: usize, value: u32) {
    bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
}

fn push_u32(bytes: &mut Vec<u8>, value: u32) {
    bytes.extend_from_slice(&value.to_le_bytes());
}

fn expect_u16(
    bytes: &[u8],
    offset: usize,
    expected: u16,
    label: &str,
) -> Result<(), CompactCodecError> {
    let actual = read_u16(bytes, offset, label)?;
    if actual != expected {
        return Err(invalid_protocol(format!(
            "{label} is {actual}, expected {expected}"
        )));
    }
    Ok(())
}

fn expect_u32(
    bytes: &[u8],
    offset: usize,
    expected: u32,
    label: &str,
) -> Result<(), CompactCodecError> {
    let actual = read_u32(bytes, offset, label)?;
    if actual != expected {
        return Err(invalid_protocol(format!(
            "{label} is {actual}, expected {expected}"
        )));
    }
    Ok(())
}

fn expect_statement_u16(
    bytes: &[u8],
    offset: usize,
    expected: u16,
    label: &str,
) -> Result<(), CompactCodecError> {
    let actual = read_u16(bytes, offset, label).map_err(as_statement_error)?;
    if actual != expected {
        return Err(invalid_statement(format!(
            "{label} is {actual}, expected {expected}"
        )));
    }
    Ok(())
}

fn expect_statement_u32(
    bytes: &[u8],
    offset: usize,
    expected: u32,
    label: &str,
) -> Result<(), CompactCodecError> {
    let actual = read_statement_u32(bytes, offset, label)?;
    if actual != expected {
        return Err(invalid_statement(format!(
            "{label} is {actual}, expected {expected}"
        )));
    }
    Ok(())
}

fn read_statement_u32(bytes: &[u8], offset: usize, label: &str) -> Result<u32, CompactCodecError> {
    read_u32(bytes, offset, label).map_err(as_statement_error)
}

fn read_u16(bytes: &[u8], offset: usize, label: &str) -> Result<u16, CompactCodecError> {
    let raw = bytes
        .get(offset..offset + 2)
        .ok_or_else(|| invalid_protocol(format!("truncated {label}")))?;
    Ok(u16::from_le_bytes(raw.try_into().expect("two-byte slice")))
}

fn read_u32(bytes: &[u8], offset: usize, label: &str) -> Result<u32, CompactCodecError> {
    let raw = bytes
        .get(offset..offset + 4)
        .ok_or_else(|| invalid_protocol(format!("truncated {label}")))?;
    Ok(u32::from_le_bytes(raw.try_into().expect("four-byte slice")))
}

fn require_exact_len(bytes: &[u8], expected: usize, label: &str) -> Result<(), CompactCodecError> {
    if bytes.len() != expected {
        return Err(CompactCodecError::invalid(
            match label {
                "statement" => "invalid_compact_statement",
                "proof" => "invalid_compact_proof",
                _ => "invalid_compact_protocol",
            },
            format!("{label} length is {}, expected {expected}", bytes.len()),
        ));
    }
    Ok(())
}

fn usize_from_u32(value: u32, label: &str) -> Result<usize, CompactCodecError> {
    usize::try_from(value).map_err(|_| {
        CompactCodecError::invalid(
            "compact_length_overflow",
            format!("{label} does not fit usize"),
        )
    })
}

fn invalid_protocol(message: impl Into<String>) -> CompactCodecError {
    CompactCodecError::invalid("invalid_compact_protocol", message)
}

fn invalid_statement(message: impl Into<String>) -> CompactCodecError {
    CompactCodecError::invalid("invalid_compact_statement", message)
}

fn invalid_proof(message: impl Into<String>) -> CompactCodecError {
    CompactCodecError::invalid("invalid_compact_proof", message)
}

fn as_statement_error(error: CompactCodecError) -> CompactCodecError {
    invalid_statement(error.message)
}

fn length_overflow() -> CompactCodecError {
    CompactCodecError::invalid(
        "compact_length_overflow",
        "compact codec length arithmetic overflow",
    )
}

#[cfg(test)]
pub(crate) mod tests_support {
    use super::*;

    pub fn protocol_bytes_for_lib_tests() -> Vec<u8> {
        CompactProtocolV1::sn2(0, 2, 4, 4000, EXPECTED_TRACE_COLUMNS)
            .encode()
            .unwrap()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn put_u16(bytes: &mut [u8], offset: usize, value: u16) {
        bytes[offset..offset + 2].copy_from_slice(&value.to_le_bytes());
    }

    fn put_u32(bytes: &mut [u8], offset: usize, value: u32) {
        bytes[offset..offset + 4].copy_from_slice(&value.to_le_bytes());
    }

    fn protocol(active: u32, sampled: u32, decommit: u32) -> Vec<u8> {
        let mut bytes = vec![0_u8; PROTOCOL_HEADER_LEN as usize];
        bytes[..8].copy_from_slice(&PROTOCOL_MAGIC);
        put_u16(&mut bytes, 8, CODEC_VERSION);
        put_u16(&mut bytes, 10, PROTOCOL_HEADER_LEN);
        for (offset, value) in [
            (16, 1),
            (20, 1),
            (24, 1),
            (32, 26),
            (36, 1),
            (40, 70),
            (48, 3),
            (52, u32::MAX),
            (56, 24),
            (60, 4),
            (64, 4),
            (68, 8),
            (72, 1),
            (76, 12),
            (80, active),
            (84, sampled),
            (88, decommit),
            (92, 161),
            (96, 3449),
            (100, 2268),
            (104, 8),
        ] {
            put_u32(&mut bytes, offset, value);
        }
        bytes
    }

    fn real_fib_tag_two_protocol() -> Vec<u8> {
        let mut bytes = protocol(30, 3564, 2_077_800);
        put_u32(&mut bytes, 24, PREPROCESSED_CANONICAL_WITHOUT_PEDERSEN);
        put_u32(&mut bytes, 68, 7);
        put_u32(&mut bytes, 76, 11);
        for (offset, columns) in [(92, 105), (96, 396), (100, 324), (104, 8)] {
            put_u32(&mut bytes, offset, columns);
        }
        put_u32(&mut bytes, 108, 20);
        bytes
    }

    fn statement(active: usize) -> Vec<u8> {
        let len = STATEMENT_HEADER_LEN as usize
            + PUBLIC_SEGMENT_COUNT * 5 * 4
            + COMPONENT_ENABLE_COUNT * 4
            + active * 4;
        let mut bytes = vec![0_u8; len];
        bytes[..8].copy_from_slice(&STATEMENT_MAGIC);
        put_u16(&mut bytes, 8, CODEC_VERSION);
        put_u16(&mut bytes, 10, STATEMENT_HEADER_LEN);
        put_u32(&mut bytes, 56, COMPONENT_ENABLE_COUNT as u32);
        put_u32(&mut bytes, 60, active as u32);
        put_u32(&mut bytes, 64, PUBLIC_SEGMENT_COUNT as u32);
        put_u32(&mut bytes, 68, MEMORY_ENTRY_WORDS as u32);
        let segments = STATEMENT_HEADER_LEN as usize;
        put_u32(&mut bytes, segments, 1);
        let enable = segments + PUBLIC_SEGMENT_COUNT * 5 * 4;
        for index in 0..active {
            put_u32(&mut bytes, enable + index * 4, 1);
        }
        let logs = enable + COMPONENT_ENABLE_COUNT * 4;
        for index in 0..active {
            put_u32(&mut bytes, logs + index * 4, 4);
        }
        bytes
    }

    fn proof(protocol: &CompactProtocolV1) -> Vec<u8> {
        let words = protocol.proof_word_count().unwrap();
        let mut bytes = vec![0_u8; words * 4];
        let decommit = words - protocol.decommitment_capacity_words as usize;
        let set = |bytes: &mut [u8], index: usize, value: u32| put_u32(bytes, index * 4, value);
        set(&mut bytes, decommit, DECOMMIT_MAGIC);
        set(&mut bytes, decommit + 1, DECOMMIT_VERSION);
        set(&mut bytes, decommit + 2, protocol.decommitment_record_count);
        set(&mut bytes, decommit + 3, protocol.query_count);
        set(&mut bytes, decommit + 4, protocol.query_count);
        set(&mut bytes, decommit + 5, 200);
        set(&mut bytes, decommit + 6, 200 + protocol.query_count);
        set(
            &mut bytes,
            decommit + 7,
            protocol.decommitment_capacity_words,
        );
        for index in 0..protocol.decommitment_record_count as usize {
            let base = decommit + 8 + index * 16;
            set(
                &mut bytes,
                base,
                u32::from(index >= protocol.commitment_count as usize),
            );
            set(&mut bytes, base + 1, index as u32);
            set(&mut bytes, base + 2, 200);
            set(&mut bytes, base + 3, 1);
            if index < protocol.commitment_count as usize {
                set(
                    &mut bytes,
                    base + 5,
                    protocol.trace_tree_column_counts[index],
                );
            }
            set(
                &mut bytes,
                base + 14,
                protocol.decommitment_record_count - index as u32,
            );
            set(&mut bytes, base + 15, 1);
        }
        bytes
    }

    fn structurally_decodable_proof(protocol: &CompactProtocolV1) -> Vec<u8> {
        let mut bytes = proof(protocol);
        let offsets = compact_proof_offsets(protocol);
        let decommit = offsets.decommitment_start;
        let set = |bytes: &mut [u8], index: usize, value: u32| put_u32(bytes, index * 4, value);
        for index in 0..protocol.decommitment_capacity_words as usize {
            set(&mut bytes, decommit + index, 0);
        }
        set(&mut bytes, decommit, DECOMMIT_MAGIC);
        set(&mut bytes, decommit + 1, DECOMMIT_VERSION);
        set(&mut bytes, decommit + 2, protocol.decommitment_record_count);
        set(&mut bytes, decommit + 3, protocol.query_count);
        set(&mut bytes, decommit + 4, 1);
        set(&mut bytes, decommit + 5, 200);
        set(&mut bytes, decommit + 6, 201);
        set(&mut bytes, decommit + 200, 7);
        set(&mut bytes, decommit + 201, 7);
        let mut cursor = 202_usize;
        for index in 0..protocol.decommitment_record_count as usize {
            let base = decommit + DECOMMIT_HEADER_WORDS + index * DECOMMIT_TREE_META_WORDS;
            let tree_start = cursor;
            set(
                &mut bytes,
                base,
                u32::from(index >= protocol.commitment_count as usize),
            );
            set(&mut bytes, base + 1, index as u32);
            set(&mut bytes, base + 2, 201);
            set(&mut bytes, base + 3, 1);
            if index < protocol.commitment_count as usize {
                let count = protocol.trace_tree_column_counts[index] as usize;
                set(&mut bytes, base + 4, cursor as u32);
                set(&mut bytes, base + 5, count as u32);
                cursor += count;
            }
            set(
                &mut bytes,
                base + 14,
                protocol.decommitment_record_count - index as u32,
            );
            set(&mut bytes, base + 15, (cursor - tree_start).max(1) as u32);
        }
        let used = cursor.max(200 + protocol.query_count as usize);
        set(&mut bytes, decommit + 7, used as u32);
        set(&mut bytes, offsets.query_pow_start, 0x7654_3210);
        set(&mut bytes, offsets.query_pow_start + 1, 0xfedc_ba98);
        bytes
    }

    fn composition_only_sample_shape(protocol: &CompactProtocolV1) -> Vec<Vec<usize>> {
        vec![
            vec![0; protocol.trace_tree_column_counts[0] as usize],
            vec![0; protocol.trace_tree_column_counts[1] as usize],
            vec![0; protocol.trace_tree_column_counts[2] as usize],
            vec![1; protocol.trace_tree_column_counts[3] as usize],
        ]
    }

    fn fib_like_protocol() -> CompactProtocolV1 {
        let mut protocol = CompactProtocolV1::sn2_for_preprocessed_trace(
            PreProcessedTraceVariant::CanonicalWithoutPedersen,
            9,
            2,
            32,
            400,
            [105, 7, 3, 8],
        );
        protocol.max_log_degree_bound = 20;
        protocol.fri_tree_count = 7;
        protocol.decommitment_record_count = 11;
        protocol.validate_geometry().unwrap();
        protocol
    }

    #[test]
    fn decodes_typed_statement_and_validates_compact_proof_geometry() {
        let protocol_bytes = protocol(2, 4, 4000);
        let statement_bytes = statement(2);
        let protocol = CompactProtocolV1::decode(&protocol_bytes).unwrap();
        let validated =
            validate_compact_sections_v1(&protocol_bytes, &statement_bytes, &proof(&protocol))
                .unwrap();
        assert_eq!(validated.statement.component_log_sizes, [4, 4]);
        assert_eq!(
            validated.statement.public_data.initial_state,
            CasmState::default()
        );
        assert_eq!(validated.proof_geometry.interaction_claim_words, 8);
        assert_eq!(validated.proof_geometry.decommitment_used_words, 4000);
        assert_eq!(validated.proof_geometry.raw_query_count, 70);
        assert_eq!(
            validated.protocol.preprocessed_trace_variant,
            PreProcessedTraceVariant::Canonical
        );
        assert_eq!(validated.protocol.encode().unwrap(), protocol_bytes);
        assert_eq!(validated.statement.encode().unwrap(), statement_bytes);
    }

    #[test]
    fn preprocessed_trace_variants_have_stable_tags_and_exact_tree_widths() {
        for (variant, wire_tag, preprocessed_columns) in [
            (PreProcessedTraceVariant::Canonical, 1, 161),
            (PreProcessedTraceVariant::CanonicalWithoutPedersen, 2, 105),
            (PreProcessedTraceVariant::CanonicalSmall, 3, 156),
        ] {
            let protocol = CompactProtocolV1::sn2_for_preprocessed_trace(
                variant,
                9,
                2,
                4,
                4000,
                [preprocessed_columns, 3449, 2268, 8],
            );
            let encoded = protocol.encode().unwrap();
            assert_eq!(
                read_u32(&encoded, 24, "preprocessed variant").unwrap(),
                wire_tag
            );
            assert_eq!(
                read_u32(&encoded, 92, "trace-tree-0 columns").unwrap(),
                preprocessed_columns
            );
            assert_eq!(CompactProtocolV1::decode(&encoded).unwrap(), protocol);
        }
    }

    #[test]
    fn decodes_real_fib_tag_two_protocol_geometry() {
        use sha2::{Digest, Sha256};

        let bytes = real_fib_tag_two_protocol();
        assert_eq!(
            format!("{:x}", Sha256::digest(&bytes)),
            "52921cfab4fde413abc484a6c39d363b88dd729c19acef620670af60c6da9286"
        );
        let protocol = CompactProtocolV1::decode(&bytes).unwrap();
        assert_eq!(
            protocol.preprocessed_trace_variant,
            PreProcessedTraceVariant::CanonicalWithoutPedersen
        );
        assert_eq!(protocol.trace_tree_column_counts, [105, 396, 324, 8]);
        assert_eq!(protocol.interaction_sum_count, 30);
        assert_eq!(protocol.sampled_value_words, 3564);
        assert_eq!(protocol.decommitment_capacity_words, 2_077_800);
        assert_eq!(protocol.max_log_degree_bound, 20);
        assert_eq!(protocol.encode().unwrap(), bytes);
    }

    #[test]
    fn preprocessed_trace_variants_reject_unknown_and_mismatched_geometry() {
        let canonical = protocol(2, 4, 4000);
        for unknown_tag in [0, 4, u32::MAX] {
            let mut bytes = canonical.clone();
            put_u32(&mut bytes, 24, unknown_tag);
            let error = CompactProtocolV1::decode(&bytes).unwrap_err();
            assert_eq!(error.code, "invalid_compact_protocol");
            assert!(error
                .message
                .contains("unknown preprocessed trace variant tag"));
        }

        for (wire_tag, wrong_columns) in [(1, 105), (2, 156), (3, 161)] {
            let mut bytes = canonical.clone();
            put_u32(&mut bytes, 24, wire_tag);
            put_u32(&mut bytes, 92, wrong_columns);
            let error = CompactProtocolV1::decode(&bytes).unwrap_err();
            assert_eq!(error.code, "invalid_compact_protocol");
            assert!(error.message.contains("trace-tree-0 columns"));
        }

        let mismatched = CompactProtocolV1::sn2_for_preprocessed_trace(
            PreProcessedTraceVariant::CanonicalSmall,
            9,
            2,
            4,
            4000,
            EXPECTED_TRACE_COLUMNS,
        );
        assert!(mismatched.encode().is_err());
    }

    #[test]
    fn reconstructs_pinned_cairo_claim_types_from_compact_words() {
        let protocol = CompactProtocolV1::decode(&protocol(2, 4, 4000)).unwrap();
        let statement = CompactStatementV1::decode(&statement(2)).unwrap();
        let mut proof = proof(&protocol);
        let interaction_start = 4 * HASH_WORDS;
        for (index, value) in (1_u32..=8).enumerate() {
            put_u32(&mut proof, (interaction_start + index) * 4, value);
        }
        put_u32(&mut proof, (interaction_start + 8) * 4, 0x89ab_cdef);
        put_u32(&mut proof, (interaction_start + 9) * 4, 0x0123_4567);

        let reconstructed = reconstruct_claims_v1(&proof, &protocol, &statement).unwrap();
        let flat_claim = reconstructed.cairo_claim.flatten_claim();
        assert_eq!(
            flat_claim.component_enable_bits,
            statement.component_enable_bits
        );
        assert_eq!(
            flat_claim.component_log_sizes,
            statement.component_log_sizes
        );
        assert_eq!(
            reconstructed.interaction_claim.flatten_interaction_claim(),
            [
                QM31::from_u32_unchecked(1, 2, 3, 4),
                QM31::from_u32_unchecked(5, 6, 7, 8),
            ]
        );
        assert_eq!(reconstructed.interaction_pow, 0x0123_4567_89ab_cdef);
    }

    #[test]
    fn reconstructs_memory_big_prefix_and_aggregate_claim() {
        let mut statement_bytes = statement(1);
        let enable = STATEMENT_HEADER_LEN as usize + PUBLIC_SEGMENT_COUNT * 5 * 4;
        put_u32(&mut statement_bytes, enable, 0);
        put_u32(&mut statement_bytes, enable + MEMORY_BIG_START * 4, 1);
        let protocol = CompactProtocolV1::decode(&protocol(1, 4, 4000)).unwrap();
        let statement = CompactStatementV1::decode(&statement_bytes).unwrap();
        let mut proof = proof(&protocol);
        for (index, value) in [9_u32, 10, 11, 12].into_iter().enumerate() {
            put_u32(&mut proof, (4 * HASH_WORDS + index) * 4, value);
        }

        let reconstructed = reconstruct_claims_v1(&proof, &protocol, &statement).unwrap();
        let flat_claim = reconstructed.cairo_claim.flatten_claim();
        assert_eq!(
            flat_claim.component_enable_bits,
            statement.component_enable_bits
        );
        assert_eq!(
            flat_claim.component_log_sizes,
            statement.component_log_sizes
        );
        let sum = QM31::from_u32_unchecked(9, 10, 11, 12);
        assert_eq!(
            reconstructed.interaction_claim.flatten_interaction_claim(),
            [sum]
        );
        assert_eq!(
            reconstructed
                .interaction_claim
                .memory_id_to_big
                .unwrap()
                .claimed_sum,
            sum
        );
    }

    #[test]
    fn reconstructs_all_83_flattened_component_slots() {
        let mut statement_bytes = statement(COMPONENT_ENABLE_COUNT);
        let enable = STATEMENT_HEADER_LEN as usize + PUBLIC_SEGMENT_COUNT * 5 * 4;
        let logs = enable + COMPONENT_ENABLE_COUNT * 4;
        for field_index in 0..CLAIM_FIELD_NAMES.len() {
            if let Some(log_size) = fixed_log_size(field_index) {
                put_u32(
                    &mut statement_bytes,
                    logs + claim_field_first_slot(field_index) * 4,
                    log_size,
                );
            }
        }
        let protocol =
            CompactProtocolV1::decode(&protocol(COMPONENT_ENABLE_COUNT as u32, 4, 4000)).unwrap();
        let statement = CompactStatementV1::decode(&statement_bytes).unwrap();
        let proof = proof(&protocol);
        let reconstructed = reconstruct_claims_v1(&proof, &protocol, &statement).unwrap();

        let flat_claim = reconstructed.cairo_claim.flatten_claim();
        assert_eq!(
            flat_claim.component_enable_bits,
            statement.component_enable_bits
        );
        assert_eq!(
            flat_claim.component_log_sizes,
            statement.component_log_sizes
        );
        assert_eq!(
            reconstructed
                .interaction_claim
                .flatten_interaction_claim()
                .len(),
            COMPONENT_ENABLE_COUNT
        );
        assert_eq!(
            reconstructed
                .interaction_claim
                .memory_id_to_big
                .unwrap()
                .big_claimed_sums
                .len(),
            MEMORY_BIG_COUNT
        );
    }

    #[test]
    fn reconstructs_pinned_stark_proof_structure() {
        let protocol = CompactProtocolV1::decode(&protocol(2, 32, 8000)).unwrap();
        let statement = CompactStatementV1::decode(&statement(2)).unwrap();
        let proof = structurally_decodable_proof(&protocol);
        let stark = reconstruct_stark_proof_v1(
            &proof,
            &protocol,
            &statement,
            &composition_only_sample_shape(&protocol),
        )
        .unwrap();

        assert_eq!(stark.0.commitments.len(), 4);
        assert_eq!(stark.0.sampled_values.len(), 4);
        assert_eq!(stark.0.sampled_values[3].len(), 8);
        assert!(stark.0.sampled_values[3]
            .iter()
            .all(|column| column.len() == 1));
        assert_eq!(stark.0.decommitments.len(), 4);
        assert_eq!(stark.0.queried_values[0].len(), 161);
        assert_eq!(stark.0.queried_values[1].len(), 3449);
        assert_eq!(stark.0.queried_values[2].len(), 2268);
        assert_eq!(stark.0.queried_values[3].len(), 8);
        assert_eq!(stark.0.fri_proof.inner_layers.len(), 7);
        assert_eq!(stark.0.fri_proof.last_layer_poly.len(), 1);
        assert_eq!(stark.0.proof_of_work, 0xfedc_ba98_7654_3210);
    }

    #[test]
    fn reconstructs_fib_like_four_plus_seven_geometry() {
        use sha2::{Digest, Sha256};

        let protocol = fib_like_protocol();
        let encoded = protocol.encode().unwrap();
        let encoded_hex = encoded
            .iter()
            .map(|byte| format!("{byte:02x}"))
            .collect::<String>();
        assert_eq!(
            encoded_hex,
            "5354575a43503100010070000000000001000000010000000200000009000000\
             1a00000001000000460000000000000003000000ffffffff1800000004000000\
             0400000007000000010000000b00000002000000200000009001000069000000\
             07000000030000000800000014000000"
                .replace(' ', "")
        );
        assert_eq!(
            format!("{:x}", Sha256::digest(&encoded)),
            "4dae06a01beaa037e0c051ad6d83eff2f2c28fa259e44fef8cdecdc5101cc334"
        );
        assert_eq!(read_u32(&encoded, 68, "FRI trees").unwrap(), 7);
        assert_eq!(read_u32(&encoded, 76, "decommit records").unwrap(), 11);
        assert_eq!(read_u32(&encoded, 108, "maximum degree").unwrap(), 20);
        let decoded = CompactProtocolV1::decode(&encoded).unwrap();
        assert_eq!(decoded, protocol);

        let statement = CompactStatementV1::decode(&statement(2)).unwrap();
        let proof = structurally_decodable_proof(&decoded);
        validate_compact_proof_v1(&proof, &decoded, &statement).unwrap();
        let stark = reconstruct_stark_proof_v1(
            &proof,
            &decoded,
            &statement,
            &composition_only_sample_shape(&decoded),
        )
        .unwrap();
        assert_eq!(stark.0.commitments.len(), 4);
        assert_eq!(stark.0.fri_proof.inner_layers.len(), 6);
        assert_eq!(stark.0.queried_values[0].len(), 105);
        assert_eq!(stark.0.queried_values[1].len(), 7);
        assert_eq!(stark.0.queried_values[2].len(), 3);
        assert_eq!(stark.0.queried_values[3].len(), 8);
    }

    #[test]
    fn stark_reconstruction_rejects_shape_and_decommitment_field_drift() {
        let protocol = CompactProtocolV1::decode(&protocol(2, 32, 8000)).unwrap();
        let statement = CompactStatementV1::decode(&statement(2)).unwrap();
        let mut proof = structurally_decodable_proof(&protocol);
        let mut shape = composition_only_sample_shape(&protocol);
        shape[3][0] = 0;
        assert!(reconstruct_stark_proof_v1(&proof, &protocol, &statement, &shape).is_err());

        let decommit = compact_proof_offsets(&protocol).decommitment_start;
        put_u32(&mut proof, (decommit + 202) * 4, M31_PRIME);
        assert!(reconstruct_stark_proof_v1(
            &proof,
            &protocol,
            &statement,
            &composition_only_sample_shape(&protocol)
        )
        .is_err());
    }

    #[test]
    fn claim_reconstruction_rejects_fixed_log_size_drift() {
        let mut statement_bytes = statement(1);
        let enable = STATEMENT_HEADER_LEN as usize + PUBLIC_SEGMENT_COUNT * 5 * 4;
        put_u32(&mut statement_bytes, enable, 0);
        put_u32(&mut statement_bytes, enable + 23 * 4, 1);
        let protocol = CompactProtocolV1::decode(&protocol(1, 4, 4000)).unwrap();
        let statement = CompactStatementV1::decode(&statement_bytes).unwrap();
        let proof = proof(&protocol);
        assert!(reconstruct_claims_v1(&proof, &protocol, &statement).is_ok());

        let logs = enable + COMPONENT_ENABLE_COUNT * 4;
        put_u32(&mut statement_bytes, logs, 5);
        let statement = CompactStatementV1::decode(&statement_bytes).unwrap();
        assert!(reconstruct_claims_v1(&proof, &protocol, &statement).is_err());
    }

    #[test]
    fn decodes_nonempty_program_output_and_segment_data() {
        let mut bytes = statement(1);
        put_u32(&mut bytes, 16, 1);
        put_u32(&mut bytes, 20, 2);
        put_u32(&mut bytes, 24, 3);
        put_u32(&mut bytes, 40, 5);
        put_u32(&mut bytes, 44, 6);
        put_u32(&mut bytes, 48, 1);
        put_u32(&mut bytes, 52, 1);
        let memory_start = STATEMENT_HEADER_LEN as usize + PUBLIC_SEGMENT_COUNT * 5 * 4;
        bytes.splice(
            memory_start..memory_start,
            [0_u8; 2 * MEMORY_ENTRY_WORDS * 4],
        );
        put_u32(&mut bytes, memory_start, 7);
        put_u32(&mut bytes, memory_start + 4, 0xfeed_beef);
        let output_start = memory_start + MEMORY_ENTRY_WORDS * 4;
        put_u32(&mut bytes, output_start, 8);
        put_u32(&mut bytes, output_start + 4, 0xdead_beef);

        let decoded = CompactStatementV1::decode(&bytes).unwrap();
        assert_eq!(decoded.public_data.initial_state.pc.0, 1);
        assert_eq!(decoded.public_data.public_memory.safe_call_ids, [5, 6]);
        assert_eq!(decoded.public_data.public_memory.program[0].0, 7);
        assert_eq!(
            decoded.public_data.public_memory.program[0].1[0],
            0xfeed_beef
        );
        assert_eq!(decoded.public_data.public_memory.output[0].0, 8);
        assert_eq!(
            decoded.public_data.public_memory.output[0].1[0],
            0xdead_beef
        );
    }

    #[test]
    fn protocol_mutations_fail_closed() {
        for (offset, value) in [
            (0, 1),
            (8, 2),
            (12, 1),
            (40, 0),
            (68, 7),
            (76, 11),
            (92, 0),
            (108, 1),
        ] {
            let mut bytes = protocol(2, 4, 4000);
            put_u32(&mut bytes, offset, value);
            assert!(
                CompactProtocolV1::decode(&bytes).is_err(),
                "offset {offset}"
            );
        }
        let mut bytes = protocol(2, 3, 4000);
        assert!(CompactProtocolV1::decode(&bytes).is_err());
        bytes.pop();
        assert!(CompactProtocolV1::decode(&bytes).is_err());
    }

    #[test]
    fn recorded_sn_pie_layout_counts_reconcile_exactly() {
        let sn2 = CompactProtocolV1::decode(&protocol(58, 24_440, 2_077_800)).unwrap();
        assert_eq!(sn2.proof_word_count().unwrap(), 2_102_576);
        assert_eq!(
            sn2.proof_word_count().unwrap() - sn2.decommitment_capacity_words as usize,
            24_776
        );

        let sn134 = CompactProtocolV1::decode(&protocol(58, 24_436, 2_077_800)).unwrap();
        assert_eq!(sn134.proof_word_count().unwrap(), 2_102_572);
        assert_eq!(
            sn134.proof_word_count().unwrap() - sn134.decommitment_capacity_words as usize,
            24_772
        );
    }

    #[test]
    fn statement_mutations_fail_closed() {
        let mut bytes = statement(2);
        bytes[0] ^= 1;
        let error = match CompactStatementV1::decode(&bytes) {
            Ok(_) => panic!("mutated statement unexpectedly decoded"),
            Err(error) => error,
        };
        assert_eq!(error.code, "invalid_compact_statement");

        let mut bytes = statement(2);
        let enable = STATEMENT_HEADER_LEN as usize + PUBLIC_SEGMENT_COUNT * 5 * 4;
        put_u32(&mut bytes, enable + 4, 2);
        assert!(CompactStatementV1::decode(&bytes).is_err());

        let mut bytes = statement(2);
        put_u32(&mut bytes, 16, M31_PRIME);
        assert!(CompactStatementV1::decode(&bytes).is_err());

        let mut bytes = statement(2);
        bytes.push(0);
        assert!(CompactStatementV1::decode(&bytes).is_err());
    }

    #[test]
    fn rejects_noncontiguous_memory_big_enable_prefix() {
        let mut bytes = statement(2);
        let enable = STATEMENT_HEADER_LEN as usize + PUBLIC_SEGMENT_COUNT * 5 * 4;
        put_u32(&mut bytes, enable, 0);
        put_u32(&mut bytes, enable + MEMORY_BIG_START * 4, 1);
        put_u32(&mut bytes, enable + (MEMORY_BIG_START + 2) * 4, 1);
        assert!(CompactStatementV1::decode(&bytes).is_err());
    }

    #[test]
    fn proof_mutations_fail_closed() {
        let protocol = CompactProtocolV1::decode(&protocol(2, 4, 4000)).unwrap();
        let statement = CompactStatementV1::decode(&statement(2)).unwrap();
        let original = proof(&protocol);
        let decommit = protocol.proof_word_count().unwrap() - 4000;
        for (word, value) in [
            (decommit, 0),
            (decommit + 2, 11),
            (decommit + 3, 69),
            (decommit + 7, 4001),
            (decommit + 8, 1),
            (decommit + 9, 3),
            (decommit + 8 + 16 * 4 + 5, 1),
            (decommit + 8 + 5, 160),
        ] {
            let mut bytes = original.clone();
            put_u32(&mut bytes, word * 4, value);
            assert!(
                validate_compact_proof_v1(&bytes, &protocol, &statement).is_err(),
                "word {word}"
            );
        }
        let mut bytes = original;
        put_u32(&mut bytes, 4 * HASH_WORDS * 4, M31_PRIME);
        assert!(validate_compact_proof_v1(&bytes, &protocol, &statement).is_err());
    }
}
