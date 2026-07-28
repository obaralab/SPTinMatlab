# SPT + Contact-Site Pipeline — Map & Streamlining Proposal

This document maps your current single-particle-tracking (SPT) pipeline
end-to-end, overlays your advisor's contact-site (CS) analysis suite from the
Nature paper, and identifies where the two can be merged and where the biggest
friction is. It is a planning reference — no code has been changed.

---

## 1. Current state — two pipelines that meet at a `Tracks` struct

### 1a. Your acquisition → tracking → curation pipeline (documented in README_SPT_pipeline.pdf)

| # | Stage | File | Language | In → Out |
|---|-------|------|----------|----------|
| 1 | **Channel extraction** | `extract_channels_v2_2.ijm` | ImageJ macro | 4-channel `.czi` → `_ch1_mito.tif` (MIP), `_ch24_spt.tif` (interleaved), `_ch3_spt.tif` (raw stack). Batch, skip-if-done. |
| 2 | **Threshold scan** | `trackmate_find_thresholds_v1.py` | Fiji/Jython (headless) | folder of single-particle TIFFs → `thresholds_<TS>.csv`. DoG detection at threshold=0, per-file quality percentile (default p99.5 / README says start p95). Reads px size + frame interval from TIFF metadata, fallback 0.0968 µm / 0.0267 s. |
| 3 | **Tracking** | `trackmate_run_v1.py` | Fiji/Jython (headless) | TIFFs + thresholds CSV → per-file `_session.xml`, `_tracks_builtin.xml`, `_tracks.xml` (custom, carries `SPOT_ID`), `_spots.csv`. DoG + SimpleSparseLAP tracker. RADIUS 0.25, LINKING 1.2, GAP 1, MIN_TRACK_LENGTH 46. Outputs to `run_<TS>/`. Resumable via `completed_files.log`. |
| 4 | **Quality curation** | `260623_track_viewer.m` | MATLAB GUI (uifigure) | `_tracks.xml` + `_spots.csv` pairs → interactive/percentile/batch filtering on **mean NND**, **displacement variance**, **local density**. Exports `_tracks_filtered.xml`, `_spots_filtered.csv`, `_track_metrics.csv`, `_filter_log.csv`, `batch_filter_report.html`. |
| 5 | **XML → XLSX** | `XML2XLSX-macrodistributer.xlsm` | Excel VBA (Windows) | `_tracks_builtin.xml` → `.xlsx`. Hardcoded path `Z:\sashrestha\...\builtin\`. |
| 6 | **Struct build + kinetics** | `TrackImporterCJO_2024v1.m` | MATLAB | `.xlsx` (cols K:M = t,x,y; col J = nSpots) → `Tracks` struct: `matrix`, `lengths`, `center`, `rawSteps`, `steps`, `CSD`, `CSDnorm`, `MSD`, `MSDerror`, `MSDstdev`, `rawVector`, `vector`. Saves `TrackStruct.mat`. |

### 1b. Advisor's contact-site suite (`ContactSites.zip` — 75 `.m`, 7 `.ijm`)

Two instruction files define the order. The suite consumes the **same `Tracks`
struct** (from `TrackImporterCJO_2020v1.m`, which reads col **I** for nSpots —
note the drift vs your 2024 version's col **J**).

- **Prep (advisor):** `2-color-prep.ijm` — 4-channel `.nd2` → time-averaged single-color TIFFs (Median-3D z=10) + spectral inputs. Upstream of ER segmentation / masking.
- **Pre-tracking:** CustomMaskMaker → MaskParticles → TrackMate → `TrackImporterCJO_2020v1`.
- **Post-tracking (the CS analysis):** `DensityVisualization` → `LocDensityFigIntUse` → `QuickPlotterTracks` → Fiji `CSidentifier`/`CSchecker`/`CSrepairer` → `ContactSiteMapper[NoDeff]` → `CellAccumulator` + `CStabulator` → `CSrefiner1/2` → `CS_builder` → averagers/accumulators/reorienters → figure scripts (`Fig4D_*`, `plotEllipseFit`, etc.).
- **Key struct interface:** `CS_builder(Tracks)` reads `Tracks(i).matrix/vector/Deff/cp/segID/LocIndex/CCindex` and per-file `CSdata/<base>_CSdata.mat`, producing a `CS` struct keyed per contact site.

---

## 2. Data-flow diagram

```
.czi ─[extract_channels]─> _ch24_spt.tif ─┐
                                          ├─[find_thresholds]─> thresholds.csv ─┐
                                          └──────────────────────────────────────┼─[trackmate_run]─> _tracks.xml + _spots.csv + _tracks_builtin.xml + _session.xml
                                                                                  
   _tracks.xml + _spots.csv ─[track_viewer.m]─> _tracks_filtered.xml + _spots_filtered.csv + _track_metrics.csv
                                                                                  
   _tracks_builtin.xml ─[XML2XLSX .xlsm]─> .xlsx ─[TrackImporter]─> Tracks struct ─> TrackStruct.mat
                                                                                          │
                                                                                          ▼
                                                                          [ContactSite suite: CSidentifier … CS_builder … figures]
