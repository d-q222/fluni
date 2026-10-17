# FlUni live demo: 5-minute runbook

3 iPhones (U1/U2, iPhone 11 or later, not SE) and a laptop on the same Wi-Fi. Commands run from the repo
root unless noted. Nothing here needs the internet except map tiles and Leaflet (phones and laptop need
internet for the map, see Troubleshooting).

## Who plays whom

| Phone | Role | Does |
|---|---|---|
| **A** | Patient zero | Taps "I tested positive" |
| **B** | Close contact | Sits next to A, shows nearby, then close contact, then the risk % |
| **C** | Walk-in + map | Sits next to A too; shows "Pretend I'm at...", then the Map tab |
| **Laptop** | Bird's-eye view | Presenter heat map (`/heatmap/`) on the big screen |

Phones A, B and C are placed within 1 m on a table, screens up, in the audience's view (a document camera
or three people holding them works too).

## Before the demo (about 10 minutes)

1. **Charge and keep awake.** Phones above 50 %. Settings > Display & Brightness > Auto-Lock > Never. Turn
   off Low Power Mode. Wi-Fi on, same network as the laptop. Bluetooth on. Silent switch off if you want
   the alert sound.
2. **Check the laptop:** `proximity/tools/doctor.sh` (read-only). You want "Ready." and 3 phones ready.
   If a phone is locked, unlock it and run it again. Set the team once: `export FLUNI_TEAM=<team id>`.
3. **Start the map server** in its own terminal: `proximity/tools/serve_heatmap.sh`. It serves the repo
   root and prints two phone URLs (`<laptop>.local` and the IP). Keep the terminal open. On the laptop
   open `http://localhost:8000/heatmap/` for the presenter view (optional: `?at=2115&agent=A0008`
   opens a scene with a sick neighbour; see `heatmap/README.md`).
4. **Install the latest builds, fresh** (clears old data on all ready, unlocked phones):
   `proximity/tools/demo_reset.sh` (preview with `DRY_RUN=1`). Use `SKIP_BUILD=1` if the build is already
   current. Free-team builds expire after 7 days, so do this the day before at the latest.
5. **Trust the developer cert** (first install on a phone only): Settings > General > VPN & Device
   Management > your Apple ID > Trust. Open FlUni once to confirm it starts.
6. **Onboarding and permissions** on each phone (FlUni shows onboarding after a fresh install; swipe to the
   last page, tap "Turn on detection"). Accept all of these:
   - Bluetooth: Allow
   - Local Network: Allow (this is how the phones find each other; if you deny it, nothing works)
   - Nearby Interaction: Allow
   - Notifications: Allow
   - Location: Allow While Using the App (then "Change to Always Allow" if offered; only needed for
     background building warnings)
7. **Pre-set FlUni on every phone:**
   - Map address: Me > Settings > Map address, type the `.local` URL printed in step 3
     (`http://<laptop>.local:8000/heatmap/?embed=app`). Open the Map tab: the campus map should load.
   - **Demo speed 60x:** Me > Developer tools > Demo controls > Time speed > 60x. **This is not saved:
     set it again after every launch or relaunch of FlUni**, on all three phones (A too).
   - **Persona** (phone B, optional but shown in step 4 of the script): Today > "See how this is worked
     out" > Demo settings... > "Load from the laptop" (default run is fine), then "Play as" > Student > pick
     one agent. Leave "Follow the map" on.
   - Leave A at "I feel fine" (the default). Do not tap "I tested positive" until the script says so; it
     cannot be undone from the UI (see Reset).
8. **Rehearsal check (30 s):** put the phones together; each Today tab should say "1 other FlUni phone
   nearby" (or 2). If not, see Troubleshooting. Then reset again with step 4 if you tapped positive.

## The script

Total 5 minutes. Say the italic lines; do the bold actions.

### 0:00 Bird's-eye view (laptop)
- **Do:** show the presenter map on the laptop (`http://localhost:8000/heatmap/`). Press play; dots walk
  the campus, colours show who is probably sick, heat pools in buildings.
- **Audience sees:** every simulated student moving, heat building up.
- *"This is the god's-eye view only we get. A real user never sees dots, only totals per building."*
- **Fallback:** map blank or tiles missing: reload; check the laptop's internet; the server terminal must
  still be running (Troubleshooting). If dead, continue with phones only and skip step 4's map part.

### 0:30 Patient zero reports (phone A)
- **Do:** on A: Me tab > "I tested positive" > in the dialog "Share that I tested positive". (The Me tab is
  the third tab.)
