"""Spend cap for Claude-driven agents: a wrapper around the Anthropic client, passed to run() as llm_client.

    client = BudgetClient(anthropic.Anthropic(), budget_usd=20, pricing=cal["pricing"]["models"])
    run_dir = run(cfg, llm_client=client)
    client.write(run_dir / "cost.json")

Every real response's `usage` is priced (input, output, cache writes, cache reads; per model from
configs/calibration.json -> pricing). Once the spend, plus the expected cost of calls already in flight,
reaches `budget_usd`, no more requests go out: `create` returns a stand-in message whose text is not JSON.
LLMAgents._call treats that as a failed call (it returns None and caches nothing), so the agent keeps the
scheduler's default plan, a talk ends, and a reflection is skipped. One warning is printed when the cap
is hit. Calls in flight when the cap is reached still finish, so the spend can pass the cap by at most
about max_workers calls.
"""
import json
import threading
from types import SimpleNamespace


def usage_tokens(usage):
    """(input, output, cache_write, cache_read) from an SDK usage object or a dict."""
    g = (lambda k: usage.get(k)) if isinstance(usage, dict) else (lambda k: getattr(usage, k, None))
    return tuple(int(g(k) or 0) for k in
                 ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"))


def price_of(model, pricing):
    """Per-million prices for a model; unknown models get the most expensive known prices (conservative)."""
    if model in pricing:
        return pricing[model], True
    for k in pricing:  # e.g. a dated or prefixed id that contains a known id
        if k in str(model):
            return pricing[k], True
    worst = max(pricing.values(), key=lambda p: p["output"])
    return worst, False


def cost_usd(tokens, prices):
    i, o, cw, cr = tokens
    return (i * prices["input"] + o * prices["output"] + cw * prices.get("cache_write", prices["input"] * 1.25)
            + cr * prices.get("cache_read", prices["input"] * 0.1)) / 1e6


class _Messages:
    def __init__(self, owner):
        self._o = owner

    def create(self, **req):
        return self._o._create(**req)


class BudgetClient:
    """Duck-types `client.beta.messages.create(**req)` for llm_agents; thread-safe (llm_agents calls in parallel)."""

    def __init__(self, client, budget_usd, pricing, verbose=True):
        self.client = client
        self.budget = float(budget_usd)
        self.pricing = pricing
        self.verbose = verbose
        self.beta = SimpleNamespace(messages=_Messages(self))
        self._lock = threading.Lock()
        self.calls = 0          # requests that went to the API and returned
        self.blocked = 0        # requests refused because the cap was reached
        self.errors = 0         # requests that raised
        self.in_flight = 0
        self.spent = 0.0
        self.by_model = {}      # model -> {calls, input, output, cache_write, cache_read, usd}
        self.warned = False
        self.unknown_models = set()

    @property
    def capped(self):
        return self.warned

    def _expected_in_flight(self):
        return self.in_flight * (self.spent / self.calls if self.calls else 0.0)

    def _create(self, **req):
        with self._lock:
            if self.spent + self._expected_in_flight() >= self.budget:
                self.blocked += 1
                if not self.warned:
                    self.warned = True
                    print(f"budget: spend ${self.spent:.2f} reached the cap of ${self.budget:.2f}; no more API "
                          "calls, remaining Claude agents keep their default plans", flush=True)
                return self._stopped(req)
            self.in_flight += 1
        try:
            msg = self.client.beta.messages.create(**req)
        except Exception:
            with self._lock:
                self.in_flight -= 1
                self.errors += 1
            raise
        tok = usage_tokens(getattr(msg, "usage", None) or {})
        model = getattr(msg, "model", None) or req.get("model")
        prices, known = price_of(model, self.pricing)
        usd = cost_usd(tok, prices)
        with self._lock:
            self.in_flight -= 1
            self.calls += 1
            self.spent += usd
            if not known:
                self.unknown_models.add(str(model))
            m = self.by_model.setdefault(str(model), {"calls": 0, "input": 0, "output": 0, "cache_write": 0,
                                                       "cache_read": 0, "usd": 0.0})
            m["calls"] += 1
            for k, v in zip(("input", "output", "cache_write", "cache_read"), tok):
                m[k] += v
            m["usd"] += usd
        return msg

    @staticmethod
    def _stopped(req):
        # Not JSON: llm_agents._call returns None (the default plan stays) and nothing is cached.
        return SimpleNamespace(stop_reason="end_turn", model=req.get("model"), stop_details=None,
                               usage=SimpleNamespace(input_tokens=0, output_tokens=0),
                               content=[SimpleNamespace(type="text", text="")])

    def summary(self):
        tot = {k: sum(m[k] for m in self.by_model.values()) for k in ("input", "output", "cache_write", "cache_read")}
        return {"budget_usd": self.budget, "spent_usd": round(self.spent, 4), "capped": self.warned,
                "calls": self.calls, "blocked_calls": self.blocked, "error_calls": self.errors,
                "tokens": tot,
                "by_model": {k: {**v, "usd": round(v["usd"], 4)} for k, v in sorted(self.by_model.items())},
                "unknown_models_priced_as_most_expensive": sorted(self.unknown_models)}

    def write(self, path):
        from pathlib import Path
        Path(path).write_text(json.dumps(self.summary(), indent=1, sort_keys=True) + "\n")
        return path
