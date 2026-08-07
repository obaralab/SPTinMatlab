# Getting started

Single-particle tracking of an ER membrane protein at ER–mitochondria contact sites, from raw movies
to per-site residence times.

This guide assumes **you have never opened MATLAB**. If you have, read Part 0 and skip to Part 3.

---

# Part 0 · The one-page version

*For someone who already knows MATLAB. Everyone else: start at Part 1.*

**You need**

| | |
|---|---|
| MATLAB | R2024b (what this is built and tested on) |
| Add-on | **Image Processing Toolbox** — all three tools |
| Add-on | **Statistics and Machine Learning Toolbox** — Tools 2 and 3 |

**Your data must sit like this.** You create the top three folders; the tools create the rest.

```
MyExperiment/                 ← "the project folder". Point the tools at THIS.
├── spt/                      ← the single-particle movies      (you)
│   └── 250408_WT_012_C3.tif
├── er_seg/                   ← ER segmentation masks           (you)
│   └── 250408_WT_012_er.tiff
├── mito_seg/                 ← mitochondria masks              (you)
│   └── 250408_WT_012_mito.tiff
├── tracks/                   ← Tool 1 writes this
└── analysis/                 ← Tool 2 and 3 write this
```

The three files for one cell must **share a name** apart from their channel ending
(`..._C3`, `..._er`, `..._mito`). That shared part is how the tools know they belong together.

**Run it**

```matlab
addpath('/path/to/SPTinMatlab')   % once per MATLAB session
run_track                          % Tool 1 — detect and track
run_curate                         % Tool 2 — review, then build
run_analyze                        % Tool 3 — contact sites and dwell
```

In order. Each tool reads what the previous one wrote.

---

# Part 1 · Install MATLAB and the two add-ons

### 1.1 Get MATLAB

Most universities have a site licence — search *"[your university] MATLAB licence"*. You will need a
MathWorks account made with your university email address.

Download and install **R2024b**. A newer release will very likely work; an older one is untested.

### 1.2 Install the two add-ons

The pipeline needs two toolboxes. If you missed them during installation you can add them at any
time — you do **not** need to reinstall MATLAB.

1. Open MATLAB.
2. On the **Home** tab, click **Add-Ons** → **Get Add-Ons**.
3. Search for **Image Processing Toolbox**. Click it, then **Install**.
4. Search for **Statistics and Machine Learning Toolbox**. Click it, then **Install**.

### 1.3 Check they are really there

Copy this into the MATLAB command window (the big pane with the `>>` prompt) and press Enter:

```matlab
ver
```

You will get a list. You need to see **both** of these lines:

```
Image Processing Toolbox                              Version ...
Statistics and Machine Learning Toolbox               Version ...
```

If either is missing, go back to 1.2. Nothing else in this guide will work without them.

> **What each one is for.** Image Processing reads the TIFF stacks and does the mask and density
> work. Statistics does the diffusion fitting and the Monte-Carlo null behind contact-site detection.

---

# Part 2 · Get the code onto your computer

You will be given a folder called **`SPTinMatlab`**. Put it somewhere sensible and **remember the
path** — you need it in Part 4.

Good places:

- macOS: `/Users/yourname/Documents/SPTinMatlab`
- Windows: `C:\Users\yourname\Documents\SPTinMatlab`

Do not put it inside Downloads, and avoid folder names with spaces if you can.

**Do not rename anything inside the folder.** The tools find each other by name.

To check you have the whole thing, look inside — you should see:

```
SPTinMatlab/
├── run_track.m
├── run_curate.m
├── run_analyze.m
├── tool1_track/
├── tool2_analyze/
└── docs/
```

If those three `run_*.m` files are not at the top level, you have the wrong folder or an
extra layer of nesting — look for the level that has them.

---

# Part 3 · Lay out your data

**This is where most first attempts fail, so read it carefully.**

### 3.1 The folders

Make one folder per experiment. Inside it, make exactly three folders:

```
MyExperiment/
├── spt/         your single-particle movies (.tif)
├── er_seg/      ER segmentation masks       (.tif / .tiff)
└── mito_seg/    mitochondria masks          (.tif / .tiff)
```

> ### ⚠ Spell them exactly: `spt`, `er_seg`, `mito_seg`
>
> Lower case, with the underscore. This one bites people: **Tool 1 also accepts `erseg` and
> `mitoseg` without the underscore, but Tools 2 and 3 do not.** Name them the short way and Tool 1
> looks like it worked, then Tool 3 quietly finds no masks at all and you get no contact sites with
> no error message. Use the underscore.

Do **not** create `tracks/` or `analysis/` — the tools make those themselves.

### 3.2 The naming rule

For each cell you have three files. They must share one common stem, and differ only in the ending:

| | example | ending |
|---|---|---|
| movie | `250408_WT_012_C3.tif` | `_C3` (your channel name — anything) |
| ER mask | `250408_WT_012_er.tiff` | `_er` |
| mito mask | `250408_WT_012_mito.tiff` | `_mito` |

