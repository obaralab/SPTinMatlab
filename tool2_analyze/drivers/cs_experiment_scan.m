function cells = cs_experiment_scan(folders)
%CS_EXPERIMENT_SCAN  Rich per-cell records across project/analysis folders (for the experiment manifest).
%
%   cells = cs_experiment_scan(folders)   folders: a char path or cellstr of PROJECT folders (with
%   spt/ er_seg/ mito_seg/ tracks/ analysis/) OR analysis/ folders (with TrackStruct.mat).
%
% Each input folder is one "day/batch". Cells are enumerated from the raw movies (spt_match, so it
% works even BEFORE tracking) and/or from a built TrackStruct.mat, then enriched with paths,
% provenance and a per-stage status derived from the filesystem (cs_experiment_status).
%
% cells(k) fields:
%   file, day, condition('') , exclude(false), reason(''), notes('')
%   project, analysis, tracks, spt, erSeg, mitoSeg, trackstruct   (resolved paths)
%   nTracks, status (struct from cs_experiment_status — stage LAMPS plus the per-stage spot and
%           track COUNTS: nSpotsRaw, nTracksRaw, nTracksFiltered, nTracksCurated, nTracksMetrics,
%           nTracksKept, nSpotsInTracks, nSpotsKept, nTracksBuilt, nSpotsBuilt, nCellsBuilt)
%   folder(=analysis), hasCSW, hasDwell                           (back-compat with the aggregator/UI)
cells = emptyCells();
if isempty(folders), return; end
if ischar(folders) || isstring(folders), folders = cellstr(folders); end
here = fileparts(mfilename('fullpath')); t1 = fullfile(fileparts(fileparts(here)),'tool1_track');
if isfolder(t1), addpath(t1); end                      % spt_match lives in tool1_track

for i = 1:numel(folders)
    P = resolvePaths(char(folders{i}));
    [bases, seg] = enumerateCells(P);                  % cell base names + a per-base seg/spt map
    for b = 1:numel(bases)
        base = bases{b};
        sp = ''; er = ''; mi = '';
        if isKey(seg, base), s = seg(base); sp = s.spt; er = s.erSeg; mi = s.mitoSeg; end
        rec = struct('file',base,'day',P.day,'condition','','exclude',false,'reason','','notes','', ...
            'project',P.project,'analysis',P.analysis,'tracks',P.tracks,'spt',sp,'erSeg',er,'mitoSeg',mi, ...
            'trackstruct',tsOrDefault_(P.analysis),'nTracks',0, ...
            'status',struct(),'folder',P.analysis,'hasCSW',false,'hasDwell',false);
        rec.status  = cs_experiment_status(rec);
        rec.hasCSW  = rec.status.mapped;
        rec.hasDwell= rec.status.dwelled;
        rec.nTracks = rec.status.nTracksBuilt;                 % already resolved (and cached) there
        if isnan(rec.nTracks), rec.nTracks = 0; end            % callers expect a number, not NaN
        cells(end+1) = rec; %#ok<AGROW>
    end
end
end

% ------------------------------------------------------------------------------------------------
function P = resolvePaths(folder)
% Resolve an input folder (project root OR its analysis/) to the standard sub-paths.
if ~isempty(cs_active_trackstruct(folder)) && ~isfolder(fullfile(folder,'analysis'))
    ana = folder; proj = fileparts(folder);                 % given an analysis/ folder
else
    proj = folder; ana = fullfile(folder,'analysis');       % given a project root
end
tracks = fullfile(proj,'tracks'); if ~isfolder(tracks), tracks = proj; end
[~,day] = fileparts(proj); if isempty(day), day = proj; end
P = struct('project',proj,'analysis',ana,'tracks',tracks, ...
    'spt',fullfile(proj,'spt'),'erSeg',fullfile(proj,'er_seg'),'mitoSeg',fullfile(proj,'mito_seg'),'day',day);
end

function [bases, seg] = enumerateCells(P)
% Cell base names from raw movies (spt_match — pre-tracking friendly) unioned with a built TrackStruct.
bases = {}; seg = containers.Map('KeyType','char','ValueType','any');
if isfolder(P.spt) && exist('spt_match','file')==2
    try
        m = spt_match(P.spt, P.erSeg, P.mitoSeg, '_VAPB');
        for i = 1:numel(m)
            [~,b] = fileparts(m(i).spt); bases{end+1} = b; %#ok<AGROW>
            seg(b) = struct('spt',m(i).spt,'erSeg',m(i).erSeg,'mitoSeg',m(i).mitoSeg);
        end
    catch
    end
end
ts = cs_active_trackstruct(P.analysis);        % the ACTIVE build, which may be named (Day1_WT.mat)
if ~isempty(ts) && isfile(ts)
    % Go through cs_experiment_status's cached reader, not a fresh load(): the per-cell status calls
    % below need the same build, so this way the .mat is read once per scan instead of once per cell.
    info = cs_experiment_status('build', ts);
    for c = 1:numel(info.bases), bases{end+1} = info.bases{c}; end %#ok<AGROW>
end
bases = unique(bases,'stable');
end

function p = tsOrDefault_(anaDir)
% Path of the folder's ACTIVE build; the conventional default when it has none yet, so the record
% still names where a build WOULD go.
p = cs_active_trackstruct(anaDir);
if isempty(p), p = fullfile(anaDir,'TrackStruct.mat'); end
end

function c = emptyCells()
c = struct('file',{},'day',{},'condition',{},'exclude',{},'reason',{},'notes',{}, ...
    'project',{},'analysis',{},'tracks',{},'spt',{},'erSeg',{},'mitoSeg',{},'trackstruct',{}, ...
    'nTracks',{},'status',{},'folder',{},'hasCSW',{},'hasDwell',{});
end
