//! Volume drivers added for the planted-Reth-bug hunt (not part of Tempo's template).
//!
//! `payroll` is ordinary traffic at volume: one sender pays a cohort of brand-new holders
//! small amounts, as the calls of Tempo transactions, and a later run pays the same cohort a
//! second instalment. Recipients come from a fresh Antithesis-random seed per cohort, so no two
//! timelines share keys, and nothing here searches hashes. It only measures how deep the
//! holders' balance slots reach in pathUSD's storage trie.
//!
//! `deep` is an ACCELERATOR: it credits holders from a menu mined offline so that their
//! balance-slot keys share 2 to 10 leading nibbles. It ships only in the `-deep` workload image.

use alloy::{
    eips::Encodable2718 as _,
    primitives::{Address, B256, TxKind, U256, keccak256},
    providers::{DynProvider, Provider},
    rpc::types::BlockId,
    signers::SignerSync as _,
    sol_types::SolCall as _,
};
use antithesis_sdk::{assert_sometimes, assert_sometimes_greater_than, random::get_random};
use eyre::{OptionExt as _, WrapErr as _};
use serde_json::json;
use std::{
    fs::{self, OpenOptions},
    io::Write as _,
    path::PathBuf,
};
use tempo_contracts::precompiles::{ITIP20, PATH_USD_ADDRESS};
use tempo_precompiles::{storage::StorageKey as _, tip20::tip20_slots};
use tempo_primitives::{
    TempoTransaction,
    transaction::{Call, calc_gas_balance_spending},
};

use super::{
    Account, Context, RECEIPT_TIMEOUT, Record, TIP20_TX_GAS, poll_until, random_below,
    random_between, random_index, shuffled,
};

/// Transfers per Tempo transaction: the most calls the pool accepts.
const CALLS_PER_TX: usize = 32;
/// Transactions one sender keeps pending at once; zone nodes forward to the leader in small
/// bursts per peer.
const PENDING_TXS: usize = 4;
/// Gas for a batch and for each transfer in it. A transfer that creates a balance slot uses
/// about 100k gas.
const BATCH_BASE_GAS: u64 = 100_000;
const CALL_GAS: u64 = 200_000;
/// Most transactions per instalment.
const MAX_TXS: u128 = 16;
/// Most base units a dust payment carries. Two of them stay within one byte (127).
const DUST: u128 = 60;
/// How long a cohort waits for its second instalment.
const COHORT_WAIT: std::time::Duration = std::time::Duration::from_secs(15);
/// Largest balance, in base units, counted as small: such a balance slot's trie leaf can be
/// shorter than 32 bytes, so it is embedded in its parent.
const SMALL_AMOUNT: u128 = 127;

