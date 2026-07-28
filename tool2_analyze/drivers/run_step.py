#!/usr/bin/env python3
"""Predict pointwise diffusion D(t) (and, when available, the anomalous exponent alpha) along contact-
site member tracks, as the bridge between the MATLAB Analyze tool and the STEP model.

Pipeline:
  Tool 3 (cs_step_export.m)  ->  step_tracks.csv  ->  [this script]  ->  step_predictions.csv  ->  cs_step_import.m

By default it uses a dependency-light rolling-window estimator (numpy only), so the round trip works
immediately. Point --weights at a trained STEP checkpoint to use the deep-learning model instead
(STEP: https://github.com/BorjaRequena/step ; models: step.models.XResAttn / LogXResAttn).

  pip install numpy                 # for the fallback
  pip install torch git+https://github.com/BorjaRequena/step.git   # for the real STEP model

  python run_step.py --in analysis/step/step_tracks.csv --out analysis/step/step_predictions.csv
  python run_step.py ... --weights step_D.pt --model logxresattn    # use trained STEP
"""
import argparse, csv, sys
from collections import defaultdict


def read_tracks(path):
    tracks = defaultdict(list)
    with open(path) as f:
        for row in csv.DictReader(f):
            tracks[row['track_uid']].append(row)
    for uid in tracks:
        tracks[uid].sort(key=lambda d: int(d['frame']))
    return tracks


def rolling_D(xy, dt, win=7, sigma=0.03, mode='lag1'):
    """Pointwise D (um^2/s) over a +/-win localization window.
      mode='lag1'   : local mean single-step MSD, minus the localization-noise floor:
                      <dr^2>/(4 dt) - sigma^2/dt  (because <dr^2> = 4 D dt + 4 sigma^2 in 2D),
                      floored at 0. Sharpest in time; needs sigma (um).
      mode='msdfit' : fit a local MSD(k) = 4 D (k dt) + b over lags 1..k inside the window; the
                      intercept b absorbs localization noise, so sigma is ignored. Less noisy, blurrier."""
    import numpy as np
    xy = np.asarray(xy, float)
    n = len(xy)
    D = np.full(n, np.nan)
    if n < 2:
        return D, np.full(n, np.nan)
    h = max(1, win // 2)
    if str(mode).lower().startswith('msd'):
        for i in range(n):
            lo, hi = max(0, i - h), min(n, i + h + 1)               # localizations in the window
            seg = xy[lo:hi]; m = len(seg)
            kmax = min(4, m - 1)
            if kmax < 2:
                continue
            ks = np.arange(1, kmax + 1)
            msd = np.array([np.mean(np.sum((seg[k:] - seg[:-k]) ** 2, axis=1)) for k in ks])
            A = np.vstack([4.0 * ks * dt, np.ones_like(ks, float)]).T  # msd = 4 D (k dt) + b
            slope = np.linalg.lstsq(A, msd, rcond=None)[0][0]
            D[i] = max(slope, 0.0)
        return D, np.full(n, np.nan)
    d2 = np.sum(np.diff(xy, axis=0) ** 2, axis=1)                     # squared single step, length n-1
    noise = (sigma * sigma) / dt                                      # localization-noise floor to remove
    for i in range(n):
        lo, hi = max(0, i - h), min(n - 1, i + h)                    # steps d2[lo:hi]
        seg = d2[lo:hi]; seg = seg[np.isfinite(seg)]
        if seg.size:
            D[i] = max(seg.mean() / (4.0 * dt) - noise, 0.0)
    return D, np.full(n, np.nan)


def load_model(weights, kind):
    import torch
    from step.models import XResAttn, LogXResAttn
    cls = LogXResAttn if kind.lower().startswith('log') else XResAttn
    model = cls(2, n_class=1, stem_szs=(32,), conv_blocks=[1, 1], block_szs=[64, 128],
                n_encoder_layers=6, dim_ff=512, nhead_enc=8, linear_layers=[])
    state = torch.load(weights, map_location='cpu')
    if isinstance(state, dict) and 'model' in state:
        state = state['model']
    model.load_state_dict(state)
    model.eval()
    return model


def predict_step(xy, dt, model):
    """Run the STEP model on one trajectory -> (D_per_point, alpha_per_point), both length L."""
    import numpy as np, torch
    x = np.asarray(xy, float)
    L = len(x)
    traj = torch.tensor(x[None, :, :], dtype=torch.float32)         # [1, L, 2]
    with torch.no_grad():
        out = model(traj)
    pred = np.asarray(out.squeeze(0).cpu()).reshape(-1) if out.ndim < 3 else np.asarray(out.squeeze(0).cpu())[:, 0]
    # displacement models (Log*) return L-1 values; pad to L by repeating the first
    if len(pred) == L - 1:
        pred = np.concatenate([pred[:1], pred])
    D = pred[:L]
    return D, np.full(L, np.nan)


def main():
    ap = argparse.ArgumentParser(description='Pointwise diffusion along contact-site tracks (STEP bridge).')
    ap.add_argument('--in', dest='inp', default='step_tracks.csv')
    ap.add_argument('--out', dest='outp', default='step_predictions.csv')
    ap.add_argument('--weights', default='', help='trained STEP checkpoint (.pt/.pth); empty -> rolling-window fallback')
    ap.add_argument('--model', default='xresattn', help='xresattn | logxresattn')
    ap.add_argument('--win', type=int, default=7, help='rolling-window size in localizations (fallback only)')
    ap.add_argument('--sigma', type=float, default=0.03, help='localization precision (um) for noise correction (rolling lag1 mode)')
    ap.add_argument('--mode', default='lag1', help='rolling estimator: lag1 (noise-corrected single-step) | msdfit (local MSD slope)')
    a = ap.parse_args()

    tracks = read_tracks(a.inp)
    model, use_step = None, bool(a.weights)
    if use_step:
        try:
            model = load_model(a.weights, a.model)
        except Exception as ex:
            print(f'[warn] STEP model unavailable ({ex}); using rolling-window fallback', file=sys.stderr)
            use_step = False
    method = 'step' if use_step else 'rolling'
    print(f'predicting D(t) with "{method}" for {len(tracks)} member track(s)')

    with open(a.outp, 'w', newline='') as f:
        w = csv.writer(f)
        w.writerow(['track_uid', 'frame', 'D', 'alpha', 'inside_cs', 'method'])
        for uid, rows in tracks.items():
            xy = [[float(r['x_um']), float(r['y_um'])] for r in rows]
            fr = [int(r['frame']) for r in rows]
            ins = [int(r['inside_cs']) for r in rows]
            if len(rows) > 1 and (fr[1] - fr[0]) != 0:
                dt = (float(rows[1]['t_s']) - float(rows[0]['t_s'])) / (fr[1] - fr[0])
            else:
                dt = 0.02
            try:
                D, A = predict_step(xy, dt, model) if use_step else rolling_D(xy, dt, a.win, a.sigma, a.mode)
            except Exception as ex:
                print(f'[warn] {uid}: {ex}; rolling fallback', file=sys.stderr)
                D, A = rolling_D(xy, dt, a.win, a.sigma, a.mode)
            for i in range(len(fr)):
                di = '' if D[i] != D[i] else f'{D[i]:.6g}'
                ai = '' if (i >= len(A) or A[i] != A[i]) else f'{A[i]:.4g}'
                w.writerow([uid, fr[i], di, ai, ins[i], method])
    print(f'wrote {a.outp}')


if __name__ == '__main__':
    main()
