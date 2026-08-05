# Using halo-Sec61B as a background null for VAPB contact sites — what to measure and how to test it

Scope: the statistics for the experiment you described — track a few halo-Sec61B cells, run them
through the pipeline, and use them as an empirical background for VAPB contact-site detection.

**Provenance.** Numbers marked **[measured]** were run against your own data or against this
pipeline's own detection functions (`cs_window_density`, `cs_mc_threshold`, `cs_detect`) during this
work. Numbers marked **[sim]** come from the design review's simulations. Claims about code carry a
`file:line` and were checked against the source.

---

## 0. Three facts about the code that constrain every test below

These are not stylistic. Each one makes a whole class of test invalid.

### 0.1 Enrichment is not pivotal — its denominator moves under the alternative

`cs_detect.m:67` computes `bgMed = median(dens(erMask))` and `:77` `enr = pk / bgMed`. The
denominator comes from the same window being tested. Real recruitment pulls localizations out of the
diffuse ER pool, depresses `bgMed`, and so inflates the enrichment of *every* blob in that window —
chance peaks included.

This is measurable and it is large. At a captured fraction *f* the inflation is ≈ 1/(1−*f*); at
*f* = 0.2 that is **1.22×**, against an `ermc` null whose entire median→p95 span is 2.02→2.84, i.e.
**1.41×**. The bias is about half the dynamic range of the statistic you would be calibrating, and it
runs **anticonservative**: a control arm has no depletion, so its enrichment sits low, so VAPB looks
more significant than it is.

It is not fixable by matching sampling depth. It is fixable by changing the denominator — §5.

### 0.2 The unit is the track, and the null does not know that

`cs_window_density.m:37` accumulates every localization of every track; `cs_mc_threshold.m:39`
scatters *N* i.i.d. points. A molecule parked for 500 frames contributes 500 correlated points that
the null scores as 500 independent ones.

The per-localization track id already exists — `cs_window_picker.m:244`, `st.aT` — and is used for
the `trk` and `dw%` columns. The null does not use it.

Same defect in the stability score: `cs_window_picker.m:643` does `h = rand(nL,1) < 0.5`, splitting
**localizations, not tracks**. So `stab` is not the independent-replication check its column header
implies.

### 0.3 `nullMax` is simulation output, not a sample

`cs_mc_threshold.m:34` sets `rng(20240713,'twister')` unconditionally, so the same *M* realizations
are reused for every window and every cell. *M* is a spinner (`cs_window_picker.m:123`). Any test
whose *n* is *M* lets you drive *p* to zero by turning a dial, and pooling `nullMax` across cells
adds no information at all because the errors are perfectly common-mode.

---

## 1. What actually transfers across the two microscopes

You are comparing a 100 Hz, 128 px, 20.48 µm acquisition against a 50 Hz, 256 px, 27.61 µm one. I
measured what survives that.

| quantity | changes by | verdict |
|---|---|---|
| **false sites per cell**, dt 0.020 → 0.050 s, *N* held identical | **2.0×** (3.52 ± 0.27 → 1.77 ± 0.19; paired sign test **p = 7×10⁻⁸**) | **does not transfer** |
| **false sites per cell**, across a 12× range of *D* | **2.3×** (5.60 → 2.42) | **does not transfer** |
| **enrichment**, same comparison | **1.6%** (+0.067 ± 0.041) | **transfers** |
| false-site enrichment, across 2.5× dt and 12× *D* | median 2.13 – 2.24 | **transfers** |

**[measured]**

**The rule that follows: compare enrichment distributions, never site counts.** Counts measure the
camera. Enrichment is a within-cell ratio and is nearly invariant.

I also tried to rescue counts by decimating the fast movie to the slow one's effective dt. It
**overshoots** — 0.80 false sites/cell against 1.75 native **[measured]** — because decimation matches
the sampling interval but not the observation lifetime (photobleaching is roughly fixed in *frames*,
so a slower acquisition watches each molecule for more real time). Two independent temporal
differences; matching one worsens the other. There is no post-hoc fix for cross-rig counts.

### Field of view

The density grid is set by the **bin size**, not the camera, so the physical scale matches
automatically:

| | FOV | grid | µm/px | smoothing | imaged area | edge band |
|---|---|---|---|---|---|---|
| VAPB | 27.61 µm | 921 | 0.02998 | 0.240 µm | 762 µm² | 3.4% |
| Sec61B | 20.48 µm | 683 | 0.02999 | 0.240 µm | 419 µm² | 4.6% |

**[measured]** Keep the bin at 30 nm for both and the detection scale is identical. Edge effects are
negligible *for the detector*. They are **not** negligible for Ripley's K — see §7.

---

## 2. The conceptual problem with "use the Sec61B density as the background"

