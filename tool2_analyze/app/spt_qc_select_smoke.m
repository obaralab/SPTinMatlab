function spt_qc_select_smoke()
%SPT_QC_SELECT_SMOKE  The Build & QC left column selects tracks, and every pooled panel and the
%export describe the SAME selected set.
%
% The left column used to carry two panels that earned their space poorly: a track-LENGTH histogram
% you could read but not act on, and a pooled stepwise-D histogram measuring the same quantity as
% the stepwise D(t) already on the right. Both are gone. In their place the two cuts that actually
% decide whether a track is worth keeping — length, and proximity to mitochondria — are controls,
% and the D distribution, the CSD and the CSV export all follow them.
%
% WHAT IS ASSERTED:
%   1. LAYOUT BY POSITION — the selection row sits directly under the cell table, above the three
%      plots. Asserted on Position, NOT on a screenshot: exportapp mis-renders a uigridlayout nested
%      inside a uigridlayout (it paints the nested one several rows low while Position is correct),
%      so a render of this tab cannot be trusted and a human eyeballing one would "fix" a
%      non-problem. See the minimal repro note in HANDOFF.md.
%   2. THE RETIRED PANELS ARE GONE — no axes titled 'track length' or 'stepwise D (per localization)'.
%   3. LENGTH selects on localization count.
%   4. DISTANCE selects on the track's MEDIAN signed distance, so one excursion neither includes nor
%      excludes a track. A min() rule would select any track that ever brushed the organelle, which
%      is a much weaker claim, and the fixture is built so the two rules disagree.
%   4b. THE CHANNEL IS A CHOICE — mito and ER are separate cuts and select different tracks. Only
%      channels with data are offered, so a project with no ER is never given a filter that would
%      silently select nothing.
%   5. THE PANELS AGREE — the D-distribution title reports the same n the selection label does.
%   6. THE EXPORT MATCHES — one row per selected track, carrying the fit window each track used,
%      because an adaptive fit chooses that per track and a D without it cannot be compared.
%   7. ROW CLICK PICKS THE CELL — clicking a row of the cell table selects it for QC and moves the
%      dropdown with it, so the control still shows which cell you are looking at.
%   8. EXPORT ALL CELLS — the all-cells export covers every cell in the build under the SAME
%      filters, whichever one the dropdown is showing, and names the cell on every row.
%   9. IT SAYS SO — an export that writes a file silently reads as an export that did nothing. The
%      Build log gets a line; the status line and the label beside the button are also set.
%
% Synthetic; reads no dataset. Runs offscreen.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_qcsel_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(fullfile(proj,'tracks'));
cleanup = onCleanup(@() rmdir(proj,'s'));

% Four tracks, chosen so length and mito separate them differently:
%   A  long,  median mito -0.30  (inside)            -> passes both cuts
%   B  long,  median mito +1.50  (far)               -> passes length only
%   C  short, median mito -0.20  (inside)            -> passes mito only
%   D  long,  median mito +1.20 but DIPS to -0.90    -> median far, min near: separates the rules
% The ER column is deliberately the mito column's mirror image — the track nearest mito is the
% furthest from ER — so "the filter uses the channel it was told to" is distinguishable from "the
% filter works but always reads mito".
spec = { 'A', 60, -0.30,  2.00, false; 'B', 60,  1.50, -0.40, false; ...
         'C', 12, -0.20,  2.00, false; 'D', 60,  1.20, -0.30, true };
makeCell(proj, 'cellA', spec);

f = spt_analyze_app('curate'); f.Visible = 'off';
closeApp = onCleanup(@() close(f));
pe = findobj(f,'Type','uieditfield');
for k = 1:numel(pe)
    if contains(lower(string(pe(k).Placeholder)),'project')
        pe(k).Value = proj; cb = pe(k).ValueChangedFcn; if ~isempty(cb), cb(pe(k), struct('Value',proj)); end
    end
end
drawnow;
press(f, 'Build + QC');

%% (2) the retired panels are gone -------------------------------------------------------------------
axAll = findobj(f,'Type','axes');
for bad = {'track length','stepwise D (per localization)'}
    hit = arrayfun(@(a) contains(string(a.Title.String), bad{1}), axAll);
    assert(~any(hit), 'the "%s" panel is still on the QC tab', bad{1});
end

