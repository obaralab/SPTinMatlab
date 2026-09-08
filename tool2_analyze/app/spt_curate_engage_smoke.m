function spt_curate_engage_smoke()
%SPT_CURATE_ENGAGE_SMOKE  Rejecting a track by hand must change the engagement number, persist, and
%be honoured by every surface that measures tracks.
%
% THE POINT OF CURATION is that you look at a track, decide it is not real, and the analysis stops
% counting it. A rejection that is recorded but not applied is worse than none: the list says the
% track is gone and the ratio still contains it.
%
% WHAT IS ASSERTED:
%   1. IT BITES        — the fixture's rejected track visibly moves the ratio. If it did not, every
%                        assertion below could pass with the rejection doing nothing.
%   2. ENGAGEMENT APPLIES IT — Compute drops rejected tracks before cs_mito_engage sees them, and
%                        the status line says how many, because a curated ratio is a different
%                        measurement from an uncurated one.
%   3. IT PERSISTS     — the decision is written to analysis/track_exclusions.csv, readable, with a
%                        reason column, and survives a reload.
%   4. IT IS A TOGGLE  — rejecting the same track again restores it and the number comes back.
%   5. THE QC APPLIES IT — the pooled panels and the per-track D export stop counting it too, so the
%                        two tools cannot disagree about which tracks exist.
%   6b. A SUBSET NEVER BECOMES THE ACTIVE BUILD — loading an examples_* file for inspection must
%      leave the project's active build alone. It did not, and every downstream stage then measured
%      pre-selected tracks: D_free computed only from molecules that also touch the organelle is a
%      depleted, biased pool and the ratio is dragged toward 1.
%   6. IDENTITY SURVIVES SLICING — a decision made while looking at a SUBSET (an examples file,
%                        whose tracks are renumbered from 1) is recorded against the original build
%                        column. Getting this wrong would silently reject a different track.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_curex_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(fullfile(proj,'tracks'));
cleanup = onCleanup(@() rmdir(proj,'s'));

% Four tracks in the zone. Three are genuinely slowed; the fourth is a FAST one sitting in the same
% zone — the kind of thing you would look at and reject. Its presence lifts D_bound, so removing it
% must lower the ratio, and by enough to see.
makeCell(proj, 'cellA');
% The BUILD gets a second cell (a copy under another name) so that excluding one still leaves one to
% measure — otherwise the exclude test cannot tell "the flag was honoured" from "there was nothing
% left". tracks/fixture.mat stays single-cell, which is what assertion 1 measures directly.
Lb = load(fullfile(proj,'analysis','TrackStruct.mat'));
Tracks = [Lb.Tracks, Lb.Tracks]; Tracks(2).file = 'cellB'; %#ok<NASGU>
save(fullfile(proj,'analysis','TrackStruct.mat'),'Tracks','-v7.3');

%% (1) THE FIXTURE MUST BITE — measured directly, before any UI is involved --------------------------
S = load(fullfile(proj,'tracks','fixture.mat'));
o = struct('dUm',0.12,'key','mito','sigmaUm',0,'dt',0.02,'minSteps',10);
rAll = cs_mito_engage(S.Tracks, o);
exOne = cs_track_exclusions('toggle', [], 'cellA', 4, 'fast impostor');
rCut = cs_mito_engage(cs_track_exclusions('apply', exOne, S.Tracks), o);
fprintf('ratio with the impostor %.3f · without it %.3f\n', rAll.Dratio, rCut.Dratio);
assert(isfinite(rAll.Dratio) && isfinite(rCut.Dratio), 'the fixture did not produce a ratio either way');
assert(rCut.Dratio < rAll.Dratio*0.85, ...
    ['rejecting the fast in-zone track moved the ratio from %.3f to %.3f — barely. This fixture ' ...
     'cannot show that curation reaches the number, so nothing below would prove it does.'], ...
    rAll.Dratio, rCut.Dratio);

%% drive the app ---------------------------------------------------------------------------------------
f = spt_analyze_app('curate'); f.Visible = 'off';
closeApp = onCleanup(@() close(f));
pe = findobj(f,'Type','uieditfield');
for k = 1:numel(pe)
    if contains(lower(string(pe(k).Placeholder)),'project')
        pe(k).Value = proj; cb = pe(k).ValueChangedFcn; if ~isempty(cb), cb(pe(k), struct('Value',proj)); end
    end
