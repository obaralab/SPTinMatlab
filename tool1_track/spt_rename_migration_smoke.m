function spt_rename_migration_smoke()
%SPT_RENAME_MIGRATION_SMOKE  Two renames must not orphan data already on disk.
%
% Tool 1 only FILTERS — by track length and net displacement. Curation proper (density,
% step-variance, per-track inspection) is Tool 2's job, so the settings block it writes is now
% `filter.*` rather than `curation.*`. And `tracking.er_aware` is gone: it was a boolean from before
% the three-way link mode existed, fully derivable from `tracking.link_mode`, naming a mode the app
% no longer has right next to the two lines that state the real one.
%
% Both live in files already written for real projects, so this pins the migrations:
%   - Tool 3's experiment status must still read a settings file written with `curation.*`
%   - detection_summary.csv rows carrying the extra er_aware field must be re-aligned, not left
%     ragged against the new header

here = fileparts(mfilename('fullpath')); addpath(here);
addpath(fullfile(fileparts(here),'tool2_analyze','drivers'));
tmp = fullfile(tempdir,'spt_rename_migration'); if isfolder(tmp), rmdir(tmp,'s'); end
mkdir(tmp); tr = fullfile(tmp,'tracks'); mkdir(tr);

% ---- 1. the writer emits the NEW spelling ---------------------------------------------------------
base = 'cellA';
fset = fullfile(tr,[base '_settings.txt']);
fid = fopen(fset,'w'); fprintf(fid,'# SPT Track run settings\nresult.n_tracks         = 900\n'); fclose(fid);
spt_append_filter_settings(tr, base, 50, 0.2, struct('before',900,'after',273,'nSpots',116092,'nSpotsKept',27194));
txt = fileread(fset);
assert(contains(txt,'filter.tracks_after'), 'the writer is not emitting filter.*');
assert(~contains(txt,'curation.'), 'a curation.* key is still being written');
assert(~contains(txt,'er_aware'), 'this file should carry no er_aware key');
fprintf('writer emits filter.*, no curation.*, no er_aware\n');

% ---- 2. a file written BEFORE the rename must still be readable ------------------------------------
oldBase = 'cellOld';
fold = fullfile(tr,[oldBase '_settings.txt']);
fid = fopen(fold,'w');
fprintf(fid, ['# SPT Track run settings\n' ...
              'tracking.link_mode      = geodesic\n' ...
              'tracking.er_aware       = 1\n' ...
              'result.n_spots          = 116092\n' ...
              'result.n_tracks         = 5564\n' ...
              'curation.min_track_len  = 50\n' ...
              'curation.tracks_before  = 5564\n' ...
              'curation.tracks_after   = 273\n' ...
              'curation.n_spots_in_kept_tracks = 27194\n']);
fclose(fid);
% enough of a project for cs_experiment_status to look at this cell
fid = fopen(fullfile(tr,[oldBase '_tracks.xml']),'w');
fprintf(fid,'<?xml version="1.0"?>\n<Tracks nTracks="5564" frameInterval="0.01" spaceUnit="um" timeUnit="s">\n</Tracks>\n');
fclose(fid);
rec = struct('file', oldBase, 'analysis', fullfile(tmp,'analysis'), 'tracks', tr);
S = cs_experiment_status(rec);
fprintf('pre-rename cell: nTracksFiltered = %g (expect 273)\n', S.nTracksFiltered);
assert(S.nTracksFiltered == 273, ...
    'curation.tracks_after is no longer read — every project tracked before the rename loses its filtered count');
assert(S.nSpotsInTracks == 27194, 'curation.n_spots_in_kept_tracks is no longer read');

% ...and the NEW spelling reads through the same code path
fid = fopen(fullfile(tr,[base '_tracks.xml']),'w');
fprintf(fid,'<?xml version="1.0"?>\n<Tracks nTracks="900" frameInterval="0.01" spaceUnit="um" timeUnit="s">\n</Tracks>\n');
fclose(fid);
rec2 = struct('file', base, 'analysis', fullfile(tmp,'analysis'), 'tracks', tr);
S2 = cs_experiment_status(rec2);
fprintf('post-rename cell: nTracksFiltered = %g (expect 273)\n', S2.nTracksFiltered);
assert(S2.nTracksFiltered == 273, 'filter.tracks_after is not read');
assert(S2.nSpotsInTracks == 27194, 'filter.n_spots_in_kept_tracks is not read');