%% (1) the selection row sits under the table, above the plots ----------------------------------------
qs = pick(findobj(f,'Type','uigridlayout'), ...
    @(x) numel(x.ColumnWidth)==7 && isequal(x.ColumnWidth{1},44) && isequal(x.ColumnWidth{2},54), ...
    'QC selection row');
tb = pick(findobj(f,'Type','uitable'), @(x) any(strcmp(x.ColumnName,'med len')), 'build cell table');
axD = pick(findobj(f,'Type','axes'), @(x) contains(string(x.Title.String),'D distribution'), 'D distribution');
% y is measured from the BOTTOM, so "under the table" is a smaller y, and "above the plots" larger.
assert(qs.Position(2) < tb.Position(2), ...
    'the selection row (y=%g) is not below the cell table (y=%g)', qs.Position(2), tb.Position(2));
assert(qs.Position(2) > axD.Position(2) + axD.Position(4), ...
    ['the selection row (y=%g..%g) overlaps or sits below the D distribution (y=%g..%g). It belongs ' ...
     'directly under the table — NB exportapp paints it low even when Position is right, so check ' ...
     'this number rather than a screenshot.'], ...
    qs.Position(2), qs.Position(2)+qs.Position(4), axD.Position(2), axD.Position(2)+axD.Position(4));

%% (3) length ------------------------------------------------------------------------------------------
sp   = findobj(f,'Type','uispinner');
lenS = pick(sp, @(x) isequal(x.Limits,[0 1e5]), 'min-length spinner');
mitS = pick(sp, @(x) isequal(x.Limits,[-5 5]),  'distance spinner');
ddD  = pick(findobj(f,'Type','uidropdown'), @(x) any(strcmp(x.Items,'any distance')), 'distance-channel dropdown');

assert(selCount(f) == 4, 'with no filters the QC shows %d of 4 tracks', selCount(f));
setv(lenS, 30);
assert(selCount(f) == 3, 'len >= 30 selected %d tracks, wanted 3 (the 12-localization one drops)', selCount(f));

%% (4) distance, on the MEDIAN -------------------------------------------------------------------------
setv(lenS, 0); setv(ddD, 'mito'); setv(mitS, 0);
% A (-0.30) and C (-0.20) have median <= 0. D dips to -0.90 but its MEDIAN is +1.20, so a
% median rule excludes it and a min rule would not — which is the whole point of the choice.
assert(selCount(f) == 2, ...
    ['mito <= 0 selected %d tracks, wanted 2. If this is 3 the filter is using the MINIMUM distance ' ...
     'along the track, which selects any track that ever brushed a mitochondrion.'], selCount(f));

%% (4b) the SAME cut against ER picks the other tracks ---------------------------------------------------
assert(any(strcmp(ddD.ItemsData,'er')), ...
    'the distance filter offers no ER option even though the fixture carries ER distances');
setv(ddD, 'er');
% ER is the mirror: B (-0.40) and D (-0.30) are the ones inside it.
assert(selCount(f) == 2, 'ER <= 0 selected %d tracks, wanted 2', selCount(f));
selER = selectedNames(f);
setv(ddD, 'mito'); selMI = selectedNames(f);
assert(~isequal(sort(selER), sort(selMI)), ...
    ['the ER and mito cuts selected the SAME tracks (%s). The filter is not reading the channel it ' ...
     'was told to.'], strjoin(selMI, ','));
setv(ddD, 'mito');

%% (5) the panels report the same n ----------------------------------------------------------------------
setv(lenS, 30);                                   % now A only: long AND median-inside
assert(selCount(f) == 1, 'len>=30 AND mito<=0 selected %d, wanted 1', selCount(f));
t = char(string(axD.Title.String));
assert(contains(t,'n=1'), 'the D distribution says "%s" while the label counts 1 selected track', t);

%% (6) the export carries the selection, and the fit window --------------------------------------------
press(f, 'Export shown');
L = dir(fullfile(proj,'analysis','qc_trackD_*shown_long.csv'));
assert(~isempty(L), 'no long-form CSV was written');
txt = strsplit(strtrim(fileread(fullfile(L(1).folder, L(1).name))), newline);
assert(numel(txt) == 2, 'the CSV holds %d lines, wanted a header + the 1 selected track', numel(txt)-1);
assert(contains(txt{1},'fit_window_pct'), ...
    ['the export omits the fit window. Under an adaptive fit each track chooses its own, so a D ' ...
     'exported without it cannot be compared with another: "%s"'], txt{1});
