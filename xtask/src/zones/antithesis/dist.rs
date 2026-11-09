//! Commands of the `zone_dist` template: a small distributed-systems check of the sequencer
//! quorum. Drivers are the `zone_payments` ones plus an operator leader rotation; the checks
//! assert safety while faults run (no forks, settled blocks stay, settlements match the nodes),
//! recovery once faults stop, and escrow backing at the end.
//!
//! The safety check keeps what it has seen in `dist.json` in the state directory, so later runs
//! compare against earlier observations: L1 settlements, sampled block hashes and per-node
//! bookkeeping for the coverage signals.

use alloy::{
    primitives::{B256, U256},
    providers::{Provider, ProviderBuilder},
    rpc::types::{BlockId, BlockNumberOrTag, Filter},
    sol_types::SolEvent as _,
    transports::http::reqwest,
};
use antithesis_sdk::{assert_always, assert_sometimes};
use eyre::{OptionExt as _, WrapErr as _};
use serde::{Deserialize, Serialize};
use serde_json::json;
use std::{
    collections::{BTreeMap, BTreeSet},
    fs::{File, OpenOptions},
    time::Duration,
};
use tempo_contracts::zones::{BatchSubmitted, LegacyBatchSubmitted, ZonePortal};
use tempo_precompiles::PATH_USD_ADDRESS;

use super::{Context, is_rpc_error, poll_until, random_below, random_index, shuffled};
use crate::verify_portal_backing::VerifyPortalBacking;

/// `zone_urls[..QUORUM]` are the sequencers zone-0..2; the rest are RPC followers.
const QUORUM: usize = 3;
/// A node this many blocks behind the highest head counts as lagging (two batches).
const LAG_BLOCKS: u64 = 40;
/// Settled heights the safety check re-reads per run, besides newly settled ones.
const SETTLED_SAMPLE: usize = 4;
/// Random heights below the common head the safety check compares per run.
const FORK_SAMPLE: usize = 3;
/// New heights the safety check reads from each node per run, so every height a node serves is
/// compared, not only a sample.
const SCAN_BLOCKS: u64 = 48;
/// The safety check re-reads random heights this far below a node's head for replaced blocks.
const RECENT_BLOCKS: u64 = 200;
/// Entries kept in the first-seen map before the lowest heights are dropped.
const SEEN_LIMIT: usize = 20_000;
/// Blocks per `eth_getLogs` request when scanning L1 for settlements.
const LOG_CHUNK: u64 = 5_000;
/// How long the recovery check waits for every zone node and L1 to answer once faults stop.
const NODES_UP_TIMEOUT: Duration = Duration::from_secs(180);
/// How long the recovery check gives the zone to settle a new batch once every node answers.
/// A batch is 20 zone blocks; fault-free runs settle one every ~10 s (2 zone blocks/s), so this
/// is 18x normal, leaving room for a new leader to catch up and the quorum to reconnect.
const BATCH_DEADLINE: Duration = Duration::from_secs(180);
/// How long the backing check retries before judging a deficit or an audit error.
const BACKING_TIMEOUT: Duration = Duration::from_secs(180);
/// Timeout for `zone_setLeader`, which waits up to 30 s for the L1 receipt.
const SET_LEADER_TIMEOUT: Duration = Duration::from_secs(45);

/// How long the operator watches a silent leader and unchanged survivor tips before forcing
/// recovery.
const LEADER_SILENCE: Duration = Duration::from_secs(10);
/// How long the operator waits for the recovery leader to extend the chain.
const RECOVERY_PRODUCES: Duration = Duration::from_secs(90);

/// The forced-recovery directive the operator last wrote, kept next to it in the control
/// directory.
#[derive(Debug, Serialize, Deserialize)]
struct RecoveryDirective {
    /// Manifest name and sequencer address of the recovery leader.
    leader: String,
    leader_address: alloy::primitives::Address,
    /// RPC URL index of the recovery leader.
    leader_index: usize,
    recovery_block_hash: B256,
    recovery_height: u64,
    /// The portal's leader epoch when the directive was written. The directive is complete
    /// once the portal's epoch is higher.
    portal_epoch: u64,
}

