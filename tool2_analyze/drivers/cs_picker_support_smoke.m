function cs_picker_support_smoke()
%CS_PICKER_SUPPORT_SMOKE  The picker must not call a derived support "ER", and its per-site gates
%must actually gate.
%
% WHAT IS ASSERTED:
%   1. A DECLARED-BUT-ABSENT SUPPORT CHANNEL IS RELABELLED. A project can declare an ER channel and
%      have an EMPTY er_seg/ — which is the user's plate. supportKey is then still 'er', so the
%      overlay box read "ER" and the method read "ER Monte-Carlo" while the mask actually being
%      drawn, scattered in and used as the background denominator was derived from the
%      localizations. The analysis was right; the labels claimed a segmentation that does not exist.
%   2. A REAL SUPPORT CHANNEL IS LEFT ALONE — the relabelling must not fire on a project that has ER.
%   3. THE PER-SITE LOCALIZATION GATE EXISTS AND BITES. minSiteLocs was plumbed all the way into
%      cs_detect and applied there, but had no control, so it sat at 0 forever. A gate nobody can
%      reach is the same as no gate.
%   4. IT IS NOT THE PER-WINDOW FLOOR. "min locs/win" warns and gates nothing; the two are different
%      numbers and were easy to confuse.
%   5. NO SUPPORT SEGMENTATION => NOT the Monte-Carlo null by default. Its null region would be
%      derived from the same localizations it is judging. 'local' compares each peak with its own
%      neighbourhood instead. The MC stays SELECTABLE — weak is not meaningless — and a project
%      that HAS a real support mask still defaults to it, which is the case it was built for.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
addpath(fullfile(fileparts(here),'app'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_picksup_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(fullfile(proj,'analysis')); mkdir(fullfile(proj,'er_seg')); mkdir(fullfile(proj,'mito_seg'));
cleanup = onCleanup(@() rmdir(proj,'s'));

% One cell, a dense blob plus scatter, and an EMPTY er_seg/ — declared, absent.
rng(6); nF = 60; nT = 40;
X = nan(nF,nT); Y = nan(nF,nT);
for j = 1:nT
    if j <= 8, c = [6 6]; else, c = 3 + 8*rand(1,2); end
    X(:,j) = c(1) + 0.15*cumsum(randn(nF,1))/8;
    Y(:,j) = c(2) + 0.15*cumsum(randn(nF,1))/8;
end
ok = isfinite(X);
T = struct('matrix', cat(3, repmat((1:nF)',1,nT), X, Y), 'frameInterval',0.02, 'file','cellA', ...
           'lengths', repmat(nF,nT,1), 'trackIDs',(1:nT)', ...
           'allSpots', struct('X',X(ok),'Y',Y(ok),'FRAME',repmat((1:nF)',nT,1)), ...
           'dist', struct('mito', abs(X-6)));
Tracks = T; %#ok<NASGU>
save(fullfile(proj,'analysis','TrackStruct.mat'),'Tracks','-v7.3');

fig = uifigure('Visible','off','Position',[1 1 1600 950]);
closer = onCleanup(@() close(fig));
pn = uipanel(fig);
cs_window_picker(pn, fullfile(proj,'analysis'), ...
    struct('FOV_um',27.61,'binNm',30,'contactUm',0.15,'Tracks',T));
drawnow;

%% (3)+(4) the per-site gate exists, and is distinct from the per-window floor -----------------------
sp = findobj(fig,'Type','uispinner');
gSite = sp(arrayfun(@(x) isequal(x.Limits,[0 1e6]), sp));
assert(~isempty(gSite), ...
    ['there is no per-site localization gate. minSiteLocs is plumbed into cs_detect and applied ' ...
     'there, so without a control it sits at 0 forever — a gate nobody can reach.']);
gWin = sp(arrayfun(@(x) isequal(x.Limits,[0 1e7]), sp));
assert(~isempty(gWin), 'the per-window locs floor is missing');
assert(gSite(1) ~= gWin(1), ...
    'the per-site gate and the per-window floor resolved to the same control; they are different numbers');
gTrk = sp(arrayfun(@(x) isequal(x.Limits,[1 1e4]) && x.Step==1, sp));
assert(~isempty(gTrk), 'the per-site track gate is missing');

%% (1) the derived support is not called ER ------------------------------------------------------------
ck = findobj(fig,'Type','uicheckbox');
txt = arrayfun(@(x) char(string(x.Text)), ck, 'uni', 0);
assert(any(strcmp(txt,'support*')), ...
    ['no "support*" checkbox. With an empty er_seg/ the mask drawn and scattered in is derived from ' ...
     'the localizations, and labelling it ER claims a segmentation this project does not have. ' ...
     'Boxes present: %s'], strjoin(txt', ', '));
assert(~any(strcmp(txt,'ER')), 'an "ER" checkbox survives on a project whose er_seg/ is empty: %s', strjoin(txt', ', '));

%% (6) and NO OUTLINE can be drawn for a support that is not there ------------------------------------
% werMask always returns something — a detection domain may not be empty — so the contour of a mask
% built from the localizations was drawn in the support channel's colour, which on a project with no
% ER reads as ER. Counted, not eyeballed: ticking the box must add no lines to the detail axes.
kSup = find(strcmp(txt,'support*'), 1);
assert(strcmp(char(ck(kSup).Enable),'off'), ...
    'the support checkbox is still enabled; there is no segmentation to outline and a tickable box invites drawing one');
assert(~ck(kSup).Value, 'the support checkbox is ticked on open, so an outline is drawn before anything is clicked');
nBefore = countDetailLines(fig);
ck(kSup).Enable = 'on'; ck(kSup).Value = true;      % force it: the box is the affordance, not the guard
cbk = ck(kSup).ValueChangedFcn; if ~isempty(cbk), cbk(ck(kSup), struct()); end
drawnow;
nAfter = countDetailLines(fig);
assert(nAfter == nBefore, ...
    ['forcing the support box on drew %d more line(s). The DRAW path must refuse a derived support, ' ...
     'not merely the checkbox — werMask always returns a mask, so the contour would otherwise ' ...
     'appear the moment anything re-ticks the box.'], nAfter - nBefore);

dd = findobj(fig,'Type','uidropdown');
meth = dd(arrayfun(@(x) any(strcmp(x.ItemsData,'ermc')), dd));
assert(~isempty(meth), 'the method dropdown was not found');
assert(strcmp(meth(1).Items{1},'Support Monte-Carlo'), ...
    'the method still reads "%s" on a project with no ER segmentation', meth(1).Items{1});
% Renaming Items must not corrupt the Items<->ItemsData mapping. (This used to assert the Value
% stayed 'ermc'; the value now deliberately moves to 'local' — see assertion 5 — so what is
% guarded here is the mapping, which is what renaming could actually break.)
assert(isequal(meth(1).ItemsData(:)', {'ermc','local','relative'}), ...
    'renaming the first item disturbed ItemsData: %s', strjoin(meth(1).ItemsData, ', '));
assert(numel(meth(1).Items) == numel(meth(1).ItemsData), ...
    'Items (%d) and ItemsData (%d) are no longer the same length', numel(meth(1).Items), numel(meth(1).ItemsData));
assert(any(strcmp(meth(1).ItemsData, meth(1).Value)), ...
    'the dropdown Value "%s" is not one of its ItemsData keys', meth(1).Value);

%% (5) with no support segmentation the method must NOT default to the Monte-Carlo null ---------------
% All three methods use the support as the detection DOMAIN; what differs is the null. ER-MC
% scatters points inside the support — sound against a real ER mask, close to circular against one
% derived from the very localizations being judged. 'local' compares each peak with its own
% neighbourhood and does not depend on the support's shape.
assert(strcmp(meth(1).Value,'local'), ...
    ['with no support segmentation the method defaulted to "%s". The derived support is built from ' ...
     'the same localizations the MC null would be judging, so it must not be what happens when the ' ...
     'user touches nothing.'], meth(1).Value);
assert(any(strcmp(meth(1).ItemsData,'ermc')), ...
    'the Monte-Carlo option was REMOVED rather than un-defaulted; the derived null is weak, not meaningless');

%% (7) NO CONTROL MAY BE SQUASHED BY A WRAPPED ROW ------------------------------------------------------
% uigridlayout does not complain when a row has more children than columns. It GROWS the grid — the
% RowHeight you declared as one entry comes back with two — and splits the height you asked for
% between them, so every control in that row renders at half size and the last one silently inherits
% the elastic column. Checking Layout.Row cannot catch it, precisely because RowHeight grows to
% match; what is visible is the HEIGHT, which is also exactly what the user sees. It has happened
% three times in this project and a screenshot of a nested grid cannot be trusted to show it.
kinds = {'uibutton','uicheckbox','uispinner','uidropdown','uieditfield','uinumericeditfield'};
short = {};
for kk = 1:numel(kinds)
    hs = findobj(fig,'Type',kinds{kk});
    for hi = 1:numel(hs)
        p_ = hs(hi).Position;
        if p_(4) > 0 && p_(4) < 18
            short{end+1} = sprintf('%s "%s" h=%.0f', kinds{kk}, labelOf(hs(hi)), p_(4)); %#ok<AGROW>
        end
    end
end
assert(isempty(short), ...
    ['%d control(s) render under 18 px tall — a row has more children than columns, so uigridlayout ' ...
     'wrapped the extras and split the row height between them: %s'], ...
    numel(short), strjoin(short(1:min(4,numel(short))), ' · '));
fprintf('every control renders at full height\n');

%% (8) THE THREE LOCALIZATION COUNTS MUST BE DISTINGUISHABLE ------------------------------------------
% "explain spot says 200 but the overlay looks like 10." They count the same TRACKED localizations;
% what differed was that the overlay drew them at 2 px and 15 % opacity, so a tight cluster of 145
% rendered as a few specks and contradicted the number beside it. Three counts are on screen and
% each answers a different question, so each must say which.
ckL = ck(arrayfun(@(x) contains(string(x.Text),'locs'), ck));
assert(~isempty(ckL), 'the ＋locs checkbox was not found');
tipL = char(string(ckL(1).Tooltip));
assert(contains(tipL,'FOOTPRINT') && contains(tipL,'CLICKED'), ...
    ['the ＋locs tooltip does not distinguish the three counts. The overlay, explain spot and the ' ...
     'site table all say "localizations" and mean different regions: "%s"'], tipL);
% ticking it must actually draw points, and at a visible size
n0 = countDetailPoints(fig);
ckL(1).Value = true;
cbL = ckL(1).ValueChangedFcn; if ~isempty(cbL), cbL(ckL(1), struct()); end
drawnow;
sc = findobj(fig,'Type','scatter');
assert(~isempty(sc), 'ticking ＋locs drew no scatter at all');
assert(sc(1).MarkerFaceAlpha > 0.3, ...
    ['the localization overlay is drawn at alpha %.2f. At that opacity a cluster of a hundred ' ...
     'points reads as a handful, which is the reported complaint.'], sc(1).MarkerFaceAlpha);
fprintf('＋locs: %d points at alpha %.2f, size %g\n', numel(sc(1).XData), sc(1).MarkerFaceAlpha, sc(1).SizeData(1));

%% (2) a real support channel must be left alone --------------------------------------------------------
proj2 = fullfile(tempdir, sprintf('spt_picksup2_%d', feature('getpid')));
if isfolder(proj2), rmdir(proj2,'s'); end
mkdir(fullfile(proj2,'analysis')); mkdir(fullfile(proj2,'er_seg')); mkdir(fullfile(proj2,'mito_seg'));
cleanup2 = onCleanup(@() rmdir(proj2,'s'));
save(fullfile(proj2,'analysis','TrackStruct.mat'),'Tracks','-v7.3');
imwrite(uint8(255*ones(64,64)), fullfile(proj2,'er_seg','cellA_er.tif'));      % a REAL support mask
fig2 = uifigure('Visible','off','Position',[1 1 1600 950]);
closer2 = onCleanup(@() close(fig2));
cs_window_picker(uipanel(fig2), fullfile(proj2,'analysis'), ...
    struct('FOV_um',27.61,'binNm',30,'contactUm',0.15,'Tracks',T, ...
           'segResolver', @(b) struct('er', fullfile(proj2,'er_seg','cellA_er.tif'), 'mito','', 'spt','', ...
                                      'seg', struct('er', fullfile(proj2,'er_seg','cellA_er.tif'), 'mito',''))));
drawnow;
ck2 = findobj(fig2,'Type','uicheckbox');
txt2 = arrayfun(@(x) char(string(x.Text)), ck2, 'uni', 0);
assert(~any(strcmp(txt2,'support*')), ...
    ['a project WITH an ER segmentation was relabelled "support*". The relabelling must fire only ' ...
     'when the derived fallback is actually in use: %s'], strjoin(txt2', ', '));
dd2 = findobj(fig2,'Type','uidropdown');
meth2 = dd2(arrayfun(@(x) any(strcmp(x.ItemsData,'ermc')), dd2));
kSup2 = find(strcmp(txt2,'ER'), 1);
if ~isempty(kSup2)
    n0 = countDetailLines(fig2);
    ck2(kSup2).Value = true;
    cb2 = ck2(kSup2).ValueChangedFcn; if ~isempty(cb2), cb2(ck2(kSup2), struct()); end
    drawnow;
    assert(countDetailLines(fig2) > n0, ...
        ['ticking ER on a project that HAS a support segmentation drew nothing. Assertion 6 would ' ...
         'then pass for the wrong reason — because nothing is ever drawn — rather than because the ' ...
         'derived support is refused.']);
end
assert(~isempty(meth2) && strcmp(meth2(1).Value,'ermc'), ...
    ['a project WITH a real support mask no longer defaults to the Monte-Carlo null (got "%s"). ' ...
     'The MC is the right default there — that is the case it was designed for.'], meth2(1).Value);

fprintf('empty er_seg -> "support*" + "Support Monte-Carlo" · real ER left as ER · per-site gates present\n');
fprintf('\nPICKER-SUPPORT SMOKE PASSED.\n');
end

% ================================================================================================
function n = countDetailLines(fig)
% Lines in the zoomed detail axes — the mask contours are drawn there as line objects.
ax = findobj(fig,'Type','axes');
hit = ax(arrayfun(@(a) contains(string(a.Title.String),'window'), ax));
n = 0;
if ~isempty(hit), n = numel(findobj(hit(1),'Type','line')); end
end

function t = labelOf(h)
t = '';
try, t = char(string(h.Text)); catch, end
if isempty(t), try, t = char(string(h.Tooltip)); catch, end, end
if numel(t) > 24, t = t(1:24); end
end

function n = countDetailPoints(fig)
sc = findobj(fig,'Type','scatter');
n = 0; if ~isempty(sc), n = numel(sc(1).XData); end
end
