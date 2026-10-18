# FlUni: known risks and open trade-offs

This is a working record for later. It is not part of the demo or the pitch: don't show it, link to it from the app or
mention it in the presentation. Last updated 2026-10-18.

## Privacy

1. **Each phone broadcasts its own risk score.** The product owner ruled that phones broadcast their own percentage so
   others can compute an accurate estimate; FlUni never displays another person's score. The score travels in plain
   Bluetooth inside the beacon, though. Anyone with a free BLE scanner app can read it, so "they can't see it" is true
   in FlUni, not over the air.
   - In a room with only two people, the value effectively reveals that person's health risk.
   - Kept at full (sqrt-encoded) precision for accuracy. Rounding to coarse bands, or broadcasting only above-baseline
     values, would reduce the leak.
2. **Infected people's floors are visible the same way.** A self-reported positive broadcasts at least 97% and
   symptoms at least 60%, which is the same information the 3-level status already exposed, now as a number.
3. **Days since symptom onset are on the air.** Since the FLU2 beacon (2026-10-17) a phone whose user reported
   symptoms or a positive test also broadcasts the whole days since onset (or the positive test), 0-14, so other
   phones can weight the dose by illness stage. That is more health detail per person than the 3-level status; like
   the score, FlUni never shows it, but any BLE scanner can read it. Symptoms, dates and test kinds stay on the phone.
4. **MPC peer name.** If a crash fix makes the MultipeerConnectivity name stable for a whole app session (rather than
   rotating every 15 min with the BLE ID), an observer could link a person's rotating IDs within that session.
5. **On-phone logs.** The 24 h place log (building visits) and exposure history stay on the phone and are covered by
   Delete my data. A lost, unlocked phone shows where its owner has been today.

## Integrity and spoofing

1. **A fake phone can claim a high score** without reporting anything. Mitigations:
   - ContactGuard counts only the top 2 contacts;
   - burst-of-new-IDs and RSSI-plausibility rules;
   - status/score consistency checks (status none but score ≥ 0.9, or a jump of more than 0.5 within 1 min, is
     ignored).
   It is reduced, not eliminated. Nothing authenticates a beacon.
2. **Echo between people.** Two people who shared an exposure slightly raise each other's scores (second-hand risk,
   partly double-counted). A one-tick lag stops a loop, and nobody can start an echo from the 2% baseline (s = P − 0.02
   = 0), but small amplification remains.
3. **Third-party app on our signal.** An app called "Fluniversity" (dev.fluniversity.app, not ours) on two demo phones
   appeared to broadcast a contagious beacon in our format. False alerts stopped when it was terminated.

## Accuracy limits (what the phone cannot know)

- **Room size and ventilation:** the building comes from the phone's own GPS fix; the room inside it can't be known,
  so each building stands for its median-volume room in the sim run's rooms.csv (`building_rooms.csv`). Without a
  good fix, the default room.
- **Indoors vs outdoors and walls:** outdoors only at a known outdoor place or with the fix clearly away from every
  building; walls (whether the peer is in the same room) can't be known.
- **Days since the source's symptoms began:** broadcast by FLU2 peers; old FLU1 builds and healthy peers use the
  0.352 average stage.
- **Second-hand risk and look-back after a report:** need everyone's contacts.
- **Window:** the phone keeps the campus model's close-contact rule (weighted minutes within 6 ft of someone who may be
  sick, running until 2 h pass with no such contact), but its dose uses only the last 24 h on the phone vs 7-day
  evidence in the campus model.
- **Bluetooth-only distance:** about ±(70% + 0.3 m), or ±(40% + 0.3 m) once calibrated against UWB. UWB (best,
  about ±10 cm) only works while FlUni is open and a peer link exists.

## Platform limits

- A powered-off phone can't be detected.
- A force-quit app is not relaunched for Bluetooth state restoration. Location-based relaunch (geofences) may still
  work; the details belong here once verified on the phones.
- iOS background Bluetooth is slower and coarser than foreground (overflow-area advertising, no UWB, no
  MultipeerConnectivity).
- **UWB is foreground only, by iOS design** (checked against Apple's NI docs and the iOS 27.1 SDK headers,
  2026-10-18). When FlUni goes to the background or the screen locks, iOS suspends every iPhone-to-iPhone NI
  session; a long suspension ends it. Background NI exists only for third-party UWB accessories paired over
  Bluetooth (`NINearbyAccessoryConfiguration(accessoryData:bluetoothPeerIdentifier:)`), not for other iPhones.
  FlUni doesn't fake it: off screen, distance comes from Bluetooth alone with its wider error (±(70 % + 0.3 m)),
  and UWB comes back when FlUni is opened (sessions re-made at once; a dropped link needs a 2.5-4.5 s handshake
  first). Keeping FlUni on screen during a demo (idle timer off while Today is shown) would keep UWB on, but it
  drains battery: proposed as a Debug-only demo toggle, not built; owner to decide.
- **How many UWB sessions at once:** iOS sets the limit dynamically (no published number); past it a session
  fails with activeSessionsLimitExceeded and FlUni retries it every 5-30 s. Links are capped at 8 per identity
  (up to 16 sessions briefly during an ID rotation's make-before-break).
- **Nearby Interaction permission:** asked on the first session (onboarding explains it first). "Don't Allow"
  means no UWB; FlUni tries once more each time it is foregrounded in case it was changed in Settings, and the
  Developer screen shows "NOT ALLOWED in Settings".
- **Low Power Mode:** Apple documents no effect on NI; not measured. The `uwb metric` line records it so a soak
  can tell.
- **Camera assistance** is not used (distance only; it would need the camera).

## Reliability

- **MultipeerConnectivity `_BrowserCancel` crash:** 12 FlUni and 7 harness crashes on 2026-10-17. Partial fix a8ab90b;
  a full fix is in progress. Record the outcome here.
- **UWB `NIERROR_INVALID_CONFIGURATION_DESCRIPTION` (cause found, fixed in flu-uwb, not yet soaked on phones).**
  Every one of ~180 in the 2026-10-17/18 logs followed a link to a peer whose hello ID Bluetooth never heard
  (`heard=no`): the other FlUni app on the same phone (FlUni and the harness share the MPC service type) or FlUni
  in a simulator over the Mac's network. Apple: invalidConfiguration means the peer's discovery token is invalid
  for this device, so those can never range. Real phone pairs, including U2 pairs with extended distance on,
  ranged fine (e.g. 0.66-0.88 m). The old "extended distance rejected" reading was a misattribution.
  Fix: no NI session for a link peer until Bluetooth hears its hello ID (UWBRanger.setHeard).
- **UWB uptime (fixed in flu-uwb, needs a phone soak to measure).** Before: an invalid configuration stopped UWB
  for that link for good (retried only on a new link, which may never come), a token that arrived before our
  session existed was dropped, the stop also cleared the peer's link ID, and sessions were re-made in the
  background where iOS suspends them at once. Now: retry with a fresh session and token after 0.5, 1, 2 … 30 s,
  forever while the phone is linked and heard; early tokens are kept; no sessions in the background and every
  missing one is re-made the moment FlUni is foregrounded. Coverage and invalidation counts are on the Developer
  screen ("UWB health") and in `uwb metric` log lines. Coverage before/after is **not measured yet**.
- **Two FlUni apps on one phone** (FlUni + harness) link to each other over MPC. Harmless now (no UWB without a
  Bluetooth-heard ID, and the hello's ID is ignored), but each such link uses one of the 8 link slots.
- **Phones auto-lock during tests:** demo phones need Auto-Lock set to Never.
