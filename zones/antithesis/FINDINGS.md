# Findings: zone sequencer quorum under faults

Runs by Antithesis on the `tempo` tenant, tagged `antithesis-adi`. Base: `main` at `bc3c03b3` plus
the test harness on this branch (see [README.md](README.md)). Three sequencers with 2-of-3
settlement, one RPC follower running the native prover, one dev-mode Tempo L1.

| # | Finding | Status | Run ID |
|---|---|---|---|
| 1 | A role change that overlaps about 40 s of L1-link disruption ends the node's role controller for good; the zone halts if that node is the next leader | Stands | `06d7a6f20b71bce259a9be336de8bac0-67-0` |
| 2 | After forced recovery, a restarted old leader keeps its unreplicated blocks, and other nodes can backfill them, splitting the zone from the settled chain | Stands as a missing guard and a runbook gap | `8d428ae3758d98a507f4e1de6c86ac40-67-0` |
| 3 | After forced recovery and `zone_setLeader`, the named leader started a follower generation and never led | Under investigation, one event | `8d428ae3758d98a507f4e1de6c86ac40-67-0` |

Each failure was reviewed by a second pass whose brief was to attribute it to the test harness
rather than to Tempo. What is below is what survived; what did not is listed under
[Not findings](#not-findings).

Outside these two situations the quorum held. In run `06d7a6f2…`, with leader rotation and
network faults on every link, "No forks" passed 2.9k times with no failure and "Settlement
validity" 2.4k times with no failure.

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
  another node. Neither shows more than section 2 does.
- **Stuck-zone failures in run `8d428ae3…`** ("Zone chain advances" 13, "A new batch settles" 23,
  "the portal's leader leads" 10, "Zone nodes converge" 18). Most follow from section 2: two
  nodes on the old leader's chain reject settlement proposals, or the rotation driver later
  names the stuck old leader as leader. On one timeline the test platform ended the operator
  command 0.9 s after it wrote the directive. On another the zone nodes took about 200 s to
  start, cause undetermined.
- **The operator's last step, removing the completed directive, never ran** in run `8d428ae3…`:
  it waits until every answering sequencer has passed the transition, and the stuck old leader
  never does. No failure was traced to the leftover directive.
- **"The recovery leader extends the chain under forced recovery" was false 9 of 33 times.**
  Not investigated.

## Limits

- About 13 timelines of run `8d428ae3…` were read in the review, not all of them.
- Section 2 rests on one underlying event in that run plus the local reproductions.
- The Rust changes on this branch are not formatted with `cargo +nightly fmt`.
