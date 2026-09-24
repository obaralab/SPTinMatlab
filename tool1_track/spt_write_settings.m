function spt_write_settings(tracksDir, base, cel, prm, R)
%SPT_WRITE_SETTINGS  Write the per-cell run-provenance file  <base>_settings.txt.
%
% Records the exact detection + tracking parameters used for one cell, next to its outputs, so any
% result is traceable to how it was produced. `cel` is the matched-cell struct (diamUm, keepPct,
% thrMode, qualThr, thrAbs); `prm` the tracking params; `R` the spt_process_cell result.
% Beside the tracks it describes, not over another colour's: same token, same rule.
base = spt_channel_stem(base, gf(R,'chKey',''));
f = fullfile(tracksDir, [base '_settings.txt']);
fid = fopen(f, 'w'); if fid < 0, return; end
c = onCleanup(@() fclose(fid)); %#ok<NASGU>
diamUm  = gf(cel,'diamUm',0.5);
keepPct = gf(cel,'keepPct',6);
isQual  = isfield(cel,'thrMode') && strcmpi(cel.thrMode,'qual');
if isQual, modeTxt = 'quality-abs'; else, modeTxt = 'top-percentile'; end
qMin = gf(cel,'qualThr',[]); if isempty(qMin) || ~(qMin>0), qMinTxt = '(n/a)'; else, qMinTxt = sprintf('%.6g', qMin); end
% The cut this cell ACTUALLY detected with, and where it came from. This used to read the literal
% '(pooled top-percentile)' for any cell that was not previewed, because the resolved number never
% came back from the engine — so across a batch there was no way to tell whether each cell got its
% own threshold or one value had been applied to all of them.
tu = gf(R,'thrUsed',[]); tsrc = gs(R,'thrSrc','');
if ~isempty(tu) && isscalar(tu) && isfinite(tu)
    if strcmp(tsrc,'pooled')
        thrTxt = sprintf('%.6g   (pooled from THIS cell, top %.4g%%)', tu, keepPct);
    else
        thrTxt = sprintf('%.6g   (fixed on the cell, not pooled)', tu);
    end
elseif isfield(cel,'thrAbs') && ~isempty(cel.thrAbs)
    thrTxt = sprintf('%.6g   (fixed on the cell, not pooled)', cel.thrAbs);
else
    thrTxt = '(unresolved — no candidates pooled)';
end
fprintf(fid, '# SPT Track run settings — %s\n', base);
fprintf(fid, 'detection.diameter_um   = %.4g\n', diamUm);
fprintf(fid, 'detection.threshold_mode= %s\n', modeTxt);
fprintf(fid, 'detection.top_percent   = %.4g\n', keepPct);
fprintf(fid, 'detection.quality_min   = %s\n', qMinTxt);
fprintf(fid, 'detection.thr_abs       = %s\n', thrTxt);
% The ridge gate and the interleaved frame map both change WHICH detections exist, so a run is not
% reproducible from the other settings alone.
rg = gf(R,'ridgeMax',[]);
fprintf(fid, 'detection.ridge_max     = %s\n', tern_(isempty(rg)||rg<=0, 'off (no filament rejection)', sprintf('%.4g', rg)));
sz = gf(R,'sizeMax',[]);
fprintf(fid, 'detection.size_max      = %s\n', tern_(isempty(sz)||sz<=0, 'off (no width rejection)', sprintf('%.4g x expected peak width', sz)));
al = gf(R,'alignDeg',[]);
fprintf(fid, 'detection.align_deg     = %s\n', tern_(isempty(al)||al<=0, 'off (no alignment rejection)', ...
    sprintf('%.4g deg of the organelle skeleton', al)));
fprintf(fid, 'detection.bleed_frames  = %s\n', gs(R,'bleedFrames','all'));
fprintf(fid, 'detection.thr_from_frames= %s   (which frames the Top-%% threshold was pooled from)\n', ...
    gs(R,'thrFrames','all'));
