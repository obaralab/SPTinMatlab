function Tracks = TrackImporter_direct(inputDir, varargin)
% TRACKIMPORTER_DIRECT  Build the `Tracks` struct directly from TrackMate
% output — no Excel, no XML2XLSX, no hardcoded column letters.
%
% Replaces the chain:  _tracks_builtin.xml -> XML2XLSX.xlsm -> .xlsx
%                      -> TrackImporterCJO_2024v1.m (fixed columns K:M / J)
% with a single reader of the custom `_tracks.xml` (+ optional `_spots.csv`).
%
% USAGE
%   Tracks = TrackImporter_direct(inputDir)
%   Tracks = TrackImporter_direct(inputDir, 'Name', Value, ...)
%
% INPUT
%   inputDir : folder containing one or more of:
%                <base>_tracks.xml            (raw run, from trackmate_run.py)
%                <base>_tracks_filtered.xml   (curated, from track_viewer.m)
%                <base>_spots.csv / _spots_filtered.csv   (optional intensities)
%
% NAME-VALUE OPTIONS
%   'Pattern'    : glob for the XML to import. Default '*_tracks.xml'.
%                  Use '*_tracks_filtered.xml' to import curated tracks.
%   'TimeUnit'   : 'frame' (default) or 'seconds'.
%                    'frame'   -> matrix(:,:,1) = integer FRAME  (reproduces
%                                 the legacy struct exactly; MSD lag-binning
%                                 (DeltaT==j) requires integer frame time).
%                    'seconds' -> matrix(:,:,1) = T = FRAME*frameInterval.
%   'AttachCSV'  : true (default) — pair each XML with its *_spots.csv and
%                  store intensities in Tracks(i).intens (m x n x 3:
%                  MEAN/MAX/TOTAL). false — skip CSV.
%   'FileSuffix' : chars appended to the base name in Tracks(i).file so the
%                  downstream CS suite's filename(1:end-K) stripping lands on
%                  <base>. Default '' (store bare base). Set this to match your
%                  own naming convention if needed.
%   'Save'       : true (default) — save 'TrackStruct.mat' (-v7.3) in inputDir.
%   'Verbose'    : true (default).
%
% OUTPUT  Tracks : 1 x nFiles struct with fields matching the legacy importer:
%   file lengths matrix center rawSteps steps MSDdata MSD MSDstdev MSDerror
%   CSD CSDnorm rawVector vector   (+ intens if AttachCSV).
%
% All kinematic formulas follow the reference implementation, so the struct is numerically
% identical when fed equivalent tracks.

% -------- options --------
p = inputParser;
p.addParameter('Pattern',   '*_tracks.xml', @ischar);
p.addParameter('TimeUnit',  'frame',        @(s) any(strcmpi(s,{'frame','seconds'})));
p.addParameter('AttachCSV', true,           @islogical);
p.addParameter('FileSuffix','',             @ischar);
p.addParameter('Save',      true,           @islogical);
p.addParameter('Verbose',   true,           @islogical);
p.addParameter('IncludeFiles',{},            @iscell);   % only import these cell bases ({}=all)
p.addParameter('ProgressFcn',[]);            % @(i,nFiles,name) called before each cell imports
p.addParameter('Calib', struct());           % project-level calibration used where a cell has none
p.parse(varargin{:});
opt = p.Results;
useFrame = strcmpi(opt.TimeUnit,'frame');

% -------- find XML files --------
xmlFiles = dir(fullfile(inputDir, opt.Pattern));
% Guard: '*_tracks.xml' would also match '*_tracks_filtered.xml'? No — filtered
% ends in '_tracks_filtered.xml', which does not match '*_tracks.xml' glob.
if ~isempty(opt.IncludeFiles) && ~isempty(xmlFiles)   % session selection: import only these cell bases
    inc = opt.IncludeFiles; keep = false(1,numel(xmlFiles));
    for k = 1:numel(xmlFiles)
        b = regexprep(xmlFiles(k).name,'(_tracks_filtered|_tracks_curated|_tracks)\.xml$','');
        keep(k) = any(cellfun(@(x) ~isempty(x) && (strcmpi(x,b) || contains(b,x) || contains(x,b)), inc));
    end
    xmlFiles = xmlFiles(keep);
end
if isempty(xmlFiles)
    error('TrackImporter_direct:noXML', ...
        'No files matching "%s" in %s', opt.Pattern, inputDir);
