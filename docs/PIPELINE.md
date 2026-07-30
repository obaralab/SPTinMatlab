# SPT–ContactSites pipeline — full reference

Single-particle tracking of **VAPB** (an ER membrane protein) and its **ER–mitochondria contact sites**,
in MATLAB, as three tools that hand off through files. This document is the reference of record for the
**code, inputs/outputs, folder organization, and algorithms**. Kept up to date as the pipeline is built.

- Repo: `/Users/safal-mac/Desktop/IntegratedPipeline/SPTinMatlab/`
- MATLAB R2024b. Launch: `spt_app` (Tool 1 · Track) · `spt_curate_app` (Tool 2 · Curate & Build) ·
  `spt_analyze_app` (Tool 3 · Analyze). Tools 2 + 3 are ONE implementation (`spt_analyze_app.m`) behind a
  `mode` argument — `spt_curate_app` just calls `spt_analyze_app('curate')`, `spt_analyze_app` defaults to
  `'analyze'`, `spt_analyze_app('full')` shows every tab in one window.

---

## 1. Architecture

```
Tool 1 · TRACK              handoff (files)      Tool 2 · CURATE & BUILD    handoff (file)     Tool 3 · ANALYZE
raw SPT + ER-seg + mito ─▶  tracks/*_filtered ─▶ import → curate → build ─▶ analysis/         ─▶ density → contact
match·detect·track·filter    .xml + .csv          the slow MSD step         <name>.mat  +        sites → refine →
                             + _settings.txt      → analysis/<name>.mat     active_trackstruct   sites → dwell → compare
```

Three tools, coupled only through files. **Tool 1** (`spt_app`, new, built from scratch) tracks + filters and
writes `tracks/<base>_tracks_filtered.xml` + `_spots_filtered.csv`. **Tool 2** (`spt_curate_app`) curates those
tracks (embeds `track_viewer`) and runs `build_trackstruct` (the slow MSD step) → a **named build**
`analysis/<name>.mat` (`TrackStruct.mat` unless you name it), recorded as the one in force in
`analysis/active_trackstruct.txt`. **Tool 3** (`spt_analyze_app`) starts from that build — which it resolves
through `cs_active_trackstruct` (§7.2), never by a hardcoded filename: density → contact-site picker → refine →
mapper → dwell → compare, reusing the advisor's ContactSites suite (`ContactSites_robust`, validated against the pristine
Nature-2024 `ContactSites_original`). A shared **Experiment** tab (`spt_experiment_panel`) is **tab 1 in all three
tools** — the multi-folder / per-condition manifest (day, condition, exclude, notes, derived tracked/curated/built/
picked/mapped/dwelled status and the per-stage spot/track counts behind it) that ties the dataset together and
drives Tool 3's cross-condition Compare. It lives with the project as `<project>/experiment_manifest.mat`.

---

## 2. Folder organization

### 2.1 Repository
```
SPTinMatlab/
├── run_track.m run_curate.m run_analyze.m   launchers (Tool 1 / Tool 2 / Tool 3)
├── README.md                          quick overview
├── docs/PIPELINE.md                   ← this file
├── tool1_track/                       TOOL 1 · Track (spt_app + engine)
│   ├── spt_app.m                      the app: Experiment · Match files · Detect · Track & filter
│   ├── spt_match.m                    3-folder matcher (SPT ↔ ER-seg ↔ mito-seg)
│   ├── spt_dog.m spt_detect.m spt_pool_quality.m spt_count_per_frame.m   detection
│   ├── spt_track.m                    LAP tracker (euclid/penalty/geodesic modes, §6.2)
│   ├── spt_link_cost.m spt_link_cost_geo.m spt_seg_off_fraction.m        link costs (shared)
│   ├── spt_er_support.m spt_on_er.m   ER support (mask ⊕ 1 px) + on-ER test — the strict rule (§6.2)
│   ├── spt_geo_strict_smoke.m         regression: no off-ER detection can reach a track (27 asserts)
│   ├── spt_link_compare.m             compare euclid vs geodesic linking; find where geodesic wins
│   ├── spt_compare_app.m spt_method_compare.m   3-way method-comparison window + engine (§6.2)
│   ├── spt_measure.m spt_load_seg.m spt_process_cell.m                   per-frame measure + orchestrate
│   ├── spt_write_outputs.m spt_curate_read.m spt_curate_write.m          outputs + filter
│   ├── spt_write_settings.m spt_append_curation_settings.m spt_append_detection_summary.m  provenance
│   ├── spt_track_movie.m spt_pixel_size.m spt_seg_fg_label.m
└── tool2_analyze/                     TOOLS 2 + 3 (ContactSites; one impl, mode-gated)
    ├── app/spt_analyze_app.m          the tab app; MODE selects the tab set (Experiment always tab 1,
    │                                  the rest numbered 2…N per launcher):
    │                                    'curate'  → Tool 2: Experiment · Import&Curate · Build&QC
    │                                    'analyze' → Tool 3: Experiment · Contact sites · Refine · Sites · Dwell · Compare
    │                                    'full'    → Experiment then both sets in one window
    ├── app/spt_curate_app.m           Tool 2 launcher (thin wrapper: spt_analyze_app('curate'))
    ├── app/spt_experiment_panel.m     SHARED Experiment tab embedded by all three tools
    ├── app/track_viewer.m             embedded Import&Curate tool
    ├── drivers/                       editable additive layer (TrackImporter_direct, build_trackstruct, cs_*,
    │                                    cs_experiment_scan/status/aggregate for the Experiment manifest)
    ├── ContactSites_robust/           WORKING suite (the app runs this)
    ├── ContactSites_original/         PRISTINE Nature-2024 paper suite (never run/edited)
    └── docs/                          advisor's suite docs
```

