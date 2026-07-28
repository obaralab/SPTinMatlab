function stat = spt_curate_write(C, keptMask, tracksDir, base)
%SPT_CURATE_WRITE  Write curated outputs: only TRACKS are filtered; every detection is preserved.
%
%   stat = spt_curate_write(C, keptMask, tracksDir, base)
%
% C        : output of spt_curate_read.
% keptMask : logical over C.trackId — the tracks to keep.
% Writes into tracksDir:
%   <base>_spots_filtered.csv  — ALL detections (unchanged), TRACK_ID renumbered 0..K-1 for kept
%                                tracks and BLANK for spots in dropped tracks / never tracked.
%   <base>_tracks_filtered.xml — the kept tracks only (SPOT_IDs shared with the CSV).
% Returns stat.before / .after (track counts) and .nSpots.
if ~isfolder(tracksDir), mkdir(tracksDir); end
S = C.spots; N = height(S);
keptIdx = find(keptMask);
newTid = nan(N,1);
for kk = 1:numel(keptIdx), newTid(C.rows{keptIdx(kk)}) = kk-1; end   % renumber kept tracks 0..K-1

SPOT=col_(S,'SPOT_ID'); FR=col_(S,'FRAME'); Ts=col_(S,'T_s'); X=col_(S,'X_um'); Y=col_(S,'Y_um');
Q=col_(S,'QUALITY'); MN=col_(S,'MEAN_INTENSITY'); MX=col_(S,'MAX_INTENSITY'); TO=col_(S,'TOTAL_INTENSITY');
MD=col_(S,'MITO_DIST_UM'); ER=col_(S,'ER_DIST_UM'); EL=col_(S,'ELONGATION'); OR=col_(S,'ORIENT_DEG');
fr1 = FR > 0; dt = 0.020064; if any(fr1), dt = median(Ts(fr1)./FR(fr1)); end   % recover frameInterval from T=FR*dt

% ---- _spots_filtered.csv (every detection) ----
csv = fullfile(tracksDir, [base '_spots_filtered.csv']);
fid = fopen(csv,'w'); c1 = onCleanup(@() fclose(fid));
fprintf(fid, ['TRACK_ID,SPOT_ID,FRAME,T_s,X_um,Y_um,QUALITY,' ...
    'MEAN_INTENSITY,MAX_INTENSITY,TOTAL_INTENSITY,MITO_DIST_UM,ER_DIST_UM,ELONGATION,ORIENT_DEG\n']);
for i = 1:N
    if isnan(newTid(i)), tstr=''; else, tstr=sprintf('%d',newTid(i)); end
    if isnan(MD(i)),     mstr=''; else, mstr=sprintf('%.4f',MD(i)); end
    if isnan(ER(i)),     estr=''; else, estr=sprintf('%.4f',ER(i)); end
    if isnan(EL(i)),     lstr=''; else, lstr=sprintf('%.3f',EL(i)); end
    if isnan(OR(i)),     ostr=''; else, ostr=sprintf('%.1f',OR(i)); end
    fprintf(fid, '%s,%d,%d,%.6f,%.4f,%.4f,%.4f,%.2f,%.2f,%.1f,%s,%s,%s,%s\n', ...
        tstr, SPOT(i), FR(i), Ts(i), X(i), Y(i), Q(i), MN(i), MX(i), TO(i), mstr, estr, lstr, ostr);
end
clear c1

% ---- _tracks_filtered.xml (kept tracks) ----
xml = fullfile(tracksDir, [base '_tracks_filtered.xml']);
fid = fopen(xml,'w'); c2 = onCleanup(@() fclose(fid));
fprintf(fid, '<?xml version="1.0" encoding="UTF-8"?>\n');
fprintf(fid, '<Tracks nTracks="%d" frameInterval="%.6g" spaceUnit="um" timeUnit="s">\n', numel(keptIdx), dt);
for kk = 1:numel(keptIdx)
    r = C.rows{keptIdx(kk)};
    fprintf(fid, '  <Track TRACK_ID="%d">\n', kk-1);
    for j = 1:numel(r)
        i = r(j);
        fprintf(fid, '    <Spot FRAME="%d" T="%.6f" X="%.6f" Y="%.6f" Z="0.0" SPOT_ID="%d"/>\n', ...
            FR(i), Ts(i), X(i), Y(i), SPOT(i));
    end
    fprintf(fid, '  </Track>\n');
end
fprintf(fid, '</Tracks>\n');

stat = struct('before', numel(C.trackId), 'after', numel(keptIdx), 'nSpots', N);
end

function v = col_(S, name)
if ~ismember(name, S.Properties.VariableNames)   % tolerate CSVs written before ER_DIST_UM existed
    v = nan(height(S), 1); return;
end
c = S.(name);
if isnumeric(c), v = double(c); else, v = str2double(string(c)); end
end
