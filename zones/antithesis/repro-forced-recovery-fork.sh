#!/bin/sh
# Reproduces: a crashed leader that persisted blocks it never replicated comes back after a
# forced recovery, stays on its own chain, and never converges.
# Run from zones/antithesis after building the images (see README.md), tagged :quorum.
set -eu
ex() { docker compose exec -T workload "$@"; }
tip() { ex cast rpc zone_getSequencerInfo --rpc-url "http://10.20.0.$1:8545" 2>/dev/null | jq -c '[.local.name,.local.role,(.localTip.zoneHeight),.localTip.zoneHash[0:12]]' || echo "\"$1 down\""; }
tips() { for n in 11 12 13 20; do tip $n; done; }
hash_at() { for n in 11 12 13 20; do ex cast rpc eth_getBlockByNumber "$(printf '0x%x' "$1")" false --rpc-url "http://10.20.0.$n:8545" 2>/dev/null | jq -r '.hash // "none"' || echo down; done; }

docker compose down -v >/dev/null 2>&1 || true
docker compose up -d >/dev/null 2>&1
until docker compose logs workload 2>/dev/null | grep -q 'zone replicated'; do sleep 2; done
sleep 10
echo "== start"; tips

echo "== 1. followers stop hearing the leader (zone-0); it keeps producing; then it crashes"
docker pause zone-1 zone-2 zone-rpc >/dev/null
sleep 6
echo "leader before crash:"; tip 11
docker kill zone-0 >/dev/null
docker unpause zone-1 zone-2 zone-rpc >/dev/null
sleep 5
echo "survivors:"; tips

echo "== 2. operator: survivors share a tip; forced recovery onto zone-1 at that tip"
HASH=$(ex cast rpc zone_getSequencerInfo --rpc-url http://10.20.0.12:8545 | jq -r .localTip.zoneHash)
HEIGHT=$(ex cast rpc zone_getSequencerInfo --rpc-url http://10.20.0.12:8545 | jq -r .localTip.zoneHeight)
echo "recovery tip $HEIGHT $HASH"
ex sh -c "printf '[forced_recovery]\nleader = \"zone-1\"\nrecovery_block_hash = \"$HASH\"\n' > /control/recovery.tmp && mv /control/recovery.tmp /control/recovery.toml"
sleep 30
tips

echo "== 3. the crashed leader comes back (same directive)"
docker start zone-0 >/dev/null
sleep 40
tips
NEXT=$(( $(printf '%d' "$HEIGHT") + 1 ))
echo "== block $NEXT on zone-0, zone-1, zone-2, zone-rpc"
hash_at "$NEXT"
docker compose logs zone-0 2>&1 | sed 's/\x1b\[[0-9;]*m//g' | grep -E 'Installed manifest forced|conflicts with canonical|parent mismatch' | cut -c1-240 | tail -3
