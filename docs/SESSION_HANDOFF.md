# SPTinMatlab — Session Handoff

**Status:** everything below is **verified present in source** and the **full smoke suite passes — 19/19**.
MATLAB apps do **not** hot-reload — **close and relaunch** `run_track` (Tool 1) and
`run_curate` / `run_analyze` (Tools 2 & 3) to see any of this.

**Tools:** `run_track` → `tool1_track/spt_app.m` · `run_curate` → `spt_analyze_app('curate')` ·
`run_analyze` → `spt_analyze_app('analyze')`. Tools 2 and 3 are the **same app**
(`tool2_analyze/app/spt_analyze_app.m`) in two modes. `tool2_analyze/app/spt_pipeline_app.m` is the
legacy one-window app and is **not** what `run_*` launches.

## Quick re-verification

```bash
# full suite — 19 *_smoke.m across tool1_track/, tool2_analyze/app/, tool2_analyze/drivers/
cd /Users/safal-mac/Desktop/IntegratedPipeline/SPTinMatlab
/Applications/MATLAB_R2024b.app/bin/matlab -batch "
addpath(genpath(pwd));
t = dir('**/*_smoke.m'); t = t(~contains({t.folder},'ContactSites_original'));
nf = 0;
for k = 1:numel(t)
    [~,n] = fileparts(t(k).name);
    try, feval(n); fprintf('PASS %s\n',n);
    catch ME, nf = nf+1; fprintf(2,'FAIL %s : %s\n',n,ME.message); end
    close all force;
end
fprintf('%d/%d passed\n', numel(t)-nf, numel(t)); exit(nf>0);"
```
There is **no runner file checked in** — the loop above is the runner. It must find **19** tests
(6 in `tool1_track/`, 2 in `tool2_analyze/app/`, 11 in `tool2_analyze/drivers/`); a lower count means
`genpath` missed a folder, not that a test was deleted.

```bash
# marker greps — any 0 means the change was reverted/lost
grep -c "spt_on_er"              tool1_track/spt_track.m                      # 1
grep -c "geo_bridge"             tool1_track/spt_track.m                      # 2
grep -cF "C(:) = Inf"            tool1_track/spt_link_cost_geo.m              # 1
grep -c "nDetsOffEr"             tool1_track/spt_process_cell.m               # 1
grep -cF "cumsum(dS1, 1)"        tool2_analyze/drivers/TrackImporter_direct.m # 1
grep -cF "MSDstdev ./ sqrt(cntSD)" tool2_analyze/drivers/TrackImporter_direct.m # 1
grep -c  "active_trackstruct.txt" tool2_analyze/app/spt_analyze_app.m         # 2
grep -cF "'Tracks',buildTracks"  tool2_analyze/app/spt_analyze_app.m          # 1
```

---

## What changed this session (most important first)

### 1. Strict ER-geodesic linking is COMPLETE (Tool 1)
The rule is now enforced **by construction**, not by the cost function alone: in `'geodesic'` mode a
detection that is not on **its own frame's** ER can never reach a track by any route.
- **`spt_track.m`** — signature `[tracks, info] = spt_track(...)`,
  `info = struct(mode, nFramesNoErMask, nDets, nDetsOffEr)`. Before the LAP it **pre-filters
  `dets{t}`** through `spt_on_er(dets{t}(:,1:2), supD{t})`, so an off-ER detection is unavailable to
  frame linking, chain assembly **and** gap closing. A frame whose mask is missing *or present but
  all-false* keeps **nothing** (fail closed), is counted in `nFramesNoErMask`, and raises
  `warning('spt_track:noErMask',…)`. Geodesic no longer routes through `spt_link_cost` at all.
- **Gap closing takes `mode`.** Geodesic requires the bridge to be reachable **along the ER**
  (`geo_bridge` → `spt_link_cost_geo(pEnd, pStart, G, sE, 0, sS)`; `Inf` or a missing mask = refuse).
  `'penalty'` keeps its old soft ">50 % off-ER straight line" veto **unchanged**.
- **`spt_link_cost_geo.m`** — `(P, Q, R, supP, lambda, supQ)`, `supQ` defaults to `supP`. The target
  is tested against **its own frame's** support (the ER moves between frames); an empty `supP` *or*
  `supQ` sets the whole matrix to `Inf`. `lambda` is unused in strict mode, kept for signature parity.