The shared part — `250408_WT_012` — is the **cell key**. Matching is done on that.

**Accepted endings** (any one of these works):

- **movie** — `_spt`, `_spt1`, `_spt2`…, or your own channel token like `_C3`, `_VAPB`
- **ER** — `_er`, `_er_mip`, `_2_TA_BC`
- **mito** — `_mito`, `_mito_mip`, `_ch1_mito`, `_3_TA_BC`

If your movies use a channel token (`_C3`), **the tools work it out for themselves** by comparing
the movie names to the mask names. Leave the "Strip regex" box in Tool 1 **empty** and it will tell
you which token it found.

**ilastik users:** exports ending `_Probabilities`, `_Simple Segmentation`, `_Segmentation`,
`_Uncertainty` or `_Object Predictions` are handled automatically — you do not have to rename them.

### 3.3 A worked example

```
VAPB_Aug2026/
├── spt/
│   ├── 250408_WT_012_C3.tif
│   └── 250408_WT_015_C3.tif
├── er_seg/
│   ├── 250408_WT_012_er.tiff
│   └── 250408_WT_015_er.tiff
└── mito_seg/
    ├── 250408_WT_012_mito.tiff
    └── 250408_WT_015_mito.tiff
```

Two cells, correctly paired.

### 3.4 If you do not have both channels

You do not need both. A project can have ER only, mito only, or neither — put a `channels.json` file
in the project folder saying so:

```json
{ "channels": [ { "key": "er", "role": "support" } ] }
```

Without that file you get the standard ER + mito setup, which is what you want in almost every case.

---

# Part 4 · Run it

### 4.1 Tell MATLAB where the code is

Every time you start MATLAB, run this **once** (substitute your own path from Part 2):

```matlab
addpath('/Users/yourname/Documents/SPTinMatlab')
```

Nothing visible happens. That is correct.

> **Tip.** To avoid retyping it, use **Home → Set Path → Add Folder…**, pick the `SPTinMatlab`
> folder, and **Save**. Then it is remembered forever and you can skip this step.

### 4.2 Tool 1 — track

```matlab
run_track
```

A window opens. Then:

1. Go to the **Match files** tab.
2. Click the **project folder** picker and choose your `MyExperiment` folder. The three subfolders
   fill in automatically.
3. Press **Scan**.
4. **Check the result line.** It should be green and say how many cells it found and how many
   resolved an ER and mito mask, plus the channel token it worked out. If it is **amber**, your
   naming does not match — go back to Part 3.2.
5. **Detect** tab: leave the top-percentile at 6 % to start.
6. **Track & filter** tab: set the linking distance, pick a linking mode, run, filter (minimum
   length 50 is a reasonable start), then **Export**.

This writes `tracks/` into your project folder.

### 4.3 Tool 2 — curate and build

```matlab
run_curate
```

1. **Import & Curate** tab — the cells load themselves from `tracks/`. There is no file picker.
2. Look through the tracks. Reject bad ones, cut mislinked ones.
3. Press **Export curated**, or **Export + Next** to move straight to the next cell.
4. **Build & QC** tab — type a **Name** for this build, then press **▶ Build + QC**.

The build is the slow step (it computes MSD for every track). It is done **once** per set of curated
tracks. It writes `analysis/<yourname>.mat`.

### 4.4 Tool 3 — analyze

```matlab
run_analyze
```

1. Set the project folder. It opens whatever build Tool 2 last made.
2. **Contact sites** — pick a cell, press **Detect all**, then **Save**.
3. **Refine** — tidy the site boundaries.
4. **Sites** — run the mapper, which decides which tracks belong to which site.
5. **Dwell** — compute residence times.
6. **Compare** — group results across cells and conditions.

---

# Part 5 · When it goes wrong

| What you see | What it means | What to do |
|---|---|---|
| `Undefined function 'run_track'` | MATLAB does not know where the code is | Redo 4.1 with the correct path |
| `Undefined function 'imgaussfilt'` (or similar) | A toolbox is missing | Redo 1.2, then check with `ver` |
| Scan finds cells but **0** ER / mito | The names do not pair up | Part 3.2 — check the endings and the shared stem |
| Scan finds **no** cells at all | Wrong folder, or movies are not `.tif` | Point at the folder that *contains* `spt/`, not at `spt/` itself |
| Tool 3 says no build | Tool 2 never finished a build | Go back and press **▶ Build + QC** |
| Everything is slow on first run | The build is genuinely slow | It is once per build; later stages are fast |

**Nothing is ever overwritten silently.** Every stage writes new files, so if a step goes wrong you
can look at what it produced and re-run just that step.

---

# Where to read more

The full reference — every control in every tool, the maths behind detection, and a worked example
with real numbers — is in **`docs/help.html`**. Open it in any browser, or press the **❓ Help**
button inside any of the three tools.

It opens on a page introducing the three tools, with a search box; press <kbd>/</kbd> to search.
