function cs_picker_loccount_smoke()
%CS_PICKER_LOCCOUNT_SMOKE  The picker must SHOW how many localizations each site holds, and that
%number must follow the footprint when the footprint changes.
%
% WHY THIS EXISTS. Three different counts are on screen at once and all three read as "localizations
% here": the ＋locs overlay draws the whole window, "explain spot" counts within contact µm of where
% you clicked, and a site holds whatever is inside its own footprint. The third is the one the gates
% (min locs/site) actually test, and it was computed, stored in the site row, and never displayed —
% so a site could pass or fail on a number nobody could read.
%
% WHAT IS ASSERTED:
%   1. THE COLUMN EXISTS AND IS WIRED. The sites table has a 'loc' column and its header count
%      matches its data width — a uitable silently renders a short row, so the two are checked
%      against each other rather than assumed.
%   2. IT IS THE FOOTPRINT COUNT, NOT A RE-DERIVED ONE. What the table shows equals the nLocs the
%      detector put in the site row — the number the min locs/site gate tests. If the display and
%      the gate disagreed, the column would be worse than nothing.
%   3. A MANUAL SITE'S COUNT IS ADAPTIVE. A manually added site's footprint IS the contact-µm disc,
%      so changing that radius changes the site. The count must be re-measured at the new radius:
%      a wider disc holds at least as many localizations, and here strictly more.
%   4. A DETECTED SITE'S COUNT IS NOT TOUCHED BY THAT SPINNER. Its footprint is the thresholded
%      blob, which the contact radius does not move. Re-measuring it there would be inventing a
%      change; it follows a re-run of Detect.
%   5. MANUAL ROWS SAY SO. The two footprints are different objects and the counts are not
%      comparable without knowing which one you are reading, so manual rows carry a marker.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));          % the two tools share the build, the channels and the manifest
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'), ...
        fullfile(root_,'tool3_contactsites','app'));
