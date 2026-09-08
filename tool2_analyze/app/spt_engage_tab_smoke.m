function spt_engage_tab_smoke()
%SPT_ENGAGE_TAB_SMOKE  The Engagement tab must carry the driver's answer to the screen intact.
%
% The driver is covered by cs_mito_engage_smoke; this covers the WIRING, which is where a correct
% metric usually goes wrong — a control read from the wrong widget, a unit not converted, a table
% built from a stale result. Driven offscreen against a built TrackStruct with KNOWN tethering.
%
% WHAT IS ASSERTED:
%   1. UNITS      — precision is entered in NANOMETRES and the driver takes microns. Entering 30 must
%                   mean 0.030 um, not 30. This is the single easiest thing to get wrong here and it
%                   would quietly floor every D to zero.
%   2. THE ANSWER — a tethered cell reaches the table with a ratio below 1, an untethered one at ~1,
%                   and they land on the rows that name them.
%   3. THE SCAN   — asking for N distances produces N rows per cell, at the distances requested.
%   4. REFUSAL    — a cell that cannot answer shows a dash and its reason, never a bare number.
%   5. EXPORT     — the CSV holds one row per cell per distance with the step counts, so a compound
%                   can be scored from the file without re-running anything.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(fileparts(here),'drivers')); addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_engtab_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(fullfile(proj,'analysis')); mkdir(fullfile(proj,'tracks'));
cleanup = onCleanup(@() rmdir(proj,'s'));

dt = 0.02; Dfast = 0.40; Dslow = 0.08; dZone = 0.10;
Tracks = [mkCell('tethered_cell',   0.10, dt, Dfast, Dslow), ...
          mkCell('untethered_cell', 0.10, dt, Dfast, Dfast)];
save(fullfile(proj,'analysis','TrackStruct.mat'), 'Tracks', '-v7.3');

f = spt_analyze_app('analyze'); f.Visible = 'off';
closeApp = onCleanup(@() close(f));
pe = findobj(f,'Type','uieditfield');
for k = 1:numel(pe)
    if contains(lower(string(pe(k).Placeholder)),'project')
        pe(k).Value = proj; cb = pe(k).ValueChangedFcn; if ~isempty(cb), cb(pe(k), struct('Value',proj)); end
    end
end
drawnow;

tg = findobj(f,'Type','uitabgroup'); tabs = tg(1).Children;
tg(1).SelectedTab = tabs(arrayfun(@(t) contains(string(t.Title),'Engagement'), tabs));
drawnow;

sp  = findobj(f,'Type','uispinner');
tbl = pick(findobj(f,'Type','uitable'), ...
    @(x) numel(x.ColumnName)>=6 && strcmp(x.ColumnName{6},'ratio'), 'Engagement table');