/// What earlier safety-check runs observed.
#[derive(Debug, Default, Serialize, Deserialize)]
struct Observed {
    /// Next L1 block to scan for `BatchSubmitted`.
    l1_cursor: u64,
    /// Zone height -> block hash, for every batch settled on L1.
    settled: BTreeMap<u64, B256>,
    /// Zone height -> block hash, the first time any node was seen holding that height.
    seen: BTreeMap<u64, B256>,
    nodes: BTreeMap<String, NodeObserved>,
    /// Leader epoch when first observed, and the latest epoch with the settled height then.
    first_epoch: Option<u64>,
    epoch: u64,
    epoch_settled: u64,
}

#[derive(Debug, Default, Serialize, Deserialize)]
struct NodeObserved {
    /// Highest head this node reported.
    max_head: u64,
    /// The node did not answer at the last run.
    down: bool,
    /// Settled height when the node answered again after being down.
    recovered_at_settled: Option<u64>,
    /// The highest head of any node when this one was found lagging.
    behind_target: Option<u64>,
    /// Highest height whose block the safety check has read from this node.
    #[serde(default)]
    scanned: u64,
    /// Settled height when the node was first found unreachable in the current outage.
    #[serde(default)]
    down_at_settled: Option<u64>,
    /// The node has reported the leader role.
    #[serde(default)]
    led: bool,
}

/// Holds the exclusive lock on the observations while a safety check runs.
struct ObservedFile {
    _lock: File,
    path: std::path::PathBuf,
}

impl ObservedFile {
    /// Locks the observations, or returns `None` if another safety check holds them.
    fn try_open(ctx: &Context) -> eyre::Result<Option<Self>> {
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(ctx.state_dir.join("dist.lock"))?;
        match lock.try_lock() {
            Ok(()) => Ok(Some(Self {
                _lock: lock,
                path: ctx.state_dir.join("dist.json"),
            })),
            Err(std::fs::TryLockError::WouldBlock) => Ok(None),
            Err(std::fs::TryLockError::Error(error)) => Err(error.into()),
        }
    }

    fn load(&self) -> eyre::Result<Observed> {
        match std::fs::read(&self.path) {
            Ok(bytes) => serde_json::from_slice(&bytes).wrap_err("corrupt dist.json"),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(Observed::default()),
            Err(error) => Err(error.into()),
        }
    }

    /// Writes atomically, so a killed check leaves the previous observations.
    fn save(&self, observed: &Observed) -> eyre::Result<()> {
        let tmp = self.path.with_extension("tmp");
        std::fs::write(&tmp, serde_json::to_vec(observed)?)?;
        std::fs::rename(&tmp, &self.path)?;
        Ok(())
    }
}

impl Context {
    /// Operator action: occasionally, at a random moment, asks a random sequencer to hand
    /// leadership to a random registered sequencer, the way an operator calls `zone_setLeader`.
    /// One run in four sends two or three such requests back to back through different
    /// sequencers, as two operators (or a retrying script) would.
    pub(super) async fn rotate_leader(&self) -> eyre::Result<()> {
        let requests = match random_below(4) {
            0 => return Ok(()),
            1 | 2 => 1,
            _ => 2 + random_below(2),
        };
        tokio::time::sleep(Duration::from_millis(random_below(20_000))).await;
        let portal = ZonePortal::new(self.portal, &self.l1);
        let count: u64 = portal.sequencerCount().call().await?.try_into()?;
        let mut calls = Vec::new();
        for _ in 0..requests {
            let target = portal
                .sequencerAt(U256::from(random_below(count)))
                .call()
                .await?;
            let relay = random_index(QUORUM.min(self.zone_urls.len()));
            let delay = Duration::from_millis(random_below(3_000));
            calls.push(async move {
                if requests > 1 {
                    tokio::time::sleep(delay).await;
                }
                (relay, target, self.set_leader(relay, target).await)
            });
        }
        let mut submitted = 0;
        for (relay, target, response) in futures::future::join_all(calls).await {
            let url = self.zone_urls[relay].as_str();
            match response {
                Ok(response) => {
                    let rotated = response["status"].as_str() == Some("submitted");
                    submitted += u64::from(rotated);
                    assert_sometimes!(
                        rotated,
                        "Operator rotates the zone leader",
                        &json!({ "relay": url, "response": response })
                    );
                    println!("rotate-leader: via {url} to {target}: {response}");
                }
                // A request can lose the epoch race to another one, or hit a faulted node.
                Err(error) => println!("rotate-leader: via {url} to {target} failed: {error:#}"),
            }
        }
        assert_sometimes!(
            submitted > 1,
            "Operator rotates the zone leader twice back to back",
            &json!({ "requests": requests, "submitted": submitted })
        );
        Ok(())
    }

