"""Quick checks for fluniml.gat: ml/.venv/bin/python -m pytest ml/tests/test_gat.py (or run directly)."""
import sys
from pathlib import Path

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fluniml.gat import GATEpi, HourlyGraph, predict, survival_nll  # noqa: E402

torch.set_num_threads(4)


def tiny_graph(N=6, hours=10, minutes=30.0, dtype=torch.float64, seed=0):
    rng = np.random.default_rng(seed)
    hr, a, b, x = [], [], [], []
    for t in range(hours):
        for i in range(N):
            for j in range(i + 1, N):
                if rng.random() < 0.5:
                    hr.append(t); a.append(i); b.append(j)
                    m = np.zeros(9); m[rng.integers(0, 9)] = rng.uniform(5, 60); x.append(m)
    hr = np.array(hr)
    ptr = np.searchsorted(hr, np.arange(hours + 1))
    s = torch.zeros(N, dtype=torch.bool); s[0] = True
    return HourlyGraph(N, hours, s, torch.tensor(ptr), torch.tensor(a), torch.tensor(b),
                       torch.log1p(torch.tensor(np.array(x), dtype=dtype)))


def test_gradcheck():
    for attn in ("gatv2_sigmoid", "softmax", "none"):
        torch.manual_seed(0)
        g = tiny_graph()
        m = GATEpi(d=8, heads=2, n_curves=3, max_lag_h=6, edge_attn=attn, checkpoint_every=3).double()
        m.rate.bias.data.fill_(2.0)   # make hazards O(1) so the check is not trivially ~0
        t_inf = torch.tensor([-1, 3, -1, 7, -1, 9])
        params = [p for p in m.parameters()]

        def f(*ps):
            with torch.no_grad():
                for p, q in zip(params, ps):
                    p.copy_(q)
            return survival_nll(m(g), t_inf, g.seed)

        # analytic vs numeric directional derivative over all params
        loss = survival_nll(m(g), t_inf, g.seed)
        grads = torch.autograd.grad(loss, params)
        v = [torch.randn_like(p) for p in params]
        an = sum((gr * vi).sum() for gr, vi in zip(grads, v)).item()
        eps = 1e-6
        base = [p.detach().clone() for p in params]
        lp = f(*[p + eps * vi for p, vi in zip(base, v)]).item()
        lm = f(*[p - eps * vi for p, vi in zip(base, v)]).item()
        f(*base)
        num = (lp - lm) / (2 * eps)
        print(f"gradcheck {attn}: analytic {an:.8f} numeric {num:.8f}")
        assert abs(an - num) <= 1e-5 * max(1.0, abs(num)), (attn, an, num)
        # checkpointed and plain forward agree, and teacher forcing runs
        m.ck = 0
        assert torch.allclose(survival_nll(m(g), t_inf, g.seed), loss)
        assert torch.isfinite(survival_nll(m(g, t_inf=t_inf), t_inf, g.seed))


def test_more_minutes_more_risk():
    torch.manual_seed(0)
    m = GATEpi(d=8, heads=2, n_curves=3, max_lag_h=48, edge_attn="none")
    N, T = 3, 48
    # agent 0 = seed, agents 1, 2 meet the seed every hour for 10 vs 50 min (tier 1 indoors)
    a = torch.tensor([0, 0] * T); b = torch.tensor([1, 2] * T)
    x = torch.zeros(2 * T, 9); x[0::2, 0] = 10.0; x[1::2, 0] = 50.0
    g = HourlyGraph(N, T, torch.tensor([True, False, False]), torch.arange(0, 2 * T + 1, 2),
                    a, b, torch.log1p(x))
    p = predict(m, g)
    print("P(10 min/h), P(50 min/h):", p[1], p[2])
    assert p[0] == 1.0 and p[2] > p[1] > 0


if __name__ == "__main__":
    test_gradcheck()
    test_more_minutes_more_risk()
    print("ok")