- **New helpers** — `spt_er_support.m` (the *single* definition: `imdilate(logical(sup),strel('disk',1))`,
  1 px registration slack, `[]` in → `[]` out = *forbid*), `spt_on_er.m` (out-of-image and empty mask
  both → `false`), `spt_seg_fg_label.m` (now `warning('spt_seg_fg_label:uniformStack',…)` on a
  single-valued stack, where an ER-aware mode would otherwise silently stop constraining anything).
- **Provenance** — `spt_process_cell.m` downgrades an ER mode with no segmentation to `'euclid'`
  **once, explicitly**, and carries `linkMode` / `linkModeReq` / `nFramesNoErMask` / `nDetsOffEr`.
  `<base>_settings.txt` gains `tracking.link_mode_req` (**only** when downgraded) and, in geodesic
  mode, `tracking.frames_no_er_mask` + `tracking.dets_off_er`.
- *Verify:* `spt_geo_strict_smoke` (27 assertions); Tool 1 → ER-geodesic → Run → `_settings.txt`
  reports the strict counters.

### 2. CSD and MSDerror were WRONG in `TrackImporter_direct.m` — both fixed
Both are per-track fields of every built `TrackStruct`. **Existing builds carry the old values and
need a rebuild.**
- **CSD** is now `cumsum(dS1, 1)` — the cumulative sum of the **actual step distance** in µm. It was
  `cumsum(dS1./dT1)`, a per-*frame* speed, so a gap-closed step was charged only its per-frame
  average. Measured on the WithER cell: **86.6 % of tracks contain a 2-frame gap**; total path length
  ran a **median 2.0 % low, up to 11.5 %** per track. Consumers read this field as µm.
- **MSDerror** is now `MSDstdev ./ sqrt(cntSD)` — this track's own spread over **its own pair count**
  at that lag. It was divided by `sum(isfinite(MSD),2)`, the **number of tracks** with a finite MSD at
  that lag, so a track with 374 pairs and one with 1 pair got the same divisor. Error bars came out a
  **median 4× too small** (10× too small … 3.7× too large).
- **MSD itself was independently verified CORRECT** and is unchanged — a brute-force per-track pair
  loop over 5,501 (lag, track) values agrees to **8.9e-16**. It is time-averaged over all pairs and
  binned by **integer frame lag**, so gaps are handled.
- *Verify:* the two `grep -cF` markers above; `docs/DATA_STRUCTURE.md` § *Correctness notes*.

### 3. Named builds + a single active-build resolver
- **Build & QC has a `Name` field** (`eTsName`, default `TrackStruct`). A build writes
  `analysis/<name>.mat` and records the basename in `analysis/active_trackstruct.txt`. Loading a
  build **adopts** its name rather than copying it over `TrackStruct.mat`, so several builds coexist
  (`Day1_WT.mat`, `Day1_KO.mat`) and the one you loaded is the one in force. No pointer means
  `TrackStruct.mat` — every pre-naming project keeps working, nothing to migrate.
- **`drivers/cs_active_trackstruct.m`** (NEW) is the **single** resolver:
  pointer → `TrackStruct.mat` → legacy `Tracks.mat` → any other `.mat` in the folder that actually
  contains a `Tracks` variable (`whos -file`, with a skip list for `cs_calib.mat` etc.).
- **Everything downstream resolves through it** — `spt_analyze_app` (`activeTsName`),
  `cs_window_picker`, `cs_window_mapper`, `cs_footprints_build`, `cs_refine`, `cs_experiment_scan`
  and `cs_experiment_status` (the Experiment "built" lamp). Before the audit these all hard-coded
  `TrackStruct.mat`, so a named build looked fine in Build & QC and then dead-ended: Sites and Refine
  asserted, the experiment scan enumerated zero cells while its lamp said "built", `setProject` kept
  the **previous** project's active name, and the confine-D spinner re-saved to a shadow file.
- **`Tracks.mat` is LEGACY.** Only `spt_pipeline_app` / `pipeline_gui` call
  `run_contactsite_analysis`, which is what writes it, so it never appears in the
  `run_curate` / `run_analyze` flow. The fallback exists only to keep those older paths alive.
- *Verify:* `spt_named_build_smoke`; Build & QC → Name `Day1_KO` → Build → `analysis/Day1_KO.mat` +
  `active_trackstruct.txt`; relaunch `run_analyze` → it opens that build.

