# exp.py MODE ITERS RATE TAG
#   MODE=kill[:D]  : receipt -> (D ms later) SIGKILL of leader's tempo-zone (from host)
#   MODE=term:G    : receipt -> SIGTERM, then SIGKILL after G s if still alive (G=inf: never)
# Background load (load.py RATE) targets the leader throughout. Results in exp-TAG.jsonl
import sys, time, subprocess, json, os, threading, re
from lib import *
MODE, ITERS, RATE, TAG = sys.argv[1], int(sys.argv[2]), float(sys.argv[3]), sys.argv[4]
PROBE = acct(int(os.environ.get("PROBE", "1007")))
DEAD = "0x000000000000000000000000000000000000dEaD"
out = open(f"exp-{TAG}.jsonl", "a")
load = subprocess.Popen(["venv/bin/python", "load.py", str(RATE), "100000"], stdout=open(f"load-exp-{TAG}.log", "w"), stderr=subprocess.STDOUT) if RATE > 0 else None
def wait_healthy(minh=0, to=300):
    t = time.time()
    while time.time() - t < to:
        h = head("zone-0", "finalized")[0]
        if h >= minh and h > 0: return h
        time.sleep(0.5)
    return -1
def durable_offline():
    p = subprocess.run(["docker", "run", "--rm", "--entrypoint", "tempo-zone", "-v", "keys_zone-0-data:/data", "-v", "keys_shared:/shared:ro",
        "tempo-zones-antithesis:pristine", "db", "--chain", "/shared/genesis.json", "--datadir", "/data/node", "get", "mdbx", "StageCheckpoints", "Finish"],
        capture_output=True, text=True)
    m = re.search(r'"block_number": (\d+)', p.stdout) or re.search(r'checkpoint_block_number\S*?=\S*?(\d+)', re.sub(r'\x1b\[[0-9;]*m', '', p.stdout + p.stderr)); 
    if not m: open(f"durable-fail-{TAG}.log", "a").write(re.sub(r'\x1b\[[0-9;]*m', '', p.stdout + p.stderr)[-3000:] + "\n=====\n")
    return int(m.group(1)) if m else -1
def shutdown_logs(since):
    p = subprocess.run(["docker", "logs", "--timestamps", "--since", since, "zone-0"], capture_output=True, text=True)
    return [l for l in (p.stdout + p.stderr).splitlines() if re.search(r"Shutdown signal|flushing|shut ?down|Persist|persist|panick|exit", l, re.I)][-12:]