    /// The last forced-recovery directive, if the operator wrote one.
    fn recovery_directive(&self) -> eyre::Result<Option<RecoveryDirective>> {
        match std::fs::read(self.control_dir.join("recovery.json")) {
            Ok(bytes) => Ok(Some(
                serde_json::from_slice(&bytes).wrap_err("corrupt recovery.json")?,
            )),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(None),
            Err(error) => Err(error.into()),
        }
    }

    /// The forced-recovery directive still in effect: written, and no portal transition since.
    async fn open_recovery(&self) -> eyre::Result<Option<RecoveryDirective>> {
        let Some(directive) = self.recovery_directive()? else {
            return Ok(None);
        };
        let epoch: u64 = ZonePortal::new(self.portal, &self.l1)
            .leaderEpoch()
            .call()
            .await?;
        Ok((epoch <= directive.portal_epoch).then_some(directive))
    }

    /// `zone_getSequencerInfo` of the sequencer at `index`, `None` if it does not answer.
    async fn sequencer_info(&self, index: usize) -> Option<serde_json::Value> {
        self.zones[index]
            .raw_request("zone_getSequencerInfo".into(), [(); 0])
            .await
            .ok()
    }

    /// Operator action, following the crashed-leader runbook in `crates/zones/p2p/README.md`:
    /// when the leader does not answer and both other sequencers sit on the same tip for
    /// [`LEADER_SILENCE`], writes a `[forced_recovery]` directive naming one of them and that
    /// tip. Every node restarts with it (see `zone-node.sh`). Once the recovery leader extends
    /// the chain, the operator returns the zone to the on-chain schedule with `zone_setLeader`.
    pub(super) async fn force_recovery(&self) -> eyre::Result<()> {
        if random_below(2) == 0 {
            return Ok(());
        }
        // One operator at a time.
        let lock = OpenOptions::new()
            .create(true)
            .truncate(false)
            .write(true)
            .open(self.state_dir.join("recovery.lock"))?;
        if lock.try_lock().is_err() {
            return Ok(());
        }
        if let Some(directive) = self.open_recovery().await? {
            // An earlier operator run was cut short: finish its recovery.
            return self.finish_recovery(&directive).await;
        }
        let portal = ZonePortal::new(self.portal, &self.l1);
        let portal_leader = portal.leader().call().await?;
        let portal_epoch: u64 = portal.leaderEpoch().call().await?;

        // The survivors: both sequencers that are not the portal's leader answer, follow, and
        // hold the same tip; the remaining sequencer does not answer.
        let survey = async || -> Option<(Vec<(usize, String, alloy::primitives::Address)>, B256, u64)> {
            let infos = futures::future::join_all((0..QUORUM).map(|index| self.sequencer_info(index))).await;
            let mut survivors = Vec::new();
            let mut tips = BTreeSet::new();
            for (index, info) in infos.iter().enumerate() {
                let Some(info) = info else { continue };
                let address: alloy::primitives::Address =
                    serde_json::from_value(info["local"]["sequencerAddress"].clone()).ok()?;
                if address == portal_leader || info["local"]["role"].as_str() == Some("leader") {
                    return None;
                }
                let hash: B256 = serde_json::from_value(info["localTip"]["zoneHash"].clone()).ok()?;
                let height = u64::from_str_radix(
                    info["localTip"]["zoneHeight"].as_str()?.trim_start_matches("0x"),
                    16,
                )
                .ok()?;
                tips.insert((hash, height));
                survivors.push((index, info["local"]["name"].as_str()?.to_owned(), address));
            }
            let &(hash, height) = tips.first()?;
            (survivors.len() == QUORUM - 1 && tips.len() == 1).then_some((survivors, hash, height))
        };
        let Some((_, first_tip, _)) = survey().await else {
            return Ok(());
        };
        tokio::time::sleep(LEADER_SILENCE).await;
        let Some((survivors, tip, height)) = survey().await else {
            return Ok(());
        };
        if tip != first_tip {
            return Ok(());
        }
        let (leader_index, leader, leader_address) =
            survivors[random_index(survivors.len())].clone();
        let directive = RecoveryDirective {
            leader,
            leader_address,
            leader_index,
            recovery_block_hash: tip,
            recovery_height: height,
            portal_epoch,
        };
        // The record first, so a directive is never in effect without it.
        self.write_control("recovery.json", &serde_json::to_vec(&directive)?)?;
        self.write_control(
            "recovery.toml",
            format!(
                "[forced_recovery]\nleader = \"{}\"\nrecovery_block_hash = \"{}\"\n",
                directive.leader, directive.recovery_block_hash
            )
            .as_bytes(),
        )?;
        assert_sometimes!(
            true,
            "Operator forces recovery after the leader stops answering",
            &json!({ "directive": directive, "portal_leader": portal_leader })
        );
        println!("force-recovery: wrote {directive:?}");
        self.finish_recovery(&directive).await
    }

