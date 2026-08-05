# Handoff

Written at commit `8ea7fec`. Working tree clean, suite **34/34**.

---

## 1. Read these first — non-negotiable

| rule | why |
|---|---|
| **Never write to `/Users/safal-mac/Desktop/IntegratedPipeline/WithER`.** Read-only, always. | The user's reference dataset. |
| **Never edit or run `tool2_analyze/ContactSites_original/`.** | Pristine Nature-2024 reference implementation. `ContactSites_robust/` is the working copy and *may* be edited. |
| **`save()` and `fopen()` follow symlinks.** Never symlink a WithER file (especially a `.mat`) into a scratch fixture. | A write through the link destroys the original. |
| **`/Users/safal-mac/Desktop/IntegratedPipeline/Control` is LIVE DATA.** Read freely; do not write. | In particular `spt_analyze_app`'s `setProject` calls `writeCalib()`, which writes `tracks/cs_calib.mat`. To exercise that path, **copy the project to scratch first**. |
| Scratch goes in the session scratchpad, never `/tmp`. | |

---

## 2. What the project is

A three-tool MATLAB (R2024b) single-particle-tracking pipeline for **VAPB at ER–mitochondria
contact sites**.

| tool | entry point | does |
|---|---|---|
| **1 · Track** | `run_track` → `tool1_track/spt_app.m` | match folders → detect → link → filter → export |
| **2 · Curate & Build** | `run_curate` → `spt_curate_app` → `spt_analyze_app('curate')` | Experiment · Import & Curate · Build & QC |
| **3 · Analyze** | `spt_analyze_app('analyze')` | Experiment · Contact sites · Refine · Sites · Dwell · Compare |

Tools 2 and 3 are the **same file** (`tool2_analyze/app/spt_analyze_app.m`, ~2860 lines) in two
modes. Tool 2's Import & Curate tab **embeds** `tool2_analyze/app/track_viewer.m` (~2930 lines).

Data flow: Tool 1 writes `tracks/<base>_{tracks.xml, spots.csv, settings.txt}` in **µm**; Tool 2
builds `analysis/TrackStruct.mat`; Tool 3 detects sites and measures dwell.

---

## 3. Running the tests

There is no in-repo runner. Each smoke test must run in **its own MATLAB process** — they build
figures and leave timers, and they interfere in-process.

```bash
# one test
/Applications/MATLAB_R2024b.app/bin/matlab -batch "addpath(genpath(pwd)); spt_calib_handoff_smoke"
```

For the full suite, write a loop that runs each `*_smoke.m` (excluding `ContactSites_original`) in a
separate `-batch` process. **Take a lock and truncate the output per run** — four concurrent runners
once produced a spurious `Invalid or deleted object` failure that cost an hour.

**It takes ~10–15 minutes.** Run it with `run_in_background: true` and poll, or you will hit the
600 s foreground timeout.

`checkcode` notes: the codebase has ~114 pre-existing style warnings in the largest file alone (it uses `if x, y; end`
one-liners throughout). **Only count parse errors**, or diff the message histogram against
`git stash`.

---

## 4. The user's live data

`/Users/safal-mac/Desktop/IntegratedPipeline/Control` — a **halo-Sec61B** cell, tracked and built:

```
spt/Halo-Sec61-TA-100Hz_004_C3.tif     128×128, 5703 frames, 0.16 µm/px, 0.010519 s (95.06 Hz)
er_seg/…_er.tiff  mito_seg/…_mito.tiff
tracks/…_{tracks.xml, spots.csv, settings.txt, tracks_filtered.xml, spots_filtered.csv}
analysis/{TrackStruct.mat, cs_calib.mat, active_trackstruct.txt}
```

Verified consistent as of this handoff: both `cs_calib.mat` copies hold 0.16 / 20.32 / 0.0105191 /
bin 30, and the TrackStruct's per-cell stamp reads `pix 0.16 (image)` — i.e. from the movie's own
metadata, not a panel default. 273 tracks kept of 5564 at a 50-frame filter.

Note the channel token here is **`_C3`**, not the historical `_VAPB`.

