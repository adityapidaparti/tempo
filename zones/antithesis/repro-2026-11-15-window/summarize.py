import json,glob,collections,statistics as st
for f in sorted(glob.glob('exp-*.jsonl')):
    R=[json.loads(l) for l in open(f)]
    if not R: continue
    c=collections.Counter(r.get('outcome',r.get('skip')) for r in R)
    ms=[r['sig_after_receipt_ms'] for r in R]
    ex=[r['exit_after_term_s'] for r in R if r.get('exit_after_term_s') is not None]
    kn=sum(bool(r.get('sigkill_needed')) for r in R)
    forks=sum(bool(r['follower_forks']) for r in R); fg=sum(any(r['followers_got_lost_block'].values()) for r in R if r['followers_got_lost_block'])
    dur=[r['durable_at_death'] - r['bn'] for r in R if r['durable_at_death'] >= 0]
    print(f, dict(c), 'sig_ms', min(ms), st.median(ms), max(ms), '| exit_s', (min(ex),st.median(ex),max(ex)) if ex else '-', 'sigkill_needed', kn,
          '| forks', forks, 'flw_had_lost', fg, '| durable-bn', collections.Counter(dur), '| restart_s', st.median([r['restart_to_past_s'] for r in R]))
