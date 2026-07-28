function [outPath, prov] = combine_trackstructs(files, outPath, sourceLabels)
%COMBINE_TRACKSTRUCTS  Merge several TrackStruct.mat into one combined TrackStruct.mat.
%
% For a multi-day final analysis: build tracks per day (each writes its own TrackStruct.mat),
% then combine them into ONE per-cell Tracks struct array so the contact-site pipeline and the
% cross-condition comparison run over all days together. Fields are ALIGNED across sources
% (union; a field missing in one source is filled with []), cells are concatenated in file
% order, and each combined cell's SOURCE is recorded so provenance is never lost.
%
%   [outPath, prov] = combine_trackstructs(files, outPath)
%   [outPath, prov] = combine_trackstructs(files, outPath, sourceLabels)
%
%   files        : cellstr of paths to TrackStruct.mat / Tracks.mat / Tracks_final.mat
%   outPath      : path to write the combined TrackStruct.mat (Tracks + source saved)
%   sourceLabels : optional cellstr (one per file) — a short day/source tag; default = file stem
%
%   prov : table(cellIndex, file, source) mapping each combined cell to where it came from.
%
% NOTE cellIndex in the combined struct is 1..Ncombined; downstream (CS_final cellIndex,
% cell_index_map.csv, the manifest) keys on the per-cell filename, so keep those unique across
% days (a duplicate filename across sources is warned about — add source tags if so).

if nargin<3 || isempty(sourceLabels), sourceLabels = {}; end
assert(iscell(files) && ~isempty(files), 'combine_trackstructs: files must be a non-empty cellstr.');

aligned = {}; labels = {};
for f = 1:numel(files)
    if exist(files{f},'file')~=2, warning('combine:missing','skipping (not found): %s', files{f}); continue; end
    L = load(files{f}); T = [];
    if isfield(L,'Tracks'), T = L.Tracks; elseif isfield(L,'TrackStruct'), T = L.TrackStruct; end
    if isempty(T) || ~isstruct(T), warning('combine:noTracks','skipping (no Tracks struct): %s', files{f}); continue; end
    aligned{end+1} = T(:)'; %#ok<AGROW>
    if f<=numel(sourceLabels) && ~isempty(sourceLabels{f}), labels{end+1} = sourceLabels{f}; %#ok<AGROW>
    else, [~,stem] = fileparts(files{f}); labels{end+1} = stem; %#ok<AGROW>
    end
end
if isempty(aligned), error('combine:empty','No valid TrackStruct files to combine.'); end

% union of fields (first-seen order), then fill missing + reorder each source to match
allF = {};
for k = 1:numel(aligned), allF = union(allF, fieldnames(aligned{k}), 'stable'); end
for k = 1:numel(aligned)
    T = aligned{k};
    miss = setdiff(allF, fieldnames(T));
    for m = 1:numel(miss), [T.(miss{m})] = deal([]); end
    aligned{k} = orderfields(T, allF);
end

Tracks = [aligned{:}];                        % concatenate all cells across sources
source  = {};
for k = 1:numel(aligned), source = [source, repmat(labels(k), 1, numel(aligned{k}))]; end %#ok<AGROW>

% warn on duplicate cell filenames across sources (would collide in per-cell outputs)
if isfield(Tracks,'file') && ~isempty(Tracks)
    fs = {Tracks.file}; [u,~,ic] = unique(fs); dc = accumarray(ic,1); dups = u(dc>1);
    if ~isempty(dups)
        warning('combine:dupnames', ['%d cell filename(s) appear in more than one source (e.g. "%s"). ' ...
            'They will collide in per-cell outputs — re-build with day prefixes or pass sourceLabels.'], numel(dups), dups{1});
    end
end

save(outPath, 'Tracks', 'source', '-v7.3');

fn = cell(1,numel(Tracks));
for j = 1:numel(Tracks), if isfield(Tracks,'file') && ~isempty(Tracks(j).file), fn{j} = Tracks(j).file; else, fn{j} = ''; end, end
prov = table((1:numel(Tracks))', fn(:), source(:), 'VariableNames', {'cellIndex','file','source'});
fprintf('combine_trackstructs: %d source(s) -> %d cells -> %s\n', numel(aligned), numel(Tracks), outPath);
end