end
drawnow;
% Load rather than Build: the fixture is a TrackStruct, not a tracks/ folder of XML. With exactly
% one build in analysis/ this button loads the active one without opening a dialog.
press(f,'Load TrackStruct');
n0 = selCount(f);
% 10, not 4: the fixture has 4 tracks in the zone plus 6 far ones that give D_free its statistics,
% and the QC shows every track because no filter is set.
assert(n0 == 20, 'the QC shows %d tracks, wanted 20 (two cells of 10)', n0);

%% (5) rejecting from the QC removes it from the pooled panels ----------------------------------------
ax = findobj(f,'Type','axes');
cov = pick(ax, @(a) contains(string(a.Title.String),'tracks (click one)'), 'track map');
tr = f.UserData.tracks();
x = tr(1).matrix(:,4,2); y = tr(1).matrix(:,4,3); x = x(isfinite(x)); y = y(isfinite(y));
cbd = cov.ButtonDownFcn; cbd(cov, struct('IntersectionPoint',[x(1) y(1) 0])); drawnow;
rej = pick(findobj(f,'Type','uibutton'), @(b) contains(string(b.Text),'Reject'), 'reject button');
cb = rej.ButtonPushedFcn; cb(rej, struct()); drawnow;
assert(selCount(f) == 19, ...
    ['after rejecting one track the QC still counts %d of 20. The pooled panels and the export are ' ...
     'still measuring a track the user removed.'], selCount(f));

%% (3) it persisted, readably ---------------------------------------------------------------------------
exf = cs_ana_path(fullfile(proj,'analysis'),'find','track_exclusions.csv');
assert(isfile(exf), 'no analysis/track_exclusions.csv — the decision did not survive the session');
txt = strsplit(strtrim(fileread(exf)), newline);
assert(numel(txt) == 2, 'the exclusions file has %d rows, wanted 1', numel(txt)-1);
assert(contains(txt{1},'reason'), ...
    'the exclusions file has no reason column: "%s". A rejection nobody can explain later is not defensible.', txt{1});
assert(contains(txt{2},'cellA'), 'the rejected row does not name the cell: "%s"', txt{2});
ex2 = cs_track_exclusions('load', proj);
assert(cs_track_exclusions('count', ex2) == 1 && cs_track_exclusions('has', ex2,'cellA',4), ...
    'the exclusion did not survive a reload');

%% (4) toggling restores ---------------------------------------------------------------------------------
assert(contains(string(rej.Text),'Restore'), ...
    'the button still reads "%s" on an already-rejected track, so the toggle is illegible', rej.Text);
cb(rej, struct()); drawnow;
assert(selCount(f) == 20, 'restoring did not bring the track back (%d of 20)', selCount(f));
assert(cs_track_exclusions('count', cs_track_exclusions('load', proj)) == 0, ...
    'restoring left the row in the file');
cb(rej, struct()); drawnow;                                  % reject again for the Engagement check

%% (6) identity survives slicing --------------------------------------------------------------------------
% Slice away track 1, so the old track 4 becomes column 3 of the subset. A decision recorded from
% the subset must still name column 4 of the build.
Tsl = cs_track_slice(S.Tracks(1), [2 3 4]);
assert(isequal(Tsl.srcCols, [2 3 4]), 'the slice did not record the original columns: %s', mat2str(Tsl.srcCols));
km = cs_track_exclusions('mask', cs_track_exclusions('toggle', [], 'cellA', 4, ''), Tsl);
assert(isequal(km{1}, [true true false]), ...
    ['masking a SUBSET by original column gave %s, wanted [1 1 0]. Column 3 of this subset is ' ...
     'column 4 of the build; keying on the subset column would reject a different track.'], mat2str(km{1}));

