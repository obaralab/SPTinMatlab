# Changelog — SPT + ContactSites integration

## Dual-colour build (2026-07)

- **Dual-colour app** (`dualcolor/spt_pipeline_dualcolor.m`, launch `run_spt_dualcolor`): a second
  channel per cell, a per-channel parallel ContactSites architecture (each channel runs the whole
  pipeline into `analysis_dualcolor/<tag>/`), and a **Dual-colour tab (Tab 10)** with three sub-tabs —
  **⇄ Shared sites** (reconciled site browser), **Association** (cross-channel correlated motion +
  angle-of-motion), and **Oligomerization** (stepwise photobleaching).
- **New dual-colour drivers** (`dualcolor/drivers/`): `dualcolor_pairs.m` (association + correlated /
  directional motion), `cs_bleach_steps.m` (oligomer-state counter), `cs_reconcile_channels.m`
  (cross-channel site matching), `cs_channel_offset.m` (registration-shift estimate),
  `cs_add_other_channel.m` (other-channel membership annotation).
- **Angle-of-motion analysis** (Association → "angle rose" tab): the signed inter-channel motion-angle
  distribution, magnitude-weighted resultant `angR` + mean angle `angMu` with a Rayleigh null band, and a
  separation-orientation stability metric.
- **Cross-channel frame alignment**: the finer channel is linearly interpolated (gap-aware) onto the
  coarser channel's grid so `stepCorr`/`relMSD`/`angR` are not biased by the ~2× frame-rate difference.
- **New docs**: [`DOCUMENTATION_dualcolor.md`](DOCUMENTATION_dualcolor.md) — dual-colour reference +
  guidance on combining data across collection days.
- `ContactSites_robust/` is **unchanged** — dual-colour lives entirely in `dualcolor/`.

## Added (new files)

- **`drivers/pool_projects.m`** — pool the per-site metrics CSV(s) across collection days into one
  labelled table (parses day/condition/cell from the `file` prefix; handles one combined project, per-day
  projects, or a list; writes a combined CSV + prints a per-day QC summary). See `DOCUMENTATION.md` §8.
- **`TrackImporter_direct.m`** — direct TrackMate XML/CSV → `Tracks` struct
  importer. Replaces the `.xlsx`-based `TrackImporterCJO_2024v1.m`. Options:
  `Pattern`, `TimeUnit` (`frame`/`seconds`), `AttachCSV`, `FileSuffix`, `Save`,
  `Verbose`. Helper functions: `parse_tracks_xml`, `attach_intensities`.
- **`build_trackstruct.m`** — bridge from `track_viewer.m` / TrackMate output to
  the importer; auto-detects curated vs raw XML.
- **`run_contactsite_analysis.m`** — staged, resumable driver for the
  ContactSites suite (11 stages, 2 manual gates).
- **`run_pipeline.m`** — master driver chaining stages 5–6 over a standardized
  `tracks/` + `analysis/` layout.
- **`tracks_struct_contract.md`** — the `Tracks` struct field contract.
- **`README_integrated_pipeline.md`**, **`pipeline_diagram.png`** — integration
  docs + updated data-flow diagram.
- **`importer_validation.md`**, **`importer_validation.png`** — validation
  record.
- **`SPT_pipeline_map.md`** — original-pipeline map + friction analysis.

## Removed (from the production path)

- **`XML2XLSX-macrodistributer.xlsm`** — Windows-only Excel VBA with a
  hard-coded `Z:\sashrestha\…\builtin\` path. No longer part of the pipeline.
- The intermediate **`.xlsx`** spreadsheet and the whole XML→XLSX→import
  round-trip.
- Dependence on **`TrackImporterCJO_2024v1.m`** / **`…2020v1.m`** and their
  fixed-column-letter parsing (kept in the repo for reference; not called).

## Fixed

- **Silent track merge.** The legacy run-length importer merged two real,
  temporally-overlapping, equal-length tracks into one. The direct XML importer
  reads explicit `<Track>` membership and keeps them separate. (Demonstrated in
  `importer_validation.md`.)
- **Column drift (2020 col I vs 2024 col J for `nSpots`).** The new importer
  keys on named CSV columns, eliminating this class of breakage.
- **Cross-platform / manual hand-off hazards documented** (see README):
  `TrackStruct.mat`↔`Tracks.mat` variable/filename reconciliation (now
  automatic in the driver), the `CSData/`↔`CSdata/` case mismatch on Linux, and
  the fixed-length filename-stripping assumption in the suite.

## Notes

- New importer defaults to `TimeUnit='frame'` to reproduce the legacy struct
  exactly.
- The ContactSites suite `.m` files are **unchanged**; the drivers call them.
- Octave could not run in the integration environment (arm64 build segfaults);
  numerical validation used an independent Python oracle. A one-dataset
  real-data `isequaln` check is recommended before production cutover.