### 4. "Compare methods" is now three side-by-side videos (Tool 1, `spt_compare_app.m`)
The 3×3 static grid (max projection + time-coloured candidate rings + all three methods' markers
stacked) is gone. One example at a time now plays as **three synchronized players**, one per method,
sharing a crop, a frame and a ±N-frame window (default 10 → 22 frames), over the **real** frames.
Each panel draws only **its own** method's tracks; the focus track is bright in the method colour,
everything else is thin grey context, and a dotted segment marks a gap-closed jump. A divergence
strip under each panel fills where that method's chain exists, ticks where the three disagree, and
seeks on click. The example list is ranked by how much the three chains **actually differ over the
window**, and a selected example opens paused at the **first diverging frame**.
Two measured facts drove this: ER-penalty's focus chain is identical to Euclidean's in **~75 %** of
examples, and ER-geodesic has **no chain at all in ~57 %** (strict linking excluded the spot) — the
difference is usually an **absence**, which one overlaid picture cannot show. Both cases are labelled
in the panel title. **Save video…** writes the window as MPEG-4 (AVI fallback) of all three players.
The summary panel no longer claims "(~equal)" linked detections: it reports how many detections
geodesic **excludes** and states that ER-penalty excludes none.
- *Verify:* `spt_compare_smoke` (drives the UI headlessly, asserts the panels differ per method,
  exercises seek/play/backdrop, checks the exported MP4 frame count).

### 5. Three new QC panels in Build & QC
The pre-existing panels (track length, ER/mito distance, D distribution, MSD, fit-window sweep) are
**unchanged**. Added, all in `drawQC` / `onTrackPick` in `spt_analyze_app.m`:
- **`axDloc`** — pooled **per-localization** stepwise D histogram; title carries median, % confined
  and n.
- **`axDtrace`** — stepwise **D(t)** for the clicked track, mobile vs confined points coloured,
  state-changes counted in the title.
- **`axCSD`** — cumulative path length per track (every track faint, median bold); clicking a track
  highlights its curve (`csdHi`).
Guards found in the audit: `drawQC` threw `Unrecognized field name "confined"` and blanked the whole
tab for a struct with `Dt` but no `confined`/`stateChange` (reachable via `combine_trackstructs` or a
pre-diffusion build); the D(t) axis was `dt`× too small for a `TimeUnit='seconds'` build (there
`matrix(:,:,1)` is already seconds); the CSD median was survivorship-biased, so it is drawn only
while ≥5 tracks **and** ≥10 % contribute and the title says how far.

### 6. Tool 3 no longer loads the same TrackStruct twice
`cs_window_picker` accepts an already-loaded struct via `opts.Tracks` and only falls back to disk when
used standalone (then: caller's `opts.tsFile` → the folder's active build). It never writes
`st.Tracks`, so the hand-off shares under copy-on-write instead of putting a **second full copy** of
the project's tracks in RAM — **70 MB per cell** today, scaling with cells per folder. This is
*Stage 0* of `docs/DATA_STRUCTURE.md`, now done.

---

## ⚠ Caution for test authors — `save()` follows symlinks

The previous handoff asserted "`WithER/` was **not modified** by any test (writes went to symlinked
temp dirs)". **That was false this session.** `spt_named_build_smoke` built its temp project by
symlinking WithER's **directories**; setting a project runs `onCalAuto → writeCalib`, which saves
`cs_calib.mat` into `tracks/`, and that write **followed the directory symlink into
`WithER/tracks/cs_calib.mat`** (rewritten three times, 2026-07-28 23:43). The content was
byte-identical to the untouched `analysis/cs_calib.mat`, so **no data was lost** — but the pristine
reference folder was written to.

Fixed: the test now symlinks **individual files** into real directories and **skips `.mat` entirely**,
since `save()` follows a symlink. Verified by mtime before/after: WithER untouched.

**Rule going forward:** never symlink a directory the app may write into, and never symlink a filename
the app may `save()` over. Only inputs the app strictly reads (`.tif/.tiff/.xml/.csv/.txt`) are safe
to link.

---

## Open items

1. **Leaked timer at MATLAB shutdown.** After `spt_named_build_smoke` prints its PASSED banner,
   `-batch` prints `Invalid or deleted object` / `timer/timercb`. **Cosmetic — exit code is 0** and
   the test passes. The **owner is not yet identified**; the candidate timers are
   `spt_analyze_app.m:1587` (Dwell player), `spt_app.m:417`, `spt_compare_app.m:545`,
   `spt_track_movie.m:207`, `spt_pipeline_app.m:2583`. Fix = stop/delete the timer in the figure's
   `CloseRequestFcn`/`DeleteFcn` once the owner is confirmed.
