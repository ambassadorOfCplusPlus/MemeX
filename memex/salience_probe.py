"""Flagship hypothesis probe (plan §2.8): is FAR-future attention demand
predictable at write time, and does it beat the published H2O signal?

Target  : attention mass a token receives from queries more than `local` tokens
          later (i.e. demand that arises after the token leaves the exact
          window — exactly what a notebook write policy must anticipate).
Predictors compared, all available at write time:
  h2o      : attention already received from NEAR queries (published policy)
  position : trivial recency baseline
  ridge(h) : closed-form linear map from the token's hidden state (ours)
  ridge(h+h2o) : both signals combined
Metric  : top-k% overlap with the oracle ranking (what a fixed-budget notebook
          actually cares about) plus R^2 for the regression fits.
"""
import argparse
import glob
import os

import torch

SINKS = 4          # attention sinks are always kept; exclude from ranking
LOCAL = 128        # must match collector's `local`


def zone_tensors(item, tailcut):
    """Return (hidden, target_far, h2o_near) for the scorable zone of a chunk.

    The last `tailcut` positions are dropped: their far-future window extends
    past the end of the chunk, so their label is truncated and misleading.
    """
    far_n = item["future_mass_far"].float()
    all_n = item["future_mass"].float()
    T = len(all_n)
    denom_all = torch.arange(T - 1, -1, -1).clamp(min=1).float()
    denom_far = (denom_all - LOCAL).clamp(min=1)
    far_raw = far_n * denom_far
    near_raw = (all_n * denom_all - far_raw).clamp(min=0)
    lo, hi = SINKS, T - tailcut
    return (item["hidden"].float()[lo:hi],
            torch.log1p(far_raw[lo:hi] / denom_far[lo:hi] * 1000),
            torch.log1p(near_raw[lo:hi] / LOCAL * 1000))


def topk_overlap(pred, target, frac):
    k = max(1, int(len(target) * frac))
    a = set(torch.topk(pred, k).indices.tolist())
    b = set(torch.topk(target, k).indices.tolist())
    return len(a & b) / k


def ridge(X, y, lam):
    X = torch.cat([X, torch.ones(len(X), 1)], dim=1)
    d = X.shape[1]
    return torch.linalg.solve(X.T @ X + lam * torch.eye(d), X.T @ y)


def contrastive_head(X, y, steps=300, lr=0.05, batch=4096, margin_frac=0.25,
                     lam=1e-3, seed=0):
    """Train the salience head as a RANKING problem instead of a regression.

    The write policy never needs the absolute future-attention value — it needs
    to know which tokens outrank the others for a fixed number of slots. This is
    the InfoNCE-flavoured objective from the original MEMEX spec: sample pairs
    where one token genuinely received more far-future attention than the other,
    and push the scores apart (logistic loss on the score difference).

    Optimising the ordering directly is a better match for how the head is used
    than minimising squared error on a heavy-tailed target.
    """
    g = torch.Generator().manual_seed(seed)
    n, d = X.shape
    w = torch.zeros(d + 1, requires_grad=True)
    opt = torch.optim.Adam([w], lr=lr)
    Xb = torch.cat([X, torch.ones(n, 1)], dim=1)
    for _ in range(steps):
        i = torch.randint(0, n, (batch,), generator=g)
        j = torch.randint(0, n, (batch,), generator=g)
        gap = y[i] - y[j]
        # only use pairs that are clearly ordered; ties carry no signal
        keep = gap.abs() > margin_frac * y.std()
        if keep.sum() < 16:
            continue
        i, j, gap = i[keep], j[keep], gap[keep]
        s = (Xb[i] - Xb[j]) @ w
        target = torch.sign(gap)
        loss = torch.nn.functional.softplus(-target * s).mean() + lam * (w ** 2).sum()
        opt.zero_grad()
        loss.backward()
        opt.step()
    return w.detach()


def apply_ridge(W, X):
    return torch.cat([X, torch.ones(len(X), 1)], dim=1) @ W


