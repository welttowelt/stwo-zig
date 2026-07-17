use std::io::{Cursor, Read};

use anyhow::{bail, ensure, Context, Result};
use cairo_vm::types::builtin_name::BuiltinName;
use stwo::core::fields::m31::{M31, P};
use stwo_cairo_adapter::builtins::{BuiltinSegments, MemorySegmentAddresses};
use stwo_cairo_adapter::memory::{EncodedMemoryValueId, Memory, MemoryConfig};
use stwo_cairo_adapter::opcodes::{CasmStatesByOpcode, StateTransitions};
use stwo_cairo_adapter::{ProverInput, PublicSegmentContext};
use stwo_cairo_common::prover_types::cpu::CasmState;

const MAGIC: &[u8; 8] = b"STWZCPI\0";
const VERSION: u32 = 1;
const OPCODE_COUNT: u32 = 20;
const PUBLIC_SEGMENT_COUNT: usize = 11;
const MAX_ITEMS: u64 = 1 << 30;

struct Decoder<'a> {
    cursor: Cursor<&'a [u8]>,
}

impl<'a> Decoder<'a> {
    fn new(bytes: &'a [u8]) -> Self {
        Self {
            cursor: Cursor::new(bytes),
        }
    }

    fn bytes<const N: usize>(&mut self) -> Result<[u8; N]> {
        let mut result = [0; N];
        self.cursor
            .read_exact(&mut result)
            .context("truncated STWZCPI input")?;
        Ok(result)
    }

    fn u8(&mut self) -> Result<u8> {
        Ok(self.bytes::<1>()?[0])
    }

    fn u16(&mut self) -> Result<u16> {
        Ok(u16::from_le_bytes(self.bytes()?))
    }

    fn u32(&mut self) -> Result<u32> {
        Ok(u32::from_le_bytes(self.bytes()?))
    }

    fn u64(&mut self) -> Result<u64> {
        Ok(u64::from_le_bytes(self.bytes()?))
    }

    fn count(&mut self, label: &str) -> Result<usize> {
        let value = self.u64()?;
        ensure!(value <= MAX_ITEMS, "{label} exceeds the STWZCPI item limit");
        usize::try_from(value).with_context(|| format!("{label} does not fit in usize"))
    }

    fn state(&mut self) -> Result<CasmState> {
        let pc = self.u32()?;
        let ap = self.u32()?;
        let fp = self.u32()?;
        ensure!(pc < P && ap < P && fp < P, "noncanonical M31 state word");
        Ok(CasmState {
            pc: M31::from_u32_unchecked(pc),
            ap: M31::from_u32_unchecked(ap),
            fp: M31::from_u32_unchecked(fp),
        })
    }

    fn states(&mut self) -> Result<Vec<CasmState>> {
        let count = self.count("opcode state count")?;
        (0..count).map(|_| self.state()).collect()
    }

    fn segment(&mut self) -> Result<Option<MemorySegmentAddresses>> {
        let present = self.u8()?;
        let padding = self.bytes::<7>()?;
        let begin_addr = self.u64()?;
        let stop_ptr = self.u64()?;
        ensure!(present <= 1, "invalid builtin segment presence flag");
        ensure!(padding == [0; 7], "nonzero builtin segment padding");
        if present == 0 {
            ensure!(
                begin_addr == 0 && stop_ptr == 0,
                "absent segment has bounds"
            );
            return Ok(None);
        }
        Ok(Some(MemorySegmentAddresses {
            begin_addr: usize::try_from(begin_addr).context("segment begin does not fit usize")?,
            stop_ptr: usize::try_from(stop_ptr).context("segment end does not fit usize")?,
        }))
    }

    fn finish(self, length: usize) -> Result<()> {
        ensure!(
            self.cursor.position() == length as u64,
            "trailing bytes in STWZCPI input"
        );
        Ok(())
    }
}

fn public_segment_context(mask: u16) -> Result<PublicSegmentContext> {
    ensure!(
        mask >> PUBLIC_SEGMENT_COUNT == 0,
        "STWZCPI public segment mask has unknown bits"
    );
    let names = [
        BuiltinName::output,
        BuiltinName::pedersen,
        BuiltinName::range_check,
        BuiltinName::ecdsa,
        BuiltinName::bitwise,
        BuiltinName::ec_op,
        BuiltinName::keccak,
        BuiltinName::poseidon,
        BuiltinName::range_check96,
        BuiltinName::add_mod,
        BuiltinName::mul_mod,
    ];
    let present = names
        .into_iter()
        .enumerate()
        .filter_map(|(bit, name)| (mask & (1 << bit) != 0).then_some(name))
        .collect::<Vec<_>>();
    Ok(PublicSegmentContext::new(&present))
}