assert(contains(txt{1},'median_mito_um'), 'the export omits the mito distance the selection was made on');
W = dir(fullfile(proj,'analysis','qc_trackD_*_wide.csv'));
assert(~isempty(W), 'no wide-form (Prism Column) CSV was written');
wtxt = strsplit(strtrim(fileread(fullfile(W(1).folder, W(1).name))), newline);
assert(numel(wtxt) == 2 && strcmp(strtrim(wtxt{1}),'D_um2_per_s'), ...
    'the wide CSV is not a single Prism-pasteable column: header "%s", %d lines', wtxt{1}, numel(wtxt));

%% (9) the export announces itself ------------------------------------------------------------------
ta = pick(findobj(f,'Type','uitextarea'), @(x) any(contains(string(x.Value),'Build log')), 'Build log');
assert(any(contains(string(ta.Value),'Exported')), ...
    ['the Build log has no record of the export. Writing a file with no visible trace reads as an ' ...
     'export that did not happen — the status line alone sits 600 px from the button.']);

%% (7) clicking a table row selects that cell ---------------------------------------------------------
% Two cells now, so "the dropdown followed the click" is distinguishable from "it was already there".
makeCell(proj, 'cellB', { 'E', 50, -0.10, 2.00, false; 'F', 50, 2.00, -0.10, false });
press(f, 'Build + QC');
dd = pick(findobj(f,'Type','uidropdown'), @(x) any(strcmp(x.Items,'All (pooled)')), 'QC cell dropdown');
tb2 = pick(findobj(f,'Type','uitable'), @(x) any(strcmp(x.ColumnName,'med len')), 'build cell table');
assert(strcmp(dd.Value,'All (pooled)'), 'a fresh build should show All (pooled), not %s', dd.Value);
cb = tb2.CellSelectionCallback;
assert(~isempty(cb), ...
    'the cell table has no selection callback, so a row can only be chosen from the dropdown');
cb(tb2, struct('Indices',[2 1])); drawnow;
assert(strcmp(dd.Value,'cellB'), ...
    ['clicking row 2 left the QC dropdown on "%s". Both routes must lead to one place, and the ' ...
     'dropdown must still SHOW which cell is displayed after a click.'], dd.Value);

%% (8) export ALL cells, under the same filters ---------------------------------------------------------
setv(lenS, 0); setv(ddD, '');
assert(selCount(f) == 2, 'cellB alone should show its 2 tracks, showing %d', selCount(f));
press(f, 'Export ALL cells');
A = dir(fullfile(proj,'analysis','qc_trackD_*allcells*_long.csv'));
assert(~isempty(A), 'no all-cells CSV was written');
at = strsplit(strtrim(fileread(fullfile(A(1).folder, A(1).name))), newline);
assert(numel(at) == 7, ...
    ['the all-cells export holds %d rows, wanted 6 (4 tracks in cellA + 2 in cellB). It is exporting ' ...
     'only the cell on screen.'], numel(at)-1);
assert(any(contains(at,'cellA')) && any(contains(at,'cellB')), ...
    'the all-cells export does not name both cells, so its rows cannot be told apart');

% ...and the filters still apply to it
setv(lenS, 30);
press(f, 'Export ALL cells');
A2 = dir(fullfile(proj,'analysis','qc_trackD_*len30*allcells*_long.csv'));
assert(~isempty(A2), 'the all-cells export ignored the length filter (no len30 file)');
a2 = strsplit(strtrim(fileread(fullfile(A2(1).folder, A2(1).name))), newline);
assert(numel(a2) == 6, ...
    ['len>=30 over both cells exported %d rows, wanted 5 (3 in cellA + 2 in cellB). The filters must ' ...
     'apply to the all-cells export — they are the point of it.'], numel(a2)-1);

fprintf('4 tracks -> len>=30: 3 · mito<=0 (median): 2 · both: 1 · exported 1 row with its fit window\n');
fprintf('row click -> cellB · all-cells export 6 rows, 5 after len>=30 · logged\n');
fprintf('\nQC-SELECT SMOKE PASSED.\n');
end