    /// Waits for the recovery leader to extend the chain, then returns the zone to the
    /// on-chain schedule by naming it leader on the portal.
    async fn finish_recovery(&self, directive: &RecoveryDirective) -> eyre::Result<()> {
        let zone = &self.zones[directive.leader_index];
        let produced = poll_until(RECOVERY_PRODUCES, async || {
            Ok(zone.get_block_number().await? > directive.recovery_height)
        })
        .await?;
        assert_sometimes!(
            produced,
            "The recovery leader extends the chain under forced recovery",
            &json!({ "directive": directive })
        );
        if !produced {
            println!("force-recovery: {} has not produced yet", directive.leader);
            return Ok(());
        }
        let response = self
            .set_leader(directive.leader_index, directive.leader_address)
            .await?;
        assert_sometimes!(
            response["status"].as_str() == Some("submitted"),
            "Operator returns the zone to the on-chain schedule after forced recovery",
            &json!({ "directive": directive, "response": response })
        );
        println!("force-recovery: setLeader {}: {response}", directive.leader);
        Ok(())
    }

    /// Writes a control file atomically.
    fn write_control(&self, name: &str, bytes: &[u8]) -> eyre::Result<()> {
        let path = self.control_dir.join(name);
        let tmp = path.with_extension("tmp");
        std::fs::write(&tmp, bytes)?;
        std::fs::rename(&tmp, &path)?;
        Ok(())
    }

    /// Calls `zone_setLeader(target)` on the sequencer at `relay`.
    async fn set_leader(
        &self,
        relay: usize,
        target: alloy::primitives::Address,
    ) -> eyre::Result<serde_json::Value> {
        let client = reqwest::Client::builder()
            .timeout(SET_LEADER_TIMEOUT)
            .build()?;
        let node = ProviderBuilder::new()
            .connect_reqwest(client, self.zone_urls[relay].clone())
            .erased();
        Ok(node
            .raw_request("zone_setLeader".into(), (target,))
            .await?)
    }