pub fn decode(bytes: &[u8]) -> Result<ProverInput> {
    let mut decoder = Decoder::new(bytes);
    ensure!(&decoder.bytes::<8>()? == MAGIC, "invalid STWZCPI magic");
    ensure!(decoder.u32()? == VERSION, "unsupported STWZCPI version");
    ensure!(decoder.u32()? == 0, "unsupported STWZCPI flags");

    let initial_state = decoder.state()?;
    let final_state = decoder.state()?;
    let pc_count = decoder.count("pc count")?;
    let public_mask = decoder.u16()?;
    ensure!(decoder.u16()? == 0, "nonzero STWZCPI header padding");
    ensure!(decoder.u32()? == 0, "unsupported STWZCPI header field");
    ensure!(decoder.u32()? == OPCODE_COUNT, "unexpected opcode count");
    ensure!(decoder.u32()? == 0, "nonzero STWZCPI opcode padding");

    let mut grouped = CasmStatesByOpcode::default();
    let groups = [
        &mut grouped.generic_opcode,
        &mut grouped.add_ap_opcode,
        &mut grouped.add_opcode,
        &mut grouped.add_opcode_small,
        &mut grouped.assert_eq_opcode,
        &mut grouped.assert_eq_opcode_double_deref,
        &mut grouped.assert_eq_opcode_imm,
        &mut grouped.call_opcode_abs,
        &mut grouped.call_opcode_rel_imm,
        &mut grouped.jnz_opcode_non_taken,
        &mut grouped.jnz_opcode_taken,
        &mut grouped.jump_opcode_rel_imm,
        &mut grouped.jump_opcode_rel,
        &mut grouped.jump_opcode_double_deref,
        &mut grouped.jump_opcode_abs,
        &mut grouped.mul_opcode_small,
        &mut grouped.mul_opcode,
        &mut grouped.ret_opcode,
        &mut grouped.blake_compress_opcode,
        &mut grouped.qm_31_add_mul_opcode,
    ];
    for group in groups {
        *group = decoder.states()?;
    }

    let small_max = u128::from(decoder.u64()?) | (u128::from(decoder.u64()?) << 64);
    let log_small_value_capacity = decoder.u32()?;
    ensure!(decoder.u32()? == 0, "nonzero STWZCPI memory padding");
    let address_count = decoder.count("address table count")?;
    let f252_count = decoder.count("felt252 table count")?;
    let small_count = decoder.count("small-value table count")?;
    let address_to_id = (0..address_count)
        .map(|_| decoder.u32().map(EncodedMemoryValueId))
        .collect::<Result<Vec<_>>>()?;
    let f252_values = (0..f252_count)
        .map(|_| {
            let mut words = [0; 8];
            for word in &mut words {
                *word = decoder.u32()?;
            }
            Ok(words)
        })
        .collect::<Result<Vec<_>>>()?;
    let small_values = (0..small_count)
        .map(|_| Ok(u128::from(decoder.u64()?) | (u128::from(decoder.u64()?) << 64)))
        .collect::<Result<Vec<_>>>()?;

    let public_count = decoder.count("public memory address count")?;
    let public_memory_addresses = (0..public_count)
        .map(|_| decoder.u32())
        .collect::<Result<Vec<_>>>()?;
    let builtin_segments = BuiltinSegments {
        add_mod_builtin: decoder.segment()?,
        bitwise_builtin: decoder.segment()?,
        output: decoder.segment()?,
        mul_mod_builtin: decoder.segment()?,
        pedersen_builtin: decoder.segment()?,
        poseidon_builtin: decoder.segment()?,
        range_check96_builtin: decoder.segment()?,
        range_check_builtin: decoder.segment()?,
        ec_op_builtin: decoder.segment()?,
    };
    decoder.finish(bytes.len())?;

    if address_to_id.is_empty() {
        bail!("STWZCPI memory address table must not be empty");
    }
    Ok(ProverInput {
        state_transitions: StateTransitions {
            initial_state,
            final_state,
            casm_states_by_opcode: grouped,
        },
        memory: Memory {
            config: MemoryConfig {
                small_max,
                log_small_value_capacity,
            },
            address_to_id,
            f252_values,
            small_values,
        },
        pc_count,
        public_memory_addresses,
        builtin_segments,
        public_segment_context: public_segment_context(public_mask)?,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn rejects_unknown_public_segment_bits() {
        assert!(public_segment_context(1 << PUBLIC_SEGMENT_COUNT).is_err());
    }

    #[test]
    fn preserves_public_segment_bits() {
        let context = public_segment_context((1 << 0) | (1 << 7) | (1 << 10)).unwrap();
        assert_eq!(
            *context,
            [true, false, false, false, false, false, false, true, false, false, true]
        );
    }
}
