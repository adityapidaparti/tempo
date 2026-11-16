# restore-repro helpers (sourced after ../keys/common.sh)
RD=/home/exedev/hunt-logs/repro/restore
PORTAL=0x5ad0000000000000000000000000000000000001; L1=http://10.20.0.10:8545
IMG=tempo-zones-antithesis:pristine
portal() { c zone-rpc sh -c "echo \$(cast call $PORTAL 'zoneHeight()(uint64)' --rpc-url $L1) \$(cast call $PORTAL 'blockHash()(bytes32)' --rpc-url $L1)"; }
bh() { c "$1" cast block "$2" -f hash --rpc-url http://localhost:8545 2>/dev/null || echo none; }
nodepid() { docker exec "$1" sh -c 'for p in /proc/[0-9]*; do c=$(tr "\0" " " < $p/cmdline 2>/dev/null); case "$c" in "/usr/local/bin/tempo-zone node"*) echo ${p#/proc/};; esac; done'; }
# graceful stop: SIGTERM the node; supervisor then exits and the container stops
gstop() { local p; p=$(nodepid $1); docker exec $1 sh -c "kill -TERM $p"; for i in $(seq 1 120); do [[ $(docker inspect -f '{{.State.Running}}' $1) == false ]] && return 0; sleep 0.5; done; log "gstop $1 timeout"; docker stop $1; }
backup() { docker run --rm --entrypoint tar -v keys_$1-data:/data -v $RD:/b $IMG czf /b/$2 -C /data .; }
restore() { docker run --rm --entrypoint sh -v keys_$1-data:/data -v $RD:/b $IMG -c "rm -rf /data/* /data/.[!.]* 2>/dev/null; tar xzf /b/$2 -C /data"; }
xfer() { c zone-0 cast send $T 'transfer(address,uint256)' 0x000000000000000000000000000000000000dEaD $2 --private-key $(wpk $1) --gas-limit 500000 --rpc-url http://localhost:8545 2>&1 | awk '/^(status|blockNumber|blockHash|transactionHash) /{printf "%s=%s ",$1,$2} END{print ""}'; }
heads() { for n in zone-0 zone-1 zone-2 zone-rpc; do echo "$n tip=$(tip $n)"; done | tr '\n' ' '; echo; }
