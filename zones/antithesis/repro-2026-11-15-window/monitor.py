# monitor.py OUT DURATION_S : samples leader finalized vs follower tips (~25ms) + durable head via db CLI (~1Hz)
import sys, time, threading, subprocess, json, re
from lib import *
OUT = sys.argv[1]; DUR = float(sys.argv[2])
end = time.time() + DUR
f = open(OUT + ".samples", "w"); g = open(OUT + ".durable", "w")
def durable():
    while time.time() < end:
        lf0 = head("zone-0", "finalized")[0]; t0 = time.time()
        p = subprocess.run(["docker", "exec", "zone-0", "tempo-zone", "db", "--chain", "/shared/genesis.json", "--datadir",
                            "/data/node", "get", "mdbx", "StageCheckpoints", "Finish"], capture_output=True, text=True)
        t1 = time.time(); lf1 = head("zone-0", "finalized")[0]
        m = re.search(r'"block_number": (\d+)', p.stdout) or re.search(r'checkpoint_block_number\S*?=\S*?(\d+)', re.sub(r'\x1b\[[0-9;]*m', '', p.stdout + p.stderr)); d = int(m.group(1)) if m else -1
        g.write(f"{t0:.3f} {t1:.3f} {lf0} {lf1} {d}\n"); g.flush()
        time.sleep(0.7)
threading.Thread(target=durable, daemon=True).start()
while time.time() < end:
    t = time.time()
    lf = head("zone-0", "finalized")[0]
    f1 = int(tryrpc("zone-1", "eth_blockNumber", [], 1) or "-0x1", 16)
    f2 = int(tryrpc("zone-2", "eth_blockNumber", [], 1) or "-0x1", 16)
    f.write(f"{t:.3f} {lf} {f1} {f2}\n")
    d = 0.025 - (time.time() - t)
    if d > 0: time.sleep(d)
f.flush()
