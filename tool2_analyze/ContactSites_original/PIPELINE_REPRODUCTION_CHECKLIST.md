# VAPB sptPALM Contact-Site Pipeline — Reproduction Checklist

Corrected, consolidated run order for the analysis in **Obara, Nixon-Abell et al., _Nature_ 626:169 (2024)**,
"Motion of VAPB molecules reveals ER–mitochondria contact site subdomains."
Reconciles `InstructionsBeforeTracking.txt` + `InstructionsAfterTracking.txt` with what the code actually does.

Legend:  🖐 = manual / operator-in-the-loop   ⚙ = automated MATLAB   🔬 = Fiji macro   ☁ = EXTERNAL (not in this repo)

---

## Stage 0 — External dependencies you must have on the MATLAB path
- `ChrisPrograms` class (TIFF I/O: `ChrisPrograms.loadtiff`) — ☁ external
- `AssimilateTessIndex3.m` — ☁ external (folds JBM Deff maps into `Tracks`)
- `LocDensityFigGenerate.m`, `TrackOverlayMaker`, `TracksOverRawImage*` — ☁ external helpers
- **JBM / Masson Deff engine** (Voronoi + Bayesian overdamped-Langevin) — ☁ produces `Maps/Maps_<file>_kmeans_60_nb_min_30.mat`
- **Calderon NPB / HDP-SLDS Python code** + model-fitting software — ☁ produces the blinded latent-state results
- **TrackMate** (Fiji) and **MaskParticles.ijm** — ☁ external

---

## Stage A — Pre-tracking image prep  (`InstructionsBeforeTracking.txt`)
1. 🔬 `RawFilePrep/2-color-prep.ijm` (or `Recusive_2-color-prep.ijm`) — split `.nd2` channels; adjust the desired time step.
   - out: `_SMinst.tif` (raw single-molecule → TrackMate), `_SM.tif` (10-frame temporal median),
     `_2.tif` (median ER), `_2_TA_BC.tif` (time-avg bleach-corrected ER).
   - optional: 🔬 `HighPassFilter+Median.ijm` (Gaussian σ=60 subtract + z=10 median) → `_maxS2N.tif`.
2. 🖐🔬 `CustomMaskMaker.ijm` — rough ER mask (or ilastik).
3. 🔬 `MaskParticles.ijm` ☁ — restrict SM stack to the ER mask.
4. ☁🖐 **TrackMate** — link the masked SM stack; **manually curate** linkages onto the ER structure; export `.xlsx`.
5. ⚙ `TrackImporterCJO_2020v1.m` — reads TrackMate `*.xlsx` (cols K:M = t,x,y; col I = spot IDs) → **`Tracks`** struct → `TrackStruct.mat`.

---

## Stage B — Density maps + contact-site definition  (`InstructionsAfterTracking.txt`)
Folder must contain: `MaxInt/` (`*_3_MaxInt_RGB.tif`), `Tracks.mat`; ideally `ER/ Mito/ Maps/`.
6. ⚙ `DensityVisualization(Tracks, 30, true)` — 30 nm-bin, σ=[2 2] density map → `*_rho.tif`.
7. ⚙ loop `LocDensityFigIntUse(Tracks, i, 30)` over all cells.
8. ⚙ `QuickPlotterTracks.m` (set loop size = `size(Tracks,2)`) — track-on-image QC overlays.
9. 🖐🔬 `CustomMaskMaker.ijm` again (rough, for later viz).
10. 🖐🔬 `CSidentifier.ijm` (all files) → auto CS ROIs + **manually picked CS centers** `*CSsites.txt`.
11. 🔬 `CSchecker.ijm` (all files) — visual QC (read-only).
12. 🖐🔬 `CSrepairer.ijm` (only files with mistakes; note hardcoded resume `i=12`).
13. ⚙ `ContactSiteMapper.m` (parent dir; needs `Densities/ csIDs/ Maps/`).  If no JBM Deff → `ContactSiteMapperNoDeff.m`.
    - folds JBM Deff via `AssimilateTessIndex3` ☁; boxes each CS; sets `MitoFlag`.
    - out: `TrackData/<file>_Tracks.mat`, `TrackData/<file>_CSdata.mat`, snaps in `CSdata/`.