impl Context {
    /// Pays the second instalment of an earlier cohort, if one is waiting, then the first
    /// instalment of a new cohort.
    pub(super) async fn payroll(&self) -> eyre::Result<()> {
        let node = random_index(self.zones.len());
        let Some((sender, balance, _lease)) = self.lease_zone_sender(&self.zones[node]).await?
        else {
            return Ok(());
        };
        let url = &self.zone_urls[node];
        let zone = self.wallet(&sender, url);
        let gas_price = zone.get_gas_price().await?;
        let gas_limit = BATCH_BASE_GAS + CALL_GAS * CALLS_PER_TX as u64;
        let tx_fee: u128 = calc_gas_balance_spending(gas_limit, gas_price).try_into()?;
        // Fees and payments stay within half of what the sender holds.
        let mut txs = ((balance / 2) / (tx_fee + 1_000_000).max(1)).min(2 * MAX_TXS);
        if txs == 0 {
            println!("payroll: {} cannot afford a batch", sender.address());
            return Ok(());
        }
        let mut nonce = zone
            .get_transaction_count(sender.address())
            .pending()
            .await?;
        let dir = self.payroll_dir()?;

        // Second instalment: every recipient of a waiting cohort gets another dust payment, so
        // slots created in an earlier batch are read and rewritten in a later one.
        if let Some((seed, count)) = claim_cohort(&dir)? {
            let count = count.min(txs as usize * CALLS_PER_TX);
            let transfers: Vec<(Address, u128)> = (0..count)
                .map(|i| (recipient(seed, i as u32), random_between(1, DUST)))
                .collect();
            let sent = self
                .pay(&zone, &sender, gas_price, &transfers, &mut nonce)
                .await?;
            assert_sometimes!(
                sent == transfers.len(),
                "Payroll pays a cohort its second instalment",
                &json!({ "cohort": seed, "recipients": sent })
            );
            println!("payroll: second instalment to {sent}/{count} of cohort {seed}");
            txs = txs.saturating_sub(count.div_ceil(CALLS_PER_TX) as u128);
            if sent != transfers.len() {
                return Ok(());
            }
        }

        let txs = random_between(1, txs.min(MAX_TXS));
        if txs == 0 {
            return Ok(());
        }
        let seed = get_random();
        let transfers: Vec<(Address, u128)> = (0..txs as usize * CALLS_PER_TX)
            .map(|i| {
                // Mostly dust; one in eight is an ordinary amount up to a cent.
                let amount = if random_below(8) == 0 {
                    random_between(1, 10_000)
                } else {
                    random_between(1, DUST)
                };
                (recipient(seed, i as u32), amount)
            })
            .collect();
        let sent = self
            .pay(&zone, &sender, gas_price, &transfers, &mut nonce)
            .await?;
        if sent > 0 {
            record_holders(&dir, &transfers[..sent])?;
            fs::write(dir.join("pending").join(format!("{seed}-{sent}")), b"")?;
        }
        println!(
            "payroll: first instalment to {sent} new holders of cohort {seed} from {}",
            sender.address()
        );
        observe_holders(&dir)
    }

    fn payroll_dir(&self) -> eyre::Result<PathBuf> {
        let dir = self.state_dir.join("payroll");
        fs::create_dir_all(dir.join("pending"))
            .wrap_err_with(|| format!("failed creating {}", dir.display()))?;
        Ok(dir)
    }

    /// Sends `transfers` from `sender` as Tempo transactions of [`CALLS_PER_TX`] calls,
    /// [`PENDING_TXS`] pending at once. Returns how many leading transfers were confirmed; stops
    /// at the first transaction that does not land.
    async fn pay(
        &self,
        zone: &DynProvider,
        sender: &Account,
        gas_price: u128,
        transfers: &[(Address, u128)],
        nonce: &mut u64,
    ) -> eyre::Result<usize> {
        let chain_id = zone.get_chain_id().await?;
        let mut confirmed = 0;
        for round in transfers.chunks(CALLS_PER_TX * PENDING_TXS) {
            let mut sent = Vec::new();
            for group in round.chunks(CALLS_PER_TX) {
                let calls: Vec<Call> = group
                    .iter()
                    .map(|(to, amount)| Call {
                        to: TxKind::Call(PATH_USD_ADDRESS),
                        value: U256::ZERO,
                        input: ITIP20::transferCall {
                            to: *to,
                            amount: U256::from(*amount),
                        }
                        .abi_encode()
                        .into(),
                    })
                    .collect();
                let tx = TempoTransaction {
                    chain_id,
                    max_fee_per_gas: gas_price,
                    max_priority_fee_per_gas: gas_price,
                    gas_limit: BATCH_BASE_GAS + CALL_GAS * calls.len() as u64,
                    calls,
                    nonce: *nonce,
                    ..Default::default()
                };
                let signature = sender.signer.sign_hash_sync(&tx.signature_hash())?;
                let encoded = tx.into_signed(signature.into()).encoded_2718();
                let hash = *zone.send_raw_transaction(&encoded).await?.tx_hash();
                *nonce += 1;
                sent.push((hash, group.len()));
            }
            for (hash, calls) in sent {
                let mut receipt = None;
                poll_until(RECEIPT_TIMEOUT, async || {
                    receipt = zone
                        .raw_request::<_, Option<serde_json::Value>>(
                            "eth_getTransactionReceipt".into(),
                            (hash,),
                        )
                        .await?;
                    Ok(receipt.is_some())
                })
                .await?;
                let Some(receipt) = receipt else {
                    println!("payroll: batch {hash} not confirmed within the timeout");
                    return Ok(confirmed);
                };
                let status = receipt["status"].as_str() == Some("0x1");
                assert_sometimes!(
                    status,
                    "Batched zone transfers succeed",
                    &json!({ "tx": hash, "from": sender.address(), "calls": calls })
                );
                if !status {
                    println!("payroll: batch {hash} reverted");
                    return Ok(confirmed);
                }
                confirmed += calls;
            }
        }
        Ok(confirmed)
    }

