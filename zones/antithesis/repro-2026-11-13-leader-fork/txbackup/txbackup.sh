#!/usr/bin/env bash
# Txpool backup loss across graceful restart on a follower (zone-2), unmodified product code.
# Expects stack up via keys/common.sh `up`. zone-2's P2P is partitioned via the proxy gate so the
# tx cannot be forwarded to the leader before the restart.
set -uo pipefail
source /home/exedev/hunt-logs/repro/keys/common.sh
W=zone-1   # container used to write fault-control files (zone-2 will be down)
BK=/data/node/txpool-transactions-backup.rlp
netfault() {
  local st serial; st=$(docker exec $W sh -c 'for i in 0 1 2; do cat /fault-control/proxy-$i.json; echo; done')
  serial=$(docker exec $W sh -c 'cat /fault-control/network-serial.json 2>/dev/null || echo 0'); serial=$((serial+1))
  docker exec $W sh -c "printf '%s' $serial > /fault-control/network-serial.json"
  NETREQ=$(python3 -I -c '
import json,sys,time,random
boots=[json.loads(l)["boot"] for l in sys.argv[1].splitlines() if l.strip()]
now=int(time.time()*1000)
print(json.dumps({"id":[random.getrandbits(63),random.getrandbits(63)],"serial":int(sys.argv[2]),"boots":boots,"issued_ms":now,"deadline_ms":now+int(sys.argv[4])*1000,"l1_mask":0,"p2p_mask":int(sys.argv[3]),"cancelled":False}))' "$st" $serial $1 $2)
  printf '%s' "$NETREQ" | docker exec -i $W sh -c 'cat > /fault-control/.network.tmp && mv /fault-control/.network.tmp /fault-control/network.json'
}
netheal() {
  local r; r=$(python3 -I -c 'import json,sys;d=json.loads(sys.argv[1]);d["cancelled"]=True;print(json.dumps(d))' "$NETREQ")
  printf '%s' "$r" | docker exec -i $W sh -c 'cat > /fault-control/.network.tmp && mv /fault-control/.network.tmp /fault-control/network.json'
}
netstatus() { docker exec $W sh -c 'cat /fault-control/proxy-2.json' | head -c 200; echo; }
rpc() { c "$1" cast rpc "$2" "${@:3}" --rpc-url http://localhost:8545 2>&1 | head -c ${LIM:-300}; echo; }
pool() { c zone-2 cast rpc txpool_status --rpc-url http://localhost:8545 2>&1; }
gettx() { c "$1" cast rpc eth_getTransactionByHash "$TX" --rpc-url http://localhost:8545 2>&1 | head -c 160; echo; }

PK=$(wpk ${SENDER:-1000}); A=$(c zone-0 cast wallet address $PK)
log "sender $A nonce(zone-0)=$(c zone-0 cast nonce $A --rpc-url http://localhost:8545) bal=$(c zone-0 cast call $T 'balanceOf(address)(uint256)' $A --from $A --rpc-url http://localhost:8545)"
log "tips: z0=$(tip zone-0) z1=$(tip zone-1) z2=$(tip zone-2)"
netfault 4 180; sleep 3; log "partition zone-2 P2P: $(netstatus)"
sleep 5; log "tips after partition: z0=$(tip zone-0) z2=$(tip zone-2)"
RAW=$(c zone-2 cast mktx $T 'transfer(address,uint256)' 0x000000000000000000000000000000000000dEaD 7 --private-key $PK --gas-limit 500000 --rpc-url http://localhost:8545)
echo "$RAW" > $R/txbackup/raw.hex
TX=$(c zone-2 cast rpc eth_sendRawTransaction "$RAW" --rpc-url http://localhost:8545 2>&1 | tr -d '"'); log "submitted to zone-2: $TX"
poll() { # background tx/partition tracker
  while :; do
    l="[$(date +%T.%N | head -c 12)]"
    for n in zone-0 zone-rpc zone-2; do
      v=$(timeout 3 docker exec $n cast rpc eth_getTransactionByHash $TX --rpc-url http://localhost:8545 2>/dev/null | python3 -I -c 'import json,sys
try:
  d=json.loads(sys.stdin.read()); print("null" if d is None else ("pending" if d.get("blockNumber") is None else "mined@"+str(int(d["blockNumber"],16))))
except Exception: print("down")')
      l="$l $n=$v"
    done
    l="$l gates=$(docker exec $W sh -c 'for i in 0 1 2; do cat /fault-control/proxy-$i.json; echo; done' | python3 -I -c 'import json,sys;print(",".join(json.loads(x)["phase"][:3]+str(json.loads(x)["p2p_mask"]) for x in sys.stdin if x.strip()))')"
    echo "$l"; sleep 0.3
  done > $R/txbackup/poll-${SENDER:-1000}.log 2>&1
}
poll & POLLER=$!; trap 'kill $POLLER 2>/dev/null' EXIT
sleep 5
log "zone-2 txpool_status: $(pool)"
log "zone-2 getTx: $(gettx zone-2)"; log "zone-0 getTx: $(gettx zone-0)"; log "zone-2 receipt: $(rcpt zone-2 $TX)"
log "tips: z0=$(tip zone-0) z2=$(tip zone-2)"
log "backup file before stop: $(docker exec zone-2 ls -la $BK 2>&1)"
PID=$(docker exec zone-2 sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline 2>/dev/null); case "$c" in "/usr/local/bin/tempo-zone node"*) echo ${p#/proc/};; esac; done')
STOPTS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
log "SIGTERM tempo-zone pid $PID in zone-2"; docker exec zone-2 sh -c "kill -TERM $PID"
for i in $(seq 1 60); do [[ $(docker inspect -f '{{.State.Running}}' zone-2) == false ]] && break; sleep 1; done
log "zone-2 running=$(docker inspect -f '{{.State.Running}}' zone-2) exit=$(docker inspect -f '{{.State.ExitCode}}' zone-2)"
docker logs --since $STOPTS zone-2 2>&1 | grep -iE "backup|local transactions|shutdown|signal|exit" | tail -n 15
rm -f $R/txbackup/backup.rlp; docker cp zone-2:$BK $R/txbackup/backup.rlp 2>&1
log "backup file after stop: $(ls -la $R/txbackup/backup.rlp 2>&1)"
[[ -f $R/txbackup/backup.rlp ]] && log "backup contains tx raw body? $(xxd -p $R/txbackup/backup.rlp | tr -d '\n' | grep -c ${RAW:6:120})  hex=$(xxd -p $R/txbackup/backup.rlp | tr -d '\n' | head -c 200)"
netfault 4 180; log "renewed partition: $(netstatus)"
STARTTS=$(date -u +%Y-%m-%dT%H:%M:%SZ)
docker start zone-2 >/dev/null; log "docker start zone-2"
for i in $(seq 1 120); do docker exec zone-2 test -e $BK 2>/dev/null || { log "backup file gone (t+${i}s)"; break; }; sleep 1; done
for i in $(seq 1 90); do [[ $(tip zone-2) -ge 0 ]] && break; sleep 2; done
sleep 5
log "restart log (backup / token discovery / txpool):"
docker logs -t --since $STARTTS zone-2 2>&1 | grep -iE "backup|local transactions|reinsert|Discovered enabled tokens|enabled token|txs_file|Starting reth|RPC|Invalid|txpool" | head -n 30
docker logs -t --since $STARTTS zone-2 > $R/txbackup/restart-${SENDER:-1000}.log 2>&1
log "zone-rpc txpool_status: $(c zone-rpc cast rpc txpool_status --rpc-url http://localhost:8545 2>&1)"
log "after restart, still partitioned: zone-2 txpool_status: $(pool)"
log "zone-2 getTx: $(gettx zone-2)"; log "backup file now: $(docker exec zone-2 ls -la $BK 2>&1)"
netheal; sleep 3; log "healed: $(netstatus)"
for i in $(seq 1 30); do sleep 2; done
log "tips: z0=$(tip zone-0) z2=$(tip zone-2)"
for n in 0 1 2; do log "zone-$n getTx: $(gettx zone-$n) receipt: $(rcpt zone-$n $TX)"; done
log "zone-0 nonce($A)=$(c zone-0 cast nonce $A --rpc-url http://localhost:8545)"
log "CONTROL: resubmitting identical raw tx to zone-2"
log "  -> $(c zone-2 cast rpc eth_sendRawTransaction "$RAW" --rpc-url http://localhost:8545 2>&1 | head -c 200)"
for i in $(seq 1 20); do r=$(rcpt zone-0 $TX); [[ -n $r && $r != null ]] && break; sleep 2; done
log "  zone-0 receipt: $(c zone-0 cast receipt $TX --json --rpc-url http://localhost:8545 2>&1 | head -c 200)"
