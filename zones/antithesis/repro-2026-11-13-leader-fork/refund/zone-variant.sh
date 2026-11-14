#!/bin/bash
# Zone variant: requestWithdrawal with zoneFallbackRecipient = virtual address; withdrawal bounces on L1.
source /home/exedev/hunt-logs/repro/keys/common.sh
L1=http://10.20.0.10:8545; ZR=http://localhost:8545
P=0x5ad0000000000000000000000000000000000001; IN=0x1c00000000000000000000000000000000000001; OUT=0x1c00000000000000000000000000000000000002
SEQ=0x9965507D1a55bcC2695C58ba16FB37d819B0A4dc
UPK=$(wpk 1000); U=$(c zone-0 cast wallet address --private-key $UPK)
VFB=0xdeadbeeffdfdfdfdfdfdfdfdfdfd000000000001   # zone fallback (virtual, masterId deadbeef)
VTO=0xcafebabefdfdfdfdfdfdfdfdfdfd000000000002   # L1 destination (virtual, unregistered on L1 -> transfer fails -> bounce)
AMT=100000000
zbal() { c zone-0 cast call $T 'balanceOf(address)(uint256)' $1 --from $1 --rpc-url $ZR 2>&1 | tail -1; }
l1bal() { c zone-0 cast call $T 'balanceOf(address)(uint256)' $1 --rpc-url $L1 | awk '{print $1}'; }
zrefund() { c zone-0 cast call $IN 'refunds(address,address)(uint128)' $T $2 --from $1 --rpc-url $ZR 2>&1 | tail -1; }
log "user U=$U  VFB=$VFB  VTO=$VTO"
log "registry on L1: resolveRecipient(VTO) -> $(c zone-0 cast call 0xfDC0000000000000000000000000000000000000 'resolveRecipient(address)(address)' $VTO --rpc-url $L1 2>&1 | tail -1)"
log "zone transfer-to-VFB sim: $(c zone-0 cast call $T 'transfer(address,uint256)(bool)' $VFB 1 --from $U --rpc-url $ZR 2>&1 | tail -1)"
log "BEFORE: U zone bal=$(zbal $U) zone totalSupply=$(c zone-0 cast call $T 'totalSupply()(uint256)' --from $U --rpc-url $ZR 2>&1|tail -1) portal L1 escrow=$(l1bal $P) L1 bal(VTO)=$(l1bal $VTO)"
FEE=$(c zone-0 cast call $OUT 'calculateWithdrawalFee(uint64)(uint128)' 0 --from $U --rpc-url $ZR | awk '{print $1}'); log "withdrawal fee=$FEE"
c zone-0 cast send $T 'approve(address,uint256)' $OUT 0xffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff --private-key $UPK --gas-limit 500000 --rpc-url $ZR 2>&1 | grep -E '^(status|transactionHash)'
L1FROM=$(c zone-0 cast block-number --rpc-url $L1)
log "requestWithdrawal(T, VTO, $AMT, 0, 0, VFB, 0x, 0x)"
c zone-0 cast send $OUT 'requestWithdrawal(address,address,uint128,bytes32,uint64,address,bytes,bytes)' $T $VTO $AMT 0x0000000000000000000000000000000000000000000000000000000000000000 0 $VFB 0x 0x --private-key $UPK --gas-limit 10000000 --rpc-url $ZR 2>&1 | grep -E '^(status|transactionHash|blockNumber)'
log "AFTER request: U zone bal=$(zbal $U)"
log "waiting for L1 WithdrawalProcessed(VTO) ..."
for i in $(seq 1 120); do
  L=$(c zone-0 cast logs --from-block $L1FROM --address $P 'WithdrawalProcessed(address indexed,bytes32 indexed,address,uint128,bool)' --rpc-url $L1 2>/dev/null)
  echo "$L" | grep -qi "${VTO#0x}" && break; sleep 3; done
echo "$L" | grep -iE "transactionHash|data|topics" -A0 | head -8
log "waiting for zone WithdrawalBounceBackPending ..."
for i in $(seq 1 120); do
  ZL=$(c zone-0 cast logs --from-block 0 --address $IN 'WithdrawalBounceBackPending(address indexed,address,uint128)' $VFB --rpc-url $ZR 2>/dev/null)
  [ -n "$ZL" ] && break; sleep 3; done
echo "$ZL" | grep -E "transactionHash|data|blockNumber"
log "parked: refunds(T,VFB) viewed by sequencer=$(zrefund $SEQ $VFB)  viewed as VFB=$(zrefund $VFB $VFB)  refunds(T,U)=$(zrefund $U $U)"
log "claimRefund sim from U:   $(c zone-0 cast call $IN 'claimRefund(address)(uint128)' $T --from $U --rpc-url $ZR 2>&1 | tail -1)"
log "claimRefund sim from VFB: $(c zone-0 cast call $IN 'claimRefund(address)(uint128)' $T --from $VFB --rpc-url $ZR 2>&1 | tail -1)"
log "claimRefund real tx from U:"; c zone-0 cast send $IN 'claimRefund(address)' $T --private-key $UPK --gas-limit 500000 --rpc-url $ZR 2>&1 | grep -E '^(status|transactionHash)|rror' | head -3
log "FINAL: U zone bal=$(zbal $U) VFB zone bal=$(zbal $VFB) zone totalSupply=$(c zone-0 cast call $T 'totalSupply()(uint256)' --from $U --rpc-url $ZR 2>&1|tail -1) portal L1 escrow=$(l1bal $P) L1 bal(VTO)=$(l1bal $VTO)"
