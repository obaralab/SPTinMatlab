# SPT–ContactSites pipeline — full reference

Single-particle tracking of **VAPB** (an ER membrane protein) and its **ER–mitochondria contact sites**,
in MATLAB, as three tools that hand off through files. This document is the reference of record for the
**code, inputs/outputs, folder organization, and algorithms**. Kept up to date as the pipeline is built.

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
through `cs_active_trackstruct` (§7.2), never by a hardcoded filename: density → contact-site picker →
mapper → dwell → compare. A shared **Experiment** tab (`spt_experiment_panel`) is **tab 1 in all three
tools** — the multi-folder / per-condition manifest (day, condition, exclude, notes, derived tracked/curated/built/
picked/mapped/dwelled status and the per-stage spot/track counts behind it) that ties the dataset together and
drives Tool 3's cross-condition Compare. It lives with the project as `<project>/experiment_details.mat`.

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
│   ├── spt_dog.m spt_detect.m spt_ridge.m spt_pool_quality.m spt_count_per_frame.m  detection
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
    │                                    'analyze' → Tool 3: Experiment · Contact sites · Refine · Sites · Dwell · Engagement · Compare
    │                                    'full'    → Experiment then both sets in one window
    ├── app/spt_curate_app.m           Tool 2 launcher (thin wrapper: spt_analyze_app('curate'))
    ├── app/spt_experiment_panel.m     SHARED Experiment tab embedded by all three tools
    ├── app/track_viewer.m             embedded Import&Curate tool
    ├── drivers/                       the analysis layer (TrackImporter_direct, build_trackstruct, cs_*,
    │                                    cs_config + ChrisPrograms, and
    │                                    cs_experiment_scan/status/aggregate for the Experiment manifest)
    └── docs/                          design notes
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
├── experiment_details.mat     the shared Experiment tab's manifest (day/condition/exclude/notes)
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

## 2b. Where analysis output goes

`analysis/` was flat, and a 93-cell plate put 186 density files in it around the handful anyone
opens. `cs_ana_path.m` decides the layout in one place:

```
analysis/
  <build>.mat, active_trackstruct.txt, cs_calib.mat   the spine — unchanged
  density/     Density_<base>.mat/.tif, Density_<base>_CSwindows.mat
  Densities/   <base>_rho.tif        unchanged: the advisor's pipeline expects this name
  exports/     the CSVs you take to Prism
  examples/    examples_*.mat        (engagement subsets)
  curation/    track_exclusions.csv
```

The spine stays at the root because every tool looks for it by name and moving it would break
existing projects for no gain. **Nothing is migrated**: `cs_ana_path(anaDir,'find',name)` checks the
new home then the root, so an old project keeps working untouched. A reader that only looked in the
new folder would report "no windows" for a project picked before the move — which reads as *nothing
was picked*, not as *the file moved*.

**Why density files appear on a project nobody ran density on.** `Densities/<base>_rho.tif` is
required — its row count sets `SF` for the mapper — so opening the Contact-sites tab bootstraps it
for every cell when that folder is empty, regardless of the checkbox. The *extra*
`Density_<base>.mat`/`.tif` are a drop-in for the advisor's external ContactSites code and **nothing
in this pipeline reads them** (there is no `cs_identify` here). They used to be written in the same
bootstrap, so a first open produced 279 files where 93 were needed. They now follow the checkbox,
and the status line says which of the two is happening.

### The picker's support channel, and what it is called

A project can **declare** an ER channel and have an empty `er_seg/`. `supportKey` is then still
`'er'`, so `werMask` falls through to `cs_support_mask` — a mask derived from where molecules were
actually seen — while the overlay box read **ER** and the method read **ER Monte-Carlo**. The
analysis was right (that fallback is the correct one, and far better than `true(size(...))`), but
the labels claimed a segmentation that does not exist and the green contour on the density map
looked like ER. `refreshSupportLabels` renames them to **support\*** and **Support Monte-Carlo**
once the derived path is taken — decided from `st.supportWhy`, not from `supportKey`, because
`supportKey` is non-empty in exactly the case that matters. Regression: `cs_picker_support_smoke`,
which also asserts a project WITH ER is left alone.

**And no outline is drawn for it.** `werMask` always returns a mask — a detection domain may not be
empty — so the derived support's contour was being drawn in the support channel's colour, which on a
project with no ER reads as ER. The draw loop now skips the support channel whenever `supportWhy` is
set, and the checkbox is unticked and **disabled** (not removed, so "where did ER go?" is answered on
the control). The guard is in the DRAW path, not only the checkbox, because `werMask` would happily
supply a contour the moment anything re-ticked the box. `cs_picker_support_smoke` (6) forces the box
on and asserts no line is added — with the guard removed it draws 21.

**Detection defaults to LOCAL BACKGROUND on every project, with or without a support segmentation.**
All three methods use the support as the detection *domain*; what differs is the null. `ermc`
scatters points inside the support and takes a cutoff from that — sound against a real ER mask, and
close to circular against one derived from the very localizations being judged, since the null
region is already shaped by the clustering it is meant to test. `local` compares each peak with its
own large-scale neighbourhood (σ=40) and does not depend on the support's shape at all, so a faint
site next to a bright one is judged on its own surroundings.

This began as a no-support-only fallback: a project with a real ER mask still defaulted to the MC,
on the reasoning that that is the case the MC was built for. That is true of the *method* and was
not a reason to make it the *default*. Local is now the default everywhere; the MC stays
**selectable** and keeps its p-values — the derived null is weak, not meaningless. Choosing it on a
project whose support is derived from the localizations says so on the status line, and choosing it
on a project with a real segmentation says nothing, because there the null is sound.
`cs_picker_support_smoke` asserts both halves of that.

