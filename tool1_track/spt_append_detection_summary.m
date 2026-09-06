function spt_append_detection_summary(tracksDir, base, cel, prm, R)
%SPT_APPEND_DETECTION_SUMMARY  Upsert one row per cell into <tracksDir>/detection_summary.csv.
%
% A project-level run table: for every cell, the detection threshold AND the tracking method/params
% used, so across many cells you can see each cell's percentile / quality gate and linking mode at a
% glance. Re-running a cell REPLACES its prior row (keyed by cell name).
f    = fullfile(tracksDir, 'detection_summary.csv');
CORE = 'cell,threshold_mode,top_percent,quality_min,thr_abs,diameter_um,link_mode,link_um,max_gap_um,max_gap_frames,lambda,n_spots,n_tracks,run_time';
% Calibration is per cell, so the project table has to carry it: this is the one file where you can
% see every cell's scale side by side, and "cell 3 was tracked at 0.16 and the rest at 0.10785" is
% otherwise only visible by opening fourteen _settings.txt files. calib_src says which of them were
% measured and which fell back to the panel.
hdr = [CORE ',pixel_um,frame_s,calib_src'];
HDR_OLD = [CORE(1:end-length(',run_time')) ',er_aware,run_time'];   % what rows before the rename have
nWant = numel(strfind(hdr,',')) + 1;
diamUm  = gf(cel,'diamUm',0.5);
keepPct = gf(cel,'keepPct',6);
isQual  = isfield(cel,'thrMode') && strcmpi(cel.thrMode,'qual');
if isQual, modeTxt = 'quality-abs'; else, modeTxt = 'top-percentile'; end
qMin = gf(cel,'qualThr',[]); if isempty(qMin) || ~(qMin>0), qMinTxt = 'NA'; else, qMinTxt = sprintf('%.6g', qMin); end
% Prefer the threshold the engine actually used: 'NA' for every un-previewed cell made a batch
% impossible to check for per-cell thresholds, which is the whole point of this table.
tu = []; if isstruct(R) && isfield(R,'thrUsed'), tu = R.thrUsed; end
if ~isempty(tu) && isscalar(tu) && isfinite(tu), thrTxt = sprintf('%.6g', tu);
elseif isfield(cel,'thrAbs') && ~isempty(cel.thrAbs), thrTxt = sprintf('%.6g', cel.thrAbs);
else, thrTxt = 'NA'; end
% One calib_src for the row: the two sources agree in all but the mixed case, and when they differ
% both are named rather than one standing for both.
pxSrc = gs(prm,'pxUmSrc','unknown'); dtSrc = gs(prm,'dtSSrc','unknown');
calSrc = pxSrc; if ~strcmp(pxSrc,dtSrc), calSrc = [pxSrc '/' dtSrc]; end
row = sprintf('%s,%s,%.4g,%s,%s,%.4g,%s,%.4g,%.4g,%d,%.4g,%d,%d,%s,%.6g,%.6g,%s', base, modeTxt, keepPct, qMinTxt, thrTxt, diamUm, ...
    gf(R,'linkMode',gf(prm,'linkMode','penalty')), ...   % EFFECTIVE mode (matches <base>_settings.txt)
    gf(prm,'linkUm',NaN), gf(prm,'gapUm',NaN), gf(prm,'maxGap',0), gf(prm,'lambda',NaN), ...
    numel(R.spotId), R.nTracks, datestr(now,'yyyy-mm-dd HH:MM:SS'), ...
    gf(prm,'pxUm',NaN), gf(prm,'dtS',NaN), calSrc);
lines = {};
if isfile(f)
    try, txt = fileread(f); lines = regexp(txt, '\r?\n', 'split'); lines = lines(~cellfun(@isempty,lines)); catch, end
end
out = {hdr}; wasOld = false;
for i = 1:numel(lines)
    L = lines{i};
    if startsWith(L, 'cell,threshold_mode')
        wasOld = strcmp(strtrim(L), HDR_OLD);                 % remember which layout the rows use
        continue;                                             % drop the old header either way
    end
    comma = find(L==',',1); first = L; if ~isempty(comma), first = L(1:comma-1); end
    if strcmp(first, base), continue; end                     % upsert: drop this cell's prior row
    % The er_aware column is gone. The file is rewritten whole with the CURRENT header, so rows
    % carrying the extra field would leave it ragged — drop that field from them rather than
    % silently misaligning every column after it.
    if wasOld, L = drop_field(L, 14); end
    % The mirror of the drop above, for the columns ADDED when calibration became per cell. Rows
    % written before then are short, and the file is rewritten whole under the current header — so
    % pad them rather than leave every column after run_time misaligned. Counted per row rather than
    % from the old header, so a row from any earlier layout is padded to fit.
    np = numel(strfind(L,',')) + 1;
    if np < nWant, L = [L repmat(',NA', 1, nWant-np)]; end
    out{end+1} = L; %#ok<AGROW>
end
out{end+1} = row;
fid = fopen(f, 'w'); if fid < 0, return; end
c = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid, '%s\n', out{:});
end

function L = drop_field(L, k)
% Remove the kth comma-separated field. Only used to migrate rows written before er_aware was
% dropped; no field in this file can contain a comma, so a plain split is safe here.
p = strsplit(L, ',');
if numel(p) > k, p(k) = []; end
L = strjoin(p, ',');
end

function v = gf(s, f, d), if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end, end

function v = gs(s, f, d)
% String field, or a placeholder. Read defensively: callers that build a prm literal without the
% provenance fields (the smoke fixtures do) must keep working.
v = d;
if isfield(s,f) && ~isempty(s.(f)) && (ischar(s.(f)) || isstring(s.(f))), v = char(s.(f)); end
end
