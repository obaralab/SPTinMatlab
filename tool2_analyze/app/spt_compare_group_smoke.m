function spt_compare_group_smoke()
%SPT_COMPARE_GROUP_SMOKE  Compare must split each CONDITION into its mito and non-mito sites.
%
% THE PROBLEM THIS FIXES
%   Compare could group by condition OR by mito/non-mito, never both, so the question the experiment
%   is actually asking — "is the mito effect the same in WT as in the FFAT mutant?" — could only be
%   answered by pooling the two halves of every condition together. The 'condition x mito' and
%   'window x mito' groupings cross the two.
%
%   Underneath that sat a matching defect that a by-condition comparison walks straight into.
%   siteUID restarts at 1 in every folder's mapper run, so across an experiment the ids collide, and
%   the old site -> dwell lookup fell through to the FIRST candidate whenever a folder had no dwell
%   record of its own. A condition that was mapped but never dwelled therefore reported another
%   condition's k_out as its own, with a full-looking n. Part (3) asserts that is gone.
%
% WHAT IS ASSERTED, on a four-folder synthetic experiment (WT, FFAT, Dimer, FFAT-Dimer) whose
% folders all restart siteUID at 1 — the collision is the point. FFAT-Dimer is there for its NAME:
% a condition whose own label contains a separator must still pair with its non-mito half, so the
% pairing is carried as (base, mito) alongside the label and never recovered by splitting it.
%   1. CROSSING      — 'condition x mito' yields both halves of every condition, each condition's
%                      mito row adjacent to its own non-mito row, with the right n and mean.
%   2. THE METRICS   — k_out /s and dwell s both cross; the plain groupings still give the pooled
%                      answers they always did.
%   3. NO BORROWING  — Dimer is mapped but never dwelled, so its rows read n=0, NOT another
%                      condition's numbers. This is the regression.
%   4. ONE LABELLER  — sites and dwell EVENTS agree on a group's name, so the CDF is drawn for the
%                      same groups the table lists.
%   7. CELL PICK     — selecting a subset of cells removes the others from every group, and from the
%                      per-point export with them.
%   8. POINTS EXPORT  — the per-datapoint CSVs are the values the TABLE was built from, in Prism's
%                      one-column-per-group shape, plus a long form that can name every point.
%   6. dw% GATE      — a site whose member tracks merely cross it (low dw%) is what a spurious hit
%                      looks like. The dw% gate drops it from EVERY metric, not just the dwell ones,
%                      and takes its dwell events out of the distribution with it.
%   5. SITES FILTER  — 'mito only' grouped by condition is the cross-condition mito comparison, and
%                      the dwell-time distribution under it pools ONLY mito events. A table filtered
%                      one way over a distribution filtered another is one figure telling two
%                      stories, so the filter is asserted on both.
%
% Synthetic data in tempdir; reads no real dataset.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(fileparts(here),'drivers'));

root = fullfile(tempdir, sprintf('spt_cmpgrp_%d', feature('getpid')));
if isfolder(root), rmdir(root,'s'); end
mkdir(root);
cleanup = onCleanup(@() rmdir(root,'s'));

%% the fixture: four day-folders, each restarting siteUID at 1 ----------------------------------
%             csID  mito  kout  meanDwell
wt    = [1 1  4 0.5; 2 1  6 0.7; 3 0 1 2.0; 4 0 3 3.0];   % mito mean k_out 5,  non-mito 2
ffat  = [1 1 10 0.2; 2 1 20 0.4; 3 0 2 5.0; 4 0 4 7.0];   % mito mean k_out 15, non-mito 3
dimer = [1 1 NaN NaN; 2 0 NaN NaN];                       % mapped, NEVER dwelled
ffdim = [1 1  8 1.0; 2 1 12 1.4; 3 0 5 0.6; 4 0 9 1.0];   % mito mean k_out 10, non-mito 7

% Folder names decide the order conditions are first seen (the aggregator walks them sorted).
% WT site csID 2 is the SPURIOUS one: flagged mito and carrying a perfectly ordinary k_out, but its
% member track is only 20% inside — traffic crossing the footprint, not a molecule held at it.
fWT = makeFolder(root,'d1_wt',    'wtA', wt,    true, [90 20 90 90]);
fFF = makeFolder(root,'d2_ffat',  'ffA', ffat,  true);   % every site dwelling (dw% 100)
fDI = makeFolder(root,'d3_dimer', 'dmA', dimer, false);
fFD = makeFolder(root,'d4_ffatdi','fdA', ffdim, true);

