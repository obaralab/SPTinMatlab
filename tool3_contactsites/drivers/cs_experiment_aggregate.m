function [CSW, DD] = cs_experiment_aggregate(manifest)
%CS_EXPERIMENT_AGGREGATE  Combine mapped/dwell results across an experiment's folders, by condition.
%
%   [CSW, DD] = cs_experiment_aggregate(manifest)
%
% The experiment manifest REFERENCES each day/batch folder (never merges the TrackStructs). This
% reads every folder's CSW_final.mat (+ cs_window_dwell.mat when present) and tags each site/event
% with its cell's CONDITION (from manifest.cells) and its source folder, then concatenates them into
% one combined CSW / DD that the Compare tab groups by condition across the whole dataset.
%
% manifest.cells(k): .folder, .file, .condition   (from cs_experiment_scan + manual assignment)
%
% OUTPUT
%   CSW : combined site-window struct array, each with extra .condition and .srcFolder fields.
%   DD  : struct with .events (each + .condition/.srcFolder), .perSite (+ .condition), .allDwell,
%         and .minPctInside — the >=% inside threshold the folders' dwell was computed at. It is the
%         UNIQUE set, so a non-scalar value means the folders were computed differently and their
%         dwell numbers are not comparable; Compare says so rather than pooling them silently.

CSW = struct([]);
DD  = struct('events',struct([]),'perSite',struct([]),'allDwell',[],'minPctInside',0);
if nargin<1 || ~isstruct(manifest) || ~isfield(manifest,'cells') || isempty(manifest.cells), return; end
cells = manifest.cells;

% (folder|file) -> condition, and the set of EXCLUDED (folder|file) cells to drop
kf = @(fo,fi) sprintf('%s||%s', char(fo), char(fi));
condMap = containers.Map('KeyType','char','ValueType','char');
exclSet = containers.Map('KeyType','char','ValueType','logical');
for k = 1:numel(cells)
    condMap(kf(cells(k).folder, cells(k).file)) = char(cells(k).condition);
    if isfield(cells,'exclude') && ~isempty(cells(k).exclude) && cells(k).exclude
        exclSet(kf(cells(k).folder, cells(k).file)) = true;
    end
end
isExcluded = @(fo,fi) isKey(exclSet, kf(fo,fi));
folders = unique({cells.folder});

allSites = {}; allEv = {}; allPS = {}; allMinPct = [];
for i = 1:numel(folders)
    fo = folders{i};
    fCSW = fullfile(fo,'CSW_final.mat');
    if isfile(fCSW)
        try
            L = load(fCSW);
            if isfield(L,'CSW') && ~isempty(L.CSW)
                C = L.CSW;
                keep = arrayfun(@(x) ~isExcluded(fo, x.file), C);   % drop excluded cells' sites
                C = C(keep);
                for j = 1:numel(C)
                    C(j).condition = getCond(condMap, kf(fo, C(j).file));
                    C(j).srcFolder = fo;
                end
                if ~isempty(C), allSites{end+1} = C; end %#ok<AGROW>
            end
        catch
        end
    end
    fDD = fullfile(fo,'cs_window_dwell.mat');
    if isfile(fDD)
        try
            Ld = load(fDD);
            if isfield(Ld,'DD') && isstruct(Ld.DD)
                % The >=% inside threshold this folder's dwell was computed at. Folders that
                % disagree are pooling two different measurements, so every distinct value is kept
                % and the caller is the one that decides whether to complain.
                if isfield(Ld.DD,'minPctInside') && isscalar(Ld.DD.minPctInside)
                    allMinPct(end+1) = Ld.DD.minPctInside; %#ok<AGROW>
                else
                    allMinPct(end+1) = 0; %#ok<AGROW>
                end
                if isfield(Ld.DD,'events') && ~isempty(Ld.DD.events)
                    ev = Ld.DD.events; ev = ev(arrayfun(@(x) ~isExcluded(fo, x.file), ev));
                    for j = 1:numel(ev), ev(j).condition = getCond(condMap, kf(fo, ev(j).file)); ev(j).srcFolder = fo; end
                    if ~isempty(ev), allEv{end+1} = ev; end %#ok<AGROW>
                end
                if isfield(Ld.DD,'perSite') && ~isempty(Ld.DD.perSite)
                    ps = Ld.DD.perSite; ps = ps(arrayfun(@(x) ~isExcluded(fo, x.file), ps));
                    for j = 1:numel(ps), ps(j).condition = getCond(condMap, kf(fo, ps(j).file)); ps(j).srcFolder = fo; end
                    if ~isempty(ps), allPS{end+1} = ps; end %#ok<AGROW>
                end
            end
        catch
        end
    end
end

CSW      = catStructs(allSites);
DD.events = catStructs(allEv);
DD.perSite= catStructs(allPS);
if ~isempty(DD.events), DD.allDwell = [DD.events.dwell]'; end
DD.minPctInside = unique(allMinPct);            % scalar when the folders agree; a vector when not
end

% -------------------------------------------------------------------------
function c = getCond(m, key), if isKey(m,key), c = m(key); else, c = ''; end, if isempty(c), c = '(unassigned)'; end, end

function out = catStructs(parts)
% Concatenate a cell array of struct arrays into one, harmonising fields (missing -> []).
out = struct([]);
parts = parts(~cellfun(@isempty,parts));
if isempty(parts), return; end
fset = {}; for i=1:numel(parts), fset = union(fset, fieldnames(parts{i})); end
for i = 1:numel(parts)
    p = parts{i}; miss = setdiff(fset, fieldnames(p));
    for m = 1:numel(miss), [p.(miss{m})] = deal([]); end
    p = orderfields(p, fset);
    if isempty(out), out = p; else, out = [out, p]; end
end
end