time.sleep(15)
for it in range(ITERS):
    r = {"it": it, "mode": MODE, "rate": RATE}
    wait_healthy(); time.sleep(8)
    pid = zpid()
    # track every (height -> hash) the leader reports as finalized until it dies
    seen = {}; stop = threading.Event()
    def track():
        while not stop.is_set():
            n, h = head("zone-0", "finalized")
            if n > 0: seen[n] = h
            time.sleep(0.02)
    th = threading.Thread(target=track, daemon=True); th.start()
    nn = nonce("zone-0", PROBE.address)
    raw, txh = sign_transfer(PROBE, nn, DEAD, 7 + it + int(time.time()) % 100000, gas=300000 if nn == 0 else 160000)
    t0 = time.time(); rpc("zone-0", "eth_sendRawTransaction", [raw])
    rc = None
    while time.time() - t0 < 20 and not rc:
        rc = receipt("zone-0", txh)
        if not rc: time.sleep(0.002)
    if not rc:
        r["skip"] = "no receipt"; stop.set(); out.write(json.dumps(r) + "\n"); out.flush(); continue
    tr = time.time(); since = time.strftime("%Y-%m-%dT%H:%M:%S", time.gmtime(tr - 1))
    bn = int(rc["blockNumber"], 16); bh = rc["blockHash"]
    if MODE.startswith("kill"):
        if ":" in MODE: time.sleep(float(MODE.split(":")[1]) / 1000)
        subprocess.run(["sudo", "kill", "-KILL", str(pid)])
        tk = time.time(); r["sig_after_receipt_ms"] = round(1000 * (tk - tr), 1)
        while os.path.exists(f"/proc/{pid}"): time.sleep(0.005)
        texit = time.time()
    else:
        G = float(MODE.split(":")[1])
        subprocess.run(["sudo", "kill", "-TERM", str(pid)])
        tk = time.time(); r["sig_after_receipt_ms"] = round(1000 * (tk - tr), 1); killed = False
        while os.path.exists(f"/proc/{pid}"):
            if time.time() - tk > G and not killed:
                subprocess.run(["sudo", "kill", "-KILL", str(pid)]); killed = True; r["sigkill_sent"] = True
            time.sleep(0.005)
        texit = time.time(); r["exit_after_term_s"] = round(texit - tk, 3); r["sigkill_needed"] = killed
    stop.set(); th.join()
    r.update(tx=txh, bn=bn, receipt_fin=max(seen) if seen else None, last_seen_fin=max(seen) if seen else None)
    # wait for the container (supervisor exits when its child dies unexpectedly)
    for _ in range(200):
        if subprocess.run(["docker", "inspect", "-f", "{{.State.Running}}", "zone-0"], capture_output=True, text=True).stdout.strip() == "false": break
        time.sleep(0.1)
    if not MODE.startswith("kill"):
        r["logs"] = shutdown_logs(since)
        m = [l for l in r["logs"] if "Shutdown signal received" in l]
        if m:
            ts = m[-1].split()[0]; from datetime import datetime, timezone
            tsig = datetime.strptime(ts[:26], "%Y-%m-%dT%H:%M:%S.%f").replace(tzinfo=timezone.utc).timestamp()
            r["flush_log_to_exit_s"] = round(texit - tsig, 3)
    r["durable_at_death"] = durable_offline()
    r["unpersisted_blocks_at_death"] = r["last_seen_fin"] - r["durable_at_death"]
    r["tx_block_durable"] = r["durable_at_death"] >= bn
    subprocess.run(["docker", "start", "zone-0"], capture_output=True)
    ts = time.time()
    h = wait_healthy(r["last_seen_fin"] + 10, 600); r["restart_to_past_s"] = round(time.time() - ts, 1)
    # catch-up: followers past the old head too
    for _ in range(120):
        if min(int(tryrpc(n, "eth_blockNumber") or "-0x1", 16) for n in NODES) > r["last_seen_fin"] + 5: break
        time.sleep(1)
    time.sleep(15)
    rcs = {n: receipt(n, txh) for n in NODES}
    def cls():
        got = [x for x in rcs.values() if x]
        if not got: return "lost"
        x = rcs["zone-0"] or got[0]
        return "kept" if x["blockHash"] == bh else "moved"
    r["outcome"] = cls()
    if r["outcome"] == "lost":   # guard against RPC lag: re-check after 30 s and confirm nonce
        time.sleep(30); rcs = {n: receipt(n, txh) for n in NODES}; r["outcome"] = cls()
        r["probe_nonce_latest"] = {n: tryrpc(n, "eth_getTransactionCount", [PROBE.address, "latest"]) for n in NODES}; r["probe_nonce_sent"] = nn
    r["new_bn"] = {n: (int(x["blockNumber"], 16) if x else None) for n, x in rcs.items()}
    # lost reported-finalized blocks + follower forks
    lo = min(seen) if seen else bn
    rewritten = [k for k in sorted(seen) if blockhash("zone-0", k) != seen[k]]
    r["reported_finalized_rewritten"] = len(rewritten); r["rewritten_range"] = [rewritten[0], rewritten[-1]] if rewritten else None
    forks = {}
    for n in ("zone-1", "zone-2", "zone-rpc"):
        bad = [k for k in range(lo, r["last_seen_fin"] + 6) if blockhash(n, k) != blockhash("zone-0", k)]
        if bad: forks[n] = [bad[0], bad[-1], len(bad)]
    r["follower_forks"] = forks
    r["followers_got_lost_block"] = {n: [k for k in rewritten if blockhash(n, k) == seen[k]] for n in ("zone-1", "zone-2", "zone-rpc")} if rewritten else {}
    log(json.dumps({k: v for k, v in r.items() if k != "logs"}))
    out.write(json.dumps(r) + "\n"); out.flush()
if load: load.terminate()
