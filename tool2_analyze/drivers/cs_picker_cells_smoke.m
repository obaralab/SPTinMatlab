function cs_picker_cells_smoke()
%CS_PICKER_CELLS_SMOKE  The picker must say which cells are saved, let you move between them by
%clicking, and never lose or hide picks in the process.
%
% THE BUG THIS PINS. Switching cells wiped the sites on screen and loaded nothing. A saved cell
% reopened EMPTY — indistinguishable from one never picked — and picks you had not saved vanished
% the moment you looked at another cell. There was no way to see which of 93 cells were done.
%
% WHAT IS ASSERTED:
%   1. ONE ROW PER CELL, names shortened to the part that differs, "—" for never saved.
%   2. PICKING MARKS THE CELL UNSAVED, with the count.
%   3. LEAVING AN UNSAVED CELL KEEPS ITS PICKS: the row stays "● unsaved", and coming back restores
%      exactly those sites and says so.
%   4. SAVE TURNS IT ✓, and the header counts it.
%   5. A SAVED CELL REOPENS WITH ITS SITES — the specific failure — with every stored column.
%   6. A LAYOUT MISMATCH IS SAID, NOT HIDDEN. Saved with one frames/win, opened with another: the
%      sites cannot be placed, and the status line says which setting brings them back. Setting it
%      back brings them back.
%   7. THE TABLE AND THE DROPDOWN AGREE on which cell is open.
%   8. HAND-REJECTED TRACKS ARE VISIBLY OUT: a cell whose caller blanked a track says so on the
%      status line, and its density count excludes that track.
%   9. A SAVED CELL OPENS ON ITS OWN LAYOUT. On real data every saved cell was picked at 4000
%      frames/win and the picker opened at 1495, so all 28 opened blank — and, worse, read
%      "● unsaved 0". Opening one now adopts the saved frames/win, and an empty screen on a layout
%      the saved sites do not belong to is NOT unsaved work.
%  10. LONG NAMES LOSE THEIR MIDDLE, not their end: the end carries the plate and cell number, and
%      cutting it made rows read the same.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
addpath(fullfile(fileparts(here),'app'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_pickcells_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
ana = fullfile(proj,'analysis'); mkdir(ana);
cleanup = onCleanup(@() rmdir(proj,'s'));

longName = 'exp_cellD_with_a_very_long_condition_name_07_spt';
T = [mkCell('exp_cellA_spt', 1) mkCell('exp_cellB_spt', 2) mkCell('exp_cellC_spt', 3) mkCell(longName, 4)];
% cellC: one track BLANKED the way the app does it for a hand-rejected track
nLocC = nnz(isfinite(T(3).matrix(:,:,2)));
nRejLoc = nnz(isfinite(T(3).matrix(:,1,2)));
T(3).matrix(:,1,2:3) = NaN;
Tracks = T; %#ok<NASGU>
save(fullfile(ana,'TrackStruct.mat'),'Tracks','-v7.3');

fig = uifigure('Visible','off','Position',[1 1 1700 950]);
closer = onCleanup(@() close(fig));
pn = uipanel(fig);
cs_window_picker(pn, ana, struct('FOV_um',16,'binNm',30,'contactUm',0.15,'Tracks',T));
drawnow;

tc  = one(findobj(fig,'Tag','cellTable'), 'cell table');
dd  = one(findobj(fig,'Type','uidropdown'), 'cell dropdown', @(x) isnumeric(x.ItemsData) && numel(x.ItemsData)==4);
ts  = one(findobj(fig,'Type','uitable'), 'sites table', @(x) any(strcmpi(x.ColumnName,'mito')));
fpw = one(findobj(fig,'Tag','framesPerWindow'), 'frames/win spinner');

%% (1) one row per cell, short names, nothing saved -----------------------------------------------------
D = tc.Data;
assert(size(D,1) == 4, 'the cell table has %d rows for 4 cells', size(D,1));
assert(isequal(D(1:3,2)', {'A','B','C'}), 'short names are %s; the shared prefix/suffix was not dropped', strjoin(D(:,2)',', '));
%% (10) long names lose their middle
dn = D{4,2};
assert(contains(dn, '…') && startsWith(dn, 'D_with') && endsWith(dn, 'name_07') && numel(dn) <= 24, ...
    'the long name displays as "%s"; it should keep its start and its END (the cell number)', dn);
assert(all(strcmp(D(:,3), '—')), 'a never-saved cell reads %s', strjoin(D(:,3)',', '));

%% (2) picking marks the cell unsaved ------------------------------------------------------------------------
openRow(tc, 2);
assert(dd.Value == 2, '(7) the table opened cell 2 but the dropdown says %d', dd.Value);
press(fig,'Detect win');
nB = size(ts.Data,1);
assert(nB > 0, 'Detect found nothing in cellB; the fixture needs a cluster');
assert(strcmp(tc.Data{2,3}, '● unsaved') && str2double(tc.Data{2,4}) == nB, ...
    'after picking %d site(s), cellB reads "%s" / "%s"', nB, tc.Data{2,3}, tc.Data{2,4});

%% (3) leaving keeps the picks; coming back restores them -----------------------------------------------
openRow(tc, 1);
assert(isempty(ts.Data), 'cellA opened showing %d site(s) it never had', size(ts.Data,1));
assert(strcmp(tc.Data{2,3}, '● unsaved'), ...
    'cellB reads "%s" after leaving it with unsaved picks — they must still be flagged', tc.Data{2,3});
openRow(tc, 2);
assert(size(ts.Data,1) == nB, ...
    'cellB came back with %d site(s); %d unsaved picks were made there and must be restored', size(ts.Data,1), nB);
assert(contains(statusText(fig), 'UNSAVED site(s) restored'), ...
    'restoring unsaved picks was silent: "%s"', statusText(fig));

%% (4) save -> saved ---------------------------------------------------------------------------------------------
press(fig,'Save');
assert(strcmp(tc.Data{2,3}, '✓') && str2double(tc.Data{2,4}) == nB, ...
    'after Save cellB reads "%s" / "%s"', tc.Data{2,3}, tc.Data{2,4});
hdr = char(string(labelContaining(fig, 'click to open').Text));
assert(contains(hdr, '1 saved'), 'the cell header does not count the saved cell: "%s"', hdr);
before = ts.Data;

%% (5) a saved cell REOPENS WITH ITS SITES ---------------------------------------------------------------------
openRow(tc, 1); openRow(tc, 2);
assert(size(ts.Data,1) == nB, ...
    ['cellB was saved with %d site(s) and reopened with %d. This is the original failure: a saved cell ' ...
     'reopening empty looks exactly like one that was never picked.'], nB, size(ts.Data,1));
assert(isequal(ts.Data, before), 'the reloaded site table differs from the one that was saved (columns lost?)');
assert(strcmp(tc.Data{2,3}, '✓'), 'reopening a saved cell marked it "%s"', tc.Data{2,3});
assert(contains(statusText(fig), sprintf('loaded %d saved site(s)', nB)), 'loading was silent: "%s"', statusText(fig));

%% (6) a layout mismatch is said, not hidden -----------------------------------------------------------------
setSpin(fpw, 30);                         % 60 frames -> 2 windows; the save was made with 1
assert(isempty(ts.Data), 'saved window-1 sites were shown on a different window layout');
st6 = statusText(fig);
assert(contains(st6, 'set frames/win'), ...
    'the saved sites are hidden by a layout change and nothing says why: "%s"', st6);
%% (9) an empty screen on another layout is NOT unsaved; reopening adopts the saved layout
assert(strcmp(tc.Data{2,3}, '✓'), ...
    ['cellB reads "%s" while showing nothing on a layout its saved sites do not belong to. Nothing ' ...
     'was picked or removed; "unsaved" sends people looking for work that does not exist.'], tc.Data{2,3});
openRow(tc, 1);
assert(fpw.Value == 30, 'opening an unsaved cell changed frames/win to %g', fpw.Value);
openRow(tc, 2);
assert(fpw.Value == 1495, ...
    'cellB was saved at 1495 frames/win and reopened at %g — it should open on its own layout', fpw.Value);
assert(size(ts.Data,1) == nB, 'cellB reopened with %d site(s) after adopting its layout; %d are saved', size(ts.Data,1), nB);
assert(contains(statusText(fig), 'frames/win set to 1495'), 'the layout change was silent: "%s"', statusText(fig));
setSpin(fpw, 30); setSpin(fpw, 1495);
assert(size(ts.Data,1) == nB, 'setting frames/win back did not bring the saved sites back (%d)', size(ts.Data,1));

%% (8) rejected tracks are visibly out ---------------------------------------------------------------------------
openRow(tc, 3);
s8 = statusText(fig);
assert(contains(s8, 'minus 1 hand-rejected track'), ...
    'cellC has a blanked (rejected) track and the status line does not say so: "%s"', s8);
tok = regexp(s8, 'density from tracked (\d+)', 'tokens', 'once');
assert(~isempty(tok) && str2double(tok{1}) == nLocC - nRejLoc, ...
    'the density count is %s; %d tracked minus %d rejected = %d', char(string(tok)), nLocC, nRejLoc, nLocC - nRejLoc);

fprintf('cells A/B/C · B: %d unsaved -> kept across a switch -> saved -> reloaded · layout mismatch named · C: rejected track out\n', nB);
fprintf('\nPICKER-CELLS SMOKE PASSED.\n');
end

% ================================================================================================
function T = mkCell(name, seed)
rng(seed); nF = 60; nT = 30;
X = nan(nF,nT); Y = nan(nF,nT);
for j = 1:nT
    if j <= 12, c = [6 6]; sd = 0.02; else, c = 3 + 8*rand(1,2); sd = 0.05; end
    X(:,j) = c(1) + sd*cumsum(randn(nF,1))/8;
    Y(:,j) = c(2) + sd*cumsum(randn(nF,1))/8;
end
ok = isfinite(X);
T = struct('file',name,'matrix',cat(3,repmat((0:nF-1)',1,nT),X,Y),'frameInterval',0.02, ...
    'lengths',repmat(nF,nT,1),'trackIDs',(1:nT)', ...
    'allSpots',struct('X',X(ok),'Y',Y(ok),'FRAME',repmat((0:nF-1)',nT,1)), ...
    'dist',struct('mito',abs(X-6)));
end

function openRow(tc, r)
cb = tc.SelectionChangedFcn; cb(tc, struct('Selection', r)); drawnow;
end

function t = statusText(fig)
t = char(string(labelContaining(fig, 'detections').Text));
end

function h = labelContaining(fig, s)
lb = findobj(fig,'Type','uilabel');
for i = 1:numel(lb), if contains(string(lb(i).Text), s), h = lb(i); return; end, end
error('no label containing "%s"', s);
end

function press(h, txt)
b = findobj(h,'Type','uibutton');
q = b(arrayfun(@(x) contains(string(x.Text), txt), b));
assert(~isempty(q), 'button "%s" not found', txt);
cb = q(1).ButtonPushedFcn; cb(q(1), struct()); drawnow;
end

function setSpin(h, v)
h.Value = v; cb = h.ValueChangedFcn; if ~isempty(cb), cb(h, struct('Value',v)); end, drawnow;
end

function h = one(hs, what, test)
if nargin >= 3, hs = hs(arrayfun(@(x) safe(test,x), hs)); end
assert(~isempty(hs), 'could not find the %s', what);
h = hs(1);
end
function tf = safe(test, x), try, tf = logical(test(x)); catch, tf = false; end, end
