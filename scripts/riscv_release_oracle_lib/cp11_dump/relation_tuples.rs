//! Production relation-tuple diagnostics for the CP-11 pinned Rust adapter.

use std::collections::BTreeMap;

use stwo::core::fields::m31::BaseField;
use stwo::core::pcs::TreeVec;
use stwo::core::vcs::blake2_hash::Blake2sHasher;
use stwo::prover::backend::Column;
use stwo_constraint_framework::relation_tracker::{
    RelationTrackerEntry, add_to_relation_entries,
};
use stwo_constraint_framework::{FrameworkComponent, FrameworkEval, TraceLocationAllocator};

use super::cp11_relation_sums::RELATION_NAMES;
use super::COMPONENT_NAMES;

const TUPLE_DIGEST_DOMAIN: &[u8] = b"stwo-zig/riscv/relation-tuples/v1\0";

struct StreamDigest {
    count: usize,
    digest: String,
}

fn new_tuple_hasher() -> Blake2sHasher {
    let mut hasher = Blake2sHasher::new();
    hasher.update(TUPLE_DIGEST_DOMAIN);
    hasher
}

fn update_tuple_hasher(hasher: &mut Blake2sHasher, entry: &RelationTrackerEntry) {
    let relation = entry.relation.as_bytes();
    hasher.update(&(relation.len() as u32).to_le_bytes());
    hasher.update(relation);
    hasher.update(&entry.mult.0.to_le_bytes());
    hasher.update(&(entry.values.len() as u32).to_le_bytes());
    for value in &entry.values {
        hasher.update(&value.0.to_le_bytes());
    }
}

fn digest_entries<'a>(entries: impl IntoIterator<Item = &'a RelationTrackerEntry>) -> StreamDigest {
    let mut hasher = new_tuple_hasher();
    let mut count = 0;
    for entry in entries {
        update_tuple_hasher(&mut hasher, entry);
        count += 1;
    }
    StreamDigest {
        count,
        digest: hasher.finalize().to_string(),
    }
}

fn print_tuple_group(prefix: &str, entries: &[RelationTrackerEntry]) {
    let all = digest_entries(entries);
    let zero = digest_entries(entries.iter().filter(|entry| entry.mult.0 == 0));
    let nonzero = digest_entries(entries.iter().filter(|entry| entry.mult.0 != 0));
    println!(
        "{prefix} entries={} digest={} zero_entries={} zero_digest={} nonzero_entries={} nonzero_digest={}",
        all.count, all.digest, zero.count, zero.digest, nonzero.count, nonzero.digest,
    );
}

fn print_relation_groups(prefix: &str, entries: &[RelationTrackerEntry]) {
    for relation in RELATION_NAMES {
        let all = digest_entries(entries.iter().filter(|entry| entry.relation == relation));
        let zero = digest_entries(
            entries
                .iter()
                .filter(|entry| entry.relation == relation && entry.mult.0 == 0),
        );
        let nonzero = digest_entries(
            entries
                .iter()
                .filter(|entry| entry.relation == relation && entry.mult.0 != 0),
        );
        println!(
            "{prefix}{relation} entries={} digest={} zero_entries={} zero_digest={} nonzero_entries={} nonzero_digest={}",
            all.count, all.digest, zero.count, zero.digest, nonzero.count, nonzero.digest,
        );
    }
}

struct RelationTupleVisitor<'a> {
    trace: &'a TreeVec<Vec<&'a Vec<BaseField>>>,
    component_index: usize,
    recomposed: Blake2sHasher,
    recomposed_count: usize,
}

impl<'a> RelationTupleVisitor<'a> {
    fn new(trace: &'a TreeVec<Vec<&'a Vec<BaseField>>>) -> Self {
        Self {
            trace,
            component_index: 0,
            recomposed: new_tuple_hasher(),
            recomposed_count: 0,
        }
    }
}

impl prover::components::ComponentVisitor for RelationTupleVisitor<'_> {
    fn visit<E: FrameworkEval>(&mut self, component: &FrameworkComponent<E>, _claimed_sum: stwo::core::fields::qm31::QM31) {
        let component_name = COMPONENT_NAMES[self.component_index];
        self.component_index += 1;
        let entries = add_to_relation_entries(component, self.trace);

        let observed: BTreeMap<&str, usize> =
            entries.iter().fold(BTreeMap::new(), |mut counts, entry| {
                *counts.entry(entry.relation.as_str()).or_insert(0) += 1;
                counts
            });
        for relation in observed.keys() {
            assert!(
                RELATION_NAMES.contains(relation),
                "component {component_name} emitted unknown relation {relation}",
            );
        }

        print_tuple_group(&format!("component={component_name}"), &entries);
        print_relation_groups(
            &format!("component_relation={component_name}/"),
            &entries,
        );
        for entry in &entries {
            update_tuple_hasher(&mut self.recomposed, entry);
            self.recomposed_count += 1;
        }
    }
}

pub fn dump(result: runner::RunResult) {
    let public = prover::public_data::PublicData::new(&result);
    let traces = prover::components::gen_trace(result.tracer);
    let claim: prover::components::Claim = (&traces).into();
    let mut channel = stwo::core::channel::Blake2sChannel::default();
    let relations = prover::relations::Relations::draw(&mut channel);
    let (_, claimed_sum) = prover::components::gen_interaction_trace(&traces, &relations);

    let preprocessed = prover::preprocessed::PreProcessedTrace::new();
    let preprocessed_cpu: Vec<Vec<BaseField>> = preprocessed
        .trace
        .iter()
        .map(|column| column.values.to_cpu())
        .collect();
    let main_cpu: Vec<Vec<BaseField>> = traces
        .columns_cloned()
        .iter()
        .map(|column| column.values.to_cpu())
        .collect();
    let cpu_trace = TreeVec::new(vec![preprocessed_cpu, main_cpu]);
    let trace_refs = cpu_trace.as_cols_ref();

    let mut allocator = TraceLocationAllocator::new_with_preprocessed_columns(&preprocessed.ids);
    let components =
        prover::components::Components::new(&claim, &mut allocator, relations, &claimed_sum);
    let authoritative = components.relation_entries(&trace_refs);
    let authoritative_digest = digest_entries(&authoritative);

    println!("schema=riscv-relation-tuples-v2");
    let mut visitor = RelationTupleVisitor::new(&trace_refs);
    components.visit_components(&claimed_sum, &mut visitor);
    assert_eq!(visitor.component_index, COMPONENT_NAMES.len());
    let recomposed_digest = visitor.recomposed.finalize().to_string();
    assert_eq!(visitor.recomposed_count, authoritative_digest.count);
    assert_eq!(recomposed_digest, authoritative_digest.digest);
    print_tuple_group("aggregate=all_components", &authoritative);
    print_relation_groups("aggregate_relation=", &authoritative);

    // Retain production PublicData construction in this instrumentation path.
    std::hint::black_box(public);
}
