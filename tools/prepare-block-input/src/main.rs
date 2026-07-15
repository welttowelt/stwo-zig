//! Generates serialized BlockInput files for the ethereum-guest.
//!
//! Supports synthetic test blocks and real Ethereum blocks via RPC.
//!
//! Usage:
//!   prepare-block-input --output block.bin [--block-number N] [--tx-count N]
//!   prepare-block-input --output block.bin --rpc-url URL --block-number N

use alloy_primitives::{Address, B256, U256};
use anyhow::{Context, Result};
use clap::Parser;
use serde::{Deserialize, Serialize};
use std::fs;

// ---- Types matching ethereum-guest/src/block_input.rs ----

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockInput {
    pub block_number: u64,
    pub parent_hash: B256,
    pub timestamp: u64,
    pub gas_limit: u64,
    pub coinbase: Address,
    pub base_fee: u64,
    pub prev_randao: B256,
    pub chain_id: u64,
    pub transactions_rlp: Vec<Vec<u8>>,
    pub accounts: Vec<AccountWitness>,
    pub storage: Vec<StorageWitness>,
    pub bytecodes: Vec<BytecodeWitness>,
    pub block_hashes: Vec<BlockHashWitness>,
    pub expected_state_root: B256,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct AccountWitness {
    pub address: Address,
    pub nonce: u64,
    pub balance: U256,
    pub code_hash: B256,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct StorageWitness {
    pub address: Address,
    pub slot: U256,
    pub value: U256,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BytecodeWitness {
    pub code_hash: B256,
    pub code: Vec<u8>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct BlockHashWitness {
    pub number: u64,
    pub hash: B256,
}

/// SimpleTx matching ethereum-guest/src/executor.rs (for synthetic mode)
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct SimpleTx {
    pub from: Address,
    pub to: Address,
    pub value: U256,
    pub data: Vec<u8>,
    pub gas_limit: u64,
    pub gas_price: u64,
    pub nonce: u64,
}

// ---- CLI ----

#[derive(Parser)]
#[command(about = "Generate Ethereum block input for stwo-zig zkVM")]
struct Args {
    #[arg(short, long)]
    output: String,
    #[arg(long, default_value_t = 1)]
    block_number: u64,
    #[arg(long, default_value_t = 2)]
    tx_count: u32,
    /// Ethereum RPC URL. When provided, fetches a real block.
    #[arg(long)]
    rpc_url: Option<String>,
    /// Chain ID (default: 1 for mainnet)
    #[arg(long, default_value_t = 1)]
    chain_id: u64,
}

#[tokio::main]
async fn main() -> Result<()> {
    let args = Args::parse();

    let input = if let Some(rpc_url) = &args.rpc_url {
        fetch_real_block(rpc_url, args.block_number, args.chain_id).await?
    } else {
        generate_synthetic_block(args.block_number, args.tx_count, args.chain_id)
    };

    let serialized = postcard::to_allocvec(&input).context("serialization failed")?;
    fs::write(&args.output, &serialized).context("failed to write output")?;

    println!(
        "Generated block input: block={}, txs={}, accounts={}, storage={}, bytecodes={}, size={} bytes → {}",
        input.block_number,
        input.transactions_rlp.len(),
        input.accounts.len(),
        input.storage.len(),
        input.bytecodes.len(),
        serialized.len(),
        args.output
    );

    Ok(())
}

// ---- RPC Mode ----

async fn fetch_real_block(rpc_url: &str, block_number: u64, chain_id: u64) -> Result<BlockInput> {
    use alloy::providers::{Provider, ProviderBuilder};
    use alloy::rpc::types::{BlockId, BlockNumberOrTag, BlockTransactionsKind};
    use alloy::eips::eip2718::Encodable2718;
    use std::collections::{BTreeMap, BTreeSet};

    eprintln!("Connecting to {rpc_url}...");
    let provider = ProviderBuilder::new()
        .connect_http(rpc_url.parse().context("invalid RPC URL")?);

    // 1. Fetch block with full transactions.
    eprintln!("Fetching block {block_number}...");
    let block = provider
        .get_block(BlockId::Number(BlockNumberOrTag::Number(block_number)))
        .full()
        .await?
        .context("block not found")?;

    let header = &block.header;
    eprintln!(
        "Block {}: {} txs, gas_limit={}, gas_used={}",
        block_number,
        block.transactions.len(),
        header.gas_limit,
        header.gas_used,
    );

    // 2. Encode transactions as raw RLP bytes.
    let mut transactions_rlp = Vec::new();
    let mut accessed_addresses: BTreeSet<Address> = BTreeSet::new();

    // Always include coinbase.
    accessed_addresses.insert(header.beneficiary);

    for tx in block.transactions.txns() {
        // Encode the transaction envelope to EIP-2718 bytes.
        use alloy::eips::eip2718::Encodable2718;
        let encoded = tx.inner.encoded_2718();
        transactions_rlp.push(encoded);

        // Track accessed addresses.
        use alloy::consensus::transaction::SignerRecoverable;
        accessed_addresses.insert(tx.inner.signer());
        if let Some(to) = alloy::consensus::Transaction::to(&*tx.inner) {
            accessed_addresses.insert(to);
        }
    }

    // 3. Try prestateTracer for complete state access, fall back to tx-based.
    let mut accessed_storage: BTreeMap<Address, BTreeSet<U256>> = BTreeMap::new();

    // Attempt debug_traceBlock with prestateTracer.
    eprintln!("Tracing block for accessed state...");
    let trace_result = provider
        .raw_request::<_, serde_json::Value>(
            "debug_traceBlockByNumber".into(),
            (format!("0x{:x}", block_number), serde_json::json!({"tracer": "prestateTracer"})),
        )
        .await;

    if let Ok(traces) = trace_result {
        if let Some(arr) = traces.as_array() {
            for trace in arr {
                if let Some(result) = trace.get("result").and_then(|r| r.as_object()) {
                    for (addr_str, account_data) in result {
                        if let Ok(addr) = addr_str.parse::<Address>() {
                            accessed_addresses.insert(addr);
                            if let Some(storage) = account_data.get("storage").and_then(|s| s.as_object()) {
                                for key_str in storage.keys() {
                                    if let Ok(key) = key_str.parse::<U256>() {
                                        accessed_storage.entry(addr).or_default().insert(key);
                                    }
                                }
                            }
                        }
                    }
                }
            }
            eprintln!("  prestateTracer: {} accounts, {} storage slots",
                accessed_addresses.len(),
                accessed_storage.values().map(|s| s.len()).sum::<usize>());
        }
    } else {
        eprintln!("  prestateTracer unavailable, using tx-based address collection");
    }

    // 4. Fetch account state for all accessed addresses.
    eprintln!("Fetching state for {} accounts...", accessed_addresses.len());
    let parent_block = BlockId::Number(BlockNumberOrTag::Number(block_number - 1));
    let mut accounts = Vec::new();
    let mut bytecodes = Vec::new();
    let mut seen_code_hashes: BTreeSet<B256> = BTreeSet::new();

    for addr in &accessed_addresses {
        let balance = provider.get_balance(*addr).block_id(parent_block).await.unwrap_or(U256::ZERO);
        let nonce = provider.get_transaction_count(*addr).block_id(parent_block).await.unwrap_or(0);
        let code = provider.get_code_at(*addr).block_id(parent_block).await.unwrap_or_default();

        let code_hash = if code.is_empty() {
            B256::ZERO
        } else {
            use sha3::{Digest, Keccak256};
            let hash = B256::from_slice(&Keccak256::digest(&code));
            if seen_code_hashes.insert(hash) {
                bytecodes.push(BytecodeWitness {
                    code_hash: hash,
                    code: code.to_vec(),
                });
            }
            hash
        };

        accounts.push(AccountWitness {
            address: *addr,
            nonce,
            balance,
            code_hash,
        });
    }

    // 5. Fetch storage values.
    eprintln!("Fetching {} storage slots...", accessed_storage.values().map(|s| s.len()).sum::<usize>());
    let mut storage = Vec::new();
    for (addr, slots) in &accessed_storage {
        for slot in slots {
            let value = provider
                .get_storage_at(*addr, *slot)
                .block_id(parent_block)
                .await
                .unwrap_or(U256::ZERO);
            if !value.is_zero() {
                storage.push(StorageWitness {
                    address: *addr,
                    slot: *slot,
                    value,
                });
            }
        }
    }

    // 6. Fetch recent block hashes (for BLOCKHASH opcode).
    eprintln!("Fetching block hashes...");
    let mut block_hashes = Vec::new();
    let start = if block_number > 256 { block_number - 256 } else { 0 };
    for n in start..block_number {
        if let Ok(Some(b)) = provider
            .get_block(BlockId::Number(BlockNumberOrTag::Number(n)))
            .await
        {
            block_hashes.push(BlockHashWitness {
                number: n,
                hash: b.header.hash,
            });
        }
    }

    eprintln!("Done: {} accounts, {} storage, {} bytecodes, {} block hashes",
        accounts.len(), storage.len(), bytecodes.len(), block_hashes.len());

    Ok(BlockInput {
        block_number,
        parent_hash: header.parent_hash,
        timestamp: header.timestamp,
        gas_limit: header.gas_limit,
        coinbase: header.beneficiary,
        base_fee: header.base_fee_per_gas.unwrap_or(0),
        prev_randao: header.mix_hash,
        chain_id,
        transactions_rlp,
        accounts,
        storage,
        bytecodes,
        block_hashes,
        expected_state_root: header.state_root,
    })
}

// ---- Synthetic Mode ----

fn generate_synthetic_block(block_number: u64, tx_count: u32, chain_id: u64) -> BlockInput {
    let parent_hash = B256::from([0xAB; 32]);
    let coinbase = Address::from([0x42; 20]);
    let sender = Address::from([0x01; 20]);

    let accounts = vec![
        AccountWitness {
            address: sender,
            nonce: 0,
            balance: U256::from(1_000_000_000_000_000_000u64),
            code_hash: B256::ZERO,
        },
        AccountWitness {
            address: coinbase,
            nonce: 0,
            balance: U256::ZERO,
            code_hash: B256::ZERO,
        },
    ];

    let transactions: Vec<Vec<u8>> = (0..tx_count)
        .map(|i| {
            let mut to_bytes = [0u8; 20];
            to_bytes[0] = 0x02;
            to_bytes[19] = i as u8;

            let tx = SimpleTx {
                from: sender,
                to: Address::from(to_bytes),
                value: U256::from(100u64),
                data: vec![],
                gas_limit: 21000,
                gas_price: 1_000_000_000,
                nonce: i as u64,
            };
            postcard::to_allocvec(&tx).expect("tx serialization failed")
        })
        .collect();

    BlockInput {
        block_number,
        parent_hash,
        timestamp: 1700000000 + block_number,
        gas_limit: 30_000_000,
        coinbase,
        base_fee: 1_000_000_000,
        prev_randao: B256::ZERO,
        chain_id,
        transactions_rlp: transactions,
        accounts,
        storage: vec![],
        bytecodes: vec![],
        block_hashes: vec![],
        expected_state_root: B256::ZERO,
    }
}
