function outPath = write_cell_index_map(analysisDir, projectDir)
%WRITE_CELL_INDEX_MAP  Persist the de-blinding key: cellIndex -> source file.
%
% The contact-site outputs (CS_final.mat, the CS Results / Dwell tables and their
% CSV exports) refer to each cell only by its numeric cellIndex — deliberately
% BLINDED so picking and classification aren't biased by the filename/condition.
% This writes the index->filename lookup to <analysisDir>/cell_index_map.csv so the
% blinding can always be reversed. cellIndex is the cell's position in the Tracks
% array (== CS(k).cellIndex), so the mapping is exact and stable as long as the
% TrackStruct is not rebuilt with a different file order (this is rewritten on Build).
%
%   outPath = write_cell_index_map(analysisDir)
%   outPath = write_cell_index_map(analysisDir, projectDir)   % for the manifest lookup
%
% Columns: cellIndex, file, condition (condition filled from <projectDir>/project.mat
% when an Experiment manifest exists, else blank). Returns '' if no Tracks were found.

outPath = '';
if nargin<1 || isempty(analysisDir) || ~isfolder(analysisDir), return; end
if nargin<2 || isempty(projectDir), projectDir = fileparts(analysisDir); end

% Tracks defines the index<->file mapping. Prefer the post-CS Tracks_final, then the
% freshly-built TrackStruct, then legacy Tracks.mat — all share the same cell order.
Tr = [];
for f = {'Tracks_final.mat','TrackStruct.mat','Tracks.mat'}
    p = fullfile(analysisDir, f{1});
    if isfile(p)
        try, L = load(p); if isfield(L,'Tracks') && ~isempty(L.Tracks), Tr = L.Tracks; break; end, catch, end
    end
end
if isempty(Tr), return; end

n = numel(Tr);
cellIndex = (1:n)';
file = strings(n,1);
for i = 1:n
    if isfield(Tr,'file') && ~isempty(Tr(i).file), file(i) = string(Tr(i).file); end
end

% condition per cell, from the Experiment manifest if present (exact name match, then
% a prefix/substring fallback — same join the comparison layer uses).
condition = strings(n,1);
pm = fullfile(projectDir,'project.mat');
if isfile(pm)
    try
        S = load(pm);
        if isfield(S,'expt') && isfield(S.expt,'cells') && ~isempty(S.expt.cells)
            names = string({S.expt.cells.name});
            conds = string({S.expt.cells.condition});
            for i = 1:n
                if strlength(file(i))==0, continue; end
                j = find(names==file(i), 1);
                if isempty(j)
                    j = find(arrayfun(@(k) strlength(names(k))>0 && ...
                        (startsWith(file(i),names(k)) || contains(file(i),names(k))), 1:numel(names)), 1);
                end
                if ~isempty(j) && strlength(strtrim(conds(j)))>0, condition(i) = strtrim(conds(j)); end
            end
        end
    catch
    end
end

T = table(cellIndex, file, condition, 'VariableNames', {'cellIndex','file','condition'});
p = fullfile(analysisDir,'cell_index_map.csv');
try
    writetable(T, p);
    outPath = p;
catch
    outPath = '';
end
end
