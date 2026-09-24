function spt_vectors_tab_smoke()
%SPT_VECTORS_TAB_SMOKE  The Analysis tool must be able to show what a build already holds: the step
%vectors as arrows, and what the intensity traces say about bleaching.
%
% WHAT IS ASSERTED:
%   1. IT SHARES THE BUILD'S TAB: the vectors and the bleaching read-out sit under the build they
%      describe, in the Analysis tool's one tab — not in the curation tool or the contact-site tool,
%      each of which has its own window.
%   2. LOADING A BUILD FILLS IT: the cells appear, picking one lists its tracks, and the tracks you
%      pick are drawn IN THE BIG PANEL - one quiver per picked track, at true length so two tracks
%      can be compared - rather than in a second small copy of the same map.
%  2b. THE ORGANELLE MASKS go under them when the project has segmentations for that cell, and the
%      checkbox takes them away again.
%  2c. THE SELECTION IS ONE SELECTION: clicking a track in the panel points the list at it.
%   3. THE BLEACHING BUTTON gives the same numbers as the driver, and says them: step height,
%      background, how much of it was measured, and whether there is a movie-wide decay at all.
%  2d. THREE PANELS ARE DIAGNOSTICS: the fit-window sweep, the ER/mito distance histogram and the
%      CSD. Off by default, each row folded to NO HEIGHT so the panels beside them take the space,
%      and not computed while off. Ticking the box brings them back, filled for the track and the
%      selection already in force rather than blank until the next click.
%  3b. AND IT IS READ PER TRACK: the picked track's own trace is fitted and reported on its own -
%      how many fluorophores were in THAT spot - which a histogram over the cell cannot answer.
%   4. NO INTENSITIES IN THE BUILD is reported, not fitted.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));
addpath(fullfile(here,'..','..','tool3_contactsites','drivers'), fullfile(here,'..','..','tool3_contactsites','app'));

