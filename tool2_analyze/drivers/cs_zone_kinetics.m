function [perCell, perTrack] = cs_zone_kinetics(Tracks, opts)
%CS_ZONE_KINETICS  How fast molecules bind to and leave the organelle interface.
%
%   [perCell, perTrack] = cs_zone_kinetics(Tracks, opts)
%
% THE ESTIMATOR, and why it is this one. Both rates are EVENTS DIVIDED BY EXPOSURE TIME:
%
%       k_off = (bound episodes seen to END) / (total time spent bound)
%       k_on  = (binding events seen to START) / (total time spent free)
%
% That form is the whole reason this can be kept simple AND defended. An episode that is still bound
% when its track stops — bleached, out of focus, or a linking failure — is RIGHT-CENSORED: we know it
% lasted at least that long and not how much longer. Divide events by exposure and such an episode
% contributes its time to the denominator and no event to the numerator, which is exactly correct.
% Averaging the durations you happen to observe instead treats every truncation as an unbinding and
% systematically OVERSTATES k_off — badly here, because tracks end on the same timescale as plausible
% binding (a median track is ~60 frames). This is also the maximum-likelihood estimate for a constant
% hazard with censoring, so the simple thing and the right thing coincide; Kaplan-Meier would let you
% TEST the constant-hazard assumption but is not needed to estimate the rate under it.
%
% Time is accumulated per STEP as tau = (frame span) x dt, and a step is credited to the class it
% STARTS in — the same convention cs_mito_engage uses for D_bound/D_free, so the kinetics and the
% diffusion contrast are describing the same partition of the data. Gap-closed steps therefore carry
% their true duration rather than one frame interval.
%
% WHAT IT ASSUMES. A single exponential — one population with one off-rate. If binding is
% heterogeneous (a fast-exchanging pool and a stable one), k_off is their exposure-weighted average
% and is not a property of either. perTrack is returned so that can be looked at rather than assumed
% away: a bimodal spread of per-track bound fractions is the signature.
%
% k_on is PSEUDO-first-order: events per second of free time, with no concentration term, so it is
% comparable between conditions on the same construct and is not a bimolecular rate constant.
%
% INPUT
%   Tracks : a built TrackStruct array
%   opts   : .dUm    zone half-width, um (signed: negative is inside the mask). Default 0.1
%            .key    reference channel, 'mito' (default) or 'er'
%            .dt     frame interval fallback for a cell that carries none; default 0.02
%            .minLoc a track needs this many localizations to contribute; default 5
%
% OUTPUT
%   perCell  : one per cell (never dropped) — .file .cellIndex .kOff .kOn .meanBound_s .meanFree_s
%              .nEnd .nCensored .nStart .tBound .tFree .nTracks .why
%   perTrack : one per contributing track — .file .cellIndex .col .srcCol .nEnd .nCensored .nStart
%              .tBound .tFree
%
% READ .nEnd AND .nCensored. A k_off from 3 completed episodes is not a rate, and a cell where most
% episodes are censored is telling you the tracks are too short for the binding it contains.

if nargin < 2 || ~isstruct(opts), opts = struct(); end
dUm    = getf_(opts,'dUm', 0.1); dUm = dUm(1);
key    = getf_(opts,'key', 'mito');
dtDef  = getf_(opts,'dt', 0.02);
minLoc = max(2, round(getf_(opts,'minLoc', 5)));

perCell  = repmat(emptyCell(), numel(Tracks), 1);
perTrack = emptyTrack();

for k = 1:numel(Tracks)
    T = Tracks(k);
    rec = emptyCell(); rec.cellIndex = k;
    if isfield(T,'file'), rec.file = char(T.file); end
    if ~isfield(T,'matrix') || isempty(T.matrix)
        rec.why = 'no tracks in this cell'; perCell(k) = rec; continue;
    end
    M = T.matrix; [nF, nT, ~] = size(M);
    X = M(:,:,2); Y = M(:,:,3); F = M(:,:,1);
    rec.nTracks = nT;
    dt = dtDef;
    if isfield(T,'frameInterval') && ~isempty(T.frameInterval) && T.frameInterval > 0, dt = T.frameInterval; end

    [dv, have] = cs_channel_dist(T, key, 'tracked');
    if ~have || numel(dv) ~= nF*nT
        rec.why = sprintf('no %s distance on this cell', key); perCell(k) = rec; continue;
    end
    Dm = reshape(dv, nF, nT);
    if isfield(T,'srcCols') && numel(T.srcCols) == nT, src = double(T.srcCols(:)'); else, src = 1:nT; end

    for j = 1:nT
        rr = find(isfinite(X(:,j)) & isfinite(Y(:,j)) & isfinite(Dm(:,j)));
        if numel(rr) < minLoc, continue; end
        z  = Dm(rr,j) <= dUm;                     % inside the zone, per localization
        fr = F(rr,j);
        if all(abs(fr - round(fr)) < 1e-6), tau = diff(round(fr)) * dt;   % frame indices
        else,                               tau = diff(fr); end           % already seconds
        a = z(1:end-1);                            % which class each STEP starts in

        tB = sum(tau(a));  tF = sum(tau(~a));
        % An episode ENDS when a bound localization is followed by a free one; a bound run that
        % reaches the last localization is CENSORED. A binding event is the reverse transition.
        nEnd  = sum( z(1:end-1) & ~z(2:end));
        nStart= sum(~z(1:end-1) &  z(2:end));
        nCens = double(z(end));                    % still bound when the track stopped

        r = emptyTrack();
        r(1).file = rec.file; r(1).cellIndex = k; r(1).col = j; r(1).srcCol = src(j);
        r(1).nEnd = nEnd; r(1).nCensored = nCens; r(1).nStart = nStart;
        r(1).tBound = tB; r(1).tFree = tF;
        perTrack(end+1) = r; %#ok<AGROW>

        rec.nEnd = rec.nEnd + nEnd; rec.nCensored = rec.nCensored + nCens;
        rec.nStart = rec.nStart + nStart;
        rec.tBound = rec.tBound + tB; rec.tFree = rec.tFree + tF;
    end

    if rec.tBound > 0
        rec.kOff = rec.nEnd / rec.tBound;
        if rec.kOff > 0, rec.meanBound_s = 1/rec.kOff; end
    end
    if rec.tFree > 0
        rec.kOn = rec.nStart / rec.tFree;
        if rec.kOn > 0, rec.meanFree_s = 1/rec.kOn; end
    end
    if ~(rec.tBound > 0), rec.why = 'no time spent in the zone'; end
    perCell(k) = rec;
end
end

% =================================================================================================
function r = emptyTrack()
r = struct('file',{},'cellIndex',{},'col',{},'srcCol',{}, ...
           'nEnd',{},'nCensored',{},'nStart',{},'tBound',{},'tFree',{});
end

function r = emptyCell()
r = struct('file','','cellIndex',0,'nTracks',0, ...
           'kOff',NaN,'kOn',NaN,'meanBound_s',NaN,'meanFree_s',NaN, ...
           'nEnd',0,'nCensored',0,'nStart',0,'tBound',0,'tFree',0,'why','');
end

function v = getf_(s, f, d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