    /// S1 no forks, S2 settled finality, S3 settlement validity, plus coverage bookkeeping.
    /// Runs while faults are injected: unreachable nodes and RPC errors are skipped.
    pub(super) async fn check_safety(&self) -> eyre::Result<()> {
        let Some(file) = ObservedFile::try_open(self)? else {
            println!("check-safety: another check is running");
            return Ok(());
        };
        let mut observed = file.load()?;

        let new_batches = match self.scan_settlements(&mut observed).await {
            Ok(batches) => batches,
            Err(error) if is_rpc_error(&error) => {
                println!("check-safety: L1 unavailable: {error:#}");
                Vec::new()
            }
            Err(error) => return Err(error),
        };
        let latest_settled = observed
            .settled
            .last_key_value()
            .map_or(0, |(height, _)| *height);

        // Read concurrently, so a node timing out does not skew the others' heads.
        let heads: Vec<Option<u64>> = futures::future::join_all(
            self.zones
                .iter()
                .map(async |zone| zone.get_block_number().await.ok()),
        )
        .await;
        let max_head = heads.iter().flatten().copied().max().unwrap_or_default();
        self.observe_nodes(&mut observed, &heads, max_head, latest_settled);
        self.observe_leader(&mut observed, latest_settled).await;

        self.observe_roles(&mut observed).await;

        // S1: every node holding a height holds the same block there, and the block first seen
        // at a height is never replaced. Reads every height a node has added since the last
        // run (up to SCAN_BLOCKS), plus a few random earlier ones.
        let blocks = self.scan_blocks(&mut observed, &heads).await;
        for (height, hashes) in blocks {
            let Some(&(_, first)) = hashes.first() else {
                continue;
            };
            let agree = hashes.iter().all(|(_, hash)| *hash == first);
            assert_always!(
                agree,
                "No forks: zone nodes never hold different blocks at the same height",
                &json!({ "height": height, "hashes": hashes })
            );
            let earlier = observed.seen.get(&height).copied();
            let kept = hashes
                .iter()
                .all(|(_, hash)| earlier.is_none_or(|earlier| earlier == *hash));
            assert_always!(
                kept,
                "A block a zone node served is never replaced by another at its height",
                &json!({ "height": height, "hashes": hashes, "first_seen": earlier })
            );
            if agree && kept {
                observed.seen.entry(height).or_insert(first);
            }
        }
        while observed.seen.len() > SEEN_LIMIT {
            observed.seen.pop_first();
        }

        // S3: each newly settled batch matches the block every node that passed it holds.
        for &(height, hash) in &new_batches {
            self.check_settled_block(
                &heads,
                height,
                hash,
                true,
            )
            .await;
        }
        // S2: earlier settled blocks never disappear or change on any node that passed them.
        let older: Vec<(u64, B256)> = observed
            .settled
            .iter()
            .map(|(height, hash)| (*height, *hash))
            .filter(|settled| !new_batches.contains(settled))
            .collect();
        for (height, hash) in shuffled(older).into_iter().take(SETTLED_SAMPLE) {
            self.check_settled_block(
                &heads,
                height,
                hash,
                false,
            )
            .await;
        }

        assert_sometimes!(
            latest_settled > 0,
            "A zone batch settles on L1",
            &json!({ "height": latest_settled })
        );
        file.save(&observed)?;
        println!(
            "check-safety: heads {heads:?}, settled {latest_settled}, {} new batches",
            new_batches.len()
        );
        Ok(())
    }

    /// Records batches settled on L1 since the last run and returns them as (height, hash).
    /// Reads the portal's settled height and hash at each L1 block holding a `BatchSubmitted`.
    async fn scan_settlements(&self, observed: &mut Observed) -> eyre::Result<Vec<(u64, B256)>> {
        let to = self.l1.get_block_number().await?;
        let portal = ZonePortal::new(self.portal, &self.l1);
        let filter = Filter::new().address(self.portal).event_signature(vec![
            BatchSubmitted::SIGNATURE_HASH,
            LegacyBatchSubmitted::SIGNATURE_HASH,
        ]);
        let mut new = Vec::new();
        let mut from = observed.l1_cursor;
        while from <= to {
            let end = to.min(from + LOG_CHUNK - 1);
            let blocks: BTreeSet<u64> = self
                .l1
                .get_logs(&filter.clone().from_block(from).to_block(end))
                .await?
                .iter()
                .filter_map(|log| log.block_number)
                .collect();
            for block in blocks {
                let at = BlockId::number(block);
                let height: u64 = portal.zoneHeight().block(at).call().await?.try_into()?;
                let hash = portal.blockHash().block(at).call().await?;
                if observed.settled.insert(height, hash).is_none() {
                    new.push((height, hash));
                }
            }
            from = end + 1;
            observed.l1_cursor = from;
        }
        Ok(new)
    }

