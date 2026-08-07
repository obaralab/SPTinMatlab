function spt_shape_smoke()
% Verify the per-spot motion-blur metric: spt_detect's 2nd output flags an elongated (streaked) spot,
% and ELONGATION/ORIENT_DEG propagate through spt_process_cell -> _spots.csv -> _spots_filtered.csv.
here = fileparts(mfilename('fullpath')); addpath(here);

%% synthetic: a round spot vs a Y-elongated (motion-blurred) spot -----------------
[X,Y] = meshgrid(1:48,1:48);
img = 100 + 600*exp(-((X-12).^2+(Y-12).^2)/(2*1.3^2)) ...                 % round
          + 600*exp(-((X-34).^2/(2*1.3^2) + (Y-34).^2/(2*3.0^2)));       % elongated along Y
[xy, shp] = spt_detect(img, 0.5, 0.10785, []);
assert(size(shp,2)==4, 'shp is not Nx4');
elR = []; elE = [];
for i = 1:size(xy,1)
    if hypot(xy(i,1)-12, xy(i,2)-12) < 3, elR = shp(i,3); end
    if hypot(xy(i,1)-34, xy(i,2)-34) < 3, elE = shp(i,3); end
end
assert(~isempty(elR) && ~isempty(elE), 'did not detect both synthetic spots (found %d)', size(xy,1));
fprintf('synthetic elongation: round=%.2f  streaked=%.2f\n', elR, elE);
assert(elE > 1.4 && elE > elR + 0.3, 'elongation did not flag the streaked spot');
assert(elR < 1.4, 'round spot wrongly flagged as elongated');

%% real data: columns propagate raw -> filtered ----------------------------------
W = '/Users/safal-mac/Documents/IntegratedPipeline/WithER';
cel = struct('key','250408_WT_012','spt',fullfile(W,'spt','250408_WT_012_spt1.tif'), ...
    'erSeg',fullfile(W,'er_seg','250408_VAPB_WT_012_2_TA_BC.tiff'),'mitoSeg','','diamUm',0.5);
prm = struct('linkUm',0.8,'gapUm',1.4,'maxGap',1,'useEr',true,'lambda',3,'pxUm',0.10785,'dtS',0.020064,'maxFrames',15);
R = spt_process_cell(cel, prm);
assert(isfield(R,'elong') && numel(R.elong)==numel(R.spotId), 'R.elong missing/mismatched');
td = fullfile(tempdir,'spt_shape'); if isfolder(td), rmdir(td,'s'); end, mkdir(td);
spt_write_outputs(R, td);
S = readtable(fullfile(td,'250408_WT_012_spt1_spots.csv'));
assert(all(ismember({'ELONGATION','ORIENT_DEG'}, S.Properties.VariableNames)), 'raw CSV missing shape columns');
assert(all(S.ELONGATION >= 1-1e-6), 'elongation < 1 found');
fprintf('raw csv: %d spots · median elong %.2f · %d with elong>=1.5\n', height(S), median(S.ELONGATION), sum(S.ELONGATION>=1.5));
C = spt_filter_read(fullfile(td,'250408_WT_012_spt1_spots.csv'));
spt_filter_write(C, C.len>=1, td, '250408_WT_012_spt1');
S2 = readtable(fullfile(td,'250408_WT_012_spt1_spots_filtered.csv'));
assert(all(ismember({'ELONGATION','ORIENT_DEG'}, S2.Properties.VariableNames)), 'filtered CSV missing shape columns');
fprintf('filtered csv carries ELONGATION/ORIENT_DEG (%d rows)\n', height(S2));
rmdir(td,'s');

fprintf('\nSHAPE / MOTION-BLUR SMOKE PASSED.\n');
end
