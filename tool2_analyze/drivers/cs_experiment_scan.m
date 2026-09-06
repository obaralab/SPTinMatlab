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
%   seg          struct with one field per CHANNEL KEY holding that channel's resolved path — the
%                keyed form, and the only one a project's third channel appears in. erSeg/mitoSeg
%                stay as the flat mirror the rest of the codebase still reads.
%   nTracks, status (struct from cs_experiment_status — stage LAMPS plus the per-stage spot and
%           track COUNTS: nSpotsRaw, nTracksRaw, nTracksFiltered, nTracksCurated, nTracksMetrics,
%           nTracksKept, nSpotsInTracks, nSpotsKept, nTracksBuilt, nSpotsBuilt, nCellsBuilt)
%   folder(=analysis), hasCSW, hasDwell                           (back-compat with the aggregator/UI)
%   pixUm, pixSrc, pixLock / dtS, dtSrc, dtLock                   this cell's OWN calibration
%           Cameras and frame rates differ BETWEEN CELLS in a real comparison, so calibration belongs
%           on the cell record, not on a panel. NaN means nothing could supply one — an honest
%           absence the caller falls back from, never 0 and never the reference rig's number.
%           *Src is spt_project_calib's label ('settings'|'movie'|'xml'|'derived'|'missing'), plus
%           'panel' for a value that only the panel could supply and 'edited' for a typed one.
%           *Lock marks a HAND-EDITED value. This function never sets it and never reads it: it
%           always reports what the filesystem currently says, and the panel — the one place that
%           knows what the user typed — is what carries a locked value across a rescan.
cells = emptyCells();
if isempty(folders), return; end
if ischar(folders) || isstring(folders), folders = cellstr(folders); end
here = fileparts(mfilename('fullpath')); t1 = fullfile(fileparts(fileparts(here)),'tool1_track');
if isfolder(t1), addpath(t1); end                      % spt_match lives in tool1_track

% Two folders can name the SAME project — Tool 1 adds the project root while Tools 2 and 3 used to
% add its analysis/ subfolder, and both resolve here to the same P.project. Scanning both then
% enumerated every cell twice, which is what showed up as duplicate rows in the manifest. Resolve
% first, then keep one entry per project.
seenProj = {};
for i = 1:numel(folders)
    P = resolvePaths(char(folders{i}));
    if any(strcmp(seenProj, P.project)), continue; end
    seenProj{end+1} = P.project; %#ok<AGROW>
    [bases, seg] = enumerateCells(P);                  % cell base names + a per-base seg/spt map
    for b = 1:numel(bases)
        base = bases{b};
        sp = ''; er = ''; mi = ''; sg = struct();
        if isKey(seg, base), s = seg(base); sp = s.spt; er = s.erSeg; mi = s.mitoSeg; sg = s.seg; end
        rec = struct('file',base,'day',P.day,'condition','','exclude',false,'reason','','notes','', ...
            'project',P.project,'analysis',P.analysis,'tracks',P.tracks,'spt',sp, ...
            'seg',sg,'erSeg',er,'mitoSeg',mi, ...
            'trackstruct',tsOrDefault_(P.analysis),'nTracks',0, ...
            'status',struct(),'folder',P.analysis,'hasCSW',false,'hasDwell',false, ...
            'pixUm',NaN,'pixSrc','missing','pixLock',false, ...
            'dtS',NaN,  'dtSrc','missing', 'dtLock',false);
        rec.status  = cs_experiment_status(rec);
        rec = readCalib_(rec, P, base);
        rec.hasCSW  = rec.status.mapped;
        rec.hasDwell= rec.status.dwelled;
        rec.nTracks = rec.status.nTracksBuilt;                 % already resolved (and cached) there
        if isnan(rec.nTracks), rec.nTracks = 0; end            % callers expect a number, not NaN
        cells(end+1) = rec; %#ok<AGROW>
    end
end
% Final guard: one record per (project, cell). The project-level skip above handles the common case,
% but two DIFFERENT projects that happen to share a cell base name are legitimate and must survive,
% so the key is the pair, not the file name alone.
if ~isempty(cells)
    key = strcat({cells.project}, '|', {cells.file});
    [~, keep] = unique(key, 'stable');
    cells = cells(keep);
end
end

