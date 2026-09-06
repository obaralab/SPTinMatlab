# Handoff — Tool 1 bleedthrough / interleaved acquisition; Tool 3 Compare + Engagement

Written 2026-09-03. Everything below is uncommitted working-tree state on `main`.

---

## 1. Read this first: what the data actually is

The user runs a **dual-camera** setup. Two channels are exposed together in one 10 ms slot, then two
more in the next: `ch1 + ch2`, then `ch3 + ch4`. One camera's stream is therefore saved as a single
stack with **two channels alternating page by page**.

Files seen so far, and what they are:

| file | contents |
|---|---|
| `<cell>_spt12.tif` (11962 pages, 0.01003 s/page) | camera A raw: ch1 on ODD pages, ch3 on EVEN |
| `<cell>_spt1.tif` (5981 pages, 0.02006 s/frame) | ch1 alone — **byte-identical to the odd pages** |
| `<cell>.tiff` (5981 pages) | mito segmentation |
| `<cell>_ch24_spt.tif` (newer dataset) | camera B equivalent; `_ch24` is a name token, see §6 |

**ch1 and ch3 are BOTH particle channels — the same molecules 10 ms apart.** Only ch3 carries
bleedthrough, because it is exposed simultaneously with the mito channel on the other camera.

### The mistake I made, so you do not repeat it

I measured mito-mask intensity enrichment per parity (ch3 1.66×, ch1 1.05×) and concluded ch3 *was*
the organelle channel, and told the user to de-interleave. **That was wrong.** Additive bleedthrough
onto a real particle frame lifts the in-mask mean identically — the measurement cannot distinguish
"this is the organelle channel" from "this is a contaminated particle channel". The user corrected
me. `spt_interleave_check.m` now reports both readings and refuses to pick one; do not re-add an
inference that picks.

**Consequences that follow:** do NOT de-interleave this data (it throws away half the real particle
frames), and `dt = 0.0100321` is correct for tracking `spt12` at 10 ms — I wrongly called it "half
what it should be" at one point.

---

## 2. Current recommended settings for this user

Detect tab, behind the `▸ interleaved acquisition & bleedthrough options` disclosure:

```
de-interleave        off            keep all 11962 frames at 10 ms
ridge R ≤            2              tracks contamination, flat 2–5 % cost on the clean channel
width ≤              0              added nothing on this data (leak is ridge-shaped, not blob)
align °              0              OFF — see §4, morphology-dependent
thr from             odd 1,3,5…     the clean ch1 parity
on frames            even 2,4,6…    gate only the contaminated parity
organelle /          auto           resolves to 2 (11962 SPT / 5981 organelle)
```

---

## 3. What was built (Tool 1)

All new controls default to **off/auto** and are collapsed behind a disclosure that opens itself when
a cell's stacks look interleaved or mismatched. A project with equal frame counts sees none of it.

| file | what |
|---|---|
| `spt_ridge.m` *(new)* | curvature ratio `tr²/det` (SIFT edge-response elimination) + a SIZE test on the Hessian-implied peak width |
| `spt_interleave_check.m` *(new)* | structural test: `corr(f,f+2) − corr(f,f+1)` > 0.02 ⇒ alternating pages. Optional mask arg adds per-parity enrichment |
| `spt_skel_align.m` *(new)* | rejects detections lying ALONG the organelle skeleton (near + elongated + aligned) |
| `spt_bleedthrough_smoke.m` *(new)* | covers all of the above, parts (A)–(E) |
| `spt_detect.m` | `opts.ridgeMax/.sizeMax/.alignDeg/.skel/.gateMask`; 3rd output `rej` = what the gate discarded |
| `spt_dog.m` | 3rd output `scale` (one definition of the spot scale) |
| `spt_pool_quality.m` | `opts.stride/.offset/.bleedFrames` so the tuner pools the same candidates detection keeps |
| `spt_process_cell.m` | `frameStride/frameOffset` (de-interleave), `segEvery` (organelle frame map), `bleedFrames`, `thrFrames`, dt provenance guard |
| `spt_match.m` | warns `spt_match:duplicateKey` when two stacks reduce to one cell key |
| `spt_app.m` | the Detect-tab UI for all of it, frame ◀▶ stepper + frame box, magenta × rejects overlay |
| `spt_write_settings.m` | records every new setting |

### Measured numbers (real data, cell WT_011 unless noted)