    /// Asserts that every node whose head passed `height` holds `hash` there: as S3 for a
    /// newly settled batch, as S2 for an earlier one.
    async fn check_settled_block(
        &self,
        heads: &[Option<u64>],
        height: u64,
        hash: B256,
        new_batch: bool,
    ) {
        for ((url, zone), head) in self.zone_urls.iter().zip(&self.zones).zip(heads) {
            if !head.is_some_and(|head| head >= height) {
                continue;
            }
            let Ok(block) = zone
                .get_block_by_number(BlockNumberOrTag::Number(height))
                .await
            else {
                continue;
            };
            let node_hash = block.map(|block| block.header.hash);
            let details = json!({
                "node": url.as_str(),
                "height": height,
                "settled_hash": hash,
                "node_hash": node_hash,
                "node_head": head,
            });
            if new_batch {
                assert_always!(
                    node_hash == Some(hash),
                    "Settlement validity: every batch settled on L1 matches the nodes' block",
                    &details
                );
            } else {
                assert_always!(
                    node_hash == Some(hash),
                    "Settled finality: a block settled on L1 never disappears from a node that passed it",
                    &details
                );
            }
        }
    }

    /// Reads, from every reachable node, the blocks it added since the last run (at most
    /// [`SCAN_BLOCKS`]) and [`FORK_SAMPLE`] random heights among its last [`RECENT_BLOCKS`].
    /// Returns the hashes found per height.
    async fn scan_blocks(
        &self,
        observed: &mut Observed,
        heads: &[Option<u64>],
    ) -> BTreeMap<u64, Vec<(String, B256)>> {
        let mut blocks: BTreeMap<u64, Vec<(String, B256)>> = BTreeMap::new();
        for ((url, zone), head) in self.zone_urls.iter().zip(&self.zones).zip(heads) {
            let Some(head) = *head else {
                continue;
            };
            let node = observed.nodes.entry(url.to_string()).or_default();
            // A head below the scanned height is re-read from there: its blocks changed.
            let from = node.scanned.min(head);
            let to = head.min(from + SCAN_BLOCKS);
            let mut heights: BTreeSet<u64> = (from + 1..=to).collect();
            for _ in 0..FORK_SAMPLE {
                let back = random_below(RECENT_BLOCKS.min(head.max(1)));
                heights.insert(head.saturating_sub(back).max(1));
            }
            let read = futures::future::join_all(heights.iter().map(async |&height| {
                let block = zone
                    .get_block_by_number(BlockNumberOrTag::Number(height))
                    .await;
                (height, block)
            }))
            .await;
            let mut complete = true;
            for (height, block) in read {
                match block {
                    Ok(Some(block)) => blocks
                        .entry(height)
                        .or_default()
                        .push((url.to_string(), block.header.hash)),
                    // An error or a block gone since the head was read: scan it again next run.
                    _ => complete &= height > to,
                }
            }
            if complete {
                node.scanned = to;
            }
        }
        blocks
    }

    /// Reads each node's role from `zone_getSequencerInfo` for the leadership coverage
    /// signals. Roles are read at slightly different moments and a demoting leader reports
    /// its role until its tasks stop, so two leaders here are a signal, not a violation.
    async fn observe_roles(&self, observed: &mut Observed) {
        let roles = self.roles().await;
        let leaders: Vec<&str> = roles
            .iter()
            .filter(|(_, role)| role.as_deref() == Some("leader"))
            .map(|(url, _)| url.as_str())
            .collect();
        for url in &leaders {
            observed.nodes.entry((*url).to_owned()).or_default().led = true;
        }
        let details = json!({ "roles": roles });
        assert_sometimes!(
            leaders.len() > 1,
            "Two zone nodes report the leader role at once",
            &details
        );
        assert_sometimes!(
            leaders.is_empty() && roles.iter().take(QUORUM).all(|(_, role)| role.is_some()),
            "No sequencer reports the leader role while all three answer",
            &details
        );
        assert_sometimes!(
            roles.iter().any(|(_, role)| role.as_deref() == Some("fenced")),
            "A zone node reports the fenced role",
            &details
        );
        assert_sometimes!(
            self.zone_urls
                .iter()
                .take(QUORUM)
                .all(|url| observed.nodes.get(url.as_str()).is_some_and(|node| node.led)),
            "Every sequencer has led the zone",
            &details
        );
    }

    /// Each node's URL and its role per `zone_getSequencerInfo`, `None` if it did not answer.
    async fn roles(&self) -> Vec<(String, Option<String>)> {
        futures::future::join_all(self.zone_urls.iter().zip(&self.zones).map(
            async |(url, zone)| {
                let info: Option<serde_json::Value> = zone
                    .raw_request("zone_getSequencerInfo".into(), [(); 0])
                    .await
                    .ok();
                let role = info.and_then(|info| info["local"]["role"].as_str().map(str::to_owned));
                (url.to_string(), role)
            },
        ))
        .await
    }

