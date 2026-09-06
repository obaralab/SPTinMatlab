# SPT in MATLAB — three-tool VAPB contact-site pipeline

Everything for the single-particle-tracking → ER–mitochondria contact-site workflow, in MATLAB,
in one place. Three focused tools that hand off through files only.

```
Tool 1: TRACK & FILTER          Tool 2: CURATE & BUILD              Tool 3: ANALYZE
match · detect · track · filter   import · curate · build             contact sites · refine
                                  (the slow MSD step)                 sites · dwell · compare
        │                                 │              │                      │
        ▼                                 ▼              ▼                      ▼
  tracks/<base>_tracks_filtered.xml  ─▶ tracks/<base>_tracks_curated.xml  ─▶ analysis/<name>.mat
         <base>_spots_filtered.csv           <base>_spots_curated.csv           + active_trackstruct.txt
         <base>_settings.txt                 <base>_track_metrics.csv
                                             <base>_filter_log.csv

  <project>/experiment_details.mat  ← the manifest all three tools share (cells, conditions, stage counts)
```

Every hand-off is a file on disk, so you can stop after any stage, inspect what it wrote, and resume in a
different tool — or a different session — without re-running anything upstream.

## Launch

Point this at wherever **your** copy of `SPTinMatlab` lives — the folder holding the three
`run_*.m` files. Nothing else needs setting up; the tools add their own sub-folders.

```matlab
addpath('/path/to/SPTinMatlab')     % once per MATLAB session
run_track      % Tool 1  spt_app         — Experiment · Match files · Detect · Track & filter
run_curate     % Tool 2  spt_curate_app  — Experiment · Import & Curate · Build & QC
run_analyze    % Tool 3  spt_analyze_app — Experiment · Contact sites · Refine · Sites · Dwell · Compare
```

To avoid retyping it: **Home → Set Path → Add Folder…**, pick that folder, then **Save**.

New to MATLAB, or setting this up on a new machine? Read **[docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)**
first — it covers the two required toolboxes (**Image Processing**, **Statistics and Machine
Learning**), how your data folders must be named, and what the common first-run errors mean.

**Experiment is tab 1 in all three tools**, and the tabs are numbered in the title bar so the order is
visible. The manifest itself lives at the project top level (`<project>/experiment_details.mat`, not
inside `analysis/`) and is loaded as soon as a project folder is set, so whichever tool you open next
already knows the cells and conditions. Tools 2 and 3 open on it. Tool 1 is the exception: it moves the
selection to *Match files*, because on a fresh project there is nothing in the manifest yet and matching
the three input folders is the first thing you actually do.

Tools 2 and 3 are **one implementation** — `spt_analyze_app.m` behind a `mode` argument.
`spt_curate_app` just calls `spt_analyze_app('curate')`; `run_analyze` calls `spt_analyze_app('analyze')`;
`spt_analyze_app('full')` shows every tab in one window. The **Experiment** tab (`spt_experiment_panel`)
is shared by all three tools — the multi-folder / condition manifest that ties them together.

## Folder layout

