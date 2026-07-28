# ContactSites_robust — refactor changelog

Behavior-preserving hardening of the ContactSites suite. The pristine original is kept as `ContactSites_original/` for `isequaln` validation. Every edit below is mechanical and, for correctly-named inputs, produces the identical base string / numeric value as the original.

**38 edits across 26 files.**

## New helper files (added, not edits)

- `cs_config.m` — single source of truth: constants, folder names, filename suffixes, `FileTagChars`.
- `cellBase.m` — replaces `file(1:end-7)`; tag length is `cs_config.FileTagChars` (0 = integrated pipeline, 7 = original paper runs).
- `stripSuffix.m` — replaces `filename(1:end-N)`; removes a *literal* suffix and errors loudly on mismatch.
- `cs_preflight.m` — pre-run validator; prints a pass/fail table for the run folder.

## Two bugs fixed

1. **Folder-case split (data-loss risk):** the `CSrefiner*` scripts *saved* to `CSData/` but every other script *reads* `CSdata/`. On a case-sensitive filesystem these are different folders. Normalized all to `CSdata` (5 sites).
2. **Scale-factor discrepancy (flagged, not silently changed):** `ContactSiteMapper.m` used `SF=20.48/size(imG,1)` while `ContactSiteMapperNoDeff.m` used `27.61`. The density map spans 27.61 µm, so 20.48 appears stale. The robust `ContactSiteMapper.m` keeps `20.48` for bit-identical behavior but flags it inline; `cs_config.SnapFOV_um` (=27.61) is the intended value — change one line to adopt it once you confirm.

## Edits by file

### `CS_refiner_v2_wacom.m`
- `filename(1:end-11)` (×2) → `stripSuffix(filename,'_CSdata.mat')`

### `CSaverager.m`
- `filename(1:end-11)` → `stripSuffix(filename,'_CSdata.mat')`

### `CSaveragerNoDeff.m`
- `filename(1:end-11)` → `stripSuffix(filename,'_CSdata.mat')`

### `CSellipseAnalysis.m`
- `filename(1:end-11)` → `stripSuffix(filename,'_CSdata.mat')`

### `CSensemble1.m`
- `filename(1:end-11)` → `stripSuffix(filename,'_CSdata.mat')`

### `CSensemble2.m`
- `filename(1:end-11)` → `stripSuffix(filename,'_CSdata.mat')`

### `CSrefiner1.m`
- `filename(1:end-10)` → `stripSuffix(filename,'CSdata.mat')`
- `fullfile(pwd,'CSData',` → `fullfile(pwd,'CSdata',`

### `CSrefiner2.m`
- `filename(1:end-10)` (×2) → `stripSuffix(filename,'CSdata.mat')`
- `fullfile(pwd,'CSData',` → `fullfile(pwd,'CSdata',`

### `CSrefiner2_wacom.m`
- `filename(1:end-10)` (×2) → `stripSuffix(filename,'CSdata.mat')`
- `fullfile(pwd,'CSData',` → `fullfile(pwd,'CSdata',`

### `CSrefiner3_wacom.m`
- `filename(1:end-10)` → `stripSuffix(filename,'CSdata.mat')`
- `fullfile(pwd,'CSData',` → `fullfile(pwd,'CSdata',`

### `CSrefinerNoDeff.m`
- `filename(1:end-10)` (×3) → `stripSuffix(filename,'CSdata.mat')`
- `fullfile(pwd,'CSData',` → `fullfile(pwd,'CSdata',`

### `CStabulator.m`
- `filename(1:end-11)` → `stripSuffix(filename,'_CSdata.mat')`

### `ContactSiteMapper.m`
- `filebase=CellTracks.file(1:end-7);` → `filebase=cellBase(CellTracks.file);`
- `SF=20.48/size(imG,1);` → `cfg=cs_config(); SF=20.48/size(imG,1); %#ok<NASGU> % FLAGGED: NoDeff uses cfg.SnapFOV_um(=27.61); set SF=cfg.SnapFOV_um/size(imG,1) if 20.48 is stale`

### `ContactSiteMapperNoDeff.m`
- `filebase=CellTracks.file(1:end-7);` → `filebase=cellBase(CellTracks.file);`
- `SF=27.61/size(imG,1);` → `cfg=cs_config(); SF=cfg.SnapFOV_um/size(imG,1);`

### `DensityVisualization.m`
- `Bins=PixSize*(1:ceil(27.61/(PixSize/1000))+1);` → `cfg=cs_config(); Bins=PixSize*(1:ceil(cfg.FOV_um/(PixSize/1000))+1);`

### `Final/CS_builder.asv`
- removed: (MATLAB autosave file)

### `Final/CS_builder.m`
- `filebase=filename(1:end-7);` → `filebase=cellBase(filename);`

### `Final/CS_builderMitoOnly.m`
- `filebase=filename(1:end-7);` → `filebase=cellBase(filename);`

### `Final/CS_builderNoJBM.m`
- `filebase=filename(1:end-7);` → `filebase=cellBase(filename);`

### `Final/CS_builder_v2.m`
- `filebase=filename(1:end-7);` → `filebase=cellBase(filename);`

### `Final/Reorganize.m`
- `CS2(i).file=CS1(i).file(1:end-7);` → `CS2(i).file=cellBase(CS1(i).file);`

### `Final/Revision/CS_builder.m`
- `filebase=filename(1:end-7);` → `filebase=cellBase(filename);`

### `LocDensityFigIntUse.m`
- `Bins=PixSize*(1:ceil(27.61/(PixSize/1000))+1);` → `cfg=cs_config(); Bins=PixSize*(1:ceil(cfg.FOV_um/(PixSize/1000))+1);`

### `QuickPlotterTracks.m`
- `filebase=filename(1:end-7);` → `filebase=cellBase(filename);`

### `WorkingCode/QuickPlotterTracks.m`
- `filebase=filename(1:end-7);` → `filebase=cellBase(filename);`

### `WorkingCode/QuickPlotterTracksOptovar.m`
- `filebase=filename(1:end-7);` → `filebase=cellBase(filename);`

---

## Orientation fix (display-only) — added after user QC

### `LocDensityFigIntUse.m`
- Figure 1 (localization tile, `histogram2 'tile'`) was drawn Cartesian (Y up),
  while Figure 3 (density, `imshow`), the saved `Density_*.tif`, and the raw
  mito/ER TIFFs are all image-convention (Y down). The two figures therefore
  appeared vertically mirrored ("rotated").
- **Fix:** added `set(gca,'YDir','reverse');` to Figure 1 so it matches the
  Y-down microscopy convention used everywhere else in the suite.
- **Scope:** display-only. The saved density TIFF and every coordinate-to-pixel
  mapping in `ContactSiteMapper.m` are unchanged, so contact-site detection and
  all `.mat` outputs are bit-identical. Verified against real data
  (250408_FFAT_006): the dense cluster sits upper-right in both figures after
  the fix. Diagnosis figure: orientation_diagnosis.png.
