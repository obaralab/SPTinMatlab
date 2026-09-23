function cs_advisor_viewer_smoke()
%CS_ADVISOR_VIEWER_SMOKE  A ContactSites folder (the advisor layout) must open in the tool's viewer and
%in the shipped snippet, and both must show what the files hold.
%
% WHAT IS ASSERTED:
%   1. THE VIEWER OPENS THE FOLDER: one row per cell, the selected cell's sites, the selected site's
%      member tracks; the frame interval is the folder's own (imaging_settings.csv), not 0.011.
%   2. IT SHOWS THE SITE'S OWN NUMBERS: the member-track "in" column adds up to the site's refLocIDs,
%      and the view frames the whole outline even when the outline is bigger than the neighbourhood
%      square (half the sites on a real plate) - it used to run off the edge.
%   3. A HAND-ANNOTATED SITE SHOWS ITS ANNOTATION: bound tracks, dwell times, and the bound interval
%      shaded on the distance-vs-time plot at the annotated times, not rescaled.
%   4. THE APP OPENS IT: the Contact sites tab's "View advisor format" reaches the same viewer.
%   5. THE SNIPPET RUNS ON THE FOLDER with no pipeline file on its dependency list, and reaches the
%      same localizations the site says are inside.
%
% Synthetic; reads no dataset. The viewer runs with its figure invisible.

here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));          % the two tools share the build, the channels and the manifest
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'), ...
        fullfile(root_,'tool3_contactsites','app'));