```

---

## 3. Friction points (ranked by cost)

1. **The XLSX round-trip (stages 5–6) is the weakest link.** TrackMate already
   emits a clean `_spots.csv` and a `_tracks.xml`. The Excel VBA macro is
   Windows/Excel-only, has a **hardcoded absolute path**, and is manual. Worse,
   it feeds `TrackImporter`, which reads *fixed column letters* — and those
   letters already drifted between the 2020 (col I) and 2024 (col J) versions.
   This is fragile glue that a direct XML/CSV → struct reader eliminates.

2. **The filtered output bypasses the importer.** `track_viewer.m` produces
   `_tracks_filtered.xml` in the *custom* format, but the importer consumes the
   *builtin* XML via XLSX — so your curated tracks and your struct build are on
   two different XML formats. The filtering and the struct build should share
   one path.

3. **Two TrackImporter versions with silent column drift** (I vs J) — a
   maintenance hazard; whichever the CS suite was validated against is the one
   the Nature results depend on.

4. **Two 4-channel prep macros doing overlapping work** (`extract_channels`
   for `.czi`, `2-color-prep` for `.nd2`; both split channels + time-average).
   Candidate for a single parameterized prep.

5. **Five languages across six stages** (ImageJ macro → Jython → MATLAB GUI →
   Excel VBA → MATLAB). TrackMate genuinely needs Fiji; everything *downstream
   of tracking* (curate → import → kinetics → contact sites) could live in one
   environment.

---

## 4. Proposed streamlined shape

**Keep** (these are the right tool for the job):
- Fiji headless for stages 1–3 (detection/tracking must run in Fiji/TrackMate).
- `track_viewer.m` as the interactive curation GUI.

**Replace / merge:**
- **Delete the Excel step entirely.** Write one importer (`TrackImporter`)
  that reads `_spots.csv` + `_tracks.xml` (or the filtered variants) **directly**
  into the `Tracks` struct — no XLSX, no hardcoded columns. This is the single
  highest-value change and unblocks 1, 2, and 3 at once.
- **Make curation and import share one file path:** `track_viewer` exports the
  filtered CSV/XML → importer reads exactly those.
- **Unify the two importer versions** into one, validated to reproduce the
  struct the CS suite expects (matrix layout, `vector`, `CSD`/`MSD`).
- **Wrap the CS suite** behind the two instruction files as a driver script so
  the ~30-step manual sequence becomes a small number of calls.

**Open decision — target language for the downstream half** (this shapes
everything after tracking):
- **All-MATLAB consolidation** — least risk; the 75-file CS suite already runs
  there and drives the Nature results. Effort concentrated on the importer +
  drivers.
- **Python port** — one language end-to-end with the Jython steps, easier to
  version/automate, but the CS suite would need porting and re-validation
  against published figures (high effort, high risk).
- **Hybrid** — Python importer/kinetics feeding the existing MATLAB CS suite.
