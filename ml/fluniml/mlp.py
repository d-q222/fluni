"""MLP + ReLU: one agent's feature vector in, P(infected during the run) out.

    x (181) -> Linear 128 -> ReLU -> Dropout -> Linear 64 -> ReLU -> Dropout -> Linear 1 -> sigmoid

Rows are agents; seeds are left out (their label is known). Trained with binary cross-entropy,
early-stopped on the "stop" runs (see ml/runs.json). Features are standardised with training-set statistics.
"""
import numpy as np
import torch
from torch import nn

from .data import CACHE, Run
from .features import FEATURE_SETS, agent_features


def run_features(run: Run):
    """Full feature matrix for a run (cached), plus names."""
    f = CACHE / f"feat_{run.run_id}.npz"
    if f.exists():
        z = np.load(f)
        return z["X"], list(z["names"])
    X, names = agent_features(run)
    np.savez_compressed(f, X=X, names=np.array(names))
    return X, names


def select(names, feature_set):
    groups = FEATURE_SETS[feature_set]
    prefix = {"activity": ("act_", "deg_"), "seed": ("seed_", "n_seeds"), "hop2": ("hop2_",),
              "hop3": ("hop3_",), "run": ("run_",)}
    keep = tuple(p for g in groups for p in prefix[g])
    return np.array([n.startswith(keep) for n in names])


def stack(runs, cols):
    X, y, rid, idx = [], [], [], []
    for r in runs:
        F, _ = run_features(r)
        s = r.scored
        X.append(F[s][:, cols])
        y.append(r.label[s])
        rid += [r.run_id] * int(s.sum())
        idx.append(np.flatnonzero(s))
    return np.concatenate(X), np.concatenate(y), np.array(rid), np.concatenate(idx)


class MLP(nn.Module):
    def __init__(self, d_in, hidden=(128, 64), dropout=0.1):
        super().__init__()
        layers, d = [], d_in
        for h in hidden:
            layers += [nn.Linear(d, h), nn.ReLU(), nn.Dropout(dropout)]
            d = h
        layers.append(nn.Linear(d, 1))
        self.net = nn.Sequential(*layers)

    def forward(self, x):
        return self.net(x).squeeze(-1)  # logits


class MLPModel:
    def __init__(self, feature_set="full", hidden=(128, 64), dropout=0.1, lr=1e-3,
                 weight_decay=1e-4, batch=512, max_epochs=200, patience=15, seed=0):
        self.feature_set = feature_set
        self.kw = dict(hidden=hidden, dropout=dropout)
        self.lr, self.wd, self.batch = lr, weight_decay, batch
        self.max_epochs, self.patience, self.seed = max_epochs, patience, seed

    def fit(self, train_runs, val_runs, verbose=True):
        torch.manual_seed(self.seed)
        _, names = run_features(train_runs[0])
        self.cols = select(names, self.feature_set)
        self.names = [n for n, k in zip(names, self.cols) if k]
        Xtr, ytr, _, _ = stack(train_runs, self.cols)
        Xva, yva, _, _ = stack(val_runs, self.cols)
        self.mu, self.sd = Xtr.mean(0), Xtr.std(0) + 1e-6
        Xtr = torch.tensor((Xtr - self.mu) / self.sd)
        Xva = torch.tensor((Xva - self.mu) / self.sd)
        ytr, yva = torch.tensor(ytr), torch.tensor(yva)
        self.net = MLP(Xtr.shape[1], **self.kw)
        opt = torch.optim.AdamW(self.net.parameters(), lr=self.lr, weight_decay=self.wd)
        lossf = nn.BCEWithLogitsLoss()
        best, best_state, bad = np.inf, None, 0
        g = torch.Generator().manual_seed(self.seed)
        for ep in range(self.max_epochs):
            self.net.train()
            perm = torch.randperm(len(Xtr), generator=g)
            for i in range(0, len(perm), self.batch):
                j = perm[i:i + self.batch]
                opt.zero_grad()
                loss = lossf(self.net(Xtr[j]), ytr[j])
                loss.backward()
                opt.step()
            self.net.eval()
            with torch.no_grad():
                vl = lossf(self.net(Xva), yva).item()
            if vl < best - 1e-5:
                best, bad = vl, 0
                best_state = {k: v.clone() for k, v in self.net.state_dict().items()}
            else:
                bad += 1
            if verbose and ep % 10 == 0:
                print(f"  epoch {ep}: val logloss {vl:.4f} (best {best:.4f})", flush=True)
            if bad >= self.patience:
                break
        self.net.load_state_dict(best_state)
        self.val_loss, self.epochs = best, ep + 1
        return self

    def predict(self, run: Run):
        F, _ = run_features(run)
        X = torch.tensor((F[:, self.cols] - self.mu) / self.sd)
        self.net.eval()
        with torch.no_grad():
            p = torch.sigmoid(self.net(X)).numpy()
        return np.where(run.seed, 1.0, p)

    def n_params(self):
        return sum(p.numel() for p in self.net.parameters())
