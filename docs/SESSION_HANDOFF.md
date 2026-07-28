# SPTinMatlab — Session Handoff

**Status:** all changes below are **verified present in source** (grep-checked) and the app **builds green**
(`spt_split_smoke` passes for curate/analyze/full). MATLAB apps do **not** hot-reload — **close and relaunch**
`spt_app` (Tool 1) and `spt_analyze_app`/`run_analyze` (Tool 3) to see any of this.

## Quick re-verification
```bash
# 1) app builds (all tabs construct)
/Applications/MATLAB_R2024b.app/bin/matlab -batch "cd SPTinMatlab/tool2_analyze/app; spt_split_smoke"
# 2) strict ER-geodesic regression (section H) — 27 assertions
/Applications/MATLAB_R2024b.app/bin/matlab -batch "cd SPTinMatlab/tool1_track; spt_geo_strict_smoke"
# 3) confirm markers exist (any ✗ = reverted/lost)
grep -c "cs_split_peaks" SPTinMatlab/tool2_analyze/drivers/cs_detect.m
grep -c "densMode"       SPTinMatlab/tool2_analyze/drivers/cs_window_picker.m
grep -c "addDiffusion"   SPTinMatlab/tool2_analyze/app/spt_analyze_app.m
grep -c "C(:) = Inf"     SPTinMatlab/tool1_track/spt_link_cost_geo.m
grep -c "spt_on_er"      SPTinMatlab/tool1_track/spt_track.m
grep -c "geo_bridge"     SPTinMatlab/tool1_track/spt_track.m
grep -c "nDetsOffEr"     SPTinMatlab/tool1_track/spt_process_cell.m
```
> The old marker `grep -c "FORBID all" .../spt_link_cost_geo.m` is **retired** — section H rewrote that
> header, so it now returns 0 for a healthy tree. Use `C(:) = Inf` instead.
> The per-feature headless test scripts were written to the **session scratchpad**, which is **ephemeral** —
> they will NOT be present next session. Re-verify via `spt_split_smoke` + relaunching the apps + the grep markers.
> `WithER/` was **not modified** by any test (writes went to symlinked temp dirs).

---

## What changed this session (by area)

### A. Dwell tab (Tool 3)
- **csID column** — `drivers/cs_window_dwell.m` (perTrack/perSite/events carry csID) + `app` `tblDwell` shows
  `cell·site·win·track…`. *Verify:* Dwell tab table has a `site` column with real IDs.
- **Filled ER/mito overlay + toggle-hang fix** — `app` `dwellOrgMask`/`addOrgFill` (translucent filled masks,
  z-ordered below the track). Removed the **per-frame `imfinfo`** on the ~5981-page seg (the hang) → single cached
  `imread(page)`. *Verify:* Dwell tab, toggle ER/mito → filled tint (not outline), no stall.

### B. Sites-tab raw-movie player (Tool 1 widget, `spt_track_movie.m`)
- **"zoom" toggle** (default on) frames the CS + played tracks; axes toolbar enabled for manual pan/zoom-out.
  *Verify:* Sites tab → Play → view is zoomed to the site; uncheck "zoom" → full frame.

### C. Density picker (Tool 3 Contact-sites, `drivers/cs_window_picker.m`)
- **Tracked-only density** — "All localizations" option **removed**; density always from the tracked matrix
  (`cellLocs(T,true)`). *Verify:* no Source dropdown; readout says "tracked … (density source)".