%% (6b) loading a SUBSET must not change the active build ---------------------------------------------
act0 = fileread(fullfile(proj,'analysis','active_trackstruct.txt'));
L0 = load(fullfile(proj,'analysis','TrackStruct.mat'));
% Whole-array assignment: cs_track_slice ADDS .srcCols, and writing that back into an element of a
% narrower struct array is "Subscripted assignment between dissimilar structures".
Tracks = cs_track_slice(L0.Tracks(1), [1 2]);                     %#ok<NASGU> a 2-track subset
save(fullfile(proj,'analysis','examples_mito_100nm.mat'),'Tracks','-v7.3');
f.UserData.loadTracksFile(fullfile(proj,'analysis','examples_mito_100nm.mat'));
drawnow;
act1 = fileread(fullfile(proj,'analysis','active_trackstruct.txt'));
assert(strcmp(strtrim(act0), strtrim(act1)), ...
    ['loading examples_mito_100nm.mat changed the active build from "%s" to "%s". A subset is ' ...
     'pre-selected for touching the organelle, so measuring on it computes D_free from a depleted ' ...
     'pool and pulls every ratio toward 1.'], strtrim(act0), strtrim(act1));

%% (6e) a STALE pointer naming a subset must be ignored ---------------------------------------------
% The write path is guarded, but a project can already carry a pointer written before that guard —
% and it is silent: the tool simply computes different numbers. The user's plate had exactly this,
% so an engagement run measured 3044 pre-selected tracks instead of 7615 and every ratio was wrong.
fid = fopen(fullfile(proj,'analysis','active_trackstruct.txt'),'w');
fprintf(fid,'examples_mito_999nm.mat\n'); fclose(fid);
w = warning('off','cs_active_trackstruct:subsetPointer'); restoreW = onCleanup(@() warning(w));
[~, nmAct] = cs_active_trackstruct(fullfile(proj,'analysis'));
assert(~startsWith(nmAct,'examples_'), ...
    ['a pointer naming the subset %s was honoured. Every downstream stage would then measure ' ...
     'pre-selected tracks: D_free from molecules that also touch the organelle is a depleted, ' ...
     'biased pool.'], nmAct);
assert(strcmp(nmAct,'TrackStruct.mat'), 'fell back to "%s" instead of the real build', nmAct);
fid = fopen(fullfile(proj,'analysis','active_trackstruct.txt'),'w');
fprintf(fid,'TrackStruct.mat\n'); fclose(fid);

%% (6d) apply must survive a TRACKLESS cell -------------------------------------------------------------
% A real 93-cell plate has fields where nothing linked. doApply had its own early-out for those that
% handed the cell back WITHOUT .srcCols, while every other cell went through cs_track_slice and got
% it — so the array mixed two field sets and vertcat threw, several frames from the cause. No
% fixture had a trackless cell, so it only surfaced on the user's data.
Tempty = S.Tracks(1); Tempty.file = 'cellNone';
Tempty.matrix = Tempty.matrix(:, [], :);
Tmix = [S.Tracks(1), Tempty];
try
    Tap = cs_track_exclusions('apply', cs_track_exclusions('toggle', [], 'cellA', 4, ''), Tmix);
catch ME
    error(['cs_track_exclusions(''apply'') threw on an array containing a trackless cell: %s\n' ...
           'Every cell must go through cs_track_slice so the field sets match.'], ME.message);
end
assert(numel(Tap) == 2, 'apply returned %d cells for 2 in', numel(Tap));
assert(size(Tap(2).matrix,2) == 0, 'the trackless cell gained %d tracks', size(Tap(2).matrix,2));

%% (6c) loading a subset must MOVE the Name box, and not to the subset ---------------------------------
% The Name box answers "what will Build write?". setActiveTs is what normally updates it and is
% deliberately skipped for a subset, so the box kept a stale name and pointed at a file that was not
% the one on screen. It must change — and NOT to the subset's name, or Build would write over the
% examples file, which is the confusion the subset guard exists to prevent.
eNm = pick(findobj(f,'Type','uieditfield'), ...
    @(x) ischar(x.Value) && strcmp(x.Value,'TrackStruct'), 'build Name field');
eNm.Value = 'something_stale';
subFile = fullfile(proj,'analysis','examples_mito_999nm.mat');
Tracks = cs_track_slice(S.Tracks(1), [1 2]); %#ok<NASGU>
save(subFile,'Tracks','-v7.3');
f.UserData.loadTracks(subFile); drawnow;
assert(~strcmp(eNm.Value,'something_stale'), ...
    ['the Name box still reads "something_stale" after loading a different file, so it names a ' ...
     'build that is not the one on screen.']);