**"It is clearly above background — why is it not a site?"** has five possible answers and the
picker used to give none of them. A spot passes only if it is (1) inside the support mask, (2) above
the method's threshold, (3) part of a patch of at least `minArea` pixels, (4) over `min enrich` and
`min locs/site`, and (5) over `min tracks`. **Gate 3 is the one that surprises**: a peak can be far
above background and still be dropped for being spatially CONFINED, because too few pixels clear the
threshold. `cs_detect_explain_smoke` plants a spot at **1.8x the threshold with only 13 px above it**
against a `minArea` of 20 — rejected, and recovered by lowering `minArea` to 1.

**explain spot now names the failing gate**, read off `cs_detect`'s own intermediates (its 5th
output `dbg`: `bwThr`, `bwOpen`, `L`, `dthr`, `bgMed`, `minArea`) rather than from a second copy of
the chain — an explanation derived independently is how it comes to disagree with the detection it
claims to explain.

**THREE localization counts are on screen and they answer different questions.** All three count the
same TRACKED localizations (the density is built from the matrix, not the cloud), but over different
regions:

| where | region counted |
|---|---|
| `explain spot` | within `contact µm` of **where you clicked** — a disc |
| a site's `loc` column | inside that site's **thresholded footprint** — usually smaller |
| the `＋locs` overlay | **every** localization in the window |

They were easy to read as contradicting each other, and the overlay made it worse: it drew at 2 px
and **alpha 0.15**, tuned for a crowded window, so a site holding 145 localizations rendered as a
handful of faint specks and looked like ten. Size and opacity now scale with the count (9 px / 0.85
under 2 000 points, down to the old 2 px / 0.15 over 20 000), the >60 000 subsample says so on the
plot instead of silently thinning, and `explain spot` names the radius it counted within.

**Per-site gates.** `min tracks` (distinct molecules) and `min locs/site` both gate detection in
`cs_detect`. The second was plumbed all the way through as `minSiteLocs` and applied at
`cs_detect.m:79`, but had **no control**, so it sat at 0 forever — a gate nobody could reach. It is
distinct from `min locs/win`, which is a per-WINDOW floor for the low-count warning and gates
nothing.

**The picker is not offered cells the Experiment tab excluded.** They are dropped from the Tracks
it receives rather than greyed out in its dropdown, because it also has *Detect all*, which would
otherwise pick sites in a cell marked not-to-analyse — and those sites flow on to the mapper and to
Dwell.

## 3. Calibration (per-CELL — cameras differ, and so do cells)

Calibration is resolved **per cell**, not per dataset. Cells in one comparison are routinely acquired on
different rigs at different frame rates — the advisor's paper used a different camera (FOV 20.48 µm) than
the current rig (FOV 27.61 µm) — so a single pair of numbers applied to every cell mis-scales every µm
coordinate and every diffusion coefficient for the cells it does not describe.

Each cell's values are resolved by **`spt_project_calib(projectDir, base [, useManifest])`**,
most-trustworthy source first:

| rank | source | label |
|---|---|---|
| **0** | **your edit**, read back out of `<project>/experiment_details.mat` | `edited` |
| 1 | `tracks/<base>_settings.txt` — what Tool 1 actually tracked with | `settings` |
| 2 | the movie TIFF's own metadata, and the **only** source for the image dimensions | `movie` |
| 3 | the tracks XML `frameInterval` (dt only) | `xml` |

It returns `NaN` rather than a guess. Values are stored on the cell's record in the **experiment
manifest** (`experiment_details.mat`), shown in every tool's Experiment tab as `µm/px` · `dt (s)` ·
`calib`, and **editable there** — a typed value is marked `edited`, is locked, and is not overwritten by
a later Rescan or by Tool 1's resolver on the next run.

**Rank 0 is the fix for a silent disagreement.** The manifest stored the correction and the resolver
never read it, so the Experiment tab showed the edited value while the top bar, the build and every
downstream stage went on using the fallback, with nothing on screen to say the two disagreed. A
correction that is displayed but not applied is worse than none: it is a wrong number wearing the
user's authority. Only values the panel marked **locked** are taken — a hand edit sets that and nothing
else does, which is what stops Tool 1's own stamp-back (`setCalib` with `lock=false`) from outranking
the file it was read from and making the ranking circular.

`useManifest=false` is passed by `cs_experiment_scan`, which *fills* the manifest: it must report what
the filesystem currently says, and the panel then re-applies the edit on top of the rescan. Reading the
manifest there would make an edit its own evidence and no rescan could show what the files contain.

**The edit propagates**, per `spt_calib_ui_smoke`: the top bar updates live (edited fields tinted green,
tooltip naming them as yours) via the panel's `onChange`; `analysis/cs_calib.mat` is rewritten so
`cs_config` carries it downstream; and the `Calib` struct sent to `build_trackstruct` gains an
`edited` field listing which keys were typed, so `TrackImporter_direct/cell_calib` ranks them above the
cell's own TIFF tags and above the XML's `frameInterval`. Tool 1's `cellCalib` already ranked a
hand-edited value first at run time. Regressions: `spt_calib_edit_smoke` (the resolver — rank, that it
bites, lock-only, per-field, no scan loop, project scoping, dimensions) and `spt_calib_ui_smoke` (the
wiring, offscreen).

**Bulk assignment.** The panel's calibration row applies one `µm/px` / `dt` to the **selected rows**
or to **every row the filter is showing** (the button names the count). A 0 in either field leaves
that field alone, so `dt` can be set across a plate without disturbing a measured pixel size. Applied
values are `edited` + locked, identical to typing one in. The scope is never inferred from an empty
selection — that would make "nothing selected" mean "all 93 cells" — and overwriting a value that was
*measured* from a cell's own files asks for confirmation first, since that is the only case where the
operation destroys evidence. One `notifyChange` per batch, not per cell: each one saves the manifest
and re-resolves the host's calibration. Regression: `spt_calib_bulk_smoke` (scope by filter, scope by
selection, edited+locked, blank-leaves-alone, one save, and that the resolver then answers with the
applied value).

