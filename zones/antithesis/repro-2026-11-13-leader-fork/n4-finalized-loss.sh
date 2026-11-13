#!/usr/bin/env bash
# N4 on UNMODIFIED product code: the leader returns a success receipt for a tx in a block it reports
# as `finalized`, before that block is durable. A leader crash then erases the tx everywhere.
# The gdb hold pauses only the MDBX commit thread, i.e. it freezes "durability" while the leader
# keeps producing; on a real node the same window exists for every block, just shorter.
set -uo pipefail
R=/home/exedev/hunt-logs/repro; Z=~/src/wt/hunt/contrib/antithesis/zones
export ZONES_IMAGE=tempo-zones-antithesis:pristine WORKLOAD_IMAGE=tempo-zones-antithesis-workload:pristine
DC="docker compose -p n4 -f $Z/docker-compose.yaml"
E="-e FOUNDRY_DISABLE_NIGHTLY_WARNING=1"; T=0x20c0000000000000000000000000000000000000
log() { echo "[$(date +%T)] $*"; }
c() { docker exec $E "$@"; }
tip() { c "$1" cast block-number --rpc-url http://localhost:8545 2>/dev/null || echo -1; }
rcpt() { c "$1" cast rpc eth_getTransactionReceipt "$2" --rpc-url http://localhost:8545 2>/dev/null | head -c 90; }
ctl() { docker exec zone-2 sh -c "printf '%s' '$2' > /fault-control/.$1.tmp && mv /fault-control/.$1.tmp /fault-control/$1"; }
REQ_ID=$(date +%s%N); sup() { REQ_ID=$((REQ_ID+1)); ctl "zone-$1.request" "{\"id\":$REQ_ID,\"action\":\"$2\"}"; }
pre=$(printf 'tempo-zone-antithesis-workload' | xxd -p | tr -d '\n')

for p in n2impact smoke n2repro; do docker compose -p $p -f $Z/docker-compose.yaml down -v >/dev/null 2>&1; done
$DC down -v >/dev/null 2>&1; $DC up -d >/dev/null 2>&1
until docker logs workload 2>&1 | grep -q 'zone replicated'; do sleep 5; done
docker exec workload /opt/antithesis/test/v1/zone_payments/first_seed | tail -n 1
log "image $(docker inspect -f '{{.Config.Image}}' zone-0); leader zone-0"
PK=$(c zone-0 cast keccak 0x${pre}$(printf '%08x' 1001)); A=$(c zone-0 cast wallet address $PK)
BAL0=$(c zone-1 cast call $T 'balanceOf(address)(uint256)' $A --from $A --rpc-url http://localhost:8545)
log "sender $A balance on zone-1 before: $BAL0"

PID=$(docker exec zone-0 sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline 2>/dev/null); case "$c" in "/usr/local/bin/tempo-zone node"*) echo ${p#/proc/};; esac; done')
FIFO=$R/gdbin4; GLOG=$R/gdb-n4.log; rm -f $FIFO; mkfifo $FIFO; : > $GLOG
sleep 100000 > $FIFO & HOLDER=$!
docker exec -i zone-0 gdb -q -nx < $FIFO > $GLOG 2>&1 & GDB=$!
g() { printf '%s\n' "$@" > $FIFO; }
waitlog() { for i in $(seq 1 ${2:-300}); do grep -q "$1" $GLOG && return 0; sleep 1; done; return 1; }
g "set pagination off" "set confirm off" "set non-stop on" "set print thread-events off" "attach $PID" "echo ATTACHED\\n"
waitlog ATTACHED 300 || { log "attach failed"; exit 1; }; sleep 5
g "continue -a &" "break mdbx_txn_commit_ex" "echo ARMED\\n"; waitlog ARMED 60
waitlog "hit Breakpoint 1" 120 || { log "no commit"; exit 1; }
log "leader's MDBX commit is paused (durability frozen); followers at $(tip zone-1)"
sleep 2
OUT=$(c zone-0 sh -c "cast send $T 'transfer(address,uint256)' 0x000000000000000000000000000000000000dEaD 12345 --private-key $PK --gas-limit 500000 --rpc-url http://localhost:8545 2>&1")
TX=$(echo "$OUT" | awk '/^transactionHash/{print $2}'); BN=$(echo "$OUT" | awk '/^blockNumber/{print $2}')
echo "$OUT" | grep -E '^(status|blockNumber|transactionHash)'
sleep 3
FIN=$(c zone-0 cast block finalized -f number --rpc-url http://localhost:8545)
log "leader reports finalized block = $FIN (tx block $BN); receipt on leader: $(rcpt zone-0 $TX)"
sup 0 kill; log "SIGKILL leader"; sleep 1; g "quit"; kill $HOLDER 2>/dev/null; wait $GDB 2>/dev/null
sup 0 start; log "restarted leader"
for i in $(seq 1 60); do [[ $(tip zone-0) -gt $((BN+10)) ]] && break; sleep 2; done
docker logs --since 3m zone-0 2>&1 | grep -oE 'AccountsHistory: healing via changesets checkpoint=[0-9]+ sf_tip=[0-9]+' | tail -n 1
log "waiting 120s for any re-inclusion"; sleep 120
for n in 0 1 2 rpc; do log "zone-$n tip=$(tip zone-$n) receipt=$(rcpt zone-$n $TX)"; done
BAL1=$(c zone-1 cast call $T 'balanceOf(address)(uint256)' $A --from $A --rpc-url http://localhost:8545)
log "sender balance on zone-1 after: $BAL1 (before $BAL0)"
for n in 0 1 2; do log "zone-$n hash@$BN=$(c zone-$n cast block $BN -f hash --rpc-url http://localhost:8545 2>/dev/null)"; done
