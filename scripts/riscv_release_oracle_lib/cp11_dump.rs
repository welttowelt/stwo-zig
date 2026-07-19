//! CP-11 receipt adapter: serialize the oracle's own run + public data.
#[path = "cp11_dump/relation_sums.rs"]
mod cp11_relation_sums;
#[path = "cp11_dump/relation_tuples.rs"]
mod cp11_relation_tuples;

use std::env;
use std::fs;
// decode matrix mode relies on the air crate re-exported through prover deps.
use air;
use num_traits::Zero;
use prover as _;
use simd::AlignedVec;
use stwo::core::channel::Channel;
use stwo::core::fields::m31::BaseField;
use stwo::core::fields::qm31::QM31;
use stwo::core::pcs::TreeVec;
use stwo::prover::backend::Column;
use stwo_constraint_framework::{FrameworkComponent, FrameworkEval, TraceLocationAllocator};

use cp11_relation_sums::RELATION_NAMES;

const COMPONENT_NAMES: [&str; 27] = [
    "auipc",
    "base_alu_imm",
    "base_alu_reg",
    "branch_eq",
    "branch_lt",
    "div",
    "jal",
    "jalr",
    "load_store",
    "lt_imm",
    "lt_reg",
    "lui",
    "mul",
    "mulh",
    "shifts_imm",
    "shifts_reg",
    "program",
    "memory",
    "merkle",
    "poseidon2",
    "clock_update",
    "bitwise",
    "range_check_20",
    "range_check_8_11",
    "range_check_8_8_4",
    "range_check_8_8",
    "range_check_m31",
];

struct FamilyMatrix {
    name: &'static str,
    names: &'static [&'static str],
    columns: Vec<AlignedVec<u32>>,
}

impl FamilyMatrix {
    fn rows(&self) -> usize {
        self.columns.first().map_or(0, |column| column.len())
    }

    fn value(&self, name: &str, row: usize) -> u32 {
        let column = self
            .names
            .iter()
            .position(|candidate| *candidate == name)
            .unwrap_or_else(|| panic!("missing {name} column in {}", self.name));
        self.columns[column][row]
    }

    fn word(&self, prefix: &str, suffix: &str, row: usize) -> u32 {
        let mut word = 0u32;
        for limb in 0..4 {
            let name = format!("{prefix}_{suffix}_{limb}");
            word |= self.value(&name, row) << (8 * limb);
        }
        word
    }
}

macro_rules! family_matrix {
    ($name:literal, $columns:ident, $table:expr) => {
        FamilyMatrix {
            name: $name,
            names: air::trace::prover_columns::$columns::<()>::NAMES,
            columns: $table.clone().into_columns(),
        }
    };
}

/// Canonical component order is generated from the pinned prover registry at
/// crates/prover/src/components/mod.rs. Each matrix is the oracle tracer's own
/// generated, unpadded witness layout; the adapter only formats it.
fn family_matrices(tracer: &runner::Tracer) -> Vec<FamilyMatrix> {
    vec![
        family_matrix!("auipc", AuipcColumns, tracer.auipc),
        family_matrix!("base_alu_imm", BaseAluImmColumns, tracer.base_alu_imm),
        family_matrix!("base_alu_reg", BaseAluRegColumns, tracer.base_alu_reg),
        family_matrix!("branch_eq", BranchEqColumns, tracer.branch_eq),
        family_matrix!("branch_lt", BranchLtColumns, tracer.branch_lt),
        family_matrix!("div", DivColumns, tracer.div),
        family_matrix!("jal", JalColumns, tracer.jal),
        family_matrix!("jalr", JalrColumns, tracer.jalr),
        family_matrix!("load_store", LoadStoreColumns, tracer.load_store),
        family_matrix!("lt_imm", LtImmColumns, tracer.lt_imm),
        family_matrix!("lt_reg", LtRegColumns, tracer.lt_reg),
        family_matrix!("lui", LuiColumns, tracer.lui),
        family_matrix!("mul", MulColumns, tracer.mul),
        family_matrix!("mulh", MulhColumns, tracer.mulh),
        family_matrix!("shifts_imm", ShiftsImmColumns, tracer.shifts_imm),
        family_matrix!("shifts_reg", ShiftsRegColumns, tracer.shifts_reg),
    ]
}

fn dump_witness_rows(tracer: &runner::Tracer) {
    let mut out = String::new();
    for matrix in family_matrices(tracer) {
        out.push_str(&format!(
            "family={} rows={} columns={}\n",
            matrix.name,
            matrix.rows(),
            matrix.columns.len(),
        ));
        out.push_str("names=");
        out.push_str(&matrix.names.join(","));
        out.push('\n');
        for row in 0..matrix.rows() {
            out.push_str(&format!("row={row}"));
            for column in &matrix.columns {
                out.push_str(&format!(" {}", column[row]));
            }
            out.push('\n');
        }
    }
    print!("{out}");
}