`cs_mc_threshold`'s `wmap` is a per-pixel weight **on that cell's own grid**. Cell A's ER network does
not overlay cell B's, and there is no registration between them. A density map from a different cell
cannot be a per-pixel background.

Three things *can* transfer, and they are different objects:

| | what it is | defensibility |
|---|---|---|
| **(a) a calibration distribution** | what enrichment a non-clustering ER protein reaches | **strongest.** Measured to be rig-invariant, so it transfers |
| **(b) a learned relationship** | `density ≈ f(local ER signal)`, fit on Sec61B, evaluated per VAPB cell against *that cell's own* ER segmentation | defensible; needs the ER segmentation you have |
| **(c) co-imaging** | Sec61B and VAPB in the same cell, two colours | **the only literal per-pixel transfer.** Your data is not yet acquired, so this is still on the table |

If co-imaging is feasible with your constructs it is a much stronger experiment for the same
microscope time: it makes the comparison **paired**, and it collapses the entire cross-rig confound.
The design review flagged the separate-rig design as a **perfect marker × microscope alias** — every
Sec61B cell on one rig, every VAPB cell on the other, with no shared level of the batch factor. That
is not something statistics can repair after the fact.

---

## 3. How much the existing null already does

Before spending microscope time, know the baseline. On a synthetic reticular ER with **zero** real
clustering **[measured]**:

| null | false sites/cell | median enrichment | p95 |
|---|---|---|---|
| uniform CSR over the whole FOV | 10.38 | 4.23 | 7.56 |
| **`ermc` with a binary ER mask** (what the pipeline does today) | **1.93** | 2.02 | 2.84 |

An **81% reduction** already. Sec61B is an improvement on a decent baseline, not a rescue from
nothing. Its marginal value is in capturing *within-ER* density variation — junctions, sheets — that a
binary mask cannot express.

Also worth knowing what α delivers. `cs_mc_threshold.m:6-7,45` control the family-wise error rate
**per window**, not per cell. Converting the measured 1.93 false sites/cell honestly needs the
windows-per-cell count *W*:

| *W* | realized false sites/window | miscalibration vs α = 0.01 |
|---|---|---|
| 4 | 0.48 | 48× |
| 12 | 0.16 | 16× |
| **20** | **0.10** | **~10×** |

For a per-*cell* FWER of 0.05 you want α_window = 1 − 0.95^(1/W) — **0.0026 at W = 20**, against the
shipped 0.01.

---

## TIER 1 — use these

### 4. Cell-level permutation test *(the primary inferential tool)*

Permute the arm label over **cells**, recompute the entire statistic — including anything estimated
from the pooled control arm — inside every permutation. 10 VAPB vs 8 control gives C(18,8) = 43,758
assignments: exactly enumerable, minimum two-sided p = 4.6×10⁻⁵.

**Why it must be a permutation and not a fixed threshold.** The tempting shortcut is: compute
E\* = 95th percentile of pooled control enrichments, then test each VAPB cell's exceedance fraction
against the constant 0.05. Under a **true null** that rejects at **[sim]**:

| n_control | sites/cell | true-null rejection (nominal 0.05) |
|---|---|---|
| 8 | 10 | **0.146** |
| 8 | 25 | **0.147** |
| 15 | 10 | 0.101 |

E\* is estimated, and its error shifts *all* cells the same way. Note it does **not** improve with
more sites per cell — only with more control **cells**. Recomputing E\* inside each shuffle restores
validity: 0.037 at n=8 **[sim]**.

### 5. Wilcoxon rank-sum / signed-rank, cell as the unit

Rank-sum, not *t*-test: enrichment is a ratio bounded below with a long right tail, and at n ≈ 8–12
you cannot check normality in the tail that matters.

**Pair whenever you can.** Minimum achievable two-sided *p* for a signed-rank test: n=6 → 0.031,
n=8 → 0.0078, n=10 → 0.0020, n=12 → 0.00049. **n=5 pairs can never reach p < 0.05** (floor 0.0625).
This is the table to scope a paired design against — and another argument for co-imaging.

### 6. Cliff's δ / AUC with a **cell** bootstrap CI — report this instead of a p-value

δ = 2·AUC − 1. Point estimate over pooled sites; **CI by resampling whole cells**, 10⁴ replicates.
Never bootstrap sites, never bootstrap windows, never count Monte-Carlo repeats toward *n*. At
10 cells × ~10 sites a naive site-level CI is about **√10 ≈ 3× too narrow**.

### 7. Comparing the two nulls: a **quantile ratio**, not a distributional test

Report

> R = q₀.₉₉(Sec61B-derived maxima) / q₀.₉₉(`nullMax`), in smoothed-density units, per window,
> matched on λ = N/A_ER, with a 95% CI bootstrapped over control **cells**.

