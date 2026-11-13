#!/usr/bin/env bash
# N2 impact demo on UNMODIFIED product code: fork the leader (gdb hold of its MDBX commit + SIGKILL),
# then show (1) quorum + user RPC frozen, (2) settlement to L1 stops, (3) a tx the leader gave a
# receipt for never reaches the quorum/user RPC.
set -uo pipefail
R=/home/exedev/hunt-logs/repro; Z=~/src/wt/hunt/contrib/antithesis/zones
export ZONES_IMAGE=tempo-zones-antithesis:pristine WORKLOAD_IMAGE=tempo-zones-antithesis-workload:pristine
DC="docker compose -p n2impact -f $Z/docker-compose.yaml"
E="-e FOUNDRY_DISABLE_NIGHTLY_WARNING=1"; T=0x20c0000000000000000000000000000000000000
log() { echo "[$(date +%T)] $*"; }
tip() { docker exec $E "$1" cast block-number --rpc-url http://localhost:8545 2>/dev/null || echo -1; }
hash_at() { docker exec $E "$1" cast block "$2" -f hash --rpc-url http://localhost:8545 2>/dev/null || echo none; }
receipt() { docker exec $E "$1" cast receipt "$2" blockNumber --rpc-url http://localhost:8545 2>/dev/null || echo "NOT FOUND"; }
batches() { docker logs "$1" 2>&1 | grep -c 'Batch submitted to L1'; }
pre=$(printf 'tempo-zone-antithesis-workload' | xxd -p | tr -d '\n')

if [[ ${1:-} == up ]]; then
  $DC down -v >/dev/null 2>&1; docker compose -p smoke -f $Z/docker-compose.yaml down -v >/dev/null 2>&1
  $DC up -d >/dev/null 2>&1
  until docker logs workload 2>&1 | grep -q 'zone replicated'; do sleep 5; done
  docker exec workload /opt/antithesis/test/v1/zone_payments/first_seed | tail -n 1
  log "image: $(docker inspect -f '{{.Config.Image}}' zone-0)"
fi
PK=$(docker exec $E zone-0 cast keccak 0x${pre}$(printf '%08x' 1000))
log "settlement batches so far: leader zone-0=$(batches zone-0)"
log "=== forking the leader ==="
bash $R/n2-gdb-hold.sh 2>&1 | tail -n 9
H=$(tip zone-1)
log "=== post-fork: tx sent to the LEADER's RPC ==="
OUT=$(docker exec $E zone-0 sh -c "cast send $T 'transfer(address,uint256)' 0x000000000000000000000000000000000000dEaD 7 --private-key $PK --gas-limit 500000 --rpc-url http://localhost:8545 2>&1")
TX=$(echo "$OUT" | awk '/^transactionHash/{print $2}'); echo "$OUT" | grep -E '^(status|blockNumber|transactionHash)'
B0=$(batches zone-0)
log "=== waiting 5 minutes ==="; sleep 300
for n in 0 1 2 rpc; do log "zone-$n tip=$(tip zone-$n) hash@$H=$(hash_at zone-$n $H) receipt($TX)=$(receipt zone-$n $TX)"; done
log "leader L1 settlement batches: at fork=$B0 after 5min=$(batches zone-0)"
docker logs --since 5m zone-1 2>&1 | grep -E 'Rejected settlement|conflicts with canonical|parent mismatch' | awk '{$1="";print}' | cut -c1-200 | sort | uniq -c | sort -rn | head -n 4
