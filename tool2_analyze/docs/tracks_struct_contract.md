# `Tracks` struct — field contract

Derived from `TrackImporterCJO_2024v1.m` (producer) and a full grep of the
ContactSites suite (consumers). This pins exactly what the new direct importer
must reproduce, and what it must **not** try to produce (fields added later by
JBM/ChrisC/CS steps).

`Tracks` is a `1×nFiles` struct array — one element per tracked movie.

## Geometry convention (load-bearing — verified against downstream use)

- **`matrix` is `m × n × 3`**: `m` = max track length (rows, per-localization
  index), `n` = number of tracks (columns), `3` = **(t, x, y)** on the third
  dim. Unused cells are `NaN`.
- Confirmed by `CS_builder`: `CSmatrix = cat(3, matrix(:,tr,1),
  matrix(:,tr,2)-refCenter(1), matrix(:,tr,3)-refCenter(2))` — dim3 index 1 is
  time, 2 is x, 3 is y; refCenter (x,y) is subtracted from planes 2 and 3.
- Units: `x`,`y` in **µm** (TrackMate calibrated output); `t` (plane 1) is the
  **integer FRAME index** under the default `TimeUnit='frame'` — *not* seconds.
  See the "Units & the time-vs-step distinction" section below — this is
  load-bearing for MSD lag-binning.

## Units & the time-vs-step distinction (apply `dt` in exactly ONE place)

There are **three different quantities** in the struct, in three different
units. Conflating them is the classic way MSD/Deff go wrong. Keep them straight:

| Quantity | Where | Unit | Never multiply by `dt`? |
|----------|-------|------|--------------------------|
| **Time axis** | `matrix(:,:,1)` (plane 1) | **integer frame index** | it *is* the pre-`dt` time; `dt` converts it to seconds |
| **Row / step index** | the matrix **row number** | count (1,2,3…) | n/a — it's just position-in-track |
| **Spatial displacement** | `rawVector`, `rawSteps(:,:,2)`, `steps` numerator | **µm** | **yes — never.** Pure space, `dt` must not touch it |

### Calibration for THIS microscope (verified against real data)
- Pixel size **0.10785 µm/px**, FOV **27.61 µm** (256 px), frame interval
  **`dt = 0.020064 s`** (TIFF `finterval` / XML `frameInterval`; the CS suite
  rounds to 0.020 s — use the exact value if you want Deff to 0.3 %).
- `x`,`y` are already in µm in the CSV/XML, so the struct carries µm directly —
  no pixel multiply anywhere in the importer.

### Why time is stored as FRAME, not seconds
The MSD lag loop bins with `(DeltaT == j)` where
`DeltaT = matrix(1+j:m,:,1) - matrix(1:m-j,:,1)`. That integer equality only
holds if plane 1 is the **frame index**. If it held seconds (0.0201, 0.0402, …)
the comparison would never be true and `MSD` would come out empty. This is why
`TimeUnit='frame'` is the default and is what reproduces the legacy struct
bit-for-bit. `TimeUnit='seconds'` exists but breaks lag-binning — use only if a
downstream step explicitly wants seconds in plane 1 and does its own binning.

### Frame index ≠ row index (gap safety)
A track that starts at frame 19 has its 1st **row** = frame **19**. Because the
true frame lives in plane 1, an MSD lag of `j` always means `j` real frames of
elapsed time — even across a dropped frame. Do **not** use the row number as
time. (This dataset is gapless, `all(diff(frame)==1)`, so the two coincide up to
the start offset — but the code is correct for gapped tracks regardless.)

### Converting to physical units downstream
```matlab
dt = 0.020064;                          % exact frameInterval (s)
lag_frames  = 1:size(Tracks(1).MSD,2);  % MSD columns are lags in FRAMES
lag_seconds = lag_frames * dt;          % <-- convert lag to seconds HERE, once
% MSD itself is already µm². 2D Deff from short-lag slope: MSD ≈ 4·D·t
%   fit MSD(µm²) vs lag_seconds(s); D = slope/4  -> µm²/s
% Per-track lengths (NOT the survival curve):
L = sum(~isnan(Tracks(1).matrix(:,:,2)), 1);   % 1×n, sum along dim 1 (rows=steps)
```
> **Gotcha:** `sum(~isnan(matrix(:,:,2)), 2)` sums across *tracks* and returns a
> length-`m` survival curve (how many tracks reach each step), **not** per-track
> lengths. Sum along **dim 1** for track lengths.

