function spt_dwell_engage_smoke()
%SPT_DWELL_ENGAGE_SMOKE  The Dwell tab must answer the three questions the VAPB figures answer: did
%this track engage this site, how many times, and how do the dwell times compare between conditions.
%
% WHAT IS ASSERTED:
%   1. THE CONTROLS EXIST: an engaged-if-longer-than threshold, a grouping for the histogram and a
%      choice of what the second axes shows.
%   2. COMPUTING DWELL CLASSIFIES EVERY MEMBER TRACK, the ones that never approach included - they
%      are the denominator of "what fraction engaged" - and the tab SAYS that fraction.
%   3. THE THRESHOLD RECLASSIFIES WITHOUT RECOMPUTING: raising it un-engages tracks while the dwell
%      events themselves are untouched, because reading the traces again is all it takes.
%   4. GROUPING BY CONDITION gives one series per condition, each with its own tau, and a test
%      between them - the comparison the histogram is for.
%   5. THE OTHER TWO VIEWS DRAW: engagements per track (his trackBinding distribution) and the
%      fraction of a site's member tracks that engaged it.
%   6. THE TABLE SAYS WHICH TRACKS ENGAGED, so a row can be read as well as counted.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));
addpath(fullfile(here,'..','..','tool3_contactsites','drivers'), fullfile(here,'..','..','tool3_contactsites','app'));

