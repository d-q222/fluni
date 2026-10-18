# Perf measurements on a phone

Before/after Instruments recordings of FlUni on one phone: launch, the 1 s tick (main-thread ms/s),
Animation Hitches during the intro, the live risk number roll, tab switches and sheets, warm opens,
WebContent memory for the Map, and Power Profiler at idle.

Needs: a connected, unlocked phone (Auto-Lock off helps; the Debug `-keepAwake YES` argument keeps it on while
FlUni is open), and two Debug builds of FlUni (`.app` from DerivedData, `Debug-iphoneos`). Every launch is a test
launch (`-skipOnboarding YES`), so the owner's saved status, pause, history and self-report are never read or
written. The phone must already be onboarded. Don't run it while another agent is using the phone
(`ps aux | grep devicectl`).

    DEV=<udid> tools/perf/batch.sh <before.app> <after.app> <outdir>     # ~35 min; leaves "after" installed

The Debug-only hooks it uses: `-perfTour YES` (Map, Me, report sheet open/close, Today, every 1.5 s, five times),
`-demoPeer contagious@0.5` (the risk number climbs every second) and Points of Interest signposts (`tick`,
`tabs on screen`, `intro done`, `map load`, `map drawn`, `tour`). `an.py` and `hitch.py` summarise one trace.
