#!/usr/bin/env bash
# Local deterministic repro of N2: leader serves block H from static files before MDBX commit,
# then crashes; on restart it rebuilds a different H'. Uses gdb non-stop to hold only the
# leader's "persistence" thread at mdbx_txn_commit_ex.
set -euo pipefail
cd ~/src/wt/hunt/contrib/antithesis/zones
export ZONES_IMAGE=tempo-zones-antithesis:hunt WORKLOAD_IMAGE=tempo-zones-antithesis-workload:hunt
DC="docker compose -p n2repro -f docker-compose.yaml"
rpc() { docker exec "$1" cast "${@:2}" --rpc-url http://localhost:8545; }
hash_at() { docker exec "$1" cast block "$2" -f hash --rpc-url http://localhost:8545 2>/dev/null || echo none; }
tip() { docker exec "$1" cast block-number --rpc-url http://localhost:8545 2>/dev/null || echo -1; }
log() { echo "[$(date +%T)] $*"; }

phase=${1:-all}
if [[ $phase == up || $phase == all ]]; then
  $DC down -v >/dev/null 2>&1 || true
  $DC up -d l1 provision proxy-0 proxy-1 proxy-2 zone-0 zone-1 zone-2 zone-rpc
  log "waiting for zone-1 to reach height 30"
  until [[ $(tip zone-1) -ge 30 ]]; do sleep 5; done
  log "tips: z0=$(tip zone-0) z1=$(tip zone-1) z2=$(tip zone-2)"
fi

# ---- N2 trigger using the slow-fsync shim instead of gdb ----
# usage: n2-gdb-repro.sh trigger <leader_idx> <lagger_idx> <fsync_ms> <pause_s>
ctl() { docker exec zone-2 sh -c "printf '%s' '$2' > /fault-control/.$1.tmp && mv /fault-control/.$1.tmp /fault-control/$1"; }
REQ_ID=$(date +%s%N)
sup() { REQ_ID=$((REQ_ID+1)); ctl "zone-$1.request" "{\"id\":$REQ_ID,\"action\":\"$2\"}"; }
if [[ $phase == trigger ]]; then
  L=$2; F=$3; MS=$4; P=$5
  log "tips before: z0=$(tip zone-0) z1=$(tip zone-1) z2=$(tip zone-2)"
  docker pause zone-$F; log "paused zone-$F for ${P}s"; sleep "$P"
  ctl fsync-$L "$MS"; log "leader fsync delay ${MS}ms"; sleep 2
  docker unpause zone-$F; log "unpaused zone-$F"
  # wait until lagger catches up to within 1 of the leader's served tip, then kill leader
  for i in $(seq 1 400); do
    ft=$(tip zone-$F); lt=$(tip zone-$L)
    if [[ $ft -ge $((lt-1)) && $ft -gt 0 ]]; then break; fi; sleep 0.05
  done
  sup $L kill; log "KILLED leader zone-$L at follower tip=$ft leader rpc tip=$lt"
  ctl fsync-$L 0
  H=$ft; HF=$(hash_at zone-$F $H); log "follower zone-$F height $H hash $HF"
  sleep 3; sup $L start; log "restarted leader"
  for i in $(seq 1 60); do [[ $(tip zone-$L) -gt $H ]] && break; sleep 2; done
  for n in 0 1 2 rpc; do log "zone-$n tip=$(tip zone-$n) hash@$H=$(hash_at zone-$n $H)"; done
fi

# usage: n2-gdb-repro.sh loop <leader> <lagger> <fsync_ms> <iterations>
if [[ $phase == loop ]]; then
  L=$2; F=$3; MS=$4; N=$5
  for it in $(seq 1 "$N"); do
    ctl fsync-$L "$MS"; sleep 4
    docker pause zone-$F >/dev/null; sleep 3; docker unpause zone-$F >/dev/null
    d=$(awk -v s=$RANDOM 'BEGIN{srand(s); printf "%.2f", 0.3+rand()*2.5}'); sleep "$d"
    sup $L kill; ft=$(tip zone-$F); HF=$(hash_at zone-$F $ft)
    ctl fsync-$L 0; sleep 2; sup $L start
    for i in $(seq 1 30); do [[ $(tip zone-$L) -gt $((ft+1)) ]] && break; sleep 1; done
    HL=$(hash_at zone-$L $ft)
    log "iter $it delay=${d}s follower@$ft=$HF leader@$ft=$HL"
    if [[ $HF != "$HL" && $HL != none && $HF != none ]]; then log "*** FORK at $ft ***"; break; fi
    sleep 5
  done
fi

# usage: n2-gdb-repro.sh loop2 <leader> <lagger> <fsync_ms> <lag_s> <iterations>
if [[ $phase == loop2 ]]; then
  L=$2; F=$3; MS=$4; LAG=$5; N=$6
  for it in $(seq 1 "$N"); do
    ctl fsync-$L 0
    docker pause zone-$F >/dev/null; sleep $((LAG-2)); ctl fsync-$L "$MS"; sleep 2
    docker unpause zone-$F >/dev/null
    for i in $(seq 1 150); do
      ft=$(tip zone-$F); lt=$(tip zone-$L); [[ $ft -ge $((lt-2)) && $ft -gt 0 ]] && break; sleep 0.1
    done
    sup $L kill; ft=$(tip zone-$F); HF=$(hash_at zone-$F $ft)
    ctl fsync-$L 0; sleep 2; sup $L start
    for i in $(seq 1 40); do [[ $(tip zone-$L) -gt $((ft+1)) ]] && break; sleep 1; done
    HL=$(hash_at zone-$L $ft)
    ck=$(docker logs --since 60s zone-$L 2>&1 | grep -oE 'AccountsHistory: healing via changesets checkpoint=[0-9]+ sf_tip=[0-9]+' | tail -n1 || true)
    log "iter $it follower@$ft leaderRPCtip_at_kill=$lt [$ck] F=$HF L=$HL"
    if [[ $HF != "$HL" && $HL != none && $HF != none ]]; then log "*** FORK at $ft ***"; break; fi
    sleep 5
  done
fi

# usage: n2-gdb-repro.sh loop3 <leader> <lagger> <fsync_ms> <down_s> <iterations>  (lag via follower restart)
if [[ $phase == loop3 ]]; then
  L=$2; F=$3; MS=$4; DOWN=$5; N=$6
  for it in $(seq 1 "$N"); do
    ctl fsync-$L 0
    sup $F kill; sleep "$DOWN"; ctl fsync-$L "$MS"; sleep 1; sup $F start
    ft=-1
    for i in $(seq 1 600); do
      ft=$(tip zone-$F); lt=$(tip zone-$L); [[ $ft -ge $((lt-2)) && $ft -gt 0 ]] && break; sleep 0.1
    done
    sup $L kill; sleep 0.3; ft=$(tip zone-$F); HF=$(hash_at zone-$F $ft)
    ctl fsync-$L 0; sleep 2; sup $L start
    for i in $(seq 1 40); do [[ $(tip zone-$L) -gt $((ft+1)) ]] && break; sleep 1; done
    HL=$(hash_at zone-$L $ft)
    ck=$(docker logs --since 60s zone-$L 2>&1 | grep -oE 'AccountsHistory: healing via changesets checkpoint=[0-9]+ sf_tip=[0-9]+' | tail -n1 || true)
    log "iter $it follower@$ft leaderRPCtip_at_kill=$lt [$ck] F=$HF L=$HL"
    if [[ $HF != "$HL" && $HL != none && $HF != none ]]; then log "*** FORK at $ft ***"; break; fi
    sleep 5
  done
fi

# usage: n2-gdb-repro.sh freeze <leader> <lagger>  (persistence thread frozen ~60s inside MDBX commit)
if [[ $phase == freeze ]]; then
  L=$2; F=$3
  ctl fsync-$L 0; sleep 3
  sup $F kill; log "follower zone-$F down"; sleep 8
  ctl fsync-$L 60000; log "leader commits frozen (60s)"; sleep 4
  sup $F start; log "follower restarted"
  for i in $(seq 1 200); do
    ft=$(tip zone-$F); [[ $ft -gt 0 ]] && break; sleep 0.2
  done
  prev=-1; for i in $(seq 1 30); do ft=$(tip zone-$F); [[ $ft == "$prev" ]] && break; prev=$ft; sleep 3; done
  lt=$(tip zone-$L)
  sup $L kill; sleep 0.5; ft=$(tip zone-$F); HF=$(hash_at zone-$F $ft); log "KILLED leader; follower tip=$ft hash=$HF leaderRPCtip=$lt"
  ctl fsync-$L 0; sleep 2; sup $L start; log "leader restarted"
  for i in $(seq 1 60); do [[ $(tip zone-$L) -gt $((ft+1)) ]] && break; sleep 1; done
  docker logs --since 90s zone-$L 2>&1 | grep -oE 'AccountsHistory: healing via changesets checkpoint=[0-9]+ sf_tip=[0-9]+' | tail -n1 || true
  sleep 5
  for n in 0 1 2 rpc; do log "zone-$n tip=$(tip zone-$n) hash@$ft=$(hash_at zone-$n $ft)"; done
fi