#[derive(Clone)]
struct OrderedAccess {
    clock: u32,
    kind: u8,
    ordinal: u8,
    family_index: usize,
    family: &'static str,
    role: &'static str,
    addr_space: u32,
    addr: u32,
    previous_clock: u32,
    previous: u32,
    next: u32,
}

fn access_roles(family: &str) -> &'static [&'static str] {
    match family {
        "base_alu_reg" | "shifts_reg" | "lt_reg" | "mul" | "mulh" | "div" => &["rs1", "rs2", "rd"],
        "base_alu_imm" | "shifts_imm" | "lt_imm" | "jalr" => &["rs1", "rd"],
        "branch_eq" | "branch_lt" => &["rs1", "rs2"],
        "lui" | "auipc" | "jal" => &["rd"],
        "load_store" => &["rs1", "src", "dst"],
        _ => panic!("unknown family {family}"),
    }
}

fn dump_ordered_accesses(tracer: &runner::Tracer) {
    let mut accesses = Vec::new();
    for (family_index, matrix) in family_matrices(tracer).into_iter().enumerate() {
        for row in 0..matrix.rows() {
            let clock = matrix.value("clock", row);
            let is_store = matrix.name == "load_store"
                && (matrix.value("opcode_sb_flag", row)
                    + matrix.value("opcode_sh_flag", row)
                    + matrix.value("opcode_sw_flag", row)
                    != 0);
            for (ordinal, role) in access_roles(matrix.name).iter().copied().enumerate() {
                let addr_space = if matrix.name == "load_store" {
                    match role {
                        "src" => (!is_store) as u32,
                        "dst" => is_store as u32,
                        _ => 0,
                    }
                } else {
                    0
                };
                accesses.push(OrderedAccess {
                    clock,
                    kind: 1,
                    ordinal: ordinal as u8,
                    family_index,
                    family: matrix.name,
                    role,
                    addr_space,
                    addr: matrix.value(&format!("{role}_addr"), row),
                    previous_clock: matrix.value(&format!("{role}_clock_prev"), row),
                    previous: matrix.word(role, "prev", row),
                    next: matrix.word(role, "next", row),
                });
            }
        }
    }

    // Clock catch-up rows are native tracer records. Their current clock is
    // implicit in Stark-V and equals previous + max_clock_diff.
    for gap in tracer.clock_update.iter() {
        accesses.push(OrderedAccess {
            clock: gap.access.clock_prev.saturating_add(tracer.max_clock_diff),
            kind: 0,
            ordinal: 0,
            family_index: usize::MAX,
            family: "clock_update",
            role: "clock_update",
            addr_space: gap.addr_space,
            addr: gap.access.addr,
            previous_clock: gap.access.clock_prev,
            previous: gap.access.prev,
            next: gap.access.next,
        });
    }

    accesses.sort_by_key(|access| {
        (
            access.clock,
            access.kind,
            access.ordinal,
            access.addr_space,
            access.addr,
            access.family_index,
        )
    });
    for access in accesses {
        println!(
            "clock={} ordinal={} family={} role={} space={} addr={} previous_clock={} previous={} next={}",
            access.clock,
            access.ordinal,
            access.family,
            access.role,
            access.addr_space,
            access.addr,
            access.previous_clock,
            access.previous,
            access.next,
        );
    }
}

fn dump_trace_json(result: &runner::RunResult) {
    let mut steps = Vec::new();
    for matrix in family_matrices(&result.tracer) {
        for row in 0..matrix.rows() {
            steps.push((matrix.value("clock", row), matrix.value("pc", row)));
        }
    }
    steps.sort_by_key(|(clock, _)| *clock);
    let rendered_steps = steps
        .iter()
        .map(|(clock, pc)| format!("{{\"step\":{clock},\"pc\":{pc}}}"))
        .collect::<Vec<_>>()
        .join(",");
    let registers = result
        .final_regs
        .iter()
        .map(u32::to_string)
        .collect::<Vec<_>>()
        .join(",");
    print!(
        "{{\"steps\":[{rendered_steps}],\"final_pc\":{},\"final_regs\":[{registers}],\"total_steps\":{}}}",
        result.final_pc, result.cycles,
    );
}

struct RelationSumVisitor {
    component_index: usize,
    prefix: QM31,
}