manifest = struct();
manifest.folders = {fWT, fFF, fDI, fFD};
manifest.cells   = [cellRec(fWT,'wtA','WT'), cellRec(fFF,'ffA','FFAT'), ...
                    cellRec(fDI,'dmA','Dimer'), cellRec(fFD,'fdA','FFAT-Dimer')];

[CSW, DD] = cs_experiment_aggregate(manifest);
assert(numel(CSW)==14, 'aggregate lost sites: %d of 14', numel(CSW));
assert(isequal(sort(unique({CSW.condition})), {'Dimer','FFAT','FFAT-Dimer','WT'}), 'conditions did not survive the aggregate');
assert(numel(unique([CSW.siteUID]))==4, 'the fixture must reuse siteUIDs across folders — that is the collision under test');
fprintf('aggregate: %d sites, %d dwell records, siteUIDs collide across %d folders\n', ...
    numel(CSW), numel(DD.perSite), numel(manifest.folders));

% Hand the app exactly what the experiment path hands its Compare tab. Loading it as a project's
% own CSW/DD exercises the same grouping code on the same structs without also driving the
% Experiment tab's folder picker.
proj = fullfile(root,'project');
mkdir(fullfile(proj,'analysis')); mkdir(fullfile(proj,'tracks'));
save(fullfile(proj,'analysis','CSW_final.mat'),'CSW','-v7.3');
save(fullfile(proj,'analysis','cs_window_dwell.mat'),'DD','-v7.3');

%% drive the Compare tab offscreen --------------------------------------------------------------
f = spt_analyze_app('analyze'); f.Visible = 'off';
closeApp = onCleanup(@() close(f));
pe = findobj(f,'Type','uieditfield');
for k = 1:numel(pe)
    if contains(lower(string(pe(k).Placeholder)),'project')
        pe(k).Value = proj; cb = pe(k).ValueChangedFcn; if ~isempty(cb), cb(pe(k), struct('Value',proj)); end
    end
end
drawnow;

% Search WITHIN the Compare tab, not the whole figure. Searching the figure worked only while
% Compare owned the only '▶ Compute' button in the app; the Engagement tab then added its own and
% this test failed with "found 2" on a Compare tab that was perfectly healthy. Scope the search to
% the tab under test so a new sibling tab cannot break it.
tab = pick(findobj(f,'Type','uitab'), @(x) contains(string(x.Title),'Compare'), 'Compare tab');
dds = findobj(tab,'Type','uidropdown');
ddGroup  = pick(dds, @(x) any(strcmp(x.Items,'condition x mito')), 'Compare group-by dropdown');
ddMetric = pick(dds, @(x) any(strcmp(x.Items,'k_out /s')) && any(strcmp(x.Items,'mito fraction')), 'Compare metric dropdown');
ddSites  = pick(dds, @(x) any(strcmp(x.Items,'mito only')), 'Compare sites filter');
bCompute = pick(findobj(tab,'Type','uibutton'), @(x) strcmp(string(x.Text),'▶ Compute'), 'Compare Compute button');
tbl      = pick(findobj(tab,'Type','uitable'), ...
    @(x) isequal(x.ColumnName(:)',{'group','n','mean','sem','median','mode'}), 'Compare table');

%% (1)+(2) k_out crossed with mito ---------------------------------------------------------------
D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'k_out /s','condition x mito');
assert(size(D,1)==8, 'condition x mito gave %d rows, wanted 8 (4 conditions x mito/non-mito)', size(D,1));
want = {'WT · mito',2,5; 'WT · non-mito',2,2; 'FFAT · mito',2,15; 'FFAT · non-mito',2,3; ...
        'Dimer · mito',0,NaN; 'Dimer · non-mito',0,NaN; ...
        'FFAT-Dimer · mito',2,10; 'FFAT-Dimer · non-mito',2,7};
for r = 1:size(want,1), assertRow(D, r, want{r,1}, want{r,2}, want{r,3}); end
fprintf('k_out by condition x mito: %s\n', rowsTag(D));

%% (2) dwell crosses too, and the plain groupings are unchanged ----------------------------------
D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'dwell s','condition x mito');
assertRow(D,1,'WT · mito',2,0.6); assertRow(D,2,'WT · non-mito',2,2.5);
assertRow(D,3,'FFAT · mito',2,0.3); assertRow(D,4,'FFAT · non-mito',2,6);
assertRow(D,7,'FFAT-Dimer · mito',2,1.2); assertRow(D,8,'FFAT-Dimer · non-mito',2,0.8);
fprintf('dwell by condition x mito: %s\n', rowsTag(D));

