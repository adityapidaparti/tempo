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

# The operator can stop this node and keep it stopped, as with `systemctl stop` on its host: while
# /control/stop-zone-<node> exists the node is not running, and the supervisor copies that file to
# /acks/zone-<node> so the operator knows the stop took effect.
FENCE=/control/stop-zone-$NODE
ACK=/acks/zone-$NODE

# A minimal supervisor, standing in for the process supervisor a production node runs under:
# when the node process exits by itself, the exit is logged with its code and the node is
# started again on the same datadir. On SIGTERM or SIGINT the signal is passed to the node and
# the container exits with the node's status.
CHILD=
STOPPING=
# The node may already be gone when the signal arrives (it exited by itself and the supervisor
# is pausing before the restart): a failed kill must not end the script through set -e.
trap 'STOPPING=1; if [ -n "$CHILD" ]; then kill -TERM "$CHILD" 2>/dev/null || true; fi' TERM INT

while :; do
    if [ -n "$STOPPING" ]; then
        echo "zone-node supervisor: stop signal while the node was not running, exiting"
        exit 0
    fi
    while [ -e "$FENCE" ] && [ -z "$STOPPING" ]; do
        if ! cmp -s "$FENCE" "$ACK" 2>/dev/null; then
            cp "$FENCE" "$ACK.tmp" && mv "$ACK.tmp" "$ACK"
            echo "zone-node supervisor: the operator stopped this node; acknowledged"
        fi
        sleep 1
    done
    rm -f "$ACK"
    if [ -n "$STOPPING" ]; then
        echo "zone-node supervisor: stop signal while the node was not running, exiting"
        exit 0
    fi
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
    # A stop signal that arrived between the check above and the start: pass it on now.
    if [ -n "$STOPPING" ]; then kill -TERM "$CHILD" 2>/dev/null || true; fi
    DIRECTIVE=
    FENCED=
    while kill -0 "$CHILD" 2>/dev/null; do
        sleep 1
        if [ -z "$STOPPING" ] && [ -e "$FENCE" ]; then
            echo "zone-node supervisor: the operator asked to stop this node"
            FENCED=1
            kill -TERM "$CHILD" 2>/dev/null || true
            break
        fi
        NOW=$(recovery_stamp)
        if [ "$NOW" = none ] && [ "$STAMP" != none ]; then
            # The operator removed a completed directive from the manifest: nothing to restart
            # for; the next start of this node runs without it.
            echo "zone-node supervisor: forced-recovery directive removed"
            STAMP=none
        fi
        if [ -z "$STOPPING" ] && [ "$NOW" != "$STAMP" ]; then
            echo "zone-node supervisor: forced-recovery directive changed, restarting the node"
            DIRECTIVE=1
            kill -TERM "$CHILD" 2>/dev/null || true
            break
        fi
    done
    set +e
    wait "$CHILD"
    CODE=$?
    # A signal that interrupted the wait: collect the node's own status.
    if kill -0 "$CHILD" 2>/dev/null; then
        wait "$CHILD"
        CODE=$?
    fi
    set -e
    if [ -n "$STOPPING" ]; then
        echo "zone-node supervisor: node exited code=$CODE after a stop signal, exiting"
        exit "$CODE"
    fi
    if [ -n "$FENCED" ]; then
        echo "zone-node supervisor: node exited code=$CODE after the operator's stop"
    elif [ -n "$DIRECTIVE" ]; then
        echo "zone-node supervisor: node exited code=$CODE for the forced-recovery directive, restarting"
    else
        echo "zone-node supervisor: node exited code=$CODE, restarting"
        sleep 1
    fi
done