end
nFiles = numel(xmlFiles);

Tracks = struct('file',{},'lengths',{},'matrix',{},'center',{}, ...
    'rawSteps',{},'steps',{},'MSDdata',{},'MSD',{},'MSDerror',{}, ...
    'MSDstdev',{},'CSD',{},'CSDnorm',{},'rawVector',{},'vector',{}, ...
    'intens',{},'allSpots',{},'dist',{});

for i = 1:nFiles
    xmlPath = fullfile(xmlFiles(i).folder, xmlFiles(i).name);
    [~, xmlBase] = fileparts(xmlFiles(i).name);
    % base name = strip the trailing '_tracks' / '_tracks_filtered' / '_tracks_curated', keeping the
    % variant so the spots CSV can be paired with the SAME stage of the pipeline (see below).
    base = regexprep(xmlBase, '_tracks(_filtered|_curated)?$', '');
    vtok = regexp(xmlBase, '_tracks(_filtered|_curated)?$', 'tokens', 'once');
    variant = ''; if ~isempty(vtok), variant = vtok{1}; end   % '' | '_filtered' | '_curated'
    if opt.Verbose
        fprintf('[%d/%d] %s\n', i, nFiles, xmlFiles(i).name);
    end
    if ~isempty(opt.ProgressFcn)
        try, opt.ProgressFcn(i, nFiles, xmlFiles(i).name); catch, end
    end

    % ---- parse the custom Tracks XML ----
    [trkCols, frameInt, spotIDs, trackIDs] = parse_tracks_xml(xmlPath, useFrame);
    % trkCols is a cell array {1 x nTracks}, each an [k x 3] matrix of
    % [time, x, y] rows already sorted by frame.
    n = numel(trkCols);
    if n == 0
        if opt.Verbose, fprintf('   (no tracks) skipped\n'); end
        continue
    end
    RealLengths = cellfun(@(c) size(c,1), trkCols);
    m = max(RealLengths);

    % ---- assemble matrix (m x n x 3), dim3 = (t,x,y); pad with NaN ----
    matrix = NaN(m, n, 3);
    for j = 1:n
        c = trkCols{j};
        matrix(1:size(c,1), j, :) = reshape(c, size(c,1), 1, 3);
    end

    % ==== kinematics — offset-loop MSD, O(m^2) time / O(m*n) memory ====
    % (The legacy version built three [m x n x m] scratch arrays and masked them
    %  per lag -> O(m^3) time and gigabytes for long tracks. This gives the SAME
    %  numbers by accumulating each pair's squared displacement into (lag,track)
    %  bins keyed by integer frame gap.)
    center = bsxfun(@minus, matrix, matrix(1,:,:));

    F = matrix(:,:,1); X = matrix(:,:,2); Y = matrix(:,:,3);   % [m x n] frame, x, y

    % single-step (lag-1) quantities for rawSteps / steps / CSD (keep MAGNITUDE)
    dT1 = F(2:m,:) - F(1:m-1,:);
    dS1 = sqrt((X(2:m,:)-X(1:m-1,:)).^2 + (Y(2:m,:)-Y(1:m-1,:)).^2);
    rawSteps = NaN(m-1, n, 2);
    rawSteps(:,:,1) = dT1;
    rawSteps(:,:,2) = dS1;
    steps = dS1 ./ dT1;                % per-FRAME speed (µm/frame) — a rate, not a distance
    % CSD = cumulative path length in µm: sum the ACTUAL step distances, not the frame-normalized
    % speeds. Summing dS1./dT1 charges a gap-closed step only its per-frame average, so a 2-frame
    % gap contributes half the distance the molecule actually covered — and the result is not even
    % in µm unless every dT is 1. Measured on the WithER cell (86.6% of tracks contain a 2-frame
    % gap): total path length was understated by a median of 2.0% and up to 11.5% per track.
    % Consumers read this as µm (spt_pipeline_app: "cumulative displacement (\mum)").
    CSD   = cumsum(dS1, 1);            % CSD(j,:) = path length through step j (NaN past track end)

    % data-integrity guard (the legacy "doubleLag" check): sorted frames must be
    % strictly increasing within a track, else a (start,lag) pair is ambiguous.
    if any(dT1(isfinite(dT1)) == 0)
        error('TrackImporter_direct:doubleLag', ...
            'A frame registered twice within a track in %s.', base);
    end

    % MSD = mean SQUARED displacement <r^2> (um^2). For each position offset o,
    % add every real pair's squared displacement to bin (frameGap, track).
    sumSD = zeros(m-1, n); sumSD2 = zeros(m-1, n); cntSD = zeros(m-1, n);
    for o = 1:m-1
        df  = F(1+o:m,:) - F(1:m-o,:);                              % [(m-o) x n] frame gap
        dsq = (X(1+o:m,:)-X(1:m-o,:)).^2 + (Y(1+o:m,:)-Y(1:m-o,:)).^2;
        % dsq>0 reproduces the legacy MSD exactly: the old code used
        % MSDcomplete==0 as its "no pair" sentinel, which also dropped the rare
        % EXACT-zero-displacement pair (e.g. a TrackMate gap-filled duplicate
        % position). Drop the same pairs so this stays a pure speed-up.
        % Bin by INTEGER FRAME lag regardless of TimeUnit: in 'seconds' mode the time gap is
        % frameGap*frameInt, so recover the integer frame gap — else df is non-integer and every
        % pair is dropped, silently producing an all-NaN MSD.
        lagF = df; if ~useFrame && frameInt>0, lagF = df./frameInt; end
        valid = isfinite(lagF) & isfinite(dsq) & lagF>=1 & lagF<=(m-1) & abs(lagF-round(lagF))<1e-6 & dsq>0;
        if ~any(valid(:)), continue; end
        lagF = round(lagF);
        [rr, cc] = find(valid);
        rr = rr(:); cc = cc(:);
        lin  = sub2ind(size(df), rr, cc);
        % df(lin)/dsq(lin) follow df's ROW orientation when df is a single row (offset o=m-1
        % with >=2 tracks at the max length), so force COLUMNS — else [lagv,cc] is 1xK vs Kx1
        % and accumarray errors. (rr/cc already columns above.)
        lagv = lagF(lin);  lagv = lagv(:);                        % integer FRAME lag per pair
        dv   = dsq(lin); dv   = dv(:);
        sumSD  = sumSD  + accumarray([lagv, cc], dv,    [m-1, n], @sum, 0);
        sumSD2 = sumSD2 + accumarray([lagv, cc], dv.^2, [m-1, n], @sum, 0);
        cntSD  = cntSD  + accumarray([lagv, cc], 1,     [m-1, n], @sum, 0);
    end

    MSD      = sumSD ./ cntSD;                     % [lag x track]; 0/0 -> NaN
    MSDvar   = sumSD2 ./ cntSD - MSD.^2;           % population variance (= std(...,1)^2)
    MSDvar(MSDvar < 0) = 0;                        % clamp tiny round-off negatives
    MSDstdev = sqrt(MSDvar);
    noPair   = (cntSD == 0);
    MSD(noPair) = NaN; MSDstdev(noPair) = NaN;
    % Standard error of THIS track's MSD at THIS lag = its own spread over its own pair count.
    % It was previously divided by sum(isfinite(MSD),2) — the number of TRACKS that happen to have
    % a finite MSD at that lag (2..838 here) — so a track with 374 pairs and a track with 1 pair
    % got the same divisor, and the error bars came out a median 4x too small (range 10x too small
    % to 3.7x too large). cntSD is the pair count that actually went into MSD(lag,track).
    MSDerror = MSDstdev ./ sqrt(cntSD);
    MSDerror(noPair) = NaN;
    MSDdata  = [];                                 % legacy 3-D array — unused (Part1 nulls it)

    % CSDnorm — normalize each track to its total cumulative step
    Totals = zeros(1,n);
    for j = 1:n
        L = RealLengths(j);
        if L >= 2
            Totals(j) = CSD(L-1, j);
        else
            Totals(j) = NaN;                     % length-1 track (shouldn't occur)
        end
    end
    CSDnorm = bsxfun(@rdivide, CSD, Totals);

    rawVector = NaN(m-1, n, 2);
    rawVector(:,:,1) = diff(matrix(:,:,2), 1, 1);
    rawVector(:,:,2) = diff(matrix(:,:,3), 1, 1);
    vector = bsxfun(@rdivide, rawVector, rawSteps(:,:,1));

    % ---- optional intensities + mito/ER distance + ALL detections from the spots CSV ----
    intens = []; allSpots = []; mitoDist = []; erDist = [];
    if opt.AttachCSV
        [intens, allSpots, mitoDist, erDist] = attach_intensities(inputDir, base, variant, trkCols, spotIDs, m, n, useFrame, frameInt);
    end

    % ---- padded-layout size guard ----
    % Every per-localization field is [nF x nT] with nF set by the SINGLE longest track, so one
    % outlier track inflates every column of this cell. Size is ~200*nF*nT bytes; at 23% occupancy
    % that is already 70 MB for 838 tracks, and a 5981-frame track would make one cell ~1 GB at 1.5%
    % occupancy. Warn before that lands silently in a hundreds-of-cells run. See docs/DATA_STRUCTURE.md.
    occ = sum(RealLengths) / max(m*n, 1);
    estMB = 200 * m * n / 1048576;
    if estMB > 250 || (occ < 0.10 && estMB > 60)
        warning('TrackImporter_direct:paddedSize', ...
            ['%s: padded layout is ~%.0f MB in memory at %.1f%% occupancy (nF=%d set by the longest ' ...
             'track, nT=%d). Hundreds of cells at this size will not fit in RAM — see ' ...
             'docs/DATA_STRUCTURE.md (per-cell files / CSR).'], base, estMB, 100*occ, m, n);
    end

    % ---- store ----
    k = numel(Tracks) + 1;
    Tracks(k).file     = [base opt.FileSuffix];
    Tracks(k).lengths  = RealLengths(:);
    Tracks(k).matrix   = matrix;
    Tracks(k).center   = center;
    Tracks(k).rawSteps = rawSteps;
    Tracks(k).steps    = steps;
    Tracks(k).MSDdata  = MSDdata;
    Tracks(k).MSD      = MSD;
    Tracks(k).MSDstdev = MSDstdev;
    Tracks(k).MSDerror = MSDerror;
    Tracks(k).CSD      = CSD;
    Tracks(k).CSDnorm  = CSDnorm;
    Tracks(k).rawVector= rawVector;
    Tracks(k).vector   = vector;
    Tracks(k).intens   = intens;
    Tracks(k).allSpots = allSpots;   % struct(FRAME,X,Y[,DIST.<key>]) of EVERY detection (tracked + untracked)
    % Per-spot distances, KEYED ONLY (step 4 of the reference-channel migration — see
    % cs_channel_fields). The flat mitoDist/erDist pair this used to write alongside is gone: no
    % file in the repo reads it any more, so it was pure duplication of the largest arrays in
    % the struct.
    %
    % Only a channel this cell actually HAS gets a key — an absent key is how a project carries
    % cells with different channel sets, which is the whole point of the move. The field itself is
    % set on every element (possibly to an empty struct) so the Tracks array stays concatenable
    % across cells.
    %
    % Builds made before this still LOAD: cs_channel_dist and cs_channel_has keep their fallback to
    % the flat names. Only writing stopped.
    Tracks(k).dist = struct();
    if ~isempty(mitoDist), Tracks(k).dist.mito = mitoDist; end
    if ~isempty(erDist),   Tracks(k).dist.er   = erDist;   end
    Tracks(k).trackIDs = trackIDs(:);   % TrackMate TRACK_ID per matrix column (NaN if the XML omits it)
    Tracks(k).frameInterval = frameInt; % seconds per frame from the XML root (1 if absent) — real-time clock
    % Per-CELL calibration. dt already came from this cell's own XML; pixel size and field of view
    % come from this cell's own image where the acquisition chain kept the TIFF resolution tags, and
    % otherwise from the project-level Calibration panel. Storing all four per cell is what lets one
    % project (or one comparison) hold acquisitions from DIFFERENT cameras and frame rates — the
    % downstream code reads Tracks(k).*, never a single global.
    Tracks(k).calib = cell_calib(xmlPath, opt.Calib, frameInt);

    if opt.Verbose
        fprintf('   %d tracks, max length %d, frameInterval=%g\n', n, m, frameInt);
    end
end

if opt.Save
    outPath = fullfile(inputDir, 'TrackStruct.mat');
    save(outPath, 'Tracks', '-v7.3');
    if opt.Verbose, fprintf('Saved %s (%d files)\n', outPath, numel(Tracks)); end
end
end % TrackImporter_direct


% =====================================================================
function [trkCols, frameInt, spotIDs, trackIDs] = parse_tracks_xml(xmlPath, useFrame)
% Parse the custom <Tracks><Track><Spot .../> XML into per-track [k x 3]
% matrices of [time, x, y], sorted by FRAME. time = FRAME (integer) if
% useFrame, else T (seconds). spotIDs{t} is the matching [k x 1] SPOT_ID
% column (NaN where a Spot has no SPOT_ID attribute), for the exact CSV join.
% trackIDs(t) is the TrackMate TRACK_ID of track t (NaN if absent), so the
% matrix columns can be traced back to the original TrackMate ids.
xdoc = xmlread(xmlPath);
root = xdoc.getDocumentElement();
frameInt = str2double(char(root.getAttribute('frameInterval')));
if isnan(frameInt) || frameInt == 0, frameInt = 1; end

tnodes = root.getElementsByTagName('Track');
nT = tnodes.getLength();
trkCols = cell(1, nT);
spotIDs = cell(1, nT);
trackIDs = nan(1, nT);
for ti = 0:nT-1
    tn  = tnodes.item(ti);
    trackIDs(ti+1) = str2double(char(tn.getAttribute('TRACK_ID')));   % NaN if absent
    sn  = tn.getElementsByTagName('Spot');
    ns  = sn.getLength();
    fr  = zeros(ns,1); T = zeros(ns,1); X = zeros(ns,1); Y = zeros(ns,1); ID = NaN(ns,1);
    for si = 0:ns-1
        s = sn.item(si);
        fr(si+1) = str2double(char(s.getAttribute('FRAME')));
        T(si+1)  = str2double(char(s.getAttribute('T')));
        X(si+1)  = str2double(char(s.getAttribute('X')));
        Y(si+1)  = str2double(char(s.getAttribute('Y')));
        ID(si+1) = str2double(char(s.getAttribute('SPOT_ID')));   % NaN if absent
    end
    [fr, order] = sort(fr);          % ensure frame order
    T = T(order); X = X(order); Y = Y(order); ID = ID(order);
    if useFrame, tcol = fr; else, tcol = T; end
    trkCols{ti+1} = [tcol, X, Y];
    spotIDs{ti+1} = ID;
end
end


% =====================================================================
function [intens, allSpots, mitoDist, erDist] = attach_intensities(inputDir, base, variant, trkCols, spotIDs, m, n, useFrame, frameInt)
% Attach MEAN/MAX/TOTAL intensity (and, when present, the signed mito distance
% MITO_DIST_UM and ER distance ER_DIST_UM) from <base>_spots.csv (or _filtered)
% to the tracked spots.
% Returns:
%   intens   [m x n x 3] (page 1/2/3 = MEAN/MAX/TOTAL) aligned 1:1 with matrix
%            rows, or [] if no CSV;
%   allSpots struct(FRAME,X,Y[,DIST.<key>]) of EVERY detection in the CSV
%            (tracked + untracked), for QC mislinkage context and contact-site analysis. The
%            per-channel distances live in the keyed DIST container; the caller files the tracked
%            matrices below under Tracks(k).dist.<key> for the same reason;
%   mitoDist [m x n] signed µm from each tracked spot to the nearest mito pixel
%            in its own frame (+ outside mito, - inside, ~0 on the boundary), or
%            [] when the CSV has no MITO_DIST_UM column (older exports / no mito);
%   erDist   [m x n] signed µm to the nearest ER pixel per tracked spot (same sign
%            convention), or [] when the CSV has no ER_DIST_UM column.
% The join is by SPOT_ID (exact) when both the XML and the CSV carry it; else it
% falls back to a rounded (X_um,Y_um) position match.
intens = []; allSpots = []; mitoDist = []; erDist = [];
% Pair the CSV with the XML variant actually being imported — <base>_spots<variant>.csv first, then
% the other variants as a fallback. '_spots_curated.csv' (Tool 2's export) was not in the list at
% all, so importing '*_tracks_curated.xml' silently paired it with Tool 1's '_spots_filtered.csv'.
% Benign where both exist (each preserves the whole cloud under the same SPOT_IDs, so the join gives
% identical intensities and distances), but a curate-only folder holding just the curated pair got no
% localization data at all: no intensities, no MITO_DIST_UM, no ER_DIST_UM, and an empty allSpots.
cand = {};
if ~isempty(variant), cand{end+1} = fullfile(inputDir,[base '_spots' variant '.csv']); end
for v = {'', '_filtered', '_curated'}
    p = fullfile(inputDir,[base '_spots' v{1} '.csv']);
    if ~any(strcmp(cand, p)), cand{end+1} = p; end %#ok<AGROW>
end
csvPath = '';
for c = 1:numel(cand)
    if exist(cand{c},'file'), csvPath = cand{c}; break; end
end
if isempty(csvPath), return; end
S = readtable(csvPath, 'TextType','string');
hasMD = ismember('MITO_DIST_UM', S.Properties.VariableNames);
if hasMD, MD = double(S.MITO_DIST_UM); end                    % NaN where the cell blanked it
hasED = ismember('ER_DIST_UM', S.Properties.VariableNames);
if hasED, ED = double(S.ER_DIST_UM); end                      % NaN where blank / no ER seg
% every detection (frame + position [+ mito distance]) for QC context — untracked
% spots included. Store FRAME in the SAME units as matrix(:,:,1) (frame index, or
% seconds when TimeUnit='seconds') so the QC 'other spots this frame' match is exact.
if all(ismember({'FRAME','X_um','Y_um'}, S.Properties.VariableNames))
    frameVals = double(S.FRAME);
    if ~useFrame, frameVals = frameVals * frameInt; end   % -> seconds, matching matrix(:,:,1)
    allSpots = struct('FRAME',frameVals,'X',double(S.X_um),'Y',double(S.Y_um));
    % Keyed only — the flat MITODIST/ERDIST pair was dropped in step 4. See cs_channel_fields.
    if hasMD, allSpots.DIST.mito = MD; end
    if hasED, allSpots.DIST.er   = ED; end
end
needI = {'MEAN_INTENSITY','MAX_INTENSITY','TOTAL_INTENSITY'};
if ~all(ismember(needI, S.Properties.VariableNames)), return; end
INT = [double(S.MEAN_INTENSITY), double(S.MAX_INTENSITY), double(S.TOTAL_INTENSITY)];

haveXmlIDs = ~all(cellfun(@(v) all(~isfinite(v)), spotIDs));   % any real SPOT_ID in the XML
useID = haveXmlIDs && ismember('SPOT_ID', S.Properties.VariableNames);

intens = NaN(m, n, 3);
if hasMD, mitoDist = NaN(m, n); end
if hasED, erDist = NaN(m, n); end
if useID
    % ---- exact join by SPOT_ID (integer id present in both XML and CSV) ----
    sid = double(S.SPOT_ID);
    map = containers.Map('KeyType','double','ValueType','double');   % id -> CSV row
    for r = 1:height(S), if isfinite(sid(r)), map(sid(r)) = r; end, end
    for j = 1:n
        ids = spotIDs{j};
        for r = 1:numel(ids)
            if isfinite(ids(r)) && isKey(map, ids(r))
                intens(r, j, :) = reshape(INT(map(ids(r)), :), 1, 1, 3);
                if hasMD, mitoDist(r, j) = MD(map(ids(r))); end
                if hasED, erDist(r, j) = ED(map(ids(r))); end
            end
        end
    end
else
    % ---- fallback: match by rounded (X_um,Y_um) ----
    if ~all(ismember({'X_um','Y_um'}, S.Properties.VariableNames)), intens = []; mitoDist = []; erDist = []; return; end
    key = @(x,y) sprintf('%.6f_%.6f', x, y);
    map = containers.Map('KeyType','char','ValueType','double');
    for r = 1:height(S), map(key(double(S.X_um(r)), double(S.Y_um(r)))) = r; end
    for j = 1:n
        c = trkCols{j};
        for r = 1:size(c,1)
            kk = key(c(r,2), c(r,3));   % x=col2, y=col3
            if isKey(map, kk)
                intens(r, j, :) = reshape(INT(map(kk), :), 1, 1, 3);
                if hasMD, mitoDist(r, j) = MD(map(kk)); end
                if hasED, erDist(r, j) = ED(map(kk)); end
            end
        end
    end
end
end

function c = cell_calib(xmlPath, proj, frameInt)
%CELL_CALIB  This cell's own calibration, with the project panel as the fallback.
%
% Resolution order, most specific first:
%   1. the cell's own image metadata (TIFF resolution tags next to its XML)
%   2. the project-level Calibration panel ('Calib' option)
%   3. the historical defaults, so an old project imports exactly as it always did
%
% .src records which one won per field, so the app can SAY whether a cell was measured or inherited
% rather than presenting an inherited value as if it had been read off the file.

DEF = struct('pixSizeUm',0.10785,'fovUm',27.61,'precNm',30);
c = struct('pixSizeUm',NaN,'fovUm',NaN,'dt_s',frameInt,'precNm',NaN,'binNm',NaN, ...
           'src',struct('pixSizeUm','default','fovUm','default','dt_s','xml','precNm','default','binNm','default'));
if ~(isscalar(frameInt) && isfinite(frameInt) && frameInt > 0)
    c.dt_s = pick(proj,'dt_s',0.020064); c.src.dt_s = 'project';
end

% 1. the cell's own image, where the acquisition chain kept the tags
meta = struct('pixSizeUm',NaN,'fovUm',NaN);
try
    tif = sibling_image(xmlPath);
    if ~isempty(tif), meta = read_calibration('Image', tif); end
catch
end

[c.pixSizeUm, c.src.pixSizeUm] = resolve(getfd(meta,'pixSizeUm'), pick(proj,'pixSizeUm',NaN), DEF.pixSizeUm);
[c.fovUm,     c.src.fovUm]     = resolve(getfd(meta,'fovUm'),     pick(proj,'fovUm',NaN),     DEF.fovUm);
% Localization precision is never in file metadata — it is a property of the fit, not the camera
% geometry — so it can only come from the panel (or the default).
[c.precNm,    c.src.precNm]    = resolve(NaN,                     pick(proj,'binNm',NaN),     DEF.precNm);

% The DENSITY BIN is a separate number from the localization precision, even though one field used to
% serve both. Precision is a property of the data — a coarser camera pixel localizes worse, and D's
% noise floor must use that cell's real value. The bin size is an ANALYSIS choice, and the detector
% smooths by a fixed number of BINS, so the physical scale it looks for is 8*(FOV/grid) microns.
% Two datasets only measure the same object when the bin size matches, whatever their precisions are.
% Defaulting binNm to precNm keeps every existing project bit-identical.
% 'densBinNm' is the explicit project-level bin; 'binNm' is what the panel has always sent and is
% the LOCALIZATION PRECISION, already consumed above. Reading only densBinNm meant the bin could
% never be set at import — it always silently fell back to the precision, which is the right DEFAULT
% but left no way to state a different one.
[c.binNm, c.src.binNm] = resolve(NaN, pick(proj,'densBinNm',NaN), c.precNm);
end

function t = sibling_image(xmlPath)
% The cell's raw image, if it sits beside its XML under any of the usual names.
t = '';
[d, b] = fileparts(xmlPath);
base = regexprep(b, '_tracks(_filtered|_curated)?$', '');
% <project>/spt/ FIRST: the XML lives in <project>/tracks/, so the movie is a SIBLING folder away,
% and that is the layout every project in this pipeline uses. Omitting it meant the per-cell stamp
% never found the movie and silently fell back to the project panel — which is exactly how a cell
% recorded at 0.16 um/px ended up stamped with the panel's 0.10785.
roots = {fullfile(d,'..','spt'), d, fullfile(d,'..'), fullfile(d,'..','raw'), fullfile(d,'..','images')};
for i = 1:numel(roots)
    if ~isfolder(roots{i}), continue; end
    for ext = {'.tif','.tiff','.ome.tif'}
        f = fullfile(roots{i}, [base ext{1}]);
        if isfile(f), t = f; return; end
    end
end
end

function [v, src] = resolve(fromImage, fromProject, fallback)
if isfinite(fromImage) && fromImage > 0
    v = fromImage;   src = 'image';
elseif isfinite(fromProject) && fromProject > 0
    v = fromProject; src = 'project';
else
    v = fallback;    src = 'default';
end
end

function v = pick(s, f, d)
v = d; if isstruct(s) && isfield(s,f) && isscalar(s.(f)) && isfinite(s.(f)) && s.(f) > 0, v = s.(f); end
end
function v = getfd(s, f)
v = NaN; if isstruct(s) && isfield(s,f) && isscalar(s.(f)), v = s.(f); end
end