D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'k_out /s','condition');
assert(size(D,1)==4, 'plain condition grouping gave %d rows, wanted 4', size(D,1));
assertRow(D,1,'WT',4,3.5); assertRow(D,2,'FFAT',4,9);
assertRow(D,3,'Dimer',0,NaN); assertRow(D,4,'FFAT-Dimer',4,8.5);

D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'k_out /s','mito vs non-mito');
assert(size(D,1)==2, 'plain mito grouping gave %d rows, wanted 2', size(D,1));
assertRow(D,1,'mito',6,10); assertRow(D,2,'non-mito',6,4);
fprintf('pooled groupings unchanged: condition 4 rows, mito 2 rows\n');

%% (3) THE REGRESSION: a never-dwelled condition borrows nobody's numbers -------------------------
D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'k_out /s','condition x mito');
for r = 5:6
    assert(str2double(D{r,2})==0, ...
        ['%s reported n=%s: a condition that was never dwelled took another folder''s dwell record ' ...
         '(colliding siteUID). It must contribute no value at all.'], D{r,1}, D{r,2});
end
fprintf('never-dwelled condition contributes n=0, not a borrowed k_out\n');

%% (4) sites and events name a group the same way -------------------------------------------------
% The CDF is drawn per group name from the EVENTS; if events labelled themselves differently the
% legend would be empty for every crossed group.
wantCdf = {'WT · mito (','WT · non-mito (','FFAT · mito (','FFAT · non-mito (', ...
           'FFAT-Dimer · mito (','FFAT-Dimer · non-mito ('};
lgs = findobj(f,'Type','legend');
hit = arrayfun(@(L) all(cellfun(@(w) any(startsWith(cellstr(L.String), w)), wantCdf)), lgs);
assert(any(hit), ['the dwell CDF was not drawn for the crossed groups — a dwell EVENT must label ' ...
    'itself exactly as its site does. Legends found: %s'], strjoin(cellfun(@(c) strjoin(c,'/'), ...
    arrayfun(@(L) cellstr(L.String), lgs, 'uni',0), 'uni',0), ' | '));
fprintf('CDF legend agrees with the table: %s\n', strjoin(cellstr(lgs(find(hit,1)).String),', '));

%% (5) the sites filter: mito only, compared BETWEEN conditions ------------------------------------
D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'k_out /s','condition','mito only');
assert(size(D,1)==4, 'mito-only by condition gave %d rows, wanted 4', size(D,1));
assertRow(D,1,'WT',2,5); assertRow(D,2,'FFAT',2,15); assertRow(D,3,'Dimer',0,NaN); assertRow(D,4,'FFAT-Dimer',2,10);
fprintf('mito only by condition: %s\n', rowsTag(D));

D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'k_out /s','condition','non-mito only');
assertRow(D,1,'WT',2,2); assertRow(D,2,'FFAT',2,3); assertRow(D,3,'Dimer',0,NaN); assertRow(D,4,'FFAT-Dimer',2,7);
fprintf('non-mito only by condition: %s\n', rowsTag(D));

% The distribution under the table must be filtered the same way. Every fixture site carries two
% events, so a mito-only WT curve pools the 4 events of its 2 mito sites — never the non-mito ones,
% whose dwells (2.0 s, 3.0 s) would drag the median far off 0.6 s.
compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'dwell s','condition','mito only');
lgs = findobj(f,'Type','legend');
hit = arrayfun(@(L) any(startsWith(cellstr(L.String),'WT (')), lgs);
assert(any(hit), 'no dwell-time distribution was drawn under the mito-only comparison');
lstr = cellstr(lgs(find(hit,1)).String);
wtCurve = lstr{startsWith(lstr,'WT (')};
assert(contains(wtCurve,'n=4') && contains(wtCurve,'med 0.6'), ...
    ['the dwell-time distribution ignored the sites filter: WT pooled "%s", wanted the 4 mito ' ...
     'events (median 0.6 s). A filtered table over an unfiltered distribution is two comparisons ' ...
     'drawn as one figure.'], wtCurve);
