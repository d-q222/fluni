# Heat map live demo: run-of-show (about 4 minutes)

The laptop shows the god's-eye view (every simulated student, room-level heat) and ends on what a real
student sees, then hands over to the real iPhones. Times below were checked on the default run
`influenza_none_n1000_d4_s42_73b8452c` (1,000 agents, Mon 5 to Thu 8 Jan, seed 42). The phone part is
scripted in [../proximity/DEMO.md](../proximity/DEMO.md).

## Setup (T-10 min)

1. **Start it**, from any folder: `heatmap/tools/demo.sh` (run it as `~/fluni/heatmap/tools/demo.sh`).
   It serves the repo root on port 8766 if nothing is there yet, opens the page in your default browser
   and prints the shortcuts. Running it again is safe. `--run <id>` picks another run in `sim/runs/`,
   `--port <n>` another port. The run is in git, so `git pull` is all the data you need.
2. **URL:** `http://localhost:8766/heatmap/index.html`. Use Chrome (what this was tested in).
3. **Screen:** mirror to the projector at 1920x1080 if you can. Browser at 100% zoom (Cmd-0), full screen
   (Ctrl-Cmd-F), bookmarks bar hidden, one tab. Below 1400 px wide the header wraps into two rows, and at
   1280x720 the phone shrinks to about half size, so avoid that.
4. **Laptop:** plugged in, Do Not Disturb on, sleep and screen saver off (`caffeinate -d` in a spare
   terminal), brightness up, other apps quit.
5. **Wi-Fi:** leave it on. The default "Sim map" pulls street names, the lake and labels from OpenFreeMap
   (and MapLibre from unpkg). Everything else is local.
6. **Warm up:** the page opens on **Day 3 · Wed 1:20 pm, paused**, Room-level, "People" ticked, 10 min/s,
   about 35 expected sick in view. Press `J` once to check the jumps work, then reload (Cmd-R) to reset.
7. **Phones:** the FlUni app open on the **Map tab** (its map is an offline copy of "What users see", no
   laptop needed), unlocked, Auto-Lock Never, Bluetooth on, battery over 50%. Permissions and who
   plays patient zero are in [../proximity/DEMO.md](../proximity/DEMO.md).

## Shortcuts

| Key | Does |
|---|---|
| `Space` | Play / pause |
| `←` `→` | Back / forward 10 min |
| `[` `]` | Slower / faster (2, 10, 30 min/s, 1 h/s) |
| `J` | Open "Jump to…" (then click an item) |
| `?` | Show this list on screen |
| `Esc` | Close the phone and the "Why this %?" panel |
| Header | **Room-level** / **What users see**; **Display** holds the base map |

## The beats

Beat 3 and 4 jump to different days on purpose; say "let me show two moments".

### 1. Campus at a glance (0:00 to 0:30)

- **Do:** nothing. Page is paused on Wed 1:20 pm. Point at the legend.
- **See:** the Stanford campus, green dots (people), warm patches inside buildings only. Legend says
  "about 35 expected sick people in view".
- **Say:** "Each patch is the expected number of sick people above the 2% baseline, and it only ever sits
  inside buildings, because that is where people share air."

### 2. Press play (0:30 to 1:00)

- **Do:** `Space`. Let it run about 6 seconds (1:20 to about 2:20 pm), then `Space` again.
- **See:** dots walk the real footpaths between buildings, heat appears and fades as they arrive and leave.
- **Say:** "These are 1,000 simulated students on a four-day schedule; the heat follows them from room to room."

### 3. Hottest building, then a person (1:00 to 2:30)

- **Do:** `J`, click **Breer Library at its peak**. The map flies in over about 1.5 s.
  Then click a red dot in the cluster in the middle of the screen (scroll once to zoom if the dots are
  small). Click **Why this %?** on the pink presenter bar under the phone.
- **Lands on:** **Day 4 · Thu 2:50 pm**. Breer Library has 86 people and about 7 sick (5.5 above
  baseline); about 21 expected sick in view. A heads-up phone may open if you click a neighbour.
- **Rehearsed person:** **A0237**, the reddest dot in Breer Library (63% campus model, 88% on the phone).
  To open exactly that person, load `?at=5210&agent=A0237&why=1`.
- **See:** the phone mock (Today tab: "Breer Library has a lot of illness right now", 88% high) and the
  panel "Why A0237 is at 63%": a contact graph and Rio's formula with numbers. Key line: **810 minutes at
  0.4 m from A0239 (97% risk), dose 0.977, so λ = 0.62 and it adds 55% to p.**
- **Say:** "Heat stays in the rooms. This is a roommate: 13 hours at arm's length from someone who later
  reported sick. Every number here is Rio's dose formula, Baker et al., PNAS 2021."
- **Note:** the pink bar says "A0237 is healthy". That is the simulator's secret truth, shown only to
  the presenter; the model never sees it.

