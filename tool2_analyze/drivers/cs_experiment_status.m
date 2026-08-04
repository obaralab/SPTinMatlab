function st = cs_experiment_status(rec, tsPath)
%CS_EXPERIMENT_STATUS  Per-cell processing status + stage counts, derived from the filesystem.
%
%   st   = cs_experiment_status(rec)   rec: a cell record (from cs_experiment_scan) with .file,
%   .analysis, and optionally .tracks (the tracks folder).
%
%   info = cs_experiment_status('build', tsPath)   the cached TrackStruct reader used below, exposed
%   so cs_experiment_scan can enumerate a build's cells without loading the same .mat a second time.
%   info: .nCells .bases{} .nTracks[] .nSpots[] (parallel to .bases), all NaN/empty on failure.
%
% st carries the pipeline-stage LOGICALS (unchanged — everything reading them keeps working):
%   .tracked  a <base>_tracks(_filtered).xml exists in the tracks folder
%   .curated  a <base>_tracks_curated.xml exists
%   .built    the folder has a TrackStruct build — the ACTIVE one, which may be a named build
%             such as Day1_WT.mat, resolved by cs_active_trackstruct   (folder-level)
%   .picked   analysis/csIDs/<base>_CSsites.txt exists
%   .mapped   analysis/CSW_final.mat exists                          (folder-level)
%   .dwelled  analysis/cs_window_dwell.mat exists                    (folder-level)
%
% ...plus how MUCH survives each stage (NaN where the source file is absent). A lamp answers "did
% this run?"; these answer "on how many spots and tracks?" — the number that decides whether a cell
% is worth analysing at all:
%   .nSpotsRaw       detections found by Tool 1                       (result.n_spots)
%   .nTracksRaw      tracks linked by Tool 1                          (_tracks.xml, else result.n_tracks)
%   .nTracksFiltered tracks left after Tool 1's length/displacement filter
%                                                                     (_tracks_filtered.xml, else curation.tracks_after)
%   .nTracksCurated  tracks left after Tool 2's curation              (_tracks_curated.xml, else KEEP in _track_metrics.csv)
%   .nTracksMetrics  rows in <base>_track_metrics.csv — the pool curation chose FROM
%   .nTracksKept     rows with KEEP=1 in that file
%   .nSpotsInTracks  detections belonging to those pooled tracks      (sum of n_spots, else
%                    filter.n_spots_in_kept_tracks from _settings.txt)
%   .nSpotsKept      detections belonging to the KEPT tracks          (sum of n_spots over KEEP=1)
%   .nTracksBuilt    this cell's tracks in the ACTIVE build           (size(Tracks(k).matrix,2))
%   .nSpotsBuilt     this cell's localisations in that build          (sum of Tracks(k).lengths)
%   .nCellsBuilt     cells in the ACTIVE build                        (numel(Tracks))  (folder-level)
%
% EVERY count comes from a cheap source. The 20 MB *_spots.csv files are never row-counted: the raw
% numbers are read from the small _settings.txt, track totals from the first 2 KB of each tracks XML
% (the <Tracks nTracks="…"> attribute — no XML parse), kept-vs-total from the ~100 KB
% _track_metrics.csv, and the build is loaded at most once per file version thanks to an
% mtime-and-size-keyed cache.

% --- exposed cached build reader: cs_experiment_status('build', tsPath) ---
if nargin >= 2 && (ischar(rec) || isstring(rec)) && strcmpi(char(rec),'build')
    st = builtInfo_(char(tsPath)); return
end

st = struct('tracked',false,'curated',false,'built',false,'picked',false,'mapped',false,'dwelled',false, ...
    'nSpotsRaw',NaN,'nTracksRaw',NaN,'nTracksFiltered',NaN,'nTracksCurated',NaN, ...
    'nTracksMetrics',NaN,'nTracksKept',NaN,'nSpotsInTracks',NaN,'nSpotsKept',NaN, ...
    'nTracksBuilt',NaN,'nSpotsBuilt',NaN,'nCellsBuilt',NaN);
base = ''; if isfield(rec,'file'), base = char(rec.file); end
ana  = ''; if isfield(rec,'analysis'), ana = char(rec.analysis); end
tr   = ''; if isfield(rec,'tracks'),   tr  = char(rec.tracks);   end

