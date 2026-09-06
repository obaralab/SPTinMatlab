function cs_experiment_smoke()
% Validate the experiment engine: build two "day" folders (each with its own TrackStruct + picked
% sites), map + dwell each, then scan + aggregate across both with per-cell CONDITIONS assigned, and
% confirm the combined CSW/DD carry the right condition labels and group correctly.
here = fileparts(mfilename('fullpath')); addpath(here);
addpath(fileparts(fileparts(here)));   % repo root, where spt_test_data lives
addpath(fullfile(fileparts(here),'app'));                           % spt_experiment_panel
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));        % spt_match / spt_project_calib

% The per-cell calibration half is deliberately FIRST and self-contained: it builds its own synthetic
% project, so it runs on a machine with no dataset installed — and it covers the behaviour most
% likely to be got wrong (a hand-edited value surviving a rescan), which must not be skippable.
calibManifestCheck();

% Needs a REAL built project: the two day-folders are carved out of two of its cells.
src = spt_test_data(fullfile('Project','analysis'));
if isempty(src)
    fprintf('SKIP the aggregation half of %s — test dataset not installed (see spt_test_data.m)\n', mfilename);
    return
end
S = load(fullfile(src,'TrackStruct.mat')); fn=fieldnames(S); Tr=S.(fn{1});
assert(numel(Tr)>=2,'need >=2 cells to split into two day-folders');

root = fullfile(tempdir,'cs_expt'); if isfolder(root), rmdir(root,'s'); end
dayA = fullfile(root,'dayA','analysis'); dayB = fullfile(root,'dayB','analysis');
mkFolder(dayA, Tr(1), src); mkFolder(dayB, Tr(2), src);

% map + dwell each folder (persist CSW_final + cs_window_dwell)
for fo = {dayA, dayB}
    cs_window_mapper(fo{1}, struct('save',true,'verbose',false,'useRefined',false));
    cs_window_dwell(fo{1}, struct('save',true,'verbose',false));
end

% scan both folders
cells = cs_experiment_scan({dayA, dayB});
fprintf('scanned %d cell(s) across 2 folders\n', numel(cells));
assert(numel(cells)==2, 'expected 2 cells');
assert(all([cells.hasCSW]) && all([cells.hasDwell]), 'CSW/dwell not detected');
% derived status matrix
st = [cells.status];
fprintf('status: built=%d mapped=%d dwelled=%d (of 2)\n', nnz([st.built]), nnz([st.mapped]), nnz([st.dwelled]));
assert(all([st.built]) && all([st.mapped]) && all([st.dwelled]), 'status not derived correctly');
assert(all(arrayfun(@(c) c.nTracks>0, cells)), 'nTracks not populated');

% assign conditions: dayA cell -> "WT", dayB cell -> "FFAT"
for k=1:numel(cells)
    if contains(cells(k).folder,'dayA'), cells(k).condition='WT'; else, cells(k).condition='FFAT'; end
end
manifest = struct('folders',{{dayA,dayB}}, 'cells', cells);

% aggregate
[CSW, DD] = cs_experiment_aggregate(manifest);
conds = unique({CSW.condition});
fprintf('combined %d sites; conditions present: %s\n', numel(CSW), strjoin(conds,', '));
assert(numel(CSW) >= 2, 'no sites combined');
assert(isequal(sort(conds), {'FFAT','WT'}), 'conditions not tagged correctly: %s', strjoin(conds,','));
% every site's condition must match its source folder
for k=1:numel(CSW)
    want = 'FFAT'; if contains(CSW(k).srcFolder,'dayA'), want='WT'; end
    assert(strcmp(CSW(k).condition,want), 'site condition mismatch');
end
% dwell events also tagged + groupable
assert(~isempty(DD.events),'no dwell events combined');
evConds = unique({DD.events.condition});
fprintf('combined %d dwell events; conditions: %s\n', numel(DD.events), strjoin(evConds,', '));
assert(isequal(sort(evConds), {'FFAT','WT'}), 'event conditions wrong');
% per-condition site counts
nWT   = nnz(strcmp({CSW.condition},'WT'));
nFFAT = nnz(strcmp({CSW.condition},'FFAT'));
fprintf('sites: WT=%d  FFAT=%d\n', nWT, nFFAT);
assert(nWT>0 && nFFAT>0, 'a condition has no sites');

