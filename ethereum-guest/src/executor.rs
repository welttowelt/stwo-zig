//! Block executor using revm with real Ethereum transaction decoding.

extern crate alloc;

use alloc::vec::Vec;
use alloy_primitives::{Address, B256, U256, Bytes, TxKind};
use alloy_consensus::{TxEnvelope, Transaction, transaction::SignerRecoverable};
use alloy_eips::eip2718::Decodable2718;
use revm::context::{TxEnv, BlockEnv, CfgEnv, Context, Journal};
use revm::handler::{MainBuilder, ExecuteCommitEvm, ExecuteEvm};
use revm::primitives::hardfork::SpecId;
// Use accelerated keccak256 via host syscall instead of software sha3.
use stwo_guest_sdk::precompiles;

use crate::block_input::{BlockInput, BlockResult};
use crate::witness_db::WitnessDb;

/// Execute all transactions in a block using revm.
/// Supports both real RLP-encoded transactions and legacy SimpleTx format.
pub fn execute_block(input: &BlockInput) -> BlockResult {
    let db = WitnessDb::from_block_input(input);
    let mut total_gas_used: u64 = 0;
    let mut tx_count: u32 = 0;
    let mut tx_successes: u32 = 0;

    let spec = spec_for_block(input.block_number);
    let mut ctx: Context<BlockEnv, TxEnv, CfgEnv, WitnessDb, Journal<WitnessDb>, ()> =
        Context::new(db, spec);

    ctx.block.number = U256::from(input.block_number);
    ctx.block.timestamp = U256::from(input.timestamp);
    ctx.block.gas_limit = input.gas_limit;
    ctx.block.beneficiary = input.coinbase;
    ctx.block.basefee = input.base_fee;
    ctx.cfg.chain_id = input.chain_id;
    ctx.block.prevrandao = Some(input.prev_randao);

    let mut evm = ctx.build_mainnet();
    let base_fee = Some(input.base_fee);

    for tx_bytes in &input.transactions_rlp {
        // Try real RLP decoding first, fall back to SimpleTx.
        let tx_env = if let Ok(envelope) = TxEnvelope::decode_2718(&mut &tx_bytes[..]) {
            // Real Ethereum transaction — recover signer via accelerated syscall.
            let caller = accelerated_recover_signer(&envelope)
                .unwrap_or(Address::ZERO);
            let kind = match envelope.to() {
                Some(addr) => TxKind::Call(addr),
                None => TxKind::Create,
            };

            TxEnv {
                caller,
                gas_limit: envelope.gas_limit(),
                gas_price: envelope.effective_gas_price(base_fee),
                kind,
                value: envelope.value(),
                data: envelope.input().clone(),
                nonce: envelope.nonce(),
                chain_id: envelope.chain_id(),
                ..Default::default()
            }
        } else if let Ok(tx) = postcard::from_bytes::<SimpleTx>(tx_bytes) {
            // Legacy SimpleTx format (for synthetic test blocks).
            TxEnv {
                caller: tx.from,
                gas_limit: tx.gas_limit,
                gas_price: tx.gas_price as u128,
                kind: TxKind::Call(tx.to),
                value: tx.value,
                data: Bytes::copy_from_slice(&tx.data),
                nonce: tx.nonce,
                chain_id: Some(input.chain_id),
                ..Default::default()
            }
        } else {
            // Skip undecodable transactions.
            continue;
        };

        match evm.transact_commit(tx_env) {
            Ok(result) => {
                total_gas_used += result.gas_used();
                tx_count += 1;
                if result.is_success() {
                    tx_successes += 1;
                }
            }
            Err(_) => {
                tx_count += 1;
            }
        }
    }

    // Compute state commitment: keccak256 of sorted (address, nonce, balance).
    let state_commitment = compute_state_commitment(&evm.ctx.journaled_state.database);

    BlockResult {
        state_root: state_commitment,
        gas_used: total_gas_used,
        tx_count,
        tx_successes,
        valid: true,
    }
}

