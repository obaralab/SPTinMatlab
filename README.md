# SPT in MATLAB — two-tool VAPB contact-site pipeline

Everything for the single-particle-tracking → ER–mitochondria contact-site workflow, in MATLAB,
in one place. Two focused tools that hand off through files only.

```
Tool 1: TRACK & FILTER            handoff (files)              Tool 2: ANALYZE
raw SPT + ER-seg + mito-seg  ──▶  <base>_tracks_filtered.xml  ──▶  contact sites, dwell,
match·detect·track·filter         <base>_spots_filtered.csv        density, cross-condition
```

## Launch

```matlab
addpath('/Users/safal-mac/Desktop/IntegratedPipeline/SPTinMatlab')
run_track      % Tool 1 — SPT Track & filter  (produces the curated tracks)
run_analyze    % Tool 2 — ContactSites analysis (consumes them)
```

## Folder layout

```
SPTinMatlab/
├── run_track.m                 ← launcher for Tool 1
├── run_analyze.m               ← launcher for Tool 2
├── README.md                   ← this file
│
├── tool1_track/                ← TOOL 1 (new, built here) — self-contained
│   ├── spt_app.m               ← the app: Match · Detect · Track & filter
│   ├── spt_match.m             ← 3-folder file matcher (SPT ↔ ER-seg ↔ mito-seg)
│   ├── spt_dog.m spt_detect.m spt_pool_quality.m spt_count_per_frame.m   ← detection
│   ├── spt_track.m spt_measure.m spt_load_seg.m spt_process_cell.m       ← tracking + per-spot mito/ER distance
│   ├── spt_write_outputs.m spt_curate_read.m spt_curate_write.m          ← output + filter (only tracks filtered)
│   ├── spt_track_movie.m       ← embedded track player (frames + ER/mito overlays)
│   └── spt_pixel_size.m
│
├── tool2_analyze/              ← TOOL 2 (advisor's published pipeline + additive drivers)
│   ├── app/
│   │   ├── spt_pipeline_app.m  ← one-window app: Calibration · Curate · Build · Run · Contact sites · Dwell · Compare
│   │   ├── track_viewer.m
│   │   └── cs_pipeline_doc.html
│   ├── drivers/                ← EDITABLE additive layer (the picker rework lives here)
│   │   ├── TrackImporter_direct.m   ← curated XML/CSV → Tracks struct (reads MITO_DIST_UM + ER_DIST_UM)
│   │   ├── build_trackstruct.m      ← folder-picker wrapper over the importer (the slow MSD step)
│   │   ├── cs_identify.m cs_window_density.m cs_mito_from_dist.m         ← contact-site picker + density
│   │   ├── cs_mc_threshold.m cs_refine.m cs_radial_plot.m               ← Monte-Carlo null · refine · radial
│   │   └── run_pipeline.m run_contactsite_analysis.m setup_run_folder.m … ← staged drivers
│   ├── ContactSites_robust/    ← WORKING suite — the app + drivers actually run against THIS.
│   │                              Hardened refactor of the paper code (config-driven scale factor,
│   │                              robust name handling); proven equal to the original. Editable if needed.
│   ├── ContactSites_original/  ← ★ PRISTINE — the Nature 2024 VAPB paper suite. DO NOT EDIT / RUN.
│   │                              Kept as the reference of record; robust was validated against it.
│   └── docs/                   ← DOCUMENTATION.md, tracks_struct_contract.md, SPT_pipeline_map.md, …
│
└── docs/                       ← cross-tool notes (the file handoff contract)
```

## The two-tool contract

Tool 1 writes, and Tool 2 reads, one pair per cell in `<project>/tracks/`:

- **`<base>_tracks_filtered.xml`** — only the tracks that passed curation (renumbered `TRACK_ID` 0…K-1).
- **`<base>_spots_filtered.csv`** — **every** detection (the localization cloud is never filtered),
  columns `TRACK_ID, SPOT_ID, FRAME, T_s, X_um, Y_um, QUALITY, MEAN/MAX/TOTAL_INTENSITY,
  MITO_DIST_UM, ER_DIST_UM`. `TRACK_ID` is blank for spots in dropped/untracked tracks.

`MITO_DIST_UM` / `ER_DIST_UM` are signed µm (− inside the organelle, + outside) computed per spot
from the **per-frame** ER/mito masks. Tool 2's importer carries both into
`Tracks(k).mitoDist` / `Tracks(k).erDist` (per tracked spot) and `Tracks(k).allSpots` (every detection).

## Provenance & which suite runs

There are two copies of the ContactSites suite, with distinct roles:

- **`ContactSites_original/`** — the code the advisor used for the **Nature 2024 VAPB paper**. Kept
  **pristine**: never edited, never run by the app. It is the reference of record.
- **`ContactSites_robust/`** — a hardened refactor, *proven equal to the original*, that the app +
  drivers **actually run against**. The additive drivers were built on it and depend on its behaviour
  (e.g. the density-map scale factor comes from `cs_config.m` instead of the paper's hardcoded value,
  and name handling is robust). The app auto-selects `ContactSites_robust` when both are present.

All new / reworked analysis (including the frame-based contact-site picker) is *additive* and lives in
`tool2_analyze/drivers/` — it calls the suite in the intended order and never edits a suite `.m` file.
The upstream originals also remain untouched in `../SPT_ContactSites_Pipeline/`.