impl prover::components::ComponentVisitor for RelationSumVisitor {
    fn visit<E: FrameworkEval>(&mut self, _component: &FrameworkComponent<E>, claimed_sum: QM31) {
        let component = COMPONENT_NAMES[self.component_index];
        self.component_index += 1;
        self.prefix += claimed_sum;
        println!(
            "component={component} claim={} prefix={}",
            cp11_relation_sums::qm31_text(claimed_sum),
            cp11_relation_sums::qm31_text(self.prefix),
        );
    }
}

fn dump_relation_sums(result: runner::RunResult) {
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
    let components = prover::components::Components::new(
        &claim,
        &mut allocator,
        relations.clone(),
        &claimed_sum,
    );
    let entries = components.relation_entries(&trace_refs);
    let domain_sums = cp11_relation_sums::tracker_relation_sums(&relations, &entries);
    let tracker_total: QM31 = domain_sums.iter().copied().sum();
    assert_eq!(tracker_total, claimed_sum.total());

    let public_domains = cp11_relation_sums::public_domain_sums(&public, &relations);
    let public_total: QM31 = public_domains.iter().copied().sum();
    assert_eq!(public_total, public.logup_sum(&relations));
    for (index, sum) in domain_sums.iter().copied().enumerate() {
        let compensation = match index {
            0 => public_domains[0],
            1 => public_domains[2],
            3 => public_domains[1],
            _ => QM31::zero(),
        };
        assert_eq!(sum + compensation, QM31::zero());
    }
    assert_eq!(tracker_total + public_total, QM31::zero());

    println!("schema=riscv-relation-sums-v1");
    for (index, relation) in RELATION_NAMES.iter().copied().enumerate() {
        let values: Vec<BaseField> = (1..=cp11_relation_sums::RELATION_ARITIES[index])
            .map(|value| BaseField::from(value as u32))
            .collect();
        let signature = cp11_relation_sums::combine_relation(&relations, relation, &values);
        println!(
            "challenge={relation} signature={}",
            cp11_relation_sums::qm31_text(signature),
        );
    }

    let mut visitor = RelationSumVisitor {
        component_index: 0,
        prefix: QM31::zero(),
    };
    components.visit_components(&claimed_sum, &mut visitor);
    assert_eq!(visitor.component_index, COMPONENT_NAMES.len());
    assert_eq!(visitor.prefix, claimed_sum.total());

    for (relation, sum) in RELATION_NAMES.iter().zip(domain_sums) {
        println!(
            "relation={relation} sum={}",
            cp11_relation_sums::qm31_text(sum),
        );
    }
    println!(
        "public=registers_state sum={}",
        cp11_relation_sums::qm31_text(public_domains[0]),
    );
    println!(
        "public=merkle sum={}",
        cp11_relation_sums::qm31_text(public_domains[1]),
    );
    println!(
        "public=memory_access sum={}",
        cp11_relation_sums::qm31_text(public_domains[2]),
    );
    let native_total = claimed_sum.total();
    println!(
        "aggregate=native sum={} public_sum={} balanced_sum={}",
        cp11_relation_sums::qm31_text(native_total),
        cp11_relation_sums::qm31_text(public_total),
        cp11_relation_sums::qm31_text(native_total + public_total),
    );
}

