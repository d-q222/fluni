"""Compare the model's P(sick) with the sim's truth at a few moments of a run (stdlib only).

    python3 model/calibrate.py sim/runs/<run> [model/out/<run>/p_sick.csv]

For each moment: how many agents are truly infected (E or I*), how many the model expects
(sum of P), mean P of the infected and of the susceptible, and AUC (0.5 = no better than chance).
"""
import csv, gzip, json, sys
from datetime import datetime, timedelta
from pathlib import Path

run = Path(sys.argv[1])
psick = Path(sys.argv[2]) if len(sys.argv) > 2 else Path(__file__).parent / 'out' / run.name / 'p_sick.csv'
cfg = json.loads((run / 'config.json').read_text())
start, step_min = datetime.fromisoformat(cfg['start']), cfg['step_min']
per_day = 24 * 60 // step_min
n_days = cfg.get('days') or 1
steps = sorted({d * per_day + h * 60 // step_min for d in range(n_days) for h in (12, 23)})

state = {s: {} for s in steps}
with gzip.open(run / 'timeline.csv.gz', 'rt') as f:
    for r in csv.DictReader(f):
        t = int(r['t'])
        if t in state:
            state[t][r['agent_id']] = r['disease_state']

changes = {}
with open(psick) as f:
    for r in csv.DictReader(f):
        changes.setdefault(r['agent_id'], []).append((r['t_iso'], float(r['p_sick'])))
prior = 0.02

def p_at(agent, iso):
    p = prior
    for t, v in changes.get(agent, []):
        if t > iso:
            break
        p = v
    return p

print('moment            infected  expected  P(infected)  P(susceptible)  AUC')
for s in steps:
    if not state[s]:
        continue
    iso = (start + timedelta(minutes=s * step_min)).strftime('%Y-%m-%dT%H:%M:%S')
    pos = [p_at(a, iso) for a, st in state[s].items() if st[0] in 'EI']
    neg = [p_at(a, iso) for a, st in state[s].items() if st == 'S']
    allp = [p_at(a, iso) for a in state[s]]
    auc = f'{sum((x > y) + 0.5 * (x == y) for x in pos for y in neg) / (len(pos) * len(neg)):.2f}' if pos and neg else 'n/a'
    mean = lambda v: sum(v) / len(v) if v else 0
    print(f'{iso[:16]}  {len(pos):8d}  {sum(allp):8.1f}  {mean(pos):11.3f}  {mean(neg):14.3f}  {auc}')
