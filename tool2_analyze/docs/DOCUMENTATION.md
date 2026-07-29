# ContactSites SPT Pipeline — Documentation

Single-particle-tracking (SPT) analysis of **ER–mitochondria contact sites** tagged by
**VAPB**, implementing the density and diffusion analysis of Obara et al., *Nature* **626**:169 (2024).
The pipeline turns TrackMate trajectories into per-cell localization-density maps, lets you pick and
refine contact sites interactively, and produces a single results structure (`CS_final.mat`) plus
per-site density-probability metrics.

This document covers the workflow, the pipeline stages, the output-folder layout, and — in detail —
the **data structures written to every `.mat` file**. Field shapes below were verified against a real
`analysis/` output; field meanings were read from the source that creates them.

---

## 1. The two apps

The single-colour and dual-colour builds are **completely separate code** and write to **separate
output roots**, so one can never disturb the other.

| | Single-colour | Dual-colour |
|---|---|---|
| Launch (in MATLAB) | `run_spt` | `run_spt_dualcolor` |
| App file | `gui/spt_pipeline_app.m` | `dualcolor/spt_pipeline_dualcolor.m` |
| Output subfolder (under the project) | `analysis/` | `analysis_dualcolor/` |
| Shared analysis engine | `ContactSites_robust/` suite (both) | same |

Each launcher scrubs the *other* build off the MATLAB path first, so both can be opened in one MATLAB
session without shadowing. **Requirements:** MATLAB R2024b, Image Processing Toolbox, Statistics &
Machine Learning Toolbox. (The Parallel Computing Toolbox is used opportunistically if installed, but
is optional — everything degrades to serial.)

> **This file documents the single-colour pipeline.** The dual-colour build adds a **Dual-colour tab
> (Tab 10)** with reconciled shared contact sites, cross-channel correlated-motion / angle-of-motion
> analysis, and stepwise-photobleaching oligomerization, plus a per-channel output layout under
> `analysis_dualcolor/`. All of that — and advice on **combining data across collection days** — is in
> the companion reference **[`DOCUMENTATION_dualcolor.md`](DOCUMENTATION_dualcolor.md)**.

---

## 2. The tab workflow

The app is organized as a left-to-right sequence of tabs; a normal run goes top to bottom.

| Tab | Name | Purpose |
|---|---|---|
| 1 | Calibration | Pixel size, FOV, frame interval, 30 nm density bin → `cs_calib.mat`. |
| 2 | Experiment | Point at the tracks/mito/ER folders; scan cells; choose which cells to run. |
| 3 | Curate tracks | Filter/curate tracks before building. |
| 4 | Build tracks | Import TrackMate XML(+CSV) → the `Tracks` struct (`TrackStruct.mat`). |
| 4b | Import QC | Overlay tracks on the structure image; click-inspect tracks. |
| 5 | Run ContactSites | Runs the staged pipeline (density → … → builder → accum). Press **Run**. |
| 6 | Contact Sites | The interactive **picker** (csid) and **refiner** open here. |
| 7 | CS Results | Browse sites, play member tracks, classify mito/non-mito, edit membership. |
| 8 | Dwell & labels | Per-track dwell-time analysis inside each site. |
| 9 | Compare | Cross-condition comparison. |

Tab 5 has an in-app documentation panel describing each stage; this file is the fuller reference.

---

## 3. Pipeline stages (Tab 5)

Run in order by `drivers/run_contactsite_analysis.m`. The two interactive stages (**csid**, **refiner**)
open in Tab 6 and block for your input, then continue automatically.

