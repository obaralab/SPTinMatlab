# Scaling Reconciliation — prior Python attempt vs. all-MATLAB integration

This note reconciles the two documents from your earlier Claude/Python attempt
(`spt_scaling_documentation.html`, `spt_pipeline_documentation.html`) against the
all-MATLAB deliverables built in this project (`TrackImporter_direct.m`,
`build_trackstruct.m`, `run_contactsite_analysis.m`, `run_pipeline.m`).

**Bottom line (RESOLVED against uploaded real data):** the importer is
calibration-agnostic and needs no change. The apparent tracking-vs-suite mismatch was a
false alarm — the 0.0968 µm/px / 0.0267 s values are *fallback literals* that never
fire when the TIFF carries calibration metadata (it does). Verified against
`250408_FFAT_006`: the true calibration is **0.1079 µm/px, 27.61 µm FOV, 0.02006 s**,
matching the CS suite and scaling doc. **No CS-suite edit is needed.** The only optional
follow-ups are (a) using 0.020064 s instead of rounded 0.020 s if you want Deff exact to
0.3 %, and (b) cosmetically refreshing the stale fallback literals in the tracking
scripts. See §3–§5.

---

## 1. Where every scaling constant lives

| Constant | Value | Set by | Consumed by |
|---|---|---|---|
| SPT camera pixel | **0.0968 µm/px** | `trackmate_find_thresholds_v1.py`, `trackmate_run_v1.py` (fallback) | TrackMate → writes `X_um`,`Y_um` in the `_spots.csv` |
| Frame interval | **0.0267 s** | tracking scripts | `_spots.csv` `T_s`; downstream physical Deff |
| Density bin | **30 nm** | CS suite: `DensityVisualization.m`, `LocDensityFigIntUse.m`, `CS_refiner_v2_wacom.m` | localization histogram grid |
| FOV | **27.61 µm** | CS suite (hardcoded): `DensityVisualization.m:12`, `LocDensityFigIntUse.m:8`, `ContactSiteMapperNoDeff.m:28` (`SF=27.61/size(imG,1)`) | density grid extent, µm↔bin scaling |
| MaxInt image | **256 × 256 px** | acquisition (confirmed by you in scaling doc) | mito mask, per-cell figures |

The scaling doc's headline numbers — 27.61 µm FOV, 30 nm bins, 921-bin grid, implied
107.85 nm camera pixel — are **exactly the advisor's CS-suite hardcoded constants**
(verified by grep against the unzipped suite). The prior Python code
(`CS_population_analysis.py`) faithfully ported them. They are *not* something the
importer introduces or can change.

---

## 2. The importer is insulated from calibration — no change needed

`TrackImporter_direct.m` and `build_trackstruct.m`:

- read `X_um`,`Y_um` **directly** from the TrackMate CSV (already in µm — no pixel
  multiply), and read `frameInterval` from the XML;
- default to `TimeUnit='frame'`, storing the **integer frame index** in
  `matrix(:,:,1)`, so the frame interval never even enters the struct in default mode
  (this is what reproduces the legacy `TrackStruct.mat` bit-for-bit).

So the importer carries whatever physical coordinates TrackMate produced, unchanged. No
pixel size or frame interval is hardcoded anywhere in the new MATLAB code. ✔

The prior Python reader (`h5py` on `TrackStruct.mat`) reads the **same** file the
importer writes — the two halves connect at exactly that struct. The Python "axis
permutation" fix (doc §7 Bug 1) is only needed because h5py transposes MATLAB's
column-major arrays; it is irrelevant to the all-MATLAB path, where MATLAB reads its own
`.mat` natively.

---

## 3. The real discrepancy: two different calibrations

The apparent 0.0968 µm/px, 0.0267 s numbers are **hardcoded fallbacks** in
`trackmate_find_thresholds_v1.py` / `trackmate_run_v1.py` that fire *only when the TIFF
carries no calibration metadata*. On real data the TIFF **does** carry metadata, so
TrackMate reads it and the fallbacks never fire. Verified against the uploaded files:

| Source | Pixel size | FOV (256 px) | Frame interval |
|---|---|---|---|
| `250408_FFAT_006_mito_mip.tif` (ImageJ tags) | **0.10785 µm/px** (XRes 9.27201 px/µm) | **27.61 µm** | **0.020064 s** (`finterval`) |
| `250408_FFAT_006_spt1_tracks.xml` | — | — | **0.020064 s** (`frameInterval`) |
| `250408_FFAT_006_spt1_spots.csv` | — | X,Y max = 26.89, 27.50 µm (fits 27.61) | **0.020064 s** (T_s max / FRAME max) |
| CS suite hardcoded (`DensityVisualization.m` etc.) | 0.1079 µm/px | **27.61 µm** | 0.020 s |

All four agree. **The real calibration is 0.1079 µm/px / 27.61 µm FOV / 0.02006 s —
i.e., the CS-suite / scaling-doc numbers.** The 0.0968/0.0267 fallbacks are stale and
were never used to produce your tracks.

---

## 4. Resolution — nothing needs to change

- **CS suite:** its hardcoded 27.61 µm FOV and 30 nm bins are **correct** for your data.
  Leave `DensityVisualization.m`, `LocDensityFigIntUse.m`, `ContactSiteMapperNoDeff.m`
  untouched. (The earlier draft of this note hypothesized a 27.61→24.78 edit *if* the
  0.0968 fallback were real — the uploaded TIFF proves it is not. No edit.)
- **Importer / drivers:** unchanged — they pass through the µm coordinates and
  `frameInterval` that TrackMate already wrote. ✔
- **Tracking scripts:** functionally correct on real data (metadata path taken). The
  only cosmetic cleanup worth doing is updating the fallback literals from
  0.0968/0.0267 to 0.1079/0.02006 so that *if* a future TIFF ever lacks metadata, the
  fallback matches this microscope instead of an unrelated default. Not required for any
  data that carries calibration.

**One residual caution — frame interval precision.** The true interval is 0.020064 s,
but the CS suite / scaling doc round it to 0.020 s (FRAME_MS = 20). That 0.32 %
difference propagates linearly into any µm²/s Deff. If you want Deff exact, use
0.020064 s wherever the suite converts frame time to seconds; if 0.3 % is within your
error bars, 0.020 s is fine. This is a precision choice, not a bug.

---

## 5. Real-data importer validation (this dataset)

Parsed `250408_FFAT_006_spt1_tracks.xml` + `_spots.csv` through the importer's exact
logic (explicit `<Track>` membership, per-spot FRAME/X/Y, sort by frame):

- **259 tracks, 17169 spots**; every track has explicit `<Track TRACK_ID=… N_SPOTS=…>`
  membership — so the XML importer keeps temporally-overlapping equal-length tracks
  separate (the legacy `.xlsx` run-length merge bug cannot occur here).
- Track lengths 50–332 (median 59); **all 259 already ≥ 46** (MIN_TRACK_LENGTH).
- **Zero internal frame gaps** — every track's frames are consecutive.
- Coordinates lie inside the FOV (x ≤ 26.9, y ≤ 27.5 µm); crude 2D Deff on the longest
  track ≈ 0.68 µm²/s — physically reasonable for membrane-protein SPT.

The struct builds cleanly from your real data. Recommend one `isequaln` check against a
legacy `.xlsx`-built struct for the *same* dataset before production, but the structure,
membership, and units are all confirmed correct here.
