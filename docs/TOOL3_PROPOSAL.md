# Tool 3 — what I think needs changing, and why

Written 2026-08-07, at commit `09a4583`, while you were asleep.

**Nothing here has been implemented.** Every item below either changes a reported number or is a
judgement call about your analysis, so it is a proposal, not a change. Tool 2's fixes were mostly
about controls that lied; Tool 3's problems are mostly about *numbers that are wrong or unstated*,
which is a different and more careful kind of work.

Ordered by what I would do first.

---

## 1 · A window whose first frame has no ER runs UNCONFINED — and silently

**Severity: high. This one changes site lists and enrichment on real data.**

`cs_channel_mask` (and `segMaskAt` before it) takes the foreground label as *the minimum non-zero
value on the requested page*. That is correct for an ilastik label map — until you hit a frame that
contains none of the organelle. Such a page is entirely label 2, so the rule reads `fg = 2` and
returns `a == 2`, which is the **background**. The mask comes back inverted: all true.

Then `cs_window_picker`'s support fallback is

```matlab
if isempty(m) || ~any(m(:)), m = st.erMip; end
```

An all-true mask is not empty and is not all-false, so **the fallback does not catch it**. That
window is detected over the whole field, and its background median is taken over the whole field
too — the exact failure mode we just spent effort avoiding for no-support-channel projects.

I pinned the current behaviour in `cs_channel_accessor_smoke` (Part D) with a comment, and gave
`cs_channel_mask` a `'FgLabel'` option as the escape hatch, but I did **not** change the default,
because doing so moves `nnz(mask)` on sparse frames, which moves the Monte-Carlo `N`, the enrichment
denominator, the detection domain, and therefore the saved site list.

**Proposed fix.** Take the foreground label from a stack-wide sample, exactly as
`tool1_track/spt_seg_fg_label.m` already does (it probes 16 pages spread through the stack for this
precise reason — its comment says so). Then a frame with no ER yields an empty mask, the existing
fallback fires, and that window is analysed against the whole-movie MIP as intended.

**What it costs you:** any window whose start frame is ER-free will change from "detected over the
whole field" to "detected on the MIP footprint". Site counts and enrichment for those windows will
change — correctly, but they will change. It needs a re-run and a before/after comparison, which is
why I stopped.

---

## 2 · `p = 0` is reported for the strongest sites

**Severity: high for anything downstream of p. Already in `HANDOFF.md` §7.1 awaiting your call.**

`cs_detect.m:80`

```matlab
pv = mean(nullMax >= pk);
```

For a site above all *M* Monte-Carlo maxima this is **exactly 0**. `cs_identify.m:1237` already uses
the add-one form `(1 + Σ) / (M + 1)`, so the two disagree with each other.

`p = 0` breaks log-scale plotting, π₀ estimation, and any FDR curve — the best sites drop out of the
analysis that is supposed to reward them.

**Proposed fix.** Use `(1 + sum(nullMax >= pk)) / (M + 1)` in both places. With the default `M = 100`
the floor becomes `p = 0.0099` instead of `0`.

**Why I have not done it:** it changes every reported p-value. That is your call, and it should be
made once, deliberately, with a note in the methods.

---

## 3 · The enrichment denominator is estimated from the window being tested

**Severity: high for any FDR work. `HANDOFF.md` §7.4.**

`cs_detect.m:67` takes the background median over the support mask **of the same window** the site
was found in. The statistic is therefore not pivotal: it inflates roughly 1.22× at 20 % capture,
against a null whose entire span is 1.41×.

This gates FDR calibration — you cannot calibrate a false-discovery rate on a statistic whose null
distribution shifts with the signal.

**Proposed fix, either of:**
- a leave-sites-out background (mask out detected footprints before taking the median), or
- the 25th percentile instead of the median, which is far less sensitive to the sites themselves.

I would implement both behind a switch and let you compare on the Control cell before choosing.

**Note the interaction with the work already done.** `cs_support_mask` derives its support from the
localizations for no-support-channel projects, which *adds* to this circularity — I flagged that when
you chose it, and it is reported in the picker status line rather than hidden. Fixing this item
would reduce the combined problem materially.

---

## 4 · `stab` is not the independent-replication check it reads as

**Severity: medium. `HANDOFF.md` §7.5.**