proj = fullfile(tempdir, sprintf('spt_vectab_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
ana = fullfile(proj,'analysis'); mkdir(ana);
cleanup = onCleanup(@() rmdir(proj,'s'));

rng(4); nF = 60; nTr = 12; bgTrue = 400; stepTrue = 150;
oneStepTrack = 2; twoStepTrack = 5;          % built to hold one and two emitters
X = nan(nF,nTr); Y = X; I = nan(nF,nTr); Fr = repmat((0:nF-1)',1,nTr);
for j = 1:nTr
    X(:,j) = 5 + 0.05*cumsum(randn(nF,1)); Y(:,j) = 5 + 0.05*cumsum(randn(nF,1));
    nEmit = 1 + (j == twoStepTrack);
    y = (bgTrue + nEmit*stepTrue)*ones(nF,1);
    ts = sort(randperm(nF-30, nEmit) + 15);
    for q = 1:nEmit, y(ts(q)+1:end) = y(ts(q)+1:end) - stepTrue; end
    I(:,j) = y + (stepTrue/12)*randn(nF,1);
end
% a movie and two segmentations, so the tab can draw the organelle masks under the tracks
mkdir(fullfile(proj,'spt')); mkdir(fullfile(proj,'er_seg')); mkdir(fullfile(proj,'mito_seg'));
SS = 64;
mvp = fullfile(proj,'spt','cellA.tif');
for k = 1:3
    fm = uint16(200 + zeros(SS,SS)); fm(30:32,30:32) = 9000;
    if k == 1, imwrite(fm, mvp); else, imwrite(fm, mvp, 'WriteMode','append'); end
end
erM = false(SS); erM(10:50, 12:18) = true;
miM = false(SS); miM(34:48, 30:50) = true;
imwrite(uint8(erM)*255, fullfile(proj,'er_seg','cellA.tif'));
imwrite(uint8(miM)*255, fullfile(proj,'mito_seg','cellA.tif'));
T = struct('file','cellA','matrix',cat(3,Fr,X,Y),'frameInterval',0.02,'lengths',repmat(nF,nTr,1), ...
    'steps',hypot(diff(X,1,1),diff(Y,1,1)),'vector',cat(3,diff(X,1,1),diff(Y,1,1)), ...
    'intens',cat(3,I,I,I),'trackIDs',(1:nTr)', ...
    'calib',struct('pixSizeUm',0.16,'fovUm',16,'dt_s',0.02,'binNm',30,'precNm',30));
% A SECOND cell, so a click can land on a track that belongs to a different cell from the one the
% list is showing — which is every click made from the pooled QC view, and the only path on which
% the list has to switch cells.
T2 = T; T2.file = 'cellB';
T2.matrix(:,:,2) = T.matrix(:,:,2) + 30;      % well away from cellA, so a click cannot be ambiguous
Tracks = [T T2]; %#ok<NASGU>
save(fullfile(ana,'TrackStruct.mat'),'Tracks','-v7.3');

%% (1) the tab belongs to Tool 2 ---------------------------------------------------------------------
f = spt_analyze_app('analysis'); f.Visible = 'off'; f.Position = [1 1 1600 950];
closer = onCleanup(@() closeQuietly(f));
titles = tabTitles(f);
assert(any(contains(lower(titles), 'vectors')), 'the Analysis tool has no vectors panel (%s)', strjoin(titles, ' | '));
assert(any(contains(titles, 'Build, QC & vectors')), ...
    'the vectors and the build should share ONE tab, got: %s', strjoin(titles, ' | '));
g = spt_analyze_app('contactsites'); g.Visible = 'off';
assert(~any(contains(lower(tabTitles(g)), 'vectors')), 'the contact-site tool should not carry it');
closeQuietly(g);
h = spt_analyze_app('curate'); h.Visible = 'off';
assert(~any(contains(lower(tabTitles(h)), 'vectors')), 'nor should the curation tool');
closeQuietly(h);

%% (2) a build fills it, in the same tab as the build controls ------------------------------------------------------------------------------
selectTab(f, 'Build, QC');
pe = findobj(f,'Type','uieditfield');                  % the project, so the segmentations resolve
for q = 1:numel(pe)
    if contains(lower(string(pe(q).Placeholder)),'project')
        pe(q).Value = proj; cb = pe(q).ValueChangedFcn;
        if ~isempty(cb), cb(pe(q), struct('Value',proj)); end
    end
end
drawnow;
f.UserData.loadTracksFile(fullfile(ana,'TrackStruct.mat')); drawnow;
dd = one(findobj(f,'Tag','vecCell'), 'cell dropdown');
assert(isequal(dd.Items, {'cellA','cellB'}), 'the build''s cells should be listed, got %s', strjoin(dd.Items,', '));
f.UserData.vecSelect(1); drawnow;
lst = one(findobj(f,'Tag','vecTracks'), 'track list');
assert(numel(lst.Items) == nTr, 'the cell''s %d tracks should be listed, got %d', nTr, numel(lst.Items));
axMain = one(findobj(f,'Type','axes'), 'main tracks panel', ...
    @(a) contains(lower(char(strjoin(string(a.Title.String),' '))), 'tracks (click one)'));
axQ = one(findobj(f,'Tag','vecAxes'), 'step-vector panel');
q = findobj(axQ, 'Type', 'quiver');
assert(numel(q) == numel(lst.Value), ...
    'one quiver per picked track in the vector panel: %d picked, %d drawn', numel(lst.Value), numel(q));
assert(isempty(findobj(axMain,'Type','quiver')), ...
    ['the whole-cell map should NOT carry the arrows: at true length they are a couple of pixels ' ...
     'there, which is why they have a panel framed on the picked tracks']);
assert(numel(q(1).UData) == nF-1, 'a %d-localization track has %d steps, got %d arrows', nF, nF-1, numel(q(1).UData));
j = lst.Value(end);                                   % findobj returns newest first
assert(max(abs(q(1).UData(:) - T.vector(:,j,1))) < 1e-12, 'the arrows are not the track''s own vectors');

%% (2b) the organelle masks, and the checkbox that removes them ---------------------------------------
nImg = numel(findobj(axMain,'Type','image'));
assert(nImg == 2, 'the ER and mito masks should be drawn under the tracks (got %d images)', nImg);
chk = one(findobj(f,'Tag','vecOrg'), 'ER/mito checkbox');
chk.Value = false; chk.ValueChangedFcn(chk, struct()); drawnow;
assert(isempty(findobj(axMain,'Type','image')), 'unticking ER/mito should take the masks away');
chk.Value = true;  chk.ValueChangedFcn(chk, struct()); drawnow;
assert(numel(findobj(axMain,'Type','image')) == 2, 'and ticking it should bring them back');

%% (2c) one selection: a click in the panel moves the list ---------------------------------------------
want = 7;
f.UserData.qcSelect(want); drawnow;
assert(isequal(lst.Value, want), 'clicking track %d in the panel should select it in the list (list says %s)', ...
    want, mat2str(lst.Value));
% ACROSS CELLS. Picking a cell below points the big panel at it, so the two halves always show the
% same cell — but the QC panel can also be put back on ALL (pooled), and then a click can land on a
% track of a cell the list is not showing. The list has to follow it there, cell dropdown included.
f.UserData.vecSelect(1); drawnow;
assert(isequal(dd.Value, 1), 'the list should be showing cellA to start');
qcDd = one(findobj(f,'Tag','qcCell'), 'QC cell dropdown');
assert(strcmp(char(qcDd.Value), 'cellA'), ...
    'picking cellA below should have pointed the big panel at cellA (it shows %s)', char(qcDd.Value));
qcDd.Value = 'All (pooled)'; qcDd.ValueChangedFcn(qcDd, struct()); drawnow;
f.UserData.qcSelectIn(2, 4); drawnow;
assert(isequal(dd.Value, 2), 'a click on a cellB track should move the list to cellB (dropdown says %s)', ...
    mat2str(dd.Value));
assert(isequal(lst.Value, 4), 'and select that track in it (list says %s)', mat2str(lst.Value));
f.UserData.vecSelect(1); drawnow;

%% (2d) the sweep is folded away until asked for --------------------------------------------------------
dg = one(findobj(f,'Tag','qcDiag'), 'diagnostics checkbox');
assert(~dg.Value, 'the diagnostics should be off by default');
axSw = one(findobj(f,'Type','axes'), 'sweep axes', ...
    @(a) contains(lower(char(strjoin(string(a.Title.String),' '))), 'fit window'));
axEr = one(findobj(f,'Type','axes'), 'ER/mito distance axes', ...
    @(a) contains(lower(char(strjoin(string(a.Title.String),' '))), 'er / mito distance'));
axCs = one(findobj(f,'Type','axes'), 'CSD axes', ...
    @(a) contains(lower(char(strjoin(string(a.Title.String),' '))), 'csd'));
for hh = [axSw axEr axCs]
    assert(strcmp(hh.Visible,'off'), '"%s" should be hidden, not just empty', ...
        char(strjoin(string(hh.Title.String),' ')));
end
rp = axSw.Parent; lp = axEr.Parent;
assert(isequal(axCs.Parent, lp), 'the ER/mito and CSD panels share the left column');
assert(isequal(rp.RowHeight{4}, 0), 'the sweep row should take no height');
assert(isequal(lp.RowHeight{3}, 0) && isequal(lp.RowHeight{5}, 0), ...
    'the ER/mito and CSD rows should take no height, so the D distribution gets it');
assert(isequal(lp.RowHeight{4}, '1x'), 'the D distribution stays — it is not a diagnostic');
f.UserData.qcSelect(3); drawnow;
% The title is the witness: it says "(click a track)" until the sweep is actually computed, and this
% fixture's build carries no MSD, so whether lines appear says nothing either way.
swTitle = @() char(strjoin(string(axSw.Title.String),' '));
assert(contains(swTitle(),'click a track'), ...
    'a hidden sweep should not be computed — its title moved to "%s"', swTitle());
dg.Value = true; dg.ValueChangedFcn(dg, struct()); drawnow;
for hh = [axSw axEr axCs]
    assert(strcmp(hh.Visible,'on'), '"%s" should come back', char(strjoin(string(hh.Title.String),' ')));
end
assert(isequal(rp.RowHeight{4},'1x') && isequal(lp.RowHeight{3},'1x') && isequal(lp.RowHeight{5},'1x'), ...
    'and their rows should take height again');
assert(~contains(swTitle(),'click a track'), ...
    'the sweep should be computed for the track already selected, not left blank until the next click');
assert(~isempty(findobj(axCs,'Type','line')) || contains(lower(char(strjoin(string(axCs.Title.String),' '))),'not in this'), ...
    'the CSD should be filled (or say the build has none), not left blank');
dg.Value = false; dg.ValueChangedFcn(dg, struct()); drawnow;
for hh = [axSw axEr axCs]
    assert(strcmp(hh.Visible,'off'), 'unticking should fold them away again');
end

%% (3) the bleaching button --------------------------------------------------------------------------
B = f.UserData.runBleaching(); drawnow;
assert(~isempty(B) && abs(B(1).medianStepHeight - stepTrue) < 0.2*stepTrue, ...
    'the tab''s bleaching should recover the %d step (got %.0f)', stepTrue, B(1).medianStepHeight);
assert(abs(B(1).movieBg - bgTrue) < 0.1*bgTrue, 'background %.0f, truth %d', B(1).movieBg, bgTrue);
[~, Bdirect] = spt_bleaching(T, struct('verbose', false));
assert(abs(Bdirect.movieBg - B(1).movieBg) < 1e-9, 'the tab and the driver disagree');
lbl = one(findobj(f,'Tag','bleachInfo'), 'bleaching summary');
txt = char(strjoin(string(lbl.Text), ' '));
assert(contains(txt, 'one step') && (contains(txt, 'no movie-wide decay') || contains(txt, 'decay tau')), ...
    'the summary should say what was found: "%s"', txt);
assert(~isempty(findobj(f, 'Type', 'uiaxes', '-or', 'Type', 'axes')), 'the bleaching plots are missing');

%% (3b) the per-track read-out -------------------------------------------------------------------------
axT = one(findobj(f,'Tag','trkIntAxes'), 'per-track intensity axes');
lst.Value = twoStepTrack; lst.ValueChangedFcn(lst, struct()); drawnow;
tt = char(strjoin(string(axT.Title.String), ' '));
assert(contains(tt, sprintf('track %d', twoStepTrack)), 'the per-track plot should name the track: "%s"', tt);
assert(contains(tt, '2 step'), ...
    'track %d was built with two bleaching steps and the per-track fit should say so: "%s"', twoStepTrack, tt);
assert(~isempty(findobj(axT,'Type','line')), 'the track''s trace and its fitted steps should be drawn');
lst.Value = oneStepTrack; lst.ValueChangedFcn(lst, struct()); drawnow;
tt1 = char(strjoin(string(axT.Title.String), ' '));
assert(contains(tt1, '1 step'), 'a one-emitter track should read one step: "%s"', tt1);

%% (4) a build with no intensities --------------------------------------------------------------------
Tracks = rmfield(T, 'intens'); %#ok<NASGU>
save(fullfile(ana,'NoIntens.mat'),'Tracks','-v7.3');
f.UserData.loadTracksFile(fullfile(ana,'NoIntens.mat')); drawnow;
f.UserData.runBleaching(); drawnow;
txt2 = char(strjoin(string(lbl.Text), ' '));
assert(contains(txt2, 'no intensities'), 'a build without intensities should say so, not fail: "%s"', txt2);

fprintf('vectors tab: %d tracks listed, %d quivers at true length; bleaching step %.0f, background %.0f, no-intensity build reported\n', ...
    nTr, numel(q), B(1).medianStepHeight, B(1).movieBg);
fprintf('\nVECTORS-TAB SMOKE PASSED.\n');
end

% ================================================================================================
function closeQuietly(h)
try, if ~isempty(h) && isgraphics(h), close(h); end, catch, end
end

function t = tabTitles(f)
tg = findobj(f,'Type','uitabgroup');
t = string({tg(1).Children.Title});
end

function selectTab(f, name)
tg = findobj(f,'Type','uitabgroup'); tabs = tg(1).Children;
sel = arrayfun(@(t) contains(string(t.Title), name), tabs);
if any(sel), tg(1).SelectedTab = tabs(find(sel,1)); end
drawnow;
end

function h = one(hs, what, test)
if nargin >= 3, hs = hs(arrayfun(@(x) safe(test,x), hs)); end
assert(~isempty(hs), 'could not find the %s', what);
h = hs(1);
end
function tf = safe(test, x), try, tf = logical(test(x)); catch, tf = false; end, end
