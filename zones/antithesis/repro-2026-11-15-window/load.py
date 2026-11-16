# rate-limited transfer load: load.py RATE DURATION_S [target] ; senders 2000..2063
import sys, os, time, threading, random
from lib import *
RATE = float(sys.argv[1]); DUR = float(sys.argv[2]); TGT = sys.argv[3] if len(sys.argv) > 3 else "zone-0"
W = int(os.environ.get("W", "32"))
senders = [acct(i) for i in range(2000, 2064)]
addrs = [a.address for a in senders]
ok = [0] * W; err = [0] * W; lasterr = [""] * W
stop_at = time.time() + DUR
def worker(w):
    mine = senders[w::W]; nn = {}
    per = RATE / W; t0 = time.time(); k = 0
    while time.time() < stop_at:
        a = mine[k % len(mine)]
        target_t = t0 + k / per
        d = target_t - time.time()
        if d > 0: time.sleep(d)
        k += 1
        try:
            if a.address not in nn: nn[a.address] = nonce(TGT, a.address)
            raw, h = sign_transfer(a, nn[a.address], random.choice(addrs), 1, gas=300000 if nn[a.address] == 0 else 160000)
            rpc(TGT, "eth_sendRawTransaction", [raw], timeout=2)
            nn[a.address] += 1; ok[w] += 1
        except Exception as e:
            err[w] += 1; lasterr[w] = str(e)[:80]; nn.pop(a.address, None)
            if "nonce" not in str(e) and "known" not in str(e): time.sleep(0.2)
            t0 = time.time(); k = 0  # do not burst after an outage
ts = [threading.Thread(target=worker, args=(w,), daemon=True) for w in range(W)]
[t.start() for t in ts]
prev = 0
while any(t.is_alive() for t in ts):
    time.sleep(5); s = sum(ok)
    log(f"load rate={RATE} sent_ok={s} (+{(s-prev)/5:.1f}/s) err={sum(err)} last={[e for e in lasterr if e][:1]}"); prev = s
