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
assert(~isempty(meth2) && strcmp(meth2(1).Value,'ermc'), ...
    ['a project WITH a real support mask no longer defaults to the Monte-Carlo null (got "%s"). ' ...
     'The MC is the right default there — that is the case it was designed for.'], meth2(1).Value);

fprintf('empty er_seg -> "support*" + "Support Monte-Carlo" · real ER left as ER · per-site gates present\n');
fprintf('\nPICKER-SUPPORT SMOKE PASSED.\n');
end
