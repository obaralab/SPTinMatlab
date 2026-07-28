# Code Review — single- & dual-colour SPT ContactSites apps

Multi-agent review (6 finders × adversarial verification). **24 findings, all confirmed** in the actual
code (0 refuted): **6 high · 11 medium · 7 low**. Each verifier re-read the cited code and defaulted to
"refuted" unless it could reproduce the issue. Line numbers are from the review pass and may drift by a few
lines as the files change.

Legend — 🅢 single (`gui/spt_pipeline_app.m`) · 🅓 dual (`dualcolor/spt_pipeline_dualcolor.m`) ·
🅱 both · 🅕 drivers/suite.

## Fix status (applied 2026-07-18)

**Fixed & verified (17 of 24)** — all correctness / data-integrity / parity / driver issues:
`H1 H2 H3 H4 H5 · M1 M2 M3 M4/M5 M6 M7 M9 M10 · L1 L2 L6`. Both apps lint 0-error; the numeric
changes were checked on real data (M4/M5 bbox exact 6269==6269; M6 imfinfo 921×921; frame-mode MSD
unchanged; dwell channel filters mirror `computeDwell`/`buildDwellSel`).

**Deferred (7 of 24), with reason:**
- **H6, L5, "138 identical functions"** (dedup) — conflicts with the deliberate single/dual *separation*.
  If desired, extract only pure, uniquely-named helpers into the already-shared `ContactSites_robust/`
  suite (does not re-couple the app files). Left as-is by design.
- **M8, L3, L4** (per-playback-frame draw-handle caching) — recommended, but they need live-GUI
  verification to rule out a rendering regression, which can't be done headless. Deferred.
- **L7** (`IncludeFiles` gates only interactive stages) — documented here; the pipeline's `CS_final.mat`
  always spans every cell with a `csIDs/` pick, not just the session subset.

---

## HIGH

### H1 · Track Add/Remove/Undo leaves dwell, density metrics, and Compare stale 🅱 · data-integrity
`refreshCSafterTrackEdit` rebuilds `csMemDens` and clears `dwellData`, but after a membership edit it
**never** recomputes `csData.dwell(k)`, **never** re-runs `computeCSDensityMetrics`, and **never** clears
`cmpData`. Consequences after add/remove/undo of a track:
- CS Results table still shows the pre-edit **dwell (col 6), p (col 7), enrich (col 8)**; the site title shows old dwell; the probability colour scale uses a stale `probScaleMax`.
- `saveCSfinal` writes the **new membership together with the OLD embedded density fields** (`probMass/peakProb/nLocInside/areaUm2`) to `CS_final.mat`, and `cs_density_metrics.csv` is stale.
- The **Compare tab** (recomputes only when `cmpData` is empty) reports pre-edit stats.
All self-heal only on a full `loadCSresults`.
**Fix:** in `refreshCSafterTrackEdit`, set `csData.dwell(k)=computeCSdwell(...)`, call
`computeCSDensityMetrics()`, and add `cmpData=[]`; order `saveCSfinal` *after* the metric recompute.

