function [perTrack, perCell] = cs_track_occupancy(Tracks, opts)
%CS_TRACK_OCCUPANCY  How much of each MOLECULE's trajectory is spent at the organelle.
%
%   [perTrack, perCell] = cs_track_occupancy(Tracks, opts)
%
% WHY PER TRACK. This is single-particle tracking: the unit of observation is a molecule, not a
% localization. Pooling every localization in a cell and taking the fraction inside the zone — which
% is what cs_mito_engage's `occupancy` field does — weights a 400-frame track 100x more than a
% 4-frame one, so a handful of long resident tracks can carry a cell's number on their own. Worse,
% it collapses the thing you most want to see: a bound population and a free population give a
% BIMODAL per-track distribution and a perfectly ordinary-looking pooled mean.
%
% Per track, occupancy is the fraction of that track's own localizations lying within dUm:
%
%       occ_j = (localizations of track j with dist <= dUm) / (localizations of track j)
%
% and the cell is summarised by the MEDIAN over its tracks (robust to a few residents) plus the
% ENGAGED FRACTION — the share of tracks with occ >= engFrac. That second number is the one that
% states a result in words: "38 % of molecules spend at least half their time at mitochondria".
%
% NOTE ON UNITS vs THE D RATIO. Occupancy counts localizations; the D ratio classifies STEPS by
% where they started. They answer different questions — present vs held — and occupancy needs no
% minimum step count, so it still reports on cells the ratio refuses. That is deliberate: a sparse
% cell is not a cell with no answer, it is a cell with a weaker one.
%
% INPUT
%   Tracks : a built TrackStruct array
%   opts   : .dUm      zone half-width, um. Default 0.1. SCALAR (per-track occupancy is for one d)
%            .key      reference channel, 'mito' (default) or 'er'
%            .minLoc   a track needs this many localizations to be scored; default 5. Below it the
%                      fraction is quantised to a handful of values (3 localizations can only give
%                      0, 1/3, 2/3 or 1) and is noise, not a measurement.
%            .engFrac  occupancy at or above which a track counts as ENGAGED; default 0.5
%
% OUTPUT
%   perTrack : struct array, one per SCORED track — .file .cellIndex .col .srcCol .nLoc .nIn
%              .occ .engaged
%   perCell  : struct array, one per cell in Tracks (never dropped, so indices line up with
%              cs_mito_engage) — .file .cellIndex .nTracks .nScored .occMedian .occMean
%              .engagedFrac .why ('' when scored, else why not)

if nargin < 2 || ~isstruct(opts), opts = struct(); end
dUm     = getf_(opts,'dUm', 0.1); dUm = dUm(1);
key     = getf_(opts,'key', 'mito');
minLoc  = max(2, round(getf_(opts,'minLoc', 5)));
engFrac = getf_(opts,'engFrac', 0.5);

perTrack = emptyTrack();
perCell  = repmat(emptyCell(), numel(Tracks), 1);

for k = 1:numel(Tracks)
    T = Tracks(k);
    rec = emptyCell(); rec.cellIndex = k;
    if isfield(T,'file'), rec.file = char(T.file); end
    if ~isfield(T,'matrix') || isempty(T.matrix)
        rec.why = 'no tracks in this cell'; perCell(k) = rec; continue;
    end
    M = T.matrix; [nF, nT, ~] = size(M);
    X = M(:,:,2); Y = M(:,:,3);
    rec.nTracks = nT;

    [dv, have] = cs_channel_dist(T, key, 'tracked');
    if ~have || numel(dv) ~= nF*nT
        rec.why = sprintf('no %s distance on this cell', key); perCell(k) = rec; continue;
    end
    Dm = reshape(dv, nF, nT);

    % ORIGINAL column identity, so a per-track row can be traced back to the build (and matched
    % against the curation list) even when this is a sliced subset.
    if isfield(T,'srcCols') && numel(T.srcCols) == nT, src = double(T.srcCols(:)'); else, src = 1:nT; end

    occ = [];
    for j = 1:nT
        rr = find(isfinite(X(:,j)) & isfinite(Y(:,j)) & isfinite(Dm(:,j)));
        if numel(rr) < minLoc, continue; end
        nIn = sum(Dm(rr,j) <= dUm);
        r = emptyTrack();
        r(1).file = rec.file; r(1).cellIndex = k; r(1).col = j; r(1).srcCol = src(j);
        r(1).nLoc = numel(rr); r(1).nIn = nIn; r(1).occ = nIn / numel(rr);
        r(1).engaged = r(1).occ >= engFrac;
        perTrack(end+1) = r; %#ok<AGROW>
        occ(end+1) = r(1).occ; %#ok<AGROW>
    end

    rec.nScored = numel(occ);
    if isempty(occ)
        rec.why = sprintf('no track has %d+ localizations with a distance', minLoc);
    else
        rec.occMedian   = median(occ);
        rec.occMean     = mean(occ);
        rec.engagedFrac = mean(occ >= engFrac);
    end
    perCell(k) = rec;
end
end

% =================================================================================================
function r = emptyTrack()
r = struct('file',{},'cellIndex',{},'col',{},'srcCol',{},'nLoc',{},'nIn',{},'occ',{},'engaged',{});
end

function r = emptyCell()
r = struct('file','','cellIndex',0,'nTracks',0,'nScored',0, ...
           'occMedian',NaN,'occMean',NaN,'engagedFrac',NaN,'why','');
end

function v = getf_(s, f, d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