| Stage | Auto/You | What it does | Writes |
|---|---|---|---|
| `density` | auto | 30 nm-binned, Gaussian-smoothed whole-cell density map per cell | `Densities/<file>_rho.tif` |
| `locdens` | auto | Same binning saved as the picker/refiner background | `Density_<file>.tif/.mat` |
| `quickplot` | auto (opt.) | Tracks-on-structure QC images (skipped if no `MaxInt/`) | figures only |
| `csid` | **YOU** | Pick contact-site points (auto-detect + manual) on the density map | `csIDs/<base>_CSsites.txt` |
| `mapper` | auto | Crop a box around each pick; record member tracks + localizations | `TrackData/<base>_CSdata.mat`, snaps |
| `part2` | auto | Tabulate mito/non-mito counts; reassemble per-cell tracks | `CSindexing.mat`, `Tracks_final.mat` |
| `snaprename` | auto | File the mapper snaps into the canonical layout | `CSsnaps/`, fresh `CSdata/` |
| `refiner` | **YOU** | Click the refined centre + freehand-trace each boundary | `CSdata/<base>_CSdata.mat` (refined) |
| `ensemble` | auto (JBM only) | Aggregate D_eff inside vs outside sites (needs JBM Maps) | `CSoutput.xlsx/.mat` |
| `builder` | auto | Assemble **`CS_final.mat`** — the main result Tabs 7 & 8 read | `CS_final.mat` |
| `accum` | auto (opt., slow) | Excel table + ~9 QC images per site (export-only) | `CS_details.xlsx`, image folders |

**JBM vs NoJBM:** the "JBM/Deff" branch needs external tessellation `Maps/*.mat` + `AssimilateTessIndex3`.
Absent those (the usual case here) the pipeline auto-runs the **NoJBM** path: `ensemble` is skipped and the
diffusion fields (`Deff`, `TessIndex`, `refDeff`, `neighborDeff`, `segIDs`) are left empty in `CS_final.mat`.

**Speed note:** re-refining a single site stops after `builder`, so Tabs 7/8 update immediately; the slow
`accum` (image/Excel export) runs only on a full run with "Excel + reference images" ticked.

---

## 4. Output folder layout (`analysis/`)

```
analysis/
├── cs_calib.mat                         calibration (pixel size, FOV, dt, bin)
├── TrackStruct.mat                      the Tracks struct from Tab 4 (var: Tracks)
├── Tracks.mat                           working copy the suite runs on (var: Tracks)
├── Tracks_final.mat                     Tracks + MitoCSindex, after part2 (var: Tracks)
├── CSindexing.mat                       per-cell mito-CS index (var: CSinfo)
├── CS_final.mat                         ★ every contact site (var: CS) — the main result
├── Density_<cell>.mat / .tif            per-cell density image (var: imG)
├── cs_density_metrics.csv               per-site density-PMF metrics (written by the app)
├── csIDs/        <base>_CSsites.txt      your picks (mapper input)
├── Densities/    <file>_rho.tif          whole-cell density renders
├── TrackData/    <base>_Tracks.mat       per-cell Tracks (var: CellTracks)
│                 <base>_CSdata.mat       per-cell sites, RAW (6 fields)
├── CSdata/       <base>_CSdata.mat       per-cell sites, REFINED (12 fields)
├── CSdata2/, CSsnaps/                    builder / mapper intermediates
└── CS_turbo/ CS_jet/ VectorGraphics/     accum exports (per-site images) — export-only,
    DeffVisual/ TracksVisual/             the app never reads these back
```

---

## 5. Data structures in the `.mat` files

### 5.1 Conventions used throughout

- **Per-track array layout** (`Tracks`, `CS`, `CSdata`): the big arrays are `M × N × page` where
  **dim 1 (rows, M) = ordered spot index within a track** (row *k* = the *k*-th detection, frame-sorted)
  and **dim 2 (cols, N) = track index** (one column per track). `M` = the longest track in that cell;
  shorter tracks are **NaN-padded** below their real length.
- **The `matrix` pages:** `(:,:,1)` = time (integer **frame** index by default, or seconds), `(:,:,2)` = **X
  in microns**, `(:,:,3)` = **Y in microns**. Two-page fields (`vector`) are `(dX, dY)`.
- **Units matter and are not uniform:** positions are **µm**; refined boundaries are stored in **nm
  relative to `refCenter`**; density bins are **30 nm**; areas are **µm²**; time is **frames** unless a
  field says seconds. Each field below states its units.
- **Coordinate frames:** the cell's absolute frame is µm. A site's `CSmatrix` and `refboundary` are
  **centred on `refCenter`**. To get an absolute boundary: `refboundary/1000 + refCenter` (nm→µm→shift).
