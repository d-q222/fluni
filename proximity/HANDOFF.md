# FlUni (proximity/): handoff

Updated 2026-10-18 ~03:45 PDT. This covers the app's state, what is in flight, open decisions and how we work. It is read
together with README.md (how things work), DEMO.md (the demo) and RISKS.md (known risks, kept out of the demo).

## State of main (origin/main bcf5666 or later)
- **Targets.** One XcodeGen project (`project.yml`) with two apps: **FlUni** (`com.fluni.app`, the student app) and
  **FluniProx** (`com.fluni.proxtest`, the harness). `Core/` is shared and has no SwiftUI. Tests: **618 unit** and
  **12/12 UI** pass.
- **Window structure.** `FlUniApp` → `AppRoot` → a TabView with tags. The system tab bar is hidden and **Lisa's
  TissueTabBar** is overlaid (Today / Map / Me, ids `tab.today` / `tab.map` / `tab.me`).
  - Don't put tabs in a hand-made ZStack.
  - Don't put App-level @State overlays on the TabView root.
- **Intro.** Lisa's swirl, `IntroController`, in its own UIWindow, triggered by UIKit active/background via `IntroGate`.
- **Today: risk-first home (mock v4, owner-approved).**
  - Header: a speech bubble plus a small tissue companion, top right. **No logo.** Lisa's logo is in the asset catalog
    behind `TodayView.showLogo = false`; the owner will revisit it.
  - The card holds only the % (`model.ownScore`), a "● Low" band marker ("up from X" when it rose) and "I don't feel
    well". On a heads-up or close contact, a compact strip sits inside the card.
  - "Your day so far": a timeline built from the on-phone place log (`Core/PlaceLog.swift`, building names only, never
    sent) and Recent contacts (`Core/DayTimeline.swift`). The time column starts at the page margin.
  - **Sick mode** (symptoms or a positive): "You're staying home / Day N of 5", with **no subtext**, the Better / The
    same / Worse check-in, the recovery track, the tips, and a Vaden tap-to-call line. Never a % or "All clear".
- **Owner rulings implemented 2026-10-18:**
  - A negative **PCR** dated on or after the positive clears it; with symptoms the user stays "possibly sick". A rapid
    test never clears it.
  - "Pause until tomorrow" ends at **6 AM**.
  - **Vaden**: (650) 498-2336, Mon–Fri 8:15–5.
  - **UWB is not required** for a close contact.
  - **Sick users** in a busy building get "You're out at X while you're unwell. Head home and rest up when you can."
    instead of the illness warning.
  - **Close-contact clock = the model's episode rule.** Status-weighted minutes (×1 contagious, ×0.5 possibly sick;
    strongest peer only) within 6 ft. Gaps under 2 h are bridged; after **2 h** away from possibly-sick people it
    resets to exactly 0. The alert fires at 15. Rio's dose / live % keeps its own 24 h window (unchanged, validated
    against `model/infer.js`).
- **Bug-hunt fixes:**
  - the Map is full-bleed at the top and stops above the tissue box (legend (i) tappable);
  - "Low, but follow the … steps" during alerts;
  - "15 of 15 min" cap;
  - the Pause dialog and the Delete alert with Cancel;
  - Debug-only map address;
  - one heads-up;
  - an in-progress contact survives a kill.
- **Unchanged from before:**
  - Rio's per-peer dose formula, live risk, and FLU2 own-score sharing (never shown).
  - `RiskState` persistence (no re-alert after a swipe-away).
  - Lisa's tissue alert ("Got it" instant, drag-down reverses).
  - Off-screen detection, Always location and Visits.
  - The crash fixes.
  - Demo run `influenza_none_n1000_d4_s42_73b8452c`.