addpath(fullfile(fileparts(here),'app'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

root = fullfile(tempdir, sprintf('spt_advview_%d', feature('getpid')));
if isfolder(root), rmdir(root,'s'); end
mkdir(root); cleanup = onCleanup(@() rmdir(root,'s'));
d = fullfile(root, 'VAPBlike'); mkdir(d);

% two cells; cell 1 has a small site and a site whose outline is LARGER than the 1.024 um square
cells = struct('base', {}, 'T', {}, 'sites', {}, 'cond', {}, 'dims', {});
th = linspace(0, 2*pi, 60)';
for c = 1:2
    T = mkCell(sprintf('cell%d', c), c);
    S = site(1, [5 5], [5.02 4.99], 0.15*[cos(th) sin(th)], true);
    if c == 1, S(2) = site(2, [9 9], [9 9], 0.75*[cos(th) sin(th)], false); end
    cells(c) = struct('base', T.file, 'T', T, 'sites', S, 'cond', '', 'dims', [100 100]); %#ok<AGROW>
end
cs_advisor_format(d, 'VAPBlike', cells, struct('frameInterval_s', 0.02));

% simulate a hand annotation on CS 1, the way DwellTimeManual.m + EntryExitManualClassifierv2.m
% leave it: trackBinding per member track, DwellTimes(j).EntryPts/ExitPts in seconds
L = load(fullfile(d,'CS_final_v3.mat')); CS = L.CS;
nt = numel(CS(1).tracks);
CS(1).trackBinding = zeros(1, nt); CS(1).trackBinding(1) = 1;
dw = repmat(struct('trackID',[],'EntryPts',[],'ExitPts',[],'DwellTimes',[],'Class',[],'EntryBool',[],'ExitBool',[]), 1, nt);
dw(1).trackID = CS(1).tracks(1); dw(1).EntryPts = [0.20 0.1]; dw(1).ExitPts = [0.60 0.1];
dw(1).DwellTimes = dw(1).ExitPts - dw(1).EntryPts; dw(1).EntryBool = 1; dw(1).ExitBool = 1;
CS(1).DwellTimes = dw; CS(1).NumEntry = [1 NaN(1, nt-1)]; CS(1).NumExit = CS(1).NumEntry;
save(fullfile(d,'CS_final_v3.mat'), 'CS');

%% (1) the viewer opens the folder ----------------------------------------------------------------------
f = cs_advisor_viewer(d, struct('Visible','off'));
closer = onCleanup(@() closeQuietly(f));
U = f.UserData;
tabs = findobj(f, 'Type', 'uitable');
tCells = pick(tabs, 'cell'); tSites = pick(tabs, 'csID'); tTrk = pick(tabs, 'track');
assert(size(tCells.Data,1) == 2 && strcmp(tCells.Data{1,2}, 'cell1'), 'the cell list is not the folder''s cells');
assert(size(tSites.Data,1) == 2, 'cell 1 should list its 2 sites, got %d', size(tSites.Data,1));
assert(abs(U.data.dt - 0.02) < 1e-12, ...
    'the frame interval is %.4g; the folder records 0.02 s in imaging_settings.csv', U.data.dt);

%% (2) the site's own numbers, and a big outline stays in view ----------------------------------------------
U.selectSite(2); drawnow;
s2 = U.data.CS(2);
inCol = cell2mat(tTrk.Data(:,3));
assert(sum(inCol) == numel(s2.refLocIDs), 'the tracks'' "in" column sums to %d; the site has %d refLocIDs', sum(inCol), numel(s2.refLocIDs));
ax = pick(findobj(f,'Type','axes'), 'CS 2');
ob = s2.refboundary/1000 + s2.refCenter;
assert(all(ob(:,1) >= ax.XLim(1) & ob(:,1) <= ax.XLim(2) & ob(:,2) >= ax.YLim(1) & ob(:,2) <= ax.YLim(2)), ...
    'an outline larger than the neighbourhood square runs off the view (x %s, outline %.2f-%.2f)', ...
    mat2str(ax.XLim,3), min(ob(:,1)), max(ob(:,1)));

%% (3) the annotation ------------------------------------------------------------------------------------------
U.selectSite(1); drawnow;
assert(strcmp(tSites.Data{1,9}, '1'), 'CS 1 is annotated with 1 bound track; the site table says "%s"', tSites.Data{1,9});
U.selectTrack(1); drawnow;
assert(strcmp(tTrk.Data{1,5}, '1') && strcmp(tTrk.Data{1,6}, '0.40'), ...
    'track 1 should show 1 binding event of 0.40 s; got "%s" / "%s"', tTrk.Data{1,5}, tTrk.Data{1,6});
axRT = pick(findobj(f,'Type','axes'), 'highlighted');
pt = findobj(axRT, 'Type', 'patch');
assert(isscalar(pt) && abs(min(pt.XData) - 0.20) < 1e-12 && abs(max(pt.XData) - 0.60) < 1e-12, ...
    'the bound interval should be shaded from 0.20 to 0.60 s as annotated');

%% (4) the app reaches it ---------------------------------------------------------------------------------------
app = spt_analyze_app('analyze'); app.Visible = 'off';
closeApp = onCleanup(@() closeQuietly(app));
assert(~isempty(findobj(app, 'Tag', 'csViewAdvisor')), 'the Contact sites tab has no View advisor format button');
fv = app.UserData.viewAdvisor(d);
closeFv = onCleanup(@() closeQuietly(fv));
assert(~isempty(fv) && isgraphics(fv) && fv.UserData.data.nCells == 2, 'the app''s button did not open the folder');
fv.Visible = 'off';

%% (5) the snippet ----------------------------------------------------------------------------------------------------
scr = fullfile(d, 'open_advisor_format.m');
assert(isfile(scr), 'the folder has no open_advisor_format.m');
deps = matlab.codetools.requiredFilesAndProducts(scr);
assert(isscalar(deps) && strcmp(deps{1}, scr), 'the snippet depends on pipeline files: %s', strjoin(deps, ', '));
oldVis = get(groot, 'DefaultFigureVisible'); set(groot, 'DefaultFigureVisible', 'off');
restoreVis = onCleanup(@() set(groot, 'DefaultFigureVisible', oldVis));
[out, got] = runSnippet(scr);
close all force
assert(contains(out, '2 cells') && contains(out, 'dwell 0.4 s') && contains(out, 'MitoEnrichCoeff NaN'), ...
    'the snippet did not run through (or divided by zero for a cell with no other sites): %s', out);
Lt = load(fullfile(d, 'VAPBlike_Tracks_finalv3.mat')); T1 = Lt.Tracks(CS(1).cellIndex);
ids = CS(1).refLocIDs;
want = [T1.matrix(ids) T1.matrix(ids + numel(T1.matrix(:,:,1))) T1.matrix(ids + 2*numel(T1.matrix(:,:,1)))];
assert(isequal(got, want) && ~isempty(want), ...
    'the snippet''s "inside" localizations (%d) are not the frame/x/y of CS 1''s refLocIDs (%d)', size(got,1), size(want,1));

fprintf('viewer: 2 cells, sites, tracks, dt 0.02 from the folder, big outline framed, annotation shaded 0.20-0.60 s · app button · snippet runs with no pipeline code\n');
fprintf('\nADVISOR-VIEWER SMOKE PASSED.\n');
end

% ================================================================================================
function [out, inside] = runSnippet(scr)
% run() executes the script in this function's workspace; `inside` is one of its variables.
inside = [];
out = evalc('run(scr)');
end

function closeQuietly(h)
try, if ~isempty(h) && isgraphics(h), close(h); end, catch, end
end

function e = site(id, pickUm, centre, rb, mito)
SF = 0.03;
e = struct('csID', id, 'center', centre, 'refboundary', rb, 'pickPx', pickUm/SF, 'SF', SF, ...
           'winFrames', [-Inf Inf], 'mito', mito);
end

function T = mkCell(name, seed)
rng(seed); nF = 50; tr = {};
for j = 1:6, tr{end+1} = [5 5] + 0.02*cumsum(randn(nF,2))/3; end   %#ok<AGROW>
for j = 1:6, tr{end+1} = [9 9] + 0.05*cumsum(randn(nF,2))/3; end   %#ok<AGROW>
for j = 1:4, tr{end+1} = 2 + 8*rand(1,2) + 0.05*cumsum(randn(nF,2))/3; end %#ok<AGROW>
nT = numel(tr); X = nan(nF,nT); Y = X;
for j = 1:nT, X(:,j) = tr{j}(:,1); Y(:,j) = tr{j}(:,2); end
Fr = repmat((0:nF-1)', 1, nT); st = hypot(diff(X), diff(Y));
T = struct('file', name, 'lengths', repmat(nF,nT,1), 'matrix', cat(3,Fr,X,Y), ...
    'center', cat(3,Fr,X-X(1,:),Y-Y(1,:)), 'rawSteps', cat(3,ones(nF-1,nT),st), 'steps', st, 'MSDdata', [], ...
    'MSD', st.^2, 'MSDerror', zeros(nF-1,nT), 'MSDstdev', zeros(nF-1,nT), 'CSD', cumsum(st), ...
    'CSDnorm', cumsum(st)./sum(st), 'rawVector', cat(3,diff(X),diff(Y)), 'vector', cat(3,diff(X),diff(Y)), ...
    'frameInterval', 0.02, 'calib', struct('pixSizeUm',0.16,'fovUm',15.84,'dt_s',0.02,'binNm',30));
end

function h = pick(hs, s)
for k = 1:numel(hs)
    try
        if isprop(hs(k), 'ColumnName') && any(strcmp(hs(k).ColumnName, s)), h = hs(k); return; end
        if isprop(hs(k), 'Title') && contains(string(hs(k).Title.String), s), h = hs(k); return; end
    catch
    end
end
error('could not find a component for "%s"', s);
end
