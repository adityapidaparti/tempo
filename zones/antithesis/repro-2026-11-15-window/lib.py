import json, time, subprocess, requests
from eth_account import Account
from eth_utils import keccak
CHAIN = 5742371274753
from eth_utils import to_checksum_address
TOKEN = to_checksum_address('0x20c0000000000000000000000000000000000000')
IP = {"zone-0": "10.20.0.11", "zone-1": "10.20.0.12", "zone-2": "10.20.0.13", "zone-rpc": "10.20.0.20"}
NODES = ["zone-0", "zone-1", "zone-2", "zone-rpc"]
_sess = {}
def url(n): return f"http://{IP[n]}:8545"
def rpc(n, method, params=(), timeout=3):
    s = _sess.setdefault(n, requests.Session())
    r = s.post(url(n), json={"jsonrpc": "2.0", "id": 1, "method": method, "params": list(params)}, timeout=timeout)
    j = r.json()
    if "error" in j: raise RuntimeError(j["error"].get("message"))
    return j["result"]
def tryrpc(n, method, params=(), timeout=3):
    try: return rpc(n, method, params, timeout)
    except Exception: return None
def wkey(i):
    return "0x" + keccak(b"tempo-zone-antithesis-workload" + i.to_bytes(4, "big")).hex()
def acct(i): return Account.from_key(wkey(i))
def transfer_data(to, amt):
    return "0xa9059cbb" + to[2:].lower().rjust(64, "0") + hex(amt)[2:].rjust(64, "0")
def sign_transfer(a, nonce, to, amt=1, gas=300000):
    tx = {"chainId": CHAIN, "nonce": nonce, "to": TOKEN, "value": 0, "data": transfer_data(to, amt),
          "gas": gas, "maxFeePerGas": 2, "maxPriorityFeePerGas": 1, "type": 2}
    s = a.sign_transaction(tx)
    raw = s.raw_transaction if hasattr(s, "raw_transaction") else s.rawTransaction
    return "0x" + raw.hex().removeprefix("0x"), "0x" + s.hash.hex().removeprefix("0x")
def nonce(n, addr, tag="pending"): return int(rpc(n, "eth_getTransactionCount", [addr, tag]), 16)
def head(n, tag="latest"):
    b = tryrpc(n, "eth_getBlockByNumber", [tag, False], 1)
    return (int(b["number"], 16), b["hash"]) if b else (-1, None)
def receipt(n, h):
    r = tryrpc(n, "eth_getTransactionReceipt", [h], 2)
    return r
def blockhash(n, num):
    b = tryrpc(n, "eth_getBlockByNumber", [hex(num), False], 2)
    return b["hash"] if b else None
def zpid(c="zone-0"):
    out = subprocess.run(["docker", "top", c, "-eo", "pid,args"], capture_output=True, text=True).stdout
    for l in out.splitlines():
        if "tempo-zone node" in l: return int(l.split()[0])
    return None
def log(*a): print(f"[{time.strftime('%H:%M:%S')}.{int(time.time()*1000)%1000:03d}]", *a, flush=True)