### 2.2 A dataset / project folder (Tool 1 input, Tool 2 input)
```
<project>/                      e.g. WithER/
├── spt/                        raw single-particle .tif stacks   (one per cell; the movie)
├── er_seg/                     per-frame ER segmentation stacks   (ilastik; 1=fg, 2=bg label map)
├── mito_seg/                   per-frame mito segmentation stacks (ilastik; 1=fg, 2=bg)
├── tracks/                     ← Tool 1 writes here, Tool 2 reads here
│   ├── <base>_tracks.xml           all tracks (raw run)
│   ├── <base>_spots.csv            all detections (localization cloud)
│   ├── <base>_tracks_filtered.xml  Tool 1 length/disp filter (kept tracks)
│   ├── <base>_spots_filtered.csv   all detections, TRACK_ID for kept only
│   ├── <base>_tracks_curated.xml   ← Tool 2 curation (density/variance) writes this
│   ├── <base>_spots_curated.csv    all detections, TRACK_ID for twice-curated kept
│   ├── <base>_track_metrics.csv    one row per track + a KEEP flag (Tool 2 export/batch)
│   ├── <base>_filter_log.csv       per-track kept/removed + the thresholds applied
│   ├── <base>_settings.txt         provenance: detection + tracking + curation params used
│   ├── detection_summary.csv       project-level: one row per cell (§5)
│   ├── batch_filter_report.html    Tool 2 batch-filter summary
│   └── cs_calib.mat                per-dataset calibration (written by Tool 2)
├── experiment_manifest.mat     the shared Experiment tab's manifest (day/condition/exclude/notes)
└── analysis/                   ← Tool 2 writes the build here, Tool 3 reads it
    ├── <name>.mat              a NAMED build (Tracks struct); TrackStruct.mat by default, several may coexist
    ├── active_trackstruct.txt  one line: the basename of the build IN FORCE (§7.2)
    ├── cs_calib.mat            copied in from tracks/ at build time
    └── Densities/ csIDs/ mips/ Density_<cell>_CSwindows.mat CS_footprints.mat CS_trackedits.mat
        CSW_final.mat cs_window_metrics.csv cs_window_dwell.* cs_window_track_labels.csv step/ …
```

`<base>` = the spt file name, e.g. `250408_WT_012_spt1`. Channel-name mismatches (the seg files carry a
`_VAPB` / `_2_TA_BC` / `_3_TA_BC` token the SPT lacks) are bridged by `spt_match` (§4.1).

---

## 3. Calibration (per-dataset — cameras differ)

Every stage reads calibration from **`cs_calib.mat`** (a `calib` struct) via **`cs_config.m`**; defaults
apply when absent. Set in the app top bars. **These are per-dataset** because the advisor's paper used a
different camera (FOV 20.48 µm) than the current rig (FOV 27.61 µm).

| field | meaning | this rig |
|---|---|---|
| `pixSizeUm` | camera pixel size (µm/px) | 0.10785 |
| `fovUm` / `snapFovUm` | field of view (µm); drives the density-map **scale factor** SF = FOV/imgHeight | 27.61 |
| `dt_s` | frame interval (s) | 0.020064 |
| `binNm` | localization precision / density-bin size (nm) | *set per camera* (paper: 30) |

The scale factor now comes from `cfg.SnapFOV_um` (robust suite), **not** the paper's hardcoded 20.48 —
so contact-site geometry follows your camera. (TODO: route `binNm` through `cs_config` everywhere; a couple
of picker sites still default to 30 nm.)

---

## 4. Tool 1 — Track & filter

Input: the 3 folders (`spt/`, `er_seg/`, `mito_seg/`; ER/mito optional). Tabs: **1 · Experiment · 2 · Match files ·
3 · Detect · 4 · Track & filter**.

### 4.1 Match (`spt_match.m`)
Pairs each SPT stack with its ER/mito seg by a shared key: strip the channel suffix (`_spt\d*`,
`_(2_TA_BC|er_mip|er)`, `_(3_TA_BC|mito_mip|ch1_mito|mito)`) + a user token (default `_VAPB`). Returns
`{key, spt, erSeg, mitoSeg}` per cell.

### 4.2 Detect (`spt_dog.m`, `spt_detect.m`, `spt_pool_quality.m`)
Difference-of-Gaussians on a background high-pass, scaled by the **spot diameter (µm)**; 5×5 non-max
suppression + subpixel centroid. Per-spot **quality = the DoG response at the peak**. Two threshold modes
(Detect-tab dropdown): **Top %** — keep the top X% of pooled candidate qualities, adapting per cell
(default **6%**); or **Quality ≥** — a fixed absolute DoG-quality gate applied to every cell (directly
comparable across cells). Both resolve to `spt_detect`'s 4th arg `thrAbs`. Detection runs on **every frame**
(all 5981 frames of the WithER cell) and yields the full localization set. **Provenance:** each cell's
`_settings.txt` records `threshold_mode`, `top_percent`, `quality_min`, and the resolved `thr_abs`; a
project-level `tracks/detection_summary.csv` keeps **one upserted row per cell** so every cell's threshold
is visible at a glance (`spt_write_settings.m`, `spt_append_detection_summary.m`).

**Localization** is a 5×5 intensity-weighted **centroid** (center of mass) on the high-pass image — not a
Gaussian fit, so there is no fitted PSF width or per-spot Cramér-Rao precision. Two derived metrics fill that
gap:
- **Motion blur** (`spt_detect` 2nd output): the intensity **second-moment covariance** of each spot (7×7
  window) → principal widths `σ_maj/σ_min`, **ELONGATION = σ_maj/σ_min**, and major-axis **ORIENT_DEG**. A
  round spot has elong≈1; a particle that moves during the exposure streaks (elong ≳ 1.5) — written as
  `ELONGATION`,`ORIENT_DEG` columns in `_spots.csv`/`_spots_filtered.csv`, and shown in the Detect preview by
  colouring spot rings green (round) / red (elong ≥ 1.5, likely motion-blur).
- **Localization precision** (`drivers/spt_fit_msd.m`, Tool 2): fit MSD(τ)=4Dτ+b; the τ→0 intercept b=4·σ_loc²
  gives a per-track precision **σ_loc = √b/2** (`sigLocUm`). Build & QC reports it for the **clicked** track only,
  as a trailing `· σ_loc≈N nm` on the QC readout line — deliberately a small caveat rather than a headline,
  because it is fit-window dependent, and because the intercept also absorbs confined/blur dynamic error within
  the first lag, so it is an *upper bound* on the static precision. There is no pooled/ensemble annotation.

The **track player** (`spt_track_movie.m`, used in Track & filter) shows the true movie length: its title
reads "N tracks · track span f0–f1 of NFR frames" and the scrubber spans the whole movie, so the animated
tracks' frame span is never mistaken for the movie length.

### 4.3 Track (`spt_track.m`) — LAP linking + ER penalty
Frame-to-frame links solved as a linear assignment (`matchpairs`). Then chains are assembled and
gap-closed. **See §6.2 for the ER-aware penalty in full.** TrackMate-equivalent params: link distance,
gap-closing distance, max frame gap.

### 4.4 Per-spot mito & ER distance (`spt_process_cell.m`, `spt_load_seg.m`)
For every detection, the **signed distance** (µm) to the nearest mito and ER pixel **in its own frame**
(`bwdist(mask) − bwdist(~mask)`; − inside, + outside). Uses the per-frame seg masks. Written as
`MITO_DIST_UM` / `ER_DIST_UM`. Blank when that segmentation is absent.

### 4.5 Filter (Track & filter tab; `spt_curate_read/write.m`)
Filter **tracks** by min length + min displacement. **Localizations are never filtered** — every detection
is preserved; only `TRACK_ID` is renumbered (kept 0…K-1) or blanked. Writes the `_filtered` pair.

