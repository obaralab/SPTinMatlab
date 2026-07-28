function spt_write_settings(tracksDir, base, cel, prm, R)
%SPT_WRITE_SETTINGS  Write the per-cell run-provenance file  <base>_settings.txt.
%
% Records the exact detection + tracking parameters used for one cell, next to its outputs, so any
% result is traceable to how it was produced. `cel` is the matched-cell struct (diamUm, keepPct,
% thrMode, qualThr, thrAbs); `prm` the tracking params; `R` the spt_process_cell result.
f = fullfile(tracksDir, [base '_settings.txt']);
fid = fopen(f, 'w'); if fid < 0, return; end
c = onCleanup(@() fclose(fid)); %#ok<NASGU>
diamUm  = gf(cel,'diamUm',0.5);
keepPct = gf(cel,'keepPct',6);
isQual  = isfield(cel,'thrMode') && strcmpi(cel.thrMode,'qual');
if isQual, modeTxt = 'quality-abs'; else, modeTxt = 'top-percentile'; end
qMin = gf(cel,'qualThr',[]); if isempty(qMin) || ~(qMin>0), qMinTxt = '(n/a)'; else, qMinTxt = sprintf('%.6g', qMin); end
if isfield(cel,'thrAbs') && ~isempty(cel.thrAbs), thrTxt = sprintf('%.6g', cel.thrAbs); else, thrTxt = '(pooled top-percentile)'; end
fprintf(fid, '# SPT Track run settings — %s\n', base);
fprintf(fid, 'detection.diameter_um   = %.4g\n', diamUm);
fprintf(fid, 'detection.threshold_mode= %s\n', modeTxt);
fprintf(fid, 'detection.top_percent   = %.4g\n', keepPct);
fprintf(fid, 'detection.quality_min   = %s\n', qMinTxt);
fprintf(fid, 'detection.thr_abs       = %s\n', thrTxt);
% Report the EFFECTIVE linking mode (what ran), not the requested one — an ER mode is downgraded
% to Euclidean for a cell with no ER segmentation, and the record must not claim otherwise.
modeEff = gf(R, 'linkMode', gf(prm,'linkMode','penalty'));
modeReq = gf(R, 'linkModeReq', modeEff);
fprintf(fid, 'tracking.method         = %s\n', linkModeName(modeEff));   % the linking method actually used
fprintf(fid, 'tracking.link_mode      = %s\n', modeEff);                 % engine key: euclid|penalty|geodesic
if ~strcmp(modeReq, modeEff)
    fprintf(fid, 'tracking.link_mode_req  = %s   (DOWNGRADED — ER mode unavailable; see result.have_er / tracking.er_aware)\n', modeReq);
end
if strcmp(modeEff,'geodesic')
    fprintf(fid, 'tracking.frames_no_er_mask = %d\n', gf(R,'nFramesNoErMask',0));   % frames with no ER -> nothing tracked
    fprintf(fid, 'tracking.dets_off_er       = %d\n', gf(R,'nDetsOffEr',0));        % detections excluded as off-ER
end
fprintf(fid, 'tracking.link_um        = %.4g\n', prm.linkUm);
fprintf(fid, 'tracking.max_gap_um     = %.4g\n', prm.gapUm);
fprintf(fid, 'tracking.max_gap_frames = %d\n', prm.maxGap);
fprintf(fid, 'tracking.er_aware       = %d\n', R.erAware);
fprintf(fid, 'tracking.lambda         = %.4g\n', prm.lambda);
fprintf(fid, 'calibration.pixel_um    = %.6g\n', prm.pxUm);
fprintf(fid, 'calibration.frame_s     = %.6g\n', prm.dtS);
fprintf(fid, 'result.n_spots          = %d\n', numel(R.spotId));
fprintf(fid, 'result.n_tracks         = %d\n', R.nTracks);
fprintf(fid, 'result.have_er          = %d\n', R.haveEr);
fprintf(fid, 'result.have_mito        = %d\n', R.haveMito);
end

function name = linkModeName(mode)
% Human-readable name for the linking method that produced these tracks.
switch lower(mode)
    case 'euclid',   name = 'Euclidean (no ER)';
    case 'geodesic', name = 'ER-geodesic (strict: on-ER detections only, off-ER excluded from tracks)';
    otherwise,       name = 'ER-penalty (soft: straight-line off-ER fraction, off-ER links allowed)';
end
end

function v = gf(s, f, d), if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end, end
