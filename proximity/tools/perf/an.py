#!/usr/bin/env python3
"""Summarise an xctrace .trace: signposts (com.fluni), main-thread CPU, tick cost, hot main-thread frames."""
import subprocess, sys, collections, re
import xml.etree.ElementTree as ET

def export(trace, schema):
    import time
    for _ in range(5):
        toc = subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace, '--toc'], capture_output=True, text=True).stdout
        if toc.strip(): break
        time.sleep(2)
    tables = ET.fromstring(toc).find('run').find('data').findall('table')
    idx = [i + 1 for i, t in enumerate(tables) if t.attrib.get('schema') == schema]
    allrows = []
    ids = {}
    for i in idx:
        x = subprocess.run(['xcrun', 'xctrace', 'export', '--input', trace, '--xpath',
                            f'/trace-toc/run[@number="1"]/data/table[{i}]'], capture_output=True, text=True).stdout
        if not x.strip():
            continue
        root = ET.fromstring(x)
        local = {}
        for el in root.iter():
            if 'id' in el.attrib:
                local[el.attrib['id']] = el
        for el in list(root.iter()):  # inline every ref so callers can ignore ids
            ref = el.attrib.get('ref')
            if ref and ref in local:
                t = local[ref]
                el.attrib.update(t.attrib); el.text = t.text; el.extend(list(t))
        for row in root.iter('row'):
            allrows.append(list(row))
    if not idx:
        return [], (lambda e: e)
    return allrows, (lambda e: e)

def main(trace, proc='FlUni', steady_from=None, steady_to=None, hot=0, window=None):
    out = {}
    sp = export(trace, 'os-signpost')
    events = []
    if sp:
        rows, r = sp
        for row in rows:
            d = {c.tag: c for c in row}
            if d.get('subsystem') is None or d['subsystem'].text != 'com.fluni':
                continue
            t = int(d['event-time'].text) / 1e9
            events.append((t, d['event-type'].text, d['signpost-name'].text, d['os-signpost-identifier'].text))
    tp = export(trace, 'time-profile')
    samples = []  # (t, thread, weight_ms, frames)
    if tp:
        rows, r = tp
        for row in rows:
            d = {c.tag: c for c in row}
            th = d.get('thread')
            if th is None or proc not in th.attrib.get('fmt', ''):
                continue
            t = int(d['sample-time'].text) / 1e9
            w = int(d['weight'].text) / 1e6
            bt = d.get('tagged-backtrace') if d.get('tagged-backtrace') is not None else d.get('backtrace')
            frames = []
            if bt is not None:
                for f in bt.iter('frame'):
                    f = r(f)
                    frames.append(f.attrib.get('name', '?'))
            samples.append((t, th.attrib['fmt'], w, frames))
    t0 = min([s[0] for s in samples] or [0])
    print(f'process first sample t0={t0:.3f}s')
    for name in ['tabs on screen', 'intro done', 'map drawn', 'tour done']:
        ts = [e[0] for e in events if e[2] == name and e[1] == 'Event']
        if ts:
            print(f'  {name}: ' + ', '.join(f'{(t - t0) * 1000:.0f} ms' for t in ts))
    # intervals
    begins = {}
    iv = collections.defaultdict(list)
    for t, typ, name, ident in sorted(events):
        if typ == 'Begin':
            begins[(name, ident)] = t
        elif typ == 'End' and (name, ident) in begins:
            iv[name].append((begins.pop((name, ident)), t))
    for name, xs in iv.items():
        ds = sorted((b - a) * 1000 for a, b in xs)
        print(f'  interval {name}: n={len(ds)} median={ds[len(ds)//2]:.3f} ms max={ds[-1]:.3f} ms first@{(xs[0][0]-t0)*1000:.0f} ms')
    main_s = [s for s in samples if s[1].startswith('Main Thread')]
    end = max([s[0] for s in samples] or [0])
    a = t0 + steady_from if steady_from is not None else None
    b = t0 + steady_to if steady_to is not None else end
    if a is not None:
        ms = sum(s[2] for s in main_s if a <= s[0] < b)
        allt = sum(s[2] for s in samples if a <= s[0] < b)
        print(f'  steady {steady_from}-{(b - t0):.1f}s: main thread {ms / (b - a):.2f} ms/s, all threads {allt / (b - a):.2f} ms/s')
        # main-thread work inside vs outside tick
        if hot:
            c = collections.Counter()
            for s in main_s:
                if a <= s[0] < b:
                    for fr in s[3][:hot]:
                        c[fr] += s[2]
            for fr, w in c.most_common(25):
                print(f'     {w:7.1f} ms  {fr[:140]}')
    if window:
        wa, wb = t0 + window[0], t0 + window[1]
        c = collections.Counter(); tot = 0
        for s in main_s:
            if wa <= s[0] < wb:
                tot += s[2]
                seen = set()
                for fr in s[3]:
                    if fr not in seen:
                        c[fr] += s[2]; seen.add(fr)
        print(f'  window {window}: main {tot:.0f} ms; inclusive frames matching image/decode:')
        for fr, w in c.most_common(400):
            if re.search(r'PNG|png|decode|Decode|ImageIO|copy_image|CGImage|IntroFrame|LaunchIntro|WebView|WK', fr):
                print(f'     {w:7.1f} ms  {fr[:140]}')

if __name__ == '__main__':
    import argparse
    p = argparse.ArgumentParser()
    p.add_argument('trace'); p.add_argument('--from', dest='f', type=float); p.add_argument('--to', type=float)
    p.add_argument('--hot', type=int, default=0); p.add_argument('--window', type=float, nargs=2)
    a = p.parse_args()
    main(a.trace, steady_from=a.f, steady_to=a.to, hot=a.hot, window=a.window)