% ------------------------------------------------------------------------------------------------
function P = resolvePaths(folder)
% Resolve an input folder (project root OR its analysis/) to the standard sub-paths.
% Normalize FIRST: a trailing separator or an unresolved symlink makes two spellings of one project
% compare unequal, and every dedup downstream keys on these strings.
folder = char(folder);
if numel(folder) > 1 && endsWith(folder, filesep), folder = folder(1:end-1); end
try, r = char(java.io.File(folder).getCanonicalPath()); if ~isempty(r), folder = r; end, catch, end
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
        % Channels come from the project's own config (built-in ER/mito default when it has none),
        % and the channel token is DERIVED from the file names rather than typed. It used to be the
        % literal '_VAPB', which silently enumerated nothing on any dataset named otherwise — the
        % user's live data uses '_C3'. spt_analyze_app was fixed for this; this was the last one.
        spec = cs_channel_segspec(cs_channel_config(P.project), P.project);
        % Prefer what Tool 1 RECORDED over re-deriving it. Deriving compares SPT names to
        % segmentation names, so it only works when one is a prefix of the other; a regex typed in
        % Tool 1 for unusual naming cannot be recovered that way at all. Fall back to deriving when
        % nothing was recorded (a folder from an older Tool 1) or when the record resolves nothing,
        % so a stale record cannot make this worse than it was.
        tok = ''; m = [];
        try
            [reRec, ~, srcRec] = spt_settings_match(P.tracks);
            if ~isempty(srcRec)
                mR = spt_match(P.spt, spec, reRec);
                if any(arrayfun(@(x) ~isempty(x.erSeg) || ~isempty(x.mitoSeg), mR)), m = mR; end
            end
        catch
        end
        if isempty(m)
            try tok = spt_channel_token(P.spt, spec); catch, end
            m = spt_match(P.spt, spec, tok);
        end
        for i = 1:numel(m)
            [~,b] = fileparts(m(i).spt); bases{end+1} = b; %#ok<AGROW>
            seg(b) = struct('spt',m(i).spt,'erSeg',m(i).erSeg,'mitoSeg',m(i).mitoSeg,'seg',m(i).seg);
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
% MUST list exactly the fields of the struct(...) literal above, in exactly that order — `cells(end+1)
% = rec` compares the two field-for-field and throws "dissimilar structures" on any disagreement.
c = struct('file',{},'day',{},'condition',{},'exclude',{},'reason',{},'notes',{}, ...
    'project',{},'analysis',{},'tracks',{},'spt',{},'seg',{},'erSeg',{},'mitoSeg',{},'trackstruct',{}, ...
    'nTracks',{},'status',{},'folder',{},'hasCSW',{},'hasDwell',{}, ...
    'pixUm',{},'pixSrc',{},'pixLock',{},'dtS',{},'dtSrc',{},'dtLock',{});
end

function rec = readCalib_(rec, P, base)
% This cell's own calibration, straight from spt_project_calib — its resolution order (Tool 1's
% _settings.txt, then the movie's metadata, then the tracks XML) and its refusal to guess are the
% contract, so nothing is re-derived here.
if exist('spt_project_calib','file') ~= 2, return; end       % defensive, like enumerateCells above
try
    % useManifest=false: this function FILLS the manifest, so reading it back would make an edit
    % its own evidence and no rescan could ever show what the files actually contain. The panel
    % re-applies the user's edit on top of the rescan (doScan's pixLock merge).
    cc = spt_project_calib(P.project, base, false);
    rec.pixUm = cc.pixUm; rec.pixSrc = cc.src.pixUm;
    rec.dtS   = cc.dt_s;  rec.dtSrc  = cc.src.dt_s;
catch
    return
end
% A value Tool 1 fell back to the PANEL for is still written into _settings.txt — it has to be, it is
% what produced the µm coordinates on disk — so the resolver legitimately reads it back and calls it
% 'settings'. The _src marker beside it is the only thing that distinguishes a measurement from a
% panel guess, and reading it belongs here rather than in the resolver: the manifest is where a
% person looks to see which cells are on their own scale and which are on the panel's.
try
    f = fullfile(rec.tracks, [base '_settings.txt']);
    if isfile(f)
        txt = fileread(f);
        if strcmp(rec.pixSrc,'settings') && srcIsPanel_(txt,'calibration.pixel_um_src'), rec.pixSrc = 'panel'; end
        if strcmp(rec.dtSrc,'settings')  && srcIsPanel_(txt,'calibration.frame_s_src'),  rec.dtSrc  = 'panel'; end
    end
catch
end
end

function tf = srcIsPanel_(txt, k)
t = regexp(txt, ['(?m)^\s*' regexptranslate('escape',k) '\s*=\s*(\S+)'], 'tokens','once');
tf = ~isempty(t) && strcmpi(strtrim(t{1}),'panel');
end