- **Total/tracked/window counts** in the status readout: `detections N · tracked M (46%) · … · THIS window W`.
- **Windowing tools:** `step frames` (sliding/overlapping windows), `min locs/win` (red ⚠ warning floor),
  **⇢ Sweep window length** (popup: #sites + median significance vs frames/window).
- **Robust peak detection + transparency:**
  - **split peaks** (default on) — watershed splits touching peaks (`cs_detect.m` `cs_split_peaks`).
  - **min enrich ×** — effect-size gate (peak/ER-median-bg). **min tracks** — distinct-molecule gate (≥K unique
    tracks → rejects one parked molecule).
  - **per-site table** (`#,p,enr×,trk,dw%,stab`): p-value, enrichment, distinct tracks, **dwell %** (median % of
    each track's locs inside the site — passing vs dwelling), split-half stability. Click a row → overlays that
    site's tracks colored blue(passing)→red(dwelling).
  - **🔍 explain spot** — click anywhere (even a non-site) → density/null-percentile/enrichment/#tracks/p.
  - **Save provenance** → `csIDs/<base>_CSsites_provenance.json` (all params+date) + `_CSsites_stats.csv`.
  - **＋ Add site** manual button restyled prominent (soft-orange).
- **Diffusion channels** (see F): `channel` dropdown Tracked | Confined (low D) | State-change.
- *Verify:* Contact-sites tab, Detect → per-site table populates; toggle a gate + re-Detect → count changes.

### D. Refine radial null (Tool 3, `drivers/cs_radial_plot.m` + `app` `erGridForCell`/`erNullForSite`)
- Dashed "uniform" line is now **cell-wide ER-uniform** (`ρ·A_ER(r)`, ρ = cell-wide locs-over-ER per ER-µm²),
  not a local disk. *Verify:* Refine tab → radial plot legend reads "uniform over ER (cell density)".

### E. Docs
- **`docs/help.html`** — full pipeline guide (self-contained, theme-aware). Opened by a new **❓ Help** button in
  BOTH `spt_app` and `spt_analyze_app` (`onHelp` → `web(...,'-browser')`). *Verify:* click ❓ Help → opens.

### F. Stepwise-diffusion integration (step 1 of the STEP plan — DONE)
Goal: compute pointwise diffusion **after curation**, independent of contact sites, so Tool 3 can identify sites by
**confinement** and **fast→slow state change**.
- **`drivers/spt_track_diffusion.m`** (NEW, native MATLAB) — per-loc `Dt` (noise-corrected rolling: `<Δr²>/(4dt) −
  σ²/dt`, σ from Loc-prec), `confined` (D≤confineD), `stateChange` (rising edge mobile→confined). ~0.1 s for 100k locs.
- **Wired into Build** — `app` `addDiffusion` runs it in `onBuild` (before save) + `onLoadTracks` (if missing) and
  stores the fields in `TrackStruct.mat`. Build&QC "**confined ≤ D**" spinner (`onConfineD`→`reDeriveConfinement`)
  re-derives confined/stateChange from stored Dt (no re-roll) + re-saves; the D-distribution shows the cutoff + %
  confined + #state-changes. **GOTCHA fixed:** `Tracks(k)=struct-with-new-fields` throws "dissimilar structures" →
  assign field-by-field.
- **Tool 3 channels** — picker `channel` dropdown (enabled iff TrackStruct has diffusion); `densMask()` filters the
  density by confined/stateChange; Detect runs on the chosen channel. *Verified on WithER:* confined→10 sites vs
  tracked→28; state-change→0 (sparse). *Verify:* Build (or Load) → Contact-sites → channel=Confined → Detect.
- **`run_step.py`** gained `--sigma` (noise correction), `--win`, `--mode lag1|msdfit` — the Python bridge stays the
  optional real-STEP path.

### G. Strict ER-geodesic (Tool 1 linking, `tool1_track/spt_link_cost_geo.m`)
- The two `E·(1+λ)` soft fallbacks → **`Inf`**: geodesic is now a **hard** constraint (on-ER links only; off-ER /
  unreachable / detour>R **forbidden**). Ladder: euclid < penalty (soft) < geodesic (strict). Breaks only for
  genuinely off-(that-frame's)-ER detections → **more/shorter tracks, more sensitive to seg quality + SPT/ER
  registration**. Labels updated (dropdown tooltip + provenance `linkModeName`).
  *Verify:* Tool 1 → ER-geodesic → Run; provenance `_settings.txt` says "strict".
- ⚠ **CORRECTION.** This section originally claimed *"Uses the per-frame ER support, so ER motion is fine"*. That
  was **false when written**: the cost function received one mask and judged **both** endpoints against it, so the
  target in frame t+1 was tested against **frame t's** ER. A spot that moved *with* the ER onto newly-covered
  pixels was scored against a stale mask. The claim became **true only in section H** (the `supQ` argument =
  the target frame's own support). Anything produced by the ER-geodesic mode **before** section H carries that bug.

### H. Strict-mode fail-closed audit + fixes (2026-07-28, Tool 1 linking)
Requirement: in ER-geodesic mode a detection **outside the ER must not end up in any track**. An audit found
strict mode **failed OPEN in four places** — the constraint was silently dropped instead of refusing. Every fix
below makes the missing/empty case **forbid**, never "no constraint".
- **`spt_er_support.m`** (NEW) — `supD = imdilate(logical(sup), strel('disk',1))`. The **single** definition of
  the ER support (1 px registration slack). `[]` in → `[]` out, and every caller must read `[]` as *forbid*.
  The cost function, the detection pre-filter and the gap-close test all go through it, so they cannot drift apart.
- **`spt_on_er.m`** (NEW) — `tf = spt_on_er(xy, supD)`: which detections sit on the dilated support **of their own
  frame**. Out-of-image and empty-mask both → `false`.
- **`spt_geo_strict_smoke.m`** (NEW) — 27-assertion regression test for all of the above. **ALL PASS.**
- **`spt_link_cost_geo.m`** — signature now `(P, Q, R, supP, lambda, supQ)`, `supQ` defaulting to `supP`. Fails
  **CLOSED**: an empty `supP` *or* `supQ` sets the whole matrix to `Inf`. The target is validated against **its own
  frame's** ER (`supQ`), not the source frame's — see the section-G correction. `lambda` unused in this mode.
- **`spt_track.m`** — returns `[tracks, info]`, `info = struct(mode, nFramesNoErMask, nDets, nDetsOffEr)`. In
  `'geodesic'` it **pre-filters `dets{t}`** to on-ER-in-frame-t detections **before** the LAP, so an off-ER
  detection cannot enter a track by *any* route (frame link, chain assembly, gap close). A frame with no ER mask
  keeps nothing and raises `warning('spt_track:noErMask',…)`. Geodesic no longer routes into `spt_link_cost` at
  all. Gap closing now takes `mode`: geodesic requires the bridge to be reachable **along the ER** (`geo_bridge`
  → a geodesic cost call; `Inf` = refuse, missing mask = refuse); `'penalty'` keeps its old soft
  ">50 % off-ER straight line" veto **unchanged**.
- **`spt_process_cell.m`** — an ER mode with **no ER segmentation** is now downgraded to `'euclid'` **once,
  explicitly** (previously it emerged implicitly from an all-empty supports array). `R` carries `linkMode`
  (effective), `linkModeReq` (requested), `nFramesNoErMask`, `nDetsOffEr`.
- **`spt_write_settings.m`** — reports the **effective** mode; adds `tracking.link_mode_req` when downgraded, and
  `tracking.frames_no_er_mask` / `tracking.dets_off_er` in geodesic mode.
- **`spt_compare_app.m`** — the summary panel no longer claims "(~equal)" linked detections; it reports how many
  detections geodesic **excludes** and states that penalty excludes none.
- **`spt_link_compare.m`, `spt_method_compare.m`** — pass the **target** frame's ER mask to `spt_link_cost_geo`,
  so the comparison matches what tracking actually does.
- *Verify:*
  ```bash
  /Applications/MATLAB_R2024b.app/bin/matlab -batch "cd SPTinMatlab/tool1_track; spt_geo_strict_smoke"
  grep -c "spt_on_er"    SPTinMatlab/tool1_track/spt_track.m
  grep -c "C(:) = Inf"   SPTinMatlab/tool1_track/spt_link_cost_geo.m
  grep -c "geo_bridge"   SPTinMatlab/tool1_track/spt_track.m
  grep -c "nDetsOffEr"   SPTinMatlab/tool1_track/spt_process_cell.m
  ```
  Pre-existing `spt_track_changes_smoke`, `spt_compare_smoke`, `spt_shape_smoke` all still pass.

---

## Pending / next steps
1. **`train_step.py` kit** (real STEP) — no pretrained weights exist; STEP must be TRAINED on simulated AnDi
   trajectories. Local blockers: only py3.10 is **x86_64/Rosetta (no MPS)** + torch download timed out → train on
   **arm64+MPS or Colab**. Simulation config from WithER is in scratchpad `track_cfg.json` (dt 0.02, len median 75,
   D 0.12–2 µm²/s, σ 30 nm). Deliverable: a script that simulates + trains `XResAttn` (matching `run_step.py`'s
   arch) → `step_D.pt`, + a Colab recipe. Then `run_step.py --weights step_D.pt` upgrades the D with zero code change.
2. **`spt_step_export_all.m` / `spt_step_import_all.m`** — optional: export ALL curated tracks → `run_step.py`
   (real STEP) → re-import D(t) into TrackStruct, replacing the native rolling D.
3. (Optional) declutter the Contact-sites tab — it now has 5 control rows; consider a collapsible "advanced" strip.

## Key data facts (WithER test cell)
- Movie 256×256, **5981 frames**; PXUM ≈ 0.10785 µm/px; dt 0.02006 s.
- **220,401 detections → 101,948 tracked (46%)**; ~17 tracked locs/frame; flat rate (no bleaching).
- Per-track D median 0.76 µm²/s; per-loc: 10.6% confined (≤0.15), 1,815 state-changes in 622/1076 tracks.
- 17 mapped contact sites; density peaks are mostly pass-throughs (median dwell ≈ 9%).

### Link-mode comparison — `250408_WT_012_spt1.tif`, **frames 1–300 ONLY**
> A **300-frame slice**, not the full 5981-frame movie above — the counts here are *not* comparable to the
> 220,401 / 101,948 whole-movie figures and neither set supersedes the other.
Params: 11,535 detections, pxUm 0.10785, link 0.8 µm, gap 1.4 µm, maxGap 1, λ 3, Top 6 %.

| mode | tracks | linked | % linked | medLen | maxLen |
|---|---|---|---|---|---|
| euclid | 560 | 11,111 | 96.3 % | 8.5 | 300 |
| penalty | 617 | 11,108 | 96.3 % | 7 | 300 |
| geodesic | 644 | 10,361 | 89.8 % | 7 | 246 |

- The strict pre-filter excluded **653 of 11,535 detections (5.7 %)** as off their **own** frame's ER.
- **Frames with no ER mask: 0** — the ER stack has 5981 pages, same as the movie.
- Tracks surviving the export default **Min-track-length = 50**: euclid 56, penalty 49, geodesic 37.

## Open design questions (user's call — current behaviour noted)
1. **Should gap closing bridge an ER-segmentation hole at all in strict mode?** *Currently: no* — the bridge must
   be reachable **along** the ER, so a frame where the segmentation drops out breaks the track. The alternative is
   to let a gap span a hole on the assumption it is a seg artefact, not real off-ER travel.
2. **Should a track tolerate *k* consecutive off-ER frames instead of terminating?** *Currently: no tolerance* —
   strict per-frame; one off-ER detection ends the track. A small *k* would trade some strictness for length.
3. **Should the 1 px dilation become a GUI parameter?** *Currently: hard-coded* in `spt_er_support.m`. It ought to
   be tied to the **measured SPT/ER channel offset** rather than assumed, since it sets exactly how far outside the
   segmented ER a detection may sit and still count as on it.

## Standing constraints
- **Never edit or run `ContactSites_original/`** (pristine Nature-2024 reference).
- Clean up any project writes from headless drives (use symlinked temp anaDirs; WithER stays pristine).
</content>
