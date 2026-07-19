//! Diagnostic-only capture of the pinned signed-MULH lookup failure.
//!
//! This deliberately stops before counter registration. It evaluates the
//! pinned production AIR over the pinned runner witness and serializes the raw
//! relation requests which production would feed to the preprocessed tables.

use num_traits::Zero;
use serde_json::json;
use sha2::{Digest, Sha256};
use stwo::core::fields::m31::{BaseField, M31};
use stwo::core::fields::qm31::QM31;
use stwo::core::pcs::TreeVec;
use stwo::prover::backend::simd::m31::PackedM31;
use stwo::prover::backend::Column;
use stwo_constraint_framework::relation_tracker::{add_to_relation_entries, RelationTrackerEntry};
use stwo_constraint_framework::{FrameworkComponent, TraceLocationAllocator};

use prover::preprocessed::PreprocessedTable;

const SCHEMA: &str = "riscv-mulh-limitation-v1";
const LIMITATION: &str = "stark-v-signed-mulh";
const ORACLE_COMMIT: &str = "d478f783055aa0d73a93768a433a3c6c31c91d1c";
const RAW_DOMAIN: &[u8] = b"riscv/mulh-limitation/raw-stream/v1\0";
const RANGE_DOMAIN: &[u8] = b"riscv/mulh-limitation/range811-stream/v1\0";
const INVALID_DOMAIN: &[u8] = b"riscv/mulh-limitation/invalid-stream/v1\0";
const RANGE_8_11_DOMAIN_ID: u8 = 8;

#[derive(Clone, Copy, Eq, PartialEq)]
enum RangeMembership {
    Member,
    OutOfBounds,
    Aliased,
}

struct Request<'a> {
    row: u32,
    opcode_id: u32,
    request_index: u32,
    domain: u8,
    entry: &'a RelationTrackerEntry,
}

fn column_index(name: &str) -> usize {
    air::trace::prover_columns::MulhColumns::<()>::NAMES
        .iter()
        .position(|candidate| *candidate == name)
        .unwrap_or_else(|| panic!("missing MULH witness column {name}"))
}

fn opcode_id(columns: &[Vec<BaseField>], row: usize) -> u32 {
    let mulh = columns[column_index("opcode_mulh_flag")][row].0;
    let mulhsu = columns[column_index("opcode_mulhsu_flag")][row].0;
    let mulhu = columns[column_index("opcode_mulhu_flag")][row].0;
    mulh * air::decode::Opcode::Mulh as u32
        + mulhsu * air::decode::Opcode::Mulhsu as u32
        + mulhu * air::decode::Opcode::Mulhu as u32
}

fn domain_id(name: &str) -> u8 {
    super::cp11_relation_sums::RELATION_NAMES
        .iter()
        .position(|candidate| *candidate == name)
        .unwrap_or_else(|| panic!("unknown relation domain {name}")) as u8
}

fn append_qm31(hasher: &mut Sha256, value: M31) {
    hasher.update(value.0.to_le_bytes());
    for _ in 1..4 {
        hasher.update(0u32.to_le_bytes());
    }
}

fn append_record(hasher: &mut Sha256, request: &Request<'_>) {
    hasher.update(request.row.to_le_bytes());
    hasher.update(request.opcode_id.to_le_bytes());
    hasher.update(request.request_index.to_le_bytes());
    hasher.update([request.domain]);
    append_qm31(hasher, request.entry.mult);
    hasher.update([request.entry.values.len() as u8]);
    for value in &request.entry.values {
        append_qm31(hasher, *value);
    }
}

fn digest<'a>(domain: &[u8], requests: impl IntoIterator<Item = &'a Request<'a>>) -> String {
    let mut hasher = Sha256::new();
    hasher.update(domain);
    for request in requests {
        append_record(&mut hasher, request);
    }
    format!("{:x}", hasher.finalize())
}

fn range_membership(request: &Request<'_>, table_columns: &[Vec<BaseField>]) -> RangeMembership {
    assert_eq!(request.domain, RANGE_8_11_DOMAIN_ID);
    assert_eq!(request.entry.values.len(), table_columns.len());
    let values = request
        .entry
        .values
        .iter()
        .copied()
        .map(PackedM31::broadcast)
        .collect::<Vec<_>>();
    let index = prover::preprocessed::range_check_8_11::Table::index(&values)[0];
    let index = index as usize;
    if index >= table_columns[0].len() {
        return RangeMembership::OutOfBounds;
    }
    if request
        .entry
        .values
        .iter()
        .zip(table_columns)
        .any(|(requested, column)| requested != &column[index])
    {
        return RangeMembership::Aliased;
    }
    RangeMembership::Member
}

