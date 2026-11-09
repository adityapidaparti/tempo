#!/bin/sh
# Runs one zone node from the files provision.sh wrote: "0", "1" or "2" for a quorum
# sequencer, "rpc" for the RPC follower that runs the native prover and the checker.
# Restarts reuse the same datadir.
set -eu

S=/shared
NODE=$1
L1_WS=ws://10.20.0.10:8546

case "$NODE" in
    0)
        ROLE_ARGS="--secp256k1.key $S/seq-0.key --sequencer-key-file $S/seq-0.key"
        P2P_KEY=$S/p2p-0.key
        ;;
    1 | 2)
        ROLE_ARGS="--secp256k1.key $S/seq-$NODE.key --sequencer-key-file $S/seq-$NODE.key --deposit-decryption-keys-file $S/decryption.keys"
        P2P_KEY=$S/p2p-$NODE.key
        ;;
    rpc)
        # Without --sequencer.prover-address the shadow prover runs the native prover in-process.
        ROLE_ARGS="--sequencer.enable-prover --checker.mode observe"
        P2P_KEY=$S/p2p-rpc.key
        ;;
    *)
        echo "zone-node: unknown node $NODE" >&2
        exit 1
        ;;
esac

# The manifest the node runs with is the provisioned one plus the operator's forced-recovery
# directive, if the workload wrote one to /control/recovery.toml. When that file changes, the
# node restarts with the new manifest, as in the operator's coordinated restart.
RECOVERY=/control/recovery.toml
MANIFEST=/data/manifest.toml
recovery_stamp() {
    cksum "$RECOVERY" 2>/dev/null || echo none
}
write_manifest() {
    cp "$S/manifest.toml" "$MANIFEST.tmp"
    if [ -s "$RECOVERY" ]; then
        printf '\n' >> "$MANIFEST.tmp"
        cat "$RECOVERY" >> "$MANIFEST.tmp"
    fi
    mv "$MANIFEST.tmp" "$MANIFEST"
}

CHILD=
trap '[ -n "$CHILD" ] && kill -TERM "$CHILD" 2>/dev/null' TERM INT

while :; do
    STAMP=$(recovery_stamp)
    write_manifest
    # shellcheck disable=SC2086
    /usr/local/bin/tempo-zone node \
        --chain "$S/genesis.json" \
        --l1.rpc-url "$L1_WS" \
        --datadir /data/node \
        --http --http.addr 0.0.0.0 --http.port 8545 --http.api all \
        --ws --ws.addr 0.0.0.0 --ws.port 8546 --ws.api all \
        --redacted-rpc.port 8544 \
        --sequencer.manifest "$MANIFEST" \
        --p2p.key "$P2P_KEY" \
        --p2p.listen 0.0.0.0:9200 \
        --zone.batch-interval-blocks 20 \
        --disable-discovery \
        --ipcdisable \
        --color never \
        $ROLE_ARGS &
    CHILD=$!
    while kill -0 "$CHILD" 2>/dev/null; do
        sleep 1
        if [ "$(recovery_stamp)" != "$STAMP" ]; then
            echo "zone-node: forced-recovery directive changed; restarting the node"
            kill -TERM "$CHILD" 2>/dev/null || true
            wait "$CHILD" || true
            continue 2
        fi
    done
    # The node exited on its own or on a signal: exit with its status.
    set +e
    wait "$CHILD"
    exit $?
done