% exclude: mark the FFAT cell excluded -> its sites drop from the aggregate
for k=1:numel(cells), cells(k).exclude = strcmp(cells(k).condition,'FFAT'); end
manifest.cells = cells;
[CSWx, DDx] = cs_experiment_aggregate(manifest);
fprintf('after excluding FFAT: %d sites (was %d); conditions: %s\n', numel(CSWx), numel(CSW), strjoin(unique({CSWx.condition}),','));
assert(numel(CSWx)==nWT, 'exclude did not drop the FFAT sites');
assert(~any(strcmp({CSWx.condition},'FFAT')), 'excluded FFAT still present');
assert(~any(strcmp({DDx.events.condition},'FFAT')), 'excluded FFAT events still present');

%% one project named two ways must yield ONE set of cells --------------------------------------
% Tool 1 adds the project root; Tools 2 and 3 used to add <project>/analysis. Both land in the same
% <project>/experiment_details.mat and both resolve to the same project, so every cell was listed
% twice — which is what showed up as duplicate rows when opening Analyze after Track and Curate.
pj = fileparts(dayA);                       % the PROJECT root; dayA is its analysis/
nRoot = numel(cs_experiment_scan({pj}));
nBoth = numel(cs_experiment_scan({pj, dayA}));
nSpel = numel(cs_experiment_scan({[pj filesep], pj, dayA, [dayA filesep]}));
fprintf('dedup: root %d · root+analysis %d · 4 spellings %d\n', nRoot, nBoth, nSpel);
assert(nBoth == nRoot, 'project root + its analysis/ produced %d cells, expected %d', nBoth, nRoot);
assert(nSpel == nRoot, 'four spellings of one project produced %d cells, expected %d', nSpel, nRoot);

fprintf('\nALL EXPERIMENT-ENGINE ASSERTIONS PASSED.\n');
end


function calibManifestCheck()
% Calibration is PER CELL, lives in the manifest, is editable there, and — the part that matters —
% a HAND-EDITED value survives a Rescan while an unedited one refreshes.
%
% Why this is the load-bearing test: the whole feature is worthless if Rescan silently puts a
% corrected cell back on the wrong scale. Nothing about that failure is visible — the coordinates
% still come out, just measured with the wrong ruler — so it has to be pinned here.
%
% Two synthetic cells, deliberately different acquisitions: cellA carries nothing readable (so it
% resolves nothing and the user has to type its value in), cellB carries Fiji metadata at 0.16.
root = fullfile(tempdir,'cs_expt_calib'); if isfolder(root), rmdir(root,'s'); end
proj = fullfile(root,'proj'); mkdir(fullfile(proj,'spt'));
writeMovie(fullfile(proj,'spt','cellA.tif'), 64, NaN,  NaN);     % no scale, no interval
writeMovie(fullfile(proj,'spt','cellB.tif'), 64, 0.16, 0.0105);  % a calibrated stack

fig = uifigure('Visible','off'); c = onCleanup(@() delete(fig));
ctl = spt_experiment_panel(fig, struct('seedFolders',{{proj}}));
ctl.setAutoPath(proj);                                   % the manifest lives WITH the project
cells = ctl.getCells();
assert(numel(cells)==2, 'expected 2 synthetic cells, got %d', numel(cells));
[~, ord] = sort({cells.file}); cells = cells(ord);
fprintf('scanned calibration: %s %s(%s) · %s %.5g(%s)\n', ...
    cells(1).file, num2str(cells(1).pixUm), cells(1).pixSrc, cells(2).file, cells(2).pixUm, cells(2).pixSrc);
assert(isnan(cells(1).pixUm) && strcmp(cells(1).pixSrc,'missing'), ...
    'a pixel size was invented for a cell that carries none (%g, %s)', cells(1).pixUm, cells(1).pixSrc);
assert(abs(cells(2).pixUm-0.16) < 1e-9 && strcmp(cells(2).pixSrc,'movie'), ...
    'cellB did not resolve its own pixel size from its movie (%g, %s)', cells(2).pixUm, cells(2).pixSrc);

