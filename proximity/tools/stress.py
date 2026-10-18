#!/usr/bin/env python3
"""Stress-test the phone links and report latencies, drops and failures per configuration.

Launches Fluni Prox on 2-3 connected iPhones (phone A is the sick one), timestamps every
"[fluni]" line on the Mac, and repeats for several cycles.

  tools/stress.py relaunch --config encryption=required --cycles 5 --hold 40
  tools/stress.py flip      # A turns contagious 20 s in; measures how fast listeners learn it, and by which channel
  tools/stress.py rotate    # IDs rotate every 20 s; checks for double counting and lost exposure
  tools/stress.py background  # listener B goes to the background mid-run, then returns

Link/UWB uptime columns come from the app's "link metric" lines: handshake_med (s per successful MPC
handshake), link_failed (failed attempts), uwb_resumes (UWB came back after a gap > 1 s or a link drop),
uwb_gap_max (longest UWB outage, s) and uwb_after_drop_max (link drop -> next UWB distance, s).

--config takes app launch arguments as k=v pairs: encryption (required|optional|none), inviteTimeout, rotate.
Phones: PHONES="udidA udidB [udidC]" or every paired, connected iPhone. Install the app first
(tools/pair_test.sh does). Raw logs go to --out.
"""
import argparse, json, os, re, statistics, subprocess, sys, tempfile, threading, time

BUNDLE = "com.fluni.proxtest"
LABELS = "ABC"


def phones():
    if os.environ.get("PHONES"):
        return os.environ["PHONES"].split()
    with tempfile.NamedTemporaryFile(suffix=".json") as f:
        subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", f.name], capture_output=True)
        ds = json.load(open(f.name))["result"]["devices"]
    return [d["hardwareProperties"]["udid"] for d in ds
            if d["hardwareProperties"].get("deviceType") == "iPhone"
            and d["hardwareProperties"].get("reality") != "simulated"
            and d["connectionProperties"].get("pairingState") == "paired"
            and d["connectionProperties"].get("tunnelState") == "connected"][:3]


def run_cycle(ph, scenario, config, hold, out_path):
    t0 = time.monotonic()
    lines, lock, procs = [], threading.Lock(), []
    common = ["-speed", "60"] + [x for kv in config for x in ("-" + kv[0], kv[1])]
    if scenario == "rotate":
        common += ["-rotate", "20"]

    def reader(label, proc):
        for raw in proc.stdout:
            if "[fluni]" in raw:
                with lock:
                    lines.append((label, time.monotonic() - t0, raw.split("[fluni] ", 1)[1].strip()))

    for i, udid in enumerate(ph):
        if i == 0:
            risk = ["-risk", "none", "-riskAfter", "20:contagious"] if scenario == "flip" else ["-risk", "contagious"]
        else:
            risk = ["-risk", "none"]
        p = subprocess.Popen(["xcrun", "devicectl", "device", "process", "launch", "--device", udid, "--console",
                              "--terminate-existing", BUNDLE, "--"] + risk + common,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
        procs.append(p)
        threading.Thread(target=reader, args=(LABELS[i], p), daemon=True).start()

    events = []
    if scenario == "background":
        time.sleep(hold * 0.4)
        events.append(("bg", time.monotonic() - t0))
        subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", ph[1], "com.apple.Preferences"],
                       capture_output=True)
        time.sleep(8)
        events.append(("fg", time.monotonic() - t0))
        subprocess.run(["xcrun", "devicectl", "device", "process", "launch", "--device", ph[1], BUNDLE], capture_output=True)
        time.sleep(max(0, hold - (time.monotonic() - t0)))
    else:
        time.sleep(hold)
    for p in procs:
        p.terminate()
    time.sleep(1)
    with open(out_path, "w") as f:
        for lab, t, s in lines:
            f.write(f"{t:7.2f} [{lab}] {s}\n")
    return lines, dict(events)


def first(lines, label, pattern, after=0.0):
    for lab, t, s in lines:
        if lab == label and t >= after and re.search(pattern, s):
            return t
    return None