```
SPTinMatlab/
├── run_track.m  run_curate.m  run_analyze.m   ← the three launchers
├── README.md                   ← this file
│
├── tool1_track/                ← TOOL 1 (built here) — self-contained
│   ├── spt_app.m               ← the app: Match · Detect · Track & filter · Experiment
│   ├── spt_match.m             ← 3-folder file matcher (SPT ↔ ER-seg ↔ mito-seg)
│   ├── spt_dog.m spt_detect.m spt_pool_quality.m spt_count_per_frame.m   ← detection
│   ├── spt_track.m spt_process_cell.m spt_measure.m spt_load_seg.m       ← tracking + per-spot mito/ER distance
│   ├── spt_link_cost.m spt_link_cost_geo.m spt_seg_off_fraction.m        ← Euclid/penalty · geodesic link costs
│   ├── spt_er_support.m spt_on_er.m spt_seg_fg_label.m                   ← the ONE definition of "on the ER"
│   ├── spt_compare_app.m spt_method_compare.m spt_link_compare.m         ← 3-way linking-method comparison
│   ├── spt_filter_read.m spt_filter_write.m spt_write_outputs.m          ← output + filter (only tracks filtered)
│   ├── spt_write_settings.m spt_append_filter_settings.m spt_append_detection_summary.m  ← provenance
│   ├── spt_track_movie.m       ← embedded track player (frames + ER/mito overlays)
│   ├── spt_pixel_size.m
│   └── *_smoke.m               ← regression tests (geodesic-strict, compare, shape, save-video, …)
│
├── tool2_analyze/              ← TOOLS 2 + 3 (advisor's published pipeline + additive drivers)
│   ├── app/
│   │   ├── spt_analyze_app.m   ← the shared app — 'curate' | 'analyze' | 'full'
│   │   ├── spt_curate_app.m    ← thin Tool 2 wrapper over it
│   │   ├── spt_experiment_panel.m  ← the Experiment tab, shared by all three tools
│   │   ├── spt_pipeline_app.m  ← LEGACY one-window app; not what run_* launches
│   │   ├── track_viewer.m      ← the curation viewer (embedded in Import & Curate)
│   │   ├── *_smoke.m           ← regression tests (batch-overwrite, curate-review, named-build, split)
│   │   └── cs_pipeline_doc.html
│   ├── drivers/                ← EDITABLE additive layer (the picker rework lives here)
│   │   ├── TrackImporter_direct.m   ← curated XML/CSV → Tracks struct (reads MITO_DIST_UM + ER_DIST_UM)
│   │   ├── build_trackstruct.m      ← folder-picker wrapper over the importer (the slow MSD step)
│   │   ├── cs_active_trackstruct.m  ← the SINGLE resolver for "which build is in force"
│   │   ├── cs_window_picker.m cs_window_mapper.m cs_window_density.m cs_window_dwell.m  ← windowed picker → sites → dwell
│   │   ├── cs_footprints_build.m cs_mc_threshold.m cs_radial_plot.m                     ← footprints · MC null · radial
│   │   ├── cs_detect.m cs_mito_from_dist.m                                              ← peak detection · mito from distance
│   │   ├── cs_config.m ChrisPrograms.m                                                  ← pipeline constants · TIFF I/O helper
│   │   └── cs_experiment_scan.m cs_experiment_aggregate.m cs_experiment_status.m        ← the experiment manifest
│
└── docs/
    ├── help.html               ← the reference manual — every tab, every control, the maths, the
    │                             file/column reference, a metric glossary and troubleshooting.
    │                             Opens in your browser from the ❓ Help button in all three tools.
    ├── PIPELINE.md             ← the narrative walk-through, stage by stage
    ├── DATA_STRUCTURE.md       ← what each stage holds in memory, and what it costs at scale
    └── GETTING_STARTED.md      ← start here if you have never opened MATLAB
```

## The tool-to-tool contract

**Tool 1 → Tool 2.** Tool 1 writes, and Tool 2 reads, one set per cell in `<project>/tracks/`:

- **`<base>_tracks_filtered.xml`** — the tracks that passed Tool 1's **filter** (renumbered `TRACK_ID`
  0…K-1). Tool 1 filters on length and net displacement only; *curation* — density, step-variance and
  per-track human judgement — is Tool 2's job, and nothing in Tool 1 is called curation.
- **`<base>_spots_filtered.csv`** — **every** detection (the localization cloud is never filtered),
  columns `TRACK_ID, SPOT_ID, FRAME, T_s, X_um, Y_um, QUALITY, MEAN/MAX/TOTAL_INTENSITY,
  MITO_DIST_UM, ER_DIST_UM`. `TRACK_ID` is blank for spots in dropped/untracked tracks.
