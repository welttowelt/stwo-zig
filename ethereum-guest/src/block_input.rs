//! Ethereum block input data structures using flat witness format.
//!
//! The host pre-resolves all state lookups and provides them as flat maps.
//! This avoids expensive MPT verification inside the guest — the STARK
//! proof validates the entire execution trace regardless.

extern crate alloc;

use alloc::collections::BTreeMap;
use alloc::vec::Vec;
use alloy_primitives::{Address, B256, U256};
use serde::{Deserialize, Serialize};

/// Input data for executing a single Ethereum block.
/// Serialized with postcard and passed from host to guest via hints.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockInput {
    /// Block number.
    pub block_number: u64,
    /// Parent block hash (32 bytes).
    pub parent_hash: B256,
    /// Block timestamp.
    pub timestamp: u64,
    /// Gas limit.
    pub gas_limit: u64,
    /// Coinbase address.
    pub coinbase: Address,
    /// Base fee per gas.
    pub base_fee: u64,
    /// Previous RANDAO / difficulty.
    pub prev_randao: B256,
    /// Chain ID.
    pub chain_id: u64,
    /// RLP-encoded transactions.
    pub transactions_rlp: Vec<Vec<u8>>,
    /// Pre-resolved account state (flat witness).
    pub accounts: Vec<AccountWitness>,
    /// Pre-resolved storage values (flat witness).
    pub storage: Vec<StorageWitness>,
    /// Contract bytecodes referenced during execution.
    pub bytecodes: Vec<BytecodeWitness>,
    /// Block hashes for BLOCKHASH opcode (up to 256 recent).
    pub block_hashes: Vec<BlockHashWitness>,
    /// Expected post-state root (for validation, 32 bytes).
    pub expected_state_root: B256,
}

/// Pre-resolved account state.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountWitness {
    pub address: Address,
    pub nonce: u64,
    pub balance: U256,
    pub code_hash: B256,
}

/// Pre-resolved storage slot value.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageWitness {
    pub address: Address,
    pub slot: U256,
    pub value: U256,
}

/// Contract bytecode.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BytecodeWitness {
    pub code_hash: B256,
    pub code: Vec<u8>,
}

/// Block hash for BLOCKHASH opcode.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockHashWitness {
    pub number: u64,
    pub hash: B256,
}

/// Result of block execution.
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockResult {
    /// Post-state root / commitment hash.
    pub state_root: B256,
    /// Total gas used by all transactions.
    pub gas_used: u64,
    /// Number of transactions processed.
    pub tx_count: u32,
    /// Number of transactions that succeeded (didn't revert).
    pub tx_successes: u32,
    /// Whether execution completed without errors.
    pub valid: bool,
}
