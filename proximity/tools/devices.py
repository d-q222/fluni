#!/usr/bin/env python3
"""Read-only iPhone readiness probe shared by pair_test.sh and doctor.sh.

  devices.py [--lock] [--installed BUNDLE] [udid ...]

Prints one TSV line per physical iPhone (or per given udid):
  udid <TAB> name <TAB> model <TAB> problem-or-"ok" [<TAB> installed|not-installed|unknown]
--lock also asks the phone whether it is locked (needs a live tunnel).
"""
import json, subprocess, sys, tempfile, os


def devicectl(*args, timeout=25):
    with tempfile.NamedTemporaryFile(suffix=".json") as f:
        try:
            r = subprocess.run(["xcrun", "devicectl", *args, "--timeout", str(timeout), "--json-output", f.name],
                               capture_output=True, text=True, timeout=timeout + 15)
            return json.load(open(f.name)), r.stdout + r.stderr
        except Exception as e:
            return None, str(e)


def main():
    argv = sys.argv[1:]
    lock = "--lock" in argv
    bundle = None
    if "--installed" in argv:
        i = argv.index("--installed"); bundle = argv[i + 1]; del argv[i:i + 2]
    argv = [a for a in argv if a != "--lock"]
    data, err = devicectl("list", "devices")
    if data is None:
        print(f"devicectl list devices failed: {err.strip()[:200]}", file=sys.stderr); sys.exit(2)
    for d in data["result"]["devices"]:
        hw, dp, cp = d["hardwareProperties"], d["deviceProperties"], d["connectionProperties"]
        udid = hw.get("udid", "")
        if argv and udid not in argv and d["identifier"] not in argv:
            continue
        if not argv and (hw.get("deviceType") != "iPhone" or hw.get("reality") == "simulated"):
            continue
        name = dp.get("name", "?").replace("’", "'")
        problem = "ok"
        if cp.get("pairingState") != "paired":
            problem = "not paired: connect by cable and tap Trust on the phone"
        elif dp.get("developerModeStatus") == "disabled":
            problem = "Developer Mode is off: Settings > Privacy & Security > Developer Mode, then restart the phone"
        elif cp.get("tunnelState") in ("unavailable", "disconnected", None):
            problem = f"no tunnel ({cp.get('tunnelState')}): plug in, unlock, and wait a few seconds"
        elif lock:
            ls, _ = devicectl("device", "info", "lockState", "--device", d["identifier"], timeout=10)
            if ls is None:
                problem = "cannot query lock state: unlock the phone and retry"
            elif ls["result"].get("passcodeRequired"):
                problem = "phone is locked: unlock it and keep the screen on"
        row = [udid, name, hw.get("marketingName", "?"), problem]
        if bundle:
            state = "unknown"
            if cp.get("tunnelState") == "connected":
                a, _ = devicectl("device", "info", "apps", "--device", d["identifier"], "--bundle-id", bundle)
                if a is not None:
                    state = "installed" if a["result"].get("apps") else "not-installed"
            row.append(state)
        print("\t".join(row))


main()