- **ridge R=2**: ch1 16.6 → 15.8 dets/frame (5 % cost); ch3 106.7 → 55.6 (48 % cut). Across three
  cells the ch3 cut was 48/24/17 %, tracking contamination fractions of 84/56/37 % — it scales with
  the artefact, not with morphology.
- **size test**: point-source peak width is `1.53 × scale` px (1.53/3.06/4.58 at scales 1/2/3);
  filament never below 3.12/5.29/8.92. Default `1.6 ×` expected sits in the gap at every scale.
  **Added nothing on the real data** (55.5 vs 55.6) — this leak is ridge-shaped.
- **interleave check**: `spt12` +0.279/+0.259/+0.268, `spt1` −0.108/−0.099/−0.088.
- **de-interleave equivalence**: `spt12` + odd pages reproduced the separate `spt1` export
  **bit-for-bit** at full length (5981 frames, 229 901 detections, 14 373 tracks). Same stack
  un-de-interleaved: **411 tracks**.

---

## 4. Two things deliberately NOT enabled, with reasons

**`align °` (skeleton alignment).** Works — 56.0 → 45.6 dets/frame on ch3 at zero cost on ch1, and
scored against ch1 as ground truth it removed 425 artefacts against 5 real molecules (99 % artefact,
1.4 % of real). **But its bite depends on organelle MORPHOLOGY, not contamination**: 19 %, 8 %, 5 %
across three cells of one condition, inversely with mito density (denser network → more junctions →
ill-defined local direction). If morphology differs between conditions that is a condition-dependent
detection bias. The user raised this objection and the measurement confirmed it. Leave it at 0 for
comparative work.

**Mask-based gating (`opts.gateMask`).** Exists in `spt_detect` but has no UI. Measured effect on
real data was ~0.5 % (rejections were already 99 % inside the mask), so a control was not worth it.
More importantly: **never filter detections by the mito mask**. A molecule ON a mitochondrion is the
measurement. Applying gates only inside the mask biases enrichment and mito fraction downward,
exactly where the biology is.

---

## 5. The biggest finding, and it is not a filter

**Top % pools candidate qualities over ALL frames, so bleedthrough sets the detection threshold for
the clean frames too — by a different amount in every cell.**

| cell | thr (all frames) | thr (ch1 only) | ch1 dets/frame (all) | (ch1 only) |
|---|---|---|---|---|
| 011 | 25.1 | 6.7 | 16.8 | **82.7** |
| 012 | 32.0 | 7.4 | 35.4 | **63.7** |
| 013 | 36.6 | 16.7 | 47.6 | **65.1** |

Cross-cell spread collapses from **2.8× to 1.3×**. Most of the apparent biological variation was the
threshold moving with contamination. Fixed by the **`thr from`** control (`thrFrames`); `Quality ≥`
also removes the coupling.

---

## 6. Fiji script — `tools/duplicate_organelle_frames.py`

Pre-duplicates organelle pages so every stack matches the movie length. Jython; Script Editor →
language Python → Run. Dry run by default.

**Why it exists:** the viewers were reverted (§7), so they need matching lengths. Detection's
`organelle /` map covers detection only.

Pairing is by cell key: drop extension → drop ilastik token → drop the **strip** regex (anywhere) →
drop the channel **suffix** (at the end). Strip runs first, which is what makes `_ch24` work.

- `_VAPB` dataset: strip `_VAPB`
- `_ch24` dataset: strip **`_ch24`** ← required; without it everything falls to the prefix fallback

Verified dry run on the user's 12 files: all matched **by key**, `N = 2` throughout, 49 524 pages to
write. **Not yet executed for real, and never run under Jython by me** — logic verified in CPython
only. One bug already found and fixed this way: `getTiffFileInfo` returns a *single* `FileInfo` with
`nImages` for contiguously-written stacks, so `len(info)` reported 1 page for every SPT movie.

---

## 7. REVERTED — do not re-apply without asking

I fixed the frame→page map in **every viewer** (Tool 1 player, Tool 2 curate overlay, Tool 3 picker
and Sites/Dwell overlay), then the user asked for it reverted in favour of pre-duplicating frames.
All five files are back to committed state; `cs_seg_every.m` deleted; smoke part (F) removed.

**The user was right to ask.** `cs_channel_mask` also feeds `werMask`, the *support mask* for the
windowed mapper, where `[]` means "no restriction" — so my clamp→`[]` change was not a display change
at all, it could alter which localizations a window admits. That is analysis, and it should not have
ridden along with an overlay fix.

