# Findings: Tempo zones under Antithesis

Runs by Antithesis on the `tempo` tenant, tagged `antithesis-adi`. This file keeps two kinds of
result apart:

- **[Part 1: bugs in Tempo's code](#part-1-bugs-in-tempos-code).** Found on `main` at
  `bc3c03b3` by the sequencer-quorum harness on this branch (`antithesis/adi-quorum-bug`). Nobody
  put them there.
- **[Part 2: planted bugs](#part-2-planted-bugs).** Tempo deliberately planted three changes in
  the Reth revision pinned by its `antithesis-poc` branch, to see whether testing finds them. A
  result here says how good the tests are, not that Tempo has a bug. Work is on branch
  `antithesis/adi-reth-planted-bugs`.

The [harness](#harness) for Part 1 is described after both parts.

---

# Part 1: bugs in Tempo's code

| # | Bug | Status | Run | Failing property |
|---|---|---|---|---|
| 1 | A role change that overlaps about 40 s of L1-link disruption ends the node's role controller for good; the zone halts if that node is the next leader | Found; survived review | `06d7a6f20b71bce259a9be336de8bac0-67-0` | Role controller exits after an unproven generation teardown (12) |
| 2 | After forced recovery, a restarted old leader keeps its unreplicated blocks, and other nodes can backfill them, splitting the zone from the settled chain | Found; stands as a missing guard and a runbook gap | `8d428ae3758d98a507f4e1de6c86ac40-67-0` | Follower canonical block matches the settled batch (9); No forks (14) |
| 3 | After forced recovery and `zone_setLeader`, the named leader started a follower generation and never led | Under investigation, one event | `8d428ae3758d98a507f4e1de6c86ac40-67-0` | Zone chain advances after faults stop |

Numbers in brackets are failure counts for the run.

Each failure was reviewed by a second pass whose brief was to attribute it to the test harness
rather than to Tempo. What is below is what survived; what did not is listed under
[Not findings](#not-findings).

Outside bugs 1 and 2 the quorum held. In run `06d7a6f2…`, with leader rotation and network
faults on every link, "No forks" passed 2.9k times with no failure and "Settlement validity"
2.4k times with no failure.

---

## 1. Role controller exits after a role change that cannot stop in 40 s

### What happens

When a node changes role it first stops the tasks of its current role. If they do not stop
within 40 s, the node refuses to start the next role, which is safe. It does so by ending the
role controller task. The process stays up, answers RPC and still reports its last role, but it
no longer leads or follows, and it does not recover when the network heals. If the portal names
that node leader, nobody produces blocks until someone restarts it.

### Evidence (run `06d7a6f20b71bce259a9be336de8bac0-67-0`)

Workload: deposits, transfers, withdrawals and operator leader rotation through
`zone_setLeader`. Faults: network faults on every link, including each zone node's link to L1.
No node was killed or paused.

"Role controller exits after an unproven generation teardown" failed 12 times, from two
separate events, both on `zone-0`.

Event at vtime 158.67 (input hash `5196924904726649597`), stopping a follower generation:

```text
115.92  INFO  zone::role: Follower generation started generation=2 epoch=2
118.56  INFO  Leadership transition on L1 ... new_leader=0x9965…A4dc epoch=3
118.67  INFO  zone::role: Promotion barrier satisfied epoch=3 next_anchor=205
143.74  ERROR alloy_transport_ws::native: WS server missed a pong        (repeats to 147.75)
158.67  WARN  zone::role: Generation did not stop within the timeout; aborting remaining tasks generation=2
158.67  ERROR zone::role: Role generation teardown was not proven safe generation=2 role="follower"
158.67  ERROR zone::role: Role controller exiting after an unproven generation teardown
```

Event at vtime 194.06 (input hash `-5461180171937633032`), stopping a leader generation: the
engine demotes at 154.05 and the same three lines follow at 194.06, exactly 40 s later. The L1
link was disrupted throughout (32 network faults in those 40 s).

Consequences on the timelines that continued from the second event:

- The process stayed up and was not restarted: it logged `latest_block=191` at 251, at 326 and
  later.
- With faults stopped from vtime 239, the recovery checks still failed: "A new batch settles
  within the deadline after faults stop" 13 times and "Zone nodes converge once faults stop" 14
  times. Every failed recovery check that was read has this exit earlier on its own timeline.
- At 419.15 the node still reported the role `leader` while producing nothing.

### Where in the code

- `GENERATION_STOP_TIMEOUT` (40 s) and `RunningGeneration::stop` in
  `crates/zones/node/src/role.rs`.
- `stop_current_generation` returns `false` after a failed teardown, and `run_role_controller`
  then returns. It is spawned with `spawn_critical_task` in `crates/zones/node/src/node.rs`; a
  task that returns without panicking does not stop the process.

Which task outlasted the 40 s was not established in this run. An earlier analysis on commit
`8cab4c21` pointed at two places that do not observe cancellation while waiting on L1: a batch
submission in progress (`crates/zones/sequencer/src/monitor.rs`) and a step of the follower
sync loop (`crates/zones/node/src/follower.rs`). That was not re-checked on `bc3c03b3`.

### Caveats

- The rotation driver rotates far more often than an operator would: five rotations in 57 s
  before the second event. That raises exposure. Each exit still needs only one role change
  plus about 40 s of a bad L1 link.
- Refusing to start a new role after an unproven teardown is deliberate. The finding is that
  the node then stays up looking healthy instead of exiting or retrying.
- No timeline restarted the node afterwards, so "a restart clears it" is expected but was not
  observed.

---

## 2. Forced recovery: a restarted old leader keeps its unreplicated blocks

### What happens

A leader persists a block before it replicates it. If it stops while holding blocks its
followers never received, and the operator then forces recovery onto a survivor, the old leader
restarts with the same directive, accepts it, and keeps its own blocks after the recovery
point. Two things follow:

- The old leader never rejoins the recovery leader's chain.
- Other nodes can import the old leader's blocks through backfill and end up on its chain too,
  while the recovery leader's chain is the one settled on L1.

### Evidence (run `8d428ae3758d98a507f4e1de6c86ac40-67-0`)

Workload: as above, plus an operator that follows the crashed-leader runbook in
`crates/zones/p2p/README.md`. Faults: node pause, throttle, stop and kill, partitions and clock
changes on the zone nodes; `l1` and the workload excluded.

What the operator does, in order: it sees the portal's leader not answering while both other
sequencers hold one unchanged tip; it stops the old leader's node and waits for its host to
confirm (without confirmation it does not proceed: it declined 15 times in this run); it writes
the `[forced_recovery]` directive, with which every node restarts, the old leader included; it
calls `zone_setLeader` once the recovery leader has extended the chain.

The failures in this run come from one underlying event, explored on many timelines: recovery
height 499, old leader `zone-0`. On input hash `1874939917987081153`:

| vtime | Event |
|---|---|
| 279.86–298.20 | `zone-0` (leader) builds blocks 500–537 while its followers are paused or partitioned. |
| 301.85 | A node-stop fault ends `zone-0` cleanly. |
| 300.66–344.01 | The survivors have imported up to block 499 only. |
| 359.04 | `zone-0`'s host confirms the operator's stop. The directive is written after this. |
| after restart | `zone-0`: `Installed manifest forced recovery ... resumed=true`; it keeps its 500–537. |
| 601.94 | `zone-2`: `Imported canonical peer block block_number=500 hash=0x4e71318b…`, which is `zone-0`'s old block 500. |

On input hash `3608665734426430614`, `zone-rpc` imports the same old block at 365.28, and at
368.01 Tempo's own assertion in `shadow_prover.rs` fails on it:

```text
FAIL Always "Follower canonical block matches the settled batch"
     zone_block 512, local_hash 0x6c5860…, settled_hash 0xe89e76…
```

Properties, with final counts for the run:

| Property | Failures | Note |
|---|---|---|
| Follower canonical block matches the settled batch (Tempo's assertion) | 9 | A node that was never leader holds a block that differs from the settled one. |
| No forks: zone nodes never hold different blocks at the same height | 14 | |
| Follower receives a block that conflicts with its canonical chain | 125 | Most are the old leader rejecting the new chain; the survivor cases are the ones that matter. |
| Leader settlement proposal matches the follower's state | 18 | 17 of 18 are on the old leader. |
| A restarted old leader holds blocks after the recovery point that the recovery leader did not produce | 32 hits | The operator's head comparison after the restart; the precondition, observed directly. |

### Where in the code

- `install_manifest_forced_recovery` (`crates/zones/node/src/node.rs`) and
  `canonical_recovery_height` (`crates/zones/node/src/role.rs`) accept the directive when the
  recovery hash is an ancestor in the node's own chain. Nothing checks whether the node holds
  blocks after it that the recovery leader did not produce. The log line is
  `Installed manifest forced recovery ... resumed=true`.
- `validate_live_block_sender` (`crates/zones/node/src/follower.rs`) returns `Ok` when a block
  has no live sender, so a backfilled block is not checked against the leader scheduled for its
  anchor. The README describes this for backfill in general; under forced recovery it lets the
  old leader's blocks reach other nodes.

### Reproduce locally

From this directory, after building the images as in [README.md](README.md):

- `./repro-forced-recovery-fork.sh`: the bare mechanism, with the directive written by hand.
- `./repro-runbook-operator.sh`: the same with the test operator, which stops the old leader
  and waits for confirmation before forcing recovery. In one run the old leader ended frozen at
  block 166 (`peer block parent mismatch at height 167`) while the other nodes passed 348, and
  the convergence check reported `converged=false`.

### How far this goes, and the counter-argument

Tempo can fairly call part of this operator error. The README says: "Restarting during recovery
assumes every participating node's descendants of `recovery_block_hash` belong to the same chain
produced by the selected, non-equivocating recovery leader." The test operator compares the old
leader's head only after restarting it.

Against that: the README asks operators to compare "the survivors' heads" and says nothing about
a crashed leader's data directory; "adds the same `[forced_recovery]` directive to every
manifest" reads as including the old leader; and the node accepts the mismatch silently.

So the claim is narrow: a stopped leader restarted with the directive and its old data keeps its
unreplicated blocks; surviving followers can backfill them; the node does not reject this and
the runbook does not say to wipe or resync the old leader.

### Questions

1. Is the old leader's data directory expected to be wiped or resynced before it rejoins after a
   forced recovery? If so, the runbook should say it.
2. Should the node enforce it, for example by refusing to start (or unwinding to the recovery
   block) when it holds blocks after the recovery block that the recovery leader did not produce?
3. Should backfill during a forced-recovery window reject blocks the recovery leader did not
   produce?

---

## 3. Under investigation: named leader starts following and never leads

One event in run `8d428ae3758d98a507f4e1de6c86ac40-67-0`, input hash `-4901740061769937608`.
After a forced recovery, `zone_setLeader` named the recovery leader `zone-2` (vtime 397.26). At
399.74 `zone-2` logged `Follower generation started generation=2 epoch=1` and did not lead
afterwards. Faults stopped at 406.54 and the head stayed at block 537 for the 180 s the
recovery check waited.

This may be a race between the forced-recovery window and the portal transition that ends it.
That is a guess; the cause was not established. It is listed so it can be looked at, not as a
confirmed bug.

---

## Not findings

Failures in the same runs that the review attributed to the test harness or left undetermined:

- **"Settlement validity: every batch settled on L1 matches the nodes' block" (10) and "A block a
  zone node served is never replaced" (33) in run `8d428ae3…`.** Checker artifacts: the first
  fired only on the old leader itself, and the second compares a node with a hash first seen on
  another node. Neither shows more than bug 2 does.
- **Stuck-zone failures in run `8d428ae3…`** ("Zone chain advances" 13, "A new batch settles" 23,
  "the portal's leader leads" 10, "Zone nodes converge" 18). Most follow from bug 2: two
  nodes on the old leader's chain reject settlement proposals, or the rotation driver later
  names the stuck old leader as leader. On one timeline the test platform ended the operator
  command 0.9 s after it wrote the directive. On another the zone nodes took about 200 s to
  start, cause undetermined.
- **The operator's last step, removing the completed directive, never ran** in run `8d428ae3…`:
  it waits until every answering sequencer has passed the transition, and the stuck old leader
  never does. No failure was traced to the leftover directive.
- **"The recovery leader extends the chain under forced recovery" was false 9 of 33 times.**
  Not investigated.

---

# Part 2: planted bugs

These are not defects in Tempo. Tempo's `antithesis-poc` branch (`18f2fc76`) pins Reth
`5d0dd5f6`, which carries three deliberate changes in `crates/trie`. The question is whether
the tests detect each one. The full write-up is `contrib/antithesis/FINDINGS-reth.md` on branch
`antithesis/adi-reth-planted-bugs`.

| # | Planted change | Detected? | Run | Property that caught it |
|---|---|---|---|---|
| P1 | Inline witness children (SIGP-334) | Yes, by realistic traffic through the zone prover | `6c31e497e76ccd1852459d3efe06d823-67-0` | Native prover accepts the sequencer witness (33) |
| | | Yes, with a mined-key accelerator; control on fixed Reth is clean (`13021985d1ad5c750b42fb9149f1f188-67-0`) | `0dca3443c205133a127cfe4549c7e192-67-0` | Native prover accepts the sequencer witness (22) |
| | | Yes, on the proof path, with Tempo's `reth-state-root` harness unchanged | `eba6d113a8fc0f9c9236188ab9702076-67-0` | eth_getMultiProof proofs verify against the model's state root (169) |
| P2 | Proof target bugs (reverts Reth #28085) | No | | |
| P3 | `node_iter` revert (reverts Reth #28264) | No | | |

## P1. Inline witness children (SIGP-334): detected

A witness or proof mishandles a trie node small
enough to be embedded in its parent.

- *Realistic traffic, no mined keys* (run `6c31e497e76ccd1852459d3efe06d823-67-0`, 60 min, faults off). A driver pays small
  amounts to cohorts of new random holders in batched transactions, twice each. At about 6,700
  holders two recipients' storage keys shared 8 leading nibbles, and the next batch failed
  `Native prover accepts the sequencer witness` with `incomplete storage proof` (33 failures over
  7 slots). First moment: input hash `8717736145821261756`, vtime 145.45. Three of the 7 slots
  were traced to such a pair; the other 4 were not checked.
- *Mined-key accelerator* (run `0dca3443c205133a127cfe4549c7e192-67-0`, 15 min). Same property, 22 failures. The same driver on
  fixed Reth (run `13021985d1ad5c750b42fb9149f1f188-67-0`) passed 93 times with no failure while reaching the same trie shape 32
  times.
- *Proof path* (run `eba6d113a8fc0f9c9236188ab9702076-67-0`, 15 min, Tempo's `reth-state-root` harness unchanged).
  `eth_getMultiProof proofs verify against the model's state root` failed 169 times; in each, an
  embedded leaf was returned as its own proof node. That harness shapes keys at run time, which
  is an accelerator rather than realistic traffic.

## P2 and P3. Proof target bugs and the `node_iter` revert: not detected

Every existing root and prover
check passed on the planted pin, including three per-block model-against-node checks added to
`reth-state-root` for this purpose. From reading the code, not from a run: the `node_iter` change
should give a wrong incremental state root, but only for a trie shape (three nested stored
branches under an extension) that neither harness produced; no definite symptom was derived for
the proof target change.

Limits of this part: the runs show the symptom on the planted pin and its absence on fixed Reth
but do not bisect Reth; there is no fixed-Reth control for the realistic workload itself; and
this part did not get the second-pass review that Part 1 did.

---

# Harness (Part 1)

## Topology

`docker-compose.yaml` in this directory. Every binary is built with Antithesis coverage
instrumentation and the `fuzz` feature, which enables the in-node assertions.

| Container | Role | Faults |
|---|---|---|
| `l1` | Tempo dev node, 500 ms blocks, finality depth 1. A dependency: the zone reads from it and settles to it. | Never killed or paused. Its network links are faulted in run `06d7a6f2…` only. |
| `zone-0`, `zone-1`, `zone-2` | The sequencers. One leads; settlement needs 2 of 3 signatures. Batch every 20 blocks. | Under test. |
| `zone-rpc` | Follower outside the quorum; re-proves every settled batch with the native prover and runs the solvency checker. | Under test. |
| `workload` | Runs the test commands; keeps a ledger of confirmed operations. | Excluded in run `8d428ae3…`. |
| `provision` | One-shot: creates the zone on L1, writes genesis, keys and the manifest. | |

Each zone container runs `scripts/zone-node.sh`, a small supervisor standing in for a process
manager: it restarts a node that exits by itself (the compose file sets no restart policy),
applies the operator's forced-recovery directive from the `control` volume, and stops the node
on the operator's request, confirming through the `acks` volume.

## Test commands

Two templates under `test/v1/`. Each command is a `tempo-zone-xtask antithesis` subcommand
(`xtask/src/zones/antithesis/`). Antithesis decides when each runs.

| Command | Template | What it does |
|---|---|---|
| `first_seed` | both | Funds the first zone accounts. |
| `parallel_driver_deposit`, `_transfer`, `_withdraw` | both | Traffic between L1 and the zone, to new and existing accounts; each operation is recorded once its receipt confirms it. |
| `parallel_driver_rotate_leader` | both | Operator: `zone_setLeader` to a random sequencer through a random sequencer, sometimes two or three requests back to back. |
| `parallel_driver_force_recovery` | `zone_recovery` | Operator: the crashed-leader runbook, described in [bug 2](#2-forced-recovery-a-restarted-old-leader-keeps-its-unreplicated-blocks). |
| `anytime_safety` | both | While faults run: no two nodes differ at a height; every batch settled on L1 matches the nodes; a node's head never falls below a settled height. Reads every new block from every reachable node. |
| `eventually_recovery` | both | After faults stop: every node answers, the chain advances and a batch settles within 180 s, the portal's leader leads and the others follow, nodes converge, confirmed deposits and withdrawals have landed. |
| `finally_backing` | both | At the end: the portal's escrow covers zone supply and pending flows. |

Test commands act only through RPC, the portal contract and the operator files above. They do
not cut links, change clocks or signal other containers; those faults come from Antithesis.

## Assertions added inside the node

Behind the existing `fuzz` feature, in `crates/zones/node/src/role.rs` and `follower.rs`. They
add no behaviour.

| Assertion | Kind |
|---|---|
| Role controller exits after an unproven generation teardown | must never happen |
| Role generation task panics | must never happen |
| Leader engine fences on an ungoverned anchor | must never happen |
| Follower receives a block that conflicts with its canonical chain | must never happen |
| Leader settlement proposal matches the follower's state | must always hold |
| Node promoted or demoted after its first role generation; leader engine demotes at the activation boundary; follower rejects a settlement proposal; role generation restarts after a task ends | coverage signals |

Tempo's own assertions in the node ("Follower canonical block matches the settled batch",
"Native prover accepts the sequencer witness", the solvency checks) are used unchanged.

## Runs

| Run | Template | Faults | Length, tier |
|---|---|---|---|
| `06d7a6f20b71bce259a9be336de8bac0-67-0` | `zone_dist` | `basic_test` default: network faults on every container, including zone-to-L1 links; no node faults | 30 min, turbo (100.3 compute hours) |
| `8d428ae3758d98a507f4e1de6c86ac40-67-0` | `zone_recovery` | `high_availability` (node pause, throttle, stop, kill; partitions; clock), with `l1`, `workload` and `provision` excluded | 30 min, turbo |

Both were launched with `--filter-logs-matching ' INFO reth_node_events::node'` to drop per-block
log lines. Build and launch commands are in [README.md](README.md).

## What the harness makes easier than production

- Leader rotation is far more frequent than an operator would do it.
- The forced-recovery operator acts after 5 s of leader silence and acts through files where a
  person would use a shell on each host.
- Batches settle every 20 blocks; the L1 is a single dev-mode node.
- The native in-process prover stands in for the remote one.

---

# Limits

- About 13 timelines of run `8d428ae3…` were read in the review, not all of them.
- Bug 2 rests on one underlying event in that run plus the local reproductions.
- The Rust changes on this branch are not formatted with `cargo +nightly fmt`.
