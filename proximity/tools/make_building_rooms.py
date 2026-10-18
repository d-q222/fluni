#!/usr/bin/env python3
"""Builds FlUni/Resources/building_rooms.csv: the room each sim location stands for on the phone.

The phone knows which building it is in (its own GPS fix, on the phone only), never which room. For Rio's
room-air term it uses one representative room per location: the location's median-volume room from the
run's map/rooms.csv (lower median; ties by room_id), with that room's own volume_m3, ventilation_ach and
room_type, exactly the row infer.js's doseModel would read for a contact in that room. The circle
(lat, lon, radius_m) is the footprint's area as a circle plus 10 m of GPS slack, the rule
heatmap/tools/precompute.mjs uses for building_heat.csv. indoor comes from map/buildings.csv.

Run from the repo root:
  python3 proximity/tools/make_building_rooms.py sim/runs/influenza_none_n1000_d4_s42_73b8452c
"""
import csv
import math
import sys
from collections import defaultdict
from pathlib import Path

run = Path(sys.argv[1] if len(sys.argv) > 1 else 'sim/runs/influenza_none_n1000_d4_s42_73b8452c')
out = Path(__file__).resolve().parent.parent / 'FlUni/Resources/building_rooms.csv'

rooms = defaultdict(list)
with open(run / 'map/rooms.csv', newline='') as f:
    for r in csv.DictReader(f):
        rooms[r['location_id']].append(r)

rows = []
with open(run / 'map/buildings.csv', newline='') as f:
    for b in csv.DictReader(f):
        rs = rooms.get(b['location_id'])
        if not rs or not b['lat'] or not b['lon']:
            continue
        rs = sorted(rs, key=lambda r: (float(r['volume_m3'] or 0), r['room_id']))
        rep = rs[(len(rs) - 1) // 2]
        area = float(b['area_m2'] or 0)
        radius = math.floor(math.sqrt(area / math.pi) + 10 + 0.5) if area > 0 else 40  # JS Math.round; BuildingHeat.defaultRadius
        rows.append([b['location_id'], b['lat'], b['lon'], str(radius), rep['room_id'], rep['volume_m3'],
                     rep['ventilation_ach'], rep['room_type'], '1' if b['indoor'] == 'True' else '0'])

rows.sort()
with open(out, 'w', newline='') as f:
    w = csv.writer(f, lineterminator='\n')
    w.writerow(['building_id', 'lat', 'lon', 'radius_m', 'room_id', 'volume_m3', 'ventilation_ach', 'room_type', 'indoor'])
    w.writerows(rows)
print(f'{out}: {len(rows)} locations from {run}')