fprintf('dwell-time distribution honours the filter: %s\n', strjoin(lstr,' · '));

% Comparing four conditions leaves no PAIR to rank-sum, so the omnibus has to cover it — without
% it a cross-condition comparison reports no statistic at all.
if exist('kruskalwallis','file')==2
    D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'k_out /s','condition','mito only'); %#ok<NASGU>
    lbs = findobj(f,'Type','uilabel');
    st = lbs(arrayfun(@(x) contains(string(x.Text),'by condition'), lbs));
    assert(~isempty(st) && contains(string(st(1).Text),'Kruskal-Wallis'), ...
        'more than two groups reported no omnibus test: "%s"', st(1).Text);
    fprintf('status: %s\n', st(1).Text);
end

%% (6) the dw% gate drops a spurious site from EVERY metric ----------------------------------------
% WT's site 2 is flagged mito and carries an unremarkable k_out of 6, so no metric-level check
% would ever catch it — only its dw% of 20 says the track merely crossed the footprint.
D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'k_out /s','condition x mito','all sites',0);
assertRow(D,1,'WT · mito',2,5);                       % spurious site still in: mean of 4 and 6
D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'k_out /s','condition x mito','all sites',50);
assertRow(D,1,'WT · mito',1,4);                       % gated out: only the real site is left
assertRow(D,2,'WT · non-mito',2,2);                   % ...and nothing else moved
assertRow(D,3,'FFAT · mito',2,15);
fprintf('dw%% >= 50 drops the spurious site: WT mito k_out 5 -> 4 over n 2 -> 1\n');

% It is a SITE gate, not a dwell gate: a metric that never touches dwell must feel it too.
D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'# sites','condition x mito','all sites',50);
assertRow(D,1,'WT · mito',1,1);
D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'enrichment','condition x mito','all sites',50);
assertRow(D,1,'WT · mito',1,2);
fprintf('the gate reaches every metric, not only the dwell ones (# sites, enrichment)\n');

% and the dropped site takes its dwell events out of the distribution with it: WT mito pooled 4
% events unfiltered (two sites x two events), 2 once the spurious site is gone.
compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'dwell s','condition x mito','all sites',50);
lgs = findobj(f,'Type','legend');
hit = arrayfun(@(L) any(startsWith(cellstr(L.String),'WT · mito (')), lgs);
assert(any(hit), 'no dwell-time distribution after the dw%% gate');
lstr = cellstr(lgs(find(hit,1)).String);
wtM = lstr{startsWith(lstr,'WT · mito (')};
assert(contains(wtM,'n=2'), ...
    ['the distribution kept the gated-out site''s events: WT mito pooled "%s", wanted n=2. An event ' ...
     'has to leave with the site it belongs to, or the table and the curve describe different sites.'], wtM);
fprintf('gated site''s events leave the distribution too: %s\n', wtM);

%% (7) picking cells -------------------------------------------------------------------------------
% Driven through the app's headless hook rather than the modal dialog, which would block a batch run.
U = f.UserData;
assert(U.cmpLoad('enrichment'), 'the compare loader refused the fixture');
[ckeys, clabs] = U.cmpCellList();
assert(numel(ckeys)==4, 'cell list has %d entries, wanted 4 (one per fixture cell)', numel(ckeys));
assert(any(contains(clabs,'wtA')) && any(contains(clabs,'FFAT-Dimer')), ...
    'cell labels lost the file or the condition: %s', strjoin(clabs,' | '));

U.cmpSetCells(ckeys(contains(ckeys,'d1_wt') | contains(ckeys,'d2_ffat')));
D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'k_out /s','condition','all sites',0);
assert(size(D,1)==2, 'with 2 of 4 cells selected the table has %d groups, wanted 2', size(D,1));
assertRow(D,1,'WT',4,3.5); assertRow(D,2,'FFAT',4,9);
fprintf('cell selection: 2 of 4 cells -> %s\n', rowsTag(D));

