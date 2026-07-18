//! Native relation-sum diagnostics for the CP-11 pinned Rust adapter.

use num_traits::{One, Zero};
use stwo::core::fields::FieldExpOps;
use stwo::core::fields::m31::BaseField;
use stwo::core::fields::qm31::QM31;
use stwo_constraint_framework::Relation;
use stwo_constraint_framework::relation_tracker::RelationTrackerEntry;

pub const RELATION_NAMES: [&str; 12] = [
    "registers_state",
    "memory_access",
    "program_access",
    "merkle",
    "poseidon2",
    "poseidon2_io",
    "bitwise",
    "range_check_20",
    "range_check_8_11",
    "range_check_8_8_4",
    "range_check_8_8",
    "range_check_m31",
];

pub const RELATION_ARITIES: [usize; 12] = [2, 7, 5, 4, 16, 32, 4, 1, 2, 3, 2, 2];

pub fn combine_relation(
    relations: &prover::relations::Relations,
    relation: &str,
    values: &[BaseField],
) -> QM31 {
    match relation {
        "registers_state" => relations.registers_state.combine(values),
        "memory_access" => relations.memory_access.combine(values),
        "program_access" => relations.program_access.combine(values),
        "merkle" => relations.merkle.combine(values),
        "poseidon2" => relations.poseidon2.combine(values),
        "poseidon2_io" => relations.poseidon2_io.combine(values),
        "bitwise" => relations.bitwise.combine(values),
        "range_check_20" => relations.range_check_20.combine(values),
        "range_check_8_11" => relations.range_check_8_11.combine(values),
        "range_check_8_8_4" => relations.range_check_8_8_4.combine(values),
        "range_check_8_8" => relations.range_check_8_8.combine(values),
        "range_check_m31" => relations.range_check_m31.combine(values),
        _ => panic!("unknown relation {relation}"),
    }
}

pub fn qm31_text(value: QM31) -> String {
    value
        .to_m31_array()
        .iter()
        .map(|limb| limb.0.to_string())
        .collect::<Vec<_>>()
        .join(",")
}

pub fn tracker_relation_sums(
    relations: &prover::relations::Relations,
    entries: &[RelationTrackerEntry],
) -> [QM31; 12] {
    let nonzero: Vec<&RelationTrackerEntry> =
        entries.iter().filter(|entry| entry.mult.0 != 0).collect();
    let denominators: Vec<QM31> = nonzero
        .iter()
        .map(|entry| combine_relation(relations, &entry.relation, &entry.values))
        .collect();
    let inverses = QM31::batch_inverse(&denominators);
    let mut sums = [QM31::zero(); 12];
    for (entry, inverse) in nonzero.into_iter().zip(inverses) {
        let relation_index = RELATION_NAMES
            .iter()
            .position(|name| *name == entry.relation)
            .expect("known relation");
        sums[relation_index] += QM31::from(entry.mult) * inverse;
    }
    sums
}

fn fraction_sum(
    relations: &prover::relations::Relations,
    relation: &str,
    terms: &[(BaseField, Vec<BaseField>)],
) -> QM31 {
    let denominators: Vec<QM31> = terms
        .iter()
        .map(|(_, values)| combine_relation(relations, relation, values))
        .collect();
    let inverses = QM31::batch_inverse(&denominators);
    terms
        .iter()
        .zip(inverses)
        .map(|((mult, _), inverse)| QM31::from(*mult) * inverse)
        .sum()
}

/// Mirrors PublicData::logup_sum by domain, then callers assert its aggregate
/// against that production method. These values are diagnostics, never a
/// replacement for the native public total.
pub fn public_domain_sums(
    public: &prover::public_data::PublicData,
    relations: &prover::relations::Relations,
) -> [QM31; 3] {
    let one = BaseField::one();
    let minus_one = -one;
    let state_terms = vec![
        (
            one,
            vec![BaseField::from(public.initial_pc), BaseField::one()],
        ),
        (
            minus_one,
            vec![
                BaseField::from(public.final_pc),
                BaseField::from(public.clock.checked_add(1).expect("clock overflow")),
            ],
        ),
    ];

    let merkle_terms: Vec<(BaseField, Vec<BaseField>)> = [
        public.program_root,
        public.initial_rw_root,
        public.final_rw_root,
    ]
    .into_iter()
    .flatten()
    .map(|root| {
        (
            one,
            vec![
                BaseField::zero(),
                BaseField::zero(),
                BaseField::from(root),
                BaseField::from(root),
            ],
        )
    })
    .collect();

    let mut memory_terms = Vec::new();
    for (index, last_clock) in public.reg_last_clock.iter().copied().enumerate() {
        let address = BaseField::from(index as u32);
        let initial = public.initial_regs[index].to_le_bytes();
        memory_terms.push((
            one,
            vec![
                BaseField::zero(),
                address,
                BaseField::zero(),
                BaseField::from(initial[0] as u32),
                BaseField::from(initial[1] as u32),
                BaseField::from(initial[2] as u32),
                BaseField::from(initial[3] as u32),
            ],
        ));
        let final_value = public.final_regs[index].to_le_bytes();
        memory_terms.push((
            minus_one,
            vec![
                BaseField::zero(),
                address,
                BaseField::from(last_clock),
                BaseField::from(final_value[0] as u32),
                BaseField::from(final_value[1] as u32),
                BaseField::from(final_value[2] as u32),
                BaseField::from(final_value[3] as u32),
            ],
        ));
    }
    for (index, word) in public.io_entries.input_words.iter().copied().enumerate() {
        let address = public
            .io_entries
            .input_start
            .wrapping_add((index as u32).saturating_mul(4));
        let bytes = word.to_le_bytes();
        memory_terms.push((
            one,
            vec![
                BaseField::one(),
                BaseField::from(address),
                BaseField::zero(),
                BaseField::from(bytes[0] as u32),
                BaseField::from(bytes[1] as u32),
                BaseField::from(bytes[2] as u32),
                BaseField::from(bytes[3] as u32),
            ],
        ));
    }
    for word in &public.io_entries.output_words {
        let bytes = word.value.to_le_bytes();
        memory_terms.push((
            minus_one,
            vec![
                BaseField::one(),
                BaseField::from(word.addr),
                BaseField::from(word.clock),
                BaseField::from(bytes[0] as u32),
                BaseField::from(bytes[1] as u32),
                BaseField::from(bytes[2] as u32),
                BaseField::from(bytes[3] as u32),
            ],
        ));
    }

    [
        fraction_sum(relations, "registers_state", &state_terms),
        fraction_sum(relations, "merkle", &merkle_terms),
        fraction_sum(relations, "memory_access", &memory_terms),
    ]
}
