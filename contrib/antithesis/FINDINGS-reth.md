# Planted Reth trie bugs: Antithesis findings (Tempo tenant only)

Status: INTERIM. Two runs were still in progress when this was written; see "Open".

## What is under test
- tempoxyz/tempo `antithesis-poc` @ 18f2fc76 pins Reth at 5d0dd5f6a88f (head of paradigmxyz/reth
  `antithesis-poc`). 5d0dd5f6 is a Reth rev, not a Tempo commit.
- Against Reth main, `crates/trie` at that rev still differs in: `common/src/proofs.rs` (inline
  children: `from_witness` does not follow them, `encode_v2_proof_nodes` emits them as separate
  proof nodes), `trie/src/proof_v2/{calculator,target}.rs` (proof target bugs),
  `trie/src/node_iter.rs` (revert of #28264). The three planted files are byte-identical to the
  planting commits (495d5a4de, 357720a63, 50b10de93).

## Runs (source `antithesis-adi-reth-trie`)
| Run | Harness | Length | Result |
|---|---|---|---|
| eba6d113a8fc0f9c9236188ab9702076-67-0 | `reth-state-root`, unchanged | 15m | inline-children bug found |
| ca2c7e59eda31a275bba010631b7dfc0-67-0 | `zones`, template unchanged | 15m | prover detector live, 0 counterexamples |
| 6dd6513263ef1396592f143162476973-67-0 | `zones` + `parallel_driver_payroll` (no mined keys) | 60m | in progress |
| 0dca3443c205133a127cfe4549c7e192-67-0 | `zones` + `parallel_driver_deep` (ACCELERATOR, mined keys) | 15m | in progress |

## Found: inline witness children (commit 495d5a4de), by Tempo's own reth-state-root harness
- Property `eth_getMultiProof proofs verify against the model's state root`: 169 counterexamples,
  13,699 passes. Moment: input hash 346388977776832735, vtime 16.162. Details: block 1, account
  0x6E626F72...000B `does not verify: ValueMismatch { got: Some(0xdd9b36...5f), expected: Some(0x5f) }`.
  In all 169 the "got" value is a node of at most 31 bytes ending in the expected value: an
  embedded leaf returned as its own proof node.
- Property `Witness decodes an inline storage leaf` (Sometimes): 0 of 14k on this pin, while
  `A storage trie has an embedded leaf` passed. Tempo's own run on main (fixed Reth),
  220ca0582ba16f971f58255c95cc2052-67-0, has it at 165 hits and the proof property at 12k/0.
- The harness grinds key preimages into deep shapes at run time (its "collider"): a generic
  shape accelerator, not realistic traffic.
- Inference: `Proofs rebuilt from the execution witness verify...` cannot catch the
  `from_witness` half, because an embedded leaf is inside its parent's bytes either way.

## Not found so far
- Proof target bugs (357720a63) and the node_iter revert (50b10de93): every root check in the
  reth-state-root run passed, and the zones as-is run had no prover or consistency counterexample.

## Open
- Read out runs 6dd65132 and 0dca3443 (`Native prover accepts the sequencer witness`).
- No run has yet shown the proof target or node_iter bugs.
