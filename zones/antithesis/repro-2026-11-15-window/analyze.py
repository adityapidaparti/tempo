# analyze.py OUT : lag stats + achieved TPS
import sys, statistics as st
from lib import *
OUT = sys.argv[1]
S = [tuple(map(float, l.split())) for l in open(OUT + ".samples")]
S = [s for s in S if s[1] >= 0 and s[2] >= 0 and s[3] >= 0]
def pct(xs, p): xs = sorted(xs); return xs[min(len(xs) - 1, int(p * len(xs)))]
first = {}
for t, lf, f1, f2 in S:
    for key, v in (("L", lf), ("F1", f1), ("F2", f2)):
        first.setdefault((key, int(v)), t)
lo, hi = int(S[0][1]) + 1, int(S[-1][1]) - 1
res = {}
for fk in ("F1", "F2"):
    blag = [lf - (f1 if fk == "F1" else f2) for t, lf, f1, f2 in S]
    ms = [1000 * (first[(fk, n)] - first[("L", n)]) for n in range(lo, hi + 1) if (fk, n) in first and ("L", n) in first]
    res[fk] = (st.median(blag), pct(blag, .99), max(blag), st.median(ms), pct(ms, .99), max(ms))
D = [tuple(map(float, l.split())) for l in open(OUT + ".durable")]
D = [d for d in D if d[4] >= 0]
dl = [d[2] - d[4] for d in D]  # leader finalized sampled just BEFORE the db read minus durable (lower bound)
dh = [d[3] - d[4] for d in D]  # upper bound
txs = 0
for n in range(lo, hi + 1):
    c = tryrpc("zone-0", "eth_getBlockTransactionCountByNumber", [hex(n)])
    txs += max(0, int(c, 16) - 1) if c else 0
dur = first[("L", hi)] - first[("L", lo)]
print(f"blocks {lo}..{hi} over {dur:.1f}s ({(hi-lo)/dur:.2f} blk/s); user txs {txs} => {txs/dur:.1f} tx/s")
for fk, r in res.items():
    print(f"{fk} lag blocks med/p99/max {r[0]:.0f}/{r[1]:.0f}/{r[2]:.0f}  ms med/p99/max {r[3]:.0f}/{r[4]:.0f}/{r[5]:.0f}")
if D: print(f"durable (db read, n={len(D)}) lag lower-bound med/p99/max {st.median(dl):.0f}/{pct(dl,.99):.0f}/{max(dl):.0f}  upper med/max {st.median(dh):.0f}/{max(dh):.0f}")