2. **Data-structure staging** — `docs/DATA_STRUCTURE.md` plans Stages 0–4. **Stage 0 is done**
   (item 6 above). Stage 1 (one file per cell + `cells_index.mat`) is the one that matters at scale:
   200 cells goes from ~14 GB resident to ~70 MB × cells-held, with `nF`, field names and shapes
   untouched so no consumer breaks. Stages 2–4 are only worth it past what the manifest workflow
   keeps cells-per-folder at, and Stage 4 must not be attempted without version-stamping `nF` and
   migrating every stored linear index in `CSdata/`, `TrackData/` and `CSW_final.mat`.
3. **Rebuild existing `TrackStruct.mat` files** — they carry the old (wrong) CSD and MSDerror.
4. **`train_step.py` kit** (real STEP) — no pretrained weights exist; STEP must be trained on
   simulated AnDi trajectories. Local blocker: the only py3.10 here is x86_64/Rosetta (no MPS) →
   train on arm64+MPS or Colab. Then `run_step.py --weights step_D.pt` upgrades D with no code change.
5. **Unravelling VAPB trajectories on the ER network** — `docs/IDEA_unravelling.md`. **Idea only,
   deliberately not started.** Sun et al. PRResearch 4, 023182 (2022): network confinement makes
   Brownian motion look subdiffusive, so raw MSD both underestimates D and depresses α. Their MATLAB
   code is public and their segmentation route is identical to ours. Measured blocker: our `er_seg`
   skeletonises to a median edge length of 0.43 µm at 60% area coverage (theirs: 1.2 µm, sparse), so
   the `Δt ≲ 0.1ℓ²/D` validity condition fails at 50 Hz — a segmentation/region-selection problem,
   not a frame-rate one. Read that doc before touching this; it also flags that Tool 3's
   "Confined (low D)" channel may partly be flagging ER geometry rather than binding.

## Open design questions (user's call — current behaviour noted)

1. **Should gap closing bridge an ER-segmentation hole in strict mode?** *Currently: no* — the bridge
   must be reachable **along** the ER, so a frame where the segmentation drops out breaks the track.
2. **Should a track tolerate *k* consecutive off-ER frames instead of terminating?** *Currently: no
   tolerance* — one off-ER detection ends the track. A small *k* would trade strictness for length.
3. **Should the 1 px dilation be a GUI parameter?** *Currently: hard-coded* in `spt_er_support.m`. It
   ought to be tied to the **measured** SPT/ER channel offset, since it sets exactly how far outside
   the segmented ER a detection may sit and still count as on it.

## Key data facts (WithER test cell, `250408_WT_012`)

- Movie 256×256, **5981 frames**; PXUM ≈ 0.10785 µm/px; dt 0.02006 s.
- **220,401 detections → 101,948 tracked (46 %)**; ~17 tracked locs/frame; flat rate (no bleaching).
- Built `TrackStruct`: 838 tracks, nF 381, 73,994 localizations; 11.9 MB on disk, **70.7 MB in RAM**,
  23.2 % occupancy, `load()` 51 ms.
- Per-track D median 0.76 µm²/s; per-loc 10.6 % confined (≤0.15), 1,815 state-changes.
  *(Carried over from the previous handoff, measured before this session's CSD/MSDerror fix — D and
  the state-change counts do not depend on either field, but re-measure if you cite them.)*

### Link-mode comparison — frames 1–300 ONLY
> A **300-frame slice**, not the 5981-frame movie above; these counts are *not* comparable to the
> 220,401 / 101,948 whole-movie figures. Params: 11,535 detections, link 0.8 µm, gap 1.4 µm,
> maxGap 1, λ 3, Top 6 %.

| mode | tracks | linked | % linked | medLen | maxLen |
|---|---|---|---|---|---|
| euclid | 560 | 11,111 | 96.3 % | 8.5 | 300 |
| penalty | 617 | 11,108 | 96.3 % | 7 | 300 |
| geodesic | 644 | 10,361 | 89.8 % | 7 | 246 |

The strict pre-filter excluded **653 of 11,535 detections (5.7 %)** as off their **own** frame's ER.
Frames with no ER mask: **0**. Surviving the export default Min-track-length 50: euclid 56,
penalty 49, geodesic 37.

## Standing constraints

- **Never edit or run `ContactSites_original/`** (pristine Nature-2024 reference).
- **Never write into `/Users/safal-mac/Desktop/IntegratedPipeline/WithER`** — see the symlink caution
  above. Headless drives use a temp project of per-file symlinks; verify with mtime before/after.
- MATLAB apps do not hot-reload: relaunch after any source edit.
