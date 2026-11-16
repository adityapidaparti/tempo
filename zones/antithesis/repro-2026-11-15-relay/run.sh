#!/bin/bash
# usage: run.sh MODE ROUNDS   (MODE=window|control). Runs against the live "keys" compose stack.
MODE=${1:-window}; N=${2:-10}
S=(0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc 0x976EA74026E726554dB657fA54763abd0C3a0aa9 0x14dC79964da2C08b23698B3D3cc7Ca32193d9955)
IP=(10.20.0.11 10.20.0.12 10.20.0.13)
P=0x5ad0000000000000000000000000000000000001
docker cp /home/exedev/hunt-logs/repro/relay/inner.sh zone-rpc:/tmp/inner.sh
for r in $(seq 1 $N); do
  L=$(docker exec -e FOUNDRY_DISABLE_NIGHTLY_WARNING=1 zone-rpc cast call $P 'leader()(address)' -b finalized --rpc-url http://10.20.0.10:8545)
  for i in 0 1 2; do [ "${S[$i],,}" = "${L,,}" ] && a=$i; done
  b=$(( (a + 1 + r % 2) % 3 )); x=$(( 3 - a - b ))
  since=$(date -u +%Y-%m-%dT%H:%M:%SZ)
  echo "=== round $r mode=$MODE A=zone-$a B=zone-$b relay=zone-$x"
  m=$MODE; [ "$MODE" = race ] && m=race:$(( (r*53) % 500 )); t=${S[$a]}; [ "$TGT" = third ] && t=${S[$x]}; echo "  mode=$m target=$t"; docker exec -e POST=${POST:-6} zone-rpc /tmp/inner.sh $m http://${IP[$x]}:8545 ${S[$a]} ${S[$b]} $t
  for z in 0 1 2; do docker logs --since $since zone-$z 2>&1 | grep -E "Leader generation started|Confirmed setLeader" | sed "s/^/  zone-$z: /"; done
done