- **Sentinels:** `NaN` = padded/undefined; empty `[]` = a field not populated on this path (e.g. all
  `Deff` fields on the NoJBM path).

### 5.2 `Tracks` — the per-cell trajectory struct
*Files:* `TrackStruct.mat`, `Tracks.mat`, `Tracks_final.mat` (variable **`Tracks`**, `1×nCells`);
`TrackData/<base>_Tracks.mat` holds one cell as **`CellTracks`**. Built by
`drivers/TrackImporter_direct.m` from a TrackMate `_tracks.xml` (+ optional `_spots.csv`).
`M` = max track length in the cell, `N` = number of tracks.

| Field | Shape | Units | Meaning |
|---|---|---|---|
| `file` | char | — | Cell base filename (identifier). |
| `lengths` | `N×1` | count | Real (non-padded) localizations in each track. |
| `matrix` | `M×N×3` | frame, µm, µm | `(t, x, y)` per tracked spot. **Only linked/tracked spots.** NaN-padded. |
| `center` | `M×N×3` | frame, µm, µm | `matrix` minus each track's first spot (origin at track start; row 1 = 0). |
| `rawSteps` | `(M-1)×N×2` | frame, µm | Per-step `(dT = frame gap, step length)`. Step length is an unsigned magnitude. |
| `steps` | `(M-1)×N` | µm/frame | `rawSteps(:,:,2)./rawSteps(:,:,1)` = instantaneous speed. |
| `MSDdata` | `[]` | — | Legacy scratch, deliberately empty. |
| `MSD` | `(M-1)×N` | µm² | **Rows here index frame lag Δ** (not step): mean squared displacement per (lag, track). NaN where no pair. |
| `MSDerror` | `(M-1)×N` | µm² | `MSDstdev./sqrt(cntSD)` = standard error of **that track's** MSD at **that lag**, where `cntSD` is the number of displacement pairs that went into the bin. NaN where no pair. |
| `MSDstdev` | `(M-1)×N` | µm² | Std. dev. of the squared displacements in each (lag, track) bin. |
| `CSD` | `(M-1)×N` | µm | Cumulative path length in µm: `cumsum(rawSteps(:,:,2))` down rows — the sum of the **actual** step distances, so a gap-closed step contributes the whole distance covered, not a per-frame average. |
| `CSDnorm` | `(M-1)×N` | 0–1 | `CSD` normalized so each track ramps to 1.0 at its last step. |
| `rawVector` | `(M-1)×N×2` | µm | Signed per-step displacement `(dX, dY)`. |
| `vector` | `(M-1)×N×2` | µm/frame | `rawVector ./ dT` = velocity components `(dX/dT, dY/dT)`. |
| `intens` | `M×N×3` or `[]` | a.u. | Per-spot `(MEAN, MAX, TOTAL)` intensity from the CSV (`[]` if no CSV). |
| `allSpots` | struct `.FRAME/.X/.Y` | frame, µm, µm | **Flat list of EVERY detection** (tracked + untracked), not organized by track. QC context. |
| `trackIDs` | `N×1` | id | TrackMate `TRACK_ID` of each column (NaN if absent). |
| `frameInterval` | scalar | s | Seconds per frame (default 1 if absent). |
| `MitoCSindex` | `1×M` | index | *(Added by `part2`, only in `Tracks_final.mat`)* the cell's mito-associated CS indices (copy of `CSinfo.CSindex`). |

### 5.3 `CS` — the contact-site results struct
*File:* `CS_final.mat` (variable **`CS`**, `1×nSites`, one element per contact site). Built by
`CS_builder.m` (JBM) / `CS_builderNoJBM.m` (NoJBM). Below, `nTrk` = `numel(tracks)` (member tracks),
`M` = frames of the parent cell.

**Identity & geometry**