    /// ACCELERATOR. Credits the members of one to three groups from the mined deep key menu
    /// with small amounts.
    pub(super) async fn deep(&self) -> eyre::Result<()> {
        let node = random_index(self.zones.len());
        let Some((sender, _balance, _lease)) = self.lease_zone_sender(&self.zones[node]).await?
        else {
            return Ok(());
        };
        let zone = self.wallet(&sender, &self.zone_urls[node]);
        let gas_price = zone.get_gas_price().await?;
        let mut nonce = zone
            .get_transaction_count(sender.address())
            .pending()
            .await?;
        for _ in 0..random_between(1, 3) {
            let (depth, holders) = DEEP_GROUPS[random_index(DEEP_GROUPS.len())];
            let members: Vec<Address> = holders.iter().map(|&h| holder_address(h)).collect();
            let keys: Vec<B256> = members.iter().map(|&member| balance_key(member)).collect();
            eyre::ensure!(
                keys.windows(2)
                    .all(|pair| shared_nibbles(&pair[0], &pair[1]) >= usize::from(depth)),
                "deep group {holders:?} no longer shares {depth} nibbles"
            );
            // Credit every member once, in random order, and sometimes one of them again, so
            // the group's shared branch fills up and later blocks read and rewrite its leaves.
            let mut targets = shuffled(members.clone());
            if random_below(2) == 0 {
                targets.push(members[random_index(members.len())]);
            }
            for to in targets {
                self.deep_credit(&zone, sender.address(), gas_price, nonce, depth, &members, to)
                    .await?;
                nonce += 1;
            }
        }
        Ok(())
    }