Known remaining behaviour, by choice: with mismatched stack lengths the viewers either clamp to the
last organelle page (Tool 2 curate, Tool 3 picker) or stop drawing (Tool 3 Sites/Dwell, Tool 1
player). Pre-duplication is the sanctioned fix.

---

## 8. Tool 3 Compare (earlier in the session, unrelated to bleedthrough)

`spt_analyze_app.m` + new `spt_compare_group_smoke.m`:

- groupings `condition x mito` / `window x mito`; a `sites` filter (all / mito only / non-mito only);
  a `dw% ≥` spurious-hit gate; a `cells…` per-comparison picker
- table gained `median` and `mode` — **mode is BINNED** (Freedman–Diaconis modal-bin centre);
  `mode()` on continuous per-site values returns the minimum, which looks like a statistic
- `Export points` writes per-datapoint CSVs for Prism (wide one-column-per-group, long with
  identity, plus pooled dwell events)
- Kruskal-Wallis omnibus for >2 groups
- **Bug fixed:** `findPerSite` matched on `siteUID` alone, which collides across experiment folders;
  a condition mapped-but-never-dwelled reported another condition's `k_out`. Now matches on identity
  (srcFolder · file · cellIndex · csID · window) and contributes NO value when unmatched.

On the user's data all four conditions reconcile exactly with their existing CSV (154/175/145/121).

---

## 9. Batch detection at a chosen Top % (settled)

`resolveDetThr` in `spt_app.m`: **Top % was not inherited by un-previewed cells.** Scan seeds
`keepPct = 6` on every cell and only *previewing* writes the tab's value, so setting Top % = 10 and
running the batch left every un-previewed cell detecting at 6 — silently. `Quality ≥` had always been
inherited; Top % now behaves the same way, using "has no stored `thrAbs`" as the test for "never
previewed" (nothing else distinguishes Scan's seeded 6 from a chosen 6).

Built on top of that, for the 93-cell run:

- **`▶▶ Run all @ Top X%`** on the Track tab — applies the tab's Top % to every matched file and
  tracks them, so the per-cell threshold is re-derived from each cell's own intensity distribution
  rather than one absolute value copied across cells. This was the actual defect behind "it keeps
  getting back to 6%".
- **`spt_process_cell` now returns the resolved threshold** (`thrUsed`, `thrSrc`). Without it a batch
  looked as though every cell shared one value and there was no way to audit which cell used what.
- **Euclidean by default when a cell has no ER segmentation**, instead of requesting an ER mode and
  being downgraded per cell.

Verify after a batch by reading `detection.top_percent` and `detection.thr_used` in a per-cell
`_settings.txt` — they should differ cell to cell at one shared Top %. Pooling on one absolute
threshold was what produced the 2.8x cross-cell spread in detections; it is ~1.3x on Top %.

**Tool 2 batch export — an absolute density cut, not only a percentile.** `track_viewer.m` gained a
typeable `max_dn` spinner beside the slider (`on_max_dn_typed` / `on_max_dn_slid`). Typing a value
that falls outside the current range **widens the range** rather than clamping the value — clamping
silently applied a different cut from the one that was typed. The value a user types is used by the
batch as-is on every cell, which is the point: a percentile is per-cell and moves with each cell's
own distribution, an absolute number does not.

---

## 9b. Tool 3 — diffusion correctness and the Engagement tab (newest work)

**Gap-closed steps were inflating D in one of the two modes.** With Tool 1's *Max gap (fr) = 1* a
step can span two frames; its displacement is `4*D*(2*dt)`, so crediting it to one interval doubles D
for that step. `lag1` already weighted by span. **`msdfit` did not** — it lagged over *localizations*
while fitting against `4*k*dt`, the same error by another route, reading ~16 % high on tracks with
25 % of localizations dropped. `spt_track_diffusion.m` now bins by **frame** lag, and every build
carries a per-track gap census: `gapSteps`, `maxGapFr`, `nSteps`.

Regression `spt_gap_diffusion_smoke` is two-sided (an over-correcting estimator fails too) and
reproduces the old localization-lagged fit alongside the new one — 0.3031 vs 0.2610, x1.16 — so the
fix is *shown* to bite. The census is asserted against ground truth recomputed from the fixture, not
against hardcoded numbers: the first version asserted "largest span == 2" and the census truthfully
reported 8, because the drop mask allowed consecutive drops. The census was right; the expectation
was wrong.

