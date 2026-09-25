# SPT in MATLAB — four-tool VAPB contact-site pipeline

Everything for the single-particle-tracking → ER–mitochondria contact-site workflow, in MATLAB,
in one place. Four focused tools that hand off through files only.

```
  TOOL 1                 TOOL 2                 TOOL 3                    TOOL 4
  Track & filter    ─▶   Curate            ─▶   Analysis             ─▶   Contact sites
  match · detect         import · curate        build · MSD/D · QC        pick · refine · map
  track · filter                                (the slow pass)           dwell · engagement
                                                                          compare · export
         │                      │                      │                         │
         ▼                      ▼                      ▼                         ▼
  tracks/                tracks/                analysis/                 analysis/
    _tracks_filtered.xml   _tracks_curated.xml    <name>.mat                CS_footprints.mat
    _spots_filtered.csv    _spots_curated.csv     active_trackstruct.txt    CSW_final.mat
    _settings.txt          _track_metrics.csv                               cs_window_dwell.mat
                           _filter_log.csv                                  cs_engage.mat
                                                                            exports/…/advisor_format/

  <project>/experiment_details.mat   ← the manifest all four tools share
                                       (cells, conditions, stage counts)
```

Every hand-off is a file on disk, so you can stop after any stage, inspect what it wrote, and resume in a
different tool — or a different session — without re-running anything upstream.

**Every file these tools write is documented**, field by field, with a runnable snippet for each:
**[docs/EXPORTS_field_guide.html](docs/EXPORTS_field_guide.html)** (open it in a browser) and its
companion **[docs/exports_snippets.m](docs/exports_snippets.m)**.

