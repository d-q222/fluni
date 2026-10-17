# Fluniversity (fluni)

Reduce the spread of flu and other illnesses on a college campus (pilot: Stanford) by telling people
**what to do**, not just that "a contact of a contact is sick."

- **Proximity alerts** — "Someone within N feet is risky." Anonymous: no names or locations are shared.
- **Campus heat maps** — where likely infections are concentrated, now and in the near future.
- **Infection probability** — a per-person risk estimate from the contact graph, turned into advice.

The full product spec is in [docs/PRD.md](docs/PRD.md).

## Working in this repo

Several people and AI agents commit here at the same time. Before you start anything:

1. Read [AGENTS.md](AGENTS.md) for the ground rules.
2. Check [WORKSTREAMS.md](WORKSTREAMS.md) to see who owns what, and claim your piece there.

## Layout

Each workstream lives in its own top-level directory, created by its owner (see WORKSTREAMS.md).

| Path | Contents |
|------|----------|
| `docs/` | PRD, shared notes, data contracts |
| `heatmap/` | Campus infection heat map |
| `proximity/` | iOS app: live proximity alerts (Bluetooth + UWB + GPS) and the user heat map |