if ~isempty(tr) && isfolder(tr) && ~isempty(base)
    fXml  = fullfile(tr,[base '_tracks.xml']);
    fFilt = fullfile(tr,[base '_tracks_filtered.xml']);
    fCur  = fullfile(tr,[base '_tracks_curated.xml']);
    st.tracked = isfile(fFilt) || isfile(fXml);
    st.curated = isfile(fCur);

    % 1. _settings.txt (<1 KB) — the run's own record of what it produced, and of Tool 1's filter.
    fSet = fullfile(tr,[base '_settings.txt']); setTxt = '';
    if isfile(fSet)
        try
            setTxt = fileread(fSet); txt = setTxt;
            st.nSpotsRaw       = settingsVal_(txt,'result.n_spots');
            st.nTracksRaw      = settingsVal_(txt,'result.n_tracks');
            st.nTracksFiltered = filterVal_(txt,'tracks_after');
            if isnan(st.nTracksRaw), st.nTracksRaw = filterVal_(txt,'tracks_before'); end
        catch
        end
    end

    % 2. the XML headers — authoritative for track totals (the file that actually exists), and the
    %    only source when a cell was tracked by something that wrote no _settings.txt.
    n = xmlNTracks_(fXml);  if ~isnan(n), st.nTracksRaw      = n; end
    n = xmlNTracks_(fFilt); if ~isnan(n), st.nTracksFiltered = n; end
    n = xmlNTracks_(fCur);  if ~isnan(n), st.nTracksCurated  = n; end

    % 3. _track_metrics.csv (~100 KB, one row per track) — kept-vs-total, and the spot counts behind
    %    them. This is the only place the SPOT total of the surviving tracks is cheaply available.
    m = metricsCounts_(fullfile(tr,[base '_track_metrics.csv']));
    st.nTracksMetrics = m.nTracks; st.nTracksKept   = m.nKept;
    st.nSpotsInTracks = m.nSpots;  st.nSpotsKept    = m.nSpotsKept;
    if isnan(st.nTracksCurated) && st.curated, st.nTracksCurated = m.nKept; end
    % Cheaper fallback when there is no _track_metrics.csv: Tool 1 stamps the detections belonging to
    % the tracks ITS filter kept, which is the same quantity as nSpotsInTracks (the pool curation
    % then chose from). Only usable since that key exists — the old `n_spots_kept` key carried
    % every WRITTEN detection, i.e. the raw count, so reading it here would have been wrong.
    if isnan(st.nSpotsInTracks) && ~isempty(setTxt)
        st.nSpotsInTracks = filterVal_(setTxt,'n_spots_in_kept_tracks');
    end
end

if ~isempty(ana)
    ts         = cs_active_trackstruct(ana);   % any build, incl. a NAMED one (Day1_WT.mat)
    st.built   = ~isempty(ts);
    st.picked  = ~isempty(base) && isfile(fullfile(ana,'csIDs',[base '_CSsites.txt']));
    st.mapped  = isfile(fullfile(ana,'CSW_final.mat'));
    st.dwelled = isfile(fullfile(ana,'cs_window_dwell.mat'));
    if st.built
        info = builtInfo_(ts);
        st.nCellsBuilt = info.nCells;
        k = find(strcmp(info.bases, base), 1);
        if ~isempty(k), st.nTracksBuilt = info.nTracks(k); st.nSpotsBuilt = info.nSpots(k); end
    end
end
end

% ------------------------------------------------------------------------------------------------
function v = filterVal_(txt, name)
% A key from Tool 1's length/displacement-filter block. That block used to be called 'curation.*',
% which was wrong — Tool 1 only filters, curation is Tool 2's job — so it is written as 'filter.*'
% now. Projects tracked before the rename still carry the old spelling and must keep reading, so
% both are tried, new first.
v = settingsVal_(txt, ['filter.' name]);
if isnan(v), v = settingsVal_(txt, ['curation.' name]); end
end

function v = settingsVal_(txt, key)
% One numeric value out of _settings.txt ('result.n_spots          = 220401'). NaN when absent.
v = NaN;
t = regexp(txt, ['(?m)^\s*' regexptranslate('escape',key) '\s*=\s*(-?[\d.]+(?:[eE][-+]?\d+)?)'], 'tokens','once');
if ~isempty(t), v = str2double(t{1}); end
end

