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

| cells in one project folder | resident |
|---|---|
| 1 (today) | 70.7 MB |
| 20 | 1.4 GB |
| 50 | 3.5 GB |
| 200 | 14 GB |

**Opening the Contact-sites tab no longer doubles this.** It used to — that was Stage 0, and it has
since shipped; see below.

## How Tool 3 actually loads it

`ensureTracksLoaded()` (`spt_analyze_app.m:310`) loads **the whole active build** — every cell of that
project, resolved through `cs_active_trackstruct` — into `buildTracks`. The Contact-sites tab then
hands that struct straight to the picker as `opts.Tracks` (`spt_analyze_app.m:439-441`), and
`cs_window_picker` uses it as `st.Tracks` (`cs_window_picker.m:39-50`), falling back to `load` only
when no struct was passed — i.e. when the picker is driven standalone.

One `load`, one copy. Nothing in the picker writes `st.Tracks` (it is only read, at
`cs_window_picker.m:189, 200, 727, 742, 780`), so MATLAB's copy-on-write shares the data rather than
duplicating it.

Within the picker the access pattern is already correct: `onCell()` (`cs_window_picker.m:198`)
flattens **one** cell (1.8 ms) and caches the flat arrays; everything after that works columnar.
Those per-cell flat vectors are the only thing the picker adds on top of the table above — megabytes
for the selected cell, not a second project.

## Comparing cells across conditions — the scaling layer already exists

There are two paths, and only one of them scales.

