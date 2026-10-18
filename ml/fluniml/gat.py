"""Temporal, physics-shaped graph attention network (GATEpi): P(infected) from hourly contacts.

It keeps the mean-field skeleton of meanfield.py (hazards add over contacts, P = 1 - exp(-H),
infectiousness is a curve over time since infection) and replaces each hand-set piece with a
learned, attention-weighted one. Per agent i it tracks

    surv_i      P(not yet infected)              seeds 0, others 1
    hist_i(s)   P(newly infected in hour s-1)    hist(0) = 1 for seeds (infected at the start)
    h_i         d=32 GRU state                   seeds start from a learned vector, others another

and for each hour t = 0 .. hours-1:

 1. Temporal attention (infectiousness). B learned non-negative curves phi_b(lag), lag = 1..L
    (L = max_lag_h = 240 h), from a small MLP on sin/cos encodings of lag. Each agent mixes them
    with alpha_j = softmax_b(W h_j) (a softmax over curve shapes only, so it picks a shape, not a
    scale):
        iota_j(t) = sum_b alpha_jb * sum_{lag=1..L} hist_j(t + 1 - lag) * phi_b(lag)
    hist index s = t+1-lag, so a seed (s=0) has lag 1 at hour 0. That is meanfield's convention
    with phi(lag) <-> f[lag - 1]. With kernel_init (e.g. meanfield.infectiousness_kernel(cfg, L))
    phi_b(lag) = k[lag-1] * exp(delta_b(lag)): log(k) is a FIXED log-offset and the MLP output
    delta_b starts near 0 (last layer scaled by 0.01), so every curve starts at the sim's mean
    curve and learns a multiplicative correction (bounded to exp(+-6) by 6*tanh(./6)). Without it,
    phi_b(lag) = 0.5 * exp(delta_b(lag)) (flat start).
 2. Edge features. to_graph stores x = log1p(minutes) for the 9 channels (F = 9, see data.py); the
    model expands it to e_ij = [log1p(min)/log(61), min/60] (18 features). Edges are stored once
    (a < b) and used in both directions.
 3. Edge attention, GATv2-style dynamic attention with SIGMOID gates (risk is a SUM over
    contacts; a softmax would make it an average). Per head k (4 heads):
        g_ij^k    = sigmoid(a_k . LeakyReLU(W_k [h_i || h_j || e_ij]))      i = receiver
        rate_ij^k = c * softplus(U_k e_ij + u_k)                            c = 0.05 fixed scale
        a_ij      = mean_k g_ij^k * rate_ij^k
    edge_attn="softmax": g is replaced by a standard GATv2 softmax over each receiver's incoming
    edges in that hour (ablation). edge_attn="none": a_ij = mean_k rate_ij^k (no attention, h is
    still updated but not used for the hazard except via the curve mixture alpha).
        Hc_i = sum_j a_ij * iota_j
 4. Hazard: H_i = Hc_i + softplus(theta_imp) (learned per-hour import hazard, init ~1e-5).
 5. p_new = surv * (1 - exp(-H)); surv *= exp(-H); hist(t+1) = p_new.
 6. Messages: msg_i = sum_j (a_ij / c) V(h_j) (16-d);
    h_i = GRUCell([log1p(Hc_i / 1e-3), log1p(p_new_i / 1e-3), 1 - surv_i, msg_i], h_i).
    (The 1e-3 and c rescalings only bring tiny hazards to O(1) for the GRU.)

forward returns H [hours, N]. Train with survival_nll (exact discrete-time likelihood of the true
infection hours). forward(g, t_inf=...) optionally teacher-forces hist/surv from the true
infection hours (training-only aid; at test time call forward(g)).

Memory: edges are flat tensors sliced per hour by hour_ptr; all scatter is index_add (no N x N).
hist is a python list of [N] tensors (functional, no in-place writes) and each hour stacks only
its lag window. The hour loop runs under torch.utils.checkpoint in segments of checkpoint_every
hours, so backprop keeps only (h, surv, hist, H) per hour and recomputes edge activations.
"""
import math
from dataclasses import dataclass

import numpy as np
import torch
import torch.nn as nn
import torch.nn.functional as Fn
from torch.utils.checkpoint import checkpoint

N_CH = 9
LOG61 = math.log(61.0)