pub fn dump(result: runner::RunResult, elf_sha256: String) {
    let input_sha256 = format!("{:x}", Sha256::digest(&result.input));
    let mulh_trace = result.tracer.mulh.into_witness();
    let log_size = mulh_trace[0].domain.log_size();
    let domain_rows = 1usize << log_size;
    let main_columns: Vec<Vec<BaseField>> = mulh_trace
        .iter()
        .map(|column| column.values.to_cpu())
        .collect();
    let trace = TreeVec::new(vec![vec![], main_columns.clone()]);
    let trace_refs = trace.as_cols_ref();

    let relations =
        prover::relations::Relations::draw(&mut stwo::core::channel::Blake2sChannel::default());
    let eval = prover::components::mulh::air::Eval {
        log_size,
        relations,
    };
    let mut allocator = TraceLocationAllocator::default();
    let component = FrameworkComponent::new(&mut allocator, eval, QM31::zero());
    let entries = add_to_relation_entries(&component, &trace_refs);
    assert_eq!(entries.len() % domain_rows, 0);
    let requests_per_row = entries.len() / domain_rows;
    assert_eq!(requests_per_row, 20);

    let requests: Vec<Request<'_>> = entries
        .iter()
        .enumerate()
        .filter_map(|(index, entry)| {
            if entry.mult.0 == 0 {
                return None;
            }
            let row = index / requests_per_row;
            Some(Request {
                row: row as u32,
                opcode_id: opcode_id(&main_columns, row),
                request_index: (index % requests_per_row) as u32,
                domain: domain_id(&entry.relation),
                entry,
            })
        })
        .collect();
    let range: Vec<&Request<'_>> = requests
        .iter()
        .filter(|request| request.domain == RANGE_8_11_DOMAIN_ID)
        .collect();
    let range_columns = prover::preprocessed::range_check_8_11::Table::gen_columns();
    let range_table: Vec<Vec<BaseField>> = range_columns
        .iter()
        .map(|column| column.values.to_cpu())
        .collect();
    let classified: Vec<(&Request<'_>, RangeMembership)> = range
        .iter()
        .map(|request| (*request, range_membership(request, &range_table)))
        .collect();
    assert_eq!(
        classified
            .iter()
            .filter(|(_, membership)| *membership == RangeMembership::OutOfBounds)
            .count(),
        4,
    );
    assert_eq!(
        classified
            .iter()
            .filter(|(_, membership)| *membership == RangeMembership::Aliased)
            .count(),
        4,
    );
    let invalid: Vec<&Request<'_>> = classified
        .iter()
        .filter_map(|(request, membership)| {
            (*membership != RangeMembership::Member).then_some(*request)
        })
        .collect();
    for row in requests.chunks_exact(requests_per_row) {
        assert!(row
            .iter()
            .enumerate()
            .all(|(index, request)| request.request_index == index as u32));
        let range_indices: Vec<u32> = row
            .iter()
            .filter(|request| request.domain == RANGE_8_11_DOMAIN_ID)
            .map(|request| request.request_index)
            .collect();
        assert_eq!(range_indices, (9..=16).collect::<Vec<_>>());
    }

    let mulh_id = air::decode::Opcode::Mulh as u32;
    let mulhsu_id = air::decode::Opcode::Mulhsu as u32;
    let mulhu_id = air::decode::Opcode::Mulhu as u32;
    let family_rows = requests.len() / requests_per_row;
    let signed_rows = requests
        .iter()
        .step_by(requests_per_row)
        .filter(|request| request.opcode_id == mulh_id || request.opcode_id == mulhsu_id)
        .count();
    let unsigned_rows = requests
        .iter()
        .step_by(requests_per_row)
        .filter(|request| request.opcode_id == mulhu_id)
        .count();
    let invalid_json: Vec<_> = invalid
        .iter()
        .map(|request| {
            json!({
                "row": request.row,
                "opcode_id": request.opcode_id,
                "request_index": request.request_index,
                "tuple": request.entry.values.iter().map(|value| value.0).collect::<Vec<_>>(),
                "classification": "range_check_8_11_value_out_of_range",
            })
        })
        .collect();
    let payload = json!({
        "schema": SCHEMA,
        "limitation_id": LIMITATION,
        "oracle_commit": ORACLE_COMMIT,
        "family": "mulh",
        "family_rows": family_rows,
        "signed_rows": signed_rows,
        "unsigned_rows": unsigned_rows,
        "raw_nonzero_entries": requests.len(),
        "raw_stream_sha256": digest(RAW_DOMAIN, requests.iter()),
        "range811_requests": range.len(),
        "range811_stream_sha256": digest(RANGE_DOMAIN, range.iter().copied()),
        "invalid_request_count": invalid.len(),
        "invalid_requests_sha256": digest(INVALID_DOMAIN, invalid.iter().copied()),
        "invalid_requests": invalid_json,
        "outcome": "preprocessed_registration_rejected",
        "source": {
            "elf_sha256": elf_sha256,
            "input_sha256": input_sha256,
        },
    });
    println!(
        "{}",
        serde_json::to_string(&payload).expect("serialize limitation diagnostic")
    );
}
