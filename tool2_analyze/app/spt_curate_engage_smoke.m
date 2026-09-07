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
assert(n0 == 10, 'the QC shows %d tracks, wanted 10', n0);

%% (5) rejecting from the QC removes it from the pooled panels ----------------------------------------
ax = findobj(f,'Type','axes');
cov = pick(ax, @(a) contains(string(a.Title.String),'tracks (click one)'), 'track map');
tr = f.UserData.tracks();
x = tr(1).matrix(:,4,2); y = tr(1).matrix(:,4,3); x = x(isfinite(x)); y = y(isfinite(y));
cbd = cov.ButtonDownFcn; cbd(cov, struct('IntersectionPoint',[x(1) y(1) 0])); drawnow;
rej = pick(findobj(f,'Type','uibutton'), @(b) contains(string(b.Text),'Reject track'), 'reject button');
cb = rej.ButtonPushedFcn; cb(rej, struct()); drawnow;
assert(selCount(f) == 9, ...
    ['after rejecting one track the QC still counts %d of 10. The pooled panels and the export are ' ...
     'still measuring a track the user removed.'], selCount(f));

%% (3) it persisted, readably ---------------------------------------------------------------------------
exf = fullfile(proj,'analysis','track_exclusions.csv');
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
assert(selCount(f) == 10, 'restoring did not bring the track back (%d of 10)', selCount(f));
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
d0 = pick(sp, @(x) isequal(x.Limits,[0.01 5]) && x.Value < 0.2, 'distance-from spinner');
press(etab,'Compute'); drawnow;
tbl = pick(findobj(etab,'Type','uitable'), @(x) any(strcmp(x.ColumnName,'ratio')), 'engagement table');
lbl = pick(findobj(etab,'Type','uilabel'), @(x) contains(string(x.Text),'answered'), 'engagement status');
assert(contains(string(lbl.Text),'EXCLUDED'), ...
    ['the Engagement status line does not mention the rejected track: "%s". A curated ratio must not ' ...
     'look identical to an uncurated one.'], lbl.Text);
assert(contains(string(lbl.Text),'1 hand-rejected'), 'the status line reports the wrong count: "%s"', lbl.Text);

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