    #[expect(clippy::too_many_arguments)]
    async fn deep_credit(
        &self,
        zone: &DynProvider,
        sender: Address,
        gas_price: u128,
        nonce: u64,
        depth: u8,
        members: &[Address],
        to: Address,
    ) -> eyre::Result<()> {
        let token = ITIP20::new(PATH_USD_ADDRESS, zone);
        // Zone RPC only answers balance reads from the holder itself.
        let balance_of = async |holder: Address, at: BlockId| -> eyre::Result<u128> {
            Ok(token
                .balanceOf(holder)
                .from(holder)
                .block(at)
                .call()
                .await?
                .try_into()?)
        };
        let before = balance_of(to, BlockId::latest()).await?;
        // Mostly keep the leaf small; once in a while push it past one byte.
        let amount = if before < SMALL_AMOUNT && random_below(8) != 0 {
            random_between(1, SMALL_AMOUNT - before)
        } else {
            random_between(1, 2 * SMALL_AMOUNT)
        };
        let receipt = token
            .transfer(to, U256::from(amount))
            .gas(TIP20_TX_GAS)
            .gas_price(gas_price)
            .nonce(nonce)
            .send()
            .await?
            .with_timeout(Some(RECEIPT_TIMEOUT))
            .get_receipt()
            .await?;
        if !receipt.status() {
            return Ok(());
        }
        let zone_block = receipt.block_number.ok_or_eyre("receipt has no block")?;
        self.ledger.append(&Record::Transfer {
            zone_tx: receipt.transaction_hash,
            zone_block,
            from: sender,
            to,
            amount,
        })?;
        let at = BlockId::number(zone_block);
        let credited = balance_of(to, at).await?;
        let mut siblings = Vec::new();
        for &member in members.iter().filter(|&&member| member != to) {
            siblings.push(balance_of(member, at).await?);
        }
        let all_small = credited <= SMALL_AMOUNT
            && siblings
                .iter()
                .any(|&balance| balance > 0 && balance <= SMALL_AMOUNT);
        let details = json!({
            "tx": receipt.transaction_hash,
            "zone_block": zone_block,
            "depth": depth,
            "to": to,
            "amount": amount.to_string(),
            "credited": credited.to_string(),
            "siblings": siblings.iter().map(u128::to_string).collect::<Vec<_>>(),
        });
        assert_sometimes!(
            depth >= 8 && all_small,
            "Accelerator: transfer credits a mined holder while it and a sibling sharing >= 8 nibbles both hold small balances",
            &details
        );
        println!("deep: {amount} {sender} -> {to} (depth {depth}, balance {credited}, siblings {siblings:?})");
        Ok(())
    }
}

/// Recipient `index` of the cohort with this seed.
fn recipient(seed: u64, index: u32) -> Address {
    let mut preimage = b"tempo-zone-antithesis-payroll".to_vec();
    preimage.extend_from_slice(&seed.to_be_bytes());
    preimage.extend_from_slice(&index.to_be_bytes());
    Address::from_word(keccak256(preimage))
}

/// The key of `holder`'s pathUSD balance slot in the token's storage trie.
fn balance_key(holder: Address) -> B256 {
    keccak256(holder.mapping_slot(tip20_slots::BALANCES).to_be_bytes::<32>())
}

/// Takes one waiting cohort, if any: its seed and size. Removing the file is the claim, so two
/// commands never pay the same cohort.
fn claim_cohort(dir: &std::path::Path) -> eyre::Result<Option<(u64, usize)>> {
    let mut names: Vec<String> = fs::read_dir(dir.join("pending"))?
        .filter_map(|entry| entry.ok()?.file_name().into_string().ok())
        .collect();
    names.sort_unstable();
    for name in shuffled(names) {
        let Some((seed, count)) = name.split_once('-') else {
            continue;
        };
        let (Ok(seed), Ok(count)) = (seed.parse(), count.parse()) else {
            continue;
        };
        // A cohort waits until its first instalment is in an earlier batch than the second:
        // the prover's witness covers a whole batch (20 blocks, about 10 seconds).
        let path = dir.join("pending").join(&name);
        let waited = fs::metadata(&path)
            .and_then(|metadata| metadata.modified())
            .ok()
            .and_then(|modified| modified.elapsed().ok());
        if waited.is_none_or(|waited| waited < COHORT_WAIT) {
            continue;
        }
        if fs::remove_file(&path).is_ok() {
            return Ok(Some((seed, count)));
        }
    }
    Ok(None)
}

/// Appends each new holder's trie key prefix and whether its balance is small.
fn record_holders(dir: &std::path::Path, transfers: &[(Address, u128)]) -> eyre::Result<()> {
    let mut bytes = Vec::with_capacity(transfers.len() * 9);
    for (holder, amount) in transfers {
        bytes.extend_from_slice(&balance_key(*holder)[..8]);
        bytes.push(u8::from(*amount <= DUST));
    }
    OpenOptions::new()
        .create(true)
        .append(true)
        .open(dir.join("holders"))?
        .write_all(&bytes)?;
    Ok(())
}