**`cs_mito_engage.m` + tab `6 · Engagement`** — the diffusion-contrast readout for the compound
plate. Steps are labelled by where they *started* (BOUND within `d` of the organelle, FREE otherwise)
and D is pooled separately: `Dratio = D_bound / D_free`, below 1 = engagement, 1 = none.

> **The correctness argument is the classification rule, and it must not be "improved".** Requiring
> *both* endpoints inside the zone looks more careful and conditions on the step being SHORT, because
> a long step starting in a narrow zone leaves it. On an **untethered** synthetic cell — one uniform
> D, no tethering at all — both-endpoints gave `Dratio` **0.66**, a convincing false hit produced
> entirely by geometry. Start-only gives 1.004. The cost of start-only is dilution toward 1, never a
> false positive, which is the conservative direction for a hit call.

Verified numbers: driver — tethered **0.206** against a planted 0.20, untethered **1.004**, gapped
**0.234**. Tab — tethered **0.363**, untethered **0.947** (diluted because the scan's middle distance
is wider than the planted zone), `D_free` **0.3548** against a planted 0.40.

The tab has data source, channel (mito/er), a distance **scan** (two bounds + a count → one row per
cell per distance), precision in **nm** (converted to µm — `spt_engage_tab_smoke` asserts this via
`D_free` plausibility, since a µm/nm slip floors every D to zero), min steps, Compute, Export CSV. A
cell that cannot meet min steps shows a **dash and its reason**, never a number. Plots: per-cell
ratio by condition with a `yline(1)` null, and ratio-vs-distance with one line per condition — a real
contrast is strongest at short distance and washes out as the zone widens.

Documented in `docs/help.html` (§ *Tool 3 · Engagement*) and `docs/PIPELINE.md` (stage 7; Compare
renumbered to 8).

**A test-hygiene note that will recur:** adding the tab broke `spt_compare_group_smoke`, which
searched the whole figure for `▶ Compute` and found 2. Compare's smoke now searches **within its own
tab** (`findobj(tab, ...)`). Do the same in any new tab smoke — a figure-wide `pick` is a trap that
springs on whoever adds the *next* tab.

---

## 9c. Calibration edits now actually apply (newest work)

**The defect.** On a dataset whose files carry no pixel size or dt, every tool falls back to the
panel's resting value — one project into a session, that is the *previous* dataset's numbers. The
Experiment tab is where the user corrects it, and it stored the correction faithfully in
`experiment_details.mat`. **Nothing read it back.** `spt_project_calib` — the one resolver Tool 1's
runs, Tool 2's builds and Tool 3's top bar all go through — ranked `_settings.txt`, then the movie,
then the XML, and never the manifest. The Experiment tab showed 0.107 while every other surface used
0.16, with nothing on screen to say they disagreed.

Fixed at the chokepoint: `spt_project_calib` gained **rank 0 = your edit**, above `_settings.txt`.
Only values the panel marked **locked** count — a hand edit sets that and nothing else does, which is
what stops Tool 1's own `setCalib(lock=false)` stamp-back from outranking the file it was read from.

Two traps worth knowing about, both hit during this work:

- **Rank 1 was written to overwrite unconditionally.** Adding rank 0 above it was not enough — the
  settings file silently reinstated the number the user had just fixed. Ranks 2 and 3 had always been
  written `if ~isfinite(...)`; rank 1 had not. Guard added.
- **`cs_experiment_scan` must NOT read the manifest** — it *fills* it. It passes `useManifest=false`,
  so a rescan reports the filesystem and the panel re-applies the edit on top. Without that an edit
  becomes its own evidence and no rescan can ever show what the files contain.

**Propagation**, all newly wired: the panel's `onChange` → `onCalAuto` updates the **top bar live**
(edited fields tinted green, tooltip "YOUR value, typed on the Experiment tab") and rewrites
`analysis/cs_calib.mat` so `cs_config` carries it downstream; the `Calib` struct sent to the build
gained an **`edited` list** so `TrackImporter_direct/cell_calib` ranks a correction above the cell's
own TIFF tags and above the XML's `frameInterval` (rank 0 there too). Tool 1's `cellCalib` already
ranked edits first at run time — that half was fine.

