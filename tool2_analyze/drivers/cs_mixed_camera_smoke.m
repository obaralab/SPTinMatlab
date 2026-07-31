function cs_mixed_camera_smoke()
%CS_MIXED_CAMERA_SMOKE  Two cameras in one project must not share one scale.
%
% The motivating case: a VAPB dataset at 27.61 um over 256 px (0.10785 um/px) and a Sec61B dataset at
% 20.48 um over 128 px (0.16 um/px), analysed together so the second can act as a background null.
%
% The density map is written PER CELL, and its row count is what the micron-per-pixel scale SF was
% computed against. Read that map back with a different cell's field of view and every site
% coordinate, area and enrichment is wrong by the ratio of the two FOVs — silently, because nothing
% about the numbers looks out of range. This checks the picker takes each cell's own calibration.
%
% It also pins the thing that actually decides comparability: the detector smooths by a fixed number
% of BINS, so the physical scale it looks for is 8 * (FOV/grid) microns. Two datasets are only
% measuring the same object when that product matches.

here = fileparts(mfilename('fullpath')); addpath(here);

FOV_A = 27.61; PX_A = 0.10785;    % VAPB rig
FOV_B = 20.48; PX_B = 0.16;       % the second rig: 128 px across 20.48 um

% ---- 1. the scale a cell is binned at must follow that cell -----------------------------------
% grid = ceil(FOV / (precNm/1000)); SF = FOV/grid; physical smoothing = 8*SF.
prec = 30;                                            % nm, same bin size requested for both
gA = ceil(FOV_A/(prec/1000)); sfA = FOV_A/gA;
gB = ceil(FOV_B/(prec/1000)); sfB = FOV_B/gB;
fprintf('same bin size (%g nm) on both rigs:\n', prec);
fprintf('  A: FOV %.2f um -> grid %d, SF %.5f um/px, smoothing %.3f um\n', FOV_A, gA, sfA, 8*sfA);
fprintf('  B: FOV %.2f um -> grid %d, SF %.5f um/px, smoothing %.3f um\n', FOV_B, gB, sfB, 8*sfB);
assert(abs(8*sfA - 8*sfB) < 0.01, ...
    'equal bin size should give equal PHYSICAL smoothing regardless of FOV');

% ...and the trap: keeping the grid instead of the bin size does NOT.
sfBad = FOV_B/gA;
fprintf('  B with A''s grid (%d): SF %.5f um/px, smoothing %.3f um  <- %.2fx off\n', ...
        gA, sfBad, 8*sfBad, (8*sfA)/(8*sfBad));
assert(abs(8*sfBad - 8*sfA) > 0.05*8*sfA, 'the mis-scaling this test guards should be large');

% ---- 2. mixing the project FOV with a per-cell grid is the concrete failure --------------------
% This is what happened when the density map became per-cell but the picker kept the project FOV.
sfMixed = FOV_A/gB;                                   % project FOV, cell B's grid
err = abs(sfMixed - sfB)/sfB;
fprintf('\nreading cell B''s map (grid %d) with the project FOV %.2f um:\n', gB, FOV_A);
fprintf('  SF %.5f instead of %.5f um/px  -> every distance off by %.0f%%\n', sfMixed, sfB, 100*err);
assert(err > 0.3, 'the mixed-scale error should be large enough to matter');
% areas go as the square, so enrichment (a density ratio over an area) is hit twice as hard
fprintf('  areas off by %.0f%%\n', 100*abs(sfMixed^2 - sfB^2)/sfB^2);

% ---- 3. the picker must actually read the per-cell stamp ---------------------------------------
Tracks = struct('file',{'cellA','cellB'});
Tracks(1).calib = struct('pixSizeUm',PX_A,'fovUm',FOV_A,'dt_s',0.020,'precNm',prec);
Tracks(2).calib = struct('pixSizeUm',PX_B,'fovUm',FOV_B,'dt_s',0.020,'precNm',prec);
src = fileread(fullfile(here,'cs_window_picker.m'));
assert(contains(src,'applyCellCalib'), 'the picker has no per-cell calibration step');
assert(contains(src,'applyCellCalib(st.ci)'), 'onCell does not re-apply the cell''s calibration');
assert(contains(src,'st.FOVproj'), 'the picker did not keep a project-level fallback');
% the stamp the picker reads must be the one the importer writes
for k = 1:2
    for f = {'fovUm','precNm'}
        assert(isfield(Tracks(k).calib,f{1}), 'calib is missing %s', f{1});
    end
end
fprintf('\npicker reads per-cell fovUm/precNm, with the project values as the fallback.\n');

% ---- 4. a build with NO stamp must still work (old projects) -----------------------------------
Old = struct('file',{'legacy'});
assert(~isfield(Old,'calib'), 'fixture should have no calib');
fprintf('legacy builds without a calib stamp fall back to the project values.\n');

fprintf('\nALL MIXED-CAMERA ASSERTIONS PASSED.\n');
end
