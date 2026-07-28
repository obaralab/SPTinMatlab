function spt_append_curation_settings(tracksDir, base, minLen, minDisp, stat)
%SPT_APPEND_CURATION_SETTINGS  Record the curation-filter provenance in <base>_settings.txt.
%
% The detection + tracking method/params are already in the file (written on the run). This upserts a
% `curation.*` block so the settings file also documents exactly how the exported `_filtered` tracks
% were produced. Re-curating a cell overwrites the block cleanly (the block is stripped, then re-added).
f = fullfile(tracksDir, [base '_settings.txt']);
lines = {};
if isfile(f)
    try, txt = fileread(f); lines = regexp(txt, '\r?\n', 'split'); lines = lines(~cellfun(@isempty,lines)); catch, end
end
lines = lines(~startsWith(lines, 'curation.'));   % drop any prior curation block (upsert)
lines{end+1} = sprintf('curation.min_track_len  = %g', minLen);
lines{end+1} = sprintf('curation.min_disp_um    = %g', minDisp);
lines{end+1} = sprintf('curation.tracks_before  = %d', getf_(stat,'before',NaN));
lines{end+1} = sprintf('curation.tracks_after   = %d', getf_(stat,'after',NaN));
lines{end+1} = sprintf('curation.n_spots_kept   = %d', getf_(stat,'nSpots',NaN));
lines{end+1} = sprintf('curation.exported       = %s', datestr(now,'yyyy-mm-dd HH:MM:SS'));
fid = fopen(f, 'w'); if fid < 0, return; end
c = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid, '%s\n', lines{:});
end

function v = getf_(s, f, d), if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end, end