## In flight (branches not on main yet)
| Work | Where | State |
|---|---|---|
| Notification preferences + closed-app alerts | `flu-notify` (d477842, 7dbb0d8, 1128105, merge 75fdf7a), `/Users/dqi26/fluni-notify` | **Done, not merged: needs a phone check first.** 626 unit tests pass. The full UI run failed 12/13 at launch on a busy "FlUni UITest Base" sim; the new toggle test and one other pass on iPhone 18 Pro; rerun the full UI suite on an idle sim. **What it does:**<br>• Settings toggles (Someone nearby may be sick / Close contact / Busy buildings, default on), all posting through one gate, `Core/NotificationPrefs.swift` (`SystemNotifier`).<br>• Fixes sick wording on a locked relaunch.<br>• Makes RISKS/README honest.<br>**Swipe-away:** background and locked post (code path); after a force-quit, only a location relaunch can bring FlUni back, and iOS 26.4+ may not do that. Settings now says "Don't swipe FlUni away". **To verify:** a phone test (background/locked with a possibly-sick peer), and a human swipe-away plus a walk of about 500 m. |
| UWB reliability | `flu-uwb` (daaf68f, 56252a9), `/Users/dqi26/fluni-uwb` | **Done, not merged: needs a 10-min two-phone soak first.** 640 unit tests pass. **Findings:**<br>• `NIERROR_INVALID_CONFIGURATION_DESCRIPTION` came only from unrangeable links (FlUni↔harness on one phone, or a simulator); real pairs ranged fine.<br>• Fixes: start only when Bluetooth heard the peer; retry with backoff instead of stopping for good; keep early tokens; errors no longer drop the link; re-make sessions on foreground.<br>• Developer → Radios "UWB health" (coverage %, errors by reason, resume time).<br>**Background:** iPhone↔iPhone UWB is foreground-only (iOS). **Owner's call:** a Debug-only keep-screen-awake demo toggle. |
| Home v5 (text-light) mockup | `/Users/dqi26/fluni-screens/home-v5/` (`compare5.png`, `mock5-sheet.png`, `PRINCIPLES.md`, `AUDIT.md`, `NOTES.md`) | **Awaiting owner approval.** −54% words on the four home states. One-line timeline rows, the alert said once, close-contact steps in a one-tap sheet with Call Vaden, sick-mode action rows, ⓘ instead of the f(x) link. Self-scored 6.1 → 7.9; an independent re-grade is offered. |

## Open decisions for the owner
1. **Home v5:** "build v5" or changes. Three sub-points:
   - the privacy line shortened to "Your precise location stays on this phone." (it changes the exact promise; the
     full sentence stays one tap away);
   - the close-contact bubble "I'm right here." and the strip title "Close contact";
   - short building names, which need a per-building short-name field.
2. **Fluniversity on Rio's phone.** This third-party app earlier broadcast a contagious-looking beacon in our format
   (false alerts). Delete it? The owner or Rio does that on the phone; agents never uninstall.
3. **The model's starting prevalence** now comes from the run (Aiden, 878dc54), not a fixed 2%. Should FlUni's 2%
   baseline follow the run?
4. **Phone % vs presenter mock %.** The mock shows the campus model's P; the phone shows its own estimate (Rio's
   formula). Align or keep?
5. **Should the live % also reset after 2 h** like the close-contact minutes? It's 24 h today.
6. Small ones:
   - an explicit Cancel row in the Pause pop-up (iOS shows it as a popover, dismissed by tapping outside);
   - clear old contact history on the demo phones for a clean timeline (exposure reset keeps the 14-day history).
7. **Logo:** parked behind the flag (owner: "keep the option open").

## Lisa (design)
- **#25** (new home): her sign-off, four small companion poses (calm / watchful / worried / resting, ~42 pt), a
  hand-drawn speech bubble, and optional hand-drawn icons, markers and check-in faces.
- **#24** (logo): parked.
- **#21** (tab bar art: more room at the bottom and sides): still needed.
- The owner is telling her in person; the issues are the written record.

## Devices and how we work
- **Phones:** all three have bcf5666.
  - **Daniel's** 17 Pro `00008150-001E213A0C80401C` (U2): healthy. Old contact history is on its timeline.
  - **Aiden's** 15 `00008120-001458620E63601E`: healthy; **disconnected** at 03:30; at the 3-app free-profile limit.
  - **Rio's** 14 "iPhone (84)" `00008110-000E491A22A0201E` (U1): locked at 03:40; **3 apps (FlUni, FluniProx,
    Fluniversity), so no room for a UI test runner.**
  - Team `A5C3J42JT3`. Error 4016 means a phone is locked.
- **One automation per phone at a time.** Two UI-test runs or installs on one phone collide. The coordinator assigns
  phones.
- **Install:** Debug with `FLUNI_TEAM=A5C3J42JT3 -allowProvisioningUpdates`, then `xcrun devicectl device install app`
  over the existing app. Never uninstall; never use `FLUNI_UITEST_RESET` or Delete my data on phones.
- **Simulators:** never iPhone Duo. Use "iPhone 18 Pro", "FlUni UITest Base", "FlUni Design" or "FlUni Home".
- **Working style:** the coordinator delegates implementation and UI/device testing to subagents (own worktrees under
  `/Users/dqi26/fluni-<x>`). Merge (never rebase) into `proximity-work` in `/Users/dqi26/fluni-prox`, push `HEAD:main`,
  install. Stage specific files only; never `git add -A`.
- **Commit trailer (owner, 2026-10-18):** end with `Co-Authored-By: Claude <model> <noreply@anthropic.com>`; **no
  Claude-Session line.** The rule is written in `CLAUDE.local.md` (gitignored, copied into each worktree). Use `-m` on
  merge commits too.
- **Git fetch:** origin carries large sim data (~1.3 GB). Never wrap `git fetch` in a short timeout; it kills the
  download ("early EOF").
- **Heat map team:** a separate Claude session ("Campus disease tracking app"). Its presenter phone mock matches the v4
  home (e121b54) and will follow v5 once approved. The model session is "fluni-01".