/// Compute a deterministic commitment hash over the final state.
/// This is NOT the Ethereum MPT state root — it's a flat hash for
/// proof verification. The host computes the same hash independently.
fn compute_state_commitment(db: &WitnessDb) -> B256 {
    // Build commitment data: sorted (address, nonce, balance, code_hash) + storage.
    let mut data = Vec::new();
    for (addr, info) in &db.accounts {
        data.extend_from_slice(addr.as_slice());
        data.extend_from_slice(&info.nonce.to_le_bytes());
        data.extend_from_slice(&info.balance.to_le_bytes::<32>());
        data.extend_from_slice(info.code_hash.as_slice());
    }
    for ((addr, slot), value) in &db.storage {
        data.extend_from_slice(addr.as_slice());
        data.extend_from_slice(&slot.to_le_bytes::<32>());
        data.extend_from_slice(&value.to_le_bytes::<32>());
    }
    // Use accelerated keccak256 syscall (host computes at native speed).
    B256::from(precompiles::keccak256(&data))
}

/// Recover the transaction signer using the accelerated ecrecover syscall.
/// Falls back to software k256 recovery if the syscall fails.
fn accelerated_recover_signer(envelope: &TxEnvelope) -> Option<Address> {
    // Extract signature and signing hash from the envelope.
    use alloy_consensus::transaction::SignerRecoverable as _;
    let sig = envelope.signature();
    let hash = envelope.tx_hash();

    // Build the 128-byte ecrecover input: msg_hash[32] + v[32] + r[32] + s[32]
    let mut v_bytes = [0u8; 32];
    v_bytes[31] = sig.v() as u8; // v is 0 or 1 (recovery id) or 27/28

    let r_bytes: [u8; 32] = sig.r().to_be_bytes();
    let s_bytes: [u8; 32] = sig.s().to_be_bytes();

    let hash_bytes: &[u8; 32] = hash.as_ref();
    if let Some(addr_bytes) = precompiles::ecrecover(hash_bytes, &v_bytes, &r_bytes, &s_bytes) {
        Some(Address::from(addr_bytes))
    } else {
        // Fallback to software recovery.
        envelope.recover_signer().ok()
    }
}

/// Map block number to the correct EVM hardfork spec (Ethereum mainnet).
fn spec_for_block(block: u64) -> SpecId {
    match block {
        0..=199_999 => SpecId::FRONTIER,
        200_000..=1_149_999 => SpecId::HOMESTEAD,
        1_150_000..=2_462_999 => SpecId::TANGERINE,
        2_463_000..=2_674_999 => SpecId::SPURIOUS_DRAGON,
        2_675_000..=4_369_999 => SpecId::BYZANTIUM,
        4_370_000..=7_279_999 => SpecId::CONSTANTINOPLE,
        7_280_000..=9_068_999 => SpecId::ISTANBUL,
        9_069_000..=9_199_999 => SpecId::MUIR_GLACIER,
        9_200_000..=12_244_999 => SpecId::BERLIN,
        12_244_000..=12_964_999 => SpecId::BERLIN,
        12_965_000..=13_772_999 => SpecId::LONDON,
        13_773_000..=15_049_999 => SpecId::ARROW_GLACIER,
        15_050_000..=15_537_393 => SpecId::GRAY_GLACIER,
        15_537_394..=17_034_869 => SpecId::MERGE,
        17_034_870..=19_426_586 => SpecId::SHANGHAI,
        19_426_587.. => SpecId::CANCUN,
    }
}

/// Simplified transaction format for postcard serialization (test blocks).
#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct SimpleTx {
    pub from: Address,
    pub to: Address,
    pub value: U256,
    pub data: Vec<u8>,
    pub gas_limit: u64,
    pub gas_price: u64,
    pub nonce: u64,
}