`cs_window_picker.m:643` splits **localizations**, not **tracks**, into the two halves it compares.
Localizations from one track land on both sides, so the two halves are not independent and `stab`
overstates reproducibility. A reader of that column will take it as "this site reproduces in
independent data", which it is not.

**Proposed fix.** Split by track id (`st.aT` is already carried for exactly this kind of thing), so
each track contributes to one half only. Rename the column if the meaning shifts.

---

## 5 · No defensible rate normalisation is exported

**Severity: medium. `HANDOFF.md` §7.7.**

Sites per 100 µm² of *analysed ER mask* — `nnz(werMask) * SF²` — is the only site-density figure that
survives a change of field of view or of how much ER is in frame. It is computed nowhere and
exported nowhere, so cross-cell and cross-condition comparisons are currently on raw counts, which
your own analysis (`docs/sec61b_null_statistics.md`) shows move 2.0× with frame rate and 2.3× with
mobility.

**Proposed fix.** Add it to `cs_window_metrics.csv` as a column, and to the Compare tab's metric
list. Cheap, additive, breaks nothing.

---

## 6 · Opening a project can overwrite its calibration

**Severity: medium, and it is a data-integrity issue rather than a statistical one.**

`HANDOFF.md` records that `spt_analyze_app`'s `setProject` calls `writeCalib()`, which writes
`tracks/cs_calib.mat`. So *opening* a project is not read-only — it can replace a calibration record
with whatever the panel currently holds.

This is the Tool 2 "controls that lie" problem with teeth: the panel fields look like a display of
the project's calibration and are in fact an input that overwrites it.

**Proposed fix.** Open read-only. Show the project's recorded calibration; write only when the user
explicitly edits a field or presses a Save/Apply, and log it. The per-cell `Tracks(k).calib` with its
`.src` provenance already exists, so the display has a correct source.

---

## 7 · Smaller things

- **`cs_config` warns rather than errors** when no calibration is found, falling back to the
  reference rig's `27.61 / 0.10785 / 0.020064`. A headless run scrolls that warning past. Making it
  error would break the paper-reproduction scripts out of the box, so it needs a flag rather than a
  flip. (`HANDOFF.md` §7.2.)
- **`spt_pipeline_app.m` and `track_viewer.m` were never in the axes-policy sweep** — if the hover
  data-tip warning reappears, it is from one of those. (`HANDOFF.md` §7.3. Note `track_viewer` has
  since been edited a lot, so this is worth re-checking.)
- **The per-window density maximum is transient** (`cs_window_picker.m:364-367`); the null-vs-null
  quantile ratio needs it persisted. (`HANDOFF.md` §7.6.)
- **`_spt\d*` vs `_spt\d+`** still disagree across ~14 sites, twice inside `spt_analyze_app.m`
  itself (lines 602 and 2759). A stack named with a bare `_spt` keys differently depending on which
  surface resolves it.

---

## What I checked and found NOT to be a problem

So the list above is not mistaken for "everything I looked at".

- **The picker is not slow the way Tool 2 was.** `windowRaw` already caches per window
  (`st.wrc{w}`), and I found no table-filter-inside-a-loop in `cs_window_picker`,
  `cs_window_mapper` or `cs_window_dwell` — the pattern that cost 9.9 s per press in `track_viewer`.
- **Tool 3's spinners are genuine analysis choices**, not provenance: window length, sensitivity,
  contact distance, contrast, opacity, sims. None of them is a Tool 1 record dressed as an input, so
  the Tool 2 "show it, do not let them edit it" fix has no analogue here.
- **The site tables are no longer positional.** `csTable`'s literal `d{k,4}` and `d{k,5..8}` were
  fixed in `492284f`; columns resolve by name.
- **A third channel now reaches every Tool 3 panel** — contours in the picker, fills in the dwell
  overlay, its own cache slot, its own colour.

---

## Suggested order

1. **§1** (inverted mask) — a real bug producing wrong numbers now, and the fix is well understood.
2. **§2** (`p = 0`) — one line, but it changes every p-value, so do it deliberately and note it.
3. **§5** (rate normalisation) — purely additive, breaks nothing, immediately useful.
4. **§6** (calibration write) — data integrity.
5. **§3** (denominator) — the biggest piece of work, and the one that unlocks FDR.
6. **§4**, then §7.

Items 1, 2 and 3 all move published numbers. I would do them together, re-run the Control cell, and
record the before/after in one place.
