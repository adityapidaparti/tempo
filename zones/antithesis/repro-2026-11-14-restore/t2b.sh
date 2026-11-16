#!/usr/bin/env bash
# Test 2b: restored leader (zone-0) + restored follower (zone-1), backups taken together at H_b.
# zone-1 is down from backup to restore (equivalent to restoring it); zone-2 + zone-rpc stay up with
# the original chain. Settlement is held below H_b by a slow disk (slowsync shim) on zone-2 only.
# zone-1 is started 10s after the restored leader.
set -uo pipefail; cd /home/exedev/hunt-logs/repro/restore; source ../keys/common.sh; source lib.sh
fs() { docker exec zone-rpc sh -c "echo $2 > /fault-control/fsync-$1" 2>/dev/null || docker exec workload sh -c "echo $2 > /fault-control/fsync-$1"; }
for i in 1000 1001 1002; do xfer $i 1 >/dev/null; done
log "start: $(heads) portal=$(portal)"
gstop zone-0; HB=$(tip zone-1); log "zone-0 stopped; H_b=$HB portal=$(portal)"
gstop zone-1; backup zone-0 t2b-z0.tgz; backup zone-1 t2b-z1.tgz; log "backups at H_b=$HB; zone-1 stays down until restore"
fs 2 60000; log "slow disk on zone-2 (holds settlement below H_b; zone-1 down)"
docker start zone-0 >/dev/null
for i in $(seq 1 90); do [[ $(tip zone-0) -ge $((HB+2)) ]] && break; sleep 1; done
: > t2b-receipts.txt
for i in 1003 1004 1005; do r=$(xfer $i 1000); echo "$i $r" >> t2b-receipts.txt; log "xfer $i: $r"; sleep 3; done
for i in $(seq 1 60); do [[ $(tip zone-0) -ge $((HB+40)) ]] && break; sleep 1; done
sup 0 kill; sleep 1; log "zone-0 SIGKILLed: $(heads) portal=$(portal)"
for h in $((HB+1)) $((HB+5)) $((HB+15)) $((HB+30)); do echo "$h $(bh zone-rpc $h)"; done > t2b-orig-hashes.txt
while read h o; do log "  orig @$h rpc=$o z1=$(bh zone-1 $h) z2=$(bh zone-2 $h)"; done < t2b-orig-hashes.txt
fs 2 0; docker stop zone-0 >/dev/null
restore zone-0 t2b-z0.tgz; restore zone-1 t2b-z1.tgz; docker start zone-0 >/dev/null; sleep 10; log "zone-0 restored+started: $(heads)"; docker start zone-1 >/dev/null; log "zone-1 restored (H_b) and started"
sleep 75
log "after 75s: $(heads) portal=$(portal)"
docker logs --since 80s zone-0 2>&1 | grep -E "Leader generation started|Promotion barrier|failed to resolve" | cut -c1-200 | head -3
docker logs -t --since 80s zone-0 2>&1 | grep "Batch submitted" | head -3 | sed -E 's/.*tempo_block=([0-9]+).*prev_block_hash=(0x[0-9a-f]+).*next_block_hash=(0x[0-9a-f]+).*/batch prev=\2 next=\3/'
FIRST=$(docker logs --since 80s zone-0 2>&1 | grep "Batch submitted" | head -1 | sed -E 's/.*next_block_hash=(0x[0-9a-f]+).*/\1/')
N=$(c zone-0 cast block $FIRST -f number --rpc-url http://localhost:8545); log "first settled batch after restore: zone block #$N hash=$FIRST; zone-2#$N=$(bh zone-2 $N) zone-rpc#$N=$(bh zone-rpc $N)"
while read h o; do log "  @$h orig=$o z0=$(bh zone-0 $h) z1=$(bh zone-1 $h) z2=$(bh zone-2 $h) rpc=$(bh zone-rpc $h)"; done < t2b-orig-hashes.txt
while read i r; do tx=${r##*transactionHash=}; tx=${tx%% *}; for n in zone-0 zone-1 zone-2 zone-rpc; do log "  rcpt $i $n: $(rcpt $n $tx | head -c 40)"; done; done < t2b-receipts.txt
for n in zone-1 zone-2 zone-rpc; do echo "== $n"; docker logs --since 80s $n 2>&1 | grep -E "conflict|mismatch|ERROR|Rejected settlement" | cut -c1-230 | sort | uniq | head -4; done