% ---- the table exposes them, and the two numbers are EDITABLE --------------------------------
tbl = findobj(fig,'Type','uitable'); assert(~isempty(tbl),'no manifest table'); tbl = tbl(1);
cPix = colOf(tbl,'µm/px'); cDt = colOf(tbl,'dt (s)'); cSrc = colOf(tbl,'calib');
assert(~isempty(cPix) && ~isempty(cDt) && ~isempty(cSrc), 'the calibration columns are missing');
assert(tbl.ColumnEditable(cPix) && tbl.ColumnEditable(cDt), 'the calibration columns are not editable');
assert(~tbl.ColumnEditable(cSrc), 'the source column must be a readout, not something to type into');
% an unresolved value shows '–', not a plausible-looking number
rA = rowOf(tbl,'cellA');
assert(strcmp(tbl.Data{rA,cPix},'–'), 'an absent pixel size rendered as "%s" instead of –', tbl.Data{rA,cPix});

% ---- hand-edit cellA through the table's own callback ----------------------------------------
edit(tbl, rA, cPix, '0.222');
edit(tbl, rA, cDt,  '0.031');
cells = byName(ctl.getCells());
assert(abs(cells.cellA.pixUm-0.222) < 1e-12 && strcmp(cells.cellA.pixSrc,'edited') && cells.cellA.pixLock, ...
    'the typed pixel size did not land as a locked edit');
assert(abs(cells.cellA.dtS-0.031) < 1e-12 && cells.cellA.dtLock, 'the typed frame interval did not land as a locked edit');
% out-of-range input is refused rather than stored
edit(tbl, rA, cPix, '99');
assert(abs(byName(ctl.getCells()).cellA.pixUm-0.222) < 1e-12, 'an out-of-range pixel size was accepted');

% ---- THE ONE THAT MATTERS: rescan. The edit survives; the un-edited cell refreshes ------------
% cellB now gains a _settings.txt (as it would once Tool 1 tracked it) recording 0.13 — a value that
% OUTRANKS the 0.16 in its movie, because it is what actually produced the coordinates on disk. A
% rescan must adopt it. cellA's typed 0.222 must not move.
mkdir(fullfile(proj,'tracks'));
writeSettings(fullfile(proj,'tracks','cellB_settings.txt'), 0.13, 0.0105);
ctl.refresh();
cells = byName(ctl.getCells());
fprintf('after rescan: cellA %.5g (%s, lock %d) · cellB %.5g (%s, lock %d)\n', ...
    cells.cellA.pixUm, cells.cellA.pixSrc, cells.cellA.pixLock, ...
    cells.cellB.pixUm, cells.cellB.pixSrc, cells.cellB.pixLock);
assert(abs(cells.cellA.pixUm-0.222) < 1e-12 && strcmp(cells.cellA.pixSrc,'edited') && cells.cellA.pixLock, ...
    'RESCAN OVERWROTE A HAND-EDITED CALIBRATION — that cell is silently back on the wrong scale');
assert(abs(cells.cellA.dtS-0.031) < 1e-12 && cells.cellA.dtLock, 'rescan overwrote a hand-edited frame interval');
assert(abs(cells.cellB.pixUm-0.13) < 1e-9 && strcmp(cells.cellB.pixSrc,'settings'), ...
    'an UNLOCKED value did not refresh on rescan (%g, %s) — that is what Rescan is for', ...
    cells.cellB.pixUm, cells.cellB.pixSrc);

% ---- a value Tool 1 fell back to the PANEL for is labelled 'panel' in the manifest ------------
% spt_project_calib reads it back out of _settings.txt and honestly calls it 'settings' — it IS what
% made the coordinates. The _src marker beside it is what tells a person it was a guess, and the
% manifest is where they look.
writeSettings(fullfile(proj,'tracks','cellB_settings.txt'), 0.13, 0.0105, 'panel');
ctl.refresh();
cells = byName(ctl.getCells());
assert(strcmp(cells.cellB.pixSrc,'panel'), ...
    'a panel fallback still reads as a measurement in the manifest (%s)', cells.cellB.pixSrc);

