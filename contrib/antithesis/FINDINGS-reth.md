# Planted Reth trie bugs: Antithesis findings

All runs below are on Tempo's Antithesis tenant, source `antithesis-adi-reth-trie`, standard tier.

## What is under test

- tempoxyz/tempo `antithesis-poc` @ 18f2fc76 pins Reth at 5d0dd5f6a88f, the head of
  paradigmxyz/reth `antithesis-poc`. 5d0dd5f6 is a Reth rev, not a Tempo commit.
- Diffed against Reth main, `crates/trie` at that rev still carries the three planted changes, and
  the planted files are byte-identical to the planting commits:

| Planted change | Reth commit | Files | What it does |
|---|---|---|---|
| Inline witness children (SIGP-334) | 495d5a4de | `common/src/proofs.rs` | `from_witness` does not follow children embedded in their parent; `encode_v2_proof_nodes` emits embedded children as separate proof nodes |
| Proof target bugs | 357720a63 (reverts #28085) | `trie/src/proof_v2/{calculator,target}.rs` | proof targets grouped by revealed parent instead of by child |
| node_iter revert | 50b10de93 (reverts #28264) | `trie/src/node_iter.rs` | the legacy `StateRoot` skips a hashed-leaf seek when the walker lands on a deeper stored branch |

## Runs

| Run | Harness | Faults | Length | Result |
|---|---|---|---|---|
| eba6d113a8fc0f9c9236188ab9702076-67-0 | `reth-state-root`, unchanged | legacy | 15m | inline children found (proof path) |
| ca2c7e59eda31a275bba010631b7dfc0-67-0 | `zones`, template unchanged | HA | 15m | prover 0 counterexamples; about 1,000 accounts |
| 6dd6513263ef1396592f143162476973-67-0 | `zones` + payroll driver | HA | 60m | prover 0 counterexamples; at most 20,544 payroll holders, deepest shared prefix 7 nibbles |
| 6c31e497e76ccd1852459d3efe06d823-67-0 | `zones` + payroll driver offered three times, larger cohorts | none | 60m | **SIGP-334 found by realistic traffic**: prover 33 counterexamples |
| 0dca3443c205133a127cfe4549c7e192-67-0 | `zones` + deep-key driver (ACCELERATOR) | HA | 15m | SIGP-334 found: prover 22 counterexamples |
| 13021985d1ad5c750b42fb9149f1f188-67-0 | CONTROL: main c10420bb (fixed Reth 46744935) + deep-key driver | HA | 15m | prover 93 passes, 0 failures; the deep shape was hit 32 times |
| 8a8473492985383c1b43a637464ed7ea-67-0 | `reth-state-root` + model checks | legacy | 15m | new checks pass, 0 failures |
| d0d2623c9dc174b752a20fa00837fc89-67-0 | same image as 8a847349 | legacy | 30m | new checks pass (3.3k examples each), 0 failures |

## Found

### SIGP-334 through the zone prover, by realistic traffic (no mined keys)

- Run 6c31e497e76ccd1852459d3efe06d823-67-0. Property
  `Native prover accepts the sequencer witness`: 33 counterexamples, all
  `incomplete storage proof for 0x20c0000000000000000000000000000000000000 at <slot>`, over 7
  distinct slots. `Prover output matches the sequencer batch` has no counterexample.
- One moment: input hash 8717736145821261756, vtime 145.449, container `zone-rpc`, batch 243 to
  245, slot 1099411184...8338457.
- What led to it, from that timeline's log and the cohort seeds the workload printed
  (`contrib/antithesis/adi-planted/check_payroll_slot.py` rebuilds the recipients):
  - vtime 126.95: cohort 7433089142092401933 (160 new holders) gets its first dust payment.
    Recipient 132 of that cohort owns the failing slot.
  - vtime 143.29: cohort 6455114737929161631 (1,344 new holders) gets its first payment. Its
    recipient 1273 has a balance-slot key that shares exactly 8 nibbles with recipient 132's
    (`fcc2255c13...` and `fcc2255c97...`). The workload reported 6,688 holders at that point.
  - vtime 145.18: the first cohort gets its second payment.
  - vtime 145.45: the prover rejects the batch.
- Two more of the 7 slots were checked the same way (moments 7831090782051532414 at vtime 203.451
  and -2214951122831150704 at vtime 243.020): each belongs to a payroll recipient whose key
  shares exactly 8 nibbles with another recipient's. The other 4 were not checked.
- No control on fixed Reth exists for this exact workload. The control below covers the same
  detector and the same trie shape.
- Traffic: `parallel_driver_payroll` pays 1 to 60 base units (one in eight up to 10,000) to
  cohorts of brand-new holders, as 32-call Tempo transactions, and pays each cohort again at least
  15 seconds later. Recipients come from a fresh Antithesis-random seed per cohort. Nothing
  searches hashes. The run reached more than 127,000 holders in its largest timeline.
- The first attempt (6dd65132: one payroll driver, HA faults, smaller cohorts) reached 20,544
  holders and 7 nibbles and found nothing. The second attempt offered the driver three times,
  tripled the cohort size and turned faults off.

### SIGP-334 through the zone prover, by the mined-key accelerator

- Run 0dca3443c205133a127cfe4549c7e192-67-0. Same property: 22 counterexamples, all
  `incomplete storage proof` for pathUSD. Every failing slot is the balance slot of a menu holder
  whose group shares 8, 9 or 10 nibbles.
- One moment: input hash 802844530603235283, vtime 116.516, container `zone-rpc`, batch 171 to
  173. At vtime 111.754 the workload logged
  `deep: 38 ... -> 0x...3dEAcD (depth 8, balance 38, siblings [84])`.
- ACCELERATOR: `parallel_driver_deep` credits holders from a menu mined offline. It shows the
  detector fires on this pin; it is not a search.
- Control on fixed Reth, same driver and settings: run 13021985d1ad5c750b42fb9149f1f188-67-0,
  `Native prover accepts the sequencer witness` 93 passes and 0 failures, while
  `Accelerator: transfer credits a mined holder while it and a sibling sharing >= 8 nibbles both
  hold small balances` was hit 32 times.

### Inline children on the proof path: Tempo's own `reth-state-root` harness, unchanged

- Run eba6d113a8fc0f9c9236188ab9702076-67-0. Property
  `eth_getMultiProof proofs verify against the model's state root`: 169 counterexamples, 13,699
  passes.
- One moment: input hash 346388977776832735, vtime 16.162. Details: block 1, account
  0x6E626F72...000B, `ValueMismatch { got: Some(0xdd9b36...5f), expected: Some(0x5f) }`.
- All 169 have that shape: "got" is a node of at most 31 bytes that ends in the expected value,
  i.e. an embedded leaf returned as its own proof node.
- Same run, Sometimes `Witness decodes an inline storage leaf`: 0 of 14k, although
  `A storage trie has an embedded leaf` passed.
- Control on fixed Reth: Tempo's run on main, 220ca0582ba16f971f58255c95cc2052-67-0, has the proof
  property at 12k passes and 0 failures and the Sometimes at 165 hits.
- The harness grinds key preimages into deep shapes at run time (its "collider"): a generic shape
  accelerator, not realistic traffic.

## Not found

- Proof target bugs (357720a63) and the node_iter revert (50b10de93). No run shows either.
- Existing checks that pass in every run: the `reth-state-root` root checks
  (`block {number}: expected {}, actual {}`, `overlay root at ...`, `persisted root at ...`,
  `persisted trie nodes at ...`) and, in zones, `Prover output matches the sequencer batch`.
- Checks added here, once per block, model against node (`check_parent_view` in
  `reth-state-root/src/engine.rs`):
  - `incremental root at block {number}: expected {}, actual {}`: the root of the block's state
    change over the parent overlay, the call a node without the state root task makes.
  - `execution witness of block {number}'s state change: {}`: the witness is produced.
  - `execution witness of block {number} lacks {} pre-state proof nodes of written keys`.
  They passed in runs 8a847349 and d0d2623c (45 minutes together). They have not been run on fixed
  Reth, which matters only once one of them fails.

## What the runs show, and what is inferred

Shown by runs: everything under "Found", and the pass counts above.

Inferred from reading code, not shown by a run:

- The failing proofs are caused by the planted commit 495d5a4de. The runs show the symptom on the
  planted pin and its absence on fixed Reth; they do not bisect Reth.
- `Proofs rebuilt from the execution witness verify...` in `reth-state-root` cannot catch the
  `from_witness` half of the inline bug: an embedded leaf is inside its parent's bytes either way.
- node_iter: the expected symptom is a wrong root from the legacy incremental `StateRoot` when a
  new leaf lands under a prefix whose next stored branch is deeper, right after an unchanged
  sibling. Zone nodes log `State root job finished strategy="synchronous"`, so they take that
  path for every block. The harness's `overlay root` check passes an empty post state and so never
  iterates leaves; the added incremental-root check does. The shape needs three nested stored
  branches under an extension, which neither harness produced.
- Proof targets: no definite symptom derived. The change only matters when one proof request has
  two targets on different children of the same revealed parent. The harness's witness check
  writes back the values it read, so it makes no such request; the added block-witness check does.

## Other observations (not attributed to the planted bugs)

- Run 6dd65132: `Zone nodes converge once faults stop` has 8 counterexamples, all one incident
  near vtime 1028 (input hash -1563194305256431124): `zone-1` stayed at block 804 while the other
  nodes reached 1332. Its log shows no error after it imported block 804, only
  `Transaction forwarding was not admitted for any quorum peer` and `connected_peers=0`.
  Not root-caused. `zone_payments/finally_ledger` failed once in the same run.
- Zone and L1 containers exit with code 1 under HA faults in every faulted zones run; the sampled
  errors are L1 connection failures.

## Reproduce

- Images are built from this branch with the stock Dockerfiles. `contrib/antithesis/adi-planted/`
  holds `stage.sh` (config directories) and `Dockerfile.workload` (workload variants: the zones
  variants share one binary and differ only in which extra parallel drivers the `zone_payments`
  template offers).
- The control image is main c10420bb with this branch's harness commits cherry-picked.
