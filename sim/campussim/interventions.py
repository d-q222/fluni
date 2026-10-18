"""Intervention hook (SPEC §5, CONTRACT §8).

Each step the engine builds an ObservableState (positions + app-visible statuses + whatever the
downstream system passes in `external`), asks the active Intervention for actions, and applies
them with `apply_actions` (accepted w.p. pop.compliance[i]). Ground truth (disease state,
symptoms, infectiousness) is only exposed to interventions whose class sets `oracle = True`.
"""
import json
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from . import codes

KINDS = ("leave_location", "wear_mask", "isolate_until", "go_to_vaden")
_CFG_PATH = Path(__file__).resolve().parent.parent / "configs" / "interventions.json"


@dataclass(frozen=True)
class Action:
    kind: str          # one of KINDS
    until_t: int = -1  # isolate_until / wear_mask end step (-1 = config default)

    def __post_init__(self):
        if self.kind not in KINDS:
            raise ValueError(f"unknown action kind {self.kind!r}")


def _ro(a):
    """Read-only copy of an array (or None)."""
    if a is None:
        return None
    c = np.array(a, copy=True)
    c.setflags(write=False)
    return c


@dataclass(frozen=True)
class Truth:
    """Ground truth, only given to oracle interventions."""
    state: np.ndarray
    symptomatic: np.ndarray
    infectiousness: np.ndarray


@dataclass(frozen=True)
class ObservableState:
    t: int
    timestamp: str
    x: np.ndarray
    y: np.ndarray
    room: np.ndarray
    b: np.ndarray
    off_map: np.ndarray
    self_status: np.ndarray          # codes.SELF_STATUS indices (app-visible)
    test_status: np.ndarray          # codes.TEST_STATUS indices (app-visible)
    external: dict = field(default_factory=dict)
    truth: Truth | None = None
    contacts: dict = field(default_factory=dict)   # this step's pairs where both phones have the app
    reports: tuple = ()                             # this step's report/test events (no `truthful`)


class Intervention:
    """Base: no actions. Subclasses override step(); reset(ctx) receives {"cfg", "n_agents", "step_min", ...}."""
    name = "none"
    oracle = False

    def __init__(self, cfg=None):
        self.cfg_all = cfg
        self.icfg = {}
        self.spd = 288
        if cfg is not None:
            self.reset({"cfg": cfg})

    def reset(self, ctx):
        cfg = ctx.get("cfg")
        if cfg is not None and "interventions" in cfg:
            self.icfg = cfg["interventions"]
        else:
            self.icfg = json.loads(_CFG_PATH.read_text())
        step_min = ctx.get("step_min") or (cfg or {}).get("run", {}).get("step_min", 5)
        self.spd = 1440 // int(step_min)
        self.n_agents = ctx.get("n_agents")
        self._prev = None

    def step(self, obs: ObservableState) -> dict:
        return {}


class NoIntervention(Intervention):
    name = "none"


class SelfReportIsolate(Intervention):
    """Non-oracle: when an agent's app status changes to might_be_sick / tested_positive,
    ask them (once per report) to isolate for `isolation_days`."""
    name = "self_report_isolate"

    def reset(self, ctx):
        super().reset(ctx)
        names = self.icfg.get("self_report_isolate", {}).get("statuses", ["might_be_sick", "tested_positive"])
        self.trigger = np.array([codes.SELF_STATUS.index(s) for s in names], dtype=np.int8)

    def step(self, obs):
        ss = np.asarray(obs.self_status)
        prev = self._prev if self._prev is not None else np.zeros_like(ss)
        new = np.flatnonzero(np.isin(ss, self.trigger) & (ss != prev))
        self._prev = ss.copy()
        until = obs.t + int(round(self.icfg.get("isolation_days", 5) * self.spd))
        return {int(i): [Action("isolate_until", until)] for i in new}


class SymptomaticIsolateOracle(Intervention):
    """Oracle baseline (SPEC §5 trivial example): every newly symptomatic agent is told to
    isolate for `isolation_days`."""
    name = "symptomatic_isolate_oracle"
    oracle = True

    def step(self, obs):
        sym = np.asarray(obs.truth.symptomatic, dtype=bool)
        prev = self._prev if self._prev is not None else np.zeros_like(sym)
        new = np.flatnonzero(sym & ~prev)
        self._prev = sym.copy()
        until = obs.t + int(round(self.icfg.get("isolation_days", 5) * self.spd))
        return {int(i): [Action("isolate_until", until)] for i in new}