/// Observes how deep the payroll holders' balance slots reach in pathUSD's storage trie,
/// without steering anything.
fn observe_holders(dir: &std::path::Path) -> eyre::Result<()> {
    let bytes = match fs::read(dir.join("holders")) {
        Ok(bytes) => bytes,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error.into()),
    };
    let mut keys: Vec<(u64, bool)> = bytes
        .chunks_exact(9)
        .map(|chunk| {
            let prefix = u64::from_be_bytes(chunk[..8].try_into().expect("8 bytes"));
            (prefix, chunk[8] == 1)
        })
        .collect();
    keys.sort_unstable();
    let (mut shared, mut shared_small) = (0, 0);
    for pair in keys.windows(2) {
        let nibbles = ((pair[0].0 ^ pair[1].0).leading_zeros() / 4) as usize;
        shared = shared.max(nibbles);
        if pair[0].1 || pair[1].1 {
            shared_small = shared_small.max(nibbles);
        }
    }
    let holders = keys.len();
    let details = json!({
        "holders": holders,
        "shared_nibbles": shared,
        "shared_nibbles_small": shared_small,
    });
    assert_sometimes_greater_than!(shared, 5, "Payroll holders share at least 6 nibbles", &details);
    assert_sometimes_greater_than!(shared, 6, "Payroll holders share at least 7 nibbles", &details);
    assert_sometimes_greater_than!(shared, 7, "Payroll holders share at least 8 nibbles", &details);
    assert_sometimes_greater_than!(
        shared_small,
        7,
        "Payroll holders share at least 8 nibbles next to a small balance",
        &details
    );
    assert_sometimes_greater_than!(holders, 10_000, "More than 10000 payroll holders", &details);
    assert_sometimes_greater_than!(holders, 25_000, "More than 25000 payroll holders", &details);
    assert_sometimes_greater_than!(holders, 50_000, "More than 50000 payroll holders", &details);
    assert_sometimes_greater_than!(holders, 100_000, "More than 100000 payroll holders", &details);
    println!("payroll holders: {details}");
    Ok(())
}

/// How many leading nibbles `a` and `b` share.
fn shared_nibbles(a: &B256, b: &B256) -> usize {
    match a.iter().zip(b.iter()).position(|(x, y)| x != y) {
        Some(byte) => 2 * byte + usize::from((a[byte] ^ b[byte]) >> 4 == 0),
        None => 64,
    }
}

fn holder_address(holder: u64) -> Address {
    Address::from_word(B256::from(U256::from(holder)))
}

/// ACCELERATOR input. Groups of holder indices; `(d, holders)` means the holders' balance-slot
/// keys share at least `d` leading nibbles. Mined offline over holders `0x10000..0x10000 + 4M`;
/// holder `h` is the address with `h` in its low bytes.
const DEEP_GROUPS: &[(u8, &[u64])] = &[
    (2, &[66337, 65661, 66091]),
    (2, &[66406, 66032, 65928]),
    (2, &[66454, 66277, 65994]),
    (2, &[66550, 66368, 66225]),
    (4, &[3585082, 3467254, 687415]),
    (4, &[1824839, 2084019, 521448]),
    (4, &[430495, 2927738, 3188552]),
    (4, &[2235893, 3034074, 3967481]),
    (6, &[2994877, 2334092, 3074675]),
    (6, &[2371258, 2659043, 2624108]),
    (6, &[2355271, 1170989, 3739746]),
    (6, &[2652022, 3846290, 536497]),
    (8, &[3557282, 2081222]),
    (8, &[1781598, 3445938]),
    (8, &[2230282, 4057805]),
    (8, &[3858501, 2991738]),
    (9, &[692268, 3208275]),
    (9, &[1204603, 120373]),
    (9, &[3820028, 1876713]),
    (9, &[3393698, 3333290]),
    (10, &[2717512, 4048069]),
    (10, &[2906884, 725111]),
    (10, &[3784489, 1315254]),
    (10, &[3847492, 3201022]),
];