fn main() {
    let args: Vec<String> = env::args().collect();
    let mut elf: Option<String> = None;
    let mut decode_file: Option<String> = None;
    let mut poseidon2_file: Option<String> = None;
    let mut transcript_prefix = false;
    let mut witness_rows = false;
    let mut ordered_accesses = false;
    let mut relation_tuples = false;
    let mut relation_sums = false;
    let mut trace_json = false;
    let mut max: u64 = 1_000_000;
    let mut i = 1;
    while i < args.len() {
        match args[i].as_str() {
            "--elf" => {
                i += 1;
                elf = Some(args[i].clone());
            }
            "--decode-file" => {
                i += 1;
                decode_file = Some(args[i].clone());
            }
            "--poseidon2-file" => {
                i += 1;
                poseidon2_file = Some(args[i].clone());
            }
            "--transcript-prefix" => {
                transcript_prefix = true;
            }
            "--witness-rows" => {
                witness_rows = true;
            }
            "--ordered-accesses" => {
                ordered_accesses = true;
            }
            "--relation-tuples" => {
                relation_tuples = true;
            }
            "--relation-sums" => {
                relation_sums = true;
            }
            "--trace-json" => {
                trace_json = true;
            }
            "--max-steps" => {
                i += 1;
                max = args[i].parse().expect("max-steps");
            }
            _ => {}
        }
        i += 1;
    }
    if let Some(path) = poseidon2_file {
        let raw = fs::read(path).expect("read poseidon2 file");
        let mut out = String::new();
        for chunk in raw.chunks_exact(64) {
            let mut state = [0u32; 16];
            for (i, word) in chunk.chunks_exact(4).enumerate() {
                state[i] = u32::from_le_bytes([word[0], word[1], word[2], word[3]]);
            }
            runner::poseidon2::poseidon2_permutation(&mut state);
            let rendered: Vec<String> = state.iter().map(|w| w.to_string()).collect();
            out.push_str(&rendered.join(" "));
            out.push('\n');
        }
        print!("{}", out);
        return;
    }
    if let Some(path) = decode_file {
        let raw = fs::read(path).expect("read decode file");
        let mut out = String::new();
        for chunk in raw.chunks_exact(4) {
            let word = u32::from_le_bytes([chunk[0], chunk[1], chunk[2], chunk[3]]);
            match air::decode::DecodedInst::decode(word) {
                Some(inst) => out.push_str(&format!(
                    "{:08x} {} {} {} {} {}\n",
                    word,
                    format!("{:?}", inst.opcode).to_uppercase(),
                    inst.rd,
                    inst.rs1,
                    inst.rs2,
                    inst.imm
                )),
                None => out.push_str(&format!("{:08x} -\n", word)),
            }
        }
        print!("{}", out);
        return;
    }
    let bytes = fs::read(elf.expect("--elf required")).expect("read elf");
    let result = runner::run(&bytes, max).expect("run");
    if witness_rows {
        dump_witness_rows(&result.tracer);
        return;
    }
    if ordered_accesses {
        dump_ordered_accesses(&result.tracer);
        return;
    }
    if trace_json {
        dump_trace_json(&result);
        return;
    }
    if relation_tuples {
        cp11_relation_tuples::dump(result);
        return;
    }
    if relation_sums {
        dump_relation_sums(result);
        return;
    }
    let public = prover::public_data::PublicData::new(&result);
    if transcript_prefix {
        // Shared-transcript-prefix mode: replay everything prove_rv32im mixes
        // before the first commitment root (prover.rs step 4) — a default
        // Blake2s channel driven by the oracle's own PublicData::mix_into —
        // and print the digest after every mix step.
        let mut recorder = RecordingChannel::default();
        println!("init digest={}", digest_hex(&recorder.inner));
        public.mix_into(&mut recorder);
        return;
    }
    let regs: Vec<String> = result.final_regs.iter().map(|r| r.to_string()).collect();
    println!(
        "{{\"trace\":{{\"final_pc\":{},\"final_regs\":[{}],\"total_steps\":{}}},\"public_data\":{}}}",
        result.final_pc,
        regs.join(","),
        result.cycles,
        serde_json::to_string(&public).expect("serialize public data")
    );
}

fn digest_hex(channel: &stwo::core::channel::Blake2sChannel) -> String {
    channel
        .digest()
        .as_ref()
        .iter()
        .map(|byte| format!("{:02x}", byte))
        .collect()
}

/// Blake2s channel wrapper that prints the digest after every mix step. The
/// oracle's own PublicData::mix_into drives the sequence; this wrapper is
/// pure instrumentation (no duplicated transcript model).
#[derive(Default, Clone, Debug)]
struct RecordingChannel {
    inner: stwo::core::channel::Blake2sChannel,
}

impl Channel for RecordingChannel {
    const BYTES_PER_HASH: usize = <stwo::core::channel::Blake2sChannel as Channel>::BYTES_PER_HASH;

    fn verify_pow_nonce(&self, n_bits: u32, nonce: u64) -> bool {
        self.inner.verify_pow_nonce(n_bits, nonce)
    }

    fn mix_u32s(&mut self, data: &[u32]) {
        self.inner.mix_u32s(data);
        println!(
            "mix_u32s len={} digest={}",
            data.len(),
            digest_hex(&self.inner)
        );
    }

    fn mix_felts(&mut self, felts: &[stwo::core::fields::qm31::SecureField]) {
        self.inner.mix_felts(felts);
        println!(
            "mix_felts len={} digest={}",
            felts.len(),
            digest_hex(&self.inner)
        );
    }

    fn mix_u64(&mut self, value: u64) {
        self.inner.mix_u64(value);
        println!("mix_u64 digest={}", digest_hex(&self.inner));
    }

    fn draw_secure_felt(&mut self) -> stwo::core::fields::qm31::SecureField {
        self.inner.draw_secure_felt()
    }

    fn draw_secure_felts(&mut self, n_felts: usize) -> Vec<stwo::core::fields::qm31::SecureField> {
        self.inner.draw_secure_felts(n_felts)
    }

    fn draw_u32s(&mut self) -> Vec<u32> {
        self.inner.draw_u32s()
    }
}