- **`<base>_settings.txt`** — the run provenance (below), plus a project-level `detection_summary.csv`.

`MITO_DIST_UM` / `ER_DIST_UM` are signed µm (− inside the organelle, + outside) computed per spot
from the **per-frame** ER/mito masks. Tool 2's importer carries both into
`Tracks(k).mitoDist` / `Tracks(k).erDist` (per tracked spot) and `Tracks(k).allSpots` (every detection).

**Inside Tool 2.** *Import & Curate* reads that pair and exports its own, under the `curated` suffix and
never over its input: **`<base>_tracks_curated.xml`**, **`<base>_spots_curated.csv`** (again the whole
cloud, `TRACK_ID` blanked for tracks the curation dropped), plus `<base>_track_metrics.csv` with a `KEEP`
column and `<base>_filter_log.csv`. *Run batch filter* writes the same set for every matched cell, so a
batch and a hand-curated cell are interchangeable downstream; any write that would land on the file it
just read is refused and reported in the activity log. *Build & QC* then prefers `_tracks_curated.xml`
over `_tracks_filtered.xml` over raw `_tracks.xml`, and `TrackImporter_direct` pairs each XML with the
spots CSV of the **same** stage.

**Tool 2 → Tool 3.** Build & QC has a **Name** field: a build writes `<project>/analysis/<name>.mat`
(default `TrackStruct.mat`) and records that name in `analysis/active_trackstruct.txt`. A project can
therefore hold several **named builds** side by side (`Day1_WT.mat`, `Day1_KO.mat`, …).
`drivers/cs_active_trackstruct.m` is the single resolver — pointer file → `TrackStruct.mat` →
legacy `Tracks.mat` → any `.mat` in the folder that actually contains a `Tracks` variable. Tool 3,
the contact-site picker, the window mapper, footprints, `cs_refine`, the experiment scan and the
Experiment "built" lamp all resolve through it, so they can never disagree about which build is in
force. `Tracks.mat` is **legacy**: it is written only by `run_contactsite_analysis`, which only the
legacy `spt_pipeline_app` / `pipeline_gui` invoke, so it never appears in the `run_curate` /
`run_analyze` flow.

## Organelle frames at a lower rate than the movie

If the ER/mito channel was imaged at a lower rate than the particle channel, its stack is shorter
than the movie. Tool 1's **detection** can map around that (`1 organelle frame covers N SPT frames`
on the Detect tab), but every **viewer** — Tool 1's track player, Tool 2's Import & Curate overlay,
Tool 3's picker and its Sites/Dwell overlays — reads the organelle stack page-for-page and expects
matching lengths. Handed a short stack they either clamp to the last page or stop drawing part-way
through the movie.

The robust fix is to materialise the repeats before you start, so every tool sees one organelle page
per movie frame and none of them needs special handling:

```
Fiji > Plugins > Scripting > Script Editor > (language: Python) > open
tools/duplicate_organelle_frames.py > Run
```

It pairs each segmentation with its SPT movie by the same name rules Tool 1 uses (including the
`_VAPB`-style strip regex), derives N per cell from the page counts, and repeats each organelle page
N times. It **refuses** a pair whose lengths are not a whole ratio rather than guessing, and it does
not interpolate — page k is repeated verbatim, which is exactly what the index map did, made
explicit on disk. It defaults to a **dry run**: it reports the pairing and the page counts it would
write, and writes nothing until you untick that. Output is N x the input size.

Point Tool 1 at the output folder and leave `1 organelle frame covers` on `auto`; it resolves to 1
once the lengths match.

## Tests

Every `*_smoke.m` is a self-contained assertion script: no test framework, no arguments. Add the tool
folder to the path and call it by name. Each prints a line per assertion and ends in either a `PASSED`
banner or a MATLAB error naming what broke.

