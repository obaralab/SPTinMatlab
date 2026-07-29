# TrackStruct layout — audit and plan for hundreds of cells

All numbers below are **measured** on the real WithER cell (`250408_WT_012`, 838 tracks, nF 381,
73,994 localizations) on an M3 Max / MATLAB R2024b, not estimated.

## Where it stands today

| | |
|---|---|
| on disk (v7.3/HDF5) | **11.9 MB** |
| in RAM after `load` | **70.7 MB** (5.93× inflation) |
| actual information content | **6.3 MB** |
| occupancy | **23.2%** (73,994 real of 319,278 slots) |
| NaN padding | **66.5%** of RAM (47.0 MB) |
| exactly-derivable fields | **46.9%** of RAM (33.1 MB), recompute in **0.024 s** |
| fields with **zero readers** repo-wide | 8 fields = 39.7% of RAM |
| `load()` time | **51 ms** |

At **one** cell none of this matters — 51 ms to load, 0.11 ms for a full `isfinite` scan. The padded
layout is not costing measurable time today.

## Why hundreds of cells changes the answer

`Tracks` is a struct **array over cells**, all cells in one `.mat`, each cell carrying its own
`[nF_k × nT_k]` padded planes. Size follows

```
bytes ≈ 200 × nF × nT     per cell     (25 double planes + 2 logical)
```

| scenario | RAM |
|---|---|
| 1 cell (today) | 70.7 MB |
| **200 cells** | **~14 GB** — and `load` needs two live copies, so ~28 GB peak |
| one 5,981-frame track in any cell | that cell alone becomes **1.0 GB** at 1.5% occupancy |

Two independent walls. The first is the aggregate; the second is that **`nF` is set by the single
longest track**, so one outlier track inflates every column of its cell by 130×. Your movie is 5,981
frames — this is currently held off only by curation.

Meanwhile the real access pattern is **per cell**: Tool 3's picker works one cell at a time
(`onCell()` caches its flat arrays), and the `cs_*` drivers iterate cells. Nothing needs all cells
resident at once.

## The blocker on any layout change

**`nF` is the column stride of persisted `sub2ind` linear indices.** `ContactSiteMapper` and
`cs_refine` store `find(mnID)` / `sub2ind(size(...))` results into `analysis/CSdata/*.mat`,
`analysis/TrackData/*.mat` and `CSW_final.mat`. Change `nF` — by trimming padding, going ragged, or
merely re-curating to a different longest track — and every stored index silently points at a
**different localization**. No error, wrong answers.

Two secondary hazards:

- `ContactSites_robust/CellAccumulator.m:11` does `Tracks(i) = CellTracks`, which throws
  `Subscripted assignment between dissimilar structures` on any field add or removal. This is the
  exact failure a previous session hit.
- The shape guards in `spt_analyze_app.m:279-280` and `cs_window_picker.m:229-231` test
  `isequal(size(field), [nF nT])` and **fall back to NaN/false silently** when it stops matching.

Only three fields are frozen by the robust/pristine suite: `file`, `matrix`, `vector`.

## Staged plan

### Stage 1 — one file per cell *(do this first; solves the RAM wall, zero format risk)*

```
analysis/cells/<base>.mat        % one scalar-struct Tracks per cell, fields unchanged
analysis/cells_index.mat         % manifest: base, nTracks, nF, nLoc, hasER, hasMito, frameInterval
```

with a loader that fetches on demand and caches one or two cells. **`nF`, field names and shapes are
untouched**, so no consumer breaks and no stored index is invalidated.

Peak RAM at 200 cells goes from ~14 GB to ~70 MB × cells-held. This is the change that actually
matters at your scale, and it is the cheapest one to get right.

### Stage 2 — stop storing derived fields *(−30 MB/cell)*

Drop `center`, `rawSteps`, `rawVector`, `steps`, `CSDnorm`, `MSDerror`, `MSDstdev`, `MSDdata`,
`lengths` and rehydrate on load (0.024 s). **Keep `vector`** (read by `CS_builder` in the robust
suite) and **keep `CSD`** (read by `spt_pipeline_app`). Requires patching `CellAccumulator` to assign
field-by-field, and rebuilding everything so no old/new field sets meet.

Two traps found while verifying the derivations, which mean existing code may already be wrong:
`center` is displacement from the track's **first point**, not its centroid; and `vector` is **not a
unit vector** — it is velocity in µm/frame.

### Stage 3 — single precision *(−2× on the per-localization arrays)*

Max double→single round-trip error on coordinates is **0.00095 nm**, against 30 nm localization
precision — 31,500× below the noise floor. Frames are integers 0…5980 and fit `uint16` exactly.
Moderate risk: single/double mixing downstream, and the shape guards would not catch a class change.

### Stage 4 — CSR / ragged *(−4.3× RAM, −6–8× disk; removes the nF explosion entirely)*

Store per-localization data as `[nLoc × k]` plus per-track `start`/`len`. **All 838 tracks are
gap-free** (verified), so `start + length` describes every track exactly, with no bookkeeping
overhead. A 5,981-frame track then costs 5,981 rows instead of 5,981 × nT.

**Do not attempt this without first version-stamping `nF` into the struct and migrating or
invalidating every stored linear index** in `CSdata/`, `TrackData/` and `CSW_final.mat`.

## Not worth doing

- **Optimizing load time.** It is 51 ms. Any pitch aimed at I/O is aesthetic.
- **`matfile` partial loading, as things stand.** It fails with
  `MATLAB:MatFile:NotSmoothIndexing — MatFile objects only support '()' indexing`, because
  everything lives inside one scalar struct. Storing fields as top-level variables would enable
  16–18 ms single-field reads, but that is an argument for Stage 1/4, not a standalone change.
- **A columnar rewrite *today*, at one cell.** Measured payoff is ~1 ms per operation against a
  multi-file blast radius. It becomes correct at Stage 4, for the scale reason, not the speed one.

## Correctness notes (fixed 2026-07-28)

- **MSD is correct.** A brute-force per-track pair loop over 5,501 (lag, track) values agrees to
  8.9e-16. Time-averaged over all pairs, binned by integer **frame** lag, so gaps are handled.
- **CSD was wrong** — it summed `dS1./dT1` (a per-frame speed), so a gap-closed step contributed
  half the distance actually covered. 86.6% of tracks contain a 2-frame gap; total path length ran a
  median 2.0% low, up to 11.5%. Now `cumsum(dS1)`.
- **MSDerror was wrong** — divided by the number of *tracks* with a finite MSD at that lag rather
  than the pair count for that track. Error bars were a median 4× too small. Now
  `MSDstdev./sqrt(cntSD)`.

Existing `TrackStruct.mat` files carry the old CSD/MSDerror and need a rebuild.