**Dimensions.** `spt_tiff_calib` now returns `.width`/`.height`, and `spt_project_calib` passes them
through — from the SAME `imfinfo` the calibration is read from; the first version called it twice,
which on a 5 700-page stack is not free. Shown on the Tools 2/3 top bar as `256×200 px` beside the
FOV. **The FOV is no longer read from anywhere** — it is always `(width-1) × pixUm`, recomputed from
whichever pixel size won, so a corrected pixel size moves it. Previously the width was only read
inside the "pixel size came from the movie" branch, so the common case (pixel size from
`_settings.txt`) reported no width and no FOV, leaving a stale FOV on the toolbar.

**Bulk apply** (the Experiment tab's calibration row): one `µm/px`/`dt` to the **selected rows** or
to **every row the filter shows** — the button names the count, so a stale filter is visible. 0 in a
field leaves that field alone. Applied values are `edited` + locked, identical to typing one in. Two
buttons rather than one that infers scope from an empty selection, because "nothing selected" must
not silently mean "all 93". Overwriting a *measured* value confirms first; overwriting `missing`,
`panel`, or an earlier edit does not (prompting for those trains the prompt to be clicked through).
One `notifyChange` per batch — each one saves the manifest and re-resolves the host calibration.

Regressions: `spt_calib_edit_smoke` (resolver: rank, that it bites, lock-only, per-field, no scan
loop, project scoping, dimensions + derived FOV), `spt_calib_ui_smoke` (the wiring, offscreen: top
bar follows, FOV follows, `cs_calib.mat` written, build told which fields were edited), and
`spt_calib_bulk_smoke` (scope by filter, scope by selection, edited+locked, blank-leaves-alone, one
save, resolver answers with the applied value).

**The curate overlay had the same bug one layer down.** `track_viewer` draws the raw frame and the
organelle masks across `Overlay FOV (um)`, sized from the movie's **own TIFF tags only**. No
metadata -> NaN -> assignment skipped -> the spinner keeps its shipped **27.61 µm**, the old rig's
FOV, while the tracks are in µm at the project's real scale. The image is drawn ~12 % too wide on a
256 px / 0.097 µm/px movie (tracks 24.735 µm vs image 27.61) and the emitter ring sits on background
instead of on the molecule. **This is why it looked file-specific** — a movie that carries its pixel
size was always fine.

Fixed by passing `opts.pixUmFcn` from the host (a LIVE handle, so a calibration corrected on the
Experiment tab re-sizes the overlay without re-embedding the tab). Order: movie tags -> project
pixel size -> leave alone. The source is now named in the overlay status line and an unsupported
width is tinted amber, because a silent stale 27.61 is exactly what made this read as a
segmentation or drift problem rather than a scale problem. Regression: `spt_overlay_fov_smoke`,
which asserts the BROKEN state first so the fix cannot pass for an unrelated reason.

**Tool 3 had the same exposure, and it was worse.** Tool 3 reads no movie metadata at draw time —
it uses `Tracks(k).calib`, stamped once at build. `cell_calib` resolved the pixel size from the
cell's own IMAGE metadata, then the panel, then `0.10785`, and **never read
`tracks/<base>_settings.txt`**, which is Tool 1's record of what it actually tracked with. Those
disagree exactly when the user overrode the pixel size in Tool 1 — the whole no-metadata workflow —
so the coordinates are at the override and the build stamped the rejected tag. On the user's numbers
that is 0.16 vs 0.097, a **65 %** error, not 12 %. `cell_calib` now ranks settings above the image
(below only a hand edit), and `calib.fovUm` is DERIVED as `(width-1) x` the winning pixel size
instead of being resolved separately. Regression: `spt_tool3_scale_smoke`.

Also fixed: the dwell organelle overlay stepped the mask by `fov/W` and placed 1-based column `c` at
`c*ux` — one camera pixel off (~0.1 µm) against contact sites 0.1-0.5 µm across. Now `fov/(W-1)` and
`(c-1)*ux`. Display only; ER/mito DISTANCES come from Tool 1's CSV and never went through this path.

**Verified on the user's real data** (`~/Desktop/Acquisition-15`, one cell `ROI`, 256x256, 10 000
frames, movie carries NO metadata, `_settings.txt` records `pixel_um = 0.097 / src = edited`).
Rebuilt through the app's own Build button; the stamp is now `pix 0.097 (settings-derived, reported
as edited) / FOV 24.735 (derived) / dt 0.006` — the FOV was **27.61** before. Alignment measured by
mapping each localization to a raw pixel (`col = x/pixUm + 1`) and finding the local intensity peak,
over 684 localizations on 60 frames:

| pixel size | median offset | within 1.5 px |
|---|---|---|
| 0.097 (correct) | **0.75 px (73 nm)** | 92 % |
| 0.10785 (old default) | 3.72 px (402 nm) | 7 % |

0.75 px is localization noise plus peak-pixel quantization — i.e. aligned. NB the offset metric
SATURATES at the search-window half-width, so it cannot show the linear-in-radius signature of a
scale error; the offset magnitude is the discriminating statistic, not its trend.

**The mask-extent fix is now verified against ground truth too**, on `~/Desktop/CysLig` (a
labmate's plate, 93 cells, mito_seg present, no er_seg). Its SPT movies DO carry ImageJ metadata
(0.0967821 um/px, 0.0267118 s) — it is the mito TIFFs that carry none, which does not matter since
the mask is drawn across the FOV. Both are 256x256 x 5000 pages, so mask pages match frames 1:1
(the Fiji duplication script did its job).

The test: Tool 1's `MITO_DIST_UM` is computed per localization without ever touching the display
path, so it is genuine ground truth for the overlay geometry. Sample the drawn mask at each
localization using the app's extent mapping and compare `mask says inside` with `MITO_DIST_UM <= 0`:

| cell | n | inside by Tool 1 | new convention | old convention |
|---|---|---|---|---|
| Plate1 | 3666 | 48.2 % | **100.00 %** | 95.72 % |
| Plate2-002 | 3791 | 36.6 % | **100.00 %** | 97.73 % |

100.00 % is exact pixel-for-pixel reproduction of Tool 1's own mask sampling, which is what the
`fov/(W-1)` step and the `(c-1)*ux` placement should give: `ux` then equals the pixel size exactly.
The old convention put 2-4 % of localizations on the wrong side of a mito boundary — i.e. that
fraction of every contact-site judgement made by eye off the overlay.

Use CysLig for any future overlay work; Acquisition-15 has no segmentation at all.

**The subtlety to keep in mind if this comes up again:** for overlay ALIGNMENT the correct pixel
size is the one that produced the coordinates, not the one that is physically true. If a user
corrects a calibration but does NOT re-track, `_settings.txt` and the edit disagree, and the tracks
are still at the old scale. Rank 0 (the edit) then wins and the overlay will be drawn at the new
scale while the coordinates are at the old one. That is the right call — the data is mis-scaled and
must be re-tracked — but nothing currently WARNS about the disagreement. Worth adding.

Still open there: `pick_overlay` (the manual escape hatch) reports `spans %.4g um` but never SETS
the FOV, so a manually picked overlay keeps whatever width was in force. Low priority — the auto
path is what everyone uses — but it is the same class of bug.

**Two pre-existing bugs the bulk test flushed out**, both in `spt_experiment_panel`:
- `filterRows` called a `tern()` helper the file **never defined**, so every keystroke in the
  Experiment tab's filter box threw and the box did nothing. Present in HEAD: two uses, zero
  definitions. Nothing else calls `filterRows` with a non-empty query, so it never fired.
- A `shownRows` accessor written `@() rowMap(:)'` captured `rowMap` **by value at construction** —
  the same gotcha the file already carries a note about for `getCells`. Now nested. Worth watching
  for: this file mixes nested accessors and anonymous ones, and the two look identical at the call
  site.

