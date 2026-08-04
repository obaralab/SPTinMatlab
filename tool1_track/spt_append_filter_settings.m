function spt_append_filter_settings(tracksDir, base, minLen, minDisp, stat)
%SPT_APPEND_FILTER_SETTINGS  Record the LENGTH/DISPLACEMENT FILTER's provenance in <base>_settings.txt.
%
% The detection + tracking method/params are already in the file (written on the run). This upserts a
% `filter.*` block so the settings file also documents exactly how the exported `_filtered` tracks
% were produced. Re-filtering a cell overwrites the block cleanly (the block is stripped, then re-added).
f = fullfile(tracksDir, [base '_settings.txt']);
lines = {};
if isfile(f)
    try, txt = fileread(f); lines = regexp(txt, '\r?\n', 'split'); lines = lines(~cellfun(@isempty,lines)); catch, end
end
% Tool 1 only FILTERS — by track length and net displacement. Curation proper (density,
% step-variance, per-track inspection) is Tool 2's job, so the block is named for what it is.
% Both spellings are stripped so a project written before the rename upserts cleanly instead of
% ending up with two blocks.
lines = lines(~startsWith(lines, 'filter.') & ~startsWith(lines, 'curation.'));
lines{end+1} = sprintf('filter.min_track_len   = %g', minLen);
lines{end+1} = sprintf('filter.min_disp_um     = %g', minDisp);
lines{end+1} = sprintf('filter.tracks_before   = %d', getf_(stat,'before',NaN));
lines{end+1} = sprintf('filter.tracks_after    = %d', getf_(stat,'after',NaN));
% Two DIFFERENT spot counts, which is why the single old key called "n_spots_kept" was misleading:
%   n_spots_written        — every detection in _spots_filtered.csv. The localization cloud is
%                            preserved by design, so this equals result.n_spots and says nothing
%                            about the filter. Named "kept", it read as though nothing was dropped.
%   n_spots_in_kept_tracks — the detections belonging to the tracks that survived. This is the one
%                            that answers "how much data came through this stage?".
lines{end+1} = sprintf('filter.n_spots_written = %d', getf_(stat,'nSpots',NaN));
lines{end+1} = sprintf('filter.n_spots_in_kept_tracks = %d', getf_(stat,'nSpotsKept',NaN));
lines{end+1} = sprintf('filter.exported        = %s', datestr(now,'yyyy-mm-dd HH:MM:SS'));
fid = fopen(f, 'w'); if fid < 0, return; end
c = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid, '%s\n', lines{:});
end

function v = getf_(s, f, d), if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end, end