### 4.6 Outputs
See §5 for schemas. Per cell: `_tracks(.|_filtered).xml`, `_spots(.|_filtered).csv`, `_settings.txt`.

---

## 5. File formats

### `<base>_spots(_filtered|_curated).csv` — one row per **detection**
```
TRACK_ID, SPOT_ID, FRAME, T_s, X_um, Y_um, QUALITY,
MEAN_INTENSITY, MAX_INTENSITY, TOTAL_INTENSITY, MITO_DIST_UM, ER_DIST_UM, ELONGATION, ORIENT_DEG
```
- Every detection is present (the localization cloud). `TRACK_ID` blank ⇒ untracked or dropped-track spot.
- `X_um = (x-1)·pixSizeUm`, `Y_um = (y-1)·pixSizeUm` (0-based pixel origin). `T_s = FRAME·dt_s`.
- `MITO/ER_DIST_UM`: signed µm to nearest mito/ER pixel in that frame (− inside, + outside); blank if no seg.
- `ELONGATION` = spot σ_maj/σ_min (≈1 round, ≳1.5 likely motion-blur); `ORIENT_DEG` = major-axis angle 0–180°.

### `<base>_tracks(_filtered|_curated).xml` — the linked tracks
```xml
<Tracks nTracks= frameInterval= spaceUnit="um" timeUnit="s">
  <Track TRACK_ID=…>
    <Spot FRAME= T= X= Y= Z="0.0" SPOT_ID=…/> …
  </Track> …
</Tracks>
```
`SPOT_ID` is shared with the CSV — that's the join key downstream.

### `<base>_settings.txt` — run provenance (detection + tracking params)
Key=value lines: `detection.diameter_um`, `detection.threshold_mode` (top-percentile|quality-abs),
`detection.top_percent`, `detection.quality_min`, `detection.thr_abs`, `tracking.method`,
`tracking.link_mode` (the **effective** engine key euclid|penalty|geodesic; plus
`tracking.link_mode_req` only when an ER mode was **downgraded** for a cell with no ER segmentation),
`tracking.link_um`, `tracking.max_gap_um`, `tracking.max_gap_frames`, `tracking.er_aware`,
`tracking.lambda`, `calibration.pixel_um`, `calibration.frame_s`, `result.n_spots`, `result.n_tracks`,
`result.have_er`, `result.have_mito`. In **geodesic** mode two more lines record what the strict rule
excluded: `tracking.frames_no_er_mask`, `tracking.dets_off_er` (§6.2).
**Tool 2 reads the tracking lines to populate its curate params.**

### `detection_summary.csv` — project-level detection + tracking log (one row per cell)
Header, in order (`spt_append_detection_summary.m`):
```
cell, threshold_mode, top_percent, quality_min, thr_abs, diameter_um,
link_mode, link_um, max_gap_um, max_gap_frames, lambda,
n_spots, n_tracks, er_aware, run_time
```
`link_mode` is the **effective** engine key (the same value as `<base>_settings.txt`'s
`tracking.link_mode`, so a cell downgraded for want of an ER segmentation reads `euclid` here).
`quality_min` / `thr_abs` are `NA` when they do not apply. Upserted by cell name on every run, so with
many cells you can see each cell's threshold **and linking parameters** at a glance and audit which
percentile / quality gate produced each result.

### Curation naming
`_filtered` = Tool 1 (length/displacement). `_curated` = Tool 2 (density/variance/manual). Both preserve
the full localization cloud; the raw `_spots.csv`/`_tracks.xml` are the untouched full record.

---

## 6. Algorithms

### 6.1 Signed organelle distance
`sd = bwdist(mask) − bwdist(~mask)` per frame, sampled at each localization. `+` outside the organelle,
`−` inside, ~0 at the boundary. Drives `MITO_DIST_UM`/`ER_DIST_UM` and, downstream, contact classification.

### 6.2 ER-aware linking (`spt_track.m`) — ER-penalty (**λ (lambda), used = 3**) · ER-geodesic (strict)

The linker assigns spots frame→frame to minimize total cost. For a candidate link p (frame t) → q (frame t+1):

```
base cost   = ‖p − q‖  (pixels);   set to ∞ beyond the link radius R = link_um / pixSizeUm
ER penalty  = base cost × (1 + λ · off)          when ER-aware
off         = fraction of the p→q segment's MIDDLE (20–80%) that lies OFF the ER mask (that frame)
```

`off ∈ [0,1]` samples the straight segment between the two spots (excluding the endpoints, which are the
spots themselves) against the **per-frame** ER support mask. So the penalty asks: *does the path between
these two spots cut across a gap in the ER?*

**What λ = 3 means concretely** (cost multiplier `1 + λ·off`):

| link path vs ER | `off` | cost multiplier | effect |
|---|---|---|---|
| entirely on ER | 0 | ×1.0 | no penalty |
| half off ER | 0.5 | ×2.5 | penalized |
| entirely off ER | 1.0 | **×4.0** | strongly penalized |

Because the assignment compares costs, an **off-ER partner is chosen only if it is enough closer to
overcome its multiplier** — with λ=3, a fully-off-ER jump must be ≈**4× shorter** than a fully-on-ER
alternative to win. **This describes ER-penalty only.** There it is a **soft bias, not a hard gate**: an
off-ER link is still allowed (it can still beat leaving the spot unlinked — the no-link cost is
`d0 = R·(1+λ)+1`, just above the worst penalized in-range cost), which is correct because VAPB does
transiently leave the ER. **ER-geodesic makes the opposite trade deliberately** — it forbids off-ER
detections outright (below), buying the guarantee that every tracked spot was on the ER, at the price of
the transient excursions.

