#!/bin/bash
# runs inside a zone container. args: MODE(window|control) RELAY_URL A B
export FOUNDRY_DISABLE_NIGHTLY_WARNING=1
MODE=$1; RELAY=$2; A=$3; B=$4; T=${5:-$A}
L1=http://10.20.0.10:8545; P=0x5ad0000000000000000000000000000000000001
ADM=0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
ts(){ date +%T.%3N; }
st(){ echo "$(cast call $P 'leader()(address)' -b $1 --rpc-url $L1 2>&1) $(cast call $P 'leaderEpoch()(uint64)' -b $1 --rpc-url $L1 2>&1)"; }
E=$(cast call $P 'leaderEpoch()(uint64)' -b latest --rpc-url $L1)
echo "$(ts) pre latest=[$(st latest)] finalized=[$(st finalized)] blk=$(cast block-number --rpc-url $L1)"
TX=$(cast send --async --private-key $ADM $P 'setLeader(address,uint64)' $B $E --rpc-url $L1 2>&1)
echo "$(ts) admin setLeader($B,$E) tx=$TX"
if [ "$MODE" = control ]; then cast receipt $TX --rpc-url $L1 -f status >/dev/null; sleep 7
  echo "$(ts) before-relay latest=[$(st latest)] finalized=[$(st finalized)]"; fi
if [ "$MODE" = window ]; then
  until R=$(cast rpc eth_getTransactionReceipt $TX --rpc-url $L1 2>/dev/null) && [ "$R" != null ] && [ -n "$R" ]; do :; done
  echo "$(ts) receipt status=$(echo $R|jq -r .status) block=$(echo $R|jq -r .blockNumber)"
fi
case $MODE in race:*) d=${MODE#race:}; sleep $(printf "%d.%03d" $((d/1000)) $((d%1000)));; esac
# fire relay and concurrently sample finalized state
( echo "$(ts) relay-reply $(cast rpc zone_setLeader $T --rpc-url $RELAY 2>&1)" ) &
FS="$(ts) during finalized=[$(st finalized)] latest=[$(st latest)] finblk=$(cast block finalized -f number --rpc-url $L1)"
wait; echo "$FS"; echo "$(ts) admin receipt $(cast receipt $TX --rpc-url $L1 --json | jq -c "{status,blockNumber}")"
sleep ${POST:-6}
echo "$(ts) post latest=[$(st latest)] finalized=[$(st finalized)]"
