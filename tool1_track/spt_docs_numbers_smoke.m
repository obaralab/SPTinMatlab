function spt_docs_numbers_smoke()
%SPT_DOCS_NUMBERS_SMOKE  Every figure quoted in the docs must be reproducible from the code.
%
% docs/help.html states, as measured fact, what distinguishes <base>_spots.csv from
% <base>_spots_filtered.csv. Numbers in prose rot silently — nothing recomputes them, and a reader
% has no way to tell a stale figure from a current one. So this rebuilds the whole comparison from
% a synthetic cell run through the real writer, and checks each claim the table makes.
%
% It asserts the RELATIONSHIPS, not the reference cell's specific counts: the row count is identical
% between the two files, the filtered file differs only in TRACK_ID, the survivors are renumbered
% from zero, and the two "spots" statistics mean the two different things the docs say they do.
% Those are the properties a reader relies on; the 116,092 in the table is one cell's illustration.

here = fileparts(mfilename('fullpath')); addpath(here);
tmp = fullfile(tempdir,'spt_docs_numbers'); if isfolder(tmp), rmdir(tmp,'s'); end
mkdir(tmp);
base = 'cellD';

% ---- a cell with a mix of long tracks, short tracks and untracked detections --------------------
rng(3);
nLong = 6; lenLong = 60; nShort = 40; lenShort = 4; nLoose = 150;
rows = {}; sid = 0; tid = 0;
for k = 1:nLong+nShort
    n = lenLong; if k > nLong, n = lenShort; end
    x = 5+rand*10; y = 5+rand*10;
    for j = 1:n
        rows(end+1,:) = {tid, sid, j-1, (j-1)*0.01, x+0.05*j, y+0.05*j}; %#ok<AGROW>
        sid = sid + 1;
    end
    tid = tid + 1;
end
for k = 1:nLoose                                  % never tracked -> blank TRACK_ID
    rows(end+1,:) = {NaN, sid, randi(60)-1, 0, 20*rand, 20*rand}; %#ok<AGROW>
    sid = sid + 1;
end
writeSpots(fullfile(tmp,[base '_spots.csv']), rows);

C  = spt_filter_read(fullfile(tmp,[base '_spots.csv']));
km = C.len >= 50;                                  % the same rule the app's default filter applies
st = spt_filter_write(C, km, tmp, base);

A = readtable(fullfile(tmp,[base '_spots.csv']));
B = readtable(fullfile(tmp,[base '_spots_filtered.csv']));
ta = numcol(A,'TRACK_ID'); tb = numcol(B,'TRACK_ID');

fprintf('%-30s %10s %10s\n','','_spots','_spots_filtered');
fprintf('%-30s %10d %10d\n','rows', height(A), height(B));
fprintf('%-30s %10d %10d\n','with a TRACK_ID', sum(~isnan(ta)), sum(~isnan(tb)));
fprintf('%-30s %10d %10d\n','blank TRACK_ID', sum(isnan(ta)), sum(isnan(tb)));
fprintf('%-30s %10d %10d\n','distinct tracks', numel(unique(ta(~isnan(ta)))), numel(unique(tb(~isnan(tb)))));

% ---- claim 1: same number of detections ---------------------------------------------------------
assert(height(A) == height(B), ...
    'the docs say both files hold the same detections, but %d vs %d rows', height(A), height(B));

% ---- claim 2: the SAME detections, not merely the same count ------------------------------------
assert(isequal(sort(A.SPOT_ID), sort(B.SPOT_ID)), 'the SPOT_ID sets differ — rows were dropped or added');
assert(isequal(round(sort(A.X_um),4), round(sort(B.X_um),4)), 'the coordinates differ between the two files');
assert(width(A) == width(B), 'the column counts differ: %d vs %d', width(A), width(B));

% ---- claim 3: only TRACK_ID differs -------------------------------------------------------------
[~,ia] = sort(A.SPOT_ID); [~,ib] = sort(B.SPOT_ID);
for v = setdiff(A.Properties.VariableNames, {'TRACK_ID'})
    if ~isnumeric(A.(v{1})), continue; end
    assert(isequaln(round(A.(v{1})(ia),4), round(B.(v{1})(ib),4)), ...
        'column %s changed between the two files — the docs say only TRACK_ID does', v{1});