**Gap-closing** (bridging a track end to a later start across ≤ `max_frame_gap` missing frames, within
`gap_um`) applies an ER test that **matches the linking mode**:
- **ER-penalty** — reject the bridge if the straight segment is **> 50% off ER** (evaluated on the end
  frame's mask). A veto, but not a hard on-ER requirement: up to half the bridge may be off-ER.
- **ER-geodesic** — the bridge must be **reachable along the ER**: both endpoints on their own frame's ER
  support and connected along it within `gap_um` (the same `spt_link_cost_geo` call the linker uses; ∞ =
  refuse, a missing mask = refuse). So a gap close can never make a jump that frame-to-frame linking
  would have forbidden.
- **Euclidean** — no ER test.

**Why a single-frame overlay can look "off ER":** a track's full path spans many frames, but any overlay
frame shows the ER at one instant; the ER moves, so path segments from other frames sit on that frame's ER
holes even though they were on-ER when the particle was actually there. Both ER tests — the penalty and the
strict geodesic gate — are evaluated **per-frame, against the contemporaneous ER**, so judge on-ER-ness by
playing the track (marker vs current-frame ER), not by the static path.

**Linking modes** (`spt_track` arg `mode`; Track-tab dropdown):
- **Euclidean** (`'euclid'`) — distance only; λ ignored.
- **ER-penalty** (`'penalty'`) — the soft penalty above (straight-line off-ER fraction).
- **ER-geodesic** (`'geodesic'`) — a **strict, hard ER constraint**, not a bias. A detection must sit on
  **its own frame's** ER support — the mask **dilated 1 px** (`spt_er_support.m`, the single definition,
  1 px of slack for the SPT/ER registration offset; `spt_on_er.m` runs the test). A detection that does not
  is **removed before the assignment** (`spt_track` pre-filters `dets{t}`), so it **cannot enter a track by
  any route** — frame link, chain assembly or gap close. It is not deleted from the data: it stays in
  `_spots.csv` with a **blank `TRACK_ID`**, like any other untracked detection. A surviving link costs the
  **along-ER geodesic length** (`bwdistgeodesic` on a local ER crop), so a link that must **detour around an
  ER gap** costs its true path length. Everything else is **forbidden (∞)**: a target off **its own** frame's
  ER (the target is validated against frame t+1's mask, because the ER moves between frames), an
  **unreachable** partner, or an along-ER **detour longer than R**. **λ is ignored** in this mode except in
  the birth/death cost `d0`. This is the rigorous version of "reachable along the ER": it fixes the
  straight-line proxy's blind spots (over-penalizing a link whose straight line cuts a concave ER bay;
  under-penalizing one that merely skims the ER edge).
  **It fails closed:** a frame with **no ER mask contributes nothing** — every detection in it is excluded,
  rather than the missing mask being read as "no constraint here" and silently degrading to unconstrained
  Euclidean linking (`spt_track` warns `spt_track:noErMask`). The counts are recorded in the run provenance:
  `tracking.frames_no_er_mask` and `tracking.dets_off_er` in `_settings.txt`. A cell with **no ER
  segmentation at all** is downgraded to Euclidean **once, explicitly** (`spt_process_cell.m`); the settings
  file then reports the **effective** mode plus `tracking.link_mode_req` (what was asked for). Cost functions
  are shared: `spt_link_cost.m`, `spt_link_cost_geo.m`, `spt_seg_off_fraction.m`, `spt_er_support.m`,
  `spt_on_er.m`. Regression: `spt_geo_strict_smoke.m`.

**Method-comparison app** (`spt_compare_app.m` + engine `spt_method_compare.m`; Track-tab "⚖ Compare
methods" opens it in a **new window**). Over a frame window it (1) runs **full tracking** (LAP + gap-close)
under all three modes → a **bar chart of track counts per method** (+ medians, and Δ vs Euclidean), and (2)
lists every place the methods link a spot to a **different partner**, and plays the selected one as **three
synchronized videos, side by side — one per method**.

The three players share a cropped region, a frame, and a `± frames` window (default 10 → 22 frames), and
each draws **only its own method's tracks** over the **real frames** (not a max projection). The methods are
therefore *compared*, not overlaid — the overlay was the thing that made the old static grid unreadable.
Within a panel the **focus track** (the chain containing the disagreeing spot) is bright in the method
colour, every other track in the box is thin grey context, and a **dotted** focus segment is a gap-closed
jump. Under each panel a **divergence strip** fills on the frames where that method's chain exists (so a
method that has *no* track there reads instantly as an empty strip) with ticks where the three chains
disagree; click it to seek.

Two panel badges carry the usual outcome, which would otherwise read as a broken app: **"ER-penalty —
identical to Euclidean here"** and **"ER-geodesic — spot excluded (off ER)"**. On the test cell these fire in
roughly three quarters and just over half of examples respectively: the difference strict linking makes is
most often an **absence**, which is exactly what a single overlaid picture cannot show.