    /// Per-node bookkeeping: outages, lag, and heads falling back below a settled height.
    fn observe_nodes(
        &self,
        observed: &mut Observed,
        heads: &[Option<u64>],
        max_head: u64,
        latest_settled: u64,
    ) {
        for (index, (url, head)) in self.zone_urls.iter().zip(heads).enumerate() {
            let node = observed.nodes.entry(url.to_string()).or_default();
            let Some(head) = *head else {
                node.down = true;
                let since = *node.down_at_settled.get_or_insert(latest_settled);
                if index < QUORUM && latest_settled > since {
                    assert_sometimes!(
                        true,
                        "A batch settles while a sequencer is unreachable",
                        &json!({ "node": url.as_str(), "down_at": since, "settled": latest_settled })
                    );
                }
                continue;
            };
            node.down_at_settled = None;
            if node.down {
                node.down = false;
                node.recovered_at_settled = Some(latest_settled);
            }
            if let Some(at) = node.recovered_at_settled
                && latest_settled > at
            {
                assert_sometimes!(
                    true,
                    "A batch settles after a zone node was unreachable",
                    &json!({ "node": url.as_str(), "recovered_at": at, "settled": latest_settled })
                );
                node.recovered_at_settled = None;
            }
            // A settled block the node had passed but no longer has.
            let lost = (head < node.max_head)
                .then(|| observed.settled.range(head + 1..=node.max_head).next_back())
                .flatten()
                .map(|(height, _)| *height);
            assert_always!(
                lost.is_none(),
                "Zone node head never falls back below a settled height",
                &json!({
                    "node": url.as_str(),
                    "head": head,
                    "previous_max_head": node.max_head,
                    "settled_height_lost": lost,
                })
            );
            node.max_head = if lost.is_some() {
                head
            } else {
                node.max_head.max(head)
            };
            if let Some(target) = node.behind_target
                && head >= target
            {
                assert_sometimes!(
                    true,
                    "A lagging zone node catches up",
                    &json!({ "node": url.as_str(), "target": target, "head": head })
                );
                node.behind_target = None;
            }
            if node.behind_target.is_none() && head + LAG_BLOCKS < max_head {
                node.behind_target = Some(max_head);
            }
        }
    }

    /// Tracks leader epochs for the "batch settles after a leader rotation" signal.
    async fn observe_leader(&self, observed: &mut Observed, latest_settled: u64) {
        let Ok(epoch) = ZonePortal::new(self.portal, &self.l1)
            .leaderEpoch()
            .call()
            .await
        else {
            return;
        };
        let first = *observed.first_epoch.get_or_insert(epoch);
        if epoch > observed.epoch {
            observed.epoch = epoch;
            observed.epoch_settled = latest_settled;
        }
        if observed.epoch > first && latest_settled > observed.epoch_settled {
            assert_sometimes!(
                true,
                "A batch settles after a leader rotation",
                &json!({ "epoch": observed.epoch, "settled": latest_settled })
            );
        }
    }

    /// After faults stop: every node answers (recovery), the chain advances and a new batch
    /// settles within [`BATCH_DEADLINE`] (L1), then nodes converge (L2) and every confirmed
    /// deposit and withdrawal lands (M1), via `check-settled`.
    pub(super) async fn check_recovery(&self) -> eyre::Result<()> {
        let mut heads = Vec::new();
        let up = poll_until(NODES_UP_TIMEOUT, async || {
            self.l1.get_block_number().await?;
            heads.clear();
            for zone in &self.zones {
                heads.push(zone.get_block_number().await?);
            }
            Ok(true)
        })
        .await?;
        assert_always!(
            up,
            "All zone nodes and L1 answer RPC after faults stop",
            &json!({ "heads": heads, "timeout_s": NODES_UP_TIMEOUT.as_secs() })
        );
        if !up {
            return Ok(());
        }
        let start_head = heads.iter().copied().max().unwrap_or_default();
        let mut start_settled = None;
        let mut last = (start_head, 0);
        let started = tokio::time::Instant::now();
        let (mut advanced, mut settled) = (false, false);
        poll_until(BATCH_DEADLINE, async || {
            let (height, _) = self.settled_block().await?;
            let start = *start_settled.get_or_insert(height);
            let mut max = 0;
            for zone in &self.zones {
                max = max.max(zone.get_block_number().await?);
            }
            last = (max, height);
            advanced |= max > start_head;
            settled |= height > start;
            Ok(advanced && settled)
        })
        .await?;
        let details = json!({
            "start_head": start_head,
            "start_settled": start_settled,
            "last_head": last.0,
            "last_settled": last.1,
            "waited_s": started.elapsed().as_secs(),
            "deadline_s": BATCH_DEADLINE.as_secs(),
        });
        assert_always!(advanced, "Zone chain advances after faults stop", &details);
        assert_always!(
            settled,
            "A new batch settles within the deadline after faults stop",
            &details
        );
        println!("check-recovery: {details}");
        self.check_one_leader().await?;
        self.check_settled().await
    }