Two latent bugs surfaced while testing it, both pre-existing: `filterRows` called a `tern()` helper
the file never defined, so **every keystroke in the Experiment tab's filter box threw** and the box
did nothing; and a `shownRows` accessor written as `@() rowMap(:)'` captured `rowMap` by value at
construction — the same gotcha `getCells` carries a note about — so it had to be nested.

**The curate overlay is sized the same way.** `track_viewer` draws the raw movie and the ER/mito
masks across `Overlay FOV (um)`, and used to size it from the movie's **own TIFF tags only**. A movie
with no metadata returns NaN, the assignment was skipped, and the spinner silently kept its shipped
default of **27.61 µm** — the old rig's field of view — while the tracks stayed in µm at the
project's real scale. The image is then drawn at the wrong width and slides further off the tracks
the further you get from the origin: on a 256 px movie at 0.097 µm/px the tracks span 24.735 µm and
the frame was drawn across 27.61, **12 % too wide**. It afflicts the no-metadata case only, which is
why it looks file-specific. The host now passes `opts.pixUmFcn` (a live handle, so a corrected
calibration reaches the overlay without re-embedding the tab) and the order is **movie tags →
project pixel size → leave alone**, with the source named in the overlay status line and an
unsupported width tinted amber. Regression: `spt_overlay_fov_smoke`, which asserts the broken state
first so the fix cannot pass for an unrelated reason.

**Tool 3 has the same exposure one layer down, and it is fixed at the source.** Tool 3 reads no
movie metadata at draw time — it draws the raw frame at `(rawW-1)*Tracks(k).calib.pixSizeUm` and the
organelle mask across `Tracks(k).calib.fovUm`, both stamped once at build. `cell_calib` resolved that
pixel size from the cell's own **image metadata**, then the panel, then `0.10785`, and **never read
`tracks/<base>_settings.txt`** — Tool 1's record of what it actually tracked with. The two disagree
exactly when a user overrode the pixel size in Tool 1, which is the whole workflow for a movie with
no usable metadata: the `X_um` in the XML are at the override, and the build stamped the tag the user
rejected. `cell_calib` now ranks `_settings.txt` **above the cell's own image** (below only a hand
edit), for the same reason `spt_project_calib` does — nothing may contradict what produced the
coordinates without making them wrong. `calib.fovUm` is no longer resolved independently either: it
is derived as `(width-1) x` whichever pixel size won, so a cell can no longer carry 27.61 µm beside
0.097 µm/px. Regression: `spt_tool3_scale_smoke`.

The dwell-tab organelle overlay also stepped the mask by `fov/W` and placed 1-based column `c` at
`c*ux`; both are now `fov/(W-1)` and `(c-1)*ux`, matching the `X_um = (0-based col) * pixUm`
convention the tracks use. That was a **one-camera-pixel** shift (~0.1 µm) against contact sites
0.1-0.5 µm across. Display only — ER/mito distances come from Tool 1's CSV and never went through
this path, which is precisely why the drawn mask could disagree with the numbers beside it.

**Image dimensions** (`.width`/`.height`, from the movie via `spt_tiff_calib`) come back with the
calibration and are shown on the Tools 2/3 top bar beside the FOV as e.g. `256×200 px`. The FOV is
**never read** from anywhere — it is always `(width-1) x pixUm`, recomputed from whichever pixel size
won, so an edited pixel size moves it and the two cannot disagree on screen. A bare FOV is
unfalsifiable; the dimensions beside it make the arithmetic checkable at a glance.

A cell that can resolve nothing falls back to the **panel** value. That fallback is never silent: it is
named in the run log, recorded in that cell's `_settings.txt` as `calibration.pixel_um_src = panel`, and
shown as `panel ⚠` in the manifest table.

Tool 2 and Tool 3 additionally read **`cs_calib.mat`** (a `calib` struct) via **`cs_config.m`** for the
project-level fields Tool 1 does not record (field of view, localization precision, density bin);
defaults apply when absent.

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

### 4.2 Detect (`spt_dog.m`, `spt_detect.m`, `spt_ridge.m`, `spt_pool_quality.m`)
Difference-of-Gaussians on a background high-pass, scaled by the **spot diameter (µm)**; 5×5 non-max
suppression + subpixel centroid. Per-spot **quality = the DoG response at the peak**. Two threshold modes
(Detect-tab dropdown): **Top %** — keep the top X% of pooled candidate qualities, adapting per cell
(default **6%**); or **Quality ≥** — a fixed absolute DoG-quality gate applied to every cell (directly
comparable across cells). Both resolve to `spt_detect`'s 4th arg `thrAbs`. Detection runs on **every frame**
(all 5981 frames of the WithER cell) and yields the full localization set. **Provenance:** each cell's
`_settings.txt` records `threshold_mode`, `top_percent`, `quality_min`, and the resolved `thr_abs`; a
project-level `tracks/detection_summary.csv` keeps **one upserted row per cell** so every cell's threshold
is visible at a glance (`spt_write_settings.m`, `spt_append_detection_summary.m`).

All of the following are **collapsed behind one disclosure** on the Detect tab (`▸ interleaved acquisition &
bleedthrough options`) and every one defaults to off/auto: a project whose SPT, ER and mito stacks have equal
frame counts needs none of them and sees detection exactly as before. The row auto-opens for a cell whose
organelle stack has a different frame count, or whose movie tests as interleaved, naming the reason — and
never auto-collapses once any option is set.

