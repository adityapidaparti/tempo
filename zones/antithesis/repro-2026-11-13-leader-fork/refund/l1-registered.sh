#!/bin/bash
# L1 variant with a REGISTERED master: refund to V parks only because the master's own TIP-1028 receive
# policy temporarily blocks the portal. Control: same flow with refund recipient = master itself.
# usage: l1-registered.sh <salt>
source /home/exedev/hunt-logs/repro/keys/common.sh
L1=http://10.20.0.10:8545; P=0x5ad0000000000000000000000000000000000001; AR=0xfDC0000000000000000000000000000000000000; REG=0x403c000000000000000000000000000000000000
M="test test test test test test test test test test test junk"
MPK=$(c zone-0 cast wallet private-key --mnemonic "$M" --mnemonic-index 18); MA=$(c zone-0 cast wallet address --private-key $MPK)
UPK=$(c zone-0 cast wallet private-key --mnemonic "$M" --mnemonic-index 19); U=$(c zone-0 cast wallet address --private-key $UPK)
SALT=$1; AMT=30000000
l1bal() { c zone-0 cast call $T 'balanceOf(address)(uint256)' $1 --rpc-url $L1 | awk '{print $1}'; }
refund() { c zone-0 cast call $P 'refunds(address,address)(uint128)' $T $1 --rpc-url $L1 | awk '{print $1}'; }
send() { c zone-0 cast send "$@" --rpc-url $L1 2>&1 | grep -E '^(status|transactionHash)|rror' | tr '\n' ' '; echo; }
GX=0x79BE667EF9DCBBAC55A06295CE870B07029BFCDB2DCE28D959F2815B16F81798
bad_deposit() { # $1 refund recipient
  local CT=0x$(head -c 64 /dev/urandom | xxd -p | tr -d '\n') N=0x$(head -c 12 /dev/urandom | xxd -p) TG=0x$(head -c 16 /dev/urandom | xxd -p)
  send $T 'approve(address,uint256)' $P $AMT --private-key $UPK >/dev/null
  log "deposit(refund=$1): $(send $P 'deposit(address,uint128,uint256,(bytes32,uint8,bytes,bytes12,bytes16),address)' $T $AMT 0 "($GX,2,$CT,$N,$TG)" $1 --private-key $UPK --gas-limit 3000000)"
  for i in $(seq 1 60); do [ "$(refund $1)" != "0" ] && break; sleep 2; done
  local L=$(c zone-0 cast logs --from-block 1 --address $P 'DepositBounceBackPending(address indexed,address,uint128,uint128)' $1 --rpc-url $L1 2>/dev/null | grep transactionHash | tail -1)
  log "  bounce tx: $L ; refunds(T,$1)=$(refund $1)"
}
log "master MA=$MA depositor U=$U salt=$SALT"
log "registerVirtualMaster: $(send $AR 'registerVirtualMaster(bytes32)' $SALT --private-key $MPK --gas-limit 1000000)"
MID=$(c zone-0 cast keccak $(c zone-0 cast concat-hex $MA $SALT) | cut -c11-18)
V=0x${MID}fdfdfdfdfdfdfdfdfdfd000000000004
log "masterId=0x$MID getMaster=$(c zone-0 cast call $AR 'getMaster(bytes4)(address)' 0x$MID --rpc-url $L1)  V=$V resolveRecipient(V)=$(c zone-0 cast call $AR 'resolveRecipient(address)(address)' $V --rpc-url $L1 2>&1|tail -1)"
log "master blocks inbound (setReceivePolicy(0 REJECT_ALL,1,0)): $(send $REG 'setReceivePolicy(uint64,uint64,address)' 0 1 0x0000000000000000000000000000000000000000 --private-key $MPK --gas-limit 1000000)"
log "validateReceivePolicy(T,portal,MA)=$(c zone-0 cast call $REG 'validateReceivePolicy(address,address,address)(bool,uint8)' $T $P $MA --rpc-url $L1 | tr '\n' ' ')"
log "BEFORE: U=$(l1bal $U) MA=$(l1bal $MA) portal=$(l1bal $P)"
bad_deposit $V      # case A: refund recipient = V (virtual -> MA)
bad_deposit $MA     # case B (control): refund recipient = MA directly
log "master lifts block (setReceivePolicy(1,1,0)): $(send $REG 'setReceivePolicy(uint64,uint64,address)' 1 1 0x0000000000000000000000000000000000000000 --private-key $MPK --gas-limit 1000000)"
log "validateReceivePolicy(T,portal,MA)=$(c zone-0 cast call $REG 'validateReceivePolicy(address,address,address)(bool,uint8)' $T $P $MA --rpc-url $L1 | tr '\n' ' ')"
log "claimRefund sim from V (if V could sign): $(c zone-0 cast call $P 'claimRefund(address)(uint128)' $T --from $V --rpc-url $L1 2>&1|tail -1)"
log "claimRefund tx from MA: $(send $P 'claimRefund(address)' $T --private-key $MPK --gas-limit 500000)"
log "claimRefund tx from U:  $(send $P 'claimRefund(address)' $T --private-key $UPK --gas-limit 500000)"
log "FINAL: refunds(T,V)=$(refund $V) refunds(T,MA)=$(refund $MA) refunds(T,U)=$(refund $U) U=$(l1bal $U) MA=$(l1bal $MA) portal=$(l1bal $P)"
