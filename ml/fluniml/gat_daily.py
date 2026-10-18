"""Time-ordered simple GAT (GATDaily): edge attention + MLPs, unrolled one step per day.

The simple version of gat.py. Contacts are grouped into steps of step_h hours (default 24, so 14
steps for a 14-day run) and the network runs once per step with shared weights:

    h_i              d-dim state per agent; starts from [seed flag] (seeds are infected at t = 0)
    for step s = 0 .. S-1, on that step's contact graph only:
      e_ij  = [log1p(minutes per channel) / log(1 + 60 step_h),  log1p(hours in contact) / log(1 + step_h)]
      g_ij  = mean_k sigmoid(a_k . LeakyReLU(W_dst h_i + W_src h_j + W_e e_ij))     GATv2 gate, i = receiver
      r_ij  = g_ij * softplus(MLP_risk([h_j, h_i, e_ij, s/S]))                      risk this contact adds
      H_i   = sum_j r_ij + softplus(theta_imp)                                      hazard of step s
      p_new = surv * (1 - exp(-H));  surv *= exp(-H)
      M_i   = sum_j g_ij * MLP_val([h_j, e_ij])                                     message
      h_i   = LayerNorm(h_i + MLP_upd([h_i, M_i, log1p(H_i / 0.01), p_new, 1 - surv]))

Time order: step s reads every h_j as it stood at the END of step s-1, so risk picked up on day s
travels on only from day s+1, and contacts on day 5 can never affect who was infected on day 3.
A chain A -> B -> C needs two steps. Within one day the order of contacts is ignored, which costs
little because flu's latent period averages 1.5 days: someone infected today is rarely infectious
before tomorrow. step_h = 6 or 12 shortens that blind spot.

Sums, not softmax: g is a sigmoid gate, so three risky contacts add three risks (softmax would
average them). edge_attn = "softmax" (standard GATv2 over each receiver's edges in the step) and
"none" (g = 1) are ablations.

Train with survival_nll on each agent's infection step; predict() = 1 - exp(-sum_s H). Same
interface shape as gat.py (to_graph / model(g) / survival_nll / predict) so train_gat.py can swap.
"""
import math
from dataclasses import dataclass

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as Fn
from torch.utils.checkpoint import checkpoint

N_CH = 9
N_FEAT = N_CH + 1


@dataclass
class StepGraph:
    N: int
    steps: int
    step_h: int
    seed: torch.Tensor   # [N] bool
    ptr: torch.Tensor    # [steps+1] long; edges of step s are [ptr[s], ptr[s+1])
    a: torch.Tensor      # [E] long (a < b)
    b: torch.Tensor      # [E] long
    x: torch.Tensor      # [E, N_FEAT] float

    def to(self, device):
        return StepGraph(self.N, self.steps, self.step_h, self.seed.to(device), self.ptr.to(device),
                         self.a.to(device), self.b.to(device), self.x.to(device))


