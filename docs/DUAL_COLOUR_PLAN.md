# Dual-colour tracking — what exists, what is missing, and a plan

Branch: `dual-color-tracking`. Nothing in this document has been implemented yet; it is the plan and
the survey it rests on. Written against commit a5cc3f1.

The target: track TWO species in the same cell, where one colour may carry **half the frames** of the
other (interleaved acquisition, or a strobed second colour), and ask what the two do to each other.

---

## 1. What already exists

More than I expected. Four of the hard parts are already built, for the single-colour case.

**De-interleaving is already per cell.** Tool 1's Detect tab has a `de-interleave` dropdown
(`off / odd pages / even pages`, `spt_app.m:401`). It resolves to a `(stride, offset)` pair
(`deintValue()`, `spt_app.m:1371`), which is stored **on the matched cell**
(`matched(dCell).frameStride / .frameOffset`, `spt_app.m:572`) and passed into the run as
`prm.frameStride / prm.frameOffset` (`spt_app.m:1364`). `spt_process_cell` then reads only those
pages and renumbers them as consecutive frames. **The frame interval is doubled**, because the real
time between kept frames is twice the time between pages — the tooltip says so and the code does it.

So: a two-colour interleaved stack can ALREADY be tracked one colour at a time, with the correct
per-colour frame interval. What it cannot do is keep the two results apart (§2.1).

**A lower-rate channel is already handled — for masks.** When the organelle channel is imaged more
slowly, `segEvery` / `segPage` hold each organelle page across N particle frames as an index map
(nothing is duplicated on disk), with an `auto` mode that reads the ratio from the page counts
(`spt_app.m:411`, `spt_process_cell.m`). This is the same arithmetic a half-rate tracked colour
needs; it is just not available for a channel that carries localizations rather than a mask.

**Interleaving is already detected and reported.** `spt_interleave_check` exists precisely because a
raw interleaved stack detects as a chain of spurious spots along every organelle.

**The whole engagement analysis consumes a channel as a per-localization distance.** This is the
lever the plan turns on. `cs_mito_engage` labels each step BOUND or FREE purely from
`cs_channel_dist(T, key, 'tracked')` (`cs_mito_engage.m:92`) — a per-localization distance array for
one channel key. The same is true of `cs_track_occupancy` and `cs_zone_kinetics`, and the dwell /
engagement-trace machinery in Tool 4 works off distances too.

> **Consequence:** if the second colour can be expressed as a per-localization distance on the first
> colour's tracks, then `Dratio = D_bound/D_free`, per-track occupancy, on/off kinetics and dwell
> times all work on it **with no change to those drivers at all**.

**Time can already be seconds.** The build's `Time unit` dropdown writes the track matrix time column
in frames or seconds, and the apps know which (`secsMode()`).

---

## 2. What is missing

### 2.1 Two runs of one cell collide
A cell is identified by its file stem everywhere — the matcher, the build, the experiment manifest,
the contact-site mapper. Tracking the same stack twice (odd pages, then even) writes over the same
`tracks/<base>_tracks.xml` and the same build entry. There is no channel token in the output names
and no second tracked source on a cell.

### 2.2 No common time axis across colours
Each colour has its own frame numbering and its own dt. Nothing computes `t_s` for a localization,
and nothing records an offset `t0` between the colours. Two builds cannot be put side by side.

### 2.3 No partner distance (a MOVING target)
Every existing distance is to a **static mask** held per organelle page. A second tracked colour is a
moving point set with its own timestamps, and when it carries half the frames, **half of colour A's
localizations have no simultaneous B frame at all**. That is the central new primitive.

### 2.4 No chromatic registration — and this one bites hardest
Nothing in the repo estimates or applies a transform between colours (no `fitgeotrans`, no `tform`,
no bead handling; the only hits for "registration" are in comments). A typical two-camera or
two-filter chromatic offset is **100–300 nm**. The engagement threshold in current use is
`dUm = 0.1` µm. An uncorrected offset is therefore the same size as the effect being measured, and it
biases every colocalization number in one direction.

### 2.5 No UI for a second tracked colour
The Match tab scans `spt/ er_seg/ mito_seg/`. There is no place to declare a second particle channel,
and no way to draw both colours together.

---

## 3. Design

### 3.1 A tracked channel is a SOURCE, not a folder
Per cell, per colour:

```
src = struct('key','ch2', 'file','…/spt/cellA.tif', 'stride',2, 'offset',1, 'dt_s',0.0534, 't0_s',0.0267)
```

