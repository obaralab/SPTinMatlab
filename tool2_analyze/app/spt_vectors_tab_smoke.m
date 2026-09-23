function spt_vectors_tab_smoke()
%SPT_VECTORS_TAB_SMOKE  The Analysis tool must be able to show what a build already holds: the step
%vectors as arrows, and what the intensity traces say about bleaching.
%
% WHAT IS ASSERTED:
%   1. IT SHARES THE BUILD'S TAB: the vectors and the bleaching read-out sit under the build they
%      describe, in the Analysis tool's one tab — not in the curation tool or the contact-site tool,
%      each of which has its own window.
%   2. LOADING A BUILD FILLS IT: the cells appear, picking one lists its tracks, and the axes gets
%      one quiver per selected track - drawn at true length, so two tracks can be compared.
%   3. THE BLEACHING BUTTON gives the same numbers as the driver, and says them: step height,
%      background, how much of it was measured, and whether there is a movie-wide decay at all.
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
X = nan(nF,nTr); Y = X; I = nan(nF,nTr); Fr = repmat((0:nF-1)',1,nTr);
for j = 1:nTr
    X(:,j) = 5 + 0.05*cumsum(randn(nF,1)); Y(:,j) = 5 + 0.05*cumsum(randn(nF,1));
    y = (bgTrue + stepTrue)*ones(nF,1); t = randi([15 nF-15]); y(t+1:end) = bgTrue;
    I(:,j) = y + (stepTrue/10)*randn(nF,1);
end
T = struct('file','cellA','matrix',cat(3,Fr,X,Y),'frameInterval',0.02,'lengths',repmat(nF,nTr,1), ...
    'steps',hypot(diff(X,1,1),diff(Y,1,1)),'vector',cat(3,diff(X,1,1),diff(Y,1,1)), ...
    'intens',cat(3,I,I,I),'trackIDs',(1:nTr)', ...
    'calib',struct('pixSizeUm',0.16,'fovUm',16,'dt_s',0.02,'binNm',30,'precNm',30));
Tracks = T; %#ok<NASGU>
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
f.UserData.loadTracksFile(fullfile(ana,'TrackStruct.mat')); drawnow;
dd = one(findobj(f,'Tag','vecCell'), 'cell dropdown');
assert(isequal(dd.Items, {'cellA'}), 'the build''s cells should be listed');
f.UserData.vecSelect(1); drawnow;
lst = one(findobj(f,'Tag','vecTracks'), 'track list');
assert(numel(lst.Items) == nTr, 'the cell''s %d tracks should be listed, got %d', nTr, numel(lst.Items));
ax = one(findobj(f,'Tag','vecAxes'), 'vector axes');
q = findobj(ax, 'Type', 'quiver');
assert(numel(q) == numel(lst.Value), 'one quiver per selected track: %d selected, %d drawn', numel(lst.Value), numel(q));
assert(numel(q(1).UData) == nF-1, 'a %d-localization track has %d steps, got %d arrows', nF, nF-1, numel(q(1).UData));
j = lst.Value(end);                                   % findobj returns newest first
assert(max(abs(q(1).UData(:) - T.vector(:,j,1))) < 1e-12, 'the arrows are not the track''s own vectors');

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
