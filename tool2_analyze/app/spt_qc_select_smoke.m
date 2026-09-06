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
%   4. MITO selects on the track's MEDIAN signed distance, so one excursion neither includes nor
%      excludes a track. A min() rule would select any track that ever brushed a mitochondrion,
%      which is a much weaker claim, and the fixture is built so the two rules disagree.
%   5. THE PANELS AGREE — the D-distribution title reports the same n the selection label does.
%   6. THE EXPORT MATCHES — one row per selected track, carrying the fit window each track used,
%      because an adaptive fit chooses that per track and a D without it cannot be compared.
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
spec = { 'A', 60, -0.30, false; 'B', 60,  1.50, false; ...
         'C', 12, -0.20, false; 'D', 60,  1.20, true };
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
    @(x) isequal(x.RowHeight,{}) == false && numel(x.ColumnWidth)==6 && isequal(x.ColumnWidth{1},44), ...
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
mitS = pick(sp, @(x) isequal(x.Limits,[-5 5]),  'mito-distance spinner');
ckM  = pick(findobj(f,'Type','uicheckbox'), @(x) contains(string(x.Text),'near mito'), 'near-mito checkbox');

assert(selCount(f) == 4, 'with no filters the QC shows %d of 4 tracks', selCount(f));
setv(lenS, 30);
assert(selCount(f) == 3, 'len >= 30 selected %d tracks, wanted 3 (the 12-localization one drops)', selCount(f));

%% (4) mito, on the MEDIAN -----------------------------------------------------------------------------
setv(lenS, 0); ckM.Value = true; fire(ckM); setv(mitS, 0);
% A (-0.30) and C (-0.20) have median <= 0. D dips to -0.90 but its MEDIAN is +1.20, so a
% median rule excludes it and a min rule would not — which is the whole point of the choice.
assert(selCount(f) == 2, ...
    ['mito <= 0 selected %d tracks, wanted 2. If this is 3 the filter is using the MINIMUM distance ' ...
     'along the track, which selects any track that ever brushed a mitochondrion.'], selCount(f));

%% (5) the panels report the same n ----------------------------------------------------------------------
setv(lenS, 30);                                   % now A only: long AND median-inside
assert(selCount(f) == 1, 'len>=30 AND mito<=0 selected %d, wanted 1', selCount(f));
t = char(string(axD.Title.String));
assert(contains(t,'n=1'), 'the D distribution says "%s" while the label counts 1 selected track', t);

%% (6) the export carries the selection, and the fit window --------------------------------------------
press(f, 'Export D CSV');
L = dir(fullfile(proj,'analysis','qc_trackD_*_long.csv'));
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

fprintf('4 tracks -> len>=30: 3 · mito<=0 (median): 2 · both: 1 · exported 1 row with its fit window\n');
fprintf('\nQC-SELECT SMOKE PASSED.\n');
end

% ================================================================================================
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
% One cell. spec rows: {name, nLoc, medianMitoUm, dipsInside}.
rng(5); rows = []; SPOT = 0; tid = 0;
for i = 1:size(spec,1)
    tid = tid + 1; n = spec{i,2}; md = spec{i,3}; dip = spec{i,4};
    x0 = 2 + 4*i; y0 = 3 + 2*i;
    d = md + 0.05*randn(n,1);
    if dip, d(round(n/2)+(0:3)) = -0.90; end     % a brief excursion: changes min, not median
    for j = 1:n
        SPOT = SPOT + 1;
        rows(end+1,:) = [tid, SPOT, j-1, (j-1)*0.02, x0+0.05*j, y0+0.04*j, ...
                         100, 100, 140, 4000, d(j), NaN]; %#ok<AGROW>
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
