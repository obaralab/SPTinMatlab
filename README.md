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

```matlab
addpath('/Users/safal-mac/Documents/IntegratedPipeline/SPTinMatlab')
run_track      % Tool 1  spt_app         — Experiment · Match files · Detect · Track & filter
run_curate     % Tool 2  spt_curate_app  — Experiment · Import & Curate · Build & QC
run_analyze    % Tool 3  spt_analyze_app — Experiment · Contact sites · Refine · Sites · Dwell · Compare
```

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
│   │   ├── cs_footprints_build.m cs_refine.m cs_mc_threshold.m cs_radial_plot.m         ← footprints · refine · MC null · radial
│   │   ├── cs_identify.m cs_detect.m cs_mito_from_dist.m                                ← whole-movie picker · peak detection · mito from distance
│   │   ├── cs_experiment_scan.m cs_experiment_aggregate.m cs_experiment_status.m        ← the experiment manifest
│   │   └── run_pipeline.m run_contactsite_analysis.m setup_run_folder.m … ← staged drivers (legacy path)
│   ├── ContactSites_robust/    ← WORKING suite — the app + drivers actually run against THIS.
│   │                              Hardened refactor of the paper code (config-driven scale factor,
│   │                              robust name handling); proven equal to the original. Editable if needed.
│   ├── ContactSites_original/  ← ★ PRISTINE — the Nature 2024 VAPB paper suite. DO NOT EDIT / RUN.
│   │                              Kept as the reference of record; robust was validated against it.
│   └── docs/                   ← DOCUMENTATION.md, tracks_struct_contract.md, SPT_pipeline_map.md, …
│
└── docs/
    ├── help.html               ← the reference manual — every tab, every control, the maths, the
    │                             file/column reference, a metric glossary and troubleshooting.
    │                             Opens in your browser from the ❓ Help button in all three tools.
    ├── PIPELINE.md             ← the narrative walk-through, stage by stage
    ├── DATA_STRUCTURE.md       ← what each stage holds in memory, and what it costs at scale
    ├── IDEA_unravelling.md     ← a future extension (ER-trajectory unravelling) and its blocker
    └── SESSION_HANDOFF.md
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

## Tests

Every `*_smoke.m` is a self-contained assertion script: no test framework, no arguments. Add the tool
folder to the path and call it by name. Each prints a line per assertion and ends in either a `PASSED`
banner or a MATLAB error naming what broke.

```matlab
addpath(genpath('/Users/safal-mac/Documents/IntegratedPipeline/SPTinMatlab'))
spt_geo_strict_smoke        % strict ER-geodesic fails closed (27 assertions)
spt_batch_overwrite_smoke   % Tool 2's batch cannot overwrite Tool 1's output
spt_curate_review_smoke     % the curate review workflow; manual keep/reject is durable
spt_named_build_smoke       % named builds + the single-load hand-off to Tool 3
spt_msd_fit_smoke           % the adaptive MSD fit window — a confined track must fit fewer lags
spt_precision_smoke         % sigma_loc = sqrt(b)/2 recovers a known injected precision
```

Most build synthetic data in `tempdir` and clean up after themselves. The few that need a real movie
read `../WithER/`, which is **pristine reference data: never write into it** — note that MATLAB's
`save()` and `fopen()` follow symlinks, so a fixture must never symlink a whole WithER *directory*.
`spt_named_build_smoke` fingerprints every WithER file before and after and fails if any of them moved.
A test that needs a built TrackStruct and finds none skips loudly rather than passing quietly.

## Provenance & which suite runs

There are two copies of the ContactSites suite, with distinct roles:

- **`ContactSites_original/`** — the code the advisor used for the **Nature 2024 VAPB paper**. Kept
  **pristine**: never edited, never run by the app. It is the reference of record.
- **`ContactSites_robust/`** — a hardened refactor, *proven equal to the original*, that the app +
  drivers **actually run against**. The additive drivers were built on it and depend on its behaviour
  (e.g. the density-map scale factor comes from `cs_config.m` instead of the paper's hardcoded value,
  and name handling is robust). The app auto-selects `ContactSites_robust` when both are present.

All new / reworked analysis (including the windowed contact-site picker) is *additive* and lives in
`tool2_analyze/drivers/` — it calls the suite in the intended order and never edits a suite `.m` file.
The upstream originals also remain untouched in `../SPT_ContactSites_Pipeline/`.

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
