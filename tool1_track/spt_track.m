function [tracks, info] = spt_track(dets, supports, linkUm, gapUm, maxGap, pxUm, erAware, lambda, mode)
%SPT_TRACK  LAP tracking of per-frame detections. Port of ERAware build_tracks() + gap_close().
%
%   [tracks, info] = spt_track(dets, supports, linkUm, gapUm, maxGap, pxUm, erAware, lambda, mode)
%
% mode : 'euclid'   plain Euclidean LAP (no ER);
%        'penalty'  SOFT ER bias on the STRAIGHT-LINE off-ER fraction: cost = dist·(1+lambda·off).
%                   Off-ER links are allowed, just dearer.
%        'geodesic' STRICT ER constraint. A detection that is not on its OWN frame's ER support is
%                   removed before the assignment, so it cannot enter a track by ANY route (frame
%                   link, chain assembly or gap close). Surviving links cost the shortest path
%                   THROUGH the ER (bwdistgeodesic), so a link that must detour around an ER gap
%                   costs its true along-ER length; unreachable partners and detours longer than
%                   the link radius are FORBIDDEN. lambda is unused except in the birth/death cost.
% Default: 'penalty' when erAware else 'euclid'. (mode overrides erAware when given.)
%
% Strict geodesic FAILS CLOSED: a frame with no ER mask contributes no tracked detections at all,
% rather than silently falling back to unconstrained Euclidean linking. `info` reports how often
% that happened so the caller can record it in the run provenance.
%
% Frame-to-frame linking is solved as a linear assignment (matchpairs) with a cost-of-no-link that
% sits above any feasible cost, so a within-range partner always beats a birth/death. Chains are
% then assembled and gap-closed (stitch a track end to a later start within gapUm, up to maxGap
% missing frames). The gap-close ER test matches the linking mode: 'penalty' keeps the soft
% straight-line veto (reject if >50% of the segment is off-ER); 'geodesic' requires the bridge to
% be reachable ALONG the ER, so a gap close can never make a jump that frame-to-frame linking
% would have forbidden.
%
% INPUT
%   dets     : 1xT cell; dets{t} = Nx3 [x y quality] detections for frame t (1-based px)
%   supports : 1xT cell of logical ER support masks (or {}/[] entries) — used when ER-aware
%   linkUm   : frame-to-frame max link distance (µm)  [TrackMate "Linking max distance"]
%   gapUm    : gap-closing max distance (µm)           [TrackMate "Gap-closing max distance"]
%   maxGap   : max missing frames to bridge            [TrackMate "Gap-closing max frame gap"]
%   pxUm     : µm per pixel
%   erAware  : true -> ER-aware linking; false -> plain Euclidean LAP
%   lambda   : ER penalty weight, 'penalty' mode only (default 3)
% OUTPUT
%   tracks : 1xM cell; each Kx4 = [frame x y quality], sorted by frame, K>=2 (linked tracks only).
%            (Every detection stays available to the caller for the localization set; tracks are the
%            linked subset.)
%   info   : struct — mode, nFramesNoErMask, nDets, nDetsOffEr (detections strict mode excluded).
if nargin<7 || isempty(erAware), erAware = false; end
if nargin<8 || isempty(lambda),  lambda  = 3.0; end
if nargin<9 || isempty(mode),    mode = ''; end
if isempty(mode), if erAware, mode = 'penalty'; else, mode = 'euclid'; end, end   % mode overrides erAware
% Reject an unknown mode rather than silently linking Euclidean — a typo must not quietly turn the
% strict ER constraint off.
if ~ismember(mode, {'euclid','penalty','geodesic'})
    error('spt_track:badMode', 'Unknown linking mode ''%s'' (expected euclid | penalty | geodesic).', mode);
end
erAware = ~strcmp(mode,'euclid');   % gap-close veto applies for any ER-aware mode
R = linkUm/pxUm; G = gapUm/pxUm;
nT = numel(dets);
d0 = R*(1+lambda) + 1;                              % cost of leaving a spot unlinked (birth/death)
info = struct('mode',mode,'nFramesNoErMask',0,'nDets',0,'nDetsOffEr',0);
if nT > 0, info.nDets = sum(cellfun(@(d) size(d,1), dets)); end

% ---- the 1 px-dilated ER support per frame (one shared definition — see spt_er_support) ----
supD = cell(1,nT);
for t = 1:nT
    s = []; if t <= numel(supports), s = supports{t}; end
    supD{t} = spt_er_support(s);
end

% ---- strict geodesic: drop every detection that is not on its OWN frame's ER, up front ----
% Doing this BEFORE the assignment is what makes the strict rule hold by construction: an off-ER
% detection is not available to the LAP, to chain assembly, or to gap closing. A frame with no ER
% mask keeps nothing (fail closed) — it must never mean "no constraint here".
if strcmp(mode,'geodesic')
    for t = 1:nT
        % A mask that is PRESENT but all-false is the same thing as no ER for this frame — that is
        % what a segmenter returns when it finds nothing — so count it, or the provenance line
        % cannot tell "the ER really covered every frame" from "the segmentation came back empty".
        if isempty(supD{t}) || ~any(supD{t}(:)), info.nFramesNoErMask = info.nFramesNoErMask + 1; end
        if isempty(dets{t}), continue; end
        keep = spt_on_er(dets{t}(:,1:2), supD{t});
        info.nDetsOffEr = info.nDetsOffEr + sum(~keep);
        dets{t} = dets{t}(keep,:);
    end
    if info.nFramesNoErMask > 0
        warning('spt_track:noErMask', ...
            ['ER-geodesic (strict): %d of %d frames have no ER mask, so every detection in those ' ...
             'frames was excluded from tracking (strict mode fails closed). Check that the ER ' ...
             'segmentation covers the whole movie.'], info.nFramesNoErMask, nT);
    end
