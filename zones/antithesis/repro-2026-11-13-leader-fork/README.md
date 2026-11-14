# Reproducing the 2026-11-13 leader-fork finding

The scripts drive the zones Docker harness from Alexey's quorum-handoff configuration
(`tempoxyz/tempo@8314f7ba`, `contrib/antithesis/zones`). Paths inside the scripts point at the
worktree they were developed in (`~/src/wt/hunt`); edit `Z=` and the `cd` lines for your checkout.

- `n2-gdb-repro.sh up` builds the stack (compose project `n2repro`, `ZONES_IMAGE`).
- `n2-gdb-hold.sh` is the deterministic fork, gdb only. It runs in about 75 s once the stack is up.
- `n2-impact.sh up` runs on an image built from unmodified product code. It forks the leader, sends a
  transfer to the leader, and after 5 minutes compares tips, receipts and L1 settlement batches.
- `harness-8314f7ba.patch` contains the test-only harness used for the Antithesis run, applied to
  `8314f7ba`. It never touches `crates/`. It adds:
  - the lagging-backfill/drain crash driver (`xtask/zones-antithesis/src/lagging.rs`);
  - the cross-node fork check in `checks.rs` ("Zone nodes never hold different blocks at the same height");
  - the slow-MDBX-commit `LD_PRELOAD` shim (`contrib/antithesis/zones/shim/slowsync.c`).
- `evidence/` holds the Antithesis failed assertion and timeline for run
  `1b900239d3de50bcf4a2b9e2cbc8ed1a-67-0`, plus the logs of the local runs on unmodified product code.
- `n4-finalized-loss.sh` reproduces finding 2 on unmodified product code. It pauses the leader's
  commit with gdb, gets a success receipt for a transfer in a block the leader reports as
  `finalized`, kills the leader, and shows the transfer has gone from every node.
- `n2b-settlement.sh [up]` reproduces finding 1's worst case on unmodified code. It holds the leader's
  commit on a settlement-boundary block, lets L1 accept the batch, and kills the leader. The leader
  then can never start again ("failed to resolve portal-confirmed Zone height for leader recovery").
- `n4-double-spend.sh` turns finding 2 into a double spend on unmodified code. A payment
  reported as finalized vanishes after a leader crash, and the same funds are then spent to
  someone else and settled on L1.

Before you run them:
- Only one zones stack can run per Docker host (fixed container names and IPs). Run
  `docker compose -p <project> down -v` on any running stack first.
- The scripts write scratch files to `R=` (the author's `~/hunt-logs/repro`). Point `R=` at a
  writable directory that holds these scripts.
- They assume zone-0 is the leader, which holds on a fresh stack.
- `n2-gdb-repro.sh up` uses the `:hunt` image tags. For unmodified product code, set
  `ZONES_IMAGE`/`WORKLOAD_IMAGE` to images built from `8314f7ba`, as `n2-impact.sh` and
  `n4-*.sh` do.
- `cast receipt` waits for a receipt, so it never returns on a node that lacks the transaction. Use
  `cast rpc eth_getTransactionReceipt`.
- The images ship the slow-disk library from the Antithesis harness, inert at 0 ms. The gdb scripts
  do not use it.
- `keys/testA.sh` (with `keys/common.sh`) shows a key revocation reported as finalized being undone
  by a leader crash on unmodified code; the revoked key then signs a transfer and authenticates to
  the private RPC. It expects a running stack and `/tmp/keys.env` with "VPK V KPK K"; see the
  script header.
