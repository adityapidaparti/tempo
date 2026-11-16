#!/usr/bin/env bash
# Test 1: leader restored from a backup newer than the last settled batch (settlement stalled
# because both followers are down from backup time; zone-rpc is the up-to-date observer).
set -uo pipefail; cd /home/exedev/hunt-logs/repro/restore; source ../keys/common.sh; source lib.sh
for i in 1000 1001 1002; do xfer $i 1 >/dev/null; done
log "start: $(heads) portal=$(portal)"
gstop zone-0; P=$(portal); HB=$(tip zone-1); log "zone-0 stopped: followers at $HB, portal=$P"
gstop zone-1; gstop zone-2; log "followers stopped (lagging at H_b)"
backup zone-0 t1-z0.tgz; log "backup taken"
docker start zone-0 >/dev/null
for i in $(seq 1 60); do [[ $(tip zone-0) -ge $HB ]] && break; sleep 1; done
log "zone-0 restarted: $(heads)"
: > t1-receipts.txt
for i in 1003 1004 1005; do r=$(xfer $i 1000); echo "$i $r" >> t1-receipts.txt; log "xfer $i: $r"; sleep 3; done
for i in $(seq 1 60); do [[ $(tip zone-0) -ge $((HB+40)) ]] && break; sleep 1; done
log "before restore: $(heads) portal=$(portal)"
for h in $((HB+1)) $((HB+2)) $((HB+10)) $((HB+20)); do log "  orig hash@$h zone-0=$(bh zone-0 $h) zone-rpc=$(bh zone-rpc $h)"; done
for h in $((HB+1)) $((HB+2)) $((HB+10)) $((HB+20)); do echo "$h $(bh zone-0 $h)"; done > t1-orig-hashes.txt
L0=$(docker logs zone-0 2>&1 | wc -l); echo $L0 > t1-L0
gstop zone-0; restore zone-0 t1-z0.tgz; docker start zone-0 >/dev/null; log "zone-0 restored from H_b backup and started"
sleep 30
log "after restore 30s: $(heads) portal=$(portal)"
docker logs zone-0 2>&1 | tail -n +$L0 | grep -E "Leader generation started|Promotion barrier|failed to resolve|Batch submitted" | cut -c1-200 | head -5
while read h o; do log "  @$h orig=$o zone-0 now=$(bh zone-0 $h) zone-rpc=$(bh zone-rpc $h)"; done < t1-orig-hashes.txt
while read i r; do tx=${r##*transactionHash=}; tx=${tx%% *}; log "  rcpt $i ($r) zone-0: $(rcpt zone-0 $tx | head -c 60) | zone-rpc: $(rcpt zone-rpc $tx | head -c 60)"; done < t1-receipts.txt
docker logs --since 40s zone-rpc 2>&1 | grep -E "conflict|mismatch|WARN|ERROR" | cut -c1-250 | sort | uniq | head -5
log "starting lagging followers zone-1, zone-2"
docker start zone-1 zone-2 >/dev/null; sleep 60
log "after followers 60s: $(heads) portal=$(portal)"
read PH PHASH <<<"$(portal)"
log "  portal@$PH=$PHASH zone-0=$(bh zone-0 $PH) zone-1=$(bh zone-1 $PH) zone-2=$(bh zone-2 $PH) zone-rpc=$(bh zone-rpc $PH)"
while read h o; do log "  @$h orig=$o z0=$(bh zone-0 $h) z1=$(bh zone-1 $h) z2=$(bh zone-2 $h) rpc=$(bh zone-rpc $h)"; done < t1-orig-hashes.txt
while read i r; do tx=${r##*transactionHash=}; tx=${tx%% *}; for n in zone-0 zone-1 zone-2 zone-rpc; do log "  rcpt $i $n: $(rcpt $n $tx | head -c 50)"; done; done < t1-receipts.txt
for n in zone-1 zone-2 zone-rpc; do echo "== $n"; docker logs --since 70s $n 2>&1 | grep -E "conflict|mismatch|ERROR|WARN" | cut -c1-250 | sort | uniq | head -5; done
