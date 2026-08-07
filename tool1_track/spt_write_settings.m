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
% tracking.er_aware is gone. It was a boolean from before the three-way mode existed, and it is
% fully derivable from tracking.link_mode (anything but 'euclid' uses the ER) — it named a mode the
% app no longer has, right next to the two lines that say the real one.
fprintf(fid, 'tracking.lambda         = %.4g\n', prm.lambda);
fprintf(fid, 'calibration.pixel_um    = %.6g\n', prm.pxUm);
fprintf(fid, 'calibration.frame_s     = %.6g\n', prm.dtS);
% HOW this cell's movie was paired with its segmentations. Tools 2 and 3 have to redo that pairing
% to resolve overlays, and until this was recorded they could only RE-DERIVE the token by comparing
% names — which works when a segmentation name is a prefix of the SPT name and not otherwise. A
% regex typed in Tool 1 because the naming is unusual was lost the moment the scan ended.
% strip_regex is what actually went to spt_match; channel_token is the readable form of it.
fprintf(fid, 'matching.strip_regex    = %s\n', gs(cel,'stripRe','(none)'));
fprintf(fid, 'matching.channel_token  = %s\n', gs(cel,'chanTok','(none)'));
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

function v = gs(s, f, d)
% String field, or a placeholder. '(none)' rather than an empty line, because "matched with nothing
% stripped" is a real, valid answer and must not read as "this run recorded nothing".
v = d;
if isfield(s,f) && ~isempty(s.(f)) && (ischar(s.(f)) || isstring(s.(f))), v = char(s.(f)); end
end