**Use the Experiment + Compare tabs.** The manifest **references** each day/batch folder and
*never merges the TrackStructs* (`spt_analyze_app.m:1644-1646` says so in as many words: "This is the
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

**`nF` is the column stride of persisted `find` / `sub2ind` linear indices.** In the live flow
`cs_window_mapper` stores `find(mnID)` as each site-window's `LocIDs` (`cs_window_mapper.m:208, 242`)
into `CSW_final.mat`. The legacy `run_contactsite_analysis` path does the same into
`analysis/TrackData/*.mat` and `analysis/CSdata/*.mat`
(`ContactSites_robust/ContactSiteMapper.m:70-71`, `cs_refine.m:830`). Change `nF` — by trimming
padding, going ragged, or merely re-curating to a different longest track — and every stored index
silently points at a **different localization**. No error, wrong answers.

Two secondary hazards:

- `ContactSites_robust/CellAccumulator.m:11` does `Tracks(i) = CellTracks`, which throws
  `Subscripted assignment between dissimilar structures` on any field add or removal. This is the
  exact failure a previous session hit.
- The shape guards in `spt_analyze_app.m:341-342` and `cs_window_picker.m:237-239` test
  `isequal(size(field), [nF nT])` (or `size(M(:,:,1))`) and **fall back to NaN/false silently** when
  it stops matching.

Only three fields are frozen by the robust/pristine suite: `file`, `matrix`, `vector`.

## Staged plan

Ordered by payoff per unit of risk, after the corrections above. Stage 0 is done; Stage 1 is worth
doing; 2–4 are only worth it if cells-per-folder grows past what the manifest workflow keeps it at.

> These `Stage 0…4` are **layout-refactor** stages of this document's own plan. They are not pipeline
> stages and do not correspond to them. The pipeline's stages are a separate axis, documented at the
> end of this file under *[The pipeline's own stages](#the-pipelines-own-stages--what-each-consumes-produces-and-costs)*.

### Stage 0 — stop loading the same file twice ✅ **DONE** *(−50% of Tool 3's RAM)*

Shipped. `onLaunchCS()` passes the app's already-loaded `buildTracks` to the picker as `opts.Tracks`
(plus `opts.tsFile`, the active build's path), and `cs_window_picker` takes it as `st.Tracks` when
it is non-empty. The `load` survives only as the standalone fallback, and it now resolves through
`cs_active_trackstruct(anaDir)` — so a standalone picker opens the same **named** build the app
would have. No format change, no consumer affected.

Side benefit beyond the RAM: the picker can no longer analyse a different build from the one on
screen, because it is handed the exact struct the app holds.

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

---

# The pipeline's own stages — what each consumes, produces and costs

Everything above is about **one** file, `analysis/<build>.mat`. This part follows the data out of it,
through the four stages Tool 3 runs, to the files the Compare tab reads. Same rules as above: every
number is either measured out of the repo with the derivation shown, or explicitly marked as not
measured.

Measurements here are on `/Users/safal-mac/Documents/IntegratedPipeline/Project/analysis` — the only
folder in the tree that has actually been through all four stages — read straight out of the HDF5
with `h5py`, no MATLAB. That build holds **2 cells**: `250408_FFAT_001_spt1` (nT 477, nF 366,
34,701 localizations, 19.9% occupancy) and `250408_WT_010_spt1` (nT 1295, nF 334, 96,183
localizations, 22.2%). Its `CSW_final.mat` carries **16 site-windows** over **300** member tracks and
**7,121** member localizations; its dwell run found **946** events.

## The numbering, and a collision worth naming

**The code does not number the pipeline stages 1–4 anywhere.** Four different numberings coexist in
the tree, and they disagree:

| where | the numbering | "Contact sites" is |
|---|---|---|
| runtime tab labels, Tool 3 `'analyze'` (`spt_analyze_app.m:139-149`) | 1 Experiment · 2 Contact sites · 3 Refine · 4 Sites · 5 Dwell · 6 Compare | **tab 2** |
| runtime tab labels, `'full'` mode (same lines) | Experiment · Import&Curate · Build&QC · Contact sites · Refine · Sites · Dwell · Compare | **tab 4** |
| the source's own section comments (`spt_analyze_app.m:221, 463, 537, 947, 1366, 1715, 1727`) and `PIPELINE.md §7` | Import&Curate 1 · Build&QC 2 · Contact sites 3 · Refine 4 · Sites 5 · Dwell 6 · Experiment 7 · Compare 8 | **"Tab 3"** |
| `run_pipeline.m:11-19` (legacy CLI driver) | acquisition-anchored 0–6; the MATLAB work is stages **5** and **6** | not a tab |

The comment/`PIPELINE.md` numbering is the pre-*Experiment-first* order. Since Experiment was moved
to position 1 **in every mode** (`spt_analyze_app.m:136-139`) those comments are off by one in `'full'`
mode and off in the other direction in Tool 3 — `spt_analyze_app.m:951` still says the mapper reads
"csIDs (from Tab 3)" and writes "the file Tabs 5–6 read", which was true of the old layout. **Follow
the runtime labels.**

What the code *does* name and count is the six filesystem-derived **stage lamps** in
`cs_experiment_status.m:11-18`:

```
tracked · curated · built · picked · mapped · dwelled
```

Three of those are upstream of Tool 3 (`tracked`, `curated` = Tools 1/2; `built` = Tool 2's
`build_trackstruct`). Three are Tool 3's: `picked`, `mapped`, `dwelled`. **Refine has no lamp and no
count** — it is optional, and nothing in `cs_experiment_status` looks at `CS_footprints.mat` or
`CS_trackedits.mat` at all, so a manifest cannot tell you whether a folder's footprints were
hand-edited. That is a real gap, not a simplification.

So the four stages Tool 3 runs after the hand-off (Stage 0 of the plan above) are, in execution
order, **pick → refine → map → dwell**. They are numbered 1–4 below because they need names to be
referred to; **the numbering is this document's, not the code's.**

## Stage 1 · pick — Contact-sites tab → `cs_window_picker`

### Consumes

- The `Tracks` struct **already in RAM** (`opts.Tracks`, `spt_analyze_app.m:511-513`) — the hand-off.
- Per-cell ER/mito segmentation stacks, via `opts.segResolver`; only the **window start frame** page
  of each is read (`cs_window_picker.m:257-264`), never the whole stack.
- `analysis/mips/<prefix>_er_mip.tif` — whole-movie ER support, the fallback when a window's
  start-frame mask is missing (`:245-255`).
- `analysis/Densities/*_rho.tif` — **for its height only** (`:192-196`), which sets the density grid.

### The grid — one number that sizes everything downstream

```
grid = ceil(FOV_um / (binNm/1000)) = ceil(27.61 / 0.030) = 921        (cs_window_picker.m:193)
SF   = FOV_um / grid              = 27.61 / 921 = 0.029978 µm/px      (:52, cs_default_gridsf.m:6)
```

Measured: all three `Project/analysis/Densities/*_rho.tif` are **921 × 921** RGB TIFFs, 2,565,718 B
each — so the file-derived override agrees with the formula. `cs_default_gridsf.m:6` hardcodes 921 as
its fallback for the same reason.

One grid plane costs `921² × 8 = 6,785,928 B = **6.79 MB**`. That constant drives Stages 1–3.

### Produces

| file | variables / format |
|---|---|
| `analysis/csIDs/<base>_CSsites.txt` | text, 8 tab-separated columns, header ` ⇥X⇥Y⇥XM⇥YM⇥Slice⇥Counter⇥Count` (`:757-760`). One row per site across **all** windows: index; `X`,`Y` = pick in **density px**; `XM`,`YM` = the same values repeated (the paper format's "refined" columns — `cs_read_sites.m:10` prefers them); `Slice` = **1-based window index**; `Counter` = 1 mito / 2 non-mito; `Count` = 0 placeholder |
| `analysis/Density_<base>_CSwindows.mat` | `windows`, a scalar struct (`:763-765`): `framesPerWindow` (frames), `nWindows`, `ranges` `[nW × 2]` **inclusive, 0-based** frame bounds, `grid` (px), `SF_umPerPx` (µm/px), `frameInterval` (s), `source` (`'tracked'`) |
| `analysis/csIDs/<base>_CSsites_provenance.json` | the full detection parameter set + `nSites` (`:768-776`) |
| `analysis/csIDs/<base>_CSsites_stats.csv` | 14 columns, one row per site: `pval, enrich, nLocs, nTracks, stability, dwell_pct, area_um2` … (`:780-789`) |
| `analysis/Densities/<cell>_rho.tif`, `Density_<cell>.mat`, `Density_<cell>.tif` | written **on launch** behind the *save density files* checkbox (`spt_analyze_app.m:499-503`), one set per cell, for the legacy mapper. `Density_<cell>.mat` holds a single variable `imG`, `[921 × 921]` double |

Measured sizes: `250408_WT_012_spt1_CSsites.txt` = **962 B for 23 sites ≈ 42 B/site**; the legacy
density triple for that cell = 2,565,718 + 4,347,502 + 1,088,046 = **~8.0 MB per cell on disk**, and
`imG` is 6.79 MB resident. Nothing reads the `_rho.tif` except `pickGrid` / `cs_default_gridsf`, and
they read its **height**.

The two files downstream actually depends on are the first two, and only these fields:
`Xpx/Ypx` (cols 4/5), `Slice`, `Counter`; `windows.ranges`, `.SF_umPerPx`, `.grid`, `.source`.
`source` **locks** the mapper's density source — the mapper overrides its own `opts.src` with it
(`cs_window_mapper.m:129`).

**The failure mode is the missing file, and it is silent.** With no
`Density_<base>_CSwindows.mat`, `cs_load_windows.m:19-20` returns one `[-Inf Inf]` whole-movie window
per distinct `Slice`, with no warning, and every window-resolved number downstream quietly becomes a
whole-movie number. That is the state of the repo right now: `Project/analysis/csIDs` holds three
`_CSsites.txt` files, there is no `*_CSwindows.mat` anywhere, and every row of
`cs_window_metrics.csv` reads `f0 = -Inf, f1 = Inf, window = 1`.

### In memory

Per selected cell, `onCell()` flattens the build's `matrix` into 7 vectors over the cell's finite
localizations (`:225-243`): `aX aY aF aMD aT` double + `aConf aSC` logical = `5×8 + 2 = **42 B per
localization**`. For the two `Project` cells that is 34,701 × 42 = 1.46 MB and 96,183 × 42 = 4.04 MB.
Small, and only one cell at a time.

The real allocation is the **per-window cache** (`:308`), filled lazily:

| cached per window | size |
|---|---|
| `wrc` raw counts `[921 × 921]` double | 6.79 MB |
| `wdens` smoothed `[921 × 921]` double | 6.79 MB |
| `werM` ER mask `[921 × 921]` logical | 0.85 MB |
| `wmitoM` mito mask `[921 × 921]` logical | 0.85 MB |
| `wnull` MC null maxima, `M = 300` doubles | 2.4 KB |
| **per window** | **≈ 15.3 MB** |

`MAXPANELS = 24` (`:33`) caps the window count, so the picker's ceiling is
`24 × 15.27 = **366 MB**` on top of the shared `Tracks` — reached only after every window has been
drawn *and* detected on, since the masks and the null are filled on demand. **This is a function of
`grid²` and the window count alone — not of cells, not of tracks, not of sites.** Doubling
localization precision from 30 nm to 15 nm doubles `grid` and so **quadruples** it.

### Cost — time

Not measured; MATLAB was not run for this document. What is certain from the code: the unit of work
is `imgaussfilt` over the 848,241-pixel grid. Opening a cell draws one thumbnail per window, each
forcing one `accumarray` + one `imgaussfilt` (`:334-347` → `:313-321`). One **Detect** with the
default ER-Monte-Carlo method adds `M = 300` more — `cs_mc_threshold.m:35-44` runs one `accumarray`
plus one full-grid `imgaussfilt` per realization. So Stage 1 is

```
O(nWindows · grid²  +  nDetects · M · grid²)     and independent of cells and tracks
```

The null is cached per window (`:325-328`) and invalidated by a change of density channel (`:691`) or
of `M` (`:716`), so browsing back to a window is free but switching channel is not.

**One full-grid smoothing per window is computed and thrown away.** `cs_window_density` returns
`[rawCounts, Dens]` and its last line, `Dens = imgaussfilt(rawCounts, sig)` (`cs_window_density.m:39`),
is **not guarded by `nargout`**. `windowRaw` asks for the first output only
(`rc = cs_window_density(…)`, `cs_window_picker.m:316`), so it pays that `imgaussfilt` and discards
the result; `windowDensity` then smooths the cached `rc` a second time (`:321`). Because `st.wrc{w}`
is cached, the waste is exactly **one wasted `imgaussfilt` per window per cache fill** — so
`nWindows` of them on opening a cell, and `nWindows` again on each density-channel change, but none
during Detect (`cs_mc_threshold` receives the already-cached `rc`). At 24 windows that is 24 wasted
passes over 848,241 pixels against the 24 useful ones: the thumbnail draw does **twice** the
smoothing it needs. Adding `if nargout > 1` would fix it without touching any caller —
`cs_footprints_build.m:56` uses the `[~,Dens]` form and would be unaffected. I did not measure what
one `imgaussfilt` at this size costs, so I cannot say what fraction of the open latency this is.

## Stage 2 · refine — Refine tab → `cs_footprints_build` + the editor

Optional. Skip it and the mapper uses its own auto footprint.

### Consumes

`csIDs/<base>_CSsites.txt`, `Density_<base>_CSwindows.mat`, and **the active build, loaded again from
disk** — `cs_footprints_build.m:35` does its own `load(cs_active_trackstruct(anaDir))` and takes no
`Tracks` argument. So opening the Refine tab puts a **second full copy** of the build in RAM beside
the app's `buildTracks`; at the 70.7 MB/cell of the table at the top of this file, that is the
build's whole cost again. The Stage-0 hand-off covers the picker only.

### Produces

`analysis/CS_footprints.mat`, `-v7.3`, two variables (`spt_analyze_app.m:936`): `CSfoot` and
`CSdeleted`. The tab persists **only the sites you actually edited or deleted**; re-opening rebuilds
the full auto list and merges the saved entries back on. Called headless with `'save',true`,
`cs_footprints_build.m:66` writes `CSfoot` alone.

`CSfoot(k)` (`cs_footprints_build.m:58-61`):

| field | shape | units |
|---|---|---|
| `file` | char | cell base name |
| `cellIndex`, `csID`, `window` | scalar | index into the build / positional site index / 1-based window |
| `winFrames` | `[1 × 2]` | inclusive frame bounds (`±Inf` = whole movie) |
| `pickPx` | `[1 × 2]` | the **original** pick, density px — the staleness key |
| `center` | `[1 × 2]` | µm, absolute |
| `refboundary` | `[K × 2]` | µm, **relative to `center`**, closed ring |
| `mode` | char | `halfmax` / `box` / `disk` — the mode actually used, after fallbacks |
| `frac`, `maxRadiusUm` | scalar | the half-max parameters that produced it |
| `SF`, `grid` | scalar | µm/px, px — carried so the geometry is self-describing |
| `densSrc` | char | locked to `windows.source` (`:44-45`) |
| `mito` | logical | from `Counter` |
| `areaUm2` | scalar | `polyarea(refboundary)` |
| `edited`, `deleted` | logical | what the editor changed |

### Downstream dependency, and its guard

The mapper keys overrides on `file|csID|window` (`cs_window_mapper.m:167-186`), which is *positional*
— `csID` is just the row number in `_CSsites.txt`. A re-pick would therefore silently attach old
footprints to different sites, so the override is applied only when the stored `pickPx` is within
**1.5 density px** of the current pick, and skipped with a `staleFootprint` warning otherwise. The
deletion list carries the same guard (`:147-153`).

### Cost

**Memory / disk: kilobytes.** The payload per site is the polygon. Measured from the 16 half-max
`refboundary` rings the mapper stored in `CSW_final.mat`, `K` runs **36–109 vertices**, mean 76
(`Σ K = 1,216`) → `K × 2 × 8` = **0.6–1.7 KB per site**, 19,456 B for all 16 — which is exactly the
`refboundary` total measured in that file, so the count is not an estimate. I cannot quote a measured
`CS_footprints.mat` size: **no `CS_footprints.mat` exists anywhere in the tree**, so the file has never
been written by a real run here.

**Compute: `O(nSites × grid²)`, and that is worse than it needs to be.** One density per (cell,
window), cached in `dcache` (`cs_footprints_build.m:51-56`). Then, per site,
`cs_window_footprint` builds a full-grid `meshgrid` and disk mask (`:48-49`), thresholds the **whole**
grid, and runs `bwselect` / `bwboundaries` / `regionprops` on it (`:76, 84, 104`) — never on a crop.
At `maxRadiusUm = 0.6` the answer lives inside a 20.0 px radius disk (`0.6 / 0.029978`), about
**1,257 px of the 848,241 examined**. Not measured in seconds.

## Stage 3 · map — Sites tab → `cs_window_mapper`

The stage everything else reads. `cs_window_mapper.m:7` calls itself "the foundation stage" and that
is accurate: Sites, Dwell and Compare all read its one output file, which is why each is
independently re-runnable.

### Consumes

`csIDs/<base>_CSsites.txt` · `Density_<base>_CSwindows.mat` (authoritative; whole-movie fallback) ·
`CS_footprints.mat` (optional overrides + deletions) · `CS_trackedits.mat` (optional per-site track
exclusions, `CSexclude`, written by the Sites tab at `spt_analyze_app.m:1244-1258`) · and **its own
`load` of the active build** (`:53`) — the app does not hand it `buildTracks`
(`spt_analyze_app.m:1006-1009` passes footprint options only). Same second copy as Stage 2.

It iterates over **the build's cells**, not over `csIDs/` — a cell with picks but no place in the
active build is skipped with a `noSites`/`noMatrix` warning. Visible in the repo: `csIDs` holds picks
for `250408_WT_012_spt1`, the build does not contain that cell, and `cs_window_metrics.csv` has no
`WT_012` rows.

### Produces

`analysis/CSW_final.mat` (`CSW`, `-v7.3`, `:258`) and `analysis/cs_window_metrics.csv` (14 columns,
one row per site-window, `:276-288`). `CSW` is a **flat struct array, one element per (site, window)**,
36 fields, µm everywhere:

| field | shape | units / meaning |
|---|---|---|
| `file`, `cellIndex`, `csID`, `window`, `siteUID` | char / scalars | provenance; `siteUID` is the 1..N running key Stage 4 joins on |
| `winFrames` | `[1 × 2]` | inclusive frame bounds, `[-Inf Inf]` on the fallback |
| `pickPx` | `[1 × 2]` | density px — the staleness key for refine + track-exclusion |
| `center`, `refCenter` | `[1 × 2]` | µm absolute (identical; `refCenter` is the kernel's name) |
| `refboundary` | `[K × 2]` | µm **relative to `refCenter`** |
| `boundaries` | struct `.x`, `.y` | µm absolute — a compat duplicate of `refboundary` |
| `footprintMode` | char | `halfmax` / `box` / `disk` / `refined[:mode]` |
| `EllipseFit` | struct or `[]` | `CentroidUm`, `Orientation_deg`, `MajorAxisUm`, `MinorAxisUm`; `[]` when refined |
| `tracks`, `nTracks` | `[1 × nT_s]`, scalar | **column indices into the cell's `matrix`** of the member tracks |
| `LocIDs`, `nMemberLocs` | `[nL_s × 1]`, scalar | **linear indices into `[nF × nT]`** — the `nF`-stride hazard flagged above |
| `trackLocsInside`, `trackLocsWin`, `trackPctInside` | `[1 × nT_s]` | per member track: locs in footprint / locs in window / % (dwelling vs passing) |
| `CSmatrix` | `[nF × nT_s × 3]` | plane 1 frame, planes 2–3 x,y in **µm relative to `refCenter`** |
| `MitoFlag` | logical | mito contact site |
| `SF`, `grid`, `binAreaUm2`, `dt` | scalars | µm/px, px, µm², s |
| `areaUm2`, `nLocInside`, `cellTotalLocWin` | scalars | µm², counts from the density source |
| `probMass`, `peakProb`, `peakProbRaw`, `localDens`, `cellBgDens`, `enrichment` | scalars | `csDensMetricOne` outputs |
| `densSrc` | char | which cloud the density came from |

Downstream reads: Stage 4 uses `CSmatrix`, `tracks`, `refboundary`, `winFrames`, `dt`, `siteUID`,
`window`, `MitoFlag`, `file`, `cellIndex`. `cs_experiment_aggregate` reads `.file` only, then tags
each element with `condition` + `srcFolder` and concatenates
(`cs_experiment_aggregate.m:38-54`). Compare groups on `window` / `MitoFlag` / `condition` and plots
`enrichment`, `areaUm2`, `nLocInside`.

### Cost — memory and disk, measured

Read directly out of `Project/analysis/CSW_final.mat`:

| | |
|---|---|
| file on disk (v7.3, deflated) | **854,564 B** |
| array payload inside | **2.529 MB** |
| of which `CSmatrix` | **2.439 MB = 96.4%** |
| next largest field (`LocIDs`) | 0.057 MB (7,121 × 8 B, exactly) |
| `CSmatrix` occupancy | **22.5%** — 22,869 finite of 101,608 slots |
| of those finite coordinates, inside the footprint | **7,121 = 31.1%** |

`CSmatrix` keeps the build's **full `nF` rows** for every member track of every site
(`:217`, `cat(3, Frame(:,tracks), Amat(:,tracks)-cx, Bmat(:,tracks)-cy)`), so

```
bytes(CSW) ≈ 24 × nF × Σ_sites nTracks_site        (3 planes × 8-byte double)
```

Check: `Σ nF·nTracks_site` over the 16 sites = 101,608 slots; `24 × 101,608 = 2,438,592 B` = the
2.439 MB measured. The two cells contribute nF 366 and nF 334, and `Σ nTracks_site = 300`.

**This is the one place `nF` padding is re-paid per site-window instead of once per cell.** An earlier
draft of this section had it re-paid *worse* here — it quoted 7% occupancy and reasoned that a member
track only sits inside a sub-micron footprint for a fraction of the movie. That reasoning describes
the wrong quantity. `CSmatrix` is a straight column copy of the build's `matrix` (`:217`), so it
carries **every** localization of each member track, in-footprint or not, and its occupancy is
therefore the build's own: **22.5%**, against the two cells' 19.9% and 22.2%. (Marginally above both,
because a track has to be long enough to be caught in a footprint to become a member at all — so the
member set skews long, i.e. dense in its column.) The padding multiplier
here is the same constant ~4× as anywhere else; what changes is that it is now paid `Σ nTracks_site`
times instead of `nT` times.

The 7,121 figure is a **different** number — `Σ nMemberLocs`, which is identical to
`Σ trackLocsInside` (both measured 7,121) and is the length of all the `LocIDs` put together. So of
the 22,869 real coordinates stored, 31.1% are inside the footprint and 68.9% are the parts of member
tracks that wander outside it. That is **not** waste: Stage 4 needs the whole trajectory to find where
a run of in-footprint localizations starts and stops. Only the 78,739 NaN slots are.

The growth term is `Σ nTracks_site`, i.e. sites **times** crowding — the 45- and 47-track sites in
`Project` cost `24 × 334 × 46 ≈ 369 KB` each by themselves.

Deflate hides most of it on disk (2.53 MB payload → 0.85 MB file) precisely because the padding is a
uniform NaN field. It does not hide any of it in RAM, and Stage 4 loads all of it.

### Cost — time

Not measured. The shape, from the code: per site, `inpolygon` over **every finite localization of the
whole cell** — `:190-192` builds the mask over the full `[nF × nT]` but calls `inpolygon` on `okxy`
only, so the padding costs a scan and not polygon work, the same asymmetry as Stage 4. What the
padding does cost is temporaries. Six full-size ones are allocated per site: `Ar`, `Br` double plus
`okxy`, `inPoly`, `inWin`, `mnID` logical. For the 1,295-track cell that is `334 × 1295 = 432,530`
elements each — `2 × 3.46 MB + 4 × 0.43 MB` = **8.7 MB per site, reallocated for each of its 9
sites**. One `[grid × grid]` density per (cell, window), cached (`:141, 155-161`). So

```
O(nSites · nLoc_cell  +  nWindows · grid²)
```

One unmeasured hazard worth naming: the output is grown one element at a time
(`CSW(end+1) = e`, `:250`), and so is Stage 4's event list (`ev(end+1) = struct(...)`,
`cs_window_dwell.m:62`). Whether that costs a payload copy or only an element-table copy depends on
MATLAB's struct-array internals, which the repo cannot tell us, and I did not measure it. It is the
first thing to look at if the mapper gets slow at hundreds of sites.

## Stage 4 · dwell — Dwell tab → `cs_window_dwell`

### Consumes

`analysis/CSW_final.mat` and nothing else (`:33-36`). `dt` is the **median** of the positive
`[CSW.dt]` across all site-windows (`:38`) — one representative interval for the whole run, not
per-cell.

### Produces

`analysis/cs_window_dwell.mat` (`DD`, `-v7.3`), `cs_window_dwell.csv`, `cs_window_track_labels.csv`
(`:129-134`). Shapes measured on `Project`:

| field of `DD` | shape here | contents |
|---|---|---|
| `dt` | scalar | s per frame |
| `events` | **946 × 1** struct | one dwell event: `file, cellIndex, csID, window, siteUID, mito, trackCol, entryFrame, exitFrame, dwell` (s) |
| `perTrack` | **300 × 1** | per (site, member track): `label` ∈ `RESIDENT`/`ENTERS`/`EXITS`/`ENTERS+EXITS`, `numDwell`, `longest_s`, `total_s` |
| `perSite` | **16 × 1** | per site-window: `numDwell, longest_s, total_s, meanDwell, medianDwell, kout` (s⁻¹) |
| `perWindow` | **1 × 1** (one window in this folder) | `window, nEvents, kout_w, medianDwell, meanDwell, dwell` — `dwell` is the pooled 946-vector |
| `perTrackWin` | **299 × 1** | per (cell, window, track) with overlapping footprints merged: `numEpisodes, total_s, longest_s` |
| `allDwell` | **946 × 1** double | pooled event durations (s) |

`perTrack` is exactly `Σ nTracks_site = 300` — the same term that sizes `CSmatrix`. `events` is the
only row count set by the biology rather than by the geometry.

CSV sizes: `cs_window_dwell.csv` = 49,921 B / 946 rows = **53 B/row**;
`cs_window_track_labels.csv` = 19,294 B / 300 rows = **64 B/row**; `cs_window_metrics.csv` (Stage 3)
= 1,500 B / 16 rows.

Dwell semantics, load-bearing and lifted verbatim into `cs_dwell_primitives.m` so they cannot drift:
an event is a maximal run of **consecutive in-footprint localizations** and its duration is
`(exitFrame − entryFrame + 1)·dt`, i.e. **frame-span accounting** (`:20-25`).

### Cost — the surprise is the file format, not the data

| | |
|---|---|
| `DD` array payload | **175,478 B = 175.5 KB** |
| `cs_window_dwell.mat` on disk | **5,409,240 B** |
| ratio | **30.8×** |
| HDF5 objects under `#refs#` | **14,746** |
| bytes per object | **367** |

`-v7.3` stores **every field of every struct-array element as its own HDF5 dataset**. Derivation of
the object count: `946 events × 10 fields + 300 perTrack × 10 + 16 perSite × 12 + 299 perTrackWin × 7
+ perWindow × 6 = 14,751`, against **14,746** counted — the handful of difference is string storage.
So

```
bytes(cs_window_dwell.mat) ≈ 367 × (10·nEvents + 10·nTracksAtSites + 12·nSites + 7·nTrackWin)
```

At ten times the sites that is ~54 MB of file for ~1.75 MB of numbers. **The fix, if it ever
matters, is to save `DD` columnar — one array per field instead of a struct array** — which is the
same conclusion as Stage 1 of the plan above, reached from the opposite end. It is not urgent: 5.4 MB
is nothing, and unlike the build this file is written once per run and read once per tab.

Compare that with `CSW_final.mat`, where the same `-v7.3` overhead is invisible because there are
only 16 elements: **577** objects — `16 × 36 fields = 576`, plus the one reserved slot MATLAB always
writes at `#refs#/0` — and the payload dominates. 854,564 B of file for 2.529 MB of numbers is the
*opposite* ratio, and it is the element count, not the field count, that decides which way it goes.

**Time:** not measured. Per member track, `cs_window_dwell.m:55` hands `cs_dwell_primitives`'
`csInsideMask` the track's **whole `nF`-row column**, so the `isfinite` scan covers all
`nF × Σ nTracks_site = 101,608` slots — but `inpolygon` itself is called only on the finite subset
(`cs_dwell_primitives.m:17` masks first), which is the 22,869 real coordinates. So the padding costs an
`isfinite` pass, not 4× the polygon work:

```
O(nF · Σ nTracks_site)  isfinite  +  O(nLoc_at_sites · K)  inpolygon
```

Then `runsToEvents` grows its matrix row by row and the event loop grows a struct array element by
element (`:62`), 946 times here.

### What reaches Compare, and what does not

`cs_experiment_aggregate` reads **only `DD.events` and `DD.perSite`** (`cs_experiment_aggregate.m:55-73`)
and rebuilds `allDwell` from the events. `perTrack`, `perTrackWin` and `perWindow` are **per-folder
only** and never cross an experiment. The Dwell tab's `k_out(window)` bar reads the local
`DD.perWindow` (`spt_analyze_app.m:1427-1429`); Compare takes dwell and `k_out` from
`cmpDD.perSite` (`:1829-1830`). So a cross-condition per-window escape rate is **not** available from
the aggregate as it stands — it would have to be recomputed from `DD.events`.

## What the manifest counts, and what it does not

`cs_experiment_status` returns per-cell **counts** for every stage up to the build — `nSpotsRaw`,
`nTracksRaw`, `nTracksFiltered`, `nTracksCurated`, `nTracksMetrics`, `nTracksKept`, `nSpotsInTracks`,
`nSpotsKept`, `nTracksBuilt`, `nSpotsBuilt`, `nCellsBuilt` — and then stops. For pick / refine / map /
dwell it returns **lamps only**, and nothing at all for refine. So the manifest can say a folder was
mapped, but not on how many sites, which is precisely the question the upstream counts exist to
answer. The numbers are cheap (`numel(CSW)`, `numel(DD.events)`, `numel(CSfoot)`) — but
`cs_window_dwell.mat` is 5.4 MB for the reason above, so a scan would need the same
`builtInfo_`-style mtime-keyed cache the build reader already has (`cs_experiment_status.m:162-199`).

Two more things about the lamps that matter when reading a manifest: `built`, `mapped` and `dwelled`
are **folder-level, not per-cell** (`cs_experiment_status.m:14-18`), so in a multi-cell folder they
light for every cell as soon as one has been processed; and `picked` is per-cell, because it tests for
that cell's own `csIDs/<base>_CSsites.txt`.