U.cmpSetCells([]);                                     % back to every cell
D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'k_out /s','condition','all sites',0);
assert(size(D,1)==4, 'clearing the cell selection left %d groups, wanted 4 back', size(D,1));

%% (8) the per-datapoint export ---------------------------------------------------------------------
D = compute(ddMetric,ddGroup,ddSites,bCompute,tbl,'k_out /s','condition x mito','all sites',0);
bPts = pick(findobj(tab,'Type','uibutton'), @(x) strcmp(string(x.Text),'Export points'), 'Export points button');
cb = bPts.ButtonPushedFcn; cb(bPts, struct()); drawnow;
ana = fullfile(proj,'analysis');
fw = fullfile(ana,'cs_points_k_out__s_by_condition_x_mito.csv');
fl = fullfile(ana,'cs_points_k_out__s_by_condition_x_mito_long.csv');
fe = fullfile(ana,'cs_dwellevents_by_condition_x_mito.csv');
assert(isfile(fw), 'no wide per-point CSV at %s', fw);
assert(isfile(fl), 'no long per-point CSV at %s', fl);
assert(isfile(fe), 'no dwell-event CSV at %s', fe);

W = strsplit(strtrim(fileread(fw)), newline);
hdr = strsplit(W{1}, ',');
assert(numel(hdr)==size(D,1), 'wide CSV has %d columns for %d groups', numel(hdr), size(D,1));
assert(strcmp(strtrim(hdr{1}),'WT · mito'), 'first column is "%s", wanted the first table row', hdr{1});
% one row per point of the biggest group, padded — 2 sites per group here
assert(numel(W)-1 == 2, 'wide CSV has %d data rows, wanted 2 (the largest group)', numel(W)-1);
col1 = arrayfun(@(r) str2double(subsref(strsplit(W{r},','),substruct('{}',{1}))), 2:numel(W));
assert(isequal(sort(col1), [4 6]), 'WT mito column is %s, wanted the two site k_out values 4 and 6', mat2str(col1));

Lg = strsplit(strtrim(fileread(fl)), newline);
assert(contains(Lg{1},'siteUID') && contains(Lg{1},'dw_pct') && endsWith(strtrim(Lg{1}),'k_out__s'), ...
    'long CSV header lost its identity columns: %s', Lg{1});
% one row per FINITE point: 14 sites less Dimer's 2, which were never dwelled and so have no k_out
nWant = sum(cellfun(@str2double, D(:,2)));
assert(numel(Lg)-1 == nWant, 'long CSV has %d rows; the table accounts for %d points', numel(Lg)-1, nWant);
assert(nWant == 12, 'the fixture should contribute 12 finite k_out points, not %d', nWant);
fprintf('exported %d wide cols, %d long rows, and the dwell events behind the CDF\n', numel(hdr), numel(Lg)-1);

fprintf('\nspt_compare_group_smoke: all assertions passed\n');
end

% ================================================================================================
function D = compute(ddMetric, ddGroup, ddSites, bCompute, tbl, metric, mode, sites, dw)
if nargin < 8 || isempty(sites), sites = 'all sites'; end
if nargin < 9 || isempty(dw), dw = 0; end
ddMetric.Value = metric; ddGroup.Value = mode; ddSites.Value = sites;
eDw = findobj(ancestor(bCompute,'uitab'),'Type','uispinner','-depth',inf);
eDw = eDw(arrayfun(@(x) contains(string(x.Tooltip),'dw%'), eDw));
assert(isscalar(eDw), 'expected exactly one Compare dw%% spinner, found %d', numel(eDw));
eDw.Value = dw;
cb = bCompute.ButtonPushedFcn; cb(bCompute, struct()); drawnow;
D = tbl.Data;
assert(~isempty(D), 'Compute produced no table for %s by %s', metric, mode);
end

function assertRow(D, r, name, n, mu)
assert(strcmp(D{r,1}, name), 'row %d is "%s", wanted "%s" — the mito row of a condition must sit next to its own non-mito row', r, D{r,1}, name);
assert(str2double(D{r,2})==n, '%s: n=%s, wanted %d', name, D{r,2}, n);
got = str2double(D{r,3});
if isnan(mu), assert(isnan(got), '%s: mean=%s, wanted no value', name, D{r,3});
else,         assert(abs(got-mu) < 1e-6, '%s: mean=%s, wanted %g', name, D{r,3}, mu); end
end