R has an operational meaning: the factor by which the simulated null is anticonservative *at the
exact quantile that sets `Dthr`* (`cs_mc_threshold.m:45`). R = 1.4 means every threshold in the study
is 40% too low. A referee can act on that; a p-value they cannot.

**Do not use KS.** It is maximised near the median and nearly blind in the far tail — and the far tail
is the entire object. KS can say "not significantly different" while the 99th percentiles differ by
30%. If you want a distributional test use **Anderson–Darling** (weights by 1/[F(1−F)]), with the
p-value from permuting **cell** labels, not from the asymptotic table.

**Do not compare the two rigs' `nullMax` vectors directly** — that compares two *simulations* and tells
you about *N* and mask geometry, which you already know. The informative comparison is *simulated
null* vs *observed negative control*.

### 8. Empirical-null / FDR calibration — the highest-value output

> FDR(e) = [control sites per 100 µm² of ER with enr ≥ e] ÷ [VAPB sites per 100 µm² of ER with enr ≥ e]

then set `minEnrich` = e\* = min{e : FDR(e) ≤ 0.10}. That spinner already exists
(`cs_window_picker.m:57`, gate at `cs_detect.m:69,79`) and defaults to 1.0 — **off**. This is the one
knob the Monte-Carlo null structurally cannot set, because it is conditional on *N* and has no
opinion about how large an enrichment *matters*.

Four requirements:

1. **Fix the denominator first (§0.1)** or e\* is calibrated on a statistic that moves under the
   alternative. Use a leave-sites-out background (mask detected footprints dilated by one smoothing
   length, re-estimate over the remaining ER), or the 25th percentile of `dens(erMask)` instead of the
   median. Then **verify pivotality**: simulate at 0/10/20/30% recruitment with *N* fixed and confirm
   the null-blob enrichment distribution is invariant. This check gates the whole experiment and
   costs an afternoon.
2. **Cross-fit** — each control cell against a curve built from the *other* control cells.
3. **Isotonise** FDR(e) and take e\* from the upper 90% bootstrap band; `min{e : …}` on a noisy curve
   is a winner's-curse minimum.
4. **Set π₀ = 1** and report FDR as an explicit upper bound. Every reported site has already survived
   a max-based selection, so there is no null bulk to fit π₀ against.

---

## TIER 2 — conditional

**9. Mixed-effects model, cell as a random effect.** Fit as a *secondary* sensitivity analysis if a
reviewer asks. At 8–12 cells per arm the variance components sit on ~10 df and are badly unstable,
the denominator df lands near the cell count anyway, and you have bought the rank-sum's power for a
large Gaussian assumption on a right-skewed ratio. The two-stage alternative — one number per cell,
then permute — is assumption-light and has effectively the same power at this *n*. The one place a
GLMM is genuinely right is estimating the ER-weight exponent γ in `log ρ = α_cell + γ·log occ_ER`.

**10. Ripley's K / pair correlation.** Four mandatory modifications: exclude **within-track** pairs
(otherwise K̂ is dominated by a peak at √(4D·dt) — 63 nm at 100 Hz — a purely instrumental feature
sitting in the range of interest); use the **translation (Ohser)** edge correction against the **ER
mask** boundary, not the FOV (Ripley's isotropic correction assumes a convex window and is invalid on
a reticular mask); estimate λ̂ from a covariate model, not a kernel smooth of the same data; restrict
to r = 0.20–0.80 µm.

**Pre-check before building any of it:** Sec61 is the translocon and concentrates in ribosome-studded
rough-ER sheets. Its L̂(r) − r over 200–800 nm may well **exceed** VAPB's. If it does, this arm dies
and must be reported as descriptive. Test that first — it is also by far the largest build item here
(no `spatstat` in MATLAB, 999 envelope realisations per cell per window, no caching possible).

---

## TIER 3 — traps, with the mechanism

| # | trap | why |
|---|---|---|
| 11 | **detection rates between markers** | rig-dependent 2×; **non-monotone in the signal** (recruitment depletes the background and *lifts* `Dthr`, so counts did not separate a recruitment arm from a null arm at all — 10.62 vs 9.76 **[measured]** — a count can go the *wrong way* when the effect is real); and area-confounded, 419 vs 762 µm². Legitimate only **paired**, same cells, only the null differing. |
| 12 | **the Compare tab's own rank-sum** | `spt_analyze_app.m:1919-1921` runs `ranksum` on `compareValues`, whose own comment (`:1927`) says "One value per site". Sites in a cell share an ER, a `bgMed`, a `Dthr` and the same *M* realisations. Use the tab as a **figure**, never as the p-value. |
| 13 | **any test whose n is M** | *M* is a spinner and the realisations are identical dataset-wide (§0.3). |
| 14 | **exceedance fraction against a fixed 0.05** | true-null rejection 0.146 at n=8 **[sim]**. Permute instead (§4). |
| 15 | **comparing p-values between arms** | `cs_detect.m:80` floors at 1/M and returns **exactly 0** above all maxima, and every detected site has p ≤ α by construction. Compare `peak/Dthr` or enrichment. |
| 16 | **any test whose unit is the window** | windows are not exchangeable in time — photobleaching depletes the population monotonically and the ER remodels. A stratum, never a resampling unit. Keep `stepFrames = 0`. |