One shape covers both acquisitions:
* **interleaved in one stack** — same `file`, `stride = 2`, `offset` 0 or 1;
* **two stacks** — different `file`, `stride = 1`;
* **a strobed half-rate colour** — `stride = 2` (or 4…) within its own source.

`dt_s` is the real interval between the frames actually kept (page interval × stride — what
de-interleave already computes). `t0_s` is when that colour's first kept frame happened, relative to
the other colour's first. Both must be RECORDED, not inferred at read time.

### 3.2 Seconds are the contract between colours
Frames stay as they are (the matrix keeps frame numbers; nothing downstream changes). Each cell gains
`dt_s` and `t0_s` per tracked source, and a helper turns a frame into `t_s = t0_s + frame·dt_s`.
Colours are only ever compared through `t_s`.

### 3.3 The new primitive: `spt_partner_distance(Ta, Tb, opts)`
For every localization of colour A, the distance to the nearest localization of colour B **at a
matching time**, written into `Ta.dist.<key>` so the existing analyses pick it up unchanged.

The half-frame case is exactly why the time rule has to be explicit and recorded:

| `opts.tMatch` | what it does | when it is right |
|---|---|---|
| `nearest` (default) | nearest B frame within `tol_s`; no partner if none | B is dense enough that the gap is small vs. the motion |
| `interpolate` | linear along B's own track between its bracketing frames | B moves smoothly and is well tracked |
| `hold` | last known B position | B is near-static (a structure) |

Also returned per localization: which B track the partner belonged to, the time gap actually used,
and a flag where no partner existed within tolerance. **A missing partner is not distance = ∞** and
must never silently become "far": it is unmeasured, and the fraction of unmeasured localizations has
to be reported beside any colocalization number.

### 3.4 Registration before any distance
`spt_channel_register`: estimate a transform (translation, or affine from beads) between colours,
store it with the project, and apply it to B's coordinates before any partner distance is computed.
Report the residual. Refuse to compute colocalization when no transform has been set, rather than
quietly returning biased numbers — with an explicit "assume perfectly registered" override that is
recorded in the output.

### 3.5 Identity and naming
One cell, two tracked sources. Tool 1 writes `tracks/<base>__<key>_tracks.xml` (and the matching
spots CSV), the build carries the key per cell, and the experiment manifest still sees ONE cell. The
alternative — two cells with different stems — was rejected: the manifest, the mapper and the QC
table would treat the two colours as unrelated cells, and every per-cell ratio would be computed
against the wrong denominator.

---

## 4. Staging

Each stage is independently useful and independently testable.

**Stage 0 — time.** Per-source `dt_s` / `t0_s` on the cell record, and a `spt_time_s` helper.
No behaviour change. Test: a de-interleaved run reports the doubled interval and the right `t0`.

**Stage 1 — two tracked sources per cell.** Channel token in the Tool 1 output names; the build keeps
the key. After this, both colours can be tracked and built without colliding, and every existing
single-colour analysis works on each colour separately.

**Stage 2 — registration.** Driver + a stored transform + residual reporting.

**Stage 3 — partner distance.** `spt_partner_distance` writing `dist.<key>`. At this point
`cs_mito_engage`, `cs_track_occupancy`, `cs_zone_kinetics` and the Tool 4 dwell machinery all work on
colour-vs-colour with no changes.

**Stage 4 — UI.** A second particle channel in the Match tab; a colour selector in Build / Analyse;
both colours drawn in the track panel, with the partner's localizations at the matching time.

**Stage 5 — dual-colour reporting.** Colocalized fraction, encounter dwell times (the existing
Schmitt-trigger detector, run on partner distance instead of distance-to-site), and the Compare tab
grouping those by condition.

---

## 5. Questions that change the design

1. **Interleaved in one stack, or two stacks?** Both are supported by the design; which comes first
   depends on the answer.
2. **Is the half-rate colour regular?** Every other frame is an index map. Irregular or dropped
   frames need the timestamps from the acquisition metadata.
3. **Is colour 2 a tracked MOLECULE or a STRUCTURE?** If it is a structure (e.g. an ER marker), the
   cheaper path is to rasterize it per frame into a mask and reuse the existing organelle machinery
   whole, rather than partner distances.
4. **Is there bead/registration data?** Without it, registration has to be estimated from the data,
   which is weaker and needs stating in any figure legend.
5. **What is the question?** "Do the two colocalize", "how long does an encounter last", and "is A
   slowed near B" need the same plumbing but different headline numbers.