assert(~contains(eNm.Value,'examples_'), ...
    ['the Name box became "%s". Build would then write over the examples subset — exactly what the ' ...
     'subset guard exists to prevent.'], eNm.Value);
assert(strcmp(eNm.Value,'TrackStruct'), ...
    'the Name box reads "%s"; it should snap back to the ACTIVE build, which is what Build writes', eNm.Value);
fprintf('Name box after loading a subset: "%s" (the active build, not the subset)\n', eNm.Value);

%% (2) Engagement applies it, and says so -------------------------------------------------------------------
f2 = spt_analyze_app('analyze'); f2.Visible = 'off';
closeApp2 = onCleanup(@() close(f2));
pe = findobj(f2,'Type','uieditfield');
for k = 1:numel(pe)
    if contains(lower(string(pe(k).Placeholder)),'project')
        pe(k).Value = proj; cb2 = pe(k).ValueChangedFcn; if ~isempty(cb2), cb2(pe(k), struct('Value',proj)); end
    end
end
drawnow;
tg = findobj(f2,'Type','uitabgroup'); tabs = tg(1).Children;
etab = tabs(arrayfun(@(t) contains(string(t.Title),'Engagement'), tabs));
tg(1).SelectedTab = etab; drawnow;
sp = findobj(etab,'Type','uispinner');
mn = pick(sp, @(x) isequal(x.Limits,[5 5000]), 'min-steps spinner'); mn.Value = 10;
sg = pick(sp, @(x) isequal(x.Limits,[0 500]),  'precision spinner'); sg.Value = 0;
% Limits are [-2 5], not [0.01 5]: a NEGATIVE zone threshold is legal and means "at least this
% far INSIDE the mask", which the panel could not express before.
d0 = pick(sp, @(x) isequal(x.Limits,[-2 5]) && x.Value < 0.2, 'distance-from spinner'); %#ok<NASGU>
press(etab,'Compute'); drawnow;
tbl = pick(findobj(etab,'Type','uitable'), @(x) any(strcmp(x.ColumnName,'ratio')), 'engagement table');
lbl = pick(findobj(etab,'Type','uilabel'), @(x) contains(string(x.Text),'answered'), 'engagement status');
assert(contains(string(lbl.Text),'EXCLUDED'), ...
    ['the Engagement status line does not mention the rejected track: "%s". A curated ratio must not ' ...
     'look identical to an uncurated one.'], lbl.Text);
assert(contains(string(lbl.Text),'1 hand-rejected'), 'the status line reports the wrong count: "%s"', lbl.Text);

%% (7) Engagement honours the Experiment tab's per-cell EXCLUDE flag ------------------------------------
% The durable per-cell judgement. cs_experiment_aggregate has always honoured it, so a plate that
% dropped a cell in Compare and kept it here gave two different answers with nothing to say why.
ec = f2.UserData.exptCtl();
assert(~isempty(ec) && isstruct(ec), 'the Experiment panel was never built in analyze mode');
cellsE = ec.getCells();
assert(~isempty(cellsE), 'the Experiment tab found no cells, so there is nothing to exclude');
nBefore = size(tbl.Data,1);
sel0 = ec.getSelected(); %#ok<NASGU>
% exclude the FIRST cell through the panel's own control, the way a user would
ecCells = ec.getCells();
tgtFile = ecCells(1).file;
tblE = pick(findobj(f2,'Type','uitable'), @(x) any(strcmp(x.ColumnName,'excl')), 'experiment table');
tblE.Selection = 1;
bx = pick(findobj(f2,'Type','uibutton'), @(x) contains(string(x.Text),'Exclude'), 'exclude button');
cbx = bx.ButtonPushedFcn; cbx(bx, struct()); drawnow;
after = ec.getCells();
h = find(strcmp({after.file}, tgtFile),1);
assert(~isempty(h) && after(h).exclude, 'the exclude flag did not stick on %s', tgtFile);
press(etab,'Compute'); drawnow;
nAfter = size(tbl.Data,1);
assert(nAfter < nBefore, ...
    ['the engagement table still has %d rows after excluding a cell (was %d). The Experiment tab''s ' ...
     'exclude flag is not reaching Engagement, so the same plate answers differently here and in ' ...
     'Compare.'], nAfter, nBefore);
