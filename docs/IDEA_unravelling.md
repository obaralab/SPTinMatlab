# Idea — unravelling VAPB trajectories on the ER network

**Status: IDEA ONLY. Nothing built, no code written, not scheduled.** Captured 2026-07-29 so the
reasoning and the measurements survive. Read this before deciding whether to start; the feasibility
section is the part that matters.

Source paper: Sun, Yu, Obara, Mittal, Lippincott-Schwartz, Koslover, *Unraveling trajectories of
diffusive particles on networks*, **Phys. Rev. Research 4, 023182 (2022)**.
Local copy: `/Users/safal-mac/Desktop/Sun2022_ER.pdf`.

## Why it is relevant

VAPB is an ER membrane protein, and the paper's worked example is *literally* a membrane protein
(Halo-TA, a HaloTag on the Sec61β tail-anchor) diffusing in peripheral ER tubules of COS7 cells.
Their headline finding is the one that bears on our analysis:

> **Confinement within a network makes Brownian motion look subdiffusive.** Raw MSD convolves the
> particle's dynamics with the organelle's morphology, so it underestimates motility and depresses
> the apparent scaling exponent. Unravelling separates the two.

They recover D ≈ **1.45 ± 0.24 µm²/s** and α = **1.00 ± 0.02** across 11–13 cells — i.e. Halo-TA is
plainly Brownian once the geometry is divided out, and would have looked subdiffusive without it.

## The algorithm, in one paragraph

Simulating a Brownian walker *onto* a network is a fold: sample a free 1D increment
`Δz ~ N(0, sqrt(2DΔt))`, and if it would carry the particle past the nearest node, place it on a
uniformly-chosen adjacent edge. Unravelling **inverts that fold**. Given a trajectory already in
network coordinates — edge *m*, arclength *x* along it — each step has exactly two candidate
pre-images, `z = +x` and `z = −x`; Bayes' rule weighs them with the node-passage probability
(paper Eqs. 3–8). Sampling the choice at every step yields an unravelled 1D trajectory whose MSD
should be exactly `2Dt`.

`D` is unknown — which is the point — so you sweep it and minimise

```
G(D) = Σᵢ log²[MSD_ur(tᵢ|D) / (2Dtᵢ)]  /  Σᵢ log²[MSD_ur(tᵢ|D) / ⟨MSD_ur⟩]      (paper Eq. 9)
```

evaluated at logarithmically spaced lags. The minimising `D` is the estimate. The velocity
autocorrelation of the unravelled trajectory then gives the scaling exponent from its first negative
peak, `|C_v(δ)/C_v(0)| = 1 − 2^(α−1)`, which is what distinguishes genuine fractional-Langevin
subdiffusion from geometry-induced subdiffusion.

**Validity condition: `Δt ≲ 0.1·ℓ²/D`** — a particle must pass at most the *nearest* node in one
frame. Steps that land on a non-adjacent edge are discarded and the trajectory is cut there, which
biases `D` downward. Step length should be ~10% of an edge for a good α (20% still fine for `D`).

## What we already have that fits

