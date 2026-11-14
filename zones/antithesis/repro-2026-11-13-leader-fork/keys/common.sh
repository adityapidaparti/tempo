# shared helpers for keychain repros (sourced)
R=/home/exedev/hunt-logs/repro; K=$R/keys; Z=/home/exedev/src/wt/hunt/contrib/antithesis/zones
export ZONES_IMAGE=tempo-zones-antithesis:pristine WORKLOAD_IMAGE=tempo-zones-antithesis-workload:pristine
DC="docker compose -p keys -f $Z/docker-compose.yaml"
E="-e FOUNDRY_DISABLE_NIGHTLY_WARNING=1"; T=0x20c0000000000000000000000000000000000000
KC=0xAAAAAAAA00000000000000000000000000000000
log() { echo "[$(date +%T)] $*"; }
c() { docker exec $E "$@"; }
tip() { c "$1" cast block-number --rpc-url http://localhost:8545 2>/dev/null || echo -1; }
rcpt() { c "$1" cast rpc eth_getTransactionReceipt "$2" --rpc-url http://localhost:8545 2>/dev/null | head -c 120; }
ctl() { docker exec zone-2 sh -c "printf '%s' '$2' > /fault-control/.$1.tmp && mv /fault-control/.$1.tmp /fault-control/$1"; }
REQ_ID=$(date +%s%N); sup() { REQ_ID=$((REQ_ID+1)); ctl "zone-$1.request" "{\"id\":$REQ_ID,\"action\":\"$2\"}"; }
pre=$(printf 'tempo-zone-antithesis-workload' | xxd -p | tr -d '\n')
wpk() { c zone-0 cast keccak 0x${pre}$(printf '%08x' $1); }
up() {
  $DC down -v >/dev/null 2>&1; $DC up -d >/dev/null 2>&1
  until docker logs workload 2>&1 | grep -q 'zone replicated'; do sleep 5; done
  docker exec workload /opt/antithesis/test/v1/zone_payments/first_seed | tail -n 1
}
# getKey(V,K) as V on node $1 -> "(sigType, keyId, expiry, enforceLimits, isRevoked)"
getkey() { c "$1" cast call $KC 'getKey(address,address)((uint8,address,uint64,bool,bool))' "$2" "$3" --from "$2" --rpc-url http://localhost:8545 2>&1 | tail -n1; }
# token signed by access key $1 (pk) for root account $2; chain id $3 ; prints hex
mktoken() {
  local kpk=$1 v=$2 cid=$3 now; now=$(date +%s)
  local fields; fields=$(printf '00%08x%016x%016x%016x' 0 $cid $((now-5)) $((now+3000)))
  local magic; magic=$(printf 'TempoZoneRPC' | xxd -p)$(printf '0%.0s' $(seq 1 40))
  local digest; digest=$(c zone-0 cast keccak 0x${magic}${fields})
  local inner; inner=$(c zone-0 cast keccak 0x04${digest#0x}${v#0x})
  local sig; sig=$(c zone-0 cast wallet sign --no-hash --private-key $kpk $inner)
  echo 0x04${v#0x}${sig#0x}${fields}
}
# HTTP redacted RPC call: node ip, token, json body -> "HTTP <code> <body>"
rrpc() { curl -s -m 10 -o /tmp/rrpc.$$ -w '%{http_code}' -H "content-type: application/json" -H "x-authorization-token: $2" -d "$3" http://$1:8544/; echo " $(head -c 300 /tmp/rrpc.$$)"; }