The example list is ranked by how much the three chains actually differ over the playback window (not by the
engine's single-link off-ER heuristic), and names what differs. Selecting one opens it **paused at the first
frame where the methods diverge** — opening on the disagreement frame itself usually shows three identical
panels. A **Backdrop** dropdown draws on the raw frame with the ER outline (default), a light ER tint, the
raw frame alone, or the ER mask, with a contrast slider; both redraw from preloaded frames (no re-tracking).
A **Min len** spinner (defaults to the Track-&-filter min length) re-counts the bars from the stored tracks at any
threshold, since the raw counts are unfiltered and the method with more tracks *flips* with the threshold.
The summary panel reports **how many detections ER-geodesic excludes** (ER-penalty excludes none — it links
every detection Euclidean does and differs only in *how* it groups them).
`.counts`/`.tracks`/`.summary`/`.instances` returned; frame window and list length adjustable.
**"Save video…"** writes the selected example's window as an MPEG-4 of all three players
(`exportgraphics` on the players panel); "Save figure…" exports the whole window as a PNG.
Regression: `spt_compare_smoke.m` (asserts the panels differ per method and that the video is readable).

> Index conventions inside `spt_compare_app.m`: `cmp.tracks.<mode>{j}(:,1)` is a **window index** `k`
> (1…nF into `cmp.dets`/`cmp.ERs`), while `cmp.instances.frame` is an **absolute** movie frame `t`, with
> `t = cmp.fr(1) + k − 1`. Mixing them is the easiest bug to introduce here.

**Benchmark** — measured on `250408_WT_012_spt1` (WithER), **frames 1–300**, 11 535 detections, pxUm
0.10785, link 0.8 µm · gap 1.4 µm · maxGap 1 · λ = 3 · Top 6%; **after** the strict-geodesic change (any
older figure quoting geodesic ≈ 612 tracks predates it):

| mode | tracks | linked dets | % linked | med len | max len | tracks ≥ 50 fr |
|---|---|---|---|---|---|---|
| Euclidean | 560 | 11111 | 96.3% | 8.5 | 300 | 56 |
| ER-penalty | 617 | 11108 | 96.3% | 7 | 300 | 49 |
| ER-geodesic | 644 | 10361 | 89.8% | 7 | 246 | 37 |

The strict pre-filter excluded **653 of 11 535 detections (5.7%)** as off their own frame's ER; **0 frames
had no ER mask** (the ER stack has 5981 pages, same as the movie). The last column is what survives the
Track-&-filter export default `Min track length = 50`. (The older 2-way `spt_link_compare.m` engine — Euclidean vs
geodesic only — is retained.) Regression: `spt_compare_smoke.m`, `spt_geo_strict_smoke.m`. Cost functions
shared with tracking (`spt_link_cost*`, `spt_er_support`/`spt_on_er`), and the comparison passes the
**target** frame's ER mask to `spt_link_cost_geo` so it matches what tracking does.

### 6.3 Localization density (Tool 2 curate + contact sites)
Crowding metric = for each spot, the number of other spots within the linking radius in the **same frame**;
per track = the worst-case (densest) frame. High local density + high step-size variance ⇒ mislinkage-prone
(the Tool 2 Curate filters on these). The contact-site density map bins localizations into `binNm` bins.

---

## 7. Tools 2 + 3 — Curate & Build · Analyze

New tab app `spt_analyze_app.m`; reuses the drivers + `ContactSites_robust` suite. Build order:

1. **Import & Curate** *(done)* — embeds `track_viewer`: reads Tool 1's `_filtered` pair, curates by
   **local density + displacement variance + jump gate** (params auto-filled from `_settings.txt`),
   per-frame ER/mito overlay (colour-selectable), writes `_curated` preserving the localization cloud.
   The **Selected-track** panel plays the track over the **raw SPT movie** (zoomed, per-frame; `Raw SPT bg`
   toggle + contrast), overlaying only the selected + nearby spots as rings. Manual **keep/reject** (Toggle)
   records `manual_keep`/`manual_reject` that **override the auto-filter and survive a re-apply**
   (`kept = (filter ∖ manual_reject) ∪ manual_keep`); the preview count shows the override-adjusted total.
   The **batch filter** applies the same absolute thresholds — plus each cell's own saved manual keep/reject —
   to every cell, and writes the same set the interactive Export does: `_tracks_<exportSuffix>.xml`
   (**`_tracks_curated.xml`** in Tool 2, since `exportSuffix='curated'`), `_spots_curated.csv`,
   `_track_metrics.csv`, `_filter_log.csv`, plus one `batch_filter_report.html`. Any write that would land on
   the file it just read is **refused and logged** (`same_file_`, canonical paths, so a relative out-dir or a
   symlinked `tracks/` cannot slip past), so Tool 1's `_tracks_filtered.xml` can no longer be overwritten by
   its own re-filtering.
2. **Build & QC** *(done)* — `build_trackstruct` on the `_curated` tracks (falls back to `_filtered`/raw if
   not yet curated) → **`<project>/analysis/<name>.mat`** (the slow MSD step, once, after curation), where
   `<name>` is the tab's **Name** field (default `TrackStruct`) — see *Named builds* below. Building also
   copies `tracks/cs_calib.mat` into `analysis/`. A **📂 Load TrackStruct…** button (`onLoadTracks`) loads an
   existing build and shows the QC **without recomputing MSD**: when the project holds **more than one** build
   it always opens a file picker (the shortcut to the active one made the other named builds unreachable),
   otherwise it goes straight to the active one. It infers the project from an `analysis/` path, copies the
   struct into `analysis/` **under its own name**, makes it active, and adopts any `cs_calib.mat`
   (`applyCalib`). QC survives structs with **no `erDist`/`mitoDist`/`MSD`** (a `fieldOr` guard), so no-ER or
   older builds load cleanly. Carries `mitoDist`/`erDist` per tracked spot + `allSpots` (every detection).
   Time unit `frame` (default; reproduces legacy MSD binning) or `seconds`.

   **Named builds — the ACTIVE TrackStruct.** A project may hold several builds side by side in `analysis/`
   (`Day1_WT.mat`, `Day1_KO.mat`, …). Every build **and** every load writes the basename of the one in force
   into **`analysis/active_trackstruct.txt`**, and **`drivers/cs_active_trackstruct.m` is the single
   resolver** — resolution order: (1) `active_trackstruct.txt` when it names a file that exists, (2)
   `TrackStruct.mat` (the default name, what every pre-naming project has), (3) `Tracks.mat` (legacy), (4)
   any other `.mat` in the folder that actually contains a `Tracks` variable, so a hand-copied build
   registers even without a pointer; `''` when the folder holds no build. Tool 3, the contact-site picker
   (`cs_window_picker`), the window mapper (`cs_window_mapper`), the footprint builder
   (`cs_footprints_build`), `cs_refine`, the experiment scan (`cs_experiment_scan`) and the Experiment
   **built** lamp (`cs_experiment_status`) all resolve through it, so they can never disagree about which
   file the folder is working from — and a separately launched `run_analyze` opens the build the Curate tool
   last wrote or loaded. The picker also accepts an already-loaded struct via `opts.Tracks` (plus
   `opts.tsFile`), so Tool 3 does not put a second full copy of the same build in RAM; it falls back to
   `cs_active_trackstruct` when run standalone. **`Tracks.mat` is legacy**: it is written only by
   `run_contactsite_analysis`, which only the old one-window `spt_pipeline_app` / `pipeline_gui` invoke, so
   it never appears in the `run_curate` → `run_analyze` flow.

   **Per-localization diffusion is computed at build** (`addDiffusion` → `drivers/spt_track_diffusion.m`,
   after the MSD import and before the save; also filled in on Load for an older build that lacks it). It is
   the native-MATLAB equivalent of `run_step.py`'s noise-corrected rolling estimator —
   `D = ⟨dr²⟩/(4·dt) − σ²/dt`, floored at 0, over a rolling window of 7 localizations (`mode 'lag1'`; a
   local-MSD-slope `'msdfit'` mode also exists) — and **adds four fields** to every cell, all aligned with
   `matrix` (`[nF × nT]`, NaN/false where there is no localization): **`Dt`** (D per localization, µm²/s),
   **`confined`** (`Dt ≤ confineD`), **`stateChange`** (the rising edge into a confined run — a fast→slow
   capture event), **`diffOpts`** (provenance: `dt, sigmaUm, win, mode, confineD, method`). The **confined ≤ D**
   spinner (default 0.15 µm²/s) re-derives `confined`/`stateChange` from the **stored** `Dt` — cheap, no
   re-rolling and no rebuild — re-saves the **active** build (not `TrackStruct.mat` unconditionally, which
   used to leave a divergent shadow file) and refreshes the QC. These fields are what Tool 3's **Confined /
   State-change** density channels run on (§7.3).

   Then, in the same tab, an **interactive QC** (per cell or pooled): a per-cell summary table; pooled
   **track-length**, **ER/mito signed-distance** (with **on-ER %** — §6.2, e.g. "on-ER 96.0% (median
   −0.193 µm)") and **D-distribution** (per-track D = slope/4, median annotated, the confinement threshold
   drawn as a line, titled with the % of confined localizations and the state-change count) histograms; three
   further panels off the diffusion + step fields —
   - **stepwise D (per localization)** — the pooled `Dt` histogram. A *different quantity* from the
     D-distribution above: that one fits an MSD per **track**, this is the rolling D at every
     **localization**, and it is what the `confined`/`stateChange` flags (and Tool 3's density channels) are
     derived from. Log-y (the confined peak sits orders below the bulk); the top 0.5% is **dropped**, not
     clamped into the last bin (clamping built a false spike that read as a real population); confinement
     threshold marked; titled median · % confined · n.
   - **stepwise D(t)** *(the clicked track)* — that track's `Dt` against time along the track, points
     coloured mobile vs confined, the threshold as a dashed line, and each `stateChange` frame as a vertical
     marker; titled median · % confined · # state-changes.
   - **CSD — cumulative displacement** — every track's cumulative path length (µm) vs step number, faint,
     with the **median** curve bold and the clicked track highlighted on top. The median is drawn only while
     at least `max(5, 10%)` of tracks are still alive at that step — past that it is a handful of long tracks
     and drifts upward — and the title says how far that is, plus the median total path length.

   — and a **clickable tracks panel**: click a track to (a) highlight its trajectory, (b) **play it in the
   embedded player panel** (SPT frames + per-frame ER/mito overlay, right in the tab — no popup), (c) see its
   **MSD with a D = slope/4 linear fit** whose title reports **D and the fit R²** (goodness-of-fit), and
   (d) see the **D & R² vs fit-window sweep** for that track. A **D fit** dropdown chooses *Fixed %* (the same
   % of lags for every track) or *Adaptive R²* (per track, the largest window up to that % that still fits
   with R² ≥ 0.95), and one **fit %** spinner drives both the per-track fit and the pooled D-distribution;
   re-fitting preserves the clicked track. The fit itself is `drivers/spt_fit_msd.m` (extracted from the app
   so it is unit-testable), returning `D, R², b, sigLocUm, nPts, fracUsed, lag, y, fitX, fitY`; the embedded
   player is `spt_track_movie(panel)`, torn down on app close.
3. **Contact sites** *(done — consolidated windowed picker; the standalone Density tab was removed and folded
   in here)* — embeds a purpose-built **time-resolved** picker `cs_window_picker.m` (non-blocking, opens
   in ~1 s). It splits each cell's movie into **frame windows** (you set *frames per window*; a tiny trailing
   remainder merges into the last — or a *step frames* stride smaller than that, giving sliding, overlapping
   windows that follow a moving site) and shows **one localization-density panel per window in a grid**; click a
   window → a large **zoomed detail view** to **＋Add** sites by clicking, **Detect** on demand, and
   **multi-select** the site list to remove.
   - **Density source is fixed to tracked-only** — the density (and therefore the null, the peaks and the
     saved `windows.source`) is always built from the active build's `matrix`, i.e. curated tracked
     localizations. There is **no all-vs-tracked toggle**: `st.src = 'tracked'` is hardcoded and `cellLocs`
     is always called with `useTracked = true`, which keeps single-frame noise out of the map. The full
     `allSpots` cloud is read only for the status readout `detections N · tracked M (P%)`.
   - **Channel** dropdown — what *is* selectable is **which** tracked localizations the density is built
     from: **Tracked** (all of them; default), **Confined (low D)** (only localizations flagged `confined`),
     or **State-change** (only fast→slow entry localizations). The last two identify sites by **diffusion
     state** rather than by density alone, and read the per-localization `confined`/`stateChange` flags
     stored at Build (§7.2) — so the dropdown is **disabled** for a build without them. Switching channel
     invalidates the per-window density and MC-null caches, so **re-run Detect** afterwards; the status line
     then carries `· channel <name> (N locs)`.
   - Display: **contrast** (turbo clip at contrast·peak) + **map α** (dim to reveal points) +
     **＋locs** overlay (this window's localizations).
   - **Detection** (`cs_detect.m`): **ER Monte-Carlo** (default; null scatters the on-ER localizations
     **uniformly inside the ER footprint** — no intensity weight, binary seg — so only peaks above
     ER-confined density survive; α=0.01 → ~1–25 sites/window vs the old ~208), **Local background**,
     **Relative**. `sens` is the ER-MC family-wise **α** (false-positive rate per window; the cutoff is the
     `(1−α)` quantile of the null peak); **MC sims** sets the number of null runs (default **300** — enough
     that the per-window cutoff is steady; too few, e.g. the old 60, made the extreme quantile noisy and
     collapsed some windows to a couple of sites). The null is computed **once per window on Detect**
     (cached, reused by the colorbar via `cs_detect`'s optional precomputed `Dthr`), so window-clicks stay
     instant. The ER support is the **start-frame ER mask of each window**
     (moving-organelle-correct), resized to the density grid. Sites classified mito/non-mito from per-spot `MITODIST` (`cs_mito_from_dist`,
     `contact µm` gate).
   - **ER/mito overlay** = the seg **boundary at the window's start frame** (`bwboundaries`, registered on the
     density grid), toggleable.
   - **The colorbar** beside the detail view has three modes: *density (a.u.)* (default) = the σ-smoothed
     density the detector uses, turbo strip with the **CSR null band** (median→cutoff) + the **cutoff line**
     (`Dthr` at α, from `cs_mc_threshold`'s cached `nullMax`) + the observed **peak** + its **p-value**;
     *locs / 30 nm bin* = the raw localization COUNT per 30 nm pixel (interpretable units), with the **ER-MC
     CSR background line** (= on-ER locs ÷ ER bins, the expected count/bin under uniform ER scatter) and a
     `peak (N× enrich)` readout; *significance (p)*
     recolours the detail map by per-pixel FWER p = `mean(nullMax ≥ D)` (hot = small p). The cutoff/peak-p
     read out on the status line (not a cut-off colorbar title), which reads `<cell> · detections N ·
     tracked M (P%) · <nW> windows · mito from MITODIST`, then `· THIS window <n> tracked locs`, then the
     colorbar's own `· cutoff α=… · peak p=…`. So it answers "how much of the cloud is in this window" — and
     it says `<nW> of <wanted> windows ⚠ frames N+ NOT analysed` when the 24-panel cap has cut the movie
     short, because every number in that window list is then partial.
   - **Save** writes, per cell, `csIDs/<cell>_CSsites.txt` (8-col; **`Slice` = window index**, `Counter` = mito
     flag — still mapper-readable), beside it `_CSsites_stats.csv` (per site: p, enrichment, #locs, #tracks,
     stability, dwell %, area) and `_CSsites_provenance.json` (every detection parameter that produced them),
     + `analysis/Density_<cell>_CSwindows.mat` (per-window frame ranges, grid, SF, `source`)
     for time-resolved downstream. The advisor **`Densities/<cell>_rho.tif` + `Density_<cell>.mat/.tif`** export
     (`saveDensityFiles`, byte-identical to `DensityVisualization`/`LocDensityFigIntUse`) is still written on
     launch behind a checkbox, for the legacy mapper. `cs_identify` remains as the legacy engine.
4. **Refine** *(done)* — the paper's mouse-driven refiner (`cs_refine.m` behaviour), folded into the
   modern pipeline as an **interactive footprint editor**. `cs_footprints_build.m` (headless) computes the
   **auto** half-max footprint for every picked site (or resumes an existing `CS_footprints.mat`). Per site the
   editor shows the **window density**, the footprint, the **localizations** (a *show localizations* overlay of
   this window's points), and the tracked member trails; on the side a **radial concentration plot**
   (`cs_radial_plot.m`) draws the cumulative localizations-within-radius curve against a **cell-wide
   ER-uniform** expectation (the same localizations spread over ALL this cell's ER at its average density;
   `erNullForSite` builds it, and the disk-uniform CSR curve is only the fallback when the cell has no usable
   ER mask), with a concentration index 0 = diffuse → 1 = tight, plus the *% of window locs inside the boundary*.
   You refine either the **paper way — ✎ Draw centre + boundary** (`drawpoint` sets the centre, then
   `drawfreehand` traces the boundary; both in µm), or the **auto way** (**frac / maxR** spinners recompute the
   half-max blob), or **↺ Reset to auto**. Only sites you actually edit are flagged `edited`. **💾 Save** writes
   `analysis/CS_footprints.mat` (var `CSfoot` — only the edited sites: `file, cellIndex, csID, window,
   winFrames, pickPx, center [µm], refboundary [µm rel center], mode, frac, maxRadiusUm, SF, grid, densSrc,
   mito, edited, deleted`) plus a `CSdeleted` list. The mapper **overrides** the auto footprint per site (and
   **skips** deleted sites), keyed on `file|csID|window` and guarded by a `pickPx` staleness check (a re-pick
   won't mis-map/mis-skip an old entry); the Sites tab's **use refined** toggle (→ `opts.useRefined`) turns
   overrides+deletions on/off. A hand-placed centre may differ from the pick — the mapper applies the moved
   centre while still matching the site by its original `pickPx`. **Only edited/deleted sites are persisted**;
   re-loading rebuilds the full auto list and **merges** the saved edits + deletions back on (matched by
   `pickPx`), so resume shows every site. The auto outline is **half-max only** (`frac`/`maxR`; box/disk remain
   internal fallbacks). The density **source is LOCKED** to whatever the picker used (`windows.source`, read by
   `cs_load_windows`) — no toggle, just a locked label. More editor affordances: the **radial concentration**
   plot sits full width beneath the editor (no cut-off); a **colour-scale** dropdown + colorbar + contrast
   slider — *density (a.u.)* (smoothed), *locs / bin* (raw count image), or *significance (p)*, which **recolours
   the map** as a per-pixel FWER **p-map** (`1 − p`, hot = density unlikely under a random scatter) from a
   per-window **CSR Monte-Carlo** null (`cs_mc_threshold`, cached); and a **🗑 Delete site** toggle — one click
   marks the site deleted, the next restores it (rows flag `✎`/`✗del`). Refinement is **optional**. Shared parsers `cs_read_sites.m` / `cs_load_windows.m` /
   `cs_default_gridsf.m` back both the mapper and the footprint builder (one source of truth).
5. **Sites** *(done)* — runs the **windowed mapper** `cs_window_mapper.m` (headless) over every picked
   site. For each `(site, window=Slice)` it: rebuilds the window density (`cs_window_density`, the same map the
   picker showed); derives an **auto footprint** `cs_window_footprint.m` = the connected blob of
   `density ≥ frac·localPeak` (default `frac=0.5`, half-max) containing the pick, clipped to a `maxRadius`
   disk (default **0.6 µm** — a MERC is sub-micron), traced to a polygon (box/disk fallback if degenerate or
   FOV-edge-truncated); assigns **member tracks + localizations** by a **spatial (in-footprint) AND temporal
   (frame ∈ window)** mask over the **tracked `matrix`**; and computes area / n-loc / prob-mass / peak-prob /
   **enrichment** via the reused `csDensMetricOne` kernel (extracted verbatim to `drivers/`, contract: it wants
   `refboundary` in **nm** rel `refCenter`, and indexes `cc.rho(xbin,ybin)` = the **transpose** of a `[y,x]`
   image). Window frame ranges come from `Density_<cell>_CSwindows.mat` (authoritative; never recomputed);
   with no CSwindows file it **falls back to one whole-movie window** per Slice. Membership + the dwell
   coordinate frame (`CSmatrix`, µm rel refCentre) are **always** on `matrix`; only the density/enrichment
   *source* may be `all`/`tracked`, and it is **locked to `windows.source`** written by the picker — which is
   now always `tracked` (§7.3), so `all` survives only as the mapper's standalone default. The tracks come
   from the **active** build (`cs_active_trackstruct`), not a hardcoded `TrackStruct.mat`.
   Output: **`analysis/CSW_final.mat`** (flat struct, one element per
   site×window, carrying `siteUID, window, winFrames, refboundary, tracks, LocIDs, CSmatrix, MitoFlag,
   enrichment, …`) + `cs_window_metrics.csv`. If `analysis/CS_footprints.mat` exists (from the Refine tab) it
   **overrides** the auto footprint (and **skips deleted sites**) per matching `file|csID|window`. The tab shows a **per-(site,window) results
   table** — columns `cell · site · win · mito · area µm² · tracks · enrich`, with a **window** dropdown to show
   one window at a time — an **inspector** (click a row → window density + footprint + member trails + pick,
   titled `cell C · site S · win W [f0–f1] · cloud N locs · M tracked (K trk) · enrich E`, which is where the
   two counts sit side by side: a site on **untracked** detections reads honestly as a large cloud count with
   `trk` = 0 — an immobile/blinking structure that never linked into a curated track, *not* a bug),
   and a **selectable member-track list**: clicking a track highlights it (cyan) on the density and enables
   **▶ Play selected track** (that one) or **▶ Play all member tracks**, both over the raw SPT movie in an
   embedded `spt_track_movie` (one colour per track, per-frame ER/mito overlay; `CSmatrix` µm-rel-centre →
   absolute µm → camera px via `PXUM`, per-point `trackId`). **🗑 Mark/unmark track for removal** flags the
   selected member track (it turns red and the flags stay pending across sites — nothing is written yet);
   **💾 Save removals (re-run)** then writes every pending flag to a SEPARATE `analysis/CS_trackedits.mat`
   (`CSexclude`, so it never clobbers `CS_footprints.mat`) and re-runs the mapper **once**, which drops them
   from membership (pickPx-guarded via `CSW.pickPx`). The density **source and auto half-max** are locked/simplified to match the Refine tab.
   **Units = µm everywhere** in `CSW`.
6. **Dwell** *(done)* — runs `cs_window_dwell.m` (headless). A dwell **event** = a maximal run of
   consecutive in-footprint localizations of one member track, **clipped to that site's own window**;
   duration = `(exitFrame − entryFrame + 1)·dt` (frame-span accounting). Primitives
   (`csInsideMask`/`runsToEvents`/`mergeIntervals`/`classifyInside`) are **lifted verbatim** into
   `cs_dwell_primitives.m`. Because each footprint is only valid in its window, residence is genuinely
   time-resolved → a **per-window escape rate `k_out(w) = nEvents/Σdwell`**. Outputs
   `analysis/cs_window_dwell.csv` (per event), `cs_window_track_labels.csv` (per site×track:
   RESIDENT/ENTERS/EXITS/ENTERS+EXITS), and `cs_window_dwell.mat` (the full `DD` struct). The tab shows the
   pooled **dwell-time histogram**, the **`k_out(window)` bar**, a per-track table, and (click a row) **two**
   linked panels: the track **animated on the contact site** and the **distance-to-centre vs frame** trace
   (dwell frames marked). The animator (timer-based) offers **▶ Play/⏸ Stop**, a **frame scrubber**, **fps**, a
   per-frame **ER/mito segmentation overlay** (green/magenta boundaries read from the seg at each track frame,
   registered via `FOVUM/segWidth`), and a **backdrop toggle: *density (accumulated)* ↔ *raw movie*** — density
   shows the site + dwell context; raw shows the actual SPT frame-by-frame (read from the movie, registered via
   `PXUM`). The contact-site outline, dwell colouring (inside frames red; head marker red while INSIDE), and
   organelle overlay draw on **either** backdrop. **🎥 Save video…** renders the animation (chosen backdrop +
   trajectory + dwell + moving organelle) to MP4/AVI (`exportgraphics`→`VideoWriter`).
7. **Compare** *(done)* — a grouped-stats layer over `CSW_final.mat` (+ `DD` for dwell metrics), on either
   **this project** or the whole **experiment** (every folder in the Experiment tab, via `cs_experiment_aggregate`).
   **Group by** {mito vs non-mito · window (time-resolved) · condition (cell)} × **metric** {dwell s · k_out /s ·
   enrichment · area µm² · n_loc · mito fraction · # sites}. Shows a grouped **mean ± sem** table, a
   **per-site scatter** with group means, a **pooled dwell-time CDF** per group, and a two-group **rank-sum p**
   when the Stats toolbox is present. **Export CSV** writes the grouped table. The Nature suite's
   Deff/JBM machinery (`CS_builder` full, `CSensemble`, `CSaverager`, tessellation, changepoints) is
   **intentionally dropped** — this integrated `TrackStruct` has no `Tracks.Deff`/`LocIndex`/`MitoCSindex`, and
   the requested scope is geometry + residence + enrichment (a per-track diffusion readout, if ever wanted,
   would reuse the app's own MSD `fitTrackD`, not the Deff path).

   Sites/Dwell/Compare all read `analysis/CSW_final.mat`, so each stage is independently re-runnable. Refinement
   is an **optional** editor (the Refine tab) whose `CS_footprints.mat` the mapper honours per site; skip it and
   the auto footprint is used. Engines validated headless (`cs_window_mapper_smoke`, `cs_window_dwell_smoke`,
   `cs_footprints_smoke` — the footprint-override roundtrip) and the tabs driven offscreen against real
   `Project/analysis` data (Load → Refine → mapper-applies-refined → Play → Dwell → Compare).

**Contact-site refinement + interaction metrics.** Refine: a **✨ Smooth boundary** control (`cs_smooth_boundary.m`
— arc-length resample + periodic moving average → a clean closed loop), strength from the *smooth boundary*
slider (default 0.35), applied **only when you click it** — repeat clicks smooth further, and the site is then
flagged `edited` with mode `…+smooth`. Smoothing is **not** automatic: a freehand trace keeps every vertex you
drew, and only its closing seam is rounded (`cs_close_boundary.m`, ±4 vertices either side of the join).
Sites: per member track the **% of its localizations inside** the site (`trackPctInside` in the mapper) with a
**≥% in filter** (dwelling vs passing-through), and the **STEP diffusion-change bridge**: `⇢ Export tracks for
STEP` writes `analysis/step/step_tracks.csv` (member trajectories + inside-CS flags); `drivers/run_step.py`
predicts pointwise D(t)/α(t) per track — via the STEP deep-learning model (`--weights <ckpt>`, needs
PyTorch + `step` lib + trained weights) or a numpy rolling-window fallback; `⇠ Import STEP D(t)`
(`cs_step_import.m`) reports each track's **D inside vs outside** the site (the motion change from interaction).
Smokes: `cs_smooth_smoke`, `cs_step_roundtrip_smoke` (export→run_step.py→import, a slowing track → Din≪Dout).

### Downstream struct (`TrackImporter_direct.m` → `Tracks`)
Per cell: `file, lengths, matrix (frame,x,y), center, rawSteps, steps, MSDdata, MSD, MSDstdev, MSDerror,
CSD, CSDnorm, rawVector, vector, intens (mean/max/total), allSpots (FRAME,X,Y[,MITODIST][,ERDIST]),
mitoDist [m×n], erDist [m×n], trackIDs, frameInterval`. `mitoDist`/`erDist` are signed µm per tracked spot;
`[]` if the CSV lacks the column. The spots CSV is paired with the **same variant as the XML being imported**
(`_spots_curated.csv` for `_tracks_curated.xml`, `_spots_filtered.csv` for `_tracks_filtered.xml`), the other
variants only as a fallback — so a curate-only folder is no longer read with no intensities and no
mito/ER distances. Build & QC then adds `Dt, confined, stateChange, diffOpts` (§7.2).

Two of these were **corrected**, and the fix moves downstream numbers — an old `.mat` build is not
comparable to a new one, so rebuild rather than mix them:
- **`CSD`** = `cumsum(dS1)`, the cumulative sum of the **actual step distance** (µm). It was
  `cumsum(dS1./dT1)` — the *per-frame speed* — which charges a gap-closed step only its per-frame average,
  and is not even in µm unless every `dT` is 1. On the WithER cell (**86.6%** of tracks contain a 2-frame
  gap) total path length ran a median **2.0% low**, up to **11.5%** per track. `steps = dS1./dT1` remains the
  per-frame speed on purpose; only `CSD` is a distance.
- **`MSDerror`** = `MSDstdev ./ sqrt(cntSD)` — that track's own spread over **its own pair count at that
  lag**. It was divided by the number of *tracks* that happen to have a finite MSD at that lag, so a track
  with 374 pairs and a track with 1 pair got the same divisor and the error bars came out a median **4×
  too small** (10× too small to 3.7× too large). **`MSD` itself was independently verified correct and is
  unchanged.**

---

## 8. Provenance

`ContactSites_original/` is the **Nature-2024 VAPB paper** code — pristine, never run or edited. The app runs
`ContactSites_robust` (a hardened refactor proven equal to it, config-driven scale factor). All new work is
additive (`drivers/`, the new apps). Upstream originals remain in `../SPT_ContactSites_Pipeline/`.