**Interleaved-stack guard** (`spt_interleave_check.m`). A two-colour acquisition saved as ONE stack with
the channels alternating page by page detects as a chain of spurious spots along every organelle, silently.
Structural test: in an interleaved stack `corr(f_t, f_t+2) > corr(f_t, f_t+1)` (same channel two pages
apart), in an ordinary movie the reverse. Measured on three real cells: interleaved `delta = +0.279/+0.259/
+0.268`, their own de-interleaved exports `-0.108/-0.099/-0.088` — separated by ~0.35, cut at +0.02. Warns
on the Detect tab when a cell is picked and at run time (`spt_process_cell:interleavedStack`). **The remedy
is the de-interleaved stack, not a filter.** Related: `_spt1` and `_spt12` both strip to the same cell key
under the `_spt\d*` suffix, so `spt_match` now warns (`spt_match:duplicateKey`) when two stacks claim one
cell. Regression: `spt_bleedthrough_smoke` parts (D).

**De-interleaving** (`frameStride`/`frameOffset`, Detect-tab **de-interleave**, default **off**). When the
acquisition keeps ONE stack with both channels alternating page by page, this selects one channel's pages
(`odd` = 1,3,5…, `even` = 2,4,6…) and **renumbers them as consecutive frames** — leaving page numbers in
place would read as a one-frame gap between every pair and forbid every link at maxGap 1. Detection, the
quality tuner, the preview and the frame slider all honour it. **`dtS` is multiplied by the stride** (and which interval was supplied is verified against the stack's own
ImageJ metadata — an interleaved file records half its de-interleaved export, 0.01003212 vs 0.02006423 s on
the real data, so a frame interval typed in by mistake is detected and NOT doubled again;
`spt_process_cell:dtAlreadyPerFrame` / `:dtDisagrees`):
calibration times *pages*, and the real interval between the frames you kept is twice that; every D, MSD,
dwell-second and k_out downstream reads `dtS`. Verified on a real cell against a separate single-channel
export of the same acquisition: **bit-for-bit identical** (400 frames, 31 613 detections, 3 344 tracks),
versus **411 tracks** for the same stack un-de-interleaved. Regression: `spt_bleedthrough_smoke` part (E).

**Threshold pooling** (`thrFrames`, Detect-tab **thr from**, default `all`). Top % percentiles the pooled
candidate qualities; bleedthrough floods that pool, so contaminated frames RAISE the threshold and suppress
real detections on the clean frames too — by a cell-specific amount. Three cells: pooled-over-all threshold
25.1/32.0/36.6 giving 16.8/35.4/47.6 clean dets/frame (2.8x spread between cells); pooled over the clean
parity 6.7/7.4/16.7 giving 82.7/63.7/65.1 (1.3x). Most of the apparent cell-to-cell variation was the
threshold moving with contamination. Point `thrFrames` at the clean parity, or use `Quality >=`.

**Alignment rejection** (`spt_skel_align.m`, Detect-tab **align °**, default 0 = off). **Recommended off for
comparative work**: its bite depends on organelle MORPHOLOGY, not contamination — 19%/8%/5% across three
cells of one condition, inversely with mito density (denser network -> more junctions -> ill-defined local
direction). If morphology differs by condition that is a condition-dependent detection bias. The curvature
test does not share this: its cut tracks contamination (48/24/17% against excesses of 84/56/37%) with a flat
2-5% cost on the clean channel. The curvature ratio is
orientation-blind, leaving bleedthrough that is mildly elongated and smeared ALONG a mitochondrion. Requires
all three: within 4 px of the organelle skeleton, elongation >= 1.5, and major axis within `align °` of the
local skeleton direction. Measured: of 1716 survivors of R=2, 426 were elongated and on the skeleton, at a
median 14 deg from it (78% inside 30; random would be 45 deg / 33%). At 30 deg the contaminated channel went
56.0 -> 45.6 dets/frame, the clean channel unchanged at 15.4. **Cost, scored against the clean channel as
ground truth: 5 genuine detections against 425 artefacts — 99% artefact, 1.4% of real molecules** — and that
1.4% falls on molecules sitting on mitochondria, biasing mito enrichment slightly downward.

**Two particle channels, one contaminated.** An interleaved stack may hold TWO particle channels (ch1/ch3
in successive 10 ms slots) where only one is acquired alongside the organelle exposure and picks up its
bleedthrough. De-interleaving then DISCARDS HALF THE REAL DATA — keep every frame and set `bleedFrames` to
the contaminated parity. Measured on such a cell (top 10%): gate off, ch1 16.6 dets/frame vs ch3 106.7
(6.4x); at R=2, 15.8 vs 55.6 (3.5x) — half the excess removed for a 5% cost on the clean channel; at R=1.5,
2.2x but 19% of ch1 gone. The width test added nothing (ridge-shaped leak). The clean parity is the control:
both image the same molecules, so its rate is what an uncontaminated frame looks like.

**Wrong-parity guard.** The segmentation is derived from the organelle pages, so de-interleaving onto THOSE
pages compares the organelle against a mask drawn from itself and everything reads as colocalised. Measured
on a real cell: correct parity 23% of detections in-mask (mask covers 11% of the field) = **2.0x enriched**,
the real signal; wrong parity **67% in-mask = 6.0x** — triple, self-consistent, and it looks like a result.
`spt_process_cell:trackingOrganelleChannel` fires on the run and the Detect status turns red. Note the
earlier "this stack is interleaved" warning fires only when the stride is UNSET, which is not when this
happens — the two guards cover different mistakes.