**Tell the user:** anything built or picked under the old behaviour was built at the *fallback*
scale, not their correction. Reopen the project, confirm the top bar shows the edited numbers, then
rebuild — and re-run the picker if sites were already placed, since those were positioned on the old
µm scale.

---

## 9d. Build & QC left column — selection, not just histograms

Two panels retired: the track-LENGTH histogram (readable but not actionable) and the pooled
stepwise-D histogram (the same measurement as the stepwise D(t) already on the right). In their
place a selection row directly under the cell table: **`len ≥`**, **`near mito ≤`** (checkbox +
threshold), a count label, and **Export D CSV**. The D distribution, the CSD and the track map all
follow the selection; the ER/mito histogram deliberately does NOT, because that is the plot you read
the mito threshold off, so filtering it by that threshold would be circular — the threshold is drawn
on it as a dashed line instead.

The mito cut is the track's **MEDIAN** signed distance, matching how Dwell summarises a track against
a footprint. A `min()` rule would select any track that ever brushed a mitochondrion, which is a much
weaker claim; `spt_qc_select_smoke` has a fixture track whose median is +1.20 and whose minimum is
-0.90 specifically so the two rules disagree and the test can tell them apart.

Export writes `analysis/qc_trackD_<fitmode>_<filters>.{wide,long}.csv` — wide is one Prism-pasteable
column, long carries cell, track, n_loc, D, **fit_window_pct**, sigma_loc and median mito. The fit
window travels with the value because an adaptive R² fit chooses it per track, and a D exported
without it cannot be compared against a D fitted over a different span.