% ---- and all of it is STORED in the experiment manifest ---------------------------------------
mf = cs_experiment_file(proj);
assert(isfile(mf), 'the manifest was not auto-saved to the project (%s)', mf);
L = load(mf); saved = byName(L.manifest.cells);
assert(abs(saved.cellA.pixUm-0.222) < 1e-12 && saved.cellA.pixLock, ...
    'the edit did not reach experiment_details.mat — it would not survive closing the app');
fprintf('manifest stores per-cell calibration; edits lock, survive rescan, and persist to %s\n', mf);

% ---- a manifest saved BEFORE these fields existed must still load ------------------------------
old = rmfield(L.manifest.cells, {'pixUm','pixSrc','pixLock','dtS','dtSrc','dtLock'});
manifest = struct('folders',{L.manifest.folders},'cells',old); %#ok<NASGU>
legacy = fullfile(root,'legacy.mat'); save(legacy,'manifest','-v7.3');
ctl.load(legacy);
lc = ctl.getCells();
assert(isfield(lc,'pixUm') && isfield(lc,'pixLock'), 'a pre-change manifest did not migrate');
fprintf('a manifest written before per-cell calibration still loads\n\n');
end

% --- helpers for the calibration check ---
function e = edit(tbl, r, c, val)
% Drive the table's own CellEditCallback, so the test exercises the code a keystroke reaches.
e = struct('Indices',[r c],'NewData',val,'PreviousData',tbl.Data{r,c},'EditData',val);
tbl.CellEditCallback(tbl, e);
end
function c = colOf(tbl, name), c = find(strcmp(tbl.ColumnName, name), 1); end
function r = rowOf(tbl, file),  r = find(strcmp(tbl.Data(:,2), file), 1); end
function s = byName(cells)
s = struct(); for k = 1:numel(cells), s.(cells(k).file) = cells(k); end
end

function writeMovie(path, W, pxUm, dt)
% A Fiji-style stack: scale in XResolution, unit in the ImageJ text block. NaN inputs write a stack
% with no calibration at all — the case a cell has to fall back from.
t = Tiff(path,'w');
setTag(t,'Photometric',Tiff.Photometric.MinIsBlack);
setTag(t,'ImageLength',W); setTag(t,'ImageWidth',W);
setTag(t,'BitsPerSample',16); setTag(t,'SamplesPerPixel',1);
setTag(t,'PlanarConfiguration',Tiff.PlanarConfiguration.Chunky);
if isfinite(pxUm)
    setTag(t,'XResolution',1/pxUm); setTag(t,'YResolution',1/pxUm); setTag(t,'ResolutionUnit',1);
    setTag(t,'ImageDescription', sprintf('ImageJ=1.54f\nimages=1\nframes=1\nunit=micron\nfinterval=%.17g\n', dt));
end
write(t, uint16(zeros(W))); close(t);
end

function writeSettings(path, pxUm, dt, pxSrc)
if nargin < 4, pxSrc = 'movie'; end
fid = fopen(path,'w'); c = onCleanup(@() fclose(fid));
fprintf(fid, ['# SPT Track run settings\n' ...
              'tracking.link_mode      = euclid\n' ...
              'calibration.pixel_um    = %g\n' ...
              'calibration.pixel_um_src= %s\n' ...
              'calibration.frame_s     = %.7g\n' ...
              'calibration.frame_s_src = %s\n'], pxUm, pxSrc, dt, pxSrc);
end

function mkFolder(anaDir, Tcell, src)
mkdir(anaDir); mkdir(fullfile(anaDir,'csIDs')); mkdir(fullfile(anaDir,'Densities'));
Tracks = Tcell; save(fullfile(anaDir,'TrackStruct.mat'),'Tracks'); %#ok<NASGU>
base = regexprep(char(Tcell.file),'\.[^.]*$','');
cp(fullfile(src,'csIDs',[base '_CSsites.txt']), fullfile(anaDir,'csIDs',[base '_CSsites.txt']));
Lr = dir(fullfile(src,'Densities',[base '*_rho.tif'])); if ~isempty(Lr), cp(fullfile(Lr(1).folder,Lr(1).name), fullfile(anaDir,'Densities',Lr(1).name)); end
end
function cp(a,b), if isfile(a), copyfile(a,b); end, end