@dataclass
class HourlyGraph:
    N: int
    hours: int
    seed: torch.Tensor      # [N] bool
    hour_ptr: torch.Tensor  # [hours+1] long; edges of hour t are [hour_ptr[t], hour_ptr[t+1])
    a: torch.Tensor         # [E] long (a < b)
    b: torch.Tensor         # [E] long
    x: torch.Tensor         # [E, F=9] float, log1p(minutes) per channel (data.CHANNELS order)

    def to(self, device):
        return HourlyGraph(self.N, self.hours, self.seed.to(device), self.hour_ptr.to(device),
                           self.a.to(device), self.b.to(device), self.x.to(device))


def to_graph(run, device="cpu") -> HourlyGraph:
    """Run -> HourlyGraph. Edges sorted by hour; x = log1p(minutes), F = 9 channels."""
    order = np.argsort(run.hour, kind="stable")
    hour = np.asarray(run.hour)[order]
    ptr = np.searchsorted(hour, np.arange(run.hours + 1), side="left")
    t = lambda arr, dt: torch.as_tensor(np.ascontiguousarray(arr), dtype=dt, device=device)
    return HourlyGraph(
        N=int(run.N), hours=int(run.hours), seed=t(run.seed, torch.bool),
        hour_ptr=t(ptr, torch.long), a=t(run.a[order], torch.long), b=t(run.b[order], torch.long),
        x=t(np.log1p(run.ch[order]), torch.float32))


def lag_encoding(L, n_freq=8):
    lag = torch.arange(1, L + 1, dtype=torch.float32)[:, None]
    periods = 6.0 * 2.0 ** torch.arange(n_freq, dtype=torch.float32)   # 6 h .. 768 h
    w = 2 * math.pi / periods
    return torch.cat([torch.sin(lag * w), torch.cos(lag * w), lag / L], 1)  # [L, 2n+1]


