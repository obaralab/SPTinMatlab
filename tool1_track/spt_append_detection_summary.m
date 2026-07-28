function spt_append_detection_summary(tracksDir, base, cel, prm, R)
%SPT_APPEND_DETECTION_SUMMARY  Upsert one row per cell into <tracksDir>/detection_summary.csv.
%
% A project-level run table: for every cell, the detection threshold AND the tracking method/params
% used, so across many cells you can see each cell's percentile / quality gate and linking mode at a
% glance. Re-running a cell REPLACES its prior row (keyed by cell name).
f   = fullfile(tracksDir, 'detection_summary.csv');
hdr = 'cell,threshold_mode,top_percent,quality_min,thr_abs,diameter_um,link_mode,link_um,max_gap_um,max_gap_frames,lambda,n_spots,n_tracks,er_aware,run_time';
diamUm  = gf(cel,'diamUm',0.5);
keepPct = gf(cel,'keepPct',6);
isQual  = isfield(cel,'thrMode') && strcmpi(cel.thrMode,'qual');
if isQual, modeTxt = 'quality-abs'; else, modeTxt = 'top-percentile'; end
qMin = gf(cel,'qualThr',[]); if isempty(qMin) || ~(qMin>0), qMinTxt = 'NA'; else, qMinTxt = sprintf('%.6g', qMin); end
if isfield(cel,'thrAbs') && ~isempty(cel.thrAbs), thrTxt = sprintf('%.6g', cel.thrAbs); else, thrTxt = 'NA'; end
row = sprintf('%s,%s,%.4g,%s,%s,%.4g,%s,%.4g,%.4g,%d,%.4g,%d,%d,%d,%s', base, modeTxt, keepPct, qMinTxt, thrTxt, diamUm, ...
    gf(R,'linkMode',gf(prm,'linkMode','penalty')), ...   % EFFECTIVE mode (matches <base>_settings.txt)
    gf(prm,'linkUm',NaN), gf(prm,'gapUm',NaN), gf(prm,'maxGap',0), gf(prm,'lambda',NaN), ...
    numel(R.spotId), R.nTracks, R.erAware, datestr(now,'yyyy-mm-dd HH:MM:SS'));
lines = {};
if isfile(f)
    try, txt = fileread(f); lines = regexp(txt, '\r?\n', 'split'); lines = lines(~cellfun(@isempty,lines)); catch, end
end
out = {hdr};
for i = 1:numel(lines)
    L = lines{i};
    if startsWith(L, 'cell,threshold_mode'), continue; end   % drop the old header
    comma = find(L==',',1); first = L; if ~isempty(comma), first = L(1:comma-1); end
    if strcmp(first, base), continue; end                     % upsert: drop this cell's prior row
    out{end+1} = L; %#ok<AGROW>
end
out{end+1} = row;
fid = fopen(f, 'w'); if fid < 0, return; end
c = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid, '%s\n', out{:});
end

function v = gf(s, f, d), if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end, end
