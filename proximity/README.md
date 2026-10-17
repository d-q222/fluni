# proximity/ — live two-phone proximity alerts

A SwiftUI test app (iOS 17+) for PRD Functionality 1. Two iPhones find each other, estimate
distance, and warn the user when they've been near a contagious phone. It is built for the live demo
and is not a production app.

## How it works

Each phone advertises a **random ID that changes every 15 min** plus a **3-level risk**
(healthy, possibly sick, contagious). Nothing else is broadcast. All matching happens on the phone,
with no server. (Decision 2026-10-17: live alerts beat retrospective matching for the demo; see
WORKSTREAMS.md.)

| Channel | What it carries | Distance quality |
|---|---|---|
| **Bluetooth LE** beacon | ID + risk packed into one 128-bit service UUID (`FLU1`, risk, 11-byte ID). Needs no connection. | RSSI, ±50–70 % |
| **Peer link** (MultipeerConnectivity, encrypted) | hello (ID + risk), UWB tokens, GPS fixes | — |
| **UWB** (Nearby Interaction, U1 chip) | needs tokens swapped over the peer link | ~10 cm |
| **GPS** | each phone's own fix, sent only to the linked phone | 5–20 m, poor indoors |

**Fusion** (`Fusion.swift`): fresh readings are averaged, each weighted by 1/σ². UWB dominates when
present; Bluetooth and GPS take over when it drops out. While UWB is live, it **calibrates the
Bluetooth model** for that phone pair, so Bluetooth-only ranging improves afterwards. The result is
P(within 6 ft), not a yes/no.

**Exposure** (`Exposure.swift`): minutes += dt × P(≤ 6 ft) × weight, where weight is 1 for
contagious and 0.5 for possibly sick. The app shows a heads-up as soon as a risky phone is probably
within 6 ft, and a **close-contact alert with advice at 15 cumulative minutes** (the CDC rule).
Demo speed (1×, 10× or 60×) scales time, so 60× gets there in 15 seconds.

The **Heat map tab** loads the heat map workstream's page (`heatmap/`) over the local network
rather than copying it:

```
cd fluni && python3 -m http.server 8000      # on the laptop
# in the app, Heat map tab: http://<laptop>.local:8000/heatmap/
```

## Run

Requirements: Xcode 26+, [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`),
and two U1/U2 iPhones (iPhone 11 or later, not SE). The phones need Developer Mode on and must be
paired with the Mac (tap Trust).

```
cd proximity
FLUNI_TEAM=<your team id> xcodegen generate      # team id: Xcode → Settings → Accounts
open FluniProx.xcodeproj                           # or use the script below
```

Unit tests (fusion + exposure logic; no radios needed):

```
xcodebuild test -project FluniProx.xcodeproj -scheme FluniProx \
  -destination 'platform=iOS Simulator,name=<any iPhone sim>' CODE_SIGNING_ALLOWED=NO
```

**Two-phone test** (builds, installs, launches both phones and streams their `[fluni]` logs):

```
FLUNI_TEAM=<team> tools/pair_test.sh fused 60    # A contagious; B (and C) listen on UWB+BLE+GPS
tools/pair_test.sh uwb|ble|gps|control           # one channel only, or nobody sick (expect no alert)
SKIP_BUILD=1 tools/pair_test.sh ble              # reuse the installed build
```

With phones side by side at 60×, B should log `ALERT nearby` within seconds, then
`ALERT closeContact` at about 15 s. The `control` case should never alert. To test "apart → no alert",
run `fused` with the phones in different rooms.

Launch arguments (also usable from Xcode's scheme): `-risk none|possible|contagious`, `-speed 60`,
`-sources UWB,BLE,GPS`, `-heatmapURL http://…`.

## Limits

- Foreground only. iOS hides custom Bluetooth beacons from scanners in the background, and UWB needs
  the app open. The app keeps the screen on.
- Free Apple developer teams sign builds for 7 days; reinstall after that.
- Privacy: in a room with just two people, the risk bit identifies the sick one. Acceptable for the
  demo, but it needs a fix (anonymity threshold or server-side matching) before real use.
