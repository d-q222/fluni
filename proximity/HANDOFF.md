# FlUni (proximity/): handoff

Updated 2026-10-18 ~01:30 PDT. This covers the app's state, what is in flight, open decisions and how we work. It is read
together with README.md (how things work), DEMO.md (the demo) and RISKS.md (known risks, kept out of the demo).

## State of main (origin/main 953dcd2 or later)
- **Targets.** There is one Xcode project, generated with XcodeGen from `project.yml`, with two apps: **FlUni**
  (`com.fluni.app`, the student app) and **FluniProx** (`com.fluni.proxtest`, the test harness). `Core/` is shared
  and has no SwiftUI. Unit tests (`xcodebuild test -scheme FluniProx`): **576 pass**.
- **Window structure.** `FlUniApp` → `AppRoot` view → a TabView with tags. The system tab bar is hidden
  (`UITabBar.appearance().isHidden` + `.toolbar(.hidden, for: .tabBar)`) and **Lisa's TissueTabBar** is overlaid.
  The tabs are Today / Map / Me, with ids `tab.today` / `tab.map` / `tab.me`.
  - Don't put tab content in a hand-made ZStack: Today's UIKit nav stack stayed on top.
  - Don't put App-level @State overlays on the TabView root: they never drew.
- **Intro.** Lisa's swirl intro is `IntroController`. It shows in its own UIWindow above everything and is triggered by
  UIKit `didBecomeActive` / `didEnterBackground` through `IntroGate`. It plays on every open and never invisibly in the
  background. SwiftUI's scenePhase missed the switch to active, and an earlier poster/cover approach got stuck on screen.
