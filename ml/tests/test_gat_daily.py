"""Tests for fluniml/gat_daily.py. No training: gradients, time order, one forward/backward.

    ml/.venv/bin/python ml/tests/test_gat_daily.py
"""
import resource
import sys
import time
from pathlib import Path
from types import SimpleNamespace

import numpy as np
import torch

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from fluniml import data, gat_daily  # noqa: E402

torch.set_num_threads(4)


def toy_run(N=6, hours=72, extra=None):
    """Seed 0 meets agent 1 every hour on day 0; agent 1 meets agent 2 on day 2; optional extra edges."""
    rows = [(h, 0, 1, 30.0) for h in range(24)] + [(h, 1, 2, 30.0) for h in range(48, 72)]
    rows += extra or []
    hour, a, b, m = (np.array(c) for c in zip(*rows))
    ch = np.zeros((len(rows), 9), np.float32)
    ch[:, 0] = m
    seed = np.zeros(N, bool)
    seed[0] = True
    return SimpleNamespace(N=N, hours=hours, hour=hour.astype(np.int32), a=a.astype(np.int32),
                           b=b.astype(np.int32), ch=ch, seed=seed)


def test_gradcheck():
    torch.manual_seed(0)
    for attn in ("gatv2_sigmoid", "softmax", "none"):
        m = gat_daily.GATDaily(d=8, heads=2, edge_attn=attn, d_att=4, checkpoint_every=1).double()
        g = gat_daily.to_graph(toy_run())
        g.x = g.x.double()
        t_inf = torch.tensor([0, 30, 60, -1, -1, -1])
        seed = g.seed

        def loss():
            return gat_daily.survival_nll(m(g), t_inf, seed)

        params = [p for p in m.parameters() if p.requires_grad]
        dirs = [torch.randn_like(p) for p in params]
        L = loss()
        grads = torch.autograd.grad(L, params, allow_unused=True)
        analytic = sum((gr * d).sum() for gr, d in zip(grads, dirs) if gr is not None).item()
        eps = 1e-6
        with torch.no_grad():
            for p, d in zip(params, dirs):
                p.add_(eps * d)
            lp = loss().item()
            for p, d in zip(params, dirs):
                p.sub_(2 * eps * d)
            lm = loss().item()
            for p, d in zip(params, dirs):
                p.add_(eps * d)
        numeric = (lp - lm) / (2 * eps)
        print(f"gradcheck {attn}: analytic {analytic:.8f} numeric {numeric:.8f}")
        assert abs(analytic - numeric) < 1e-5 * max(1.0, abs(numeric)), attn


def test_time_order():
    """Adding contacts on day 2 must not change hazards on days 0 and 1."""
    torch.manual_seed(1)
    m = gat_daily.GATDaily(d=16, heads=2).eval()
    with torch.no_grad():
        H1 = m(gat_daily.to_graph(toy_run()))
        H2 = m(gat_daily.to_graph(toy_run(extra=[(h, 0, 3, 50.0) for h in range(48, 72)])))
    assert torch.allclose(H1[:2], H2[:2]), "future contacts changed past hazards"
    assert not torch.allclose(H1[2], H2[2]), "day-2 contacts should change day-2 hazards"
    print("time order: day 0-1 hazards unchanged by day-2 contacts; day 2 changes")


def test_real_run():
    dirs = data.run_dirs("train")
    cache = getattr(data, "CACHE", None)
    cached = [d for d in dirs if cache is not None and (cache / f"{Path(d).name}.npz").exists()]
    r = data.load_run((cached or dirs)[0])
    for step_h in (24, 6):
        t = time.time()
        g = gat_daily.to_graph(r, step_h=step_h)
        tg = time.time() - t
        m = gat_daily.GATDaily(step_h=step_h)
        t = time.time()
        H = m(g)
        loss = gat_daily.survival_nll(H, torch.as_tensor(r.t_inf), torch.as_tensor(r.seed), step_h=step_h)
        tf = time.time() - t
        t = time.time()
        loss.backward()                      # gradient only, no optimizer step
        tb = time.time() - t
        p = 1 - torch.exp(-H.detach().sum(0)).numpy()
        rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss / 2**30
        print(f"real run {r.run_id} step_h={step_h}: N={r.N}, {g.steps} steps, {len(g.a)} step-edges "
              f"(from {len(r.hour)} hourly), graph {tg:.2f}s, fwd {tf:.2f}s, bwd {tb:.2f}s, "
              f"loss {loss.item():.3f}, mean P(non-seed) at init {p[~r.seed].mean():.3f} "
              f"vs true {r.label[~r.seed].mean():.3f}, peak RSS {rss:.2f} GB, "
              f"{sum(q.numel() for q in m.parameters())} params")
        assert torch.isfinite(loss)


if __name__ == "__main__":
    test_gradcheck()
    test_time_order()
    test_real_run()
    print("ok")