### 4. Close-contact alert on the phone (2:30 to 3:00)

- **Do:** `Esc`, `J`, click **First close-contact alert**.
- **Lands on:** **Day 3 · Wed 8:40 am**, phone of **A0939** at Vaden Health Center, bar at **15 / 15 min**.
- **See:** "You were close to someone who may be sick. From 8:10 am to 8:40 am you were within 6 ft of a
  phone whose owner reported symptoms", four steps, "Your risk estimate went from 2.0% to 3.3%".
- **Say:** "Fifteen minutes within 6 feet is the alert. The phone only uses what it saw by Bluetooth and
  ultra-wideband; it tells you what to do and never who it was."
- **Avoid:** "Why this %?" on A0939. It says "no risky contacts yet, 5.4% is the community baseline"
  because the campus model has not counted that contact. Use beat 3's person for the formula.

### 5. What users actually get (3:00 to 3:35)

- **Do:** `Esc`, click **What users see** in the header, zoom out with the `-` button to show the campus,
  click a building (Breer Library, if you are still on Thu 2:50 pm). Optionally pick **In 1 hour** in the new
  forecast menu.
- **See:** no dots, no rooms: buildings filled by expected sick count, names on them, a slim legend.
  The tap shows **"Breer Library: about 7.3 sick of 86 people"**.
- **Say:** "This is all a student sees: building totals. Buildings with fewer than 4 people are left out,
  and nobody's score or location ever leaves their phone."

### 6. Hand to the real iPhone (3:35 to 4:00)

- **Do:** pick up a phone on the Map tab.
- **See:** the same map, drawn offline inside the app; Today tab shows the live Bluetooth alert.
- **Say:** "Same map, no laptop and no internet. Now the live part." Continue with
  [../proximity/DEMO.md](../proximity/DEMO.md) at "Nearby".

## Fallbacks

| Problem | Do |
|---|---|
| **No wifi** | The page works. Street names, the lake and road labels disappear (plain footprints and footpaths stay). Turn wifi off before opening the page rather than mid-load. The "Street map" option under Display needs network, so don't use it. |
| **Slow laptop / choppy** | Untick **People** (heat only), keep the speed at 10 min/s, quit other apps and browser tabs, close the math panel. If still bad, skip beat 2 and use `J` jumps only. |
| **Wrong run or moment** | Reload (Cmd-R): back to Wed 1:20 pm on the default run. Pick a moment with `?at=<minutes since Mon 00:00>`: beat 3 is `at=5210`, beat 4 is `at=3400`. `?run=<id>` picks a run. |
| **Phone panel stuck or covering a dot** | `Esc`, or the **Close** button on the pink bar. Reload if it still won't go. |
| **Click opens the wrong person** | `Esc` and click again, or use a URL: `?at=5210&agent=A0237` (beat 3), `?at=3400&agent=A0939` (beat 4). |
| **Server died** | Run `heatmap/tools/demo.sh` again. |
| **Page says it couldn't load the run** | You opened it from the wrong place: use the `demo.sh` URL (the server must be the repo root). |

URL options (combine with `&`): `run`, `at`, `agent`, `why=1`, `view=public`, `horizon=60`, `color=truth`.
The full list is in [README.md](README.md).

## Likely questions

- **What does the heat mean?** Expected number of infected people near each spot, above a 2% background
  rate, per 1,000 m². It is a probability sum, not a head count of confirmed cases.
- **Why is the phone's number different from the campus model's?** They know different things. The campus
  model sees everyone's contacts and reports. A phone only knows its own Bluetooth contacts and its owner's
  report, using the same dose formula. A0237 shows it: 63% campus, 88% on the phone. When the other person has no app or hasn't reported yet, the phone can't see the contact, so campus can be far higher (for example A0451 on Wed 8:40: 29% campus, 2% phone).
- **Privacy?** Phones share a rotating ID and a three-level status, nothing else. A phone's score is never
  shown to anyone. The user map is built from building totals only, hides buildings with fewer than 4
  people, and gets no agent ids, positions or contacts. Location stays on the phone.
- **Where does the data come from?** The agent simulator (`sim/`): students with schedules, dorms and
  classes on the real Stanford footprints, calibrated to R of about 1.6. The probability model is Rio's
  exposure formula from Baker et al., PNAS 2021 (Wells-Riley aerosol dose, room volume and ventilation,
  distance and time), run over the sim's contacts.
- **Is that real data?** No: simulated students, so nothing about real people. That is also why we can
  show every dot.
- **How can a healthy person be 63%?** It is a risk, not a diagnosis: 13 hours next to someone who later
  reported sick. The simulator knows they are healthy; the model, like a phone, does not.
- **Why does a quiet run look as red as a busy one?** The colour scale is relative to each run
  ([HANDOFF.md](HANDOFF.md), open questions).