- **Tissue alert** (`TissueAlert.swift`, Lisa's art):
  - It pops on Today for a new alert.
  - Drag up to pull: the frames follow the finger, hard cuts only, no fades, and the text appears instantly at the end.
  - Drag down to push it back (the frames reverse). "Got it" closes at once and is recorded as read.
  - The wiggle is ±0.4° with a ~2.6 s period. The owner says it's fine.
- **Scroll room.** Each tab's scroll view has a bottom content margin of 0.75 × (bar height + allowance), so footers
  clear the tissue box.
- **Risk.** Rio's per-peer dose formula, golden-matched to `model/infer.js`.
  - `liveRisk` updates every tick; `RiskEstimate.liveText` shows one decimal below 10%.
  - Each phone broadcasts its own score: the FLU2 beacon carries the status, a sqrt-byte score and days since onset.
    The owner ruled that other phones use it but it is never shown.
  - The status floor is 0.97 for positive and 0.6 for symptoms. Per-building room context comes from the phone's
    own fix.
- **Persistence.** `RiskState` survives a swipe-away or crash. It holds the tracker, the AlertGate and the read state,
  saved on level changes, notifications, resign-active and every 30 s.
  - No re-notification on a cold launch.
  - Test launches (keys in `LaunchMode.testKeys`, which now includes `-demoPeer`) never touch saved data.
- **Sick mode.** A user who reported symptoms or a positive test sees the stay-home card on Today (and Me). They never
  see "All clear" or a risk %.
- **Off screen.**
  - Held BLE links with RSSI polling, with an honest σ.
  - Notifications fire with the app closed.
  - Visits monitoring is on (owner: keep).
  - Always-location keep-alive with the blue indicator (owner: request Always); the card is on Today.
- **Crash fixes.**
  - MPC `_BrowserCancel` (Apple bug): browsers are never stopped or restarted.
  - `UWBRanger` token SIGSEGV.
- **Demo run.** `influenza_none_n1000_d14_s42_f12e71fa` → now **`influenza_none_n1000_d4_s42_73b8452c`** (4-day,
  spread housing). The live-clock rule 3 maps weekends to the run's last day (Thursday).
  - Map bundle: `tools/sync_map_bundle.sh` copies `heatmap/out/app-bundle` (the heat map team's code).
  - Every map tap answers, and shared outlines (dining inside a dorm) are one target.

## In flight (subagents; the coordinator merges, pushes and installs)
| Work | Where | State |
|---|---|---|
| Tissue/scroll/info fixes | `/Users/dqi26/fluni-tissue` (flu-tissue) | Merged up to e8e2392. Finishing: Map legend (i), large text, close-contact sheet, full UI run. |
| Phone bug hunt | phones, scratch `UITests/ZZExplore.swift` | Blocked on **unlocked phones**. Left: control run, tissue drag check (`-demoPeer contagious@0.5 -speed 60`), Pause on Aiden, a no-arg relaunch. **ZZExplore.swift was committed to main by mistake: `git rm` it when the agent is done.** |
| Screenshots for the heat map team | sim → `/Users/dqi26/fluni-screens/phoneref2/` | Running. Message the file list to the heat map session when done. |
| Home mockup v2 (risk-first) | `/Users/dqi26/fluni-screens/home-v2/` (`mock2-sheet.png`, `compare2.png`, `NOTES.md`, src) | **Done. Waiting for the owner's verdict**, then build. |

## Design direction (owner)
- **Old timeline redesign** (branch flu-design2, dc85913): ON HOLD, "too cluttered". Don't merge it wholesale. Parts
  that can be cherry-picked: the sticker report, the stay-home track, the alert inbox, the place log, and the UI-test
  fixes (which fix the 5 old UI test failures).
- **New home plan.** The top box holds only the % (with a tiny band indicator) and "I don't feel well".
  - A compact heads-up / close-contact strip sits above the %.
  - The day history is below.
  - Sick mode is smaller, with the day markers in front of the dotted line.
  - Mockup v1 (`mock-*`) is kept for comparison.
- **Lisa's work wins.** Use her type (Fredoka/Nunito, Fraunces only for "FlUni"), her tab bar, her intro and her
  tissue alert.
  - Merge her PRs fast (build check only) and send design feedback through GitHub issues.
  - Open issues: **#21** (tab bar art: more room at the bottom/sides) and **#24** (logo asset: the top-left text
    logo is ugly).

## Open decisions for the owner
1. Should a negative PCR clear a positive? (Today: never. The heat map mock lets it.)
2. The Vaden phone number and hours for the stay-home card.
3. Require UWB corroboration for a close contact (anti-spoofing)?
4. "Pause until tomorrow": midnight or 7 am?
5. Aiden's phone has pretend exposure from two `-demoPeer` runs before the fix. Reset it (Settings → Reset exposure)
   or let it age out within 24 h.

## Devices and how we work
- **Phones:**
  - Daniel's 17 Pro `00008150-001E213A0C80401C` (has a saved "tested positive" from testing).
  - Aiden's 15 `00008120-001458620E63601E` (**at the 3-app free-profile limit**: FlUni, FluniProx, UITests-Runner).
  - Rio's 14 `00008110-000E491A22A0201E` (locked or unavailable most of the night).
  - Team `A5C3J42JT3`. Error 4016 means a phone is locked.
- **Install:** build Debug with `FLUNI_TEAM=A5C3J42JT3 -allowProvisioningUpdates` into
  `scratchpad/dd-device`, then `xcrun devicectl device install app` over the existing app. Never uninstall.
- **Simulators:** never use iPhone Duo. Use "FlUni UITest Base" A153C27A…, "iPhone 18 Pro" A6203245… or
  "FlUni Design" FB16F3FF….
- **Working style:** the coordinator delegates implementation and UI/device testing to subagents (own worktrees under
  `/Users/dqi26/fluni-<x>`). Merge (never rebase) into `proximity-work` in `/Users/dqi26/fluni-prox`, push
  `HEAD:main`, install. Stage specific files only; never `git add -A`.
- **Heat map team:** a separate Claude session ("Campus disease tracking app"). Message it for usermap/bundle changes;
  it owns `heatmap/`.