Other folders exist (`WithER`, `Project`, `ERAware`, `DualColor`, `Sec61b Halo Control`, …).
`Project/analysis` is what several smoke tests read as a fixture.

---

## 5. What this session changed, and why

All 14 commits are small and self-describing; `git log` is the index. The themes:

**Calibration provenance (5 commits).** Calibration is now **per cell**
(`Tracks(k).calib` with `pixSizeUm/fovUm/dt_s/precNm/binNm` + a `.src` provenance record), stamped
at import by `TrackImporter_direct`'s `cell_calib`. Tool 2 reads Tool 1's record via
`spt_project_calib` instead of keeping the previous project's panel values — and, critically, no
longer *overwrites* the project's calibration with its own defaults on open. The **density bin
(`binNm`) is deliberately separate from the localization precision (`precNm`)**: precision is a
property of the data, the bin is an analysis choice, and comparing two datasets needs the bins
matched while the precisions stay honest.

**Reading real file metadata.** `spt_tiff_calib` parses ImageJ/Fiji's metadata block (scale in
`XResolution`, unit in `ImageDescription`, `ResolutionUnit=None`). `spt_channel_token` *derives* the
SPT channel token from the folder rather than asking. `spt_ij_auto` + `spt_stack_range` transcribe
ImageJ's Brightness&Contrast Auto and are shared by both tools' players.