end

% ---- claim 4: the filter un-assigns rather than deletes -----------------------------------------
lost = sum(~isnan(ta)) - sum(~isnan(tb));
gained = sum(isnan(tb)) - sum(isnan(ta));
fprintf('\nnumbered rows lost = %d, blanks gained = %d (the docs say these are the same number)\n', lost, gained);
assert(lost == gained, 'rows vanished instead of being un-assigned: %d lost vs %d blanked', lost, gained);

% ---- claim 5: survivors renumbered 0..K-1 -------------------------------------------------------
kept = unique(tb(~isnan(tb)));
assert(isequal(kept(:)', 0:numel(kept)-1), 'kept tracks are not renumbered 0..K-1: %s', mat2str(kept(:)'));
assert(numel(kept) == sum(km), 'kept-track count disagrees with the filter mask');
fprintf('survivors renumbered 0..%d\n', numel(kept)-1);

% ---- claim 6: the two "spots" statistics mean different things ----------------------------------
% The docs warn that n_spots_written equals the raw count and says nothing about the filter, while
% n_spots_in_kept_tracks is the one that answers "how much came through".
assert(st.nSpots == height(A), ...
    'n_spots_written should equal every detection (%d), got %d', height(A), st.nSpots);
assert(st.nSpotsKept == sum(~isnan(tb)), ...
    'n_spots_in_kept_tracks should equal the numbered rows of the filtered file');
assert(st.nSpotsKept < st.nSpots, 'the fixture does not exercise the distinction the docs warn about');
fprintf('n_spots_written = %d (all), n_spots_in_kept_tracks = %d (survivors)\n', st.nSpots, st.nSpotsKept);

% ---- claim 7: the XML pair IS a genuine subset ---------------------------------------------------
nAll  = xmlTracks(fullfile(tmp,[base '_tracks_filtered.xml']));
assert(nAll == sum(km), 'the filtered XML should hold exactly the surviving tracks');
fprintf('filtered XML holds %d of %d tracks — a real subset, unlike the CSV\n', nAll, numel(C.len));

% ---- claim 8: the docs section still exists and still says this ----------------------------------
doc = fileread(fullfile(fileparts(here),'docs','help.html'));
for need = {'t1twocsv', 'n_spots_in_kept_tracks', 'un-assigns'}
    assert(contains(doc, need{1}), 'docs/help.html no longer covers "%s"', need{1});
end
fprintf('docs section #t1twocsv present\n');

fprintf('\nALL DOC-NUMBER ASSERTIONS PASSED.\n');
end

function v = numcol(T, name)
c = T.(name);
if isnumeric(c), v = double(c); else, v = str2double(string(c)); end
end

function writeSpots(path, rows)
fid = fopen(path,'w'); c = onCleanup(@() fclose(fid));
fprintf(fid, ['TRACK_ID,SPOT_ID,FRAME,T_s,X_um,Y_um,QUALITY,' ...
    'MEAN_INTENSITY,MAX_INTENSITY,TOTAL_INTENSITY,MITO_DIST_UM,ER_DIST_UM,ELONGATION,ORIENT_DEG\n']);
for i = 1:size(rows,1)
    t = rows{i,1}; if isnan(t), ts = ''; else, ts = sprintf('%d',t); end
    fprintf(fid, '%s,%d,%d,%.6f,%.4f,%.4f,%.4f,%.2f,%.2f,%.1f,,,,\n', ...
        ts, rows{i,2}, rows{i,3}, rows{i,4}, rows{i,5}, rows{i,6}, 100, 50, 80, 500);
end
end

function n = xmlTracks(f)
n = NaN;
try
    fid = fopen(f,'r'); c = onCleanup(@() fclose(fid));
    head = fread(fid, 2048, '*char')';
    t = regexp(head, 'nTracks="(\d+)"', 'tokens','once');
    if ~isempty(t), n = str2double(t{1}); end
catch
end
end
