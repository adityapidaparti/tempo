#!/bin/bash
# L1 variant: deposit with tempoRefundRecipient = unregistered virtual address and an undecryptable payload.
source /home/exedev/hunt-logs/repro/keys/common.sh
L1=http://10.20.0.10:8545; ZR=http://localhost:8545
P=0x5ad0000000000000000000000000000000000001; AR=0xfDC0000000000000000000000000000000000000; ADMIN=0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266
M="test test test test test test test test test test test junk"
UPK=$(c zone-0 cast wallet private-key --mnemonic "$M" --mnemonic-index 19); U=$(c zone-0 cast wallet address --private-key $UPK)
V=0xfeedfacefdfdfdfdfdfdfdfdfdfd000000000003; MASTER_ID=0xfeedface
AMT=50000000
l1bal() { c zone-0 cast call $T 'balanceOf(address)(uint256)' $1 --rpc-url $L1 | awk '{print $1}'; }
refund() { c zone-0 cast call $P 'refunds(address,address)(uint128)' $T $1 --rpc-url $L1 | awk '{print $1}'; }
log "U=$U V=$V"
log "decodeVirtualAddress(V)=$(c zone-0 cast call $AR 'decodeVirtualAddress(address)(bool,bytes4,bytes6)' $V --rpc-url $L1 | tr '\n' ' ') getMaster($MASTER_ID)=$(c zone-0 cast call $AR 'getMaster(bytes4)(address)' $MASTER_ID --rpc-url $L1) resolveRecipient(V)=$(c zone-0 cast call $AR 'resolveRecipient(address)(address)' $V --rpc-url $L1 2>&1|tail -1)"
KI=$(( $(c zone-0 cast call $P 'encryptionKeyCount()(uint256)' --rpc-url $L1 | awk '{print $1}') - 1 ))
log "keyIndex=$KI depositFee=$(c zone-0 cast call $P 'calculateDepositFee()(uint128)' --rpc-url $L1) bouncebackFee=$(c zone-0 cast call $P 'calculateBouncebackFee()(uint128)' --rpc-url $L1)"
log "BEFORE: U L1 bal=$(l1bal $U) portal escrow=$(l1bal $P) admin=$(l1bal $ADMIN) refunds(T,V)=$(refund $V) refunds(T,U)=$(refund $U)"
c zone-0 cast send $T 'approve(address,uint256)' $P $AMT --private-key $UPK --rpc-url $L1 2>&1 | grep -E '^(status|transactionHash)'
GX=0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798   # secp256k1 G: valid point, wrong ECDH -> undecryptable
CT=0x$(head -c 64 /dev/urandom | xxd -p | tr -d '\n'); NONCE=0x$(head -c 12 /dev/urandom | xxd -p); TAG=0x$(head -c 16 /dev/urandom | xxd -p)
L1FROM=$(c zone-0 cast block-number --rpc-url $L1)
log "deposit(T,$AMT,$KI,(G.x,2,rand64,rand12,rand16),V)"
c zone-0 cast send $P 'deposit(address,uint128,uint256,(bytes32,uint8,bytes,bytes12,bytes16),address)' $T $AMT $KI "($GX,2,$CT,$NONCE,$TAG)" $V --private-key $UPK --gas-limit 3000000 --rpc-url $L1 2>&1 | grep -E '^(status|transactionHash|blockNumber)'
log "AFTER deposit: U L1 bal=$(l1bal $U) portal escrow=$(l1bal $P)"
log "waiting for zone DepositFailed and L1 DepositBounceBackPending(V) ..."
for i in $(seq 1 120); do
  L=$(c zone-0 cast logs --from-block $L1FROM --address $P 'DepositBounceBackPending(address indexed,address,uint128,uint128)' $V --rpc-url $L1 2>/dev/null)
  [ -n "$L" ] && break; sleep 3; done
echo "$L" | grep -E "transactionHash|data|blockNumber"
log "parked: refunds(T,V)=$(refund $V) refunds(T,U)=$(refund $U)"
log "claimRefund sim from U (depositor): $(c zone-0 cast call $P 'claimRefund(address)(uint128)' $T --from $U --rpc-url $L1 2>&1 | tail -1)"
log "claimRefund sim from V:             $(c zone-0 cast call $P 'claimRefund(address)(uint128)' $T --from $V --rpc-url $L1 2>&1 | tail -1)"
log "claimRefund real tx from U:"; c zone-0 cast send $P 'claimRefund(address)' $T --private-key $UPK --gas-limit 500000 --rpc-url $L1 2>&1 | grep -E '^(status|transactionHash)|rror' | head -3
log "FINAL: U L1 bal=$(l1bal $U) V bal=$(l1bal $V) portal escrow=$(l1bal $P) admin=$(l1bal $ADMIN) refunds(T,V)=$(refund $V)"