---

## The honest ceiling with "a few cells"

Site-level AUC 0.686 inverts to d_site = 0.685. Propagated to a per-cell median with *k* sites per
cell and between-cell variance fraction ρ **[sim]**:

| sites/cell | ρ=0.1 | ρ=0.3 | ρ=0.5 | ρ=0.8 |
|---|---|---|---|---|
| k=5 | 1.11 | 0.95 | 0.85 | 0.74 |
| k=10 | 1.39 | 1.07 | 0.90 | 0.75 |
| k=20 | 1.66 | 1.15 | 0.93 | 0.76 |

**The honest planning value is d_cell ≈ 0.75–1.4, most likely near 1.0.** Not 1.5, not 2.0.

Power at that effect, rank-sum, α = 0.05 two-sided, against 10 VAPB cells **[sim]**:

| n_control | d=0.5 | d=0.8 | **d=1.0** | d=1.5 | d=2.0 |
|---|---|---|---|---|---|
| 3 | 0.11 | 0.19 | **0.26** | 0.50 | 0.73 |
| 5 | 0.11 | 0.23 | **0.33** | 0.66 | 0.87 |
| 8 | 0.14 | 0.32 | **0.46** | 0.81 | 0.96 |
| 12 | 0.19 | 0.41 | **0.58** | 0.89 | 0.99 |

### What each *n* buys

- **n = 1–2.** n=1 **can never reach p < 0.05** — the floor against 10 cells is 2/11 = 0.18. n=2
  bottoms out at 0.030, i.e. only under perfect separation. Descriptive figure only.
- **n = 3.** Significance is reachable (floor 0.0070) but power at d≈1.0 is **0.26** — three times in
  four a null result that means nothing. e\* carries a **±19%** bootstrap CI **[sim]**, on a statistic
  whose entire null median→p95 span is ±17% around its centre. Claimable: *"we ran a negative control
  and it produced enrichment in the range X–Y."* Not claimable: a calibrated FDR, an e\* you then
  apply, or any negative result.
- **n = 5.** Power 0.33 at d=1.0; e\* CI ±16%. A *positive* result is claimable. A negative one is not.
- **n = 8.** Power 0.46 at d=1.0, 0.81 at d=1.5; e\* CI **±13.5%**. **The first n at which a negative
  result carries information and e\* is stable enough to actually set `minEnrich`. This is the
  minimum defensible design.**

---

## Recommended order of work

1. **Decide on co-imaging.** It makes everything paired and removes the marker × rig alias. Free to
   choose now; impossible to retrofit.
2. **Verify pivotality of the enrichment denominator** (§8, requirement 1). One afternoon, and it
   gates whether an FDR calibration is meaningful at all.
3. **Acquire 8 control cells**, not 3–5.
4. Report **enrichment distributions** with Cliff's δ and a cell-bootstrap CI; use the cell-level
   permutation test for inference; report the **quantile ratio R** for the null-vs-null comparison.
5. Treat **counts** as a diagnostic and Ripley's K as speculative pending the rough-ER pre-check.

---

## Code issues this analysis surfaced

Verified against the source, not yet fixed:

| where | issue |
|---|---|
| `cs_detect.m:80` | `pv = mean(nullMax >= pk)` returns **exactly 0** for a site above all *M* maxima. `cs_identify.m:1237` already uses the add-one form `(1+Σ)/(M+1)`. The two disagree, and p=0 breaks log plotting, π₀ fitting and any FDR curve. |
| `cs_detect.m:67,77` | the enrichment denominator is estimated from the window under test, so the statistic is not pivotal (§0.1). |
| `cs_window_picker.m:643` | `h = rand(nL,1)<0.5` splits **localizations, not tracks**, so `stab` is not an independent-replication check. |
| `cs_window_picker.m:364-367` | the per-window density maximum exists only transiently — it must be persisted for §7's quantile ratio. |
| — | sites per 100 µm² of analysed ER mask (`nnz(werMask)*SF²`) is not exported anywhere; it is the only defensible rate normalisation. |