% ================================================================================================
function names = selectedNames(f)
% The selected tracks, identified by their exported track_col. Read off the D-distribution title's
% n and the map title would only give a count; this gives identity, which is what assertion 4b needs.
ls = findobj(f,'Type','axes');
ax = ls(arrayfun(@(a) contains(string(a.Title.String),'D distribution'), ls));
h  = findobj(ax(1),'Type','histogram');
names = {};
if isempty(h), return; end
d = sort(h(1).Data(:))';
names = arrayfun(@(v) sprintf('%.4g', v), d, 'uni', 0);
end

function n = selCount(f)
% The count the selection label reports, which is what every pooled panel is drawn from.
ls = findobj(f,'Type','uilabel');
n = NaN;
for k = 1:numel(ls)
    t = char(string(ls(k).Text));
    m = regexp(t, '^(\d+) of (\d+) tracks selected$', 'tokens','once');
    if ~isempty(m), n = str2double(m{1}); return; end
    m = regexp(t, '^all (\d+) tracks$', 'tokens','once');
    if ~isempty(m), n = str2double(m{1}); return; end
end
assert(isfinite(n), 'the QC selection label was not found — the panels have nothing to agree with');
end

function makeCell(dir_, base, spec)
% One cell. spec rows: {name, nLoc, medianMitoUm, medianErUm, dipsInside}.
rng(5); rows = []; SPOT = 0; tid = 0;
for i = 1:size(spec,1)
    tid = tid + 1; n = spec{i,2}; md = spec{i,3}; ed = spec{i,4}; dip = spec{i,5};
    x0 = 2 + 4*i; y0 = 3 + 2*i;
    d = md + 0.05*randn(n,1);
    e = ed + 0.05*randn(n,1);
    if dip, d(round(n/2)+(0:3)) = -0.90; end     % a brief excursion: changes min, not median
    for j = 1:n
        SPOT = SPOT + 1;
        rows(end+1,:) = [tid, SPOT, j-1, (j-1)*0.02, x0+0.05*j, y0+0.04*j, ...
                         100, 100, 140, 4000, d(j), e(j)]; %#ok<AGROW>
    end
end
tr = fullfile(dir_,'tracks');
xml = fopen(fullfile(tr,[base '_tracks.xml']),'w');
fprintf(xml,'<?xml version="1.0" encoding="UTF-8"?>\n');
fprintf(xml,'<Tracks nTracks="%d" frameInterval="0.02" spaceUnit="um" timeUnit="s">\n', tid);
for t = 1:tid
    r = sortrows(rows(rows(:,1)==t,:),3);
    fprintf(xml,'  <Track TRACK_ID="%d" N_SPOTS="%d">\n',t,size(r,1));
    for j = 1:size(r,1)
        fprintf(xml,'    <Spot SPOT_ID="%d" FRAME="%d" T="%.6f" X="%.6f" Y="%.6f" Z="0.0"/>\n', ...
            r(j,2), r(j,3), r(j,4), r(j,5), r(j,6));
    end
    fprintf(xml,'  </Track>\n');
end
fprintf(xml,'</Tracks>\n'); fclose(xml);
T = array2table(rows,'VariableNames',{'TRACK_ID','SPOT_ID','FRAME','T_s','X_um','Y_um','QUALITY', ...
    'MEAN_INTENSITY','MAX_INTENSITY','TOTAL_INTENSITY','MITO_DIST_UM','ER_DIST_UM'});
T.TRACK_ID = string(T.TRACK_ID);
writetable(T, fullfile(tr,[base '_spots.csv']));
end

function press(f, txt)
b = findobj(f,'Type','uibutton');
h = b(arrayfun(@(x) contains(string(x.Text), txt), b));
assert(~isempty(h), 'button "%s" not found', txt);
cb = h(1).ButtonPushedFcn; cb(h(1), struct()); drawnow;
end

function setv(h, v), h.Value = v; fire(h); end
function fire(h), cb = h.ValueChangedFcn; if ~isempty(cb), cb(h, struct()); end, drawnow; end

function h = pick(hs, test, what)
hit = hs(arrayfun(@(x) safe(test,x), hs));
assert(~isempty(hit), 'could not find the %s', what);
h = hit(1);
end
function tf = safe(test, x), try, tf = logical(test(x)); catch, tf = false; end, end