14. ⚙ in `TrackData/`: `CellAccumulator.m`, then `CStabulator.m` (**uncomment the save lines** — they're commented out) → `CSindexing.mat` (`CSinfo.CSindex`).
15. ⚙ loop: copy `CSinfo.CSindex` into `Tracks(i).MitoCSindex`.

---

## Stage C — Manual CS boundary refinement (Wacom)
16. Rename `CSdata/` → `CSsnaps/`, make a fresh `CSdata/`.
17. 🖐⚙ Preferred: `CS_refiner_v2_wacom(TrackStruct, MitoFlag, inputDir, outputDir)` — the one clean function (supersedes `CSrefiner1/2/2_wacom/3_wacom/NoDeff`).
    - MitoFlag: `0`=all, `1`=mito-only, `-1`=non-mito. `PixSize=30`, `ROI=[-40 40]`, `AmpFactor=10`.
    - operator `drawpoint` (refined center) + `drawfreehand` (boundary).
    - writes `refCenter`, `refboundary` (**nm**), `refLocIDs` (Track MN-space linear idx), `IDmatrixMN`, `EllipseFit`.

---

## Stage D — Ensemble diffusion + geometry
18. ⚙ `CSensemble1.m` (filtered: non-mito CS excluded from control; emits `Dother`) → `CSoutputFilt.xlsx`
    **or** `CSensemble2.m` (unfiltered) → `CSoutput.xlsx`.  (Deff-only step — skip if no `Tracks.Deff`.)
    - `Deff` (per-CS interior mean), `Din` (cell), `Dout` (control), `Dother`, `EllipseParam`.
19. ⚙ `CSellipseAnalysis.m` → pooled `CSmito`/`CSother` in `CSfits.mat`.
20. ⚙ `CSaverager.m` — center-registers CS locs; splits round vs elongated (aspect > 2.5) → `AssembledCSforAvg.mat`.

---

## Stage E — Latent-state assignment (blinded, external)
21. ☁ scramble long trajectories (>500 steps) → Calderon Python NPB/HDP-SLDS → model fitting.
22. ⚙ `ChrisSegAssign(ChrisC, SegmentDetails)` (or `ChrisCconvert`) → embeds `segID`/`cp` per localization.
23. ⚙ `ChrisCunblinder(ChrisC, IndexMatrix)` → `Condition_NPB.mat`; `FinalTrackAssembler.m` writes results back into `Tracks`.

---

## Stage F — Final CS assembly + averaging
24. ⚙ `Final/CS_builder(Tracks)` → flat condition-wide **`CS`** struct → `CS_final.mat`.
    - variants: `CS_builder_v2`, `CS_builderMitoOnly`, `CS_builderNoJBM`.  ⚠ do **not** use `Final/Revision/CS_builder.m` (buggy loops — see fixes doc).
25. ⚙ `Final/Reorganize.m` → clean nested physical-unit schema.
26. ⚙ `Final/ConditionAccumulatorFinal.m` (or `noJBM`) → `CS_details.xlsx` + per-CS figure folders.
27. 🖐⚙ `Final/CS_reorienter_v3.m` — operator `drawpoint`s "North" + enters `NumExits`; then `CSreorienterv2p2.m` + `CoordShiftCS.m` rotate to a common frame.
28. ⚙ `Final/AvgCSAccumulator(CS)` (or `v2`) → population-average CS with `normD = Deff / mean(refDeff)`.

---

## Stage G — Revision analyses (dwell kinetics, enrichment, figures)
29. 🖐⚙ `Revision/DwellTimeManual(CS, idx)` → `AddDwellTimes2CSstruct(CS, BindingInfo)` → `EntryExitManualClassifierv2(CS, idx)` (use **v2**) → `ExtractBindingInfo(CS)` → `ParseCompleteInteractions.m`.
30. ⚙ `Revision/GenerateEnrichmentStruct.m` → `OutputEnrichmentCoeffDatav2.m` → `EnrichmentCoefficients.xlsx`.
31. ⚙ index reconciliation: `AssignCSindexByCell.m`, `AddLegacyIndexestoCSstruct.m`, `CSindiciesByFlag.m`; export `ExportCSstructStatsv3.m` → `CS_details_v2.xlsx`.
32. 🖐⚙ `Revision/EMtracer_2Dv1.m` — freehand membrane tracing on EM → `EMcurvStruct` (curvature correlation).
33. ⚙ figures: `Final/Fig4D_Deffsynchronizer.m` (Fig 4D Control vs HBSS), `CS_trajPlotZoom.m`, `Label_CS_DensityPlot.m`, `CS_interactiveFig.m`.

---

### Gotchas that bite reproduction
- X/Y and centers are in **µm**; `CS.refboundary` is in **nm**.
- Frame period hardcoded `0.011 s` (~91 Hz); FOV calibrations `20.48 µm` (Deff path) vs `27.61 µm` (`*NoDeff`) coexist; box `±30 px` vs `±150 px`.
- Several scripts assume a specific working directory and that `dir()` file order is index-aligned with `Tracks`.
- Hardcoded resume indices exist (`CS_reorienter_v2` i=118; `CSrefinerNoDeff` i=15; `CSrefiner2` i=5:end−1; `TempFileCompiler` 160).
- `CStabulator.m` save lines are commented out by default.
- See `BUGS_AND_FIXES.md` for confirmed defects (do not use the `Revision/CS_builder.m` copy, `EntryExitManualClassifier` v1, or `CSaveragerNoDeff.m` as-is).