def analyse(lines, events, n_phones, scenario):
    rows = []
    for lab in LABELS[1:n_phones]:
        r = {"phone": lab,
             "start": first(lines, lab, r"^start"),
             "ble_seen": first(lines, lab, r"^ble seen"),
             "link": first(lines, lab, r"^link connected"),
             "uwb": first(lines, lab, r"^uwb ranging"),
             "nearby": first(lines, lab, r"^ALERT nearby"),
             "close": first(lines, lab, r"^ALERT closeContact"),
             "link_lost": sum(1 for l, _, s in lines if l == lab and s.startswith("link lost")),
             "errors": sum(1 for l, _, s in lines if l == lab and re.search(r"restarting|not allowed|error", s))}
        # Listeners are healthy, so every risk=contagious in their tick is a peer. Only A is sick:
        # more than one means the same phone is counted twice (e.g. old + new ID after rotation).
        r["double_count_ticks"] = sum(1 for l, _, s in lines
                                      if l == lab and s.startswith("tick") and s.count("risk=contagious") > 1)
        if scenario == "flip":
            tf = first(lines, "A", r"^risk set contagious")
            tb = first(lines, lab, r"risk=contagious via=ble", after=tf or 0)
            tl = first(lines, lab, r"risk=contagious via=link", after=tf or 0)
            r["flip_ble"] = None if tf is None or tb is None else tb - tf
            r["flip_link"] = None if tf is None or tl is None else tl - tf
        if scenario == "background" and "fg" in events:
            r["relink_after_fg"] = (lambda t: None if t is None else t - events["fg"])(
                first(lines, lab, r"^link connected", after=events["fg"]))
            r["uwb_after_fg"] = (lambda t: None if t is None else t - events["fg"])(
                first(lines, lab, r"^uwb ranging", after=events["fg"]))
        mine = [s for l, _, s in lines if l == lab]
        hs = [float(m.group(1)) for s in mine for m in [re.match(r"link metric handshake=([\d.]+)", s)] if m]
        res = [m for s in mine for m in [re.match(r"link metric uwb_resume gap=([\d.]+|-) after_drop=([\d.]+|-)", s)] if m]
        gaps = [float(m.group(1)) for m in res if m.group(1) != "-"]
        drops = [float(m.group(2)) for m in res if m.group(2) != "-"]
        r["handshake_med"] = statistics.median(hs) if hs else None
        r["link_failed"] = sum(1 for s in mine if s.startswith("link attempt failed"))
        r["uwb_resumes"] = len(res)
        r["uwb_gap_max"] = max(gaps) if gaps else None
        r["uwb_after_drop_max"] = max(drops) if drops else None
        last = [s for l, _, s in lines if l == lab and s.startswith("tick")]
        m = re.search(r"minutes=([\d.]+)", last[-1]) if last else None
        r["final_minutes"] = float(m.group(1)) if m else None
        rows.append(r)
    return rows


def fmt(v):
    return "—" if v is None else (f"{v:.1f}" if isinstance(v, float) else str(v))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("scenario", choices=["relaunch", "flip", "rotate", "background"])
    ap.add_argument("--config", default="", help="k=v,k=v app launch arguments")
    ap.add_argument("--cycles", type=int, default=3)
    ap.add_argument("--hold", type=float, default=40)
    ap.add_argument("--out", default=os.path.join(tempfile.gettempdir(), "fluni-stress"))
    a = ap.parse_args()
    ph = phones()
    if len(ph) < 2:
        sys.exit("need at least two paired, connected iPhones")
    config = [kv.split("=", 1) for kv in a.config.split(",") if kv]
    os.makedirs(a.out, exist_ok=True)
    tag = a.scenario + ("_" + a.config.replace("=", "-").replace(",", "_") if a.config else "")
    print(f"# {tag}: {len(ph)} phones, {a.cycles} cycles x {a.hold:.0f}s")
    all_rows = []
    for c in range(a.cycles):
        lines, events = run_cycle(ph, a.scenario, config, a.hold, os.path.join(a.out, f"{tag}_c{c}.log"))
        for r in analyse(lines, events, len(ph), a.scenario):
            r["cycle"] = c
            all_rows.append(r)
            print("  " + " ".join(f"{k}={fmt(v)}" for k, v in r.items()))
        time.sleep(3)
    keys = [k for k in all_rows[0] if k not in ("phone", "cycle", "start")]
    print(f"# summary {tag} (median / max / missing of {len(all_rows)})")
    for k in keys:
        vals = [r[k] for r in all_rows]
        got = [v for v in vals if v is not None]
        med = statistics.median(got) if got else None
        print(f"  {k:18} {fmt(med):>6} / {fmt(max(got) if got else None):>6} / missing {len(vals) - len(got)}")
    json.dump(all_rows, open(os.path.join(a.out, f"{tag}.json"), "w"), indent=1)


if __name__ == "__main__":
    main()