class GATEpi(nn.Module):
    def __init__(self, d=32, heads=4, n_curves=8, max_lag_h=240, edge_attn="gatv2_sigmoid",
                 kernel_init=None, checkpoint_every=1, d_att=16, d_msg=16, rate_scale=0.05):
        super().__init__()
        assert edge_attn in ("gatv2_sigmoid", "softmax", "none")
        self.d, self.K, self.B, self.L = d, heads, n_curves, max_lag_h
        self.edge_attn, self.ck, self.d_att, self.c = edge_attn, checkpoint_every, d_att, rate_scale
        F2 = 2 * N_CH

        # 1. infectiousness curves
        enc = lag_encoding(max_lag_h)
        self.register_buffer("lag_enc", enc)
        self.curve_mlp = nn.Sequential(nn.Linear(enc.shape[1], 32), nn.Tanh(),
                                       nn.Linear(32, 32), nn.Tanh(), nn.Linear(32, n_curves))
        with torch.no_grad():
            self.curve_mlp[-1].weight.mul_(0.01)
            self.curve_mlp[-1].bias.zero_()
        if kernel_init is not None:
            k = np.zeros(max_lag_h)
            ki = np.asarray(kernel_init, float)[:max_lag_h]
            k[:len(ki)] = ki
            log_k = np.log(np.maximum(k, 1e-6 * max(k.max(), 1e-12)))
        else:
            log_k = np.full(max_lag_h, math.log(0.5))
        self.register_buffer("log_k", torch.tensor(log_k, dtype=torch.float32))
        self.alpha = nn.Linear(d, n_curves)

        # 3. edge attention + rates
        self.rate = nn.Linear(F2, heads)
        with torch.no_grad():   # start near meanfield's fitted rates (60 min tier 1 ~ 0.03/h)
            self.rate.weight.uniform_(0.0, 0.3)
            self.rate.weight[:, N_CH:N_CH + 6] = torch.tensor([5.0, 3.5, 2.0, 2.5, 1.5, 1.0])
            self.rate.bias.fill_(-4.0)
        if edge_attn != "none":
            self.W_dst = nn.Linear(d, heads * d_att, bias=False)
            self.W_src = nn.Linear(d, heads * d_att, bias=False)
            self.W_e = nn.Linear(F2, heads * d_att)
            self.att = nn.Parameter(torch.randn(heads, d_att) / math.sqrt(d_att))

        # 4. imports: softplus(-11.5) ~ 1e-5 per hour
        self.theta_imp = nn.Parameter(torch.tensor(-11.5))

        # 6. state update
        self.V = nn.Linear(d, d_msg)
        self.gru = nn.GRUCell(3 + d_msg, d)
        self.h0_seed = nn.Parameter(torch.randn(d) * 0.1)
        self.h0 = nn.Parameter(torch.zeros(d))

    # ---- pieces -------------------------------------------------------------------------------
    def curves(self):
        """phi [B, L] >= 0, phi[:, l] is the curve at lag l+1."""
        delta = self.curve_mlp(self.lag_enc).T          # [B, L]
        return torch.exp(self.log_k[None] + 6.0 * torch.tanh(delta / 6.0))

    def _edge_weights(self, h, src, dst, e, N):
        """a [2E] for directed edges src -> dst (dst = receiver i)."""
        rate = self.c * Fn.softplus(self.rate(e))       # [E, K]
        rate = torch.cat([rate, rate], 0)                # both directions share the rate
        if self.edge_attn == "none":
            return rate.mean(1)
        E = e.shape[0]
        qe = self.W_e(e)
        z = self.W_dst(h)[dst] + self.W_src(h)[src] + torch.cat([qe, qe], 0)
        z = Fn.leaky_relu(z, 0.2).view(2 * E, self.K, self.d_att)
        logit = (z * self.att).sum(-1)                   # [2E, K]
        if self.edge_attn == "gatv2_sigmoid":
            g = torch.sigmoid(logit)
        else:  # softmax over each receiver's incoming edges this hour
            idx = dst[:, None].expand(-1, self.K)
            mx = torch.full((N, self.K), -1e30, device=h.device, dtype=logit.dtype)
            mx = mx.scatter_reduce(0, idx, logit.detach(), reduce="amax", include_self=True)
            ex = torch.exp(logit - mx[dst])
            den = torch.zeros(N, self.K, device=h.device, dtype=logit.dtype).index_add(0, dst, ex)
            g = ex / den[dst].clamp_min(1e-30)
        return (g * rate).mean(1)

    def _hour(self, t, h, surv, window, phi, src, dst, e, imp, teach=None):
        """One hour. window = hist[s0..t] (list of [N]); returns h, surv, p_new, H."""
        N = h.shape[0]
        n = len(window)
        W = torch.stack(window, 0)                       # [n, N], s = t+1-n .. t
        lags = torch.arange(n, 0, -1, device=h.device) - 1   # lag-1 for s = t+1-n..t
        mix = phi[:, lags] @ W                           # [B, N]
        alpha = torch.softmax(self.alpha(h), -1)         # [N, B]
        iota = (alpha * mix.T).sum(1)                    # [N]
        if src.numel():
            a = self._edge_weights(h, src, dst, e, N)
            Hc = torch.zeros(N, device=h.device, dtype=h.dtype).index_add(0, dst, a * iota[src])
            msg = torch.zeros(N, self.V.out_features, device=h.device, dtype=h.dtype).index_add(
                0, dst, (a / self.c)[:, None] * self.V(h)[src])
        else:
            Hc = torch.zeros(N, device=h.device, dtype=h.dtype)
            msg = torch.zeros(N, self.V.out_features, device=h.device, dtype=h.dtype)
        H = Hc + imp
        q = torch.exp(-H)
        p_new = surv * (1 - q)
        surv = surv * q
        if teach is not None:   # teacher forcing: true new infections / true susceptibility
            pn_t, sv_t, tm = teach
            if tm is None:
                p_new, surv = pn_t, sv_t
            else:               # only for agents in teach_mask; the rest keep the model's own
                p_new, surv = torch.where(tm, pn_t, p_new), torch.where(tm, sv_t, surv)
        inp = torch.stack([torch.log1p(Hc / 1e-3), torch.log1p(p_new / 1e-3), 1 - surv], 1)
        h = self.gru(torch.cat([inp, msg], 1), h)
        return h, surv, p_new, H

    # ---- forward ------------------------------------------------------------------------------
    def forward(self, g: HourlyGraph, t_inf=None, teach_mask=None) -> torch.Tensor:
        """Hazards H [hours, N]. t_inf (LongTensor [N], -1 never) teacher-forces hist/surv;
        teach_mask (BoolTensor [N]) limits that to some agents (e.g. only the ones being fit, so
        held-out agents' labels never enter as inputs)."""
        dev = g.x.device
        tm = None if teach_mask is None else teach_mask.to(dev)
        N, T, L = g.N, g.hours, self.L
        seed = g.seed.to(dev)
        phi = self.curves()
        imp = Fn.softplus(self.theta_imp)
        h = torch.where(seed[:, None], self.h0_seed, self.h0).expand(N, self.d).contiguous()
        dt = phi.dtype
        surv = (~seed).to(dt)
        hist = [seed.to(dt)]
        ptr = g.hour_ptr.tolist()
        if t_inf is not None:
            t_inf = t_inf.to(dev)
            inf_t = torch.where(seed | (t_inf < 0), torch.full_like(t_inf, -2), t_inf)
        Hs = []
        use_ck = self.ck and torch.is_grad_enabled()
        for t0 in range(0, T, max(self.ck, 1)):
            t1 = min(T, t0 + max(self.ck, 1))
            s0 = max(0, t0 + 1 - L)
            lo, hi = ptr[t0], ptr[t1]
            x_seg = g.x[lo:hi]
            ab = (g.a[lo:hi], g.b[lo:hi])
            offs = [p - lo for p in ptr[t0:t1 + 1]]
            if t_inf is not None:
                teach = torch.stack([(inf_t == t).to(dt) for t in range(t0, t1)], 0)
            else:
                teach = torch.zeros(0, device=dev)

            def seg(h, surv, phi, imp, x_seg, a_seg, b_seg, teach, *win,
                    t0=t0, t1=t1, s0=s0, offs=offs):
                win = list(win)
                ps, Hl = [], []
                for k, t in enumerate(range(t0, t1)):
                    lo_, hi_ = offs[k], offs[k + 1]
                    a_, b_ = a_seg[lo_:hi_], b_seg[lo_:hi_]
                    xe = x_seg[lo_:hi_]
                    e = torch.cat([xe / LOG61, torch.expm1(xe) / 60.0], 1)
                    src, dst = torch.cat([a_, b_]), torch.cat([b_, a_])
                    tf = None
                    if teach.numel():
                        pn = teach[k]
                        tf = (pn, surv * (1 - pn), tm)
                    lo_w = max(0, len(win) - L)
                    h, surv, p, H = self._hour(t, h, surv, win[lo_w:], phi, src, dst, e, imp, tf)
                    win.append(p)
                    ps.append(p)
                    Hl.append(H)
                return (h, surv, torch.stack(ps), torch.stack(Hl))

            args = (h, surv, phi, imp, x_seg, ab[0], ab[1], teach, *hist[s0:t0 + 1])
            if use_ck:
                h, surv, P, H = checkpoint(seg, *args, use_reentrant=False,
                                           preserve_rng_state=False)
            else:
                h, surv, P, H = seg(*args)
            hist.extend(P.unbind(0))
            Hs.append(H)
        return torch.cat(Hs, 0)


def survival_nll(H, t_inf, seed) -> torch.Tensor:
    """Discrete-time survival NLL, mean over non-seed agents.
    infected in hour k: sum_{h<k} H[h] - log(1 - exp(-H[k])); never: sum_h H[h]."""
    T, N = H.shape
    t_inf = t_inf.to(H.device).long()
    seed = seed.to(H.device)
    cum = torch.cumsum(H, 0)
    total = cum[-1]
    inf = (t_inf >= 0) & ~seed
    k = t_inf.clamp(0, T - 1)
    Hk = H.gather(0, k[None]).squeeze(0)
    before = cum.gather(0, k[None]).squeeze(0) - Hk
    ll_inf = before - torch.log(-torch.expm1(-Hk.clamp_min(1e-10)))
    loss = torch.where(inf, ll_inf, total)
    scored = ~seed
    return loss[scored].sum() / scored.sum().clamp_min(1)


@torch.no_grad()
def predict(model, g) -> np.ndarray:
    """P(infected during the run) = 1 - exp(-sum_h H); seeds 1.0."""
    H = model(g)
    p = -torch.expm1(-H.sum(0))
    p = torch.where(g.seed.to(p.device), torch.ones_like(p), p)
    return p.float().cpu().numpy()