def to_graph(run, device="cpu", step_h=24) -> StepGraph:
    """Run (hourly pair edges) -> one edge per pair per step, sorted by step."""
    N = int(run.N)
    step = np.asarray(run.hour, np.int64) // step_h
    key = (step * N + np.asarray(run.a, np.int64)) * N + np.asarray(run.b, np.int64)
    uk, inv = np.unique(key, return_inverse=True)
    x = np.zeros((len(uk), N_FEAT), np.float32)
    np.add.at(x[:, :N_CH], inv, np.asarray(run.ch, np.float32))
    np.add.at(x[:, N_CH], inv, 1.0)
    x[:, :N_CH] = np.log1p(x[:, :N_CH]) / math.log(1 + 60 * step_h)
    x[:, N_CH] = np.log1p(x[:, N_CH]) / math.log(1 + step_h)
    s = uk // (N * N)
    steps = -(-int(run.hours) // step_h)
    ptr = np.searchsorted(s, np.arange(steps + 1), side="left")
    t = lambda arr, dt: torch.as_tensor(np.ascontiguousarray(arr), dtype=dt, device=device)
    return StepGraph(N=N, steps=steps, step_h=step_h, seed=t(run.seed, torch.bool), ptr=t(ptr, torch.long),
                     a=t((uk // N) % N, torch.long), b=t(uk % N, torch.long), x=t(x, torch.float32))


def mlp(d_in, d_hidden, d_out):
    return nn.Sequential(nn.Linear(d_in, d_hidden), nn.ReLU(), nn.Linear(d_hidden, d_out))


class GATDaily(nn.Module):
    def __init__(self, d=32, heads=4, edge_attn="gatv2_sigmoid", step_h=24, d_att=16,
                 checkpoint_every=1, **unused):
        """checkpoint_every > 0 recomputes each step in backward, so memory holds one step's
        activations at a time (needed for 7,000-agent runs); 0 turns it off (faster, more memory)."""
        super().__init__()
        assert edge_attn in ("gatv2_sigmoid", "softmax", "none")
        self.d, self.K, self.d_att, self.edge_attn = d, heads, d_att, edge_attn
        self.step_h, self.ck = step_h, checkpoint_every
        self.max_edges = 300_000    # undirected edges per chunk inside one step (bounds memory)
        self.h0 = nn.Linear(1, d)
        if edge_attn != "none":
            self.W_dst = nn.Linear(d, heads * d_att, bias=False)
            self.W_src = nn.Linear(d, heads * d_att, bias=False)
            self.W_e = nn.Linear(N_FEAT, heads * d_att)
            self.att = nn.Parameter(torch.randn(heads, d_att) / math.sqrt(d_att))
        self.risk = mlp(2 * d + N_FEAT + 1, d, 1)
        with torch.no_grad():
            # ~100 contact pairs per agent per day: softplus(-8.5) ~ 2e-4 per contact-step, times a
            # gate ~0.5, gives ~10-15% infected over 14 days at init (roughly the true scale)
            self.risk[-1].bias.fill_(-8.5)
        self.val = mlp(d + N_FEAT, d, d)
        self.upd = mlp(2 * d + 3, d, d)
        self.norm = nn.LayerNorm(d)
        self.theta_imp = nn.Parameter(torch.tensor(-8.0))   # softplus(-8) ~ 3e-4 per step

    def _gate(self, h, src, dst, e, N):
        """g [2E] in [0, 1] for directed edges src -> dst."""
        if self.edge_attn == "none":
            return torch.ones(src.shape[0], device=h.device, dtype=h.dtype)
        z = self.W_dst(h)[dst] + self.W_src(h)[src] + self.W_e(e)
        logit = (Fn.leaky_relu(z, 0.2).view(-1, self.K, self.d_att) * self.att).sum(-1)   # [2E, K]
        if self.edge_attn == "gatv2_sigmoid":
            return torch.sigmoid(logit).mean(1)
        idx = dst[:, None].expand(-1, self.K)
        mx = torch.full((N, self.K), -1e30, device=h.device, dtype=logit.dtype)
        mx = mx.scatter_reduce(0, idx, logit.detach(), reduce="amax", include_self=True)
        ex = torch.exp(logit - mx[dst])
        den = torch.zeros(N, self.K, device=h.device, dtype=logit.dtype).index_add(0, dst, ex)
        return (ex / den[dst].clamp_min(1e-30)).mean(1)

    def _edges(self, h, a, b, x, pos):
        """Hazard and message sums [N], [N, d] from one batch of undirected edges (both directions)."""
        N = h.shape[0]
        src, dst = torch.cat([a, b]), torch.cat([b, a])
        e = torch.cat([x, x], 0)
        g = self._gate(h, src, dst, e, N)
        p_in = pos.expand(src.shape[0], 1)
        r = g * Fn.softplus(self.risk(torch.cat([h[src], h[dst], e, p_in], 1))).squeeze(1)
        Hc = torch.zeros(N, device=h.device, dtype=h.dtype).index_add(0, dst, r)
        M = torch.zeros(N, self.d, device=h.device, dtype=h.dtype).index_add(
            0, dst, g[:, None] * self.val(torch.cat([h[src], e], 1)))
        return Hc, M

    def _step(self, h, surv, a, b, x, pos):
        N = h.shape[0]
        E = a.shape[0]
        chunk = self.max_edges if self.max_edges > 0 else max(E, 1)
        if self.edge_attn == "softmax" or E <= chunk:
            # softmax normalises over all of a receiver's edges in the step, so it can't be chunked
            Hc, M = self._edges(h, a, b, x, pos)
        else:   # big step: edge chunks, each recomputed in backward, so memory holds one chunk
            Hc = torch.zeros(N, device=h.device, dtype=h.dtype)
            M = torch.zeros(N, self.d, device=h.device, dtype=h.dtype)
            for lo in range(0, E, chunk):
                sl = slice(lo, lo + chunk)
                if torch.is_grad_enabled():
                    dH, dM = checkpoint(self._edges, h, a[sl], b[sl], x[sl], pos,
                                        use_reentrant=False, preserve_rng_state=False)
                else:
                    dH, dM = self._edges(h, a[sl], b[sl], x[sl], pos)
                Hc, M = Hc + dH, M + dM
        H = Hc + Fn.softplus(self.theta_imp)
        q = torch.exp(-H)
        p_new = surv * (1 - q)
        surv = surv * q
        inp = torch.cat([h, M, torch.stack([torch.log1p(H / 0.01), p_new, 1 - surv], 1)], 1)
        h = self.norm(h + self.upd(inp))
        return h, surv, H

    def forward(self, g: StepGraph, t_inf=None) -> torch.Tensor:
        """Hazards H [steps, N]. t_inf is accepted for train_gat.py compatibility and ignored."""
        seed = g.seed.to(g.x.device)
        dt = self.h0.weight.dtype
        h = self.norm(self.h0(seed.to(dt)[:, None]))
        surv = (~seed).to(dt)
        ptr = g.ptr.tolist()
        use_ck = self.ck > 0 and torch.is_grad_enabled()
        Hs = []
        for s in range(g.steps):
            lo, hi = ptr[s], ptr[s + 1]
            pos = torch.full((1, 1), s / max(g.steps, 1), device=h.device, dtype=dt)
            args = (h, surv, g.a[lo:hi], g.b[lo:hi], g.x[lo:hi], pos)
            if use_ck and hi - lo <= self.max_edges:   # big steps checkpoint per edge chunk instead
                h, surv, H = checkpoint(self._step, *args, use_reentrant=False, preserve_rng_state=False)
            else:
                h, surv, H = self._step(*args)
            Hs.append(H)
        return torch.stack(Hs, 0)


def survival_nll(H, t_inf, seed, step_h=24) -> torch.Tensor:
    """Discrete-time survival NLL over steps, mean over non-seeds. t_inf in HOURS (-1 never)."""
    S = H.shape[0]
    t_inf = t_inf.to(H.device).long()
    seed = seed.to(H.device)
    inf = (t_inf >= 0) & ~seed
    k = torch.where(t_inf >= 0, t_inf // step_h, torch.zeros_like(t_inf)).clamp(0, S - 1)
    cum = torch.cumsum(H, 0)
    Hk = H.gather(0, k[None]).squeeze(0)
    before = cum.gather(0, k[None]).squeeze(0) - Hk
    ll_inf = before - torch.log(-torch.expm1(-Hk.clamp_min(1e-10)))
    loss = torch.where(inf, ll_inf, cum[-1])
    scored = ~seed
    return loss[scored].sum() / scored.sum().clamp_min(1)


@torch.no_grad()
def predict(model, g) -> np.ndarray:
    """P(infected during the run) = 1 - exp(-sum_s H); seeds 1.0."""
    p = -torch.expm1(-model(g).sum(0))
    p = torch.where(g.seed.to(p.device), torch.ones_like(p), p)
    return p.float().cpu().numpy()
