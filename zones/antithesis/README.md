# Zone test environment

A multi-sequencer zone in Docker Compose, for fault-injection testing of the L1 and zone nodes built with
`--features fuzz` (SDK assertions enabled). `docker-compose.yaml` describes the topology.

The Dockerfile builds every binary with Antithesis [coverage instrumentation](https://antithesis.com/docs/reference/sdk/rust/instrumentation/)
(`--features antithesis-coverage` and its sancov `RUSTFLAGS`, in the `antithesis` profile: no LTO, one codegen unit)
and links them into `/symbols`. Coverage guides the exploration, and Antithesis only pauses threads in
instrumented processes. Outside Antithesis the shim finds no `libvoidstar` and does nothing.

Build the images from the repository root, with the contract submodules checked out:

```bash
docker build -f zones/antithesis/Dockerfile -t tempo-zones-antithesis:latest \
    --build-arg VERGEN_GIT_SHA="$(git rev-parse HEAD)" .
docker build -f zones/antithesis/Dockerfile --target workload -t tempo-zones-antithesis-workload:latest \
    --build-arg VERGEN_GIT_SHA="$(git rev-parse HEAD)" .
docker build -f zones/antithesis/Dockerfile.config -t tempo-zones-antithesis-config:latest zones/antithesis
```

Run it locally:

```bash
docker compose -f zones/antithesis/docker-compose.yaml up
```

`ZONES_IMAGE` overrides the image the L1, provisioner and zone nodes run, and `WORKLOAD_IMAGE` the
`workload` container's.

## Antithesis registry

[`antithesis-zones.yml`](../../.github/workflows/antithesis-zones.yml) builds the node, workload and config images on every push to `main`
that touches the node or this directory, and on a manual dispatch of any branch, and pushes them to
`us-central1-docker.pkg.dev/molten-verve-216720/tempo-repository` as `<branch>-<sha>` and `<branch>`. The
config image adds an `.env` that pins `ZONES_IMAGE` and `WORKLOAD_IMAGE` to the digests just built. It needs the registry's JSON
key in the `ANTITHESIS_REGISTRY_KEY` repository secret.

## Test template

`test/v1/zone_payments` ships at `/opt/antithesis/test/v1` in the workload image only (the Dockerfile's
`workload` target), so only the `workload` container offers it. The test platform finds templates in the
images it is given, so they must be in the image rather than copied in when a container starts. Each command is a `tempo-zone-xtask antithesis` subcommand:

| Command | What it does |
|---|---|
| `first_seed` | Approves the portal for the L1 funders and funds the first zone accounts |
| `parallel_driver_deposit` | Deposits from a funder or a new L1 account to a new or existing zone account |
| `parallel_driver_transfer` | TIP-20 transfer inside the zone to a new or existing account |
| `parallel_driver_withdraw` | Withdraws to a new or existing L1 address |
| `parallel_driver_fanout` | Funds 5 to 20 new zone accounts from one sender |
| `anytime_consistency` | Nodes that reached the height L1 settled agree on its hash and on balances there, and settled workload transactions stay final |
| `eventually_settled` | After faults stop, every confirmed deposit is credited and every confirmed withdrawal is paid, and all nodes converge |
| `finally_ledger` | The same, then every workload account's zone balance equals what the zone's Transfer logs add up to |

Half of all recipients are accounts nobody has used before, so the L1 and zone state tries keep
growing during a run. Account keys are hashes of their index, counting from 1000, and are
recorded in an append-only ledger in `/state`, which also holds a lock file per account so
only one command sends from an account at a time. Drivers record a deposit, withdrawal or
transfer only once its receipt confirms it; the checks compare those records with both chains.

Run a command against the local stack the way the platform does:

```bash
docker compose -f zones/antithesis/docker-compose.yaml exec workload \
    /opt/antithesis/test/v1/zone_payments/first_seed
```

## `zone_dist` template

A small distributed-systems template for the sequencer quorum, and the only one the workload
image ships on this branch. Drivers are `seed`, `deposit`, `transfer` (a quarter of transfers
drain the sender), `withdraw`, plus `rotate-leader`: half the time, after a random delay, a
random sequencer is asked over `zone_setLeader` to hand leadership to a random registered
sequencer, as an operator would. Checks:

| Command | Property |
|---|---|
| `anytime_safety` (`check-safety`) | S1 nodes never hold different blocks at one height (now, or versus the first hash seen); S2 a settled block never disappears from a node that passed it, and no node's head falls back below a settled height; S3 every newly settled batch matches the block of every node that passed it |
| `eventually_recovery` (`check-recovery`) | every node answers within 180 s; the chain advances and a new batch settles within 180 s (normal: one batch of 20 blocks every ~10 s locally, so 18x); then `check-settled` (convergence, deposits credited, withdrawals paid) |
| `finally_backing` (`check-backing`) | `verify-portal-backing`: portal escrow covers zone supply plus pending flows |

On the `quorum-local` branch the template also covers the sequencer quorum more closely:

- `check-safety` reads every block a node added since the last run (not a sample) and asserts
  two properties separately: nodes never hold different blocks at one height, and a block a node
  served is never replaced. It also reads each node's role from `zone_getSequencerInfo` for
  coverage signals (two leaders at once, no leader, a fenced node, every sequencer has led, a
  batch settling while a sequencer is unreachable).
- `rotate-leader` sends two or three `zone_setLeader` requests back to back through different
  sequencers in a quarter of its runs.
- `check-recovery` also asserts that the portal's leader reports the leader role and every
  other node follows.
- The node carries assertions (feature `fuzz`) in `role.rs` and `follower.rs`: the role
  controller exiting after an unproven teardown, a role task panicking, the leader engine
  fencing, a follower receiving a block that conflicts with its chain, and a leader's settlement
  proposal differing from the follower's state.

Launch (HA faults, `l1` and `workload` excluded from faults):

```bash
SNOUTY_UNSTABLE_FEATURES=teams snouty launch --launcher basic_test --config zones/antithesis \
    --max-compute-hours 36 --fault-tolerance high_availability \
    --fault-exclusions '^(workload|l1|provision)$' \
    --filter-logs-matching ' INFO reth_node_events::node'
```

`check-safety` keeps L1 settlements, sampled block hashes and per-node state in
`/state/dist.json`, and skips unreachable nodes and RPC errors.

Exclude `l1` from container stop/kill faults (`custom.container_status_fault_exclusions=workload,l1`):
the dev-mode L1 loses its unpersisted tip when killed and re-mines different blocks at those
heights, which the zone nodes had already taken as final, so the zone halts for good. Real Tempo
finality cannot do that, so it would only produce false recovery failures.
