# Usage: check_payroll_slot.py <log.ndjson> <failing slot (decimal)>
# Rebuilds every payroll recipient of the timeline from the cohort seeds the workload logged, and
# reports which holder owns the failing balance slot and how many nibbles its trie key shares
# with the nearest other holder.
import json, re, sys
sys.path.insert(0, __file__.rsplit('/', 1)[0])
from keccak import keccak256
log, slot = sys.argv[1], int(sys.argv[2])
cohorts = {}
for line in open(log):
    ev = json.loads(line); t = ev.get('t') or ''
    m = re.search(r'payroll: first instalment to (\d+) new holders of cohort (\d+)', t)
    if m: cohorts[int(m.group(2))] = (int(m.group(1)), ev['vt'])
    m = re.search(r'payroll: second instalment to (\d+)/(\d+) of cohort (\d+)', t)
    if m and int(m.group(3)) in cohorts: cohorts[int(m.group(3))] += (ev['vt'],)
keys = []
for seed, info in cohorts.items():
    for i in range(info[0]):
        addr = keccak256(b'tempo-zone-antithesis-payroll' + seed.to_bytes(8, 'big') + i.to_bytes(4, 'big'))[12:]
        s = keccak256(b'\0' * 12 + addr + (9).to_bytes(32, 'big'))
        keys.append((keccak256(s).hex(), int.from_bytes(s, 'big'), seed, i, addr.hex()))
print('cohorts', len(cohorts), 'holders', len(keys))
keys.sort()
def shared(a, b):
    n = 0
    while n < 64 and a[n] == b[n]: n += 1
    return n
for j, k in enumerate(keys):
    if k[1] == slot:
        for other in (keys[j - 1] if j else None, keys[j + 1] if j + 1 < len(keys) else None):
            if other:
                print('failing holder 0x%s cohort %d index %d key %s' % (k[4], k[2], k[3], k[0][:14]))
                print('  neighbour 0x%s cohort %d index %d key %s shares %d nibbles' % (other[4], other[2], other[3], other[0][:14], shared(k[0], other[0])))
                print('  cohort timings (count, first vtime, second vtime...):', cohorts[k[2]], cohorts[other[2]])
        break
else:
    print('failing slot is NOT a payroll recipient of this timeline')
print('deepest pair overall:', max(shared(a[0], b[0]) for a, b in zip(keys, keys[1:])))
