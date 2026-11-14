# Delay relay: listen 10.20.0.1:<port>, forward to <dst>:8546; client->server bytes delayed by
# int(file <delayfile>) ms (read per chunk). Server->client bytes are not delayed.
import asyncio, sys, time
lport, dst, dfile = int(sys.argv[1]), sys.argv[2], sys.argv[3]
import os; LOG = os.environ.get('RELAYLOG') == '1'
def delay(port=None):
    # file: "<ms>" for all connections, or "<ms> <port>" to delay only the connection from <port>
    try:
        p = open(dfile).read().split()
        if len(p) > 1 and int(p[1]) != port: return 0
        return int(p[0] or 0) / 1000
    except Exception: return 0
async def pump_delayed(r, w):
    q = asyncio.Queue()
    async def rd():
        while True:
            d = await r.read(65536)
            await q.put((time.monotonic() + delay(r._transport.get_extra_info('peername')[1]), d))
            if LOG: print(f"{time.time():.3f} c2s {r._transport.get_extra_info('peername')[1]} {len(d)}", flush=True)
            if not d: return
    t = asyncio.create_task(rd())
    try:
        while True:
            due, d = await q.get()
            now = time.monotonic()
            if due > now: await asyncio.sleep(due - now)
            if not d: break
            w.write(d); await w.drain()
    finally:
        t.cancel(); w.close()
async def pump(r, w):
    try:
        while (d := await r.read(65536)): w.write(d); await w.drain()
    finally: w.close()
async def handle(cr, cw):
    try: sr, sw = await asyncio.open_connection(dst, 8546)
    except Exception: cw.close(); return
    print(time.time(), "conn", cw.get_extra_info("peername"), flush=True)
    await asyncio.gather(pump_delayed(cr, sw), pump(sr, cw), return_exceptions=True)
async def main():
    s = await asyncio.start_server(handle, "10.20.0.1", lport)
    async with s: await s.serve_forever()
asyncio.run(main())
