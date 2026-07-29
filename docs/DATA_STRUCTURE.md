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

## How much this actually grows

`Tracks` is a struct **array over cells**, all cells in one `.mat`, each cell carrying its own
`[nF_k × nT_k]` padded planes:

```
bytes ≈ 200 × nF × nT     per cell     (25 double planes + 2 logical)
```

**`nF` does not run away.** It is set by the longest track, and photobleaching bounds that — measured
here, lengths run 50…381 with a mean of 88, so occupancy is `mean/max` = 23% and stays there. An
earlier draft of this document warned about a 5,981-frame track inflating a cell to 1 GB; that is not
a realistic failure mode for bleaching-limited SPT, and the padding is better understood as a
**constant ~4× overhead**, not an explosion risk. The size guard in `TrackImporter_direct` is a
backstop for pathological input, not an expected event.

So the growth term is **cells per project folder**, and it is linear:

| cells in one project folder | resident | with the Contact-sites tab open (see below) |
|---|---|---|
| 1 (today) | 70.7 MB | ~141 MB |
| 20 | 1.4 GB | 2.8 GB |
| 50 | 3.5 GB | 7.0 GB |
| 200 | 14 GB | 28 GB |

## How Tool 3 actually loads it — and the one real waste

`ensureTracksLoaded()` (`spt_analyze_app.m:251`) loads **the whole `<project>/analysis/TrackStruct.mat`**
— every cell of that project — into `buildTracks`. Then the Contact-sites tab calls
`cs_window_picker(pnCS, anaDir, …)`, and the picker **loads the same file again** independently
(`cs_window_picker.m:37-42`) and keeps it as `st.Tracks`.

Two independent `load` calls, two full copies resident at once. That is the right-hand column above,
and it is the cheapest thing to fix in this whole document: pass the already-loaded struct into the
picker instead of re-reading it. Halves Tool 3's footprint for a few lines of change.

Within the picker the access pattern is already correct: `onCell()` flattens **one** cell (1.8 ms) and
caches the flat arrays; everything after that works columnar.

## Comparing cells across conditions — the scaling layer already exists

There are two paths, and only one of them scales.

**Use the Experiment + Compare tabs.** The manifest **references** each day/batch folder and
*never merges the TrackStructs* (`spt_analyze_app.m:1580-1581` says so in as many words: "This is the
scaling layer for many cells/conditions"). `cs_experiment_aggregate` reads each folder's
`CSW_final.mat` and `cs_window_dwell.mat`, tags every site and event with that cell's `condition` and
source folder, and concatenates the **results** — which are small. Compare then groups by condition
across the whole dataset. No raw track data is ever merged, so this is flat in memory no matter how
many cells the experiment contains.

**Avoid `combine_trackstructs` at scale.** It merges N TrackStructs into one struct array so the
contact-site pipeline runs over everything at once. That is exactly how you land in the bottom row of
the table above. It remains fine for combining a handful of cells that must be analysed as one unit.

The practical consequence: **keep project folders per day/condition with a manageable number of
cells, and compare across them through the Experiment manifest.** Tool 3 is a per-project tool, so the
number that matters is cells-per-folder, not cells in the study.

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

Ordered by payoff per unit of risk, after the corrections above. Stages 0 and 1 are worth doing;
2–4 are only worth it if cells-per-folder grows past what the manifest workflow keeps it at.

### Stage 0 — stop loading the same file twice *(do this first: −50% of Tool 3's RAM, a few lines)*

Pass the app's already-loaded `buildTracks` into `cs_window_picker` instead of having it re-`load`
the same `TrackStruct.mat`. Keep the current `load` as the fallback for when the picker is used
standalone. No format change, no consumer affected.

### Stage 1 — one file per cell *(worth it once a folder holds tens of cells)*

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