**Parity attribution from the organelle mask.** Given a segmentation, `spt_interleave_check` also reports
mean IMAGE intensity inside the mask vs outside, per parity, and names which parity is the organelle
channel (measured 1.66/1.43/1.37x vs 1.03-1.05x on three real cells). It reports which parity CARRIES organelle
signal, not which parity IS the organelle channel: additive bleedthrough onto a real particle frame lifts
the same number, so the two cases are indistinguishable by intensity and the message gives both readings. Same number is the crosstalk check on the channel kept, written as
`detection.mito_intensity_enrich`. **The mask attributes the channel and never filters detections** — a
molecule ON a mitochondrion is the measurement; and applying the shape/size gates only inside the mask
would bias enrichment and mito fraction downward, since that is exactly where the biology is. Intensity
rather than detection counts, because a detection-based enrichment *is* the readout and cannot judge itself.

**Ridge rejection** (`spt_ridge.m`, Detect-tab **Reject ridges**, default **0 = off**), for GENUINE crosstalk
— organelle emission leaking into an otherwise single-channel frame, not alternating pages. A DoG finds blobs;
an extended structure bleeding through from another channel is a **ridge**, and local-max detection strings a
chain of spot-sized detections along its crest. They are as bright as real molecules, so no threshold
separates them. Curvature does: `r = trace(H)²/det(H)` at the peak — SIFT's edge-response elimination
(Lowe 2004 §4.1) — is 4 at a round peak and grows without bound as the response becomes ridge-like; the
control is the largest eigenvalue ratio to accept (`2` is a sensible start). Saddles (`det ≤ 0`) go too.
The step is **1 px and must stay there**: enlarging it scales `tr` by `h²` and `det` by `h⁴`, so `r` is
invariant (measured 4.001 vs 4.001 at scale 1, 4.000 vs 4.000 at scales 2–3) — the ratio is size-blind by
construction. **Size** lives in a second test (`sizeMax`, Detect-tab **max width ×**, default 0 = off): the
Hessian-implied peak width `√(c/|λ_min|)` is proportional to the spot scale for a real point source (1.53 /
3.06 / 4.58 px at scales 1/2/3), while the same filament gave 6.16 / 9.07 / 11.03 and never dipped below
3.12 / 5.29 / 8.92 — so the cut is a multiple of the expected width and `1.6` sits inside the gap at every
scale. The two are **not redundant**: shape catches the crest, size catches the ends, crossings and focal
blobs that are round enough to pass a curvature ratio. A **bleedFrames** setting (`all`/`odd`/`even`,
1-based) applies both only to the contaminated parity of an interleaved acquisition.
It runs **before** NMS, so a filament peak cannot suppress a real molecule and then be discarded itself,
and `spt_pool_quality` applies the same gate so the percentile threshold is not set by candidates that are
about to be thrown away. **Shape-only by design** — a molecule *on* a mitochondrion is still a point source
and survives; rejecting by the mito mask instead would delete the contact-site colocalisation the pipeline
exists to measure. It is a large reduction in spurious hits, **not** a complete filter: focal blobs, filament
ends and crossings are genuinely round at the spot scale. Regression: `spt_bleedthrough_smoke`.