REGISTRY = {c.name: c for c in (NoIntervention, SelfReportIsolate, SymptomaticIsolateOracle)}


def app_contacts(contacts, has_app):
    """Contacts a phone could detect: both agents have the app."""
    if has_app is None or not len(contacts["a"]):
        return {k: _ro(v) for k, v in contacts.items()}
    m = has_app[contacts["a"]] & has_app[contacts["b"]]
    return {k: _ro(np.asarray(v)[m]) for k, v in contacts.items()}


def build_observable(t, timestamp, beh, reports, disease, intervention, external=None,
                     contacts=None, has_app=None, report_events=()) -> ObservableState:
    """Observable-safe snapshot. The disease object is never handed over; truth arrays only when
    the intervention's class is explicitly flagged oracle. Contacts are cut to app-to-app pairs and
    report events lose their `truthful` flag."""
    truth = None
    if getattr(type(intervention), "oracle", False) is True:
        state = np.asarray(disease.state)
        sym = getattr(disease, "symptomatic", None)
        if sym is None:
            sym = state == codes.I_SYM
        truth = Truth(_ro(state), _ro(np.asarray(sym, dtype=bool)), _ro(disease.infectiousness))
    return ObservableState(
        t=int(t), timestamp=timestamp,
        x=_ro(beh.x), y=_ro(beh.y), room=_ro(beh.room), b=_ro(beh.b), off_map=_ro(beh.off_map),
        self_status=_ro(reports.self_status), test_status=_ro(reports.test_status),
        external=dict(external or {}), truth=truth,
        contacts=app_contacts(contacts, has_app) if contacts is not None else {},
        reports=tuple({k: v for k, v in e.items() if k != "truthful"} for e in report_events),
    )


def _cfg_defaults():
    return json.loads(_CFG_PATH.read_text())


def apply_actions(actions, beh, pop, rng, t, reports=None, cfg_interventions=None, compliance_scale=1.0,
                  compliance=None) -> list:
    """Apply {agent_idx: [Action]} in sorted agent order; each action accepted w.p.
    compliance[i] * compliance_scale (capped at 1); compliance defaults to pop.compliance (the engine
    passes the worry-adjusted one when worry is on). isolate_until never shortens an isolation.
    Returns len-N list of timeline strings ("" = no action), multiple joined with "|".
    Pass `reports` so isolate_until survives recovery handling and go_to_vaden yields a test."""
    out = [""] * pop.N
    if not actions:
        return out
    icfg = cfg_interventions or _cfg_defaults()
    step_min = getattr(reports, "step_min", 5)
    spd = 1440 // step_min
    comp = np.asarray(pop.compliance if compliance is None else compliance, dtype=float)
    comp = np.minimum(comp * float(compliance_scale), 1.0)
    for i in sorted(int(k) for k in actions):
        parts = []
        for a in actions[i]:
            if rng.random() >= comp[i]:
                parts.append(f"declined:{a.kind}")
                continue
            if a.kind == "isolate_until":
                until = int(a.until_t) if a.until_t >= 0 else t + int(icfg.get("isolation_days", 5) * spd)
                cur = getattr(beh, "_iso_until", None)
                if cur is not None:
                    until = max(until, int(cur[i]))
                beh.set_isolation(i, until)
                if reports is not None:
                    reports.intervention_iso_until[i] = max(int(reports.intervention_iso_until[i]), until)
                parts.append(f"isolate_until:{until}")
            elif a.kind == "wear_mask":
                until = int(a.until_t) if a.until_t >= 0 else t + int(icfg.get("mask_days", 1) * spd)
                beh.force_mask(i, until)
                parts.append("wear_mask")
            elif a.kind == "leave_location":
                beh.leave_location(i)
                parts.append("leave_location")
            elif a.kind == "go_to_vaden":
                n = max(1, int(round(icfg.get("vaden_visit_min", 45) / step_min)))
                start = reports.next_vaden_slot(t + 1, n) if reports is not None else t + 1
                beh.schedule_vaden(i, start, n)
                if reports is not None:
                    reports.register_vaden_visit(i, start, start + n)
                parts.append("go_to_vaden")
        out[i] = "|".join(parts)
    return out


from .app_policy import FluniApp  # noqa: E402  (imports Action/Intervention from this module)

REGISTRY[FluniApp.name] = FluniApp