% Mean IMAGE intensity inside the organelle mask over outside, on the frames actually detected.
% ~1 means no meaningful leak-through from the other channel. Deliberately an intensity ratio and
% not a detection ratio: a detection ratio IS the biological readout and cannot judge itself.
ce = gf(R,'mitoIntensityEnrich',NaN);
if isfinite(ce)
    fprintf(fid, 'detection.mito_intensity_enrich = %.3g   (~1 = no crosstalk into this channel)\n', ce);
end
fprintf(fid, 'frames.spt_per_organelle= %d\n', gf(R,'segEvery',1));
fs = gf(R,'frameStride',1);
if fs > 1
    fprintf(fid, 'frames.de_interleave    = every %d pages from page %d (of %d) -> %d frames\n', ...
        fs, gf(R,'frameOffset',0)+1, gf(R,'nPages',0), R.nFrames);
    fprintf(fid, 'frames.page_interval_s  = %.6g   (calibration.frame_s below is this x %d)\n', gf(R,'dtPage',NaN), fs);
end
nns = gf(R,'nFramesNoSegPage',0);
if nns > 0
    fprintf(fid, 'frames.no_organelle_page= %d   (NO mito/ER distance and no link support on these frames)\n', nns);
end
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
% Calibration is per cell, so this file has to say WHERE this cell's two numbers came from — the
% same reason link_mode_req exists above. A value the app could not resolve from the cell falls back
% to the panel, and a fallback that is not recorded is indistinguishable from a measurement: a later
% reader (spt_project_calib reads calibration.pixel_um straight out of this file) would take the
% panel's guess for what the instrument said. The _src line is what tells them apart. The value
% itself is still written, because it IS what produced the µm coordinates sitting next to it.
pxSrc = gs(prm,'pxUmSrc','(unknown)');
dtSrc = gs(prm,'dtSSrc','(unknown)');
fprintf(fid, 'calibration.pixel_um    = %.6g%s\n', prm.pxUm, fallbackNote(pxSrc));
fprintf(fid, 'calibration.pixel_um_src= %s\n', pxSrc);
% The EFFECTIVE frame interval, from R — not prm.dtS, which is the interval between PAGES. With
% de-interleaving on they differ by the stride, and spt_project_calib treats this line as its most
% trustworthy source, ahead of the tracks XML. Writing the page interval here handed Tools 2 and 3
% a dt half the real one while the XML said otherwise: every diffusion coefficient, dwell second
% and k_out downstream would have been wrong by the stride, with the two files disagreeing.
dtEff = gf(R,'dtS',prm.dtS);
fprintf(fid, 'calibration.frame_s     = %.6g%s\n', dtEff, fallbackNote(dtSrc));
fprintf(fid, 'calibration.frame_s_src = %s\n', dtSrc);
% MACHINE-READABLE, unlike the prose above it: these three are what a second colour needs to be put
% on the same clock as the first, and spt_project_calib reads this file already.
fprintf(fid, 'calibration.t0_s        = %.6g\n', gf(R,'t0_s',0));
fprintf(fid, 'channel.key             = %s\n', gf(R,'chKey',''));
fprintf(fid, 'channel.frame_s_src     = %s\n', gf(R,'dtSrcCh','page x stride'));
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

function s = fallbackNote(src)
% Spell the downgrade out on the value line itself, the way link_mode_req does — a reader scanning
% the numbers should not have to notice a separate _src line to see that one of them is a guess.
if strcmpi(src,'panel')
    s = '   (FALLBACK — nothing in this cell supplied one; value from the panel)';
else
    s = '';
end
end

function v = gf(s, f, d), if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end, end

function v = gs(s, f, d)
% String field, or a placeholder. '(none)' rather than an empty line, because "matched with nothing
% stripped" is a real, valid answer and must not read as "this run recorded nothing".
v = d;
if isfield(s,f) && ~isempty(s.(f)) && (ischar(s.(f)) || isstring(s.(f))), v = char(s.(f)); end
end

function y = tern_(c, a, b), if c, y = a; else, y = b; end, end