% ---- 3. detection_summary.csv rows written with er_aware must be re-aligned -------------------------
fcsv = fullfile(tr,'detection_summary.csv');
oldHdr = 'cell,threshold_mode,top_percent,quality_min,thr_abs,diameter_um,link_mode,link_um,max_gap_um,max_gap_frames,lambda,n_spots,n_tracks,er_aware,run_time';
oldRow = 'oldCell,top-percentile,6,NA,59.5,0.5,geodesic,0.8,1.4,1,3,116092,5564,1,2026-08-03 15:09:32';
fid = fopen(fcsv,'w'); fprintf(fid,'%s\n%s\n',oldHdr,oldRow); fclose(fid);

R = struct('spotId',{{1,2,3}},'nTracks',42,'linkMode','penalty');
spt_append_detection_summary(tr, 'newCell', struct('diamUm',0.5,'keepPct',6), ...
    struct('linkUm',0.8,'gapUm',1.4,'maxGap',1,'lambda',3), R);

L = strsplit(strtrim(fileread(fcsv)), newline);
nh = numel(strsplit(L{1}, ','));
fprintf('header now %d columns; rows: ', nh);
assert(~contains(L{1},'er_aware'), 'the header still carries er_aware');
for i = 2:numel(L)
    nf = numel(strsplit(L{i}, ','));
    fprintf('%d ', nf);
    assert(nf == nh, 'row %d has %d fields against a %d-column header — the file is ragged', i-1, nf, nh);
end
fprintf('\n');
% The migrated row must keep its OWN values, not have them shifted by the dropped column.
% run_time is no longer the LAST field: pixel_um / frame_s / calib_src were appended when calibration
% became per cell, and a row written before they existed is padded so the file stays square. So the
% check moved from "run_time is last" to "run_time is still at its own column" — the same property,
% stated in a way the added columns cannot invalidate — plus: the padding must be visibly NA, never a
% number this row never had.
hdrF = strsplit(L{1}, ',');
old  = strsplit(L{contains(L,'oldCell')}, ',');
iRun = find(strcmp(hdrF,'run_time'), 1);
assert(~isempty(iRun), 'run_time is gone from the header');
assert(strcmp(old{iRun}, '2026-08-03 15:09:32'), 'the migrated row lost its run_time; fields shifted');
assert(strcmp(old{13}, '5564'), 'the migrated row''s n_tracks moved: got %s', old{13});
assert(all(strcmp(old(iRun+1:end), 'NA')), ...
    'a row predating per-cell calibration was padded with something other than NA — it would read as measured');
fprintf('pre-rename row migrated in place (n_tracks %s, run_time %s, %d padded column(s))\n', ...
    old{13}, old{iRun}, numel(old)-iRun);

% ---- 4. prm.erAware must still be honoured ----------------------------------------------------------
src = fileread(fullfile(here,'spt_process_cell.m'));
assert(contains(src,'erAware'), ...
    'spt_process_cell no longer accepts the legacy prm.erAware — an external script building prm would silently drop to Euclidean');
fprintf('spt_process_cell still honours the legacy prm.erAware\n');

% ---- 5. no stale wording anywhere the user can read -------------------------------------------------
% "ER-aware" named a two-way boolean that predates the Euclidean / ER-penalty / ER-geodesic dropdown,
% so it no longer names anything the app offers. "Curation" is Tool 2's word — Tool 1 only filters.
f = spt_app(); cf = onCleanup(@() closeQuiet(f));
drawnow; pause(0.3);
stale = {};
for h = findobj(f)'
    for prop = {'Text','Tooltip','Placeholder','Title'}
        if ~isprop(h, prop{1}), continue; end
        v = h.(prop{1});
        if ~(ischar(v) || isstring(v)), continue; end
        t = char(string(v)); lt = lower(t);
        if contains(lt,'er-aware') || contains(lt,'eraware')
            stale{end+1} = sprintf('[%s] %s', prop{1}, t); %#ok<AGROW>
        end
        % "Tool 2's curation" is correct and stays; anything else in Tool 1 is not
        if contains(lt,'curat') && ~contains(lt,'tool 2''s curation')
            stale{end+1} = sprintf('[%s] %s', prop{1}, t); %#ok<AGROW>
        end
    end
end
if ~isempty(stale)
    error('spt_rename_migration_smoke:stale', ...
        'Tool 1 still shows wording it no longer means:\n  %s', strjoin(stale, sprintf('\n  ')));
end
fprintf('no "ER-aware" or stray "curation" in any visible Tool 1 string\n');
clear cf;

fprintf('\nALL RENAME-MIGRATION ASSERTIONS PASSED.\n');
end

function closeQuiet(g)
try, delete(timerfindall); catch, end
try, delete(g); catch, end
end
