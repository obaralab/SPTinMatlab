function E = cs_mito_engage(Tracks, opts)
%CS_MITO_ENGAGE  Per-cell diffusion contrast at the organelle interface: are molecules SLOWED where
%they meet the organelle, and does a compound abolish that?
%
%   E = cs_mito_engage(Tracks)
%   E = cs_mito_engage(Tracks, opts)
%
% WHAT IT MEASURES. Each step of each track is labelled by WHERE IT STARTED: BOUND if that
% localization lies within dUm of the organelle, FREE otherwise. D is then estimated separately from
% the two populations, and the headline is the RATIO
%
%       Dratio = D_bound / D_free
%
% A tethered molecule is slowed at the interface, so Dratio < 1. A compound that abolishes tethering
% pushes it toward 1. A cell where nothing engages sits at 1 to begin with.
%
% WHY A RATIO, AND WHY PER CELL. The ratio is measured WITHIN each cell, so it cannot be moved by
% labelling density, expression level, or how much organelle a cell happens to contain — the three
% things most likely to differ between wells for reasons that are not the compound. An absolute
% occupancy count is at the mercy of all three. That matters especially when the compound itself may
% change organelle morphology: mass and shape cancel out of a within-cell ratio and do not cancel
% out of a count.
%
% WHY STEPS AND NOT T.Dt. T.Dt is a rolling estimate over ~7 LOCALIZATIONS, so its value at a
% localization near the boundary is built from steps on both sides of it — precisely the mixing this
% metric exists to resolve. Classifying whole steps and pooling them keeps the two populations
% separate. The estimator itself is the one spt_track_diffusion uses in its default mode:
%
%       D = ( sum(r^2) - 4*sigma^2*nSteps ) / ( 4 * sum(tau) ),    tau = (frame span) * dt
%
% pooled over steps rather than averaged per step, so each step contributes in proportion to the
% time it observed. GAP-CLOSED STEPS ARE HANDLED BY CONSTRUCTION: a step spanning two frames carries
% tau = 2*dt, and crediting it to one frame interval would inflate D by two.
%
% INPUT
%   Tracks : a built TrackStruct array (one element per cell)
%   opts   : .dUm       engagement distance, um. Default 0.1. Scalar, or a VECTOR to scan.
%            .key       reference channel, 'mito' (default) or 'er'
%            .sigmaUm   localization precision for the noise floor; default 0.030
%            .dt        frame interval fallback when a cell carries none; default 0.02
%            .minSteps  a population needs this many steps before D is reported; default 30
%
% OUTPUT E : [nCells x nDist] struct array with
%   .file .cellIndex .dUm            which cell, and at which engagement distance
%   .Dbound .Dfree .Dratio           the headline (NaN when either population is too small)
%   .nBound .nFree                   steps in each class — READ THESE: a ratio from 12 bound steps
%                                    is not a measurement, and .ok says whether the bar was met
%   .nStraddle                       steps that CROSSED the boundary, counted in whichever class
%                                    they started in. A large share means much of the bound pool is
%                                    molecules leaving, which dilutes the contrast toward 1
%   .occupancy                       fraction of localizations inside the zone (unnormalised — for
%                                    the enrichment version this needs the area fraction too)
%   .ok                              both populations met minSteps
%   .why                             '' when ok, else the reason it is not
%
% This function never rejects a localization for being near the organelle: it CLASSIFIES steps and
% reports both classes. The mask decides where a step happened, never whether it counts.

if nargin < 2 || ~isstruct(opts), opts = struct(); end
dList   = getf_(opts,'dUm', 0.1);      dList = dList(:).';
key     = getf_(opts,'key', 'mito');
sigmaUm = getf_(opts,'sigmaUm', 0.030);
dtDef   = getf_(opts,'dt', 0.02);
minSteps= max(1, round(getf_(opts,'minSteps', 30)));

