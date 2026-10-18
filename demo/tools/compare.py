"""Summarise app-vs-no-app sim runs into demo/data/compare.json for the Simulations section.

    sim/.venv/bin/python demo/tools/compare.py <runs_dir>   # runs named influenza_{none,fluni}_n..._s<seed>_*

Reads each run's summary.json, infections.csv and (fluni runs) app_alerts.csv. Writes per-run daily
incidence, attack rate, infections by route/location, and alert counts.
"""
import csv, json, pathlib, re, sys, collections

runs_dir = pathlib.Path(sys.argv[1])
out = pathlib.Path(__file__).resolve().parents[1] / 'data' / 'compare.json'
res = []
for d in sorted(runs_dir.iterdir()):
    m = re.match(r'(\w+?)_(none|fluni)_n(\d+)_d(\d+)_s(\d+)_', d.name)
    if not m or not (d / 'summary.json').exists():
        continue
    s = json.loads((d / 'summary.json').read_text())
    cfg = json.loads((d / 'config.json').read_text())
    row = {
        'run_id': d.name, 'intervention': m[2], 'seed': int(m[5]), 'agents': int(m[3]), 'days': int(m[4]),
        'transmission_scale': cfg['params']['disease'].get('transmission_scale'),
        'has_app_rate': cfg['params']['population'].get('has_app_rate'),
        'initial_seeds': s.get('n_seed'), 'n_infected': s['n_infected'], 'attack_rate': s['attack_rate'],
        'measured_R': s.get('measured_R'), 'daily_incidence': s['daily_incidence'],
        'by_route': s.get('infections_by_route'), 'by_location': s.get('infections_by_location_type'),
    }
    alerts = d / 'app_alerts.csv'
    if alerts.exists():
        c = collections.Counter(r['alert'] for r in csv.DictReader(open(alerts)))
        row['alerts'] = dict(c)
    res.append(row)
out.write_text(json.dumps({'source': 'sim/simulate.py --agents 1000 --days 14 --initial-seeds 30 '
                           '--set disease.transmission_scale=1.5, --intervention none vs fluni, seeds 42-44',
                           'runs': res}, indent=1))
print(f'{len(res)} runs -> {out}')