**Interleaved acquisition** (`segEvery`, Detect-tab **SPT frames / organelle**, default **auto**). An
organelle channel imaged at half the SPT rate has half the pages. Indexing both stacks with the same frame
number did not misalign a few frames — it left **every frame past the last organelle page** with no mask at
all: `NaN` mito/ER distance and an empty link support, which strict ER-geodesic reads as "forbid every
link". SPT frame *t* now reads organelle page `ceil(t/segEvery)`; `auto` takes the ratio from the page
counts only when it is a clean integer. A frame past the end keeps its `NaN` and is **counted**
(`nFramesNoSegPage`, `frames.no_organelle_page`, plus a run-time warning) rather than clamped to the last
page, which would hand it a mask that is not its own. It is an index map — no TIFF pages are duplicated. **Detection only**: every VIEWER (Tool 1's track player,
Tool 2's curate overlay, Tool 3's picker and Sites/Dwell overlays) still reads the organelle stack
page-for-page and expects matching lengths — pre-duplicate the organelle frames if you want the overlays to
follow (Fiji script in the README).

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
`tracking.lambda`, `calibration.pixel_um`, `calibration.pixel_um_src`, `calibration.frame_s`,
`calibration.frame_s_src` (the `_src` lines name where **this cell's** calibration came from —
`settings`|`movie`|`xml`|`edited`|`panel`; `panel` means nothing in the cell supplied one and the value
is the app's fallback, and the value line says `FALLBACK` too), `result.n_spots`, `result.n_tracks`,
`result.have_er`, `result.have_mito`. In **geodesic** mode two more lines record what the strict rule
excluded: `tracking.frames_no_er_mask`, `tracking.dets_off_er` (§6.2).
**Tool 2 reads the tracking lines to populate its curate params.**

### `detection_summary.csv` — project-level detection + tracking log (one row per cell)
Header, in order (`spt_append_detection_summary.m`):
```
cell, threshold_mode, top_percent, quality_min, thr_abs, diameter_um,
link_mode, link_um, max_gap_um, max_gap_frames, lambda,
n_spots, n_tracks, run_time, pixel_um, frame_s, calib_src
```
`pixel_um` / `frame_s` / `calib_src` are **this cell's own** calibration and where it came from — this is
the one file where every cell's scale is visible side by side. Rows written before these columns existed
are padded with `NA` when the file is rewritten.
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

New tab app `spt_analyze_app.m`; built on the `drivers/` layer. Build order:

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

   **Gap-closed steps.** Tool 1's linker closes gaps (**Max gap (fr)**, routinely 1), so one step can span
   two frame intervals: its squared displacement is `4·D·(2·dt)`, and dividing by `4·dt` credits a two-frame
   journey to one frame — D comes out **double** for that step. Both modes now weight each step by the frames
   it actually spans. `lag1` already did; `'msdfit'` did **not** — it lagged over **localizations** while
   fitting against `4·k·dt`, the same error by a different route, reading ~16 % high on tracks with 25 % of
   localizations dropped. It now bins by **frame** lag. A build also carries a per-track **gap census** —
   **`gapSteps`** (steps spanning >1 frame), **`maxGapFr`** (largest span), **`nSteps`** — so a run can be
   checked rather than trusted. Regression: `spt_gap_diffusion_smoke`, two-sided (an over-correcting
   estimator fails too) and carrying its own proof: it reproduces the old localization-lagged fit alongside
   the new one, so the fix is shown to bite rather than asserted.

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
   - **Detection** (`cs_detect.m`): **Local background** (default; threshold is `k ×` a σ=40 px blur of
     the density at *that pixel*, `k = 1 + 4·sens`, so a faint site beside a bright one is judged on its
     own surroundings and nothing depends on the support's global shape — no p-value), **ER Monte-Carlo**
     (null scatters the on-ER localizations **uniformly inside the ER footprint** — no intensity weight,
     binary seg — so only peaks above ER-confined density survive; α=0.01 → ~1–25 sites/window vs the old
     ~208; the only method with a false-positive rate, but it needs a REAL support: against a support
     derived from the localizations it is judging the null is close to circular), **Relative** (a fraction
     of the window's brightest pixel — no background in it at all, so one bright site raises the bar for
     every other site in that window).
     `sens` is the cutoff control for all three and means something different in each — the picker
     relabels it **cutoff α** / **cutoff ×peak** / **cutoff ×local** to say which. It is the ER-MC
     family-wise **α** (false-positive rate per window; the cutoff is the
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
   Dwell has a **≥% in** spinner (`cs_window_dwell` opt `minPctInside`, default 0 = every member):
   keep only member tracks with at least that % of their window localizations inside the footprint —
   the mapper's own `trackPctInside`, i.e. molecules that DWELL rather than pass through. It is a
   selection on the measured quantity (it can only raise mean dwell and lower `k_out`, since it removes
   the short visits), so the threshold is stored as `DD.minPctInside`, echoed in the Dwell status line
   and appended to Compare's. A site left with no qualifying track reports `k_out`/mean dwell as **NaN**,
   not 0 — no events is no rate, and a rate of zero would read as "never leaves". Regression:
   `cs_window_dwell_smoke` part C.

7. **Engagement** *(done)* — `cs_mito_engage.m` (headless), a **diffusion-contrast** readout: are molecules
   SLOWED where they meet the organelle, and does a compound abolish that? Every step is labelled by
   **where it started** — BOUND if that localization is within `d` of the organelle, FREE otherwise — and
   `D` is pooled separately over the two classes, giving `Dratio = D_bound / D_free`. Below 1 is engagement;
   1 is no contrast. Classifying by the START of a step and not by both endpoints is the whole correctness
   argument: requiring both ends inside the zone conditions on the step being SHORT (a long step starting in
   a narrow zone leaves it), which is selection on the very quantity being measured — on an **untethered**
   synthetic cell with one uniform D that gave `Dratio` 0.66, a strong false hit produced entirely by the
   geometry. Start-only gives ~1. Its cost is dilution toward 1, never a false positive, so the readout is
   conservative in the direction a hit call needs.
   The ratio is measured **within** each cell, so labelling density, expression level and how much organelle
   a cell contains — the three things most likely to differ between wells for reasons that are not the
   compound — cancel. An absolute occupancy count is at the mercy of all three, and especially so when the
   compound itself changes organelle morphology.
   Estimator: `D = (Σr² − 4σ²n) / (4Στ)` with `τ = (frame span) × dt`, pooled over steps rather than averaged
   per step, so **gap-closed steps are handled by construction** — a step spanning two frames carries
   `τ = 2·dt`, and crediting it to one interval would inflate D by two. Not built on `T.Dt`, which is a rolling
   estimate over ~7 localizations and so mixes both sides of the boundary this metric exists to resolve.
   Controls: **precision nm** (the noise floor; entered in nm, converted to µm), **min steps** per class, a
   **distance scan** (N distances between the two bounds → one row per cell per distance, and one line per
   condition on the scan plot). A cell that cannot meet `min steps` in either class shows a **dash and its
   reason**, never a number computed from a handful of steps. **Export CSV** writes
   `analysis/cs_engagement_<key>.csv` — one row per cell × distance with `D_bound, D_free, D_ratio, n_bound,
   n_free, n_crossing, occupancy, condition` — so a compound can be scored from the file without re-running.
   `n_crossing` (steps that left the zone, counted where they started) is what sets the dilution: a large
   share means much of the bound pool is molecules on their way out.

   **The examples export keeps whole TRACKS, not the localizations inside the zone.** A track
   qualifies on one step starting inside and is then exported in full, so most of its localizations
   can be far away — on the user's plate at d = 0.15 µm all 3194 exported tracks have a closest
   approach within 0.15, only **35 %** of their localizations are, and only **6 %** of tracks are
   entirely inside. That is deliberate: the point of an example is to see how a molecule arrives,
   dwells and leaves, which a clipped trajectory cannot show. It does mean Tool 2 shows plenty of
   distance above the threshold. Note there are three different criteria in play and they answer
   different questions: the D ratio classifies STEPS by where they start, the examples export keeps
   a TRACK on one qualifying step, and the QC's `near mito ≤` filter cuts on a track's MEDIAN
   distance.

   **The QC distance filter offers two statistics per channel.** `(median)` keeps tracks whose
   MEDIAN signed distance is under the threshold — more than half the track sits there, so one
   excursion neither includes nor excludes it: **residents**. `(closest)` keeps any track whose
   nearest approach is under it: **visitors** too. They are not interchangeable — on the user's
   plate at d = 0.15 µm the median rule keeps 953 of 7611 tracks (13 %) and the closest rule 3214
   (42 %). Median stays the default because a nearest-approach rule on a crowded cell selects nearly
   everything, which is a much weaker claim. The export filename carries the statistic
   (`_mitomed0.15_` vs `_mitomin0.15_`) so the two selections cannot overwrite each other.
   `spt_qc_select_smoke` (4c) has a fixture track whose median is +1.20 µm and whose minimum dips to
   -0.90, so the two rules must disagree or the option is a relabelling.

   **Two exclusions, both honoured.** Per-TRACK rejections come from `analysis/curation/
   track_exclusions.csv` (the `✖ Reject` button in Tool 2's QC); per-CELL exclusions come from the
   **Experiment tab's `exclude` flag**, the durable judgement `cs_experiment_aggregate` has always
   honoured. Engagement now applies both, in that order, before anything is measured — track
   rejections inside an excluded cell are still counted as rejections, which is honest — and the
   status line names each count. Until this, the same plate could answer one way in Compare and
   another in Engagement with nothing on screen to say why. The gallery and the examples export use
   the identical set, so a picture can never show a cell the number excluded. Cells are matched on
   the file NAME, the same key `engageConditions` uses, so a cell cannot be excluded under one
   identity and grouped under another. Regression: `spt_curate_engage_smoke` (7).

   Surfaced on the tab as **`k_off /s`** and **`k_on /s`**, computed at every scan distance on the
   same curated set as the ratio and the occupancy, so every column of a row describes one partition
   of one set of molecules. `k_off` shows a **dash when no episode was seen to end** — a zero there
   would read as "never unbinds", the opposite of "unmeasured" — and the CSV carries `n_ended`,
   `n_censored`, `t_bound_s`, `t_free_s` beside the rates so a number from three episodes is
   visible as one.

   **Binding kinetics at the interface** (`cs_zone_kinetics.m`): `k_off` = bound episodes seen to
   END ÷ total time bound, `k_on` = binding events ÷ total time FREE. Events over exposure, not
   `1/mean(duration)` — an episode still bound when its track stops is right-censored, and this form
   gives it exposure but no event, which is exactly correct and is the MLE for a constant hazard
   with censoring. The naive mean treats every truncation as an unbinding: on the smoke's fixture
   (planted `k_off` 4.0, observation window 300 ms) events/exposure returns **4.03** and
   `1/mean(observed)` returns **5.73**. That matters here because tracks end on the same timescale
   as the binding — a median track is ~60 frames. Time accumulates per step as `tau = frame span x
   dt` and each step is credited to the class it STARTS in, the same partition `D_bound`/`D_free`
   uses, so gap-closed steps carry their real duration. Assumes ONE exponential: with a fast pool
   and a stable one, `k_off` is their exposure-weighted average, which is why `perTrack` is returned.
   `k_on` is pseudo-first-order (no concentration term). Read `nEnd`/`nCensored`: a rate from three
   completed episodes is not a rate. Regression: `cs_zone_kinetics_smoke`.

   **The distance is SIGNED and negative means inside.** The zone test is `dist <= d` everywhere
   (`cs_mito_engage`, `cs_engage_examples`, `cs_track_occupancy`), so a positive `d` already
   includes every localization inside the mask plus a shell of width `d` outside it — on the user's
   93-cell plate, 10 % of distances are negative (60 157 of 603 591, min −1.386 µm) and all of them
   count as engaged at any positive `d`. The scan spinners used to be limited to `[0.01 5]`, which
   made the stricter question — *at least |d| INSIDE the organelle* — unaskable and left the
   impression those localizations were being missed. Limits are now `[-2 5]`.
   `cs_track_occupancy_smoke` asserts it both ways: at `d = +0.10` a track held at −0.30 µm scores
   1 (it is inside), and at `d = -0.10` only the track at least 100 nm inside survives.

   **Occupancy is per TRACK, not per localization** (`cs_track_occupancy.m`). This is SPT: the unit
   of observation is a molecule. Pooling every localization in a cell weights a 400-frame track 100x
   more than a 4-frame one, so a handful of long residents carry the number — and it collapses the
   thing most worth seeing, because a bound population plus a free one gives a BIMODAL per-track
   distribution and an unremarkable pooled mean. On the smoke's fixture (one 200-frame resident
   among nine 20-frame free molecules) the pooled occupancy is **0.53** and the per-track median is
   **0.00**: the two tell opposite stories. Per track it is that track's own fraction inside; the
   cell is summarised by the median plus the **engaged fraction** — the share of tracks at or above
   `engaged ≥` (default 0.5), which states a result in words: *"38 % of molecules spend at least
   half their time at mitochondria"*. Tracks under `minLoc` (5) are refused: 3 localizations can only
   score 0, ⅓, ⅔ or 1. Computed at **every** scan distance, on the same curated set as the ratio,
   and reported even where the D ratio refuses a cell — counting localizations needs no step
   statistics, so a sparse cell gets a weaker answer rather than none. Exported both per cell
   (`occ_median_per_track`, `engaged_frac`, `n_tracks_scored`) and per molecule
   (`*_pertrack.csv`), the latter being what a Prism column plot and a bimodality check need.
   Regression: `cs_track_occupancy_smoke`.
   NB the median over ALL tracks lands *between* the populations on a bimodal cell (five tracks at
   0.6 and five at 0 give 0.3, where nothing actually sits) — the engaged fraction is the summary
   that survives bimodality.

   **Seeing the tracks behind the number.** `cs_engage_examples.m` keeps every track with at least
   one step STARTING in the zone — the same rule that builds `D_bound`, so the examples are drawn
   from exactly the population the ratio is computed over. Deliberately not a ranking: selecting the
   most-engaged tracks would make every condition look engaged, inactive ones included, because the
   ranking is on the quantity being measured. The tab draws a sample of them as a gallery (one row
   per condition, each track on a crop of its own organelle mask, localizations coloured by whether
   they are inside the zone), and **Examples → Tool 2** writes them all as a sliced TrackStruct
   (`analysis/examples_<key>_<d>nm.mat`) that Tool 2 opens with *Load TrackStruct…* — giving the
   player, MSD + adaptive fit, stepwise D(t), CSD and the per-track D export on exactly those
   tracks. A `.mat` rather than an XML/CSV round trip because the round trip would lose the MSD
   curves, the per-localization D and the distances that are already computed. **The interactive
   overlaid video is Tool 2's own player** — load the file there, click a track, and it plays over
   the raw movie with the ER/mito overlay. There is deliberately no second player in Tool 3.
   Fields are sliced by SHAPE, not by a named list, so a field added later cannot be silently left
   at full width with its columns no longer corresponding — and **two** layouts occur, not one:
   `[* x nT]` (matrix, MSD, Dt, CSD, steps, distances) and `[nT x 1]` per-track column vectors
   (`lengths`, `trackIDs`). Handling only the first left those two at full width while everything
   else was cut, so `lengths(j)` described a different track from `matrix(:,j,:)` — with no error.
   Where `nF == nT` the two layouts are indistinguishable; the slicer warns and leaves the field
   alone rather than guessing. `examples_*.mat` is excluded from `listBuilds`: it is a valid
   TrackStruct but a SUBSET, and letting it become the active build would have every downstream
   stage quietly analyse 176 tracks instead of 7615. It stays reachable from *Load TrackStruct…*,
   whose own count still includes it so the picker opens rather than loading the active build.
   Regressions: `cs_engage_examples_smoke`, `cs_mito_engage_smoke` — a tethered cell recovers the planted contrast, **an untethered cell
   with the same geometry reads ~1** (the control that says the zone alone cannot manufacture a hit), gaps do
   not move it, every step is classified exactly once, and a thin cell refuses. `spt_engage_tab_smoke` covers
   the wiring: nm→µm, the answer reaching the named rows, N distances → N rows, refusal as a dash, and the
   CSV contents.

8. **Compare** *(done)* — a grouped-stats layer over `CSW_final.mat` (+ `DD` for dwell metrics), on either
   **this project** or the whole **experiment** (every folder in the Experiment tab, via `cs_experiment_aggregate`).
   **Sites** {all sites · mito only · non-mito only} and **dw% ≥** {0..100} — two filters applied BEFORE
   grouping, honoured by the table, the scatter, the dwell-time distribution and the tests alike. `dw%` is
   the picker's site statistic (median over the site's member tracks of each track's % of window
   localizations inside the footprint), recomputed from the footprint in use rather than read off the
   stored `trackPctInside`; gating on it drops SPURIOUS sites — ordinary traffic the detector called a
   site — from **every** metric, and their dwell events leave the pooled distribution with them. Distinct
   from Dwell's `≥% in`, which is per member track at compute time; the two compose. ×
   **group by** {mito vs non-mito · window (time-resolved) · condition (cell) · condition x mito · window x mito}
   × **metric** {dwell s · k_out /s · enrichment · area µm² · n_loc · mito fraction · # sites}.
   `sites = mito only` + `group by = condition` is the **cross-condition mito comparison** (WT vs FFAT vs …
   over mito sites); `condition x mito` is the different question of mito vs non-mito *inside* each condition.
   The filter is part of the exported file name, so the two do not overwrite each other. Shows a grouped
   **mean ± sem** table, a **per-site scatter** with group means, a **pooled dwell-time CDF** per group, and a
   Table columns are `group · n · mean · sem · median · mode`, the **mode BINNED** (centre of the busiest
   Freedman-Diaconis bin — `mode()` on a continuous per-site sample returns the minimum, since nothing
   repeats). **Export points** writes the per-datapoint values for Prism: wide (one column per group,
   a Prism Column data table), long (each point with cell/site/window/condition/dw% for traceability),
   and the pooled dwell EVENTS per group, which is what the CDF is drawn from. A **cells…** picker
   selects which cells enter the comparison — a per-comparison choice, unlike the manifest's durable
   `exclude` flag, and available in project mode too. Every filter, the cell set included (by size plus
   a hash), is part of the exported file names.
   **rank-sum p** when the Stats toolbox is present — the one two-group test, or, under a crossed grouping,
   mito vs non-mito *inside each* condition/window, or, for more than two groups (the cross-condition case,
   where no pair exists to rank-sum), a **Kruskal-Wallis omnibus**. The CDF is the distribution behind the
   means: one stair per group over pooled event durations, each legend entry carrying that curve's n and
   median. **Export CSV** writes the grouped table.
   The **crossed** groupings (`condition x mito`, `window x mito`) split every condition into its mito and
   non-mito sites and keep the pair adjacent, so a mutant's mito effect can be compared with WT's instead of
   being averaged against it. Every metric crosses, `k_out /s` included. Sites are matched to their dwell
   record on **identity** (srcFolder · file · cellIndex · csID · window), never on `siteUID` alone — that id
   restarts at 1 per folder, and matching on it let a condition that was mapped but never dwelled report
   another condition's `k_out`. An unmatched site now contributes no value (`n = 0`), not a borrowed one.
   Regression: `spt_compare_group_smoke`. The Nature suite's
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

The method originates with the **Nature-2024 VAPB paper** from the advisor's lab. That lab's own suite is
**not distributed here** — it is theirs to release. This repo is a clean reimplementation: everything lives
in `drivers/` and the three apps, built around the windowed picker rather than the paper's whole-movie one,
with the density scale factor read from `cs_config.m` instead of a hardcoded constant.