| Field | Shape | Units | Meaning |
|---|---|---|---|
| `file` | char | — | Parent cell filename (same for all sites in a cell). |
| `cellIndex` | scalar | index | Which cell (subscript into `Tracks`). |
| `csID` | scalar | id | The site's own label (per-cell site number). |
| `tracks` | `1×nTrk` | index | Member-track **column** indices into `Tracks(cellIndex).matrix(:,tracks,:)`. |
| `refCenter` | `1×2` | µm | Refined site centre `[x y]` (absolute cell frame). |
| `boundaries` | struct `.x/.y` | µm | The coarse mapper box `[min max]` in x and y (the ±window). |
| `refboundary` | `K×2` | **nm, rel. `refCenter`** | Refined boundary polygon `[x y]`. Absolute = `refboundary/1000 + refCenter`. |
| `EllipseFit` | struct | **pixels\*** / deg | `regionprops` fit: `Centroid`, `MajorAxisLength`, `MinorAxisLength` (\*upsampled density-image pixels, 1 px ≈ 3 nm), `Orientation` (deg, −90..90). |
| `MitoFlag` | scalar logical | — | `true` = mitochondria-associated site. |

**Membership & per-track data**

| Field | Shape | Units | Meaning |
|---|---|---|---|
| `CSmatrix` | `M×nTrk×3` | frame, µm, µm | `matrix` for member tracks, **re-centred on `refCenter`** (page 1 = frame unchanged, pages 2/3 = x−refCenter(1), y−refCenter(2)). |
| `CSvec` | `(M-1)×nTrk×2` | µm | Member-track step displacements `(dx, dy)` (not re-centred; differences are shift-invariant). |
| `tracksCCids` | `1×nTrk` | id | NPB/ChrisC cluster id per member track (0 = not fit / no NPB data). |
| `refLocIDs` | `P×1` | linear idx | Localizations **inside the refined boundary**, as linear indices (see index-space note). |
| `neighborIDs` | `Q×1` | linear idx | Localizations inside the outer box but **outside** the refined boundary. |
| `IDmatrixCSspec` | `M×nTrk` | {0,1,2} | Membership map: 2 = inside refined boundary, 1 = neighborhood, 0 = neither. |
| `ChPts` | `M×nTrk` | {0,1} | NPB change-point markers (all zeros on the NoJBM path). |

**Diffusion fields (JBM only — `[]` on the NoJBM path):**
`Deff` `[M×nTrk]` µm²/s, `segIDs` `[M×nTrk]` NPB segment ids, `TessIndex` `[M×nTrk]` JBM tile index,
`refDeff`/`neighborDeff` (flat lists of `Deff` inside/outside the boundary).

