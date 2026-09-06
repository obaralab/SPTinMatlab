function spt_calib_bulk_smoke()
%SPT_CALIB_BULK_SMOKE  Applying a calibration to a whole plate must reach every cell it claims to,
%and no cell it does not.
%
% WHY THIS EXISTS. Typing into the table sets ONE cell, which is right for a correction and hopeless
% for a plate: 93 cells whose movies carry no metadata is 93 identical edits. Bulk assignment is the
% fix, and bulk assignment is also the operation where a scoping mistake is least visible — nobody
% re-reads 93 rows to check that the twelve they filtered to were the twelve that changed.
%
% WHAT IS ASSERTED:
%   1. SCOPE: SHOWN    — "apply to all shown" hits every row the FILTER is showing, and no other. A
%                        filtered-out cell keeps what it had.
%   2. SCOPE: SELECTED — "apply to selected" hits the selected rows only.
%   3. IT COUNTS AS AN EDIT — applied values are marked 'edited' AND LOCKED, so they outrank the
%                        files in spt_project_calib and survive a Rescan. An unlocked write would
%                        look identical in the table and be ignored by every tool.
%   4. BLANK LEAVES ALONE — setting only dt must not touch a pixel size that was measured correctly.
%                        This is the whole reason the fields are separate.
%   5. ONE SAVE        — the batch notifies its host ONCE, not once per cell. 93 manifest writes and
%                        93 calibration re-resolves for one button press is a hang, not a save.
%   6. IT REACHES THE RESOLVER — after a bulk apply, spt_project_calib returns the applied value for
%                        a cell, i.e. the plate really is on the new scale.
%
% Synthetic; reads no dataset. Runs offscreen.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(fileparts(here),'drivers'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

FILE_PX = 0.16; FILE_DT = 0.05;
BULK_PX = 0.107; BULK_DT = 0.02;

root = fullfile(tempdir, sprintf('spt_calibbulk_%d', feature('getpid')));
if isfolder(root), rmdir(root,'s'); end
proj = fullfile(root,'proj');
mkdir(fullfile(proj,'tracks')); mkdir(fullfile(proj,'spt'));
cleanup = onCleanup(@() rmdir(root,'s'));

% Three cells. Two carry a MEASURED calibration (a settings file); one carries nothing, which is the
% state the whole feature exists for.
%
% The scanner enumerates cells from the RAW MOVIES (spt_match on spt/), not from tracks/ — it is
% deliberately pre-tracking-friendly, so a cell has a manifest row before it has ever been tracked.
% A fixture with only tracks/ enumerates zero cells.
names = {'d1_cellA','d1_cellB','d2_cellC'};
for k = 1:3
    imwrite(uint16(zeros(32,32)), fullfile(proj,'spt',[names{k} '.tif']));
end
for k = 1:2
    fid = fopen(fullfile(proj,'tracks',[names{k} '_settings.txt']),'w');
    fprintf(fid,'calibration.pixel_um = %.10g\ncalibration.frame_s = %.10g\n', FILE_PX, FILE_DT);
    fclose(fid);
end
fid = fopen(fullfile(proj,'tracks',[names{3} '_tracks.xml']),'w');   % an XML alone: no pixel size
fprintf(fid,'<Tracks frameInterval="%.10g"></Tracks>\n', FILE_DT); fclose(fid);

fig = uifigure('Visible','off','Position',[100 100 1300 700]);
closeFig = onCleanup(@() close(fig));
nNotify = 0;
opts = struct('tool','analyze');
opts.seedFolders = {proj};
opts.onChange = @(m) countNotify();
ctl = spt_experiment_panel(fig, opts);
% What the host does when a project is set (spt_analyze_app's onProjEdit). Without it the panel has
% no canonical file to auto-save into, so nothing would be written for the resolver to read back and
% assertion 6 would be testing the fixture rather than the feature.
ctl.setAutoPath(proj);
drawnow;

cells = ctl.getCells();
assert(numel(cells) == 3, 'the panel found %d cells, wanted 3 — the fixture is not what this test describes', numel(cells));
assert(isfield(ctl,'applyCalibTo') && isfield(ctl,'shownRows'), ...
    'the panel exposes no bulk-calibration hook, so this test would be asserting on a path nobody takes');

%% (4)+(3) apply dt ONLY, to everything -------------------------------------------------------------
nNotify = 0;
ctl.applyCalibTo(ctl.shownRows(), NaN, BULK_DT);
c = ctl.getCells();
for k = 1:3
    assert(abs(c(k).dtS - BULK_DT) < 1e-12, '%s: dt is %.5g after a bulk apply, wanted %.5g', names{k}, c(k).dtS, BULK_DT);
    assert(c(k).dtLock, ...
        ['%s: dt was written unlocked. It would look right in the table and be ignored by every ' ...
         'tool, because spt_project_calib takes only LOCKED values.'], names{k});
    assert(strcmp(c(k).dtSrc,'edited'), '%s: dt source is "%s", not "edited"', names{k}, c(k).dtSrc);
end
% ...and the measured pixel size is untouched, which is why the two fields are separate at all
for k = 1:2
    assert(abs(c(k).pixUm - FILE_PX) < 1e-12 && ~c(k).pixLock, ...
        ['%s: setting dt in bulk also overwrote the pixel size (now %.5g, was the measured %.5g). ' ...
         'A blank field must leave its field alone.'], names{k}, c(k).pixUm, FILE_PX);
end

%% (5) one save for the batch, not one per cell -----------------------------------------------------
assert(nNotify == 1, ...
    ['a 3-cell bulk apply notified the host %d times. Each notify saves the manifest and re-resolves ' ...
     'the calibration, so on a 93-cell plate this is 93 file writes for one button press.'], nNotify);

%% (1) SCOPE: only the rows the filter is showing ----------------------------------------------------
setFilter(fig, 'd1');
drawnow;
shown = ctl.shownRows();
assert(numel(shown) == 2, ...
    'filtering to "d1" shows %d rows, wanted 2 — the filter is not doing what this scoping test assumes', numel(shown));
ctl.applyCalibTo(shown, BULK_PX, NaN);
c = ctl.getCells();
byName = @(n) c(strcmp({c.file}, n));
for n = {'d1_cellA','d1_cellB'}
    r = byName(n{1});
    assert(abs(r.pixUm - BULK_PX) < 1e-12 && r.pixLock && strcmp(r.pixSrc,'edited'), ...
        '%s was shown by the filter but did not receive the bulk pixel size (%.5g, %s)', n{1}, r.pixUm, r.pixSrc);
end
r = byName('d2_cellC');
assert(~r.pixLock && ~(isfinite(r.pixUm) && abs(r.pixUm - BULK_PX) < 1e-12), ...
    ['d2_cellC was FILTERED OUT and still received the bulk pixel size (%.5g). "Apply to all shown" ' ...
     'must mean shown — otherwise filtering to one day silently rewrites the others.'], r.pixUm);

%% (2) SCOPE: selected rows only ---------------------------------------------------------------------
setFilter(fig, '');
drawnow;
shown = ctl.shownRows();
assert(numel(shown) == 3, 'clearing the filter shows %d rows, wanted 3', numel(shown));
ctl.applyCalibTo(shown(3), 0.25, NaN);            % one row, as a selection would give
c = ctl.getCells();
assert(abs(c(shown(3)).pixUm - 0.25) < 1e-12, 'a single-row apply did not land');
assert(abs(c(shown(1)).pixUm - BULK_PX) < 1e-12, ...
    'a single-row apply also changed another row (%.5g) — the scope is not being honoured', c(shown(1)).pixUm);

%% (6) and the RESOLVER now answers with the applied value ---------------------------------------------
% The point of the whole feature: the plate is on the new scale, not just the table.
pc = spt_project_calib(proj, 'd1_cellA');
assert(abs(pc.pixUm - BULK_PX) < 1e-12 && strcmp(pc.src.pixUm,'edited'), ...
    ['after a bulk apply the resolver still returns %.5g from "%s" for d1_cellA. The table would ' ...
     'show the new scale and every tool would use the old one.'], pc.pixUm, pc.src.pixUm);
assert(abs(pc.dt_s - BULK_DT) < 1e-12 && strcmp(pc.src.dt_s,'edited'), ...
    'the resolver returns dt %.5g from "%s", not the applied %.5g', pc.dt_s, pc.src.dt_s, BULK_DT);

fprintf('bulk: dt -> 3 cells · µm/px -> 2 filtered cells (1 untouched) · 1 save per batch\n');
fprintf('resolver for d1_cellA: %.5g µm/px (%s) · %.5g s (%s)\n', pc.pixUm, pc.src.pixUm, pc.dt_s, pc.src.dt_s);
fprintf('\nBULK-CALIBRATION SMOKE PASSED.\n');

    function countNotify(), nNotify = nNotify + 1; end
end

% ================================================================================================
function setFilter(fig, txt)
% The panel's filter box, by its placeholder — the same control the user types into.
ef = findobj(fig,'Type','uieditfield');
for k = 1:numel(ef)
    if contains(string(ef(k).Placeholder), 'unassigned')
        ef(k).Value = txt;
        cb = ef(k).ValueChangedFcn; if ~isempty(cb), cb(ef(k), struct('Value',txt)); end
        return
    end
end
error('could not find the panel''s filter box');
end