assert(any(strcmp(tbl.ColumnName,'occ med')) && any(strcmp(tbl.ColumnName,'eng %')), ...
    ['the table has no per-track occupancy columns: %s. This is SPT — the molecule is the unit, and ' ...
     'a pooled per-localization occupancy lets one long resident carry a cell.'], strjoin(tbl.ColumnName',', '));
sig = pick(sp, @(x) isequal(x.Limits,[0 500]),   'precision spinner');
mn  = pick(sp, @(x) isequal(x.Limits,[5 5000]),  'min-steps spinner');
nsc = pick(sp, @(x) isequal(x.Limits,[1 20]),    'scan-count spinner');
bC  = pick(findobj(f,'Type','uibutton'), @(x) strcmp(string(x.Text),'▶ Compute'), 'Compute button');

sig.Value = 30; mn.Value = 100; nsc.Value = 3;      % 30 NM, not 30 um
cb = bC.ButtonPushedFcn; cb(bC, struct()); drawnow;

D = tbl.Data;
assert(~isempty(D), 'Compute produced no table');
%% (3) a 3-distance scan over 2 cells is 6 rows
assert(size(D,1) == 6, 'a 3-distance scan over 2 cells gave %d rows, wanted 6', size(D,1));

%% (1)+(2) the answer, and the units that produce it
rt = ratioFor(D, 'tethered_cell'); ru = ratioFor(D, 'untethered_cell');
fprintf('tethered ratio %.3f · untethered ratio %.3f\n', rt, ru);
assert(isfinite(rt) && isfinite(ru), 'a cell reached the table without a ratio (tethered %g, untethered %g)', rt, ru);
% The middle distance of a 0.05-0.30 scan is 0.175 um, wider than the 0.10 um tethered layer, so
% the contrast here is DILUTED relative to the driver's best case (~0.21 at d = 0.10). The bar is
% set for that: what matters on screen is that it is clearly below 1 and clearly below the control.
assert(rt < 0.6, ...
    ['the tethered cell reached the table at ratio %.3f. If this is ~1 the contrast was lost in the ' ...
     'wiring; if it is 0 the precision was passed as 30 um instead of 0.030 and floored every D.'], rt);
assert(abs(ru - 1) < 0.30, 'the untethered cell reads %.3f, not ~1 — the tab is manufacturing a contrast', ru);
assert(ru > rt*1.5, 'tethered (%.3f) and untethered (%.3f) are not separated on screen', rt, ru);

% THE UNITS, checked by their consequence rather than by an out-of-range value (the spinner is
% limited to 0-500 nm, so 30000 cannot even be typed). D_free must come back near the planted
% Dfast. If 30 were passed through as 30 MICRONS the noise floor 4*sigma^2 per step would swamp
% every displacement and D would floor to zero — so a plausible D_free is the evidence that the
% nm -> um conversion happened.
dfree = freeFor(D, 'untethered_cell');
fprintf('D_free on the untethered cell: %.4f (planted %.2f)\n', dfree, Dfast);
assert(isfinite(dfree) && dfree > 0.4*Dfast && dfree < 1.6*Dfast, ...
    ['D_free came back %.4f against a planted %.2f. Zero or near-zero means the precision was ' ...
     'passed as microns instead of nanometres and the noise floor swallowed every step.'], dfree, Dfast);
% ...and raising the precision to its maximum must visibly lower D, or the floor is not applied
sig.Value = 500; cb(bC, struct()); drawnow;
dfree500 = freeFor(tbl.Data, 'untethered_cell');
assert(~isfinite(dfree500) || dfree500 < dfree, ...
    'a 500 nm precision gave D_free %.4f, not below the %.4f at 30 nm — the noise floor is inert', ...
    dfree500, dfree);
sig.Value = 30; cb(bC, struct()); drawnow;

%% (4) a cell that cannot answer shows a dash and a reason
mn.Value = 5000;                                     % more steps than the fixture has
cb(bC, struct()); drawnow;
D2 = tbl.Data;
noteCol = D2(:,11); ratioCol = D2(:,6);
assert(all(strcmp(ratioCol,'—')), 'a refused cell printed a number instead of a dash');
assert(all(contains(noteCol,'too few')), 'a refused cell did not say why: "%s"', noteCol{1});
fprintf('refusal shown as a dash with a reason: %s\n', noteCol{1});
mn.Value = 100; cb(bC, struct()); drawnow;

%% (5) the export carries what a compound would be scored from
bE = pick(findobj(f,'Type','uibutton'), @(x) strcmp(string(x.Text),'Export CSV'), 'Export button');
cbe = bE.ButtonPushedFcn; cbe(bE, struct()); drawnow;
csv = fullfile(proj,'analysis','exports','cs_engagement_mito.csv');
assert(isfile(csv), 'no engagement CSV at %s', csv);
L = strsplit(strtrim(fileread(csv)), newline);
assert(numel(L) == 7, 'CSV has %d lines, wanted a header + 6 rows', numel(L));
hdr = L{1};
for want = {'D_ratio','n_bound','n_free','n_crossing','condition', ...
            'occ_median_per_track','engaged_frac','n_tracks_scored'}
    assert(contains(hdr, want{1}), 'CSV header is missing %s: %s', want{1}, hdr);
end
fprintf('exported %d rows with the step counts\n', numel(L)-1);

%% (6) the PER-TRACK file — the distribution the per-cell rows summarise ---------------------------
pt = strrep(csv,'.csv','_pertrack.csv');
assert(isfile(pt), ...
    ['no per-track CSV. The per-cell rows are summaries; without the distribution behind them a ' ...
     'bimodal cell (a bound population plus a free one) is indistinguishable from an intermediate one.']);
PL = strsplit(strtrim(fileread(pt)), newline);
assert(numel(PL) > 2, 'the per-track CSV holds %d rows', numel(PL)-1);
ph = PL{1};
for want = {'track_col','n_loc','n_inside','occupancy','engaged'}
    assert(contains(ph, want{1}), 'per-track header is missing %s: %s', want{1}, ph);
end
% every occupancy must be a fraction — a count that escaped normalisation would show up here
v = [];
for i = 2:numel(PL)
    p = strsplit(PL{i}, ','); v(end+1) = str2double(p{7}); %#ok<AGROW>
end
assert(all(v >= 0 & v <= 1), 'a per-track occupancy is outside [0,1]: min %.3g max %.3g', min(v), max(v));
fprintf('per-track file: %d molecules, occupancy in [%.2f, %.2f]\n', numel(PL)-1, min(v), max(v));

%% (7) the examples export asks for a name, and the BUTTON says it worked -----------------------------
% A modal Save dialog cannot be answered headlessly, so the button takes an optional path — the
% same escape hatch onLoadTracks uses. What is asserted here is the part a user sees: the file
% lands where it was told, and the control they clicked confirms it. The status line is a paragraph
% above the table, and a person who just pressed a button is looking at the button.
bEx = pick(findobj(f,'Type','uibutton'), @(x) contains(string(x.Text),'Examples'), 'examples button');
txt0 = char(string(bEx.Text)); col0 = bEx.BackgroundColor;
want = fullfile(proj,'analysis','examples','my_named_subset.mat');
ud = f.UserData;
assert(isfield(ud,'engExamples'), 'the app exposes no headless hook for the examples export');
ud.engExamples(want); drawnow;
assert(isfile(want), 'the examples export ignored the name it was given: %s', want);
assert(~strcmp(char(string(bEx.Text)), txt0), ...
    ['the button still reads "%s" after a successful export. The status line is far from the ' ...
     'button and a silent control reads as a click that did nothing.'], txt0);
assert(~isequal(bEx.BackgroundColor, col0), 'the button colour did not change on export');
fprintf('examples written to a chosen name; button now reads "%s"\n', char(string(bEx.Text)));

fprintf('\nENGAGEMENT-TAB SMOKE PASSED.\n');
end

% ================================================================================================
function r = ratioFor(D, name)
% Ratio for a named cell at the MIDDLE distance of the scan — the same one the per-cell plot uses.
r = NaN;
rows = find(strcmp(D(:,1), name));
if isempty(rows), return; end
mid = rows(max(1,round(numel(rows)/2)));
v = str2double(D{mid,6});
if ~isnan(v), r = v; end
end

function v = freeFor(D, name)
% D_free (column 5) for a named cell, at the middle distance of the scan.
v = NaN;
rows = find(strcmp(D(:,1), name));
if isempty(rows), return; end
mid = rows(max(1,round(numel(rows)/2)));
v = str2double(D{mid,5});
end

function T = mkCell(name, dZone, dt, Dfast, Dslow)
% One cell of a TrackStruct: a zero-width organelle line at x = xc, molecules slowed within dZone.
rng(31 + numel(name));
xc = 5.0; nT = 70; nF = 140;
F = repmat((1:nF)', 1, nT); X = nan(nF,nT); Y = nan(nF,nT);
for j = 1:nT
    x = xc - 1.5 + 3*rand; y = 5*rand;
    for i = 1:nF
        X(i,j) = x; Y(i,j) = y;
        s = sqrt(2*tern_(abs(x-xc) <= dZone, Dslow, Dfast)*dt);
        x = x + s*randn; y = y + s*randn;
    end
end
T = struct();
T.matrix = cat(3, F, X, Y);
T.frameInterval = dt;
T.file = name;
T.dist = struct('mito', abs(X - xc));
end

function h = pick(hs, test, what)
hit = hs(arrayfun(@(x) test(x), hs));
assert(~isempty(hit), 'could not find the %s', what);
h = hit(1);
end

function y = tern_(c,a,b), if c, y = a; else, y = b; end, end
