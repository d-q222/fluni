"""Main loop: build the world, step behavior -> contacts -> disease -> reports -> intervention, stream output."""
import copy
import time
from datetime import datetime, timedelta
from pathlib import Path

import numpy as np
import pandas as pd

from . import codes
from .behavior import Behavior
from .campus import Campus
from .config import ROOT, code_version, config_hash
from .contacts import contacts_frame, find_contacts
from .disease import Disease, infections_frame, room_exposure_frame
from .interventions import REGISTRY, apply_actions, build_observable
from .output import RunWriter, TimelineChanges, timeline_frame, trips_frame
from .plans import build_plans
from .population import build_population
from .reports import Reports, reports_frame
from .schedule import build_events, build_sections, events_frame_for_csv, sections_frame_for_csv
from .summary import compute_summary

RNG_STREAMS = ["map", "population", "sections", "events", "plans", "behavior", "disease", "reports", "intervention"]

BUFFER_FIELDS = {  # name -> dtype of the (steps_per_day, N) day buffer
    "room": np.int32, "b": np.int32, "x": np.float64, "y": np.float64, "floor": np.float64,
    "indoor": bool, "off_map": bool, "act": np.int8, "event": np.int32, "section": np.int32,
    "entrance": np.int32, "moving": bool, "state": np.int8, "dsi": np.float64, "inf": np.float64,
    "symptomatic": bool, "severity": np.float64, "masked": bool, "self_status": np.int8,
    "test_status": np.int8, "isolating": bool, "action": object, "transport": np.int8,
}


def recorded_config(cfg):
    """Config as stored in config.json / hashed into run_id: where the run is written is not a parameter."""
    rec = copy.deepcopy(cfg)
    rec["run"].pop("out_dir", None)
    if rec["run"].get("intervention") != "fluni":  # keeps run ids of non-app runs as before the app policy
        rec.get("interventions", {}).pop("fluni", None)
    if not _llm_on(rec):  # keeps run ids of runs without Claude-driven agents unchanged
        rec.pop("llm_agents", None)
    pc = rec.get("personality", {})
    if pc.get("mode", "off") == "off" or pc.get("weights_source", "config") != "calibrated":
        rec.pop("behavior_calibrated", None)  # configs/behavior_calibrated.json only counts when used
    else:
        bc = rec.get("behavior_calibrated", {})
        rec["behavior_calibrated"] = {k: bc.get(k) for k in ("weights", "weights_fitted", "source_runs", "created")}
    if rec.get("personality", {}).get("mode", "off") == "off":  # keeps run ids of runs without Big Five
        rec.pop("personality", None)
    return rec


def _llm_on(cfg):
    c = cfg.get("llm_agents", {})
    return bool(c.get("n_agents") or c.get("agent_ids"))


def make_run_id(cfg):
    r = cfg["run"]
    return (f"{cfg['disease']['preset']}_{r['intervention']}_n{r['n_agents']}_d{r['days']}"
            f"_s{r['seed']}_{config_hash(recorded_config(cfg))[:8]}")


def _log(msg, t0):
    print(f"[{time.perf_counter() - t0:7.1f}s] {msg}", flush=True)