function s = rowsTag(D)
p = arrayfun(@(r) sprintf('%s n=%s mean=%s', D{r,1}, D{r,2}, D{r,3}), 1:size(D,1), 'uni',0);
s = strjoin(p, ' · ');
end

function h = pick(hs, test, what)
hit = hs(arrayfun(@(x) test(x), hs));
assert(isscalar(hit), 'expected exactly one %s, found %d', what, numel(hit));
h = hit(1);
end

function c = cellRec(folder, file, cond)
c = struct('folder',folder, 'file',file, 'condition',cond, 'exclude',false);
end

function fo = makeFolder(root, name, cellFile, T, withDwell, dwPct)
% One day/batch folder as the aggregator reads it: CSW_final.mat, plus cs_window_dwell.mat unless
% this folder is the never-dwelled one. T rows are [csID mito kout meanDwell].
% dwPct (optional, per row) is the site's dw%: one member track with that % of its window
% localizations inside the box, so Compare's dw% gate has something real to measure. Default 100.
fo = fullfile(root, name, 'analysis'); mkdir(fo);
n = size(T,1);
if nargin < 6 || isempty(dwPct), dwPct = 100*ones(1,n); end
nF = 20; frv = (1:nF)';
refb = 0.5*[-1 -1;1 -1;1 1;-1 1;-1 -1];       % unit box at the origin; inside=(0,0), outside=(9,9)
CSW = struct('file',{},'cellIndex',{},'csID',{},'window',{},'winFrames',{},'siteUID',{}, ...
             'tracks',{},'refboundary',{},'CSmatrix',{},'MitoFlag',{},'enrichment',{}, ...
             'areaUm2',{},'nMemberLocs',{},'trackLocsInside',{},'trackLocsWin',{}, ...
             'trackPctInside',{},'dt',{});
for k = 1:n
    nIn = round(nF * dwPct(k)/100);
    xv = 9*ones(nF,1); yv = 9*ones(nF,1);
    if nIn > 0, xv(1:nIn) = 0; yv(1:nIn) = 0; end
    CSW(k) = struct('file',cellFile,'cellIndex',1,'csID',T(k,1),'window',1,'winFrames',[1 nF], ...
        'siteUID',k,'tracks',1,'refboundary',refb,'CSmatrix',cat(3,frv,xv,yv), ...
        'MitoFlag',T(k,2),'enrichment',1+T(k,2),'areaUm2',0.2,'nMemberLocs',30, ...
        'trackLocsInside',nIn,'trackLocsWin',nF,'trackPctInside',100*nIn/nF,'dt',0.02);
end
save(fullfile(fo,'CSW_final.mat'),'CSW','-v7.3');
if ~withDwell, return; end

ps = struct('siteUID',{},'file',{},'cellIndex',{},'csID',{},'window',{},'mito',{}, ...
            'numDwell',{},'longest_s',{},'total_s',{},'meanDwell',{},'medianDwell',{},'kout',{});
ev = struct('file',{},'cellIndex',{},'csID',{},'window',{},'siteUID',{},'mito',{}, ...
            'trackCol',{},'entryFrame',{},'exitFrame',{},'dwell',{});
for k = 1:n
    ps(k) = struct('siteUID',k,'file',cellFile,'cellIndex',1,'csID',T(k,1),'window',1, ...
        'mito',logical(T(k,2)),'numDwell',2,'longest_s',T(k,4),'total_s',2*T(k,4), ...
        'meanDwell',T(k,4),'medianDwell',T(k,4),'kout',T(k,3));
    for q = 1:2
        ev(end+1) = struct('file',cellFile,'cellIndex',1,'csID',T(k,1),'window',1,'siteUID',k, ...
            'mito',logical(T(k,2)),'trackCol',q,'entryFrame',10*q,'exitFrame',10*q+1,'dwell',T(k,4)); %#ok<AGROW>
    end
end
DD = struct('dt',0.02,'events',ev,'perSite',ps,'allDwell',[ev.dwell]');
save(fullfile(fo,'cs_window_dwell.mat'),'DD','-v7.3');
end
