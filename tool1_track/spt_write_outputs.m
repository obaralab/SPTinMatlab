function [csvPath, xmlPath] = spt_write_outputs(R, tracksDir)
%SPT_WRITE_OUTPUTS  Write <base>_spots.csv (ALL detections) + <base>_tracks.xml (tracks).
%
%   [csvPath, xmlPath] = spt_write_outputs(R, tracksDir)
%
% R = output of spt_process_cell. The schema matches ERAware / TrackImporter_direct exactly, so the
% analysis app reads these unchanged:
%   _spots.csv : TRACK_ID,SPOT_ID,FRAME,T_s,X_um,Y_um,QUALITY,MEAN_INTENSITY,MAX_INTENSITY,
%                TOTAL_INTENSITY,MITO_DIST_UM  — one row PER DETECTION (TRACK_ID blank when untracked).
%   _tracks.xml: <Tracks nTracks= frameInterval= spaceUnit="um" timeUnit="s"><Track TRACK_ID>
%                <Spot FRAME T X Y Z SPOT_ID/> ...  — X/Y in µm, SPOT_ID shared with the CSV.
% X_um/Y_um use a 0-based pixel origin ((x-1)*px) to match ERAware's coordinate convention.
if ~isfolder(tracksDir), mkdir(tracksDir); end
px = R.pxUm; dt = R.dtS; base = R.base;

% ---- spots CSV (every detection) ----
csvPath = fullfile(tracksDir, [base '_spots.csv']);
fid = fopen(csvPath, 'w');
if fid < 0, error('spt_write_outputs:csv','cannot write %s', csvPath); end
c = onCleanup(@() fclose(fid));
fprintf(fid, ['TRACK_ID,SPOT_ID,FRAME,T_s,X_um,Y_um,QUALITY,' ...
    'MEAN_INTENSITY,MAX_INTENSITY,TOTAL_INTENSITY,MITO_DIST_UM,ER_DIST_UM,ELONGATION,ORIENT_DEG\n']);
hasEr    = isfield(R,'er')    && numel(R.er)    == numel(R.spotId);
hasShape = isfield(R,'elong') && numel(R.elong) == numel(R.spotId);
for i = 1:numel(R.spotId)
    if isnan(R.trackId(i)), tidStr = ''; else, tidStr = sprintf('%d', R.trackId(i)); end
    if isnan(R.mito(i)),    mdStr  = ''; else, mdStr  = sprintf('%.4f', R.mito(i)); end
    if ~hasEr || isnan(R.er(i)), erStr = ''; else, erStr = sprintf('%.4f', R.er(i)); end
    if hasShape, elStr = sprintf('%.3f', R.elong(i)); orStr = sprintf('%.1f', R.orient(i)); else, elStr = ''; orStr = ''; end
    fprintf(fid, '%s,%d,%d,%.6f,%.4f,%.4f,%.4f,%.2f,%.2f,%.1f,%s,%s,%s,%s\n', ...
        tidStr, R.spotId(i), R.frame(i), R.frame(i)*dt, ...
        (R.x(i)-1)*px, (R.y(i)-1)*px, R.q(i), R.mean(i), R.max(i), R.total(i), mdStr, erStr, elStr, orStr);
end
clear c   % close CSV

% ---- tracks XML (shared SPOT_IDs) ----
xmlPath = fullfile(tracksDir, [base '_tracks.xml']);
rowOf = containers.Map('KeyType','double','ValueType','double');
for i = 1:numel(R.spotId), rowOf(R.spotId(i)) = i; end
fid = fopen(xmlPath, 'w');
if fid < 0, error('spt_write_outputs:xml','cannot write %s', xmlPath); end
c2 = onCleanup(@() fclose(fid));
fprintf(fid, '<?xml version="1.0" encoding="UTF-8"?>\n');
fprintf(fid, '<Tracks nTracks="%d" frameInterval="%.6g" spaceUnit="um" timeUnit="s">\n', numel(R.xmlTracks), dt);
for k = 1:numel(R.xmlTracks)
    T = R.xmlTracks{k};
    fprintf(fid, '  <Track TRACK_ID="%d">\n', T.tid);
    for s = 1:numel(T.spotIds)
        i = rowOf(T.spotIds(s));
        fprintf(fid, '    <Spot FRAME="%d" T="%.6f" X="%.6f" Y="%.6f" Z="0.0" SPOT_ID="%d"/>\n', ...
            R.frame(i), R.frame(i)*dt, (R.x(i)-1)*px, (R.y(i)-1)*px, R.spotId(i));
    end
    fprintf(fid, '  </Track>\n');
end
fprintf(fid, '</Tracks>\n');
end