**Density-PMF metrics (9 fields appended by the app's `computeCSDensityMetrics`)** — all scalar,
per site, implementing the Obara PMF (30 nm bins, smoothed density = `imgaussfilt(counts,[2 2])`):

| Field | Units | Definition |
|---|---|---|
| `nLocInside` | count | Raw localizations inside the refined boundary. |
| `cellTotalLoc` | count | Total finite localizations in the whole cell (the PMF denominator). |
| `probMass` | 0–1 | **PMF over the site** = `nLocInside / cellTotalLoc`. Cross-cell comparable. |
| `peakProb` | per-bin | PMF at the densest **smoothed** bin inside = `max(rho_in)/cellTotal` (robust; sets the shared colour scale). |
| `peakProbRaw` | per-bin | Strict paper PMF peak = `max(rawCounts_in)/cellTotal` (no smoothing). |
| `areaUm2` | µm² | `polyarea` of the boundary polygon. |
| `localDens` | loc/µm² | Mean smoothed density inside the site (`mean(rho_in)/binArea`, binArea = 9e-4 µm²). |
| `cellBgDens` | loc/µm² | Whole-cell baseline (mean smoothed density over occupied bins). |
| `enrichment` | fold | **Supplementary** (not in the paper): `localDens / cellBgDens`. |

> **Index-space caveat:** `refLocIDs`/`neighborIDs` are linear indices, but the two builders use
> *different* index spaces — into the **cropped** `[M×nTrk]` member space (JBM `CS_builder`) vs the
> **full** `[M×N]` cell grid (`CS_builderNoJBM`). Check which builder produced your file before indexing.
>
> **Alignment caveat:** the Tab 7 track add/remove currently resizes `tracks/CSmatrix/CSvec/tracksCCids`
> but **not** `ChPts`/`IDmatrixCSspec`, so after editing membership those two arrays can have a stale
> column count. Impact is low (ChPts is all-zeros on the NoJBM path) and a fix is tracked separately.

### 5.4 `CSdata` — per-cell contact sites (raw + refined)
*Files:* `TrackData/<base>_CSdata.mat` (**RAW**, 6 fields, from the mapper) and
`CSdata/<base>_CSdata.mat` (**REFINED**, adds 6 fields, from `cs_refine`). Variable **`CSdata`**,
`1×nSitesInCell`. Index fields refer to that cell's `CellTracks.matrix` (`M×N×3`). `SF ≈ 0.003 µm`/display-pixel.

**RAW (from `ContactSiteMapperNoDeff`)**

| Field | Shape | Units | Meaning |
|---|---|---|---|
| `csID` | scalar | id | Per-cell 1-based site number. |
| `Tracks` | `1×K` | index | Member-track **column** indices (tracks with ≥1 localization in the mapper box). |
| `LocIDs` | `P×1` | linear idx | Localizations inside the box, as **full-grid** `[M×N]` linear indices. |
| `center` | `1×2` | µm | Coarse (auto/imported) site centre. |
| `boundaries` | struct `.x/.y` | µm | The ±150 px search box `[min max]` (≈0.9 µm wide). |
| `MitoFlag` | scalar | — | From `CSsites` col 7 (1→true, 2→false). Interactive toggle may store double 0/1. |

**REFINED (added by `cs_refine`)**

| Field | Shape | Units | Meaning |
|---|---|---|---|
| `refCenter` | `1×2` | µm | User-clicked refined centre. (`= center` for a "Use full box" site.) |
| `refboundary` | `K×2` | **nm, rel. `refCenter`** | Drawn boundary vertices. A 4-row `±2400 nm` box = an unrefined "full box". |
| `CSLocIDs` | `·×1` | linear idx | Inside-boundary localizations in the **site-local** `[M×numel(Tracks)]` space. |
| `refLocIDs` | `·×1` | linear idx | Same localizations in the **full-grid** `[M×N]` space (subset of `LocIDs`). |
| `IDmatrixMN` | `M×N` | {0,1} | Mask form of `refLocIDs` (1 inside the boundary, else 0). |
| `EllipseFit` | struct | pixels/deg | `regionprops` fit to the drawn mask (same units caveat as `CS.EllipseFit`). |

### 5.5 `CSinfo` — `CSindexing.mat`
Variable **`CSinfo`**, `1×nCells`. Written by `CStabulator`.

| Field | Shape | Units | Meaning |
|---|---|---|---|
| `cellname` | char | — | Cell base name (`<base>_CSdata.mat` minus the suffix). |
| `CSindex` | `1×M` | index | The **indices of the mito-associated sites** within that cell's `CSdata` order (value = position). Empty if none. `part2` copies this into `Tracks_final` as `MitoCSindex`. |

### 5.6 `calib` — `cs_calib.mat`
Variable **`calib`**, scalar struct. Loaded by `cs_config()`.

| Field | Units | Meaning |
|---|---|---|
| `pixSizeUm` | µm/px | SPT camera pixel size (may be NaN if FOV entered directly). |
| `nPix` | px | Image side length. |
| `fovUm` | µm | Field of view (typed, or `pixSizeUm*nPix`). Sets the density-map scale. |
| `snapFovUm` | µm | Density-image FOV (mirrors `fovUm`); sets `SF = snapFovUm/size(imG,1)`. |
| `dt_s` | s | Frame interval (sets D_eff scaling). |
| `binNm` | nm | Density histogram bin size (default 30). |
| `source` | — | `'unified-app'` or `'manual/panel'`. |
| `savedFrom` | — | Analysis-directory path (provenance). |

### 5.7 `imG` — `Density_<cell>.mat` / `.tif`
Variable **`imG`**, a single 2-D density image (`≈921×921` for a 27.61 µm FOV at 30 nm bins), the
smoothed localization-count map used as the picker/refiner background. The `.tif` is the same image.

---

## 6. Export artifacts (from `accum`)

**`cs_density_metrics.csv`** (written by the app, not `accum`) — one row per site, columns:
`csID, cellIndex, file, mito, n_loc_inside, cell_total_loc, prob_mass, peak_prob, peak_prob_raw,
area_um2, local_density_per_um2, cell_baseline_density_per_um2, enrichment` — the same 9 metrics as §5.3.

**`CS_details.xlsx`** (`accum`) — one row per site, columns:
`CS #, Cell Index, csID, # tracks, # NPB tracks, # segIDs, MajorAx, MinorAx, Angle, #ChPts, MeanDeff,
n, NeighborhoodDeff, n neighborhood, MitoFlag`. (Deff/NPB columns are 0/empty on the NoJBM path.)

**Per-site images:** `CS_turbo/`, `CS_jet/` (density PNGs), `VectorGraphics/` (tracks/vectors/boundary/
ellipse SVGs), `DeffVisual/`, `TracksVisual/` (overlay PNGs) — one set per site, for figures/records only.

---

## 7. Working with `CS_final.mat` in MATLAB

```matlab
L = load('analysis/CS_final.mat');  CS = L.CS;          % 1×nSites struct array
k = 11;                                                  % a site

% Absolute refined boundary (µm):
bx = CS(k).refboundary(:,1)/1000 + CS(k).refCenter(1);
by = CS(k).refboundary(:,2)/1000 + CS(k).refCenter(2);

% Member track j's absolute (x,y) over time (CSmatrix is centred on refCenter):
j  = 1;
xt = CS(k).CSmatrix(:,j,2) + CS(k).refCenter(1);
yt = CS(k).CSmatrix(:,j,3) + CS(k).refCenter(2);
fr = CS(k).CSmatrix(:,j,1);                              % frame index

% The paper PMF and supplementary enrichment for this site:
lbl = "non-mito"; if CS(k).MitoFlag, lbl = "mito"; end
fprintf('prob_mass=%.3g  peak_prob=%.3g  enrichment=%.2f  (%s)\n', ...
    CS(k).probMass, CS(k).peakProb, CS(k).enrichment, lbl);

% Fraction of a member track's localizations inside the site (the Tab-7 metric):
in  = inpolygon(xt, yt, bx, by);
fprintf('track %d: %d/%d inside (%.0f%%)\n', j, nnz(in), nnz(isfinite(xt)), 100*mean(in(isfinite(xt))));
```

---

## 8. Working across collection days

The pipeline is **per-project**: one project directory → one `analysis/` folder → one `cs_calib.mat`.
Data collected on different days can be handled two ways. Your track filenames already carry the date in
the prefix (`250408_FFAT_001_spt1` → cell prefix `250408_FFAT_001`, from the `_spt\d+` strip), so
**provenance is built in** — the only real hazards are **mixing incompatible calibrations** and losing
track of **which condition/day** a row came from. Both are easy to avoid.

### 8.1 Which layout to use

| | **One project per day** (recommended default) | **One combined project** |
|---|---|---|
| When | Any time; required if calibration differs across days | Only if **every** day used identical calibration |
| Structure | `.../2026-07-15/analysis/`, `.../2026-07-18/analysis/`, … | one `tracks/` folder with all days' files, one `analysis/` |
| Calibration | each day its own `cs_calib.mat` (isolated) | one `cs_calib.mat` for all |
| Picking/refining | per day (QC each day on its own first) | all cells in one sitting |
| Combine | pool the per-day CSVs (§8.3) | already pooled; slice by date/condition |

Per-day projects are the safer default — each day keeps its own calibration and can be QC'd in isolation
before it ever enters a pooled table. Reach for one combined project only for a small, uniform, final set.

### 8.2 Two things to keep consistent

- **Calibration must match** for days you intend to pool: `pixSizeUm`, `fovUm`, `dt_s`, and the 30 nm bin
  (§5.6). Different acquisition settings make density/diffusion scales non-comparable — keep such a day
  separate and note it. `cs_calib.mat` records `savedFrom` (the analysis-dir path) for provenance.
- **Keep the date in the prefix** and, ideally, a condition too, so nothing collides and every result is
  traceable: `YYYYMMDD_<condition>_<cellNN>_spt<k>_tracks.xml` (e.g. `20260715_ctrl_cell03_spt1_tracks.xml`),
  with the mito/ER images on the same prefix (`{prefix}_mito_mip.tif`, `{prefix}_er_mip.tif`). `YYYYMMDD`
  sorts unambiguously; the app's `_spt\d+` strip turns it into the cell prefix automatically. On the
  Experiment tab, **assign a condition** to each cell and **Save manifest** — that is what the **Compare
  tab (Tab 9)** groups by.

### 8.3 Combine at the export level (not the raw level)

Every project writes flat, cross-comparable tables — pool **those**, adding `day`/`condition` columns:

- **`analysis/cs_density_metrics.csv`** — one row per site (`prob_mass`, `peak_prob`, `enrichment`,
  `area_um2`, …; §6). Its `file` column already identifies the cell, but add an explicit `day` column so
  grouping is obvious.
- **Dwell (Tab 8)** and **Compare (Tab 9)** exports — per-track / per-condition tables.

Use the ready-made pooler **`drivers/pool_projects.m`** — it reads the CSV(s), parses the collection **day**,
**condition**, and **cell number** from each row's `file` prefix (e.g. `250408_FFAT_001_spt1` → day
`2025-04-08`, condition `FFAT`, cell `1`), concatenates, writes a combined CSV, and prints a per-day QC
summary. It works whether your data is in **one combined project** or **one project per day**:

