function C = spt_filter_read(csvPath)
%SPT_FILTER_READ  Read a <base>_spots.csv into the all-spots table + per-track metrics for curation.
%
%   C = spt_filter_read(csvPath)
%
% C.spots : the full spots table (every detection — the localization cloud stays intact).
% C.trackId/len/dispUm/meanQ : per-track metrics (net displacement in µm, mean DoG quality).
% C.rows  : cell array; C.rows{k} = the spot rows (frame-sorted) belonging to track k.
% Curation filters TRACKS by these metrics; the spots table is passed through unchanged.
S = readtable(csvPath, 'Delimiter', ',');
C.spots = S;
tid = colnum(S, 'TRACK_ID');
F = colnum(S,'FRAME'); X = colnum(S,'X_um'); Y = colnum(S,'Y_um'); Q = colnum(S,'QUALITY');
ids = unique(tid(~isnan(tid)));
n = numel(ids);
C.trackId = zeros(n,1); C.len = zeros(n,1); C.dispUm = zeros(n,1); C.meanQ = zeros(n,1); C.rows = cell(n,1);
for k = 1:n
    r = find(tid == ids(k));
    [~, o] = sort(F(r)); r = r(o);
    C.trackId(k) = ids(k);
    C.len(k)     = numel(r);
    C.dispUm(k)  = hypot(X(r(end))-X(r(1)), Y(r(end))-Y(r(1)));
    C.meanQ(k)   = mean(Q(r));
    C.rows{k}    = r;
end
end

function v = colnum(S, name)
if ~ismember(name, S.Properties.VariableNames)   % older CSVs may lack ER_DIST_UM (or MITO_DIST_UM)
    v = nan(height(S), 1); return;
end
c = S.(name);
if isnumeric(c), v = double(c); else, v = str2double(string(c)); end   % blank cells -> NaN
end