**Naming.** Tool 1 says **filter**, not curation (curation is Tool 2's job) — `spt_curate_*` became
`spt_filter_*`, the settings block is `filter.*`. `er_aware` is gone; the log names the actual link
mode. Both renames **migrate**: readers accept the old spelling, and `detection_summary.csv` rows
carrying the dropped column are re-aligned rather than left ragged.

**UI correctness.** Hover data-tips no longer fire against deleted objects (`spt_axes_policy`);
Play/Pause moved next to the video; a 60-vs-70 row grid mismatch that made ten controls zero pixels
tall is fixed; the overlay is drawn at the right scale.

**Docs.** `docs/help.html` updated throughout. `docs/sec61b_null_statistics.md` is a standalone
analysis (see §7).

---

## 6. Gotchas this session paid for — do not re-learn these

**MATLAB / uifigure**

- A `uigridlayout` **squeezes every child** when children exceed the declared cells. Worse: MATLAB
  *auto-grows* `RowHeight` to match, so `numel(RowHeight)` looks right — but the invented rows are
  `'1x'`, and **a `'1x'` row in a scrollable grid is zero pixels tall**. Check the *type*, not the count.
- Fixed numeric rows in a **non-scrollable** panel do the opposite: they **clip below the bottom
  edge**, silently. A `[4 1]` grid of 22 px rows in a 96 px panel puts its last two buttons at
  y = −20 and y = −52.
- `disableDefaultInteractivity()` is **not** enough to stop the hover data-tip — it disables the
  gestures but leaves the `DefaultAxesInteractionSet` in place. Assigning `Interactions` is what
  removes it. Use `spt_axes_policy`.
- A `ButtonDownFcn` **coexists** with zoom/pan. Do not strip interactions just because an axes has a
  click handler.
- `findobj` returns children of **unselected tabs**, which are never laid out and all report ~31 px.
  Scope to the selected tab and `pause` for a settle before measuring geometry.
- `uipanel(fig)` does **not** fill its figure (~260 px default). Use `'Units','normalized','Position',[0 0 1 1]`.
- `unique({})` returns a **0×1** cell, and `for n = <0×1>` still runs **one** iteration with an empty
  value. Index explicitly.
- `isequal(NaN,NaN)` is false — use `isequaln` when diffing NaN-padded struct fields.
- TIFF `XResolution` is stored as a **rational**, so it does not round-trip exactly. Use relative
  tolerances.
- `Tiff` requires `Photometric` **before** `BitsPerSample`.
- Executable code must not follow local functions in a script-style `.m`.
- `image()` places the **centres** of the first and last columns at `XData(1)`/`XData(2)`. With the
  convention `X_um = (0-based col)·pxUm`, the far edge is `(W−1)·pxUm`, **not** `W·pxUm`.

**Process**

- Verify a doc insert against the **new** text, not a string that already existed — a guard on a
  pre-existing string silently skips, and matching the same string reports false success.
- Renaming `Play` → `▶` breaks `spt_linkcut_smoke`: its substring fallback then picks `▶ Play link`.
  Several tests select controls by exact `Text` or by `Limits` — check before renaming or re-typing a
  control.
- The review agents caught **four real regressions I had introduced** across this session. Adversarial
  verification of your own changes is worth the tokens here.

---

## 7. Open items

Nothing is broken. These are known, deliberate, and unstarted.

**Flagged to the user, awaiting their call**

1. **`cs_detect.m:80`** — `pv = mean(nullMax >= pk)` returns **exactly 0** for a site above all *M*
   maxima, while `cs_identify.m:1237` already uses the add-one form `(1+Σ)/(M+1)`. The two disagree.
   p = 0 breaks log plotting, π₀ fitting and any FDR curve. **Not fixed because it changes reported
   p-values** — the user should decide.
2. **`cs_config` warns rather than errors** when no calibration is found (it falls back to the
   reference rig's 27.61 / 0.10785 / 0.020064). A headless Tool 3 run can scroll the warning past.
   Making it error would break the paper-reproduction scripts out of the box.
3. **`spt_pipeline_app.m` and `track_viewer.m` were not in the axes-policy sweep.** If the hover
   data-tip warning reappears, it is from one of those.

**From `docs/sec61b_null_statistics.md`, if that work proceeds**

4. The **enrichment denominator is estimated from the window under test** (`cs_detect.m:67,77`), so
   the statistic is not pivotal — it inflates ~1.22× at 20% capture against a null whose whole span
   is 1.41×. Fixing it (leave-sites-out background, or the 25th percentile instead of the median)
   **gates** any FDR calibration.
5. `cs_window_picker.m:643` splits **localizations, not tracks**, so the `stab` column is not the
   independent-replication check it reads as.
6. The per-window density maximum (`cs_window_picker.m:364-367`) is transient; the null-vs-null
   quantile ratio needs it persisted.
7. Sites per 100 µm² of analysed ER mask (`nnz(werMask)*SF²`) is the only defensible rate
   normalisation and is exported nowhere.

---

## 8. Where the user is heading

They plan to acquire **halo-Sec61B** cells as an **empirical background null** for VAPB
contact-site detection, on a different microscope (100 Hz, 128 px, 20.48 µm) from the VAPB data
(50 Hz, 256 px, 27.61 µm). `docs/sec61b_null_statistics.md` is the full analysis. The four things
that matter:

- **Compare enrichment, never site counts.** Counts move 2.0× with frame rate and 2.3× with
  mobility; enrichment moves 1.6%. Counts are also *non-monotone in the signal* — recruitment
  depletes the background and lifts the threshold, so a count can go the **wrong way** when the
  effect is real.
- **Co-imaging is still on the table** (the data is not acquired). It is the only literal per-pixel
  transfer, makes everything paired, and removes a perfect marker × microscope alias.
- **8 control cells, not 3.** The honest effect is d ≈ 1.0; power at n=3 is 0.26.
- **The existing `ermc` null already cuts false sites 81%.** Sec61B is an improvement on a decent
  baseline, not a rescue.

---

## 9. How the user works

- Reports problems from screenshots of the running app, in their own words, several at a time.
  Read the screenshot carefully — the detail they mention is often a symptom of something larger
  (their "the contrast is not great" was a **field-of-view misregistration** drawing the movie 1.35×
  too large).
- Values **measurement over assertion**. Simulate against the pipeline's own functions and report
  numbers with uncertainty.
- Wants concerns raised, not decisions made for them: flag a trade-off and let them choose.
- Expects work to be **finished and tested**, and will say when something is out of scope
  ("Maybe it is getting too complicated… for now I just want the rolling diffusion").
- Every behaviour change in this repo gets a smoke test that reproduces the original failure. Follow
  that pattern.