### H2 · `onCStrkAdd` can desync `CSvec` from `tracks`/`CSmatrix` 🅢 · data-integrity
Add grows `tracks`, `CSmatrix`, `tracksCCids` **unconditionally** but appends `CSvec` only under
`isfield(Tr,'vector') && ~isempty(Tr(ci).vector)`. If a site has non-empty `CSvec` but the cell's
`Tr(ci).vector` is missing, `CSvec` ends one column short — a silent per-track-array desync (distinct from
the filed ChPts/IDmatrixCSspec issue), and `saveCSfinal` only warns then writes it anyway.
*(Verifier note: the code inconsistency is certain; a reload path that produces the exact triggering state
wasn't proven, so treat as high-but-conditional.)*
**Fix:** validate `CSvec` availability *before* mutating (like the existing `CSmatrix` row-count pre-check),
or append a NaN column so all per-track arrays stay length-aligned.

### H3 · Dwell "Trace grid" mixes both channels on one column index → NaN index / wrong track 🅓 · correctness
`dwellTraceGrid` selects events by `[ev.cellIndex]==ci & [ev.trackCol]==col` **without a channel filter**,
but analysis- and other-channel `trackCol` share the index space. Other-channel events store `csCol=NaN`, so
when an other-channel track wins `max([evT.dwell])`, `CS(k).CSmatrix(:,NaN,1)` throws and aborts the whole
Trace-grid figure (no try/catch). Even when it doesn't throw, it can plot the wrong physical track with the
wrong `dt`.
**Fix:** filter by the row's channel (`atRows{r,13}`) like `buildDwellSel` does; for other-channel rows build
the trace from `TrOther(oj).matrix` and use `dtOther`.

### H4 · Compare "by condition" merges cross-channel intervals with the wrong `dt` 🅓 · data-integrity
The per-cell dwell aggregation loops `for c=unique(evCol(evCell==ci))` with no channel filter, so one `c`
selects **both** a ch1 track and an unrelated ch2 track; `mergeIntervals` merges two physically-different
tracks and converts all spans with the analysis `dt` even for other-channel frames sampled at `dtOther`.
Triggers on essentially every dual cell → the primary cross-condition dwell statistics are silently wrong.
**Fix:** separate by channel like `computeDwell` (`strcmp({ev.chan},chn)` + `chDt` per channel).

### H5 · Dual whole-cell panel lost its mito-flag boundary colouring 🅓 · consistency-drift
Single `drawCSallPanel` colours each non-selected boundary by `MitoFlag` (magenta = mito, white = non-mito)
and titles it with the selected site's status + "(magenta boundary = mito)". Dual draws **every** boundary
white and uses the old generic title — `MitoFlag` exists and is toggled in dual, only the visualization
drifted. A dual user can't tell mito vs non-mito sites at a glance.
**Fix:** port the single block (per-site `mflag` → `bcol/lw`, and the title with `selMito`).

### H6 · `track_viewer.m` duplicated as two ~1550-line files 🅱 · consistency-drift *(see separation note)*
`gui/track_viewer.m` (1551 lines) and `dualcolor/track_viewer.m` (1577) are near-identical; the dual copy is a
**strict, backward-compatible superset** (only adds an optional 5th `otherFcn` arg, a no-op when `nargin<5`).
Any curation fix must be applied to both or they drift.
**Fix (with caveat):** could collapse to one canonical file — but this **conflicts with the deliberate
single/dual separation** (see the note at the bottom). Safer path: keep both but add a drift-check to CI, or
factor the shared body into a uniquely-named helper on the shared suite path.

---

## MEDIUM

### M1 · `onCSDelete` clears `dwellData` but not `cmpData` 🅢 · consistency-drift
After deleting a site + reload, Compare still includes the deleted site until manually recomputed.
**Fix:** add `cmpData=[]` next to `dwellData=[]`. *(Same cache-invalidation family as H1.)*

### M2 · `onCSToggleMito` doesn't invalidate `dwellData`/`cmpData` 🅢 · consistency-drift
Reclassifying mito/non-mito updates the flag + table but leaves the Dwell per-row label and the entire
Compare "mito vs non-mito" grouping on the pre-toggle classification.
**Fix:** clear `dwellData=[]; cmpData=[]` after flipping the flag.

### M3 · Degenerate/0-refined CS filter present in dual `loadCSresults`, missing in single 🅢 · correctness
Dual drops placeholder sites (empty `cellIndex`) right after load; single doesn't, so a 0-refined run's blank
record survives and can crash/mis-size downstream indexing — the exact case the dual filter was written for.
The robustness fix landed in only one build. **Fix:** mirror the dual `keep=arrayfun(...)` filter + message.

### M4/M5 · Dual `computeCSDensityMetrics` lacks the bbox pre-filter (and parfor path) 🅓 · efficiency
Single extracted `csDensMetricOne` with an exact bounding-box pre-filter before the per-site `inpolygon`;
dual still runs `inpolygon` over **all** cell localizations per site (O(nSites × nLocInCell)) on every reload
and re-refine. Numerically identical, purely slower. **Fix:** share `csDensMetricOne` / add the `inbb`
pre-filter to dual.

### M6 · `loadCSresults` eagerly decodes every cell's `rho.tif`, uses one cell's dimensions 🅱 · efficiency
`rhoMap(ci)=loadtiff(...)` decodes every contact-site cell's multi-MB density TIFF, but the only consumer
(`refreshScale`) reads `size()` of **one** cell's raster. Every reload blocks the UI on dozens of discarded
decodes. **Fix:** `imfinfo` (header only) on `CS(1)`'s rho path, or lazy-load a single raster.

### M7 · `csTouchingCols` recomputed every playback frame 🅱 · efficiency
`drawCS` (12.5 fps timer) calls `csTouchingCols(k)` each frame, but its `inpolygon`-over-all-box-members
result depends only on `k` + boundary, not the frame. **Fix:** cache per selection alongside `csMemDens`.

### M8 · `drawCS` "all spots" branch: one `plot()` per detection + full-column rescans per frame 🅱 · efficiency
With `chkCSspots` on, each frame does a full-column `find` per member and one graphics object per in-view
spot. **Fix:** precompute a frame→(x,y) lookup per selection; draw near/far spots with two batched `plot`s.

### M9 · MitoOnly refine writes `_mito_CSdata.mat`; builder/ensemble read `_CSdata.mat` → silent empty result 🅕 · data-integrity
In `MitoOnly` mode `cs_refine` saves `<base>_mito_CSdata.mat`, but `CS_builder[NoJBM]` looks up
`<base>_CSdata.mat`; after `snaprename` the folder holds only `_mito_` files, so every cell is skipped with a
warning and `CS_final.mat` ends up **empty** with no hard error. **Fix:** make builder/ensemble MitoOnly-aware,
or have `cs_refine` write the canonical name; at minimum add a loud precondition.

### M10 · TrackImporter `TimeUnit='seconds'` silently yields all-NaN MSD 🅕 · correctness
In seconds mode `matrix(:,:,1)=FRAME*frameInterval`, so the MSD validity mask `df==round(df)` never passes →
`MSD/MSDstdev/MSDerror` all NaN, no error. **Fix:** bin MSD by integer frame gap regardless of `TimeUnit`, or
error/warn when `useFrame` is false.

---

## LOW

- **L1 · dt collision in `computeDwell` 🅓** — if the two channel file-tags collapse to the same token, dwell uses the wrong `dt` and merges channels. Default tags (ch24/ch3) are distinct. **Fix:** assert `anaTag≠othTag`, fall back to `ch1/ch2` keys.
- **L2 · Dual `refreshCSafterTrackEdit` eagerly rebuilds whole-cell density (then again) 🅓 · efficiency** — dual added an eager `buildLocalDensity(k, 1:nTracks)` after the invalidation but doesn't set `csWholeDensK`, so `drawCS` rebuilds it again; runs even when the overlay is off. Single is lazy. **Fix:** delete the eager line (match single) or set `csWholeDensK=k`.
- **L3 · `drawCSoverlay` rebuilds an identical cropped mito RGBA every frame 🅱 · efficiency** — cache the CData/AlphaData per selection.
- **L4 · `drawDwellFrame` re-renders static traces/patches every frame 🅱 · efficiency** — draw static layers once, update only the moving marker + `xline`.
- **L5 · Five pure top-level helpers duplicated; `csDensMetricOne` single-only 🅱 · simplification** — `fitTif/firstXml/padcat_cols/fitDeff/lblRow` are byte-identical in both apps (see separation note).
- **L6 · `cs_refine` uses `cs_config()` (pwd-dependent) vs `cs_identify`'s `cs_config(analysisDir)` 🅕** — a standalone `cs_refine` (or any refactor that stops `cd`-ing into `workDir`) silently uses default calibration. **Fix (one line):** `cfg = cs_config(analysisDir);`.
- **L7 · `IncludeFiles` session subset gates only the interactive stages 🅕 · data-integrity** — `mapper/part2/builder` aggregate **every** cell on disk, so a subset session still folds outside cells into `CS_final.mat`. **Fix:** thread `IncludeFiles` through, or document the behaviour.

---

## Note on the single/dual duplication (H6, M4/M5, L5, and finding "138 identical functions")

The review repeatedly (and correctly) flags that ~1900 lines are byte-identical across the two apps, and
recommends extracting shared modules. **This is in direct tension with the deliberate decision to keep the
two builds physically separate** ("two distinct places … don't mess up the single-colour analysis"), which
exists to prevent function-shadowing and cross-contamination.

A reconciling path that honours both: the shared **suite** (`ContactSites_robust/`) is already on both apps'
paths. Genuinely pure, GUI-free helpers (`fitDeff`, `padcat_cols`, `computeCSdwell`, `runsToEvents`,
`mergeIntervals`, `densToRGB`, `csDensMetricOne`, the Compare-tab compute) can live there under **unique
names** — shared, but *not* re-coupling the two app files or risking a shadow. The rest of the duplication is
the accepted cost of isolation; a periodic drift-review (like this one) is the mitigation.

## What is most worth fixing first

1. **H1 + M1 + M2** (one cache-invalidation family): make membership/mito/delete edits recompute dwell + density metrics and clear `cmpData` — stops silent stale results and stale `CS_final.mat`. *(Both apps.)*
2. **H3 + H4** (dual dwell channel bugs): a crash and corrupted Compare stats in the normal dual case.
3. **M3 + H5** (parity gaps I introduced): port the degenerate-CS guard and the mito-flag boundary colouring to close the single↔dual drift.
4. **H2, M4/M5, L2, L6** — cheap hardening/perf with clear one-spot fixes.