## Fields the importer MUST produce

| Field | Shape | Meaning | Formula (from TrackImporterCJO_2024v1.m) |
|-------|-------|---------|------------------------------------------|
| `file` | char | movie base name | see naming note below |
| `lengths` | `n×1` | real length of each track | count of spots per track |
| `matrix` | `m×n×3` | (t,x,y) per loc per track | assembled from spots grouped by track |
| `center` | `m×n×3` | matrix minus each track's first point | `matrix - matrix(1,:,:)` |
| `rawSteps` | `(m-1)×n×2` | plane1 = Δt, plane2 = Δdisplacement | consecutive-frame `DeltaT`, `DeltaS` |
| `steps` | `(m-1)×n` | speed = Δs/Δt | `DeltaS(:,:,1)./DeltaT(:,:,1)` |
| `CSD` | `(m-1)×n` | cumulative squared? (cumulative step displacement) | `cumsum` of `steps` over lag |
| `CSDnorm` | `(m-1)×n` | CSD normalized to each track's total | `CSD ./ Totals` |
| `MSDdata` | `(m-1)×n×(m-1)` | per-lag displacement stack | `(DeltaT==j).*DeltaS` |
| `MSD` | `n×(m-1)` | mean displacement per lag | `mean(MSDdata,1,'omitnan')` transposed |
| `MSDstdev` | `n×(m-1)` | std per lag | `std(MSDdata,1,'omitnan')` |
| `MSDerror` | `n×(m-1)` | SEM per lag | `MSDstdev ./ sqrt(N)` |
| `rawVector` | `(m-1)×n×2` | (Δx, Δy) per step | `diff(matrix(:,:,2/3),1,1)` |
| `vector` | `(m-1)×n×2` | velocity = rawVector/Δt | `rawVector ./ rawSteps(:,:,1)` |

> **Naming note.** `Tracks(i).file` must carry the movie base name **plus the
> trailing token the CS suite strips**: `CS_builder` does
> `filebase=filename(1:end-7)` (drops a 7-char suffix), other scripts use
> `end-11`/`end-10`. The 2024 importer set `.file` to the `.xlsx` basename. The
> new importer will set `.file` from the TIFF/CSV base name and expose the
> suffix convention as a documented parameter so downstream stripping still
> lands on `<base>`.

## Fields the importer must NOT produce (added downstream)

| Field | Added by | Source |
|-------|----------|--------|
| `Deff` | `CS_builder_v2.m` | JBM diffusion analysis |
| `LocIndex` | `CS_builder_v2.m` | JBM tessellation |
| `MitoCSindex` | `Part2.m` | CS indexing loop (per AfterTracking instructions) |
| `segID` | external | ChrisC segmentation `.mat` |
| `cp` | external | ChrisC change-point `.mat` |
| `CCindex` | external | ChrisC ID `.mat` |

These are optional/JBM-dependent (the `*NoDeff` script variants exist precisely
for when JBM data is absent). The importer produces the base struct; these get
merged in later exactly as they do today.

## Consumer frequency (grep of the 75-file suite)

`matrix` 63× · `Deff` 34× · `MitoCSindex` 23× · `file` 18× · `vector` 7× ·
`LocIndex` 7× · `segID` 6× · `cp` 6× · `CCindex` 6× · `rawVector` 3× ·
`rawSteps` 3× · `steps` 1× · `lengths` 1× · `center` 1× · `MSDdata` 1×.

→ The importer's correctness hinges most on **`matrix`** (and the `vector`/
`rawSteps` derived from it); MSD/CSD are used less but must still match the
legacy formulas for reproducibility.
