# Findings: zone sequencer quorum under faults

Base: `main` at `bc3c03b3`, plus the test harness on this branch (see [README.md](README.md),
"`zone_dist` template"). Three sequencers (2-of-3 settlement), one RPC follower running the native
prover, one dev-mode Tempo L1. Faults: node kill/stop/pause, network partitions and clogs, clock
skips; the L1 and the workload are excluded.

| # | Finding | Severity (our reading) | Reproduced |
|---|---|---|---|
| 1 | After forced recovery, a returning ex-leader stays on its own chain forever; the zone can halt | High if forced recovery is used as documented | Every time, locally |
| 2 | Zone node aborts during graceful shutdown | Low | Once, under Antithesis |

The ordinary path was clean: leader rotation with `zone_setLeader` (including back-to-back
rotations), node kills and partitions produced no forks, no settlement mismatches and no failed
recoveries in about 60 minutes of faulted search.

---

## 1. Forced recovery leaves the ex-leader forked

### Summary

A leader persists a block before it replicates it. If it crashes holding blocks its followers never
received, and an operator then forces recovery onto a survivor, the old leader comes back, accepts
the same `[forced_recovery]` directive, and keeps its own blocks. It rejects every block from the
recovery leader and never converges. Nothing exits or reports unhealthy.

### Timeline observed

| Step | Event |
|---|---|
| 1 | `zone-1` leads. Its links to the followers are clogged. It builds and persists blocks 266-268. `zone-0`, `zone-2` and `zone-rpc` stay at 265. |
| 2 | `zone-1` is killed. |
| 3 | The operator sees the leader silent and both other sequencers on the same tip (265), and writes `[forced_recovery] leader = "zone-2"`, `recovery_block_hash = <265>`. All nodes restart with it. |
| 4 | `zone-2` builds its own 266, 267, 268. |
| 5 | `zone-1` restarts, logs `Installed manifest forced recovery ... resumed=true`, and keeps its 266-268. From then on: `Rejected peer block while importing pending blocks err=peer block parent mismatch at height 269`. |
| 6 | `zone-rpc`, restarted at 265, receives the old 266-268 through backfill and ends on `zone-1`'s chain. `zone-1` was the only node holding those blocks. |
| 7 | `zone-2` and `zone-0` settle their 268 on L1. `zone-rpc`'s shadow prover reports that its block 268 differs from the settled one. |

```
                 ┌─ 266a ─ 267a ─ 268a ─ 269 …   zone-2, zone-0   (settled on L1)
… 264 ─ 265 ─────┤
                 └─ 266b ─ 267b ─ 268b           zone-1, zone-rpc  (never settles)
```

### Consequences

- **The zone runs 2-of-2.** The ex-leader refuses to sign settlement proposals, since they do not
  match its chain. One more sequencer failure stops settlement.
- **The dead-end chain spreads by backfill.** A node at the recovery tip can import the ex-leader's
  blocks before the recovery leader's, and is then stuck the same way.
- **The zone can halt.** In another timeline of the same recovery, a later `zone_setLeader` named
  the stuck node leader. It never reached its activation anchor, so no node produced: the head
  stayed at 363 for the 180 s the check waited.
- **It looks healthy.** The process stays up, RPC answers, and `zone_getSequencerInfo` reports the
  role `follower`. The signs are a height that no longer moves and the repeated `parent mismatch`
  error.

The dead-end blocks never reach two signatures, so they are never settled on L1.

### Where in the code

- `install_manifest_forced_recovery` (`crates/zones/node/src/node.rs`) and
  `canonical_recovery_height` (`crates/zones/node/src/role.rs`) accept the directive when the
  recovery hash is a canonical ancestor of the local chain. Nothing checks whether the node holds
  blocks after that hash that the recovery leader did not produce.
- The comments state the assumption: the check "proves local ancestry only", and restart safety
  "assumes that participating nodes advanced on the same non-equivocating recovery-leader chain".
