#!/usr/bin/env bash
# Deterministic N2 repro: hold the leader's MDBX commit (after static-file finalize) with gdb,
# let followers backfill the not-yet-committed block, crash the leader, restart, compare hashes.
# usage: n2-gdb-hold.sh [up]   (pass "up" to recreate the n2repro stack first)
set -uo pipefail
R=/home/exedev/hunt-logs/repro
[[ ${1:-} == up ]] && bash $R/n2-gdb-repro.sh up
cd ~/src/wt/hunt/contrib/antithesis/zones
log() { echo "[$(date +%T)] $*"; }
tip() { docker exec "$1" cast block-number --rpc-url http://localhost:8545 2>/dev/null || echo -1; }
hash_at() { docker exec "$1" cast block "$2" -f hash --rpc-url http://localhost:8545 2>/dev/null || echo none; }
ctl() { docker exec zone-2 sh -c "printf '%s' '$2' > /fault-control/.$1.tmp && mv /fault-control/.$1.tmp /fault-control/$1"; }
REQ_ID=$(date +%s%N); sup() { REQ_ID=$((REQ_ID+1)); ctl "zone-$1.request" "{\"id\":$REQ_ID,\"action\":\"$2\"}"; }

PID=$(docker exec zone-0 sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline 2>/dev/null); case "$c" in "/usr/local/bin/tempo-zone node"*) echo ${p#/proc/};; esac; done')
log "leader zone-0 pid=$PID tips: z0=$(tip zone-0) z1=$(tip zone-1) z2=$(tip zone-2)"
FIFO=$R/gdbin; GLOG=$R/gdb-hold.log; rm -f $FIFO; mkfifo $FIFO; : > $GLOG
sleep 100000 > $FIFO & HOLDER=$!
docker exec -i zone-0 gdb -q -nx < $FIFO > $GLOG 2>&1 & GDB=$!
g() { printf '%s\n' "$@" > $FIFO; }
waitlog() { for i in $(seq 1 ${2:-300}); do grep -q "$1" $GLOG && return 0; sleep 1; done; return 1; }
# Breakpoint on every MDBX RW commit. reth-libmdbx runs commits on the "mdbx-rs-txn-mgr" thread; in
# non-stop mode only that thread stops, *after* DatabaseProvider::commit already ran
# static_file_provider.finalize() (provider.rs:4083-4108), so last_block_number() = N while MDBX = N-1.
g "set pagination off" "set confirm off" "set non-stop on" "set print thread-events off" \
  "attach $PID" "echo ATTACHED\\n"
waitlog ATTACHED 300 || { log "gdb attach failed"; exit 1; }
sleep 5   # let all attach-stop events arrive, otherwise 'continue -a' misses late-stopping threads
g "continue -a &" "break mdbx_txn_commit_ex" "echo ARMED\\n"; waitlog ARMED 60
waitlog "hit Breakpoint 1" 120 || { log "no commit hit"; exit 1; }
log "HELD: $(grep -m1 'hit Breakpoint 1' $GLOG)"
g "thread find persistence" "echo FOUND\\n"; waitlog FOUND 60
PT=$(grep -oE "Thread [0-9]+ has target name 'persistence'" $GLOG | grep -oE '[0-9]+' | head -1)
g "thread $PT" "interrupt" "shell sleep 1" "bt 30" "echo BT\\n"; waitlog BT 60
grep -E "^#(1[0-9]|2[0-9]) .*(DatabaseProvider|database::provider::.*commit|on_save_blocks)" $GLOG | cut -c1-200
CK=$(tip zone-1); log "follower tips at hold: z1=$CK z2=$(tip zone-2) (leader rpc tip=$(tip zone-0))"
# Broadcaster waits on persisted_block_stream (never fires); after ~30s followers log
# "No peer block received recently; probing for backfill" and serve_backfill_page bounds by
# static-file last_block_number() => serves the uncommitted block.
for i in $(seq 1 90); do [[ $(tip zone-1) -gt $CK ]] && break; sleep 1; done
H=$(tip zone-1); HF=$(hash_at zone-1 $H); log "zone-1 got height $H hash $HF while leader commit still held"
sup 0 kill; log "SIGKILLed leader (supervisor kill)"; sleep 2
g "quit"; kill $HOLDER 2>/dev/null; wait $GDB 2>/dev/null
sup 0 start; log "restarted leader"
for i in $(seq 1 90); do [[ $(tip zone-0) -gt $((H+3)) ]] && break; sleep 2; done
docker logs --since 3m zone-0 2>&1 | grep -oE 'AccountsHistory: healing via changesets checkpoint=[0-9]+ sf_tip=[0-9]+' | tail -1
sleep 10
for n in 0 1 2 rpc; do log "zone-$n tip=$(tip zone-$n) hash@$H=$(hash_at zone-$n $H)"; done
docker logs --since 2m zone-1 2>&1 | grep -E "conflicts with canonical|parent mismatch" | head -2 | cut -c1-300
[[ $(hash_at zone-0 $H) != "$HF" ]] && log "*** PERMANENT FORK at $H ***" || log "no fork"