- **Their code is MATLAB and public.** [`lenafabr/unravelNetworkTraj`](https://github.com/lenafabr/unravelNetworkTraj)
  (unravelling + simulation) and [`lenafabr/networktools`](https://github.com/lenafabr/networktools)
  (network extraction). Drop-in for this repo's language.
- **Identical segmentation route.** They ran ilastik pixel classification → threshold → `bwmorph`
  skeletonise → group junction pixels by centre of mass → `bwtraceboundary` to trace edges → cubic
  splines. That is exactly what `er_seg/` already is.
- **Per-frame ER masks.** They extracted a network every ~1 s (100 frames at 100 Hz) and mapped
  trajectories within ±1 s onto it. We have a mask for all 5981 frames.
- **`TrackStruct.matrix`** is `(frame, x_µm, y_µm)` per track — the exact input their projection step
  wants.
- **Our strict ER-geodesic linker does their manual step automatically.** They tracked with TrackMate
  and then *hand-curated* to "remove trajectory linkages that were close in 2D but far from one
  another in the underlying organelle". `spt_link_cost_geo` rejects those by construction.

## The blocker — measured, and it is the segmentation, not the microscope

Skeletonised six `er_seg` frames spread across the movie (`bwskel` + `bwmorph` branchpoints,
PX = 0.10785 µm). Very consistent frame to frame, and **not** the substrate the paper assumes:

| | ours | Sun et al. (COS7 peripheral ER) |
|---|---|---|
| ER area fraction | **60.3 %** | sparse network |
| mean width (area ÷ centreline length) | **0.46 µm** | ~0.1 µm tubules |
| median edge length ℓ | **0.43 µm** | **1.2 ± 0.76 µm** |
| junctions per 256×256 field | ~1,040 | — |

At ℓ = 0.43 µm the validity condition **fails at 50 Hz**:

| D (µm²/s) | Δt_max = 0.1ℓ²/D | margin at Δt = 0.02006 s | step as % of ℓ |
|---|---|---|---|
| 0.5 | 0.037 s | 1.9× | 33 % |
| 1.0 | 0.019 s | **0.9×** | 46 % |
| 1.45 | 0.013 s | **0.6×** | 56 % |

**But run the same arithmetic at their ℓ = 1.2 µm and our frame rate is comfortable**: Δt_max =
0.099 s even at D = 1.45, a 5× margin, with steps at 20 % of an edge. So the obstacle is that
adjacent diffraction-limited tubules are merging into one connected blob — 60 % coverage at 0.46 µm
width — and skeletonising a blob invents topology (0.43 µm "edges", ~1,000 junctions). Fix the
network and the timing takes care of itself.

## Ideas, in the order they should be attempted

1. **Fix the substrate before anything else.** Crop to peripheral, well-resolved sub-regions — the
   paper deliberately worked on ~15 µm patches, not whole cells. Compute local ER area fraction,
   keep windows below ~20 %, and re-measure ℓ there. Also revisit the ilastik threshold: 60 %
   coverage at 0.46 µm width looks over-inclusive against a ~100 nm tubule.
2. **Then it is mostly plumbing** — project tracks to the nearest edge point, feed
   `unravelNetworkTraj`, sweep `D`, minimise `G(D)`.
3. **The test worth doing for its own sake.** Tool 3's "Confined (low D)" channel thresholds the
   rolling per-localization D at 0.15 µm²/s. Some unknown fraction of what it flags is **ER geometry,
   not binding**. If α returns to ~1.0 after unravelling, the confined class is largely an
   architecture artifact; if it stays below 1, the confinement is real. Either answer materially
   changes how the contact-site channels are interpreted.
4. **The novel extension.** The paper stops at a whole-cell D. We have contact sites — so unravel
   per track and compare D *inside* vs *outside* contact-site footprints, giving a site-resolved
   diffusion coefficient with network geometry divided out. The paper explicitly lists ER
   morphology's effect on protein diffusivity as open; nobody has done it site-resolved.
5. **Nearly-free cross-check.** `spt_link_cost_geo` already computes `bwdistgeodesic` along the ER.
   Along-ER path length is *not* the unravelled coordinate (unravelling treats node-passage
   ambiguity probabilistically; geodesic distance ignores it), but comparing the two would quantify
   what that ambiguity actually costs on our data.

## Cautions

- Halo-TA is a minimal tail-anchored construct — a near-ideal diffuser. **VAPB has binding partners
  at contact sites, so non-Brownian behaviour is the biology we are looking for, not a failure of
  the method.** Which is precisely why the geometric confound has to come out first.
- The method assumes *narrow tubules*, so motion along an edge is effectively 1D. Perinuclear ER
  sheets violate that assumption outright — peripheral regions only.
- The ER rearranges over tens of seconds; the network must be re-extracted periodically, not fixed.
- Their luminal-protein caveat: past work found ER *luminal* proteins may move by processive runs
  rather than diffusion. Membrane proteins (us) are the case the paper validates.
