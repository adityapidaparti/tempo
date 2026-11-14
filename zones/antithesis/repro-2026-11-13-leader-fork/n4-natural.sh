#!/usr/bin/env bash
# N4 without any test aid: receipt -> immediate SIGKILL of the leader -> restart -> does the tx survive?
set -uo pipefail
E="-e FOUNDRY_DISABLE_NIGHTLY_WARNING=1"; T=0x20c0000000000000000000000000000000000000
c() { docker exec $E "$@"; }
ctl() { docker exec zone-2 sh -c "printf '%s' '$2' > /fault-control/.$1.tmp && mv /fault-control/.$1.tmp /fault-control/$1"; }
REQ_ID=$(date +%s%N); sup() { REQ_ID=$((REQ_ID+1)); ctl "zone-$1.request" "{\"id\":$REQ_ID,\"action\":\"$2\"}"; }
pre=$(printf 'tempo-zone-antithesis-workload' | xxd -p | tr -d '\n')
N=${1:-20}; lost=0; moved=0; kept=0
for i in $(seq 1 $N); do
  idx=$((1000 + (i % 8))); PK=$(c zone-0 cast keccak 0x${pre}$(printf '%08x' $idx))
  OUT=$(c zone-0 sh -c "cast send $T 'transfer(address,uint256)' 0x000000000000000000000000000000000000dEaD 1 --private-key $PK --gas-limit 500000 --rpc-url http://localhost:8545 2>&1")
  sup 0 kill
  TX=$(echo "$OUT" | awk '/^transactionHash/{print $2}'); BN=$(echo "$OUT" | awk '/^blockNumber/{print $2}'); ST=$(echo "$OUT" | awk '/^status/{print $2}')
  sleep 1; sup 0 start
  for k in $(seq 1 60); do c zone-0 cast block-number --rpc-url http://localhost:8545 >/dev/null 2>&1 && break; sleep 1; done
  sleep 6
  R=$(c zone-1 cast rpc eth_getTransactionReceipt "$TX" --rpc-url http://localhost:8545 2>/dev/null | tr "," "\n")
  NB=$(echo "$R" | grep -oE '"blockNumber":"0x[0-9a-f]+"' | head -n1 | grep -oE "0x[0-9a-f]+"); NB=$([ -n "$NB" ] && printf '%d' $NB || echo none)
  HEAL=$(docker logs --since 20s zone-0 2>&1 | grep -oE 'AccountsHistory: healing via changesets checkpoint=[0-9]+ sf_tip=[0-9]+' | tail -n1)
  if [[ $NB == none ]]; then lost=$((lost+1)); v=LOST; elif [[ $NB != "$BN" ]]; then moved=$((moved+1)); v=MOVED; else kept=$((kept+1)); v=ok; fi
  echo "[$(date +%T)] #$i tx=${TX:0:12} status=$ST receipt_block=$BN now=$NB $v ${HEAL:+($HEAL)}"
done
echo "SUMMARY: $N kills: lost=$lost moved=$moved kept=$kept"