def run(cfg, external_provider=None, quiet=False, llm_client=None):
    """Run one simulation; returns the run directory. external_provider(t) -> dict is passed to
    the intervention through ObservableState.external (downstream closed-loop hook). llm_client
    replaces the Anthropic client of Claude-driven agents (tests)."""
    t_start = time.perf_counter()
    log = (lambda m: None) if quiet else (lambda m: _log(m, t_start))
    rc = cfg["run"]
    step_min = rc["step_min"]
    spd = 1440 // step_min
    T = rc["days"] * spd
    step_s = step_min * 60

    rngs = dict(zip(RNG_STREAMS, (np.random.default_rng(s) for s in
                                  np.random.SeedSequence(rc["seed"]).spawn(len(RNG_STREAMS)))))

    campus = Campus.build(cfg["map"], data_dir=ROOT / "data" / "osm")
    log(f"campus: {len(campus.buildings)} buildings, {len(campus.rooms)} rooms")
    pop = build_population(cfg, campus, rngs["population"])
    sections = build_sections(cfg, campus, pop, rngs["sections"])
    events = build_events(cfg, campus, pop, sections, rngs["events"])
    log(f"population {pop.N}, {len(sections)} sections, {len(events)} events")
    plans = build_plans(cfg, campus, pop, sections, events, rngs["plans"])
    log("plans built")
    beh = Behavior(cfg, campus, pop, plans, rngs["behavior"])
    dis = Disease(cfg, campus, pop, rngs["disease"])
    if rc.get("initial_seeds", 0):
        dis.seed_initial(rc["initial_seeds"], 0)
    rep = Reports(cfg, campus, pop, rngs["reports"])
    llm = None
    if _llm_on(cfg):
        from .llm_agents import LLMAgents
        llm = LLMAgents(cfg, campus, pop, plans, sections, events, beh, rep, client=llm_client)
        log(f"Claude-driven agents: {', '.join(pop.agent_id[i] for i in llm.idx)} ({cfg['llm_agents']['model']})")
    intervention = REGISTRY[rc["intervention"]]()
    if hasattr(intervention, "reset"):
        intervention.reset({"cfg": cfg, "campus": campus, "pop": pop, "n_agents": pop.N, "step_min": step_min})
    has_app = np.asarray(pop.has_app, dtype=bool)
    comp_scale = getattr(intervention, "compliance_scale", 1.0)
    n_events = 0

    run_id = make_run_id(cfg)
    run_dir = Path(rc.get("out_dir", "runs"))
    if not run_dir.is_absolute():
        run_dir = ROOT / run_dir
    run_dir = run_dir / run_id
    writer = RunWriter(run_dir, cfg)
    fractions = cfg["population"]["archetype_fractions"]
    writer.write_config(recorded_config(cfg), run_id, campus.version, code_version(), fractions)
    campus.write(run_dir / "map")
    writer.write_table("agents_static.csv", pop.to_frame(campus, sections))
    if pop.big_five is not None:
        from .personality import frame as personality_frame
        writer.write_table("personality.csv", personality_frame(pop))
    writer.write_table("schedule/sections.csv", sections_frame_for_csv(sections))
    writer.write_table("schedule/events.csv", events_frame_for_csv(events, pop))

    start = datetime.fromisoformat(rc["start_date"])
    timestamps = [(start + timedelta(minutes=t * step_min)).isoformat() for t in range(T)]

    N = pop.N
    buf = {k: np.empty((spd, N), dtype=dt) for k, dt in BUFFER_FIELDS.items()}
    changes = TimelineChanges(writer, N, T)
    contact_frames, exposure_frames = [], []
    no_action = np.full(N, None, dtype=object)

    for t in range(T):
        k = t % spd
        if llm is not None:
            llm.before_step(t, dis)
        beh.step(t, dis.symptomatic)
        contacts = find_contacts(campus, beh.room, beh.x, beh.y, cfg["contacts"], floor=beh.floor)
        dev = dis.step(t, beh, contacts)
        rep.step(t, dis, beh, contacts, dev)

        external = external_provider(t) if external_provider else {}
        obs = build_observable(t, timestamps[t], beh, rep, dis, intervention, external,
                               contacts=contacts, has_app=has_app, report_events=rep.events[n_events:])
        n_events = len(rep.events)
        actions = intervention.step(obs)
        llm_notes = {}
        if llm is not None:
            actions, llm_notes = llm.after_step(t, dev, actions, contacts=contacts, dis=dis)
        action_col = np.array(apply_actions(actions, beh, pop, rngs["intervention"], t, reports=rep,
                                            cfg_interventions=cfg["interventions"],
                                            compliance_scale=comp_scale), dtype=object) \
            if actions else no_action
        for i, note in llm_notes.items():
            action_col = action_col.copy() if action_col is no_action else action_col
            action_col[i] = note
        action_col = np.where(action_col == "", None, action_col)

        for name, val in (("room", beh.room), ("b", beh.b), ("x", beh.x), ("y", beh.y),
                          ("floor", beh.floor), ("indoor", beh.indoor), ("off_map", beh.off_map),
                          ("act", beh.act), ("event", beh.event), ("section", beh.section),
                          ("entrance", beh.entrance), ("moving", beh.moving), ("state", dis.state),
                          ("dsi", dis.days_since_infection(t)), ("inf", dis.infectiousness),
                          ("symptomatic", dis.symptomatic), ("severity", dis.severity),
                          ("masked", beh.masked), ("self_status", rep.self_status),
                          ("test_status", rep.test_status), ("isolating", beh.isolating),
                          ("action", action_col), ("transport", beh.transport)):
            buf[name][k] = val

        if len(contacts["a"]):
            contact_frames.append(contacts_frame(t, contacts, campus, pop.agent_id, step_s))
        exposure_frames.append(room_exposure_frame(t, dis.room_exposure_rows(t, beh), campus))

        if k == spd - 1 or t == T - 1:
            t0 = t - k
            day_buf = {n: a[: k + 1] for n, a in buf.items()}
            day_frame = timeline_frame(t0, t + 1, day_buf, campus, pop, events, sections, timestamps)
            writer.append("timeline", day_frame)
            changes.add(day_frame)
            if contact_frames:
                writer.append("contacts", pd.concat(contact_frames, ignore_index=True))
            writer.append("room_exposure", pd.concat(exposure_frames, ignore_index=True))
            if writer.ocfg["trips"]:
                writer.append("trips", trips_frame(beh.drain_trips(final=t == T - 1), pop.agent_id))
            contact_frames, exposure_frames = [], []
            n_inf = int(np.isin(dis.state, codes.INFECTIOUS_STATES).sum())
            log(f"day {t // spd + 1}/{rc['days']} done; infectious now {n_inf}, "
                f"cumulative infections {len(dis.infections)}")

    inf_df = pd.DataFrame(dis.infections, columns=["t", "infectee", "infector", "route", "r", "b", "contribution"])
    writer.write_table("infections.csv", infections_frame(dis, campus, pop))
    writer.write_table("reports_tests.csv", reports_frame(rep.events, pop))
    if llm is not None:
        (run_dir / "llm_agents.jsonl").write_text("".join(line + "\n" for line in llm.log_lines()))
        (run_dir / "llm_conversations.jsonl").write_text("".join(line + "\n" for line in llm.convo_lines()))
    if hasattr(intervention, "log_frame"):
        writer.write_table("app_alerts.csv", intervention.log_frame(pop.agent_id))
    summary = compute_summary(cfg, campus, pop, inf_df, T)
    writer.write_json("summary.json", summary)
    changes.close()
    writer.close()
    log(f"wrote {run_dir}")
    print(f"attack_rate={summary.get('attack_rate')} peak_day={summary.get('peak_day')} "
          f"measured_R={summary.get('measured_R')} n_imports={summary.get('n_imports')}")
    return run_dir
