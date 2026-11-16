# fund senders 2000..2000+N-1 from 1000..1007 (each workload account funds N/8)
import sys, time
from lib import *
N = int(sys.argv[1]) if len(sys.argv) > 1 else 64
funders = [acct(i) for i in range(1000, 1008)]
hs = []
for k, f in enumerate(funders):
    nn = nonce("zone-0", f.address)
    for j in range(N // 8):
        to = acct(2000 + k * (N // 8) + j).address
        raw, h = sign_transfer(f, nn, to, 20_000_000, gas=500000); nn += 1
        rpc("zone-0", "eth_sendRawTransaction", [raw]); hs.append(h)
for h in hs:
    for _ in range(60):
        r = receipt("zone-0", h)
        if r: break
        time.sleep(0.5)
    assert r and r["status"] == "0x1", (h, r)
print("funded", N)
