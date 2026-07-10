//! Flat witness-backed Database implementation for revm.

extern crate alloc;

use alloc::collections::BTreeMap;
use alloy_primitives::{Address, B256, U256};
use revm::bytecode::Bytecode;
use revm::database_interface::{DBErrorMarker, Database, DatabaseCommit};
use revm::state::{Account, AccountInfo, EvmStorageSlot};
use revm::primitives::AddressMap;

use crate::block_input::BlockInput;

/// Error type for the witness database.
#[derive(Debug)]
pub struct WitnessDbError;

impl core::fmt::Display for WitnessDbError {
    fn fmt(&self, f: &mut core::fmt::Formatter) -> core::fmt::Result {
        write!(f, "witness database error")
    }
}

impl core::error::Error for WitnessDbError {}
impl DBErrorMarker for WitnessDbError {}

/// A Database backed by pre-resolved flat witness data.
/// Supports both reads and commits for multi-transaction block execution.
pub struct WitnessDb {
    pub accounts: BTreeMap<Address, AccountInfo>,
    pub storage: BTreeMap<(Address, U256), U256>,
    pub bytecodes: BTreeMap<B256, Bytecode>,
    pub block_hashes: BTreeMap<u64, B256>,
}

impl WitnessDb {
    pub fn from_block_input(input: &BlockInput) -> Self {
        let mut bytecodes = BTreeMap::new();
        for bw in &input.bytecodes {
            bytecodes.insert(bw.code_hash, Bytecode::new_raw(
                alloy_primitives::Bytes::copy_from_slice(&bw.code),
            ));
        }

        let mut accounts = BTreeMap::new();
        for aw in &input.accounts {
            // Load bytecode into AccountInfo so revm can access it directly.
            let code = bytecodes.get(&aw.code_hash).cloned();
            accounts.insert(aw.address, AccountInfo {
                balance: aw.balance,
                nonce: aw.nonce,
                code_hash: aw.code_hash,
                code,
                account_id: None,
            });
        }

        let mut storage = BTreeMap::new();
        for sw in &input.storage {
            storage.insert((sw.address, sw.slot), sw.value);
        }

        let mut block_hashes = BTreeMap::new();
        for bh in &input.block_hashes {
            block_hashes.insert(bh.number, bh.hash);
        }

        Self { accounts, storage, bytecodes, block_hashes }
    }
}

impl Database for WitnessDb {
    type Error = WitnessDbError;

    fn basic(&mut self, address: Address) -> Result<Option<AccountInfo>, Self::Error> {
        Ok(self.accounts.get(&address).cloned())
    }

    fn code_by_hash(&mut self, code_hash: B256) -> Result<Bytecode, Self::Error> {
        self.bytecodes
            .get(&code_hash)
            .cloned()
            .ok_or(WitnessDbError)
    }

    fn storage(&mut self, address: Address, index: U256) -> Result<U256, Self::Error> {
        Ok(self.storage.get(&(address, index)).copied().unwrap_or(U256::ZERO))
    }

    fn block_hash(&mut self, number: u64) -> Result<B256, Self::Error> {
        Ok(self.block_hashes.get(&number).copied().unwrap_or(B256::ZERO))
    }
}

impl DatabaseCommit for WitnessDb {
    fn commit(&mut self, changes: AddressMap<Account>) {
        for (addr, account) in changes {
            if account.is_selfdestructed() {
                self.accounts.remove(&addr);
                self.storage.retain(|&(a, _), _| a != addr);
                continue;
            }

            // Update account info.
            self.accounts.insert(addr, account.info.clone());

            // Store bytecode if present.
            if let Some(code) = &account.info.code {
                if account.info.code_hash != B256::ZERO {
                    self.bytecodes.insert(account.info.code_hash, code.clone());
                }
            }

            // Apply storage changes.
            for (slot, value) in &account.storage {
                if value.present_value.is_zero() {
                    self.storage.remove(&(addr, *slot));
                } else {
                    self.storage.insert((addr, *slot), value.present_value);
                }
            }
        }
    }
}