```matlab
% one combined project (all days in one folder) -> label its single CSV by day + save:
T = pool_projects('Project', 'Out','Project/combined_metrics.csv');

% several per-day projects under one parent (each with its own analysis/):
T = pool_projects('AllDays');

% or an explicit list of analysis dirs:
T = pool_projects({'2025-04-08/analysis','2025-04-11/analysis'});

% pool a different pipeline CSV instead (e.g. a dwell export):
T = pool_projects('Project', 'Metrics','dwell_metrics.csv');

% then sanity-check day-to-day reproducibility BEFORE pooling across days:
groupsummary(T, {'day','condition'}, {'median','numel'}, 'prob_mass')
```

(If you prefer to roll your own, the core is one `readtable` per source + a `day` column + `vertcat`.)

Treat `day` as a **batch/replicate factor**: confirm the days agree (medians, counts) before pooling, and
keep `day` in every plot/test so a batch effect can't hide. That is exactly how Tab 9 (Compare) treats a
condition — a grouping variable kept explicit.

### 8.4 The confusions this avoids

- **Filename collisions** (same `cell03` on two days overwriting each other) — the date prefix prevents it.
- **Silently pooling incompatible calibration** — one `cs_calib.mat` per project makes the boundary explicit;
  only pool days whose calibration matches.
- **Losing provenance** — the date is in the filename and in `cs_calib.savedFrom`, and a `day` column carries
  it into the pooled table.

*(Dual-colour has the same structure with per-channel outputs and per-day reconciliation — see
[`DOCUMENTATION_dualcolor.md`](DOCUMENTATION_dualcolor.md) §8.)*

---

## 9. Cross-references

- Stage source: `ContactSites_robust/` (`DensityVisualization`, `ContactSiteMapperNoDeff`,
  `CS_builderNoJBM`, `CStabulator`/`CellAccumulator`, `ConditionAccumulatorFinalnoJBM`, …),
  interactive stages in `drivers/cs_identify.m` and `drivers/cs_refine.m`, orchestration in
  `drivers/run_contactsite_analysis.m`.
- Importer: `drivers/TrackImporter_direct.m`, `drivers/build_trackstruct.m`.
- Density-PMF metrics: `computeCSDensityMetrics` / `csDensMetricOne` in `gui/spt_pipeline_app.m`.
- In-app stage help: Tab 5 panel (`gui/cs_pipeline_doc.html`).
