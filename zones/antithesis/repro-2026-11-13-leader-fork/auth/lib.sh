# auth repro helpers (sourced after keys/common.sh)
A=/home/exedev/hunt-logs/repro/auth
# l1delay <node> <ms>: netem delay on node's egress to its L1 proxy (dst 10.20.0.(41+n):8546 only)
l1delay() {
  local pid; pid=$(docker inspect -f '{{.State.Pid}}' zone-$1)
  sudo nsenter -t $pid -n sh -c "tc qdisc del dev eth0 root 2>/dev/null; tc qdisc add dev eth0 root handle 1: prio && tc qdisc add dev eth0 parent 1:3 handle 30: netem delay ${2}ms && tc filter add dev eth0 protocol ip parent 1:0 prio 3 u32 match ip dst 10.20.0.$((41+$1))/32 match ip dport 8546 0xffff flowid 1:3"
}
l1clear() { local pid; pid=$(docker inspect -f '{{.State.Pid}}' zone-$1); sudo nsenter -t $pid -n tc qdisc del dev eth0 root 2>/dev/null; true; }
l1show() { local pid; pid=$(docker inspect -f '{{.State.Pid}}' zone-$1); sudo nsenter -t $pid -n tc -s qdisc show dev eth0; }
newkey() { # sets VPK V KPK KA; authorizes K for V (V = workload account index $1)
  VPK=$(wpk $1); V=$(c zone-0 cast wallet address $VPK)
  KPK=$(c zone-0 cast keccak 0x$(printf 'auth-%s' $(date +%s%N) | xxd -p)); KA=$(c zone-0 cast wallet address $KPK)
  c zone-0 cast send $KC 'authorizeKey(address,uint8,(uint64,bool,(address,uint256,uint64)[],bool,(address,(bytes4,address[])[])[]))' $KA 0 "(9999999999,false,[],true,[])" --private-key $VPK --gas-limit 1000000 --rpc-url http://localhost:8545 2>&1 | grep -E '^(status|blockNumber)' | tr '\n' ' '; echo
}
# userspace delay relay (kernel has no netem): zone-N's L1 traffic DNAT'd via host relay
relay_install() { # node
  local n=$1 pid; pid=$(docker inspect -f '{{.State.Pid}}' zone-$n); echo 0 > $A/delay-$n
  pkill -f "relay.py 1854$n" ; RELAYLOG=1 nohup python3 -I $A/relay.py 1854$n 10.20.0.$((41+n)) $A/delay-$n > $A/relay-$n.log 2>&1 &
  sleep 1
  sudo nsenter -t $pid -n iptables -t nat -A OUTPUT -d 10.20.0.$((41+n))/32 -p tcp --dport 8546 -j DNAT --to-destination 10.20.0.1:1854$n
  sup $n kill; sleep 3; sup $n start
}
l1delay() { echo $2 > $A/delay-$1; }
l1clear() { echo 0 > $A/delay-$1; }
l1delayport() { echo "$2 $3" > $A/delay-$1; } # node ms srcport
