import json,time,urllib.request,sys
U="http://10.20.0.10:8545"
def b(m):
    q=[{"jsonrpc":"2.0","id":i,"method":"eth_getBlockByNumber","params":[t,False]} for i,t in enumerate(m)]
    r=urllib.request.urlopen(urllib.request.Request(U,json.dumps(q).encode(),{"content-type":"application/json"}),timeout=3)
    return [int(x["result"]["number"],16) for x in sorted(json.load(r),key=lambda x:x["id"])]
n=d=0;gaps={};t0=time.time()
while time.time()-t0<float(sys.argv[1]):
    l,f=b(["latest","finalized"]); n+=1
    if l!=f: d+=1; gaps[l-f]=gaps.get(l-f,0)+1
print(f"samples={n} diverged={d} gaps={gaps}")
