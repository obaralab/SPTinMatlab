# Confirmed bugs + proposed fixes

Each item was verified against the actual source line. Fixes are proposed as before/after — **not applied**, since this
is published-paper code. Line numbers are current as of this reading.

---

## 1. `Final/Revision/CS_builder.m` — builds only ONE contact site (two loop regressions)
The correct implementation is the top-level `Final/CS_builder.m`; this Revision copy regressed on both loops.

**line 18** — outer loop runs only the last cell:
```matlab
% before
for i=size(Tracks,2)
% after
for i=1:size(Tracks,2)
```
**line 25** — `size(CSdata)` returns `[1 N]`; the colon operator uses only the first element, so `1:size(CSdata)` == `1:1`:
```matlab
% before
CSset=1:size(CSdata);
% after
CSset=1:size(CSdata,2);
```
Net effect as written: the last cell only, first CS only → one CS in `CS_final.mat`.
**Recommendation:** use the top-level `Final/CS_builder.m` (both loops correct) and do not run the Revision copy.

---

## 2. `Final/Revision/AssignCSindexByCellv2.m` — references an undefined variable
**line 17** — the function parameter is `TrackStruct`; `Tracks` does not exist in scope → `Unrecognized variable 'Tracks'`:
```matlab
% before
if isfield(Tracks,'CSindexes')
% after
if isfield(TrackStruct,'CSindexes')
```
(The `orderfields` index vectors on lines 18/20 are also hardwired to a 25/26-field layout — reconfirm field count before use.)

---

## 3. `Final/Revision/EntryExitManualClassifier.m` — highlights the wrong trajectory
**line 32** — the XY highlight indexes the track dimension with the loop counter `j` (position in `bindingEvents`),
not the actual track column `bindingEvents(j)`. Line 36 (the R-vs-t plot) does it correctly, so the two panels
disagree and the operator classifies against the wrong path:
```matlab
% before
traj1xy=plot(CSstruct(index(i)).CSmatrix(:,j,2), CSstruct(index(i)).CSmatrix(:,j,3), 'LineWidth',3,'Color','r');
% after
traj1xy=plot(CSstruct(index(i)).CSmatrix(:,bindingEvents(j),2), CSstruct(index(i)).CSmatrix(:,bindingEvents(j),3), 'LineWidth',3,'Color','r');
```
Fixed in `EntryExitManualClassifierv2.m` — prefer v2.

---

## 4. `CSaveragerNoDeff.m` — syntax error in the struct constructor
**line 18** — stray `C` token makes the file fail to parse:
```matlab
% before
CSstd=struct('Cell',[],'cellIndex',[],'csID',[],'center',[],'numLoc',[],'MajorA',[],'MinorA',[]C);
% after
CSstd=struct('Cell',[],'cellIndex',[],'csID',[],'center',[],'numLoc',[],'MajorA',[],'MinorA',[]);
```
Also: `counter2` (line 15) is never incremented because the "profile view" branch is commented out, so the
final `disp('... n=',counter2,' CS with profile view')` always reports 0. Harmless but misleading.

---

## 5. `CSrefinerNoDeff.m` — hardcoded resume point + folder-name case mismatch
**line 15** — starts at cell 15, silently skipping cells 1–14 (leftover resume point):
```matlab
% before
for i=15:size(Files,1)
% after
for i=1:size(Files,1)
```
**line 100** — saves to `'CSData'` (capital D) while the rest of the pipeline uses `'CSdata'`, and no `mkdir` is done.
Works on case-insensitive macOS/Windows filesystems but breaks on case-sensitive ones:
```matlab
% before
save(fullfile(pwd,'CSData',char(files(i))),'CSdata');
% after
save(fullfile(pwd,'CSdata',char(files(i))),'CSdata');
```
(Correction to an earlier note: this file has no `listCSs` variable and does not read time from the X channel —
those claims do not apply here.)

---

## 6. `ContactSiteMapper.m` — silent MitoFlag default (design smell, author-flagged)
**lines 79–90** — when the CS list has no mito-label columns, every CS is silently set to `MitoFlag = false`
(the author left the comment `FIX THIS? SHOULD ASK, NO?`). Consider erroring or prompting instead of defaulting,
so unlabeled datasets aren't silently treated as "no mito contact sites":
```matlab
if size(CSlist.data,2)==6
    warning('No mito-label columns found for %s — defaulting all CS to non-mito.', filebase);
    CSlist.data(:,7:8)=2*ones(size(CSlist.data,1),2);
end
```

---

## Non-bug fragilities worth a guard (not fixed here)
- Unit mismatch: X/Y/centers in µm vs `refboundary` in nm — easy to cross-wire in new code.
- Magic literals recur uncommented: `0.011` (frame period), `6.25` (DL↔SPT px), `30` nm/bin, `4500` nm half-window.
- `orderfields(...)` permutations tied to exact field counts (29 in `AddCSdwelltimes`, 28 in `AssembleClassifiedDwellStructs`) — will silently mis-order or error on schema drift.
- Growth-in-loop without preallocation: `CellAccumulator.m`, `CSensemble1/2.m`, `purifyCSdata.m`, `TempFileCompiler.m`.
- Instruction↔filename drift: instructions cite `AddDwellTimestoCS`, `CS averager.m`, `TempFileCompiler2.m`; shipped files are `AddDwellTimes2CSstruct.m`, `CSaverager.m`, `TempFileCompiler.m`.