- **Audience sees:** A's status changes to contagious; the sheet says phones nearby will see
  "contagious" and nothing else.
- *"All A shares is a random ID and a three-level status. No name, no number."*
- **Fallback:** no confirm dialog: tap the option again. If A refuses ("you stay marked contagious"), it
  already reported earlier: run `demo_reset.sh` and redo setup for A only (`PHONES=<udid>`).

### 1:00 "Nearby" on B and C
- **Do:** put A within about 1 m of B and C. Keep B and C on the Today tab. Nothing to tap.
- **Audience sees:** within seconds Today shows "Someone within 6 ft may be sick" with advice, and a
  notification; the card counts "1 other FlUni phone nearby".
- *"Bluetooth and ultra-wideband say A is probably within 6 feet, so B and C get a heads-up at once."*
- **Fallback (Bluetooth slow):** keep the phones together, screens on, and wait 10 s; first discovery can
  take 5 to 15 s. Still nothing after 30 s: on B open Me > Developer tools and look for a peer row; if
  none, force-quit and reopen FlUni on A and B (then set 60x again).

### 1:45 Close contact at about 15 s (B, C)
- **Do:** nothing. Time runs 60x, so 15 minutes of contact takes about 15 s.
- **Audience sees:** the minutes bar fills toward 15, then "You were close to someone who may be sick"
  with the advice list (leave the room, mask, wash hands, watch for symptoms).
- *"Fifteen minutes within six feet is the CDC rule. We compressed 15 minutes into 15 seconds."*
- **Fallback:** no close-contact alert after 40 s: check Me > Developer tools > Demo controls > Time speed is
  60x on **B** (it resets to real time on relaunch). If the phones were apart for a while, keep them close;
  minutes only accrue while near.

### 2:15 Risk % and "How is this calculated?" (B)
- **Do:** B: Today > the risk card ("Your risk estimate" or, with a persona, "Campus model: n%" plus "This
  phone's estimate: n%") > "See how this is worked out".
- **Audience sees:** the formula with this phone's numbers (minutes within 6 ft, weighted: full if the
  other person tested positive, half if only symptoms) turned into a percentage.
- *"It is an estimate, not a diagnosis. Two numbers when a persona is set: the phone's own, from what it
  sensed, and the campus model's, from the whole population."*
- **Fallback:** no persona number: Demo settings... > "Load from the laptop" (needs the server); otherwise
  show the phone's own estimate only.

### 3:00 Walk-in warning (C, "Pretend I'm at...")
- **Do:** on C: Today > "See how this is worked out" > Demo settings... > "Pretend I'm at..." > pick a
  building that is red on the Map tab right now (search by name) > Done > back to Today.
- **Audience sees:** a banner (and one notification): "<Building> has a lot of illness right now.
  Consider a mask, or a different spot."
- *"Indoors, GPS cannot see rooms, so for the demo we pretend C walked into that building. The warning uses
  building totals, not who is in it."*
- **Fallback:** no banner: pick a redder building (the warning needs high illness at the current sim time;
  the Map tab's colours show it). The same building only notifies once per cool-down (the banner still
  shows); choose another building. Needs the server running (building heat comes from the laptop).

### 3:45 The Map tab updates (C)
- **Do:** C: Map tab. Leave "Follow" playing (pause/play button at the bottom).
- **Audience sees:** the user-facing heat map: buildings coloured by expected sick people, moving through
  simulated time, with no people on it.
- *"This is everything a real student ever sees: totals per building."*
- **Fallback:** "Couldn't find that address": use the IP URL from `serve_heatmap.sh` instead of `.local`.

### 4:15 Privacy talking points (no taps)
- **What is broadcast:** a random ID that changes every 15 minutes, and a 3-level status (healthy, possibly
  sick, contagious). That is all. No name, number, account or location.
- **Matching happens on the phone.** No server sees who met whom.
- **Location never leaves the phone.** FlUni uses your GPS only on your device, to match buildings.
- **Honest cost:** with only two people in a room, the status bit tells the other person who is sick.
  Needs an anonymity threshold or server-side matching before real use.
- **Pause:** Me > Settings > Detection off (or pause for 1 hour). Detection stops, nothing is shared.

### 4:45 Wrap and questions
Leave the laptop map on screen. Do not reset until the room has left.

## Reset between runs

- **Full reset (best):** `proximity/tools/demo_reset.sh`. Reinstalls FlUni on every ready, unlocked phone,
  wiping its data. Then redo steps 6 and 7 above (permissions are asked again, map address and 60x are
  gone). `WITH_HARNESS=1` also reinstalls FluniProx. `PHONES="udid1 udid2"` limits it to some phones.
