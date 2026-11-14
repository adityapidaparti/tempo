#!/usr/bin/env bash
# Test A: a revokeKey with a success receipt in a leader-reported "finalized" block is undone by a
# leader crash before the MDBX commit (gdb holds mdbx_txn_commit_ex on the leader). Unmodified code.
# Expects stack up (common.sh up) and /tmp/keys.env = "VPK V KPK K" with K durably authorized for V.
set -uo pipefail
source /home/exedev/hunt-logs/repro/keys/common.sh; read VPK V KPK KA < /tmp/keys.env
CID=$(c zone-0 cast chain-id --rpc-url http://localhost:8545)
TI='{"jsonrpc":"2.0","id":1,"method":"zone_getAuthorizationTokenInfo","params":[]}'
state() { # per-node getKey + token auth
  local TOK; TOK=$(mktoken $KPK $V $CID)
  for n in 0 1 2; do log "  zone-$n tip=$(tip zone-$n) getKey=$(getkey zone-$n $V $KA) tokenInfo=$(rrpc 10.20.0.1$((n+1)) $TOK "$TI")"; done
}
log "V=$V K=$KA chain=$CID"; log "before:"; state
PID=$(docker exec zone-0 sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline 2>/dev/null); case "$c" in "/usr/local/bin/tempo-zone node"*) echo ${p#/proc/};; esac; done')
FIFO=$K/gdbinA; GLOG=$K/gdb-A.log; rm -f $FIFO; mkfifo $FIFO; : > $GLOG
sleep 100000 > $FIFO & HOLDER=$!
docker exec -i zone-0 gdb -q -nx < $FIFO > $GLOG 2>&1 & GDB=$!
g() { printf '%s\n' "$@" > $FIFO; }
waitlog() { for i in $(seq 1 ${2:-300}); do grep -q "$1" $GLOG && return 0; sleep 1; done; return 1; }
g "set pagination off" "set confirm off" "set non-stop on" "set print thread-events off" "attach $PID" "echo ATTACHED\\n"
waitlog ATTACHED 300 || { log "attach failed"; exit 1; }; sleep 5
g "continue -a &" "break mdbx_txn_commit_ex" "echo ARMED\\n"; waitlog ARMED 60
waitlog "hit Breakpoint 1" 120 || { log "no commit"; exit 1; }
log "leader MDBX commit paused; followers at $(tip zone-1)"; sleep 2
OUT=$(c zone-0 sh -c "cast send $KC 'revokeKey(address)' $KA --private-key $VPK --gas-limit 1000000 --rpc-url http://localhost:8545 2>&1")
echo "$OUT" | grep -E '^(status|blockNumber|blockHash|transactionHash)|rror'
TX=$(echo "$OUT" | awk '/^transactionHash/{print $2}'); BN=$(echo "$OUT" | awk '/^blockNumber/{print $2}')
sleep 3
log "leader finalized=$(c zone-0 cast block finalized -f number --rpc-url http://localhost:8545) safe=$(c zone-0 cast block safe -f number --rpc-url http://localhost:8545) revoke block=$BN"
log "leader getKey (pre-crash) = $(getkey zone-0 $V $KA)"
log "follower view pre-crash:"; for n in 1 2; do log "  zone-$n tip=$(tip zone-$n) getKey=$(getkey zone-$n $V $KA)"; done
sup 0 kill; log "SIGKILL leader"; sleep 1; g "quit"; kill $HOLDER 2>/dev/null; wait $GDB 2>/dev/null
sup 0 start; log "restarted leader"
for i in $(seq 1 90); do [[ $(tip zone-0) -gt $((BN+10)) ]] && break; sleep 2; done
log "after restart:"; state
for n in 0 1 2; do log "  zone-$n revoke receipt=$(rcpt zone-$n $TX) hash@$BN=$(c zone-$n cast block $BN -f hash --rpc-url http://localhost:8545 2>/dev/null)"; done
log "K-signed transfer from V after the confirmed revoke:"
c zone-1 cast send $T 'transfer(address,uint256)' 0x000000000000000000000000000000000000dEaD 99 --tempo.access-key $KPK --tempo.root-account $V --gas-limit 500000 --rpc-url http://localhost:8545 2>&1 | grep -E '^(status|blockNumber|transactionHash|type)|rror'
TOK=$(mktoken $KPK $V $CID)
log "eth_getBalance(V) with K token on zone-1: $(rrpc 10.20.0.12 $TOK "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"eth_getBalance\",\"params\":[\"$V\",\"latest\"]}")"
log "waiting 120s for any re-inclusion of revoke"; sleep 120
for n in 0 1 2; do log "  zone-$n tip=$(tip zone-$n) revoke receipt=$(rcpt zone-$n $TX) getKey=$(getkey zone-$n $V $KA)"; done