class MicroHead(torch.nn.Module):
    """The micro-model of the original MEMEX spec, in its smallest useful form:
    a 2-layer MLP over the token's hidden state. Linear probes cannot express
    "important unless X", so a nonlinear head is where a ranking objective can
    actually beat a regression one.
    """

    def __init__(self, d_in, hidden=128):
        super().__init__()
        self.net = torch.nn.Sequential(
            torch.nn.Linear(d_in, hidden), torch.nn.GELU(),
            torch.nn.Linear(hidden, 1))

    def forward(self, x):
        return self.net(x).squeeze(-1)


def train_micro(X, y, objective="mse", steps=1500, lr=1e-3, batch=2048,
                hidden=128, margin_frac=0.25, seed=0):
    """Train the micro head with either squared error or pairwise ranking loss."""
    torch.manual_seed(seed)
    g = torch.Generator().manual_seed(seed)
    head = MicroHead(X.shape[1], hidden)
    opt = torch.optim.Adam(head.parameters(), lr=lr)
    y_std = y.std()
    for _ in range(steps):
        i = torch.randint(0, len(X), (batch,), generator=g)
        if objective == "mse":
            loss = torch.nn.functional.mse_loss(head(X[i]), y[i])
        else:
            j = torch.randint(0, len(X), (batch,), generator=g)
            gap = y[i] - y[j]
            keep = gap.abs() > margin_frac * y_std
            if keep.sum() < 16:
                continue
            s = head(X[i][keep]) - head(X[j][keep])
            loss = torch.nn.functional.softplus(-torch.sign(gap[keep]) * s).mean()
        opt.zero_grad()
        loss.backward()
        opt.step()
    return head.eval()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default=r"D:\MemeX\data\future_attn")
    ap.add_argument("--holdout", type=int, default=2)
    ap.add_argument("--lam", type=float, default=10.0)
    ap.add_argument("--tailcut", type=int, default=192)
    ap.add_argument("--fracs", type=float, nargs="+", default=[0.05, 0.1, 0.25])
    ap.add_argument("--micro-hidden", type=int, default=128)
    ap.add_argument("--micro-steps", type=int, default=1500,
                    help="steps for the nonlinear micro-head (both objectives)")
    ap.add_argument("--rank-steps", type=int, default=400,
                    help="optimisation steps for the contrastive ranking head")
    args = ap.parse_args()

    shards = sorted(glob.glob(os.path.join(args.data, "shard_*.pt")))
    if len(shards) <= args.holdout:
        raise SystemExit(f"need > {args.holdout} shards, found {len(shards)}")
    train_shards, test_shards = shards[: -args.holdout], shards[-args.holdout :]

    Hs, Ys, Ns = [], [], []
    for p in train_shards:
        for item in torch.load(p, weights_only=True):
            h, y, n = zone_tensors(item, args.tailcut)
            Hs.append(h); Ys.append(y); Ns.append(n)
    H, Y, N = torch.cat(Hs), torch.cat(Ys), torch.cat(Ns)
    mu, sd = H.mean(0), H.std(0).clamp(min=1e-6)
    Hn = (H - mu) / sd
    W_h = ridge(Hn, Y, args.lam)
    W_hn = ridge(torch.cat([Hn, N.unsqueeze(1)], dim=1), Y, args.lam)
    W_rank = contrastive_head(Hn, Y, steps=args.rank_steps)
    micro_mse = train_micro(Hn, Y, "mse", steps=args.micro_steps,
                            hidden=args.micro_hidden)
    micro_rank = train_micro(Hn, Y, "rank", steps=args.micro_steps,
                             hidden=args.micro_hidden)
    # The past-attention signal carries information the hidden state does not,
    # so give the nonlinear head both.
    HN = torch.cat([Hn, N.unsqueeze(1)], dim=1)
    micro_both = train_micro(HN, Y, "mse", steps=args.micro_steps,
                             hidden=args.micro_hidden)
    n_micro = sum(p.numel() for p in micro_mse.parameters())
    print(f"train tokens: {len(Y)}  (from {len(train_shards)} shards); "
          f"микро-голова {n_micro/1e3:.0f}K параметров")

    names = ["h2o", "position", "ridge(h)", "ridge(h+h2o)", "rank(h)",
             "micro-mse", "micro-rank", "micro(h+h2o)", "random"]
    ov = {n: {f: [] for f in args.fracs} for n in names}
    r2 = {"ridge(h)": [], "ridge(h+h2o)": [], "h2o": []}
    for p in test_shards:
        for item in torch.load(p, weights_only=True):
            h, y, n = zone_tensors(item, args.tailcut)
            hn = (h - mu) / sd
            preds = {
                "h2o": n,
                "position": -torch.arange(len(y), dtype=torch.float),
                "ridge(h)": apply_ridge(W_h, hn),
                "ridge(h+h2o)": apply_ridge(W_hn, torch.cat([hn, n.unsqueeze(1)], 1)),
                "rank(h)": apply_ridge(W_rank, hn),
                "micro-mse": micro_mse(hn),
                "micro-rank": micro_rank(hn),
                "micro(h+h2o)": micro_both(torch.cat([hn, n.unsqueeze(1)], 1)),
                "random": torch.rand(len(y)),
            }
            for name, pr in preds.items():
                for f in args.fracs:
                    ov[name][f].append(topk_overlap(pr, y, f))
            ss_tot = ((y - y.mean()) ** 2).sum().clamp(min=1e-9)
            for name in r2:
                pr = preds[name]
                if name == "h2o":       # scale-free: fit a 1-D ridge on the fly
                    pr = apply_ridge(ridge(n.unsqueeze(1), y, 1.0), n.unsqueeze(1))
                r2[name].append(float(1 - ((y - pr) ** 2).sum() / ss_tot))

    n_chunks = len(r2["ridge(h)"])
    print(f"held-out chunks: {n_chunks}\n")
    hdr = "predictor".ljust(14) + "".join(f"top{int(f*100)}%".rjust(9) for f in args.fracs)
    print(hdr)
    for name in names:
        row = name.ljust(14) + "".join(
            f"{sum(ov[name][f]) / n_chunks:9.3f}" for f in args.fracs)
        print(row)
    print()
    for name, vals in r2.items():
        print(f"R^2 {name:>14}: {sum(vals) / len(vals):.3f}")

    # Keep whichever head ranks better on held-out data: the notebook only cares
    # about the ordering, so the winner is decided by top-k overlap, not by R^2.
    cands = ("ridge(h)", "ridge(h+h2o)", "rank(h)", "micro-mse", "micro-rank",
             "micro(h+h2o)")
    best = max(cands, key=lambda nm: sum(ov[nm][args.fracs[0]]) / max(n_chunks, 1))
    # "W" is always the hidden-state-only head: that is the one the KV cache can
    # apply at write time, when a causal H2O feature is not available for free.
    # The better-scoring variants are stored alongside for offline use.
    payload = {"mu": mu, "sd": sd, "local": LOCAL, "objective": best,
               "train_tokens": len(Y), "W": W_h, "W_with_h2o": W_hn,
               "needs_h2o": best in ("ridge(h+h2o)", "micro(h+h2o)")}
    if best.startswith("micro"):
        # A nonlinear head is stored as a state dict; the cache-side loader picks
        # the linear fast path only when "W" is present.
        heads = {"micro-mse": micro_mse, "micro-rank": micro_rank,
                 "micro(h+h2o)": micro_both}
        payload["state_dict"] = heads[best].state_dict()
        payload["hidden"] = args.micro_hidden
    elif best == "rank(h)":
        payload["W"] = W_rank  # also hidden-only, safe for the cache path
    torch.save(payload, os.path.join(args.data, "salience_head.pt"))
    print(f"\nлучшая голова: {best} (по top-{int(args.fracs[0]*100)}% overlap); "
          f"кэш использует линейную голову по скрытому состоянию"
          f"{' — она же лучшая' if best == 'ridge(h)' else ''}")


if __name__ == "__main__":
    main()