- **Quick reset (no cable, about 1 minute per phone):** Me > Settings > "Delete my data" (clears status,
  contacts, map address, setup), reopen, redo onboarding, map address and 60x. This is the only way to
  undo "I tested positive" without a reinstall.
- **Same-data replay, no status change:** on B and C, Me > Developer tools > Demo controls > "Reset exposure".
  Then move A away for a few seconds and bring it back.
- Preview any command with `DRY_RUN=1`.

## Troubleshooting

| Symptom | Fix |
|---|---|
| `doctor.sh` / `demo_reset.sh` says "phone is locked" | Unlock it and keep the screen on (Auto-Lock to Never), rerun. |
| "Developer Mode is off" | Settings > Privacy & Security > Developer Mode, restart the phone. |
| "not paired" / "no tunnel" | Plug in by cable, tap Trust on the phone, wait a few seconds, rerun. |
| App won't open: "Untrusted Developer" | Settings > General > VPN & Device Management > your Apple ID > Trust. |
| App stopped opening after about a week | Free-team builds expire in 7 days: run `demo_reset.sh`. |
| Phones show "No other FlUni phones nearby" | Both must be foreground, unlocked, Bluetooth and Wi-Fi on, Local Network allowed (Settings > FlUni > Local Network). Keep them within 1 m and wait 10 to 15 s. Still none: force-quit and reopen both. |
| Nearby works but no close-contact alert | Time speed is back to real time: set 60x on the listener (Developer tools > Demo controls). |
| Alerts without any Wi-Fi/link | Fine: alerts travel over Bluetooth and the phone link, not the laptop. Only the Map tab, persona and building warnings need the laptop. |
| Map tab blank or "Couldn't find that address" | Try the IP URL printed by `serve_heatmap.sh` instead of `<laptop>.local` (some networks block .local). Same Wi-Fi, no VPN, no client isolation (try the laptop's hotspot). |
| Map loads but no data / blank buildings | The server must serve the repo root, not `heatmap/`. Run `proximity/tools/serve_heatmap.sh` (or `python3 -m http.server 8000` in the repo root). `http://<host>:8000/model/out/<run>/p_sick.csv` should download. |
| Map tiles missing | Phone and laptop need internet (tiles from OpenStreetMap, Leaflet from cdnjs). |
| `serve_heatmap.sh`: port in use | A server is already running, or pass another port and retype the address. |
| Simulator not available (`sim_test.sh`, doctor warns) | Needs a standard iOS runtime: `xcodebuild -downloadPlatform iOS`. iPhone Duo does not work. Use the real phones; simulators have no Bluetooth or UWB. |
| `git push`/`pull` over SSH fails (port 22 blocked) | Use HTTPS: `gh auth login` (HTTPS), `gh auth setup-git`, `git remote set-url origin https://github.com/<owner>/<repo>.git`. |
| Build fails with signing errors | `export FLUNI_TEAM=<team id>` (Xcode > Settings > Accounts); `doctor.sh` hints it. |

## What is real vs simulated

**Real**
- Bluetooth beacons between the phones, with the rotating random ID and the 3-level status.
- Distance from Bluetooth signal strength, and from ultra-wideband (U1/U2 phones) where available, fused
  into the probability of being within 6 ft; UWB also tunes the Bluetooth estimate.
- The 15 weighted-minute close-contact rule and the heads-up/alert logic, running on the phones.
- Notifications, the in-app advice, the report flow and the pause feature.
- No server in the loop for matching.

**Simulated or staged**
- **Time runs 60x** (15 minutes of contact in about 15 seconds); a real contact takes 15 real minutes.
- The three phones sit side by side, so "nearby" is easy; real-world crowds, pockets and walls are harder.
- **The campus is simulated:** agents, buildings' illness, the presenter map, the "Campus model %"
  persona number and the Map tab data come from the synthetic influenza run (10 agents; each stands for 50
  people in the user map). They are not real students.
- **"Pretend I'm at..."** replaces the phone's location for the walk-in warning only; real use would rely
  on GPS (poor indoors), at building level.
- The presenter map shows true infection status and positions; a real user would never see them.
- The map is served from the laptop on the local network; a deployed app would not do that.
- The phone link and GPS ranging between phones exist only in the test harness; in FlUni, location is never sent.
- Foreground only: the app must be open and unlocked; iOS hides custom Bluetooth beacons in the background.
- Privacy gap: in a 2-person room the status bit identifies the sick person.