Tracking **two colours** is a separate toolkit: **[obaralab/dcSPT](https://github.com/obaralab/dcSPT)**
— see [Dual-colour SPT](#dual-colour-spt-dcspt) for why it is separate and what the two share.

## Launch

Point this at wherever **your** copy of `SPTinMatlab` lives — the folder holding the
`run_*.m` files. Nothing else needs setting up; the tools add their own sub-folders.

```matlab
addpath('/path/to/SPTinMatlab')     % once per MATLAB session
run_track         % Tool 1  spt_app         — Experiment · Match files · Detect · Track & filter
run_curate        % Tool 2  spt_curate_app  — Experiment · Import & Curate
run_analysis      % Tool 3  spt_analyze_app — Experiment · Build / Analyse
run_contactsites  % Tool 4  spt_analyze_app — Experiment · Contact sites · Refine · Sites · Dwell
                  %                           · Engagement · Compare
```

**`run_analyze` is the old name for Tool 4** and still opens it, so existing notes and scripts keep
working. The toolkit had three parts until building and QC became their own tool: what was "Tool 3:
Analyze" is now Tool 3 (**Analysis** — build, MSD/D, QC) plus Tool 4 (**Contact Sites**).

To avoid retyping it: **Home → Set Path → Add Folder…**, pick that folder, then **Save**.

New to MATLAB, or setting this up on a new machine? Read **[docs/GETTING_STARTED.md](docs/GETTING_STARTED.md)**
first — it covers the two required toolboxes (**Image Processing**, **Statistics and Machine
Learning**), how your data folders must be named, and what the common first-run errors mean.

**Experiment is tab 1 in all four tools**, and the tabs are numbered in the title bar so the order is
visible. The manifest itself lives at the project top level (`<project>/experiment_details.mat`, not
inside `analysis/`) and is loaded as soon as a project folder is set, so whichever tool you open next
already knows the cells and conditions. Tools 2, 3 and 4 open on it. Tool 1 is the exception: it moves
the selection to *Match files*, because on a fresh project there is nothing in the manifest yet and
matching the three input folders is the first thing you actually do.

Tools 2, 3 and 4 are **one implementation** — `spt_analyze_app.m` behind a `mode` argument.
`spt_curate_app` calls `spt_analyze_app('curate')`; `run_analysis` calls `spt_analyze_app('analysis')`;
`run_contactsites` calls `spt_analyze_app('contactsites')`; `spt_analyze_app('full')` shows every tab in
one window. (`'analyze'` is kept as an alias for `'contactsites'`.) The **Experiment** tab
(`spt_experiment_panel`) is shared by all four tools — the multi-folder / condition manifest that ties
them together.

**Why building is its own tool.** Curation and building are different jobs with different costs:
curation is per-cell hand work, the build is one slow pass over the whole project that computes MSD, D
and the per-localization rolling estimate. Tool 3 reads the `tracks/` folder on disk rather than Tool 2's
state, so you can build without Tool 2 open, and re-build after re-curating a single cell.

## Folder layout

```
SPTinMatlab/
├── run_track.m  run_curate.m  run_analysis.m  run_contactsites.m   ← the four launchers
│   run_analyze.m               ← the old name for Tool 4; still works
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
├── tool2_analyze/              ← TOOLS 2 + 3 + 4 (advisor's published pipeline + additive drivers)
│   ├── app/
│   │   ├── spt_analyze_app.m   ← the shared app — 'curate' | 'analysis' | 'contactsites' | 'full'
│   │   ├── spt_curate_app.m    ← thin Tool 2 wrapper over it
│   │   ├── spt_experiment_panel.m  ← the Experiment tab, shared by all four tools
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
├── tool3_contactsites/         ← TOOL 4's own layer (the contact-site analyses)
│   ├── app/                    ← the picker, the refiner and the site viewers
│   └── drivers/
│       ├── cs_window_picker.m cs_window_mapper.m cs_window_dwell.m     ← pick → map → dwell
│       ├── cs_footprints_build.m cs_footprints_regenerate.m            ← the editable outline layer
│       ├── cs_outline_sigma.m cs_close_boundary.m                      ← outline smoothing · seam closing
│       ├── cs_engage_classify.m cs_engage_detect.m cs_dwell_histogram.m ← engagement · dwell pooling
│       ├── cs_condition_apply.m                                        ← stamps the manifest's condition onto sites
│       ├── cs_tessellate.m                                             ← the per-tile diffusion map
│       └── cs_advisor_export.m cs_advisor_format.m cs_advisor_viewer.m ← the advisor-format handoff
│           export_template/open_advisor_format.m                       ← ships inside every export
│
└── docs/
    ├── help.html               ← the reference manual — every tab, every control, the maths, the
    │                             file/column reference, a metric glossary and troubleshooting.
    │                             Opens in your browser from the ❓ Help button in all four tools.
    ├── EXPORTS_field_guide.html ← every file the pipeline writes, field by field, with snippets
    ├── exports_snippets.m      ← the runnable companion to it (15 blocks, all verified)
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

**Tool 2 → Tool 3 → Tool 4.** Build / Analyse has a **Name** field: a build writes
`<project>/analysis/<name>.mat` (default `TrackStruct.mat`) and records that name in
`analysis/active_trackstruct.txt`. A project can therefore hold several **named builds** side by side
(`Day1_WT.mat`, `Day1_KO.mat`, …). `drivers/cs_active_trackstruct.m` is the single resolver — pointer
file → `TrackStruct.mat` → legacy `Tracks.mat` → any `.mat` in the folder that actually contains a
`Tracks` variable. Tool 4, the contact-site picker, the window mapper, footprints, `cs_refine`, the
experiment scan and the Experiment "built" lamp all resolve through it, so they can never disagree about
which build is in force. `Tracks.mat` is **legacy**: it is written only by `run_contactsite_analysis`,
which only the legacy `spt_pipeline_app` / `pipeline_gui` invoke, so it never appears in the
`run_curate` / `run_analysis` / `run_contactsites` flow.

**Inside Tool 4.** Five stages, each writing its own file in `analysis/`, each keyed on
`(file, csID, window)` and — from the mapper onward — on a project-unique `siteUID`:
pick (`csIDs/<base>_CSsites.txt`) → outline (`CS_footprints.mat`, editable in the Refine tab) →
map (`CSW_final.mat`, the central record) → dwell (`cs_window_dwell.mat`) → engagement
(`cs_engage.mat`). `cs_condition_apply` stamps each cell's **condition** from the manifest onto the
mapped sites, so everything downstream can pool by condition without knowing the manifest exists.
`Export → advisor format` then writes the published VAPB layout, one folder per condition.
Every field of all of these is in
**[docs/EXPORTS_field_guide.html](docs/EXPORTS_field_guide.html)**.

## Dual-colour SPT (dcSPT)

Tracking **two moving species at once** is a separate toolkit —
**[github.com/obaralab/dcSPT](https://github.com/obaralab/dcSPT)** — not a mode of this one.

The reason is structural. Everything here is built around one tracked species and its relationship to a
segmented organelle: a cell is one movie, a channel is a mask, and the analyses ask "is this molecule
near the ER". Dual colour asks a different question with a different shape — two moving species, two
frame rates, and a partner that may not have been imaged at the moment you were looking. Bolting it on
would have meant a channel token threaded through every file name, a second time base through every
consumer, and a "which colour is this" question at every call site.

What `dcSPT` shares with this repo is the detection and I/O core, copied and renamed `spt_* → dc_*` so
both toolkits can sit on one MATLAB path: the DoG filter, the detector, the ridge gate, the per-spot
intensity, the single-handle TIFF reader and the metadata calibration. It deliberately leaves behind the
ER link modes and the organelle-skeleton bleedthrough gate, both of which rest on a mask it does not
have.

**It indexes by frame, never by seconds.** These TIFFs carry one nominal `finterval` for the whole stack
and no per-page timestamps, so a second is always a frame number times a nominal interval and the error
accumulates along a track. The acquisition does write an exact index, per page, in its ImageJ slice
labels (`c:2/4 t:1/2000`), so which pages are which colour is **read from the file** rather than deduced
from a stride — a deduction that breaks silently when an acquisition drops a page. The two colours are
then related by set intersection on their acquisition timepoints, with no tolerance anywhere.

That label reader is back-ported here as **`tool1_track/spt_tiff_labels.m`**, and two things in this
repo now use it:

- **`spt_interleave_check`** asks the file before measuring pixels. Labels naming two channels are proof
  the pages hold different channel *numbers*; they do not say whether those are different *fluorophores*,
  so the message states both readings and picks neither. A label naming one channel does not clear a
  stack whose pages alternate anyway — labels can be stale, and the two mistakes do not cost the same.
- **`tool2_analyze/drivers/spt_page_map.m`** reports which organelle page belongs to a tracked frame, and
  says so when that disagrees with the `page = frame + 1` rule the viewers use.

```bash
git clone https://github.com/obaralab/dcSPT.git
```

```matlab
addpath('/path/to/dcSPT/core', '/path/to/dcSPT/drivers')
C = dc_channels('fromStack', stack, 0.0267);   % ask the file which pages are which colour
R = dc_process_cell(cel, C, prm);              % both colours, tracked independently
D = dc_dataset('new','cellA',C);
D = dc_dataset('addChannel', D, R(1));  D = dc_dataset('addChannel', D, R(2));
disp(dc_align(D).text)                         % how the two colours' timepoints relate
```

Tracking works; relating the two colours does not yet. Chromatic **registration** is the next piece —
nothing corrects it so far, and a 100–300 nm offset is the same size as the distances being measured.
Full argument in that repo's [README](https://github.com/obaralab/dcSPT#readme) and
[docs/DATA_MODEL.md](https://github.com/obaralab/dcSPT/blob/main/docs/DATA_MODEL.md).

## Organelle frames at a lower rate than the movie

If the ER/mito channel was imaged at a lower rate than the particle channel, its stack is shorter
than the movie. Tool 1's **detection** can map around that (`1 organelle frame covers N SPT frames`
on the Detect tab), but every **viewer** — Tool 1's track player, Tool 2's Import & Curate overlay,
Tool 4's picker and its Sites/Dwell overlays — reads the organelle stack page-for-page and expects
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

To see which rule applies to a cell before you start, ask
`spt_page_map(sptStack, segStack)`: it reports the relation (`perFrame`, `perTimepoint`, `window`,
`single`), uses the stack's slice labels where it has them, and says explicitly whether the answer
disagrees with the `page = frame + 1` rule the viewers use. It reports and changes nothing;
`cs_channel_mask(..., 'PageOf', M.pageOf)` applies the mapping where a caller wants it.

## Tests

Every `*_smoke.m` is a self-contained assertion script: no test framework, no arguments. Add the tool
folder to the path and call it by name. Each prints a line per assertion and ends in either a `PASSED`
banner or a MATLAB error naming what broke.

Most of them read a real dataset (`WithER/`, `Project/`, `Control/`) by absolute path, so they run
on the author's machine and will stop at a `test data missing` assert anywhere else. That is a
limitation of the tests, not of the toolkit — the four tools themselves contain no absolute paths
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
spt_qc_select_smoke         % QC selects tracks by length and mito, and every panel agrees
cs_engage_examples_smoke    % the example tracks ARE the population D_bound is built from
spt_curate_engage_smoke     % rejecting a track by hand moves the engagement number, and persists (and a subset never becomes the build)
cs_track_occupancy_smoke    % occupancy per MOLECULE, and the pooled number it corrects
cs_zone_kinetics_smoke      % k_off/k_on as events over exposure, so censoring cannot inflate them
spt_qc_table_smoke          % the QC table never claims a channel whose distances are all NaN
spt_player_teardown_smoke   % a queued timer tick, and a superseded load, cannot crash the player
cs_detect_explain_smoke     % a bright spot that is not a site says WHICH gate stopped it
cs_picker_support_smoke     % a DERIVED support is never labelled ER, and the per-site gates exist
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