function n = xmlNTracks_(f)
% Track count from a tracks XML, WITHOUT parsing it: the root element carries nTracks="…", so only
% the first couple of KB are ever read (these files run to 18 MB).
n = NaN;
if ~isfile(f), return; end
fid = fopen(f,'r'); if fid < 0, return; end
c = onCleanup(@() fclose(fid)); %#ok<NASGU>
try
    head = fread(fid, 2048, '*char')';
    t = regexp(head, '<Tracks\b[^>]*\bnTracks\s*=\s*"(\d+)"', 'tokens','once');
    if ~isempty(t), n = str2double(t{1}); end
catch
end
end

function m = metricsCounts_(f)
% Track/spot totals and kept-counts from <base>_track_metrics.csv (one row per track, columns
% n_spots and KEEP). ~100 KB, so a plain read+textscan is a few milliseconds — no need to cache.
m = struct('nTracks',NaN,'nKept',NaN,'nSpots',NaN,'nSpotsKept',NaN);
if ~isfile(f), return; end
try
    txt = fileread(f);
    nl = find(txt == newline, 1);
    if isempty(nl), return; end
    hdr = strsplit(strtrim(txt(1:nl-1)), ',');
    C = textscan(txt(nl+1:end), repmat('%f',1,numel(hdr)), 'Delimiter',',', 'EmptyValue',NaN, ...
        'CollectOutput',true, 'EndOfLine','\n');
    M = C{1};
    if isempty(M), m.nTracks = 0; return; end
    m.nTracks = size(M,1);
    iN = find(strcmpi(hdr,'n_spots'), 1);
    iK = find(strcmpi(hdr,'KEEP'), 1);
    if ~isempty(iN) && iN <= size(M,2), m.nSpots = sum(M(:,iN), 'omitnan'); end
    if ~isempty(iK) && iK <= size(M,2)
        keep = M(:,iK) > 0;
        m.nKept = nnz(keep);
        if ~isempty(iN) && iN <= size(M,2), m.nSpotsKept = sum(M(keep,iN), 'omitnan'); end
    end
catch
end
end

function info = builtInfo_(tsPath)
% Per-cell track/spot counts from a TrackStruct build, CACHED by file identity (path + mtime + size)
% so a scan across many cells of one folder loads the .mat once, and a rescan not at all unless the
% build was rewritten. Loading is the one non-trivial cost in this file (~0.1 s / 12 MB build), which
% is exactly why it is behind the cache.
persistent KEYS VALS
if isempty(KEYS), KEYS = {}; VALS = {}; end
info = struct('nCells',NaN,'bases',[],'nTracks',[],'nSpots',[]);
info.bases = {};
if isempty(tsPath) || ~isfile(tsPath), return; end
d = dir(tsPath); if isempty(d), return; end
key = sprintf('%s|%.6f|%d', tsPath, d.datenum, d.bytes);
% mtime resolution is coarse (~1 s), so a build rewritten moments after the one we cached could
% carry an identical key. Treat anything written in the last few seconds as volatile: read it fresh
% and do not cache it. That is exactly the rescan right after a Build, where correctness matters and
% one 0.1 s load costs nothing; every later scan hits the cache.
volatile = (now - d.datenum)*86400 < 3;   %#ok<TNOW1>  (datenum arithmetic — dir gives datenum)
h = find(strcmp(KEYS, key), 1);
if ~isempty(h) && ~volatile, info = VALS{h}; return; end
try
    S = load(tsPath); fn = fieldnames(S);
    if isempty(fn), return; end
    Tr = S.(fn{1});
    info.nCells = numel(Tr);
    info.bases  = cell(1,numel(Tr));
    info.nTracks = nan(1,numel(Tr)); info.nSpots = nan(1,numel(Tr));
    for c = 1:numel(Tr)
        info.bases{c} = regexprep(char(Tr(c).file),'\.[^.]*$','');   % drop any extension
        if isfield(Tr,'matrix') && ~isempty(Tr(c).matrix), info.nTracks(c) = size(Tr(c).matrix,2); end
        if isfield(Tr,'lengths') && ~isempty(Tr(c).lengths), info.nSpots(c) = sum(Tr(c).lengths(:)); end
    end
catch
    return
end
if volatile, return; end
KEYS{end+1} = key; VALS{end+1} = info;
if numel(KEYS) > 8, KEYS = KEYS(end-7:end); VALS = VALS(end-7:end); end   % bounded
end