proj = fullfile(tempdir, sprintf('spt_dwelleng_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
ana = fullfile(proj,'analysis'); mkdir(ana);
cleanup = onCleanup(@() rmdir(proj,'s'));

%% fixture: two cells, one per condition, engagements averaging 1 s and 3 s -------------------------
% Absolute coordinates around each site centre, so the BUILD and the mapped sites agree and the wider
% denominator can be tested: 10 tracks that engage, 6 that only touch the outline (members, not
% engaged), 4 that visit the neighbourhood box and never enter it at all.
rng(5); dt = 0.02; nF = 600; R = 0.15; th = linspace(0,2*pi,60)';
cen = [5 5]; boxUm = 1.0; nAll = 20; mem = 1:16;
% The drug cell is watched for half as long, which is the second way this comparison misleads and has
% to be reported rather than silently shortening its dwells.
specs = {'cellCtrl', 'ctrl', 1.0, nF; 'cellDrug', 'drug', 3.0, round(nF/2)};
CSW = struct([]); Tracks = struct([]);
for c = 1:size(specs,1)
    nFc = specs{c,4};
    X = nan(nF,nAll); Y = nan(nF,nAll); F = repmat((0:nF-1)',1,nAll);
    X(1:nFc,:) = cen(1) + 1.5; Y(1:nFc,:) = cen(2);           % parked outside the box by default
    for j = 1:10                                              % engage: a real visit
        len = max(20, round(exprnd(specs{c,3})/dt));
        t0 = 30 + randi(max(1, min(200, nFc-80)));
        X(t0:min(nFc-5,t0+len), j) = cen(1)+0.01; Y(t0:min(nFc-5,t0+len), j) = cen(2)+0.01;
    end
    for j = 11:16                                             % members, but only a 3-frame touch
        X(40:42, j) = cen(1)+0.01; Y(40:42, j) = cen(2)+0.01;
    end
    for j = 17:20                                             % in the box, never inside, never at 2R
        X(1:nFc, j) = cen(1) + 0.40; Y(1:nFc, j) = cen(2) + 0.02;
    end
    Tracks(end+1).file = specs{c,1}; %#ok<AGROW>
    Tracks(end).matrix = cat(3,F,X,Y); Tracks(end).frameInterval = dt;
    Tracks(end).lengths = sum(isfinite(X),1)'; Tracks(end).trackIDs = (1:nAll)';
    Tracks(end).calib = struct('pixSizeUm',0.16,'fovUm',16,'dt_s',dt,'binNm',30,'precNm',30);
    CSW(end+1).file = specs{c,1}; %#ok<AGROW>
    CSW(end).cellIndex = c; CSW(end).csID = 1; CSW(end).window = 1;
    CSW(end).winFrames = [0 nF-1]; CSW(end).siteUID = c;
    CSW(end).tracks = mem;
    CSW(end).CSmatrix = cat(3, F(:,mem), X(:,mem)-cen(1), Y(:,mem)-cen(2));
    CSW(end).refboundary = R*[cos(th) sin(th)];
    CSW(end).dt = dt; CSW(end).condition = specs{c,2};
    CSW(end).MitoFlag = double(c == 1);
    CSW(end).refCenter = cen; CSW(end).boxUm = boxUm; CSW(end).SF = 30;
end
save(fullfile(ana,'CSW_final.mat'),'CSW','-v7.3');
% The build is written later, in (5b): until then there is none, which is the case the tab has to
% report rather than quietly falling back to the narrow denominator.

%% (1) the controls ---------------------------------------------------------------------------------
f = spt_analyze_app('analyze'); f.Visible = 'off'; f.Position = [1 1 1700 980];
closer = onCleanup(@() closeQuietly(f));
selectTab(f, 'Dwell');
for tg = {'dwEngage','dwGroup','dwView','dwDen'}
    assert(~isempty(findobj(f,'Tag',tg{1})), 'the Dwell tab is missing its %s control', tg{1});
end
setProject(f, proj);

%% (2) computing dwell classifies every member track ------------------------------------------------
f.UserData.dwSetRule('distance');
f.UserData.runDwell(); drawnow;
DD = f.UserData.dwellRes();
assert(isfield(DD,'engage') && ~isempty(DD.engage.perTrack), 'the dwell result should carry the engagement classification');
pt = DD.engage.perTrack;
assert(numel(pt) == 32, 'every one of the 32 member tracks should be classified, got %d', numel(pt));
eng = logical([pt.engaged]);
assert(nnz(eng) == 20, '20 of the 32 tracks were built to engage, got %d', nnz(eng));
assert(nnz(~eng) == 12, 'the 12 tracks that stay away are the denominator and must be kept');
lbl = dwellLabel(f);
assert(contains(lbl,'20 of 32 member tracks engaged'), 'the tab should say the engaged fraction: "%s"', lbl);
assert(contains(lbl,'engagements each'), 'the tab should say how many engagements per engaged track: "%s"', lbl);

%% (3) the threshold reclassifies without recomputing -----------------------------------------------
nEvBefore = numel(DD.events);
f.UserData.dwSetEngage(2.0); drawnow;               % only visits longer than 2 s now count
D2 = f.UserData.dwellRes();
n2 = nnz([D2.engage.perTrack.engaged]);
assert(n2 < nnz(eng), 'raising the threshold to 2 s should un-engage the short visits (%d -> %d)', nnz(eng), n2);
assert(numel(D2.events) == nEvBefore, 'reclassifying must not touch the dwell events themselves');
f.UserData.dwSetEngage(0.30); drawnow;
assert(nnz([f.UserData.dwellRes().engage.perTrack.engaged]) == nnz(eng), 'and it should come back');

%% (4) grouped by condition -------------------------------------------------------------------------
f.UserData.dwSetGroup('condition'); drawnow;
ax = one(findobj(f,'Tag','dwHist'), 'dwell histogram axes');
t = titleOf(ax);
assert(contains(t,'ctrl') && contains(t,'drug'), 'both conditions should be named in the histogram title: "%s"', t);
assert(count(t,'τ=') == 2, 'each condition should report its own tau: "%s"', t);
assert(contains(t,'KS p='), 'two groups should be compared: "%s"', t);
assert(numel(findobj(ax,'Type','bar')) == 2, 'one bar series per condition');
sub = char(strjoin(string(ax.Subtitle.String), ' '));
assert(contains(sub,'same length of time'), ...
    'the drug cell was watched half as long — the histogram must say so: "%s"', sub);
assert(contains(sub,'cell(s) behind it'), ...
    'one cell per condition is pseudo-replication and must be said too: "%s"', sub);
H = cs_dwell_histogram(DD.engage, struct('group','condition'));
tau = [H.groups.tau]; nm = string({H.groups.name});
assert(tau(nm=="drug") > 1.7*tau(nm=="ctrl"), ...
    'the 3x longer condition should read longer (ctrl %.2f s, drug %.2f s)', tau(nm=="ctrl"), tau(nm=="drug"));

%% (5) the other two views --------------------------------------------------------------------------
axK = one(findobj(f,'Tag','dwKout'), 'second axes');
f.UserData.dwSetView('engagements'); drawnow;
assert(contains(titleOf(axK),'engagements per'), 'the second axes should switch view: "%s"', titleOf(axK));
assert(~isempty(findobj(axK,'Type','histogram')), 'engagements per track should be drawn');
assert(contains(titleOf(axK),'mean'), 'it should report the mean: "%s"', titleOf(axK));
f.UserData.dwSetView('fraction'); drawnow;
assert(contains(titleOf(axK),'fraction of member'), 'and again: "%s"', titleOf(axK));
assert(~isempty(findobj(axK,'Type','histogram')), 'fraction engaged per site should be drawn');
f.UserData.dwSetView('k_out'); drawnow;

%% (5b) the wider denominator -----------------------------------------------------------------------
% Chosen with no build in memory, the tab must say so rather than quietly reporting the narrow number.
f.UserData.dwSetDen('box'); drawnow;
assert(contains(dwellLabel(f),'needs the build in memory'), ...
    'asking for the box denominator without a build should say what to do: "%s"', dwellLabel(f));
assert(numel(f.UserData.dwellRes().engage.perTrack) == 32, 'and it should still be the member denominator');
save(fullfile(ana,'TrackStruct.mat'),'Tracks','-v7.3');
f.UserData.loadTracksFile(fullfile(ana,'TrackStruct.mat')); drawnow;
assert(isempty(f.UserData.dwellRes()), 'loading a build should invalidate the dwell result');
f.UserData.runDwell(); drawnow;                     % recompute it, now with the build in memory
Gb = f.UserData.dwellRes().engage;
assert(numel(Gb.perTrack) == 40, 'with the build loaded the 8 box-only tracks join the denominator (got %d)', numel(Gb.perTrack));
assert(nnz([Gb.perTrack.engaged]) == 20, 'the box-only tracks never approach, so the engaged COUNT is unchanged (got %d)', nnz([Gb.perTrack.engaged]));
assert(mean([Gb.perSite.fracEngaged]) < 0.6, 'and the engaged FRACTION must fall (%.2f)', mean([Gb.perSite.fracEngaged]));
assert(contains(dwellLabel(f),'20 of 40'), 'the tab should report the wider denominator: "%s"', dwellLabel(f));
f.UserData.dwSetDen('member'); drawnow;
assert(numel(f.UserData.dwellRes().engage.perTrack) == 32, 'and switching back should narrow it again');

%% (6) the table names them ------------------------------------------------------------------------
tbl = one(findobj(f,'Type','uitable'), 'dwell table', @(t) any(contains(string(t.ColumnName),'engaged')));
D = tbl.Data;
assert(~isempty(D), 'the per-track table should be filled');
col = find(contains(string(tbl.ColumnName),'engaged'), 1);
vals = string(D(:,col));
assert(any(startsWith(vals,'yes')), 'some rows should be marked engaged');
assert(all(startsWith(vals,'yes') | vals == "no" | vals == "—"), 'the engaged column should read yes/no: %s', strjoin(unique(vals)', ', '));

fprintf('dwell tab: %d/%d member tracks engaged, %d events; ctrl tau %.2f s vs drug %.2f s (KS in title), three views draw\n', ...
    nnz(eng), numel(pt), nEvBefore, tau(nm=="ctrl"), tau(nm=="drug"));
fprintf('\nDWELL-ENGAGE SMOKE PASSED.\n');
end

% ================================================================================================
function closeQuietly(h)
try, if ~isempty(h) && isgraphics(h), close(h); end, catch, end
end

function selectTab(f, name)
tg = findobj(f,'Type','uitabgroup'); tabs = tg(1).Children;
sel = arrayfun(@(t) contains(string(t.Title), name), tabs);
if any(sel), tg(1).SelectedTab = tabs(find(sel,1)); end
drawnow;
end

function setProject(f, proj)
pe = findobj(f,'Type','uieditfield');
for q = 1:numel(pe)
    if contains(lower(string(pe(q).Placeholder)),'project')
        pe(q).Value = proj; cb = pe(q).ValueChangedFcn;
        if ~isempty(cb), cb(pe(q), struct('Value',proj)); end
    end
end
drawnow;
end

function s = dwellLabel(f)
lbl = findobj(f,'Type','uilabel'); s = '';
for q = 1:numel(lbl)
    t = char(strjoin(string(lbl(q).Text),' '));
    if contains(t,'member track'), s = t; return; end
end
end

function t = titleOf(ax)
t = ax.Title.String; if iscell(t) || isstring(t), t = strjoin(string(t),' '); end
t = char(t);
end

function h = one(hs, what, test)
if nargin >= 3, hs = hs(arrayfun(@(x) safe(test,x), hs)); end
assert(~isempty(hs), 'could not find the %s', what);
h = hs(1);
end
function tf = safe(test, x), try, tf = logical(test(x)); catch, tf = false; end, end
