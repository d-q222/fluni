"""Split a run's big .csv.gz files into git-sized parts, and join them back.

GitHub rejects files over 100 MB, and full-size runs have bigger ones (contacts.csv.gz is ~180 MB
at 7,000 agents x 2 days). `split` cuts every .csv.gz over --max-mb into parts/<name>/part-NNN.csv.gz
on row boundaries; each part is a standalone gzipped CSV with the header. parts/manifest.json keeps
the sha256 of every original and part. `join` rebuilds the originals byte-for-byte (same
GzipStream writer and settings as the sim) and regenerates timeline_by_agent/ from timeline.csv.gz.
The .parquet files are mirrors of the CSVs and are not rebuilt.

  .venv/bin/python scripts/run_parts.py split runs/<run_id> [--max-mb 40]
  .venv/bin/python scripts/run_parts.py join runs/<run_id> [--no-by-agent]
"""
import argparse
import gzip
import hashlib
import json
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
from campussim.output import DEFAULTS, GzipStream  # noqa: E402

READ_BLOCK = 8 << 20


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for b in iter(lambda: f.read(READ_BLOCK), b""):
            h.update(b)
    return h.hexdigest()


def rows_blocks(path):
    """(header line, iterator of row blocks that each end on a line break) of a .csv.gz."""
    f = gzip.open(path, "rb")
    header = f.readline()

    def blocks():
        tail = b""
        for b in iter(lambda: f.read(READ_BLOCK), b""):
            b = tail + b
            cut = b.rfind(b"\n") + 1
            tail = b[cut:]
            if cut:
                yield b[:cut]
        if tail:
            yield tail
        f.close()
    return header, blocks()


def split_file(src, out_dir, max_bytes):
    out_dir.mkdir(parents=True, exist_ok=True)
    for old in out_dir.glob("part-*.csv.gz"):
        old.unlink()
    header, blocks = rows_blocks(src)
    parts, raw, part, n = [], None, None, 0

    def open_part():
        nonlocal raw, part, n
        p = out_dir / f"part-{n:03d}.csv.gz"
        n += 1
        raw = open(p, "wb")
        part = gzip.GzipFile(filename=src.name[:-3], mode="wb", fileobj=raw, mtime=0)
        part.write(header)
        parts.append(p)

    def close_part():
        part.close()
        raw.close()

    open_part()
    for b in blocks:
        # Write ~1 MB of whole lines at a time, so a part never runs far past max_bytes.
        i = 0
        while i < len(b):
            j = b.rfind(b"\n", i, i + (1 << 20)) + 1 if i + (1 << 20) < len(b) else len(b)
            if j <= i:  # a single line longer than 1 MB
                j = b.find(b"\n", i + (1 << 20)) + 1 or len(b)
            part.write(b[i:j])
            i = j
            if raw.tell() >= max_bytes:
                close_part()
                open_part()
    close_part()
    if len(parts) > 1 and parts[-1].stat().st_size < 64:  # header-only tail part
        parts.pop().unlink()
    return parts


def cmd_split(run, max_mb):
    max_bytes = int(max_mb * (1 << 20))
    manifest = {"max_mb": max_mb, "files": {}}
    for src in sorted(run.glob("*.csv.gz")):
        if src.stat().st_size <= max_bytes:
            continue
        print(f"[split] {src.name} ({src.stat().st_size / 2**20:.0f} MB)", flush=True)
        parts = split_file(src, run / "parts" / src.name[:-3], max_bytes)
        manifest["files"][src.name] = {
            "sha256": sha256(src), "bytes": src.stat().st_size,
            "parts": [{"path": str(p.relative_to(run)), "sha256": sha256(p), "bytes": p.stat().st_size}
                      for p in parts],
        }
        for p in parts:
            print(f"  {p.relative_to(run)}  {p.stat().st_size / 2**20:.1f} MB")
    (run / "parts").mkdir(exist_ok=True)
    (run / "parts" / "manifest.json").write_text(json.dumps(manifest, indent=2) + "\n")
    print(f"[split] wrote {run / 'parts' / 'manifest.json'}")


def output_cfg(run):
    cfg = json.loads((run / "config.json").read_text())
    return {**DEFAULTS, **cfg.get("params", {}).get("output", {})}


def cmd_join(run, by_agent):
    manifest = json.loads((run / "parts" / "manifest.json").read_text())
    ocfg = output_cfg(run)
    ok = True
    for name, entry in manifest["files"].items():
        print(f"[join] {name} from {len(entry['parts'])} parts", flush=True)
        g = GzipStream(run / name, ocfg["gzip_level"], threads=int(ocfg["gzip_threads"]),
                       block_bytes=int(ocfg["gzip_block_mb"] * (1 << 20)))
        for i, p in enumerate(entry["parts"]):
            if sha256(run / p["path"]) != p["sha256"]:
                sys.exit(f"[join] {p['path']}: sha256 mismatch (corrupt or stale part)")
            header, blocks = rows_blocks(run / p["path"])
            if i == 0:
                g.write(header)
            for b in blocks:
                g.write(b)
        g.close()
        match = sha256(run / name) == entry["sha256"]
        ok &= match
        print(f"  sha256 {'matches' if match else 'DIFFERS from'} the original")
    if by_agent and (run / "timeline.csv.gz").exists():
        write_by_agent(run)
    if not ok:
        sys.exit("[join] some files differ from the originals")


def write_by_agent(run):
    """timeline_by_agent/<agent_id>.csv: the timeline's rows per agent, in timeline order."""
    out = run / "timeline_by_agent"
    out.mkdir(exist_ok=True)
    for f in out.glob("*.csv"):
        f.unlink()
    header, blocks = rows_blocks(run / "timeline.csv.gz")
    col = header.rstrip(b"\r\n").split(b",").index(b"agent_id")
    created, buf, buf_bytes = set(), {}, 0

    def flush():
        for aid in sorted(buf):
            with open(out / f"{aid.decode()}.csv", "ab") as h:
                if aid not in created:
                    h.write(header)
                    created.add(aid)
                h.write(b"".join(buf[aid]))
        buf.clear()

    for b in blocks:
        for line in b.splitlines(keepends=True):
            buf.setdefault(line.split(b",", col + 1)[col], []).append(line)
            buf_bytes += len(line)
        if buf_bytes >= 512 << 20:
            flush()
            buf_bytes = 0
    flush()
    print(f"[join] wrote {len(created)} files in {out.relative_to(run)}/")


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("cmd", choices=["split", "join"])
    ap.add_argument("run", type=Path, help="run folder (runs/<run_id>)")
    ap.add_argument("--max-mb", type=float, default=40, help="split files bigger than this (MB)")
    ap.add_argument("--no-by-agent", action="store_true", help="join: skip timeline_by_agent/")
    a = ap.parse_args()
    if a.cmd == "split":
        cmd_split(a.run, a.max_mb)
    else:
        cmd_join(a.run, not a.no_by_agent)


if __name__ == "__main__":
    main()
