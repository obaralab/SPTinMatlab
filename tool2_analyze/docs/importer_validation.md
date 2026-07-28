# Importer validation — `TrackImporter_direct.m`

**Goal:** prove the new direct XML/CSV importer produces the *same* `Tracks`
struct as the legacy `TrackImporterCJO_2024v1.m` (so the ContactSites suite is
unaffected), and that its kinematics are analytically correct.

## Method

MATLAB/Octave could not be executed in this environment (the conda-forge Octave
10.3 arm64 build segfaults on startup here). Validation was therefore done with
an **independent Python oracle**: the shared kinematic block
(`kinematics_from_matrix`) is a line-by-line transcription of the MATLAB code in
both importers, and two separate front-ends were implemented —

- `import_new` — builds `matrix` from **explicit `<Track>` membership** in the
  custom `_tracks.xml` (what `TrackImporter_direct.m` does).
- `import_legacy` — builds `matrix` from the **`nSpots` run-length heuristic**
  on a flat spot table (what `TrackImporterCJO_2024v1.m` does off the XLSX).

Both were run on synthetic TrackMate-format files written with the exact XML
structure and CSV header/column order that `trackmate_run_v1.py` emits. The
synthetic set has four tracks with **known analytic** properties, including one
with a **frame gap** (frame 4 missing) to exercise lag-binning `(DeltaT==j)`.

Because the Python oracle reproduces the MATLAB array algebra operator-for-
operator (same `bsxfun`/`diff`/`squeeze`/`omitnan` semantics), field equality in
Python implies field equality in MATLAB for identical inputs.

## Results

**1. New vs legacy — all 12 struct fields identical (max abs diff = 0.0,
tolerance 1e-12):**

| field | max\|new−legacy\| | field | max\|new−legacy\| |
|-------|------------------|-------|------------------|
| matrix | 0 | MSDdata | 0 |
| center | 0 | MSD | 0 |
| rawSteps | 0 | MSDstdev | 0 |
| steps | 0 | MSDerror | 0 |
| CSD | 0 | rawVector | 0 |
| CSDnorm | 0 | vector | 0 |

**2. Analytic correctness** (ballistic tracks, step 0.1 µm/frame):
- Track 100 MSD(lag k) = 0.1·k for k=1..9 — **exact**.
- Track 101 (diagonal, |step|=0.1) MSD(lag k) = 0.1·k for k=1..7 — **exact**.
- Track 100 CSD = [0.1, 0.2, …, 0.9] — **exact**.
- Gapped track 102: consecutive `DeltaT` = [1,1,1,2,1,1] correctly detected;
  MSD(lag 1)=0.05 (only true 1-frame steps), MSD(lag 2)=0.10 (includes the
  3→5 gap step) — **exact**. Confirms the lag-binning handles missing frames.

See `importer_validation.png`.

## Correctness bug found in the legacy path (now fixed)

The legacy run-length importer separates tracks by watching for a change in the
`nSpots` value or a non-positive time jump. On a constructed case of **two real
tracks of equal length whose frames increase monotonically across the boundary**
(track A frames 0–4, track B frames 5–9, same length, distinct regions):

- **legacy → 1 merged track** of length 10 (WRONG)
- **new → 2 tracks** of length 5 each (correct)

The XLSX/run-length path silently fuses temporally-overlapping equal-length
tracks; the direct XML importer cannot, because it reads `<Track>` membership
explicitly. This is an additional reason to retire the Excel path beyond
removing the Windows/Excel dependency.

## Caveat / final check for the user

This validates the struct-construction math against synthetic data. Because your
real `.czi` → TrackMate outputs and the original `.xlsx`/`TrackStruct.mat` were
not available here, **run one real dataset through both paths once** and confirm
the resulting `Tracks` struct is identical (e.g. `isequaln(TracksOld,
TracksNew)` on the shared fields) before switching production over. The
`TimeUnit='frame'` default reproduces the legacy struct exactly (matrix time
plane = integer FRAME); use `'seconds'` only if you want calibrated time there.