end

% ---- frame-to-frame links: nxt{t}(i) = index in dets{t+1}, or 0 ----
nxt = cell(nT,1);
for t = 1:nT-1
    P = dets{t}; Q = dets{t+1};
    nxt{t} = zeros(size(P,1),1);
    if isempty(P) || isempty(Q), continue; end
    sup = []; if erAware && t <= numel(supports), sup = supports{t}; end
    if strcmp(mode,'geodesic')
        supQ = []; if t+1 <= numel(supports), supQ = supports{t+1}; end
        C = spt_link_cost_geo(P, Q, R, sup, lambda, supQ);   % forbids everything when a mask is missing
    else
        C = spt_link_cost(P, Q, R, erAware, lambda, sup);
    end
    Mm = matchpairs(C, d0);                          % rows(frame t) -> cols(frame t+1)
    for r = 1:size(Mm,1)
        i = Mm(r,1); j = Mm(r,2);
        if isfinite(C(i,j)), nxt{t}(i) = j; end
    end
end

% ---- chain assembly: walk forward from every spot that has no incoming link ----
started = cell(nT,1);
for t = 1:nT, started{t} = false(size(dets{t},1),1); end
for t = 1:nT-1
    j = nxt{t}; on = j > 0;
    started{t+1}(j(on)) = true;
end
tracks = {};
for t = 1:nT
    for i = 1:size(dets{t},1)
        if started{t}(i), continue; end             % not a chain start
        chain = zeros(0,4); tt = t; ii = i;
        while true
            d = dets{tt}(ii,:);
            chain(end+1,:) = [tt, d(1), d(2), d(3)]; %#ok<AGROW>
            if tt < nT && nxt{tt}(ii) > 0, ii = nxt{tt}(ii); tt = tt+1; else, break; end
        end
        if size(chain,1) >= 2, tracks{end+1} = chain; end %#ok<AGROW>
    end
end

% ---- gap closing ----
if maxGap >= 1 && numel(tracks) > 1
    tracks = gap_close_tracks(tracks, supports, G, maxGap, erAware, mode);
end
end

% =========================================================================
function tracks = gap_close_tracks(tracks, supports, G, maxGap, erAware, mode)
n = numel(tracks);
endF = zeros(n,1); endXY = zeros(n,2); startF = zeros(n,1); startXY = zeros(n,2);
for k = 1:n
    tr = tracks{k};
    endF(k) = tr(end,1); endXY(k,:) = tr(end,2:3);
    startF(k) = tr(1,1); startXY(k,:) = tr(1,2:3);
end
strict = strcmp(mode,'geodesic');
usedStart = false(n,1); mergedInto = zeros(n,1);   % mergedInto(b)=a : start b appended after end a
[~, order] = sort(endF);
for oi = 1:n
    a = order(oi);
    te = endF(a); best = -1; bestd = inf;
    for dt = 2:maxGap+1
        for b = 1:n
            if usedStart(b) || b == a || startF(b) ~= te+dt, continue; end
            dd = hypot(endXY(a,1)-startXY(b,1), endXY(a,2)-startXY(b,2));
            if dd <= G && dd < bestd
                if strict
                    % Strict: the bridge must be reachable ALONG the ER, so a gap close can never
                    % make a jump the linking stage forbids. A missing mask forbids the merge.
                    if ~isfinite(geo_bridge(endXY(a,:), startXY(b,:), G, supports, te, startF(b)))
                        continue;
                    end
                elseif erAware && te <= numel(supports) && ~isempty(supports{te})
                    % Soft ('penalty') veto, unchanged: reject a mostly-off-ER straight bridge.
                    if spt_seg_off_fraction(endXY(a,:), startXY(b,:), supports{te}) > 0.5, continue; end
                end
                bestd = dd; best = b;
            end
        end
        if best > 0, break; end                    % nearest start at the smallest gap
    end
    if best > 0, usedStart(best) = true; mergedInto(best) = a; end
end
% rebuild chains: childOf(a) = b when start b merged into end a
childOf = zeros(n,1); isChild = false(n,1);
for b = 1:n
    if mergedInto(b) > 0, childOf(mergedInto(b)) = b; isChild(b) = true; end
end
out = {};
for k = 1:n
    if isChild(k), continue; end
    chain = tracks{k}; c = childOf(k);
    while c > 0, chain = [chain; tracks{c}]; c = childOf(c); end %#ok<AGROW>
    out{end+1} = chain; %#ok<AGROW>
end
tracks = out;
end

% -------------------------------------------------------------------------
function c = geo_bridge(pEnd, pStart, G, supports, tEnd, tStart)
% Along-ER cost of bridging a gap, using the same strict rule as frame-to-frame linking: both
% endpoints on their own frame's ER, connected along the END frame's ER within G. Inf = forbidden
% (which includes either frame having no ER mask).
sE = []; if tEnd   >= 1 && tEnd   <= numel(supports), sE = supports{tEnd};   end
sS = []; if tStart >= 1 && tStart <= numel(supports), sS = supports{tStart}; end
c = spt_link_cost_geo(pEnd, pStart, G, sE, 0, sS);
end
