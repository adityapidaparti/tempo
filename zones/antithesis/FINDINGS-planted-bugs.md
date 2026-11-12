# Planted Reth trie bugs: what the tests detected

Runs by Antithesis on the `tempo` tenant, tagged `antithesis-adi`.

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
these results did not get the second-pass review that the quorum findings in [FINDINGS.md](FINDINGS.md) did.

---

## Harnesses used

These runs do not use the quorum harness of [FINDINGS.md](FINDINGS.md). They are built from
Tempo's `antithesis-poc` branch, on branch `antithesis/adi-reth-planted-bugs`:

| Run | Harness | Faults | Length |
|---|---|---|---|
| `6c31e497e76ccd1852459d3efe06d823-67-0` | Tempo's zones harness (`zone_payments` template) plus one added driver, `parallel_driver_payroll`, offered three times | none | 60 min |
| `0dca3443c205133a127cfe4549c7e192-67-0` | Tempo's zones harness plus an added deep-key driver (accelerator) | node and network faults | 15 min |
| `13021985d1ad5c750b42fb9149f1f188-67-0` | Control: the same as the row above, on `main` with fixed Reth | node and network faults | 15 min |
| `eba6d113a8fc0f9c9236188ab9702076-67-0` | Tempo's `contrib/antithesis/reth-state-root` harness, unchanged | network faults | 15 min |

Node code is unchanged in all of them. The full write-up, including the runs that found nothing,
is `contrib/antithesis/FINDINGS-reth.md` on that branch.