- A follower that already holds a block at a height rejects a different one there
  (`import_peer_block` in `crates/zones/node/src/follower.rs`: "peer block conflicts with canonical
  block"). There is no path that unwinds its own blocks.

### Reproduce

Build the images as in [README.md](README.md), tagged `:quorum`, then from this directory:

```bash
./repro-forced-recovery-fork.sh
```

It pauses the followers so the leader builds unreplicated blocks, kills the leader, forces recovery
onto `zone-1` at the survivors' tip, then restarts the old leader. Output from one run (role,
height, tip):

```
== 3. the crashed leader comes back (same directive)
["zone-0","follower","0x2c","0x08f7ced459"]     <- old leader, frozen at 44
["zone-1","leader","0xcb","0xc499070708"]
["zone-2","follower","0xcc","0x87283fe769"]
["zone-rpc","follower","0xcc","0x87283fe769"]
== block 32 on zone-0, zone-1, zone-2, zone-rpc
0x504672387c873d93f369eba64ef5276f5a1bef352cc493aab9ca9a83e1813d54
0xad688682326974e5a8a830656fb7dee0ac7aa24735e679bb935fa6450e289494
0xad688682326974e5a8a830656fb7dee0ac7aa24735e679bb935fa6450e289494
0xad688682326974e5a8a830656fb7dee0ac7aa24735e679bb935fa6450e289494
```

### Properties that failed

All trace to five forced recoveries in one run.

| Property | Where it is asserted | Failures |
|---|---|---|
| Follower receives a block that conflicts with its canonical chain | node, `follower.rs` | 41 |
| Leader settlement proposal matches the follower's state | node, `follower.rs` | 10 |
| Follower canonical block matches the settled batch | node, `shadow_prover.rs` (existing) | 5 |
| Zone nodes converge once faults stop | workload | 7 |
| A new batch settles within the deadline after faults stop | workload | 5 |
| After faults stop, the portal's leader leads and every other node follows | workload | 5 |
| Zone chain advances after faults stop | workload | 3 |

### Caveats about the harness

- The test operator declares the leader dead after 10 s without an RPC answer, with both other
  sequencers on one unchanged tip. In the run, the leader had been killed and was restarting.
- Every node, including the returning leader, restarts with the same directive. The runbook in
  `crates/zones/p2p/README.md` describes restarting the survivors and does not say what to do
  with the crashed leader's data before it rejoins.

### Questions

1. Is the ex-leader's datadir expected to be wiped, or resynced, before it rejoins after a forced
   recovery? If so, the runbook should say it.
2. Should the node enforce it? For example: on start with a directive, refuse to start (or unwind
   to the recovery block) when local blocks after the recovery block were not produced by the
   recovery leader.

---

## 2. Zone node aborts during graceful shutdown

Observed once. `zone-2` received SIGTERM from a node-stop fault and logged:

```
INFO reth::cli: Received SIGTERM
INFO reth::cli: Shutdown signal received — flushing engine state
INFO reth::cli: P2P runtime stopped
pthread lock: Invalid argument
```

It then died with signal 6 (exit code 134), about 1.5 ms after the last log line. Twenty-five other
SIGTERM shutdowns in the same timeline exited cleanly.

Not confirmed: the message matches RocksDB's abort when a mutex is locked after it was destroyed,
which would point at a race between process exit and a storage background thread rather than at
zone logic. The abort landed during the engine-state flush; the timeline ended there, so we did not
see whether the node restarted cleanly.

---

## Also noted

- A zone node exits when it cannot connect its L1 state provider (`Failed to connect L1 state
  provider`, `crates/zones/l1/src/state/provider.rs`) instead of retrying. The harness hides it
  with `restart: unless-stopped`.
- Followers often reject a settlement proposal. The one case we read was the expected one:
  `settlement proposal at height N is not durable; persisted head is N-1`. We did not tally the
  rest.