E = repmat(emptyRec(), numel(Tracks), numel(dList));
for k = 1:numel(Tracks)
    T = Tracks(k);
    % A cell with no tracks still gets a NAMED record at every distance. Leaving E(k,:) at the
    % default emptyRec() gave it a blank file, a NaN distance and 'not computed', and the caller
    % then had an unnamed row it could only label by index — which is where the phantom "cell 65"
    % rows came from on a 93-cell plate that has no such cell. A cell that cannot be measured is a
    % real answer about a real cell and must say which cell it is.
    if ~isfield(T,'matrix') || isempty(T.matrix)
        for q = 1:numel(dList)
            rec = emptyRec();
            if isfield(T,'file'), rec.file = char(T.file); end
            rec.cellIndex = k; rec.dUm = dList(q);
            rec.why = 'no tracks in this cell';
            E(k,q) = rec;
        end
        continue
    end
    M = T.matrix; [nF, nT, ~] = size(M);
    F = M(:,:,1); X = M(:,:,2); Y = M(:,:,3);
    dt = dtDef;
    if isfield(T,'frameInterval') && ~isempty(T.frameInterval) && T.frameInterval > 0
        dt = T.frameInterval;
    end

    % Distance for the TRACKED localizations, column-major so it reshapes back onto the matrix.
    [dv, have] = cs_channel_dist(T, key, 'tracked');
    file = ''; if isfield(T,'file'), file = char(T.file); end

    for q = 1:numel(dList)
        rec = emptyRec();
        rec.file = file; rec.cellIndex = k; rec.dUm = dList(q);
        if ~have || numel(dv) ~= nF*nT
            rec.why = sprintf('no %s distance on this cell', key);
            E(k,q) = rec; continue;
        end
        Dm = reshape(dv, nF, nT);
        inZone = Dm <= dList(q);                       % signed: negative is inside the organelle

        sumB = 0; tauB = 0; nB = 0;
        sumF = 0; tauF = 0; nF_ = 0; nStrad = 0;
        for j = 1:nT
            rr = find(isfinite(X(:,j)) & isfinite(Y(:,j)));
            if numel(rr) < 2, continue; end
            x = X(rr,j); y = Y(rr,j); z = inZone(rr,j);
            fr = F(rr,j);
            if all(abs(fr - round(fr)) < 1e-6), tau = diff(round(fr)) * dt;   % frame indices
            else,                               tau = diff(fr); end           % already seconds
            r2 = sum(diff([x y],1,1).^2, 2);
            a = z(1:end-1); b = z(2:end);
            okStep = isfinite(r2) & isfinite(tau) & tau > 0 & isfinite(a);
            % CLASSIFY BY WHERE THE STEP STARTED, not by both endpoints. Requiring both endpoints
            % inside the zone looks more careful and is badly wrong: it conditions on the step being
            % SHORT, because a long step starting in a narrow zone leaves it. That is selection on
            % the very quantity being measured. Measured on an UNTETHERED synthetic cell — one
            % uniform D, no tethering whatever — both-endpoints gave Dratio 0.66, a strong false
            % contrast produced entirely by the geometry. Start-only gives ~1.
            %
            % Start-only is unbiased with respect to step length: for Brownian motion position and
            % step are independent, so steps beginning in the zone are a fair sample of the steps
            % taken there. Its cost is DILUTION, not a false positive — a molecule that unbinds
            % mid-step contributes a fast step to the bound pool, pulling the ratio toward 1 and
            % making the readout conservative, which is the right direction for a hit call.
            bothIn  = okStep &  a;
            bothOut = okStep & ~a;
            % Crossings are still counted, for information: they say how much of the bound pool is
            % molecules on their way out, which is what sets the dilution above.
            nStrad = nStrad + sum(okStep & isfinite(b) & (a ~= b));
            sumB = sumB + sum(r2(bothIn));  tauB = tauB + sum(tau(bothIn));  nB   = nB   + sum(bothIn);
            sumF = sumF + sum(r2(bothOut)); tauF = tauF + sum(tau(bothOut)); nF_  = nF_  + sum(bothOut);
        end

        rec.nBound = nB; rec.nFree = nF_; rec.nStraddle = nStrad;
        rec.occupancy = mean(inZone(isfinite(Dm)), 'omitnan');
        rec.Dbound = poolD(sumB, tauB, nB, sigmaUm);
        rec.Dfree  = poolD(sumF, tauF, nF_, sigmaUm);
        if nB >= minSteps && nF_ >= minSteps && isfinite(rec.Dfree) && rec.Dfree > 0
            rec.Dratio = rec.Dbound / rec.Dfree;
            rec.ok = true;
        else
            rec.why = sprintf('too few steps (bound %d, free %d; need %d each)', nB, nF_, minSteps);
        end
        E(k,q) = rec;
    end
end
end

% -------------------------------------------------------------------------
function D = poolD(sumR2, sumTau, n, sigmaUm)
% Pooled, noise-corrected D over a set of steps. Floored at 0: a negative estimate means the
% displacement did not exceed the localization-noise floor, which is a real answer (immobile), not
% an error, and a negative D would propagate nonsense into the ratio.
D = NaN;
if n < 1 || ~(sumTau > 0), return; end
D = max((sumR2 - 4*sigmaUm^2*n) / (4*sumTau), 0);
end

function r = emptyRec()
r = struct('file','', 'cellIndex',0, 'dUm',NaN, ...
           'Dbound',NaN, 'Dfree',NaN, 'Dratio',NaN, ...
           'nBound',0, 'nFree',0, 'nStraddle',0, 'occupancy',NaN, ...
           'ok',false, 'why','not computed');
end

function v = getf_(s, f, d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
