#!/usr/bin/env bash
# N2b on UNMODIFIED product code: settle (on L1) a zone block that the leader never made durable.
# 1. gdb (non-stop) holds the leader's MDBX commit of a batch-boundary block H (H % 20 == 0), i.e.
#    after reth finalized static files (last_block_number()=H) but before the MDBX tx commit.
# 2. BatchPreparer sees H via last_block_number(), proposes the H batch; followers backfill H from
#    the leader (30s probe, also bounded by last_block_number()), sign; leader submits to L1.
# 3. SIGKILL leader before MDBX commit; restart -> reth heals to H-1, portal points at H.
# usage: n2b-settlement.sh [up] [observe_secs]
set -uo pipefail
R=/home/exedev/hunt-logs/repro; Z=~/src/wt/hunt/contrib/antithesis/zones
export ZONES_IMAGE=tempo-zones-antithesis:pristine WORKLOAD_IMAGE=tempo-zones-antithesis-workload:pristine
DC="docker compose -p n4 -f $Z/docker-compose.yaml"
E="-e FOUNDRY_DISABLE_NIGHTLY_WARNING=1"; PORTAL=0x5ad0000000000000000000000000000000000001
OBS=${2:-300}
log() { echo "[$(date +%T)] $*"; }
c() { docker exec $E "$@"; }
tip() { c "$1" cast block-number --rpc-url http://localhost:8545 2>/dev/null || echo -1; }
hash_at() { c "$1" cast block "$2" -f hash --rpc-url http://localhost:8545 2>/dev/null || echo none; }
portal() { echo "zoneHeight=$(c l1 cast call $PORTAL 'zoneHeight()(uint64)' --rpc-url http://localhost:8545 | cut -d' ' -f1) blockHash=$(c l1 cast call $PORTAL 'blockHash()(bytes32)' --rpc-url http://localhost:8545)"; }
ctl() { docker exec zone-2 sh -c "printf '%s' '$2' > /fault-control/.$1.tmp && mv /fault-control/.$1.tmp /fault-control/$1"; }
REQ_ID=$(date +%s%N); sup() { REQ_ID=$((REQ_ID+1)); ctl "zone-$1.request" "{\"id\":$REQ_ID,\"action\":\"$2\"}"; }
# leader's static-file head as seen by its BatchPreparer (polls last_block_number() every 1s)
sfhead() { docker logs --since 20s zone-0 2>&1 | grep -oE 'Processing zone block range from=[0-9]+ to=[0-9]+' | tail -1 | grep -oE '[0-9]+$'; }

if [[ ${1:-} == up ]]; then
  for p in n2impact smoke n2repro; do docker compose -p $p -f $Z/docker-compose.yaml down -v >/dev/null 2>&1; done
  $DC down -v >/dev/null 2>&1; $DC up -d >/dev/null 2>&1
  until docker logs workload 2>&1 | grep -q 'zone replicated'; do sleep 5; done
  docker exec workload /opt/antithesis/test/v1/zone_payments/first_seed | tail -n 1
fi
log "image $(docker inspect -f '{{.Config.Image}}' zone-0); leader zone-0; portal before: $(portal)"
PID=$(docker exec zone-0 sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline 2>/dev/null); case "$c" in "/usr/local/bin/tempo-zone node"*) echo ${p#/proc/};; esac; done')
FIFO=$R/gdbin2b; GLOG=$R/gdb-n2b.log; rm -f $FIFO; mkfifo $FIFO; : > $GLOG
sleep 100000 > $FIFO & HOLDER=$!
docker exec -i zone-0 gdb -q -nx < $FIFO > $GLOG 2>&1 & GDB=$!
g() { printf '%s\n' "$@" > $FIFO; }
waitlog() { for i in $(seq 1 ${2:-300}); do grep -q "$1" $GLOG && return 0; sleep 1; done; return 1; }
hits() { grep -c 'hit Breakpoint 1' $GLOG; }
g "set pagination off" "set confirm off" "set non-stop on" "set print thread-events off" "attach $PID" "echo ATTACHED\\n"
waitlog ATTACHED 300 || { log "attach failed"; exit 1; }; sleep 5
g "continue -a &" "echo RUNNING\\n"; waitlog RUNNING 60

# --- pick the boundary and hold exactly its commit ---
H=0; HELD=0; BP=0; TH=1
for attempt in $(seq 1 15); do
  S=$(sfhead); H=$(( (S/20 + 1) * 20 )); (( H - S < 6 )) && H=$((H+20))
  log "attempt $attempt: leader static-file head=$S, target boundary H=$H"
  until [[ $(sfhead) -ge $((H-2)) ]]; do sleep 0.2; done
  n=$(hits)
  if (( BP == 0 )); then g "break mdbx_txn_commit_ex" "echo ARMED\\n"; waitlog ARMED 30; BP=1; else g "enable 1"; fi
  while :; do
    for i in $(seq 1 100); do (( $(hits) > n )) && break; sleep 0.1; done
    (( $(hits) > n )) || { log "no hit"; break; }
    n=$(hits); TH=$(grep 'hit Breakpoint 1' $GLOG | tail -1 | grep -oE '^Thread [0-9]+' | grep -oE '[0-9]+')
    sleep 1.6; X=$(sfhead)
    if [[ $X == "$H" ]]; then HELD=1; break; fi
    log "  commit hit (thread $TH) with static-file head $X != $H -> release"
    g "thread $TH" "continue &"
    (( X > H )) && break
  done
  (( HELD )) && break
  g "disable 1"; sleep 0.5
  # release any commit that may have stopped between hit counting and disable
  g "thread $TH" "continue &"
done
(( HELD )) || { log "never held a boundary commit"; exit 1; }
g "disable 1"
HH=$(hash_at zone-0 $H)
log "HELD leader MDBX commit with static-file head = boundary H=$H (leader rpc hash $HH); rpc tip z0=$(tip zone-0) z1=$(tip zone-1) z2=$(tip zone-2)"

# --- wait for followers to backfill H and for L1 to accept the H batch ---
for i in $(seq 1 180); do
  docker logs --since 5m zone-0 2>&1 | grep -q "Batch successfully submitted to L1 last_zone_block=$H " && break; sleep 1
done
docker logs --since 5m zone-1 2>&1 | grep -E 'probing for backfill' | tail -1 | cut -c1-200
docker logs --since 5m zone-0 2>&1 | grep -E "Broadcast settlement proposal.*height=$H" | tail -1 | cut -c1-200
docker logs --since 5m zone-0 2>&1 | grep -E "Batch successfully submitted to L1 last_zone_block=$H " | tail -1 | cut -c1-260
P1=$(portal); log "L1 portal: $P1"
log "followers: z1 tip=$(tip zone-1) hash@$H=$(hash_at zone-1 $H); z2 tip=$(tip zone-2) hash@$H=$(hash_at zone-2 $H)"
log "leader commit still held: $(grep -c 'hit Breakpoint 1' $GLOG) hits, static-file head $(sfhead)"

# --- crash before durability ---
sup 0 kill; log "SIGKILL leader (supervisor kill) with MDBX commit of $H still pending"; sleep 1
g "quit"; kill $HOLDER 2>/dev/null; wait $GDB 2>/dev/null
sup 0 start; log "restarted leader"; T0=$(date +%s)
sleep 30
docker logs --since 1m zone-0 2>&1 | grep -oE 'AccountsHistory: healing via changesets checkpoint=[0-9]+ sf_tip=[0-9]+' | tail -n 1
log "post-restart: z0 tip=$(tip zone-0) hash@$H=$(hash_at zone-0 $H)"
for t in $(seq 60 60 $OBS); do
  sleep 60
  log "t+$(( $(date +%s)-T0 ))s tips z0=$(tip zone-0) z1=$(tip zone-1) z2=$(tip zone-2) rpc=$(tip zone-rpc) | $(portal)"
done
log "leader role/settlement errors since restart:"
docker logs --since $(( $(date +%s)-T0 ))s zone-0 2>&1 | grep -E 'not canonical|generation failed|fencing' | sort | uniq -c | sort -rn | head -5 | cut -c1-400
docker logs --since $(( $(date +%s)-T0 ))s zone-0 2>&1 | grep -cE 'Role generation failed to start'
docker logs --since $(( $(date +%s)-T0 ))s zone-0 2>&1 | grep -E 'Role generation failed to start' | tail -1 | cut -c1-500
for n in 1 2; do log "zone-$n last logs:"; docker logs --tail 4 zone-$n 2>&1 | cut -c1-250; done
