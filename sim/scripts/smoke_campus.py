"""Smoke test for campussim.campus: build, classification table, beds, routes, write(), d2 headers, determinism.

  .venv/bin/python scripts/smoke_campus.py [--table]
"""
import filecmp
import sys
import tempfile
import time
from pathlib import Path

import numpy as np
import pandas as pd

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campussim.campus import Campus  # noqa: E402
from campussim.config import load_config  # noqa: E402

MOCK = Path(__file__).resolve().parent.parent / "runs/mock_boring10/map"


def main():
    cfg = load_config()["map"]
    t0 = time.time()
    c = Campus.build(cfg)
    print(f"build {time.time() - t0:.2f}s  version {c.version}  B={c.B} R={c.R} E={len(c.entrances)} "
          f"path nodes={c.P} (of {c.n_path_components} components, largest kept)")
    bl = c.buildings
    beds = c.rooms[c.room_is_bedroom].groupby("b")["capacity"].sum().reindex(range(c.B)).fillna(0).astype(int)
    if "--table" in sys.argv:
        pd.set_option("display.width", 200)
        pd.set_option("display.max_rows", 1000)
        named = bl[bl["name"] != ""].assign(beds=beds)
        for t, g in named.groupby("type"):
            print(f"== {t} ({len(g)})")
            print(g[["name", "osm_tag", "levels", "footprint_m2", "n_rooms", "capacity", "beds"]].to_string(header=False))
    print("\ncounts by type:")
    print(bl.groupby("type").agg(n=("name", "size"), rooms=("n_rooms", "sum"), capacity=("capacity", "sum")).to_string())
    print(f"\ntotal beds: {c.total_beds}  in {int((beds > 0).sum())} dorm buildings, "
          f"{int(c.room_is_bedroom.sum())} bedrooms")
    print("room types:", c.rooms["room_type"].value_counts().to_dict())
    non_other = bl["type"] != "other"
    assert (bl.loc[non_other, "n_rooms"] >= 1).all(), "non-other building without rooms"
    out = c.rooms[c.rooms["room_type"] == "outdoor_area"]
    assert len(out) and not out["indoor"].any()

    # mock-consistent buildings
    for osm, t in [("way/232805657", "dorm"), ("way/333374283", "dining"), ("way/232841892", "lecture_hall"),
                   ("way/232805685", "library"), ("way/26250731", "health_center")]:
        got = bl.loc[bl["osm_id"] == osm, "type"].item()
        assert got == t, (osm, got, t)

    # routes
    rb, g, tr = c.find_building("Roble Hall"), c.find_building("Gates Computer Science"), c.find_building("Tresidder Memorial Union")
    for src, dst, label in [(("b", rb), ("b", g), "Roble Hall -> Gates"), (("e", 0), ("b", tr), "entry 0 -> Tresidder")]:
        xy, L = c.route(src, dst)
        a, b = xy[0], xy[-1]
        crow = float(np.hypot(*(b - a)))
        print(f"route {label}: {L:.0f} m, {len(xy)} pts, straight-line {crow:.0f} m, ratio {L / crow:.2f}")
        assert 1.0 <= L / crow < 2.0
        assert abs(c.distance(src, dst) - L) < 1e-6
    t0 = time.time()
    for b in range(c.B):
        c.distance(("b", b), ("b", tr))
    print(f"distance to Tresidder from all {c.B} buildings: {time.time() - t0:.3f}s")
    e = c.nearest_entrance(rb, c.b_x[rb], c.b_y[rb])
    print("nearest Roble entrance:", c.entrances.at[e, "entrance_id"])

    # write + headers + determinism
    with tempfile.TemporaryDirectory() as tmp:
        d1, d2 = Path(tmp) / "a", Path(tmp) / "b"
        c.write(d1)
        Campus.build(cfg).write(d2)
        for f in ["buildings.csv", "rooms.csv", "entrances.csv"]:
            mine = (d1 / f).read_text().splitlines()[0].split(",")
            mock = (MOCK / f).read_text().splitlines()[0].split(",")
            assert mine[:len(mock)] == mock, (f, mine, mock)
            print(f"{f}: header prefix OK (+extras {mine[len(mock):]})")
        import json
        p1 = json.loads((d1 / "rooms.geojson").read_text())["features"][0]["properties"]
        p2 = json.loads((MOCK / "rooms.geojson").read_text())["features"][0]["properties"]
        assert list(p1)[:len(p2)] == list(p2)
        for f in sorted(p.name for p in d1.iterdir()):
            assert filecmp.cmp(d1 / f, d2 / f, shallow=False), f"{f} differs between builds"
        print("two builds byte-identical:", sorted(p.name for p in d1.iterdir()))
        print((d1 / "buildings.csv").read_text().splitlines()[1])
        print((d1 / "rooms.csv").read_text().splitlines()[1])
    print("OK")


if __name__ == "__main__":
    main()