Most of them read a real dataset (`WithER/`, `Project/`, `Control/`) by absolute path, so they run
on the author's machine and will stop at a `test data missing` assert anywhere else. That is a
limitation of the tests, not of the toolkit — the three tools themselves contain no absolute paths
and run from a single `addpath` on any machine.

```matlab
addpath(genpath('/path/to/SPTinMatlab'))
spt_geo_strict_smoke        % strict ER-geodesic fails closed (27 assertions)
spt_batch_overwrite_smoke   % Tool 2's batch cannot overwrite Tool 1's output
spt_curate_review_smoke     % the curate review workflow; manual keep/reject is durable
spt_named_build_smoke       % named builds + the single-load hand-off to Tool 3
spt_msd_fit_smoke           % the adaptive MSD fit window — a confined track must fit fewer lags
spt_bleedthrough_smoke      % ridge/size/alignment rejection, parity gating, interleaved frame map
spt_gap_diffusion_smoke     % gap-closed steps must not inflate D, in either estimator
cs_mito_engage_smoke        % diffusion contrast at the organelle: sees tethering, and only tethering
spt_engage_tab_smoke        % the Engagement tab carries that answer to the screen intact
spt_calib_edit_smoke        % a calibration you TYPE outranks the files, and only a typed one does
spt_calib_ui_smoke          % ...and it reaches the top bar, cs_calib.mat and the build, not just the table
spt_calib_bulk_smoke        % one calibration across a plate: scoped by the filter, and by nothing else
spt_overlay_fov_smoke       % the raw frame is drawn across the width the TRACKS were measured in
spt_tool3_scale_smoke       % ...and the build stamps that same width, so Tool 3 draws it too
spt_compare_group_smoke     % Compare: crossing, the site/dw%/cell filters, and the per-point export
spt_precision_smoke         % sigma_loc = sqrt(b)/2 recovers a known injected precision
```

Most build synthetic data in `tempdir` and clean up after themselves. The few that need a real movie
read `../WithER/`, which is **pristine reference data: never write into it** — note that MATLAB's
`save()` and `fopen()` follow symlinks, so a fixture must never symlink a whole WithER *directory*.
`spt_named_build_smoke` fingerprints every WithER file before and after and fails if any of them moved.
A test that needs a built TrackStruct and finds none skips loudly rather than passing quietly.

## Provenance

The method originates with the advisor's **Nature 2024 VAPB** contact-site pipeline. This repo is a
clean reimplementation: the analysis lives entirely in `tool2_analyze/drivers/`, built around the
windowed contact-site picker rather than the paper's whole-movie one, with the density-map scale
factor read from `cs_config.m` instead of a hardcoded constant.

The advisor's original suite is **not distributed here** — it is that lab's code to release. Two
small helpers that this pipeline genuinely depends on live in `drivers/`: `cs_config.m` (the pipeline
constants) and `ChrisPrograms.m` (a self-contained TIFF-I/O stand-in written for this repo, not the
advisor's original).

Per run, Tool 1 writes `<base>_settings.txt` next to the outputs: detection diameter, threshold mode
and gate, and the **effective** linking mode (`tracking.link_mode` = `euclid` | `penalty` | `geodesic`)
— never the requested one, so a cell whose ER mode was downgraded for want of a segmentation records
the request separately as `tracking.link_mode_req`. Strict `geodesic` linking **fails closed**: each
frame is pre-filtered to the detections on that frame's own 1 px-dilated ER support (`spt_er_support`
/ `spt_on_er` — the one shared definition), so an off-ER detection cannot enter a track by any route,
gap closing must be reachable *along* the ER, and a frame with no ER mask contributes nothing. Both
costs are counted as `tracking.frames_no_er_mask` and `tracking.dets_off_er`; curating a cell upserts
a `filter.*` block into the same file. `⚖ Compare methods` on the Track tab opens three
side-by-side synchronized players — one per linking mode, over the real frames — with a ranked list
of the links the methods disagree on and MP4 export.