assert(~any(strcmp(tbl.Data(:,1), tgtFile)), 'the excluded cell %s is still in the table', tgtFile);
lbl2 = pick(findobj(etab,'Type','uilabel'), @(x) contains(string(x.Text),'answered'), 'engagement status');
assert(contains(string(lbl2.Text),'EXCLUDED on the Experiment tab'), ...
    'the status line does not mention the excluded cell: "%s"', lbl2.Text);
fprintf('excluding 1 cell on the Experiment tab: %d -> %d engagement rows\n', nBefore, nAfter);

fprintf('QC 4 -> 3 tracks · persisted with a reason · toggles back · subset identity holds · Engagement says EXCLUDED\n');
fprintf('\nCURATE-ENGAGE SMOKE PASSED.\n');
end

% ================================================================================================
function makeCell(proj, base)
% One cell, four tracks all inside a 0.12 µm zone around a line at x = 5:
%   1-3  slow (D 0.05) — genuinely engaged
%   4    FAST (D 0.60) — an impostor sitting in the zone, which lifts D_bound
% Everything else in the field is far away and fast, so D_free is well determined.
rng(12); dt = 0.02; nF = 120;
slow = 0.05; fast = 0.60; free = 0.40;
inX = [4.98 5.02 4.96 5.00]; inD = [slow slow slow fast];
farX = 8 + (0:5)*0.7;
nT = numel(inX) + numel(farX);
F = repmat((1:nF)', 1, nT); X = nan(nF,nT); Y = nan(nF,nT);
for j = 1:nT
    if j <= numel(inX), x0 = inX(j); D = inD(j); else, x0 = farX(j-numel(inX)); D = free; end
    s = sqrt(2*D*dt);
    % The in-zone tracks are held near the line (a tether); the far ones diffuse freely.
    if j <= numel(inX)
        X(:,j) = x0 + s*cumsum(randn(nF,1))*0.15;            % stays inside the zone
    else
        X(:,j) = x0 + s*cumsum(randn(nF,1));
    end
    Y(:,j) = 3 + s*cumsum(randn(nF,1));
end
T = struct();
T.matrix = cat(3, F, X, Y);
T.frameInterval = dt; T.file = base;
T.dist = struct('mito', abs(X - 5));
T.MSD = rand(nF-1, nT); T.Dt = rand(nF, nT); T.CSD = cumsum(rand(nF-1, nT));
T.lengths = repmat(nF, nT, 1); T.trackIDs = (1:nT)';
Tracks = T; %#ok<NASGU>
save(fullfile(proj,'tracks','fixture.mat'),'Tracks');
% Also as a build, so the app can load it without an import
a = fullfile(proj,'analysis'); if ~isfolder(a), mkdir(a); end
save(fullfile(a,'TrackStruct.mat'),'Tracks','-v7.3');
fid = fopen(fullfile(a,'active_trackstruct.txt'),'w'); fprintf(fid,'TrackStruct.mat\n'); fclose(fid);
end

function n = selCount(f)
ls = findobj(f,'Type','uilabel');
n = NaN;
for k = 1:numel(ls)
    t = char(string(ls(k).Text));
    % Not anchored at the end: the label gained a "· N rejected" suffix, and an anchored pattern
    % simply stopped matching rather than reporting a wrong count.
    m = regexp(t, '^(\d+) of (\d+) tracks selected', 'tokens','once');
    if ~isempty(m), n = str2double(m{1}); return; end
    m = regexp(t, '^all (\d+) tracks', 'tokens','once');
    if ~isempty(m), n = str2double(m{1}); return; end
end
assert(isfinite(n), 'the QC selection label was not found');
end

function press(h, txt)
b = findobj(h,'Type','uibutton');
q = b(arrayfun(@(x) contains(string(x.Text), txt), b));
assert(~isempty(q), 'button "%s" not found', txt);
cb = q(1).ButtonPushedFcn; cb(q(1), struct()); drawnow;
end

function h = pick(hs, test, what)
hit = hs(arrayfun(@(x) safe(test,x), hs));
assert(~isempty(hit), 'could not find the %s', what);
h = hit(1);
end
function tf = safe(test, x), try, tf = logical(test(x)); catch, tf = false; end, end
