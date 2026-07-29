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

> **Superseded for two fields.** This table is the *historical* result, taken when
> the direct importer was a bit-for-bit reimplementation of the legacy math. Two
> fields — **`CSD`** and **`MSDerror`** — have since been deliberately changed
> because the legacy formulas were wrong; see
> [Deliberate divergence from legacy](#deliberate-divergence-from-legacy-csd-and-msderror)
> below. The other **10 fields still match bit-for-bit** and the table stands for
> them — with the one qualification that `CSDnorm`, being derived from `CSD`,
> matches only as far as `CSD` does (‡).

| field | max\|new−legacy\| | field | max\|new−legacy\| |
|-------|------------------|-------|------------------|
| matrix | 0 | MSDdata | 0 |
| center | 0 | MSD | 0 |
| rawSteps | 0 | MSDstdev | 0 |
| steps | 0 | MSDerror † | 0 |
| CSD † | 0 | rawVector | 0 |
| CSDnorm ‡ | 0 | vector | 0 |

† No longer true, on purpose — see below.

‡ Knock-on: `CSDnorm = CSD ./ CSD(L-1,:)`, so it still matches legacy on any track
whose steps all span the same number of frames (the whole synthetic set except
track 102), but the *shape* of the ramp changes on a track with mixed frame gaps.

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

## Deliberate divergence from legacy: `CSD` and `MSDerror`

Bit-identity with the legacy importer was the goal only while the legacy math was
believed correct. Two fields were wrong there, so the direct importer now computes
them differently **on purpose**, and the certification above no longer applies to
them. Both changes are local to the kinematics block of
`drivers/TrackImporter_direct.m`; every other field is untouched.

| field | legacy (wrong) | current | why |
|---|---|---|---|
| `CSD` | `cumsum(dS1./dT1)` = `cumsum(steps)` | `cumsum(dS1)` = `cumsum(rawSteps(:,:,2))` | `steps` is a per-frame **speed**, not a distance. Summing it charges a gap-closed step only its per-frame average, so a 2-frame gap contributes half the distance the molecule actually covered — and the sum is not in µm unless every `dT` is 1, which is exactly what its consumers assume (`spt_pipeline_app` labels it "cumulative displacement (µm)"). |
| `MSDerror` | `MSDstdev./sqrt(#tracks with a finite MSD at that lag)` | `MSDstdev./sqrt(cntSD)`, NaN where `cntSD==0` | The standard error of *this* track's MSD at *this* lag must use *its own* pair count. The legacy divisor was a property of the whole cell, so a track with 374 pairs and a track with 1 pair got the same error bar. |

**Measured impact** on the WithER cell (86.6% of tracks contain a 2-frame gap):

- `CSD` — legacy understated total path length by a **median 2.0%**, up to **11.5%**
  on a single track. Only tracks with a gap are affected; a fully consecutive
  track has `dT ≡ 1` and both formulas agree exactly.
- `MSDerror` — legacy divisor ranged 2…838 across lags; the resulting error bars
  were a **median 4× too small** (worst case 10× too small, 3.7× too large).

`MSD` and `MSDstdev` themselves were independently re-derived and are **correct
and unchanged** — only the error-bar normalization moved. `CSDnorm` shifts only as
a consequence of `CSD` (see ‡ above).

The analytic checks in Results §2 still hold under the new formulas: track 100 is
gap-free (`dT ≡ 1`), where `cumsum(dS1)` and `cumsum(dS1./dT1)` are identical.

## Caveat / final check for the user

This validates the struct-construction math against synthetic data. Because your
real `.czi` → TrackMate outputs and the original `.xlsx`/`TrackStruct.mat` were
not available here, **run one real dataset through both paths once** and confirm
the resulting `Tracks` struct is identical (e.g. `isequaln(TracksOld,
TracksNew)` on the shared fields) before switching production over — **excluding
`CSD`, `CSDnorm` and `MSDerror`, which now differ by design** (see above); compare
those against the corrected formulas, not against the legacy output. The
`TimeUnit='frame'` default reproduces the legacy struct exactly (matrix time
plane = integer FRAME); use `'seconds'` only if you want calibrated time there.