> ### exportapp MIS-RENDERS A NESTED uigridlayout — do not "fix" this layout from a screenshot
>
> A `uigridlayout` nested inside a `uigridlayout` is painted several rows low by `exportapp`, while
> its `Position` is correct. Minimal repro (12 lines, no app): a [5 1] grid of
> table / nested-grid / 3 axes reports `qs.Position = [1 551 400 32]` — row 2, directly under the
> table — and exports it drawn between axes 2 and 3, with an empty band left where it belongs.
>
> This cost most of an hour: the render was read as a layout bug, "fixed" twice (explicit
> `Layout.Row` on every child, then replacing `legend()` — see below), and neither changed the
> export because nothing was wrong. **Verify this tab by Position, not by exportapp.**
> `spt_qc_select_smoke` asserts the ordering numerically for exactly this reason.
>
> Renders remain the right tool for everything else — three real layout bugs earlier in this work
> were only visible in one — but not for a tab containing a nested grid.

Found on the way, and worth knowing generally: **`legend()` on an axes inside a uigridlayout parents
itself to the LAYOUT, not the axes, and has no `Layout` property**, so it is auto-placed into a grid
cell of its own. The ER/mito panel's legend was doing this. Replaced with `text()` in the axes.
Any new legend in a gridded tab will do the same thing.

---

## 10. Open threads

1. **`_ch24` may itself be interleaved.** `_spt12` was ch1+ch3 alternating. If `_ch24` is ch2+ch4 the
   same way, the ×2 organelle duplication is right for overlays but detection would again span two
   channels. The Detect tab will open the interleaved row on its own if it tests as alternating.
2. **Linear unmixing** is the physical fix for the ch3 bleedthrough and is still unbuilt. ch4 is
   exposed simultaneously with ch3 on the other camera, so it is inherently registered. Blocked on
   whether ch4 is exported. Shape filtering only halves the excess: ch3 sits at 3.5× ch1 after R=2,
   not 1×.
3. **Nothing is committed.** ~22 modified files plus several new ones and `tools/`. No commit was
   requested; ask before making one.
4. **The rest of the engagement menu is unbuilt.** The user picked "add all, I will look later" and
   then asked for the diffusion contrast first. Still open: occupancy *enrichment* (needs the area
   fraction, unlike the raw `occupancy` field already exported), distance-resolved dwell / k_off,
   k_on (arrival rate at the interface), a radial profile of D against distance, and the scoring
   layer that ranks the 4 compounds. The plate is **2 active, 2 inactive** — that is the benchmark
   any scoring layer must reproduce before it is trusted.
5. **Track counts vary a lot** between cells (10 540 / 14 373 / 17 746 on similar detection counts).
   Worth understanding before pooling.

---

## 11. Working notes

- MATLAB: `/Applications/MATLAB_R2024b.app/bin/matlab -batch "<smoke>"`; lint with
  `bin/maca64/mlint -id <file>`. Tool 2/3 driver smokes need `addpath('../../tool1_track')`.
- **Assert on every string replacement.** Two edits this session silently did nothing because the
  target text did not match (`ColumnSpacing',7` vs `6`), leaving colliding UI controls. The render
  caught them, not the code.
- **Render the UI after layout edits.** `exportapp(fig, png)` offscreen. Three separate clipping /
  truncation bugs were only visible in the image.
- The user's data is on `~/Desktop` and shell access to it has lapsed at least once mid-session
  (macOS TCC). MATLAB may still read it when the shell cannot.
- Repo convention: every behaviour change gets a `*_smoke.m` with assertions that state the defect
  in the failure message. Verify a new regression test actually bites by temporarily restoring the
  old behaviour.
