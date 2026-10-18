"""Calibration scenario (docs/AGENT_FRAMEWORK.md section 4): oversampled events for the Claude agents,
and the dry-run cost estimate. Driven by scripts/calibration_run.py; settings in configs/calibration.json.

Scenario(cfg).setup(...) is called by engine.run(scenario=...) once everything is built and before step 0.
It needs the LLMAgents instance (which agents Claude drives) and the Disease (to seed infections), and
returns the intervention with its step() wrapped so forced FlUni alerts join the intervention's own
actions. llm_agents then turns them into notifications and an app_advice re-plan, exactly like real
alerts. Everything is drawn from its own RNG stream (run.seed + "calibration"), so the rest of the sim's
random streams are untouched, and every forced event is logged to calibration_forced.csv.
"""
import json
import threading
import zlib
from types import SimpleNamespace

import numpy as np
import pandas as pd

from .budget import cost_usd, price_of
from .codes import S as S_STATE
from .interventions import Action


def _crc(s):
    return zlib.crc32(s.encode())


class Scenario:
    def __init__(self, cfg):
        self.cfg = cfg
        self.c = cfg.get("calibration", {})
        self.rows = []          # (t, agent_id, kind, detail)
        self.opus_applied = None

    # ------------------------------------------------------------------ setup (engine hook)
    def setup(self, cfg, pop, dis, llm, intervention):
        if llm is None:
            raise ValueError("calibration scenario needs Claude-driven agents (llm_agents.n_agents > 0)")
        c, rc = self.c, cfg["run"]
        self.pop, self.dis, self.llm = pop, dis, llm
        self.aid = np.asarray(pop.agent_id)
        self.step_min = int(rc["step_min"])
        self.spd = 1440 // self.step_min
        T = int(rc["days"]) * self.spd
        self.rng = np.random.default_rng([int(rc["seed"]), _crc("calibration")])
        idx = np.asarray(llm.idx, np.int64)
        fg = np.asarray(pop.friend_group)
        self.group_members = np.flatnonzero(np.isin(fg, np.unique(fg[idx])))
        self.in_groups = np.zeros(pop.N, bool)
        self.in_groups[self.group_members] = True

        # per-agent model (model-sensitivity check)
        k = int(c.get("opus_subset") or 0)
        if k > 0:
            sub = []
            # own stream, so the forced events are the same with and without the subset
            mrng = np.random.default_rng([int(rc["seed"]), _crc("calibration_model")])
            for g in mrng.permutation(np.unique(fg[idx])).tolist():
                sub += [i for i in idx.tolist() if fg[i] == g][: k - len(sub)]
                if len(sub) >= k:
                    break
            model = c.get("opus_model", "claude-opus-5-5")
            self.opus_applied = hasattr(llm, "agent_models")
            if self.opus_applied:
                llm.agent_models.update({int(i): model for i in sub})
            else:
                print(f"calibration: llm_agents has no per-agent model support (LLMAgents.agent_models); "
                      f"the {k} agents logged as kind=model run on {cfg['llm_agents']['model']}", flush=True)
            for i in sorted(sub):
                self.rows.append((0, self.aid[i], "model", model if self.opus_applied else f"{model} (not applied)"))

        # severity mix: every infection of a friend-group member draws its peak severity from the levels
        mix = c.get("severity_mix") or {}
        lv = mix.get("levels") if isinstance(mix, dict) else None
        if lv:
            self.lv_names = list(lv)
            self.lv_peak = np.array([float(lv[n][0]) for n in self.lv_names])
            w = np.array([float(lv[n][1]) for n in self.lv_names])
            self.lv_w = w / w.sum()
        else:
            self.lv_names = None
        self._force_sym = False
        orig = dis._infect

        def infect(idx_, t, *a, **kw):
            orig(idx_, t, *a, **kw)
            for i in np.atleast_1d(np.asarray(idx_, np.int64)).tolist():
                if not self.in_groups[i]:
                    continue
                if self._force_sym:
                    dis.asym[i] = False
                if self.lv_names is not None and not dis.asym[i]:
                    j = int(self.rng.choice(len(self.lv_names), p=self.lv_w))
                    dis.peak_sev[i] = self.lv_peak[j]
                    self.rows.append((int(t), self.aid[i], "severity", f"{self.lv_names[j]}:{self.lv_peak[j]:g}"))
        dis._infect = infect

        # extra infections inside Claude agents' friend groups, spread over t_days
        es = c.get("extra_seeds") or {}
        n = min(int(es.get("n", 0)), len(self.group_members))
        lo, hi = (float(x) for x in es.get("t_days", [0, 1]))
        ts = np.sort(self.rng.integers(int(lo * self.spd), max(int(hi * self.spd), int(lo * self.spd) + 1), n))
        self.seed_at = {}
        for t in np.minimum(ts, T - 1).tolist():
            self.seed_at[t] = self.seed_at.get(t, 0) + 1
        self.force_sym = bool(es.get("force_symptomatic", True))

        # forced FlUni alerts to random Claude agents at random times
        al = c.get("alerts") or {}
        pool = idx[np.asarray(pop.has_app, bool)[idx]] if al.get("require_app") else idx
        kinds = list(al.get("kinds", ["isolate_until", "wear_mask", "leave_location", "go_to_vaden"]))
        h0, h1 = (float(x) for x in al.get("hours", [8, 22]))
        self.alert_at = {}
        for _ in range(int(al.get("n", 0)) if len(pool) else 0):
            d = int(self.rng.integers(0, int(rc["days"])))
            m = float(self.rng.uniform(h0 * 60, h1 * 60))
            t = min(d * self.spd + int(m // self.step_min), T - 1)
            i = int(self.rng.choice(pool))
            kind = kinds[int(self.rng.integers(len(kinds)))]
            self.alert_at.setdefault(t, []).append((i, kind))
        self.iso_steps = int(round(float(al.get("isolation_days", 5)) * self.spd))
        self.mask_steps = int(round(float(al.get("mask_days", 1)) * self.spd))

        inner = intervention.step

        def step(obs):
            out = inner(obs)
            out = dict(out) if out else {}
            self._step(int(obs.t), out)
            return out
        intervention.step = step
        return intervention

    # ------------------------------------------------------------------ per step
    def _step(self, t, out):
        n = self.seed_at.get(t, 0)
        if n:
            sus = self.group_members[self.dis.state[self.group_members] == S_STATE]
            pick = self.rng.choice(sus, min(n, len(sus)), replace=False) if len(sus) else []
            for i in sorted(int(x) for x in pick):
                self._force_sym = self.force_sym
                try:
                    self.dis._infect(np.array([i]), t, -1, "seed", -1, -1, 1.0)
                finally:
                    self._force_sym = False
                who = "claude" if self.llm.mask[i] else "friend"
                self.rows.append((t, self.aid[i], "extra_seed",
                                  f"{who};symptomatic={not self.dis.asym[i]};onset_t={int(self.dis.t_onset[i])}"))
            for _ in range(n - len(pick)):
                self.rows.append((t, "", "extra_seed_skipped", "no susceptible friend-group member left"))
        for i, kind in self.alert_at.get(t, []):
            until = t + self.iso_steps if kind == "isolate_until" else t + self.mask_steps if kind == "wear_mask" else -1
            out.setdefault(i, []).append(Action(kind, until))
            self.rows.append((t, self.aid[i], "alert", kind + (f";until_t={until}" if until >= 0 else "")))

    def frame(self):
        df = pd.DataFrame(self.rows, columns=["t", "agent_id", "kind", "detail"])
        return df.sort_values(["t", "kind", "agent_id"], kind="stable").reset_index(drop=True)

    def write(self, run_dir):
        path = run_dir / "calibration_forced.csv"
        self.frame().to_csv(path, index=False)
        return path


# ---------------------------------------------------------------------- dry run
def call_kind(req):
    props = req.get("output_config", {}).get("format", {}).get("schema", {}).get("properties", {})
    if "say" in props:
        return "talk"
    if "memory" in props:
        return "reflect"
    if "blocks" in props:
        return "plan"
    return "other"


def _minimal(schema):
    """Smallest valid value for a JSON schema (used for fields other agents may add to the schemas)."""
    if "enum" in schema:
        return schema["enum"][0]
    t = schema.get("type")
    if t == "object":
        return {k: _minimal(v) for k, v in schema.get("properties", {}).items() if k in schema.get("required", [])}
    if t == "array":
        return []
    if t == "boolean":
        return False
    if t in ("integer", "number"):
        return schema.get("minimum", 0)
    return ""


class DryRunClient:
    """Fake client: records each request's size and returns a minimal response. Plans come back with no
    blocks (the agent keeps its default plan), a talk turn says one line and ends, reflections don't re-plan."""

    def __init__(self):
        self.records = []
        self._lock = threading.Lock()
        self.beta = SimpleNamespace(messages=self)

    def create(self, **req):
        kind = call_kind(req)
        system = "".join(b.get("text", "") for b in req.get("system", [])) if isinstance(req.get("system"), list) \
            else str(req.get("system", ""))
        user = "".join(m["content"] if isinstance(m["content"], str) else json.dumps(m["content"])
                       for m in req.get("messages", []))
        schema = json.dumps(req.get("output_config", {}).get("format", {}).get("schema", {}))
        with self._lock:
            self.records.append({"kind": kind, "model": req.get("model"), "system": system,
                                 "user_chars": len(user), "schema_chars": len(schema)})
        sch = req.get("output_config", {}).get("format", {}).get("schema", {"type": "object"})
        out = _minimal(sch)
        if kind == "talk":
            out.update(say="hey", end=True)
        elif kind == "reflect":
            out.update(memory="", replan=False)
        elif kind == "plan":
            out["blocks"] = []
        return SimpleNamespace(stop_reason="end_turn", model="dry-run", stop_details=None,
                               usage=SimpleNamespace(input_tokens=0, output_tokens=0),
                               content=[SimpleNamespace(type="text", text=json.dumps(out))])


def estimate(records, cal, n_llm=None, opus_subset=0, opus_applied=None, n_convos=None):
    """Expected cost of the real run from the dry run's requests. Returns a dict (also printed by fmt_estimate)."""
    e, pricing = cal["estimate"], cal["pricing"]["models"]
    cpt = float(e.get("chars_per_token", 4))
    turns = float(e.get("turns_per_conversation", 4))
    out_tok = e.get("output_tokens", {})
    min_cache = int(e.get("min_cacheable_tokens", 512))
    rows = {}
    seen_sys = set()
    for r in records:
        k = r["kind"]
        scale = turns if k == "talk" else 1.0
        sys_tok = len(r["system"]) / cpt
        body = (r["user_chars"] + r["schema_chars"]) / cpt
        if k == "talk":  # later turns carry the growing transcript (~30 tokens a line)
            body += 30 * (turns - 1) / 2
        cw = cr = 0.0
        if sys_tok >= min_cache:
            key = (r["model"], r["system"])
            if key in seen_sys:
                cr = sys_tok
            else:
                seen_sys.add(key)
                cw = sys_tok
            unc = body
        else:
            unc = body + sys_tok
        x = rows.setdefault((k, r["model"]), {"dry_calls": 0, "calls": 0.0, "input": 0.0, "cache_write": 0.0,
                                              "cache_read": 0.0, "output": 0.0})
        x["dry_calls"] += 1
        x["calls"] += scale
        x["input"] += unc * scale
        x["cache_write"] += cw
        x["cache_read"] += cr * scale + (cw * (scale - 1))
        x["output"] += float(out_tok.get(k, out_tok.get("plan", 1000))) * scale
    opus_model = cal.get("opus_model", "claude-opus-5-5")
    frac = (opus_subset / n_llm) if (opus_subset and n_llm and not opus_applied) else 0.0
    by_kind, total = {}, 0.0
    for (k, model), x in sorted(rows.items(), key=lambda kv: (kv[0][0], str(kv[0][1]))):
        tok = (x["input"], x["output"], x["cache_write"], x["cache_read"])
        p, _ = price_of(model, pricing)
        usd = cost_usd(tok, p) * (1 - frac)
        if frac:
            usd += cost_usd(tok, price_of(opus_model, pricing)[0]) * frac
        d = by_kind.setdefault(k, {"dry_calls": 0, "calls": 0.0, "input": 0.0, "cache_write": 0.0,
                                   "cache_read": 0.0, "output": 0.0, "usd": 0.0, "models": []})
        for f in ("dry_calls", "calls", "input", "cache_write", "cache_read", "output"):
            d[f] += x[f]
        d["usd"] += usd
        d["models"].append(model)
        total += usd
    sys_tokens = sorted({round(len(r["system"]) / cpt) for r in records})
    return {"by_kind": by_kind, "total_usd": total, "turns_per_conversation": turns,
            "system_prompt_tokens": sys_tokens, "min_cacheable_tokens": min_cache,
            "system_cached": any(t >= min_cache for t in sys_tokens),
            "opus_subset": opus_subset, "opus_fraction_priced": frac, "n_conversations": n_convos,
            "budget_usd": cal.get("budget_usd")}


def fmt_estimate(est):
    L = ["Dry-run cost estimate (tokens ~ chars/4; output tokens assumed, see configs/calibration.json estimate)",
         f"{'call':8s} {'dry':>6s} {'est.calls':>9s} {'input':>11s} {'cache_wr':>9s} {'cache_rd':>10s} "
         f"{'output':>10s} {'USD':>8s}  model"]
    tot = {"dry_calls": 0, "calls": 0, "input": 0, "cache_write": 0, "cache_read": 0, "output": 0, "usd": 0}
    for k, d in est["by_kind"].items():
        L.append(f"{k:8s} {d['dry_calls']:6d} {d['calls']:9.0f} {d['input']:11,.0f} {d['cache_write']:9,.0f} "
                 f"{d['cache_read']:10,.0f} {d['output']:10,.0f} {d['usd']:8.2f}  {','.join(map(str, d['models']))}")
        for f in tot:
            tot[f] += d[f]
    L.append(f"{'total':8s} {tot['dry_calls']:6d} {tot['calls']:9.0f} {tot['input']:11,.0f} {tot['cache_write']:9,.0f} "
             f"{tot['cache_read']:10,.0f} {tot['output']:10,.0f} {tot['usd']:8.2f}")
    L.append(f"talk calls scaled x{est['turns_per_conversation']:g} turns per conversation "
             f"({est['n_conversations']} conversations in the dry run; its agents kept their default plans, so real meetings may differ)")
    L.append(f"system prompts ~{est['system_prompt_tokens']} tokens; "
             + ("cached (cache reads priced)" if est["system_cached"] else
                f"below the {est['min_cacheable_tokens']}-token minimum cacheable prefix, so priced as uncached input"))
    if est["opus_fraction_priced"]:
        L.append(f"opus subset not applied by llm_agents; {est['opus_fraction_priced']:.0%} of calls priced at Opus anyway")
    if est.get("budget_usd") is not None:
        L.append(f"estimated total ${est['total_usd']:.2f} vs budget cap ${est['budget_usd']:.2f}")
    return "\n".join(L)