    /// After faults stop: the sequencer the portal names leader reports the leader role, and
    /// every other node follows. Retried, since a handoff may still be in progress.
    async fn check_one_leader(&self) -> eyre::Result<()> {
        let portal = ZonePortal::new(self.portal, &self.l1);
        let mut last = json!(null);
        let agreed = poll_until(BATCH_DEADLINE, async || {
            // A forced recovery still in effect: the operator returns to the on-chain schedule.
            if let Some(directive) = self.open_recovery().await? {
                let response = self
                    .set_leader(directive.leader_index, directive.leader_address)
                    .await?;
                println!("check-recovery: completing forced recovery: {response}");
                return Ok(false);
            }
            let leader = portal.leader().call().await?;
            let infos: Vec<serde_json::Value> =
                futures::future::try_join_all(self.zones.iter().map(async |zone| {
                    zone.raw_request::<_, serde_json::Value>("zone_getSequencerInfo".into(), [(); 0])
                        .await
                }))
                .await?;
            let views: Vec<serde_json::Value> = infos
                .iter()
                .map(|info| {
                    json!({
                        "name": info["local"]["name"],
                        "address": info["local"]["sequencerAddress"],
                        "role": info["local"]["role"],
                    })
                })
                .collect();
            let leader_text = json!(leader);
            let agreed = views.iter().all(|view| {
                let expected = if view["address"] == leader_text {
                    "leader"
                } else {
                    "follower"
                };
                view["role"].as_str() == Some(expected)
            });
            last = json!({ "portal_leader": leader, "nodes": views });
            Ok(agreed)
        })
        .await?;
        assert_always!(
            agreed,
            "After faults stop, the portal's leader leads and every other node follows",
            &last
        );
        println!("check-recovery: one leader: {agreed} {last}");
        Ok(())
    }

    /// M2: at the end, the portal's escrow covers zone supply plus every pending flow, per
    /// `verify-portal-backing`. Retries while flows are still in motion.
    pub(super) async fn check_backing(&self) -> eyre::Result<()> {
        let zone_url = self.zone_urls.last().ok_or_eyre("no zone RPC URLs")?;
        let audit = VerifyPortalBacking::new(
            self.l1_url.to_string(),
            zone_url.to_string(),
            self.portal,
            PATH_USD_ADDRESS,
        );
        let deadline = tokio::time::Instant::now() + BACKING_TIMEOUT;
        let mut last = json!(null);
        let backed = loop {
            match audit.audit().await {
                Ok(report) if report.portal_balance >= report.required_backing => break true,
                Ok(report) => last = json!({ "deficit": report }),
                Err(error) if is_rpc_error(&error) => {
                    println!("check-backing: RPC error: {error:#}");
                }
                Err(error) => last = json!({ "error": format!("{error:#}") }),
            }
            if tokio::time::Instant::now() >= deadline {
                break false;
            }
            tokio::time::sleep(Duration::from_secs(2)).await;
        };
        // Only RPC errors throughout: nothing was judged, so nothing is asserted.
        if !backed && last.is_null() {
            println!("check-backing: no audit completed");
            return Ok(());
        }
        assert_always!(
            backed,
            "Portal escrow covers zone supply and pending flows",
            &last
        );
        println!("check-backing: backed={backed} {last}");
        Ok(())
    }
}
