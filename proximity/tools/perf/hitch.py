import sys, an, collections
trace=sys.argv[1]
rows, r = an.export(trace,'hitches')
H=[]
for row in rows:
    d={x.tag:x for x in row}
    p=d.get('process')
    if p is None or 'FlUni' not in p.attrib.get('fmt',''): continue
    H.append((int(d['start-time'].text)/1e9, int(d['duration'].text)/1e6, (d.get('string').attrib.get('fmt') if False else '')))
sp,r2 = an.export(trace,'os-signpost')
ev=[]; iv=[]; begins={}
for row in sp:
    d={x.tag:x for x in row}
    if d.get('subsystem') is None or d['subsystem'].text!='com.fluni': continue
    t=int(d['event-time'].text)/1e9; typ=d['event-type'].text; name=d['signpost-name'].text
    msg=d.get('message'); msg=msg.attrib.get('fmt','') if msg is not None else ''
    key=(name,d['os-signpost-identifier'].text)
    if typ=='Event': ev.append((t,name))
    elif typ=='Begin': begins[key]=(t,msg)
    elif typ=='End' and key in begins:
        b,m=begins.pop(key); iv.append((b,t,name,m))
# process start ~ first life-cycle / first time-profile sample
tp,_=an.export(trace,'time-profile')
t0=min(int({x.tag:x for x in row}['sample-time'].text)/1e9 for row in tp if 'FlUni' in ({x.tag:x for x in row}.get('thread').attrib.get('fmt','') if {x.tag:x for x in row}.get('thread') is not None else ''))
tabs=min([t for t,n in ev if n=='tabs on screen'] or [t0+0.1])
intro_end=min([t for t,n in ev if n=='intro done'] or [tabs+1.45])
if not any(n=='tour' for _,_,n,_ in iv) and '-tour' in sys.argv:  # no signposts recorded: the tour's fixed schedule
    names=['tab map','tab me','sheet open','sheet close','tab today']
    iv=[(tabs+3+1.5*k, tabs+3+1.5*(k+1), 'tour', names[k%5]) for k in range(25)]
def scen(t):
    if t<intro_end+0.05: return 'launch+intro'
    for b,e,n,m in iv:
        if n=='tour' and b<=t<e+0.0: return m or 'tour'
    return 'idle/number roll'
c=collections.defaultdict(list)
for t,dur,_ in H: c[scen(t)].append(dur)
print(f'hitches total={len(H)} (intro done at {(intro_end-t0)*1000:.0f} ms after first sample)')
for k,v in sorted(c.items()): print(f'  {k:18s} n={len(v)} total={sum(v):.1f} ms max={max(v):.1f} ms')
if '-v' in sys.argv:
    for t,dur,_ in H: print(f'   {(t-t0)*1000:8.0f} ms  {dur:5.1f} ms  {scen(t)}')