addpath(fullfile(fileparts(here),'app'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_pickloc_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(fullfile(proj,'analysis'));
cleanup = onCleanup(@() rmdir(proj,'s'));

% One cell: a tight cluster at (6,6) that must detect as a site, plus scatter. A second loose
% cluster at (10,10) gives the manual pick somewhere with a radius-sensitive number of neighbours.
rng(11); nF = 60; nT = 60;
X = nan(nF,nT); Y = nan(nF,nT);
for j = 1:nT
    if     j <= 12, c = [6 6];   sd = 0.02;      % tight  -> detected
    elseif j <= 30, c = [10 10]; sd = 0.10;      % loose  -> a radius-sensitive manual pick
    else,           c = 3 + 9*rand(1,2); sd = 0.05;
    end
    X(:,j) = c(1) + sd*cumsum(randn(nF,1))/8;
    Y(:,j) = c(2) + sd*cumsum(randn(nF,1))/8;
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

tbl = pickOne(findobj(fig,'Type','uitable'), @(x) any(strcmpi(x.ColumnName,'mito')), 'sites table');
hdr = cellstr(string(tbl.ColumnName(:)'));

%% (1) the column exists and the header matches the data width --------------------------------------
iLoc = find(strcmpi(hdr,'loc'), 1);
assert(~isempty(iLoc), ...
    ['the sites table has no loc column: %s. Every site row already carries its footprint ' ...
     'localization count — the number min locs/site gates on — and it was never shown.'], strjoin(hdr,', '));

press(fig,'Detect win');
D = tbl.Data;
assert(~isempty(D), 'Detect found no sites on a fixture built with a tight cluster');
assert(size(D,2) == numel(hdr), ...
    ['the table has %d headers and %d data columns. uitable renders the short row without ' ...
     'complaining, so the mismatch shows up as a column of the wrong numbers.'], numel(hdr), size(D,2));

%% (2) what is shown is the number the gate tests ------------------------------------------------------
shown = cellfun(@(v) str2double(string(v)), D(:,iLoc));
assert(all(isfinite(shown) & shown > 0), ...
    'a detected site shows loc = "%s"; a detected footprint always holds localizations', char(string(D{1,iLoc})));
% Proved by making the gate bite on exactly the displayed number: set min locs/site one above the
% largest count in the column and every site must vanish. If the column were some other count, a
% site would survive a threshold set from it.
gate = gateSpinner(fig);
assert(~isempty(gate), 'the min locs/site gate control is gone; this test is pinning the wrong number');
setSpin(gate, max(shown) + 1);
press(fig,'Detect win');
assert(isempty(tbl.Data), ...
    ['%d site(s) survived min locs/site = %d, one above the largest count the loc column shows. ' ...
     'The column is therefore not the quantity the gate tests, which is the whole point of showing it.'], ...
    size(tbl.Data,1), max(shown)+1);
setSpin(gate, 0);
press(fig,'Detect win');
assert(size(tbl.Data,1) == numel(shown), 'dropping the gate back to 0 did not restore the sites');

%% (3)+(4) a manual site re-measures on a radius change; a detected one does not ---------------------
% The detail axes is indexed in DENSITY PIXELS, not µm, so the click has to be converted the way
% the picker derives its own scale.
axDet = pickOne(findobj(fig,'Tag','detailAxes'), @(x) true, 'detail axes');
SF = 27.61 / ceil(27.61/0.030);                         % FOV / grid, as applyCellCalib computes it
press(fig,'Add site');                                  % arm manual add
clickAt(axDet, 10/SF, 10/SF);                           % the loose cluster at (10,10) µm
drawnow;
D1 = tbl.Data;
rMan = find(contains(string(D1(:,1)),'⁺'), 1);
assert(~isempty(rMan), ...
    ['no row is marked as manual (%s). A manual site''s loc counts inside the contact disc and a ' ...
     'detected site''s counts inside its thresholded blob; the two are not comparable unless the ' ...
     'table says which is which.'], strjoin(string(D1(:,1))', ', '));
rAuto = find(~contains(string(D1(:,1)),'⁺'), 1);
assert(~isempty(rAuto), 'the fixture produced no detected site to compare against');
manBefore  = str2double(string(D1{rMan, iLoc}));
autoBefore = str2double(string(D1{rAuto,iLoc}));
assert(isfinite(manBefore) && manBefore > 0, 'the manual site was added with loc = "%s"', char(string(D1{rMan,iLoc})));

con = pickOne(findobj(fig,'Type','uispinner','Tag','contactUm'), @(x) true, 'contact µm spinner');
setSpin(con, 0.60);                                     % 4x the radius

D2 = tbl.Data;
manAfter  = str2double(string(D2{rMan, iLoc}));
autoAfter = str2double(string(D2{rAuto,iLoc}));
assert(manAfter > manBefore, ...
    ['the manual site still reports %d localizations after the contact radius went 0.15 -> 0.60 µm ' ...
     '(now %d). That radius IS its footprint, so the count belongs to a site that no longer exists.'], ...
    manBefore, manAfter);
assert(autoAfter == autoBefore, ...
    ['a DETECTED site''s loc changed from %d to %d when the contact radius moved. Its footprint is ' ...
     'the thresholded blob, which that spinner does not touch — this is an invented change.'], ...
    autoBefore, autoAfter);

fprintf('%d site(s) shown, loc %d–%d · all gated out at min locs/site %d · detected %d unchanged by radius · manual %d -> %d at 0.15 -> 0.60 µm\n', ...
    numel(shown), min(shown), max(shown), max(shown)+1, autoAfter, manBefore, manAfter);
fprintf('\nPICKER-LOCCOUNT SMOKE PASSED.\n');
end

% ================================================================================================
function press(h, txt)
b = findobj(h,'Type','uibutton');
q = b(arrayfun(@(x) contains(string(x.Text), txt), b));
assert(~isempty(q), 'button "%s" not found', txt);
cb = q(1).ButtonPushedFcn; cb(q(1), struct()); drawnow;
end

function clickAt(ax, x, y)
cb = ax.ButtonDownFcn;
assert(~isempty(cb), 'the detail axes has no click handler');
cb(ax, struct('IntersectionPoint',[x y 0]));
end

function setSpin(h, v)
h.Value = v; cb = h.ValueChangedFcn; if ~isempty(cb), cb(h, struct('Value',v)); end, drawnow;
end

function s = gateSpinner(fig)
% By TAG: 'step frames' shares this control's [0 1e6] range, and setting a stride to 1141 detects
% exactly as many sites as before, which reads as "the gate did not bite".
s = findobj(fig,'Type','uispinner','Tag','minSiteLocs');
if ~isempty(s), s = s(1); end
end

function h = pickOne(hs, test, what)
hit = hs(arrayfun(@(x) safe(test,x), hs));
assert(~isempty(hit), 'could not find the %s', what);
h = hit(1);
end
function tf = safe(test, x), try, tf = logical(test(x)); catch, tf = false; end, end
