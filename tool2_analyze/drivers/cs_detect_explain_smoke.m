function cs_detect_explain_smoke()
%CS_DETECT_EXPLAIN_SMOKE  A bright spot that is NOT a site must say which gate stopped it.
%
% "It is clearly above background, why was it not detected?" has five possible answers and the
% picker used to give none of them: explain spot reported density, enrichment, localizations and
% tracks, all of which can look fine while the spot is rejected for a reason none of them shows.
%
% The gates, in the order they apply:
%   1. outside the SUPPORT MASK      — nothing there is ever detected, at any brightness
%   2. below the method's THRESHOLD  — 'relative' is a fraction of the window's brightest peak, so a
%                                      spot can be far above background and still under it
%   3. smaller than MIN AREA         — the speck filter, which is what removes a peak that is bright
%                                      but spatially CONFINED: few pixels clear the threshold
%   4. under MIN ENRICH / MIN LOCS   — the per-site effect-size gates
%   5. under MIN TRACKS              — one parked molecule is not a contact site
%
% WHAT IS ASSERTED: cs_detect exposes the intermediates each verdict is read from, and they identify
% the right stage for a spot planted to fail at each one. The verdict is read off the DETECTION's own
% arrays — recomputing the chain to explain it is how an explanation comes to disagree with the
% result it explains.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
N = 120; sig = 2;

%% a field with four planted spots, each engineered to fail at a different stage ------------------
% Amplitudes and sizes were MEASURED, not guessed: with sig=2 the threshold lands at 179 and the
% four spots come out at 357 / 357 / 8 / 313, with above-threshold areas of 45 and 13 px.
N = 120; sig = 2;
raw = zeros(N);
raw(27:33, 27:33) = 400;     % A  big and bright, inside the support   -> must pass everything
raw(27:33, 87:93) = 400;     % B  equally bright, OUTSIDE the support  -> stopped by the mask
raw(89:91, 29:31) =  25;     % C  dim, inside the support              -> stopped by the threshold
raw(95, 95)       = 7500;    % D  ONE pixel, very bright               -> stopped by min area
mask = true(N); mask(:, 70:end) = false;     % B's column is outside the support
mask(88:102, 88:102) = true;                 % ...but D's corner is inside it

MINAREA = 20;                % A covers 45 px above threshold, D only 13
p = struct('relFrac',0.5,'minArea',MINAREA,'minEnrich',1.0,'minSiteLocs',0,'splitPeaks',false);
[xy, dens, dthr, ~, dbg] = cs_detect(raw, mask, sig, 'relative', p);
fprintf('threshold %.4g · %d site(s) detected\n', dthr, size(xy,1));

%% (1) the intermediates exist and describe the stages ---------------------------------------------
for f = {'bwThr','bwOpen','L','dthr','bgMed','minArea'}
    assert(isfield(dbg,f{1}), 'cs_detect''s 5th output has no %s — a caller cannot name the gate without it', f{1});
end
assert(isequal(size(dbg.bwThr), [N N]) && isequal(size(dbg.bwOpen), [N N]), 'the masks are the wrong size');
assert(dbg.minArea == MINAREA, 'dbg reports min area %d, not the %d it was given', dbg.minArea, MINAREA);

%% (2) A passes every stage --------------------------------------------------------------------------
assert(dbg.bwThr(30,30) && dbg.bwOpen(30,30) && dbg.L(30,30) > 0, ...
    'the bright well-formed spot did not survive detection, so this fixture cannot separate the failures');

%% (3) B is stopped by the SUPPORT MASK, not by brightness ---------------------------------------------
assert(dens(30,90) > dthr, ...
    'spot B is not above threshold (%.3g vs %.3g), so it would fail for the wrong reason', dens(30,90), dthr);
assert(~mask(30,90), 'the fixture mask does not actually exclude spot B');
assert(~dbg.bwThr(30,90), 'spot B is outside the support mask but reached bwThr');

%% (4) C is stopped by the THRESHOLD ------------------------------------------------------------------
assert(mask(90,30), 'spot C should be inside the support so the threshold is what stops it');
assert(dens(90,30) < dthr, ...
    'spot C is above the relative threshold (%.3g vs %.3g), so it does not test that gate', dens(90,30), dthr);
assert(~dbg.bwThr(90,30), 'spot C is under the threshold but reached bwThr');

%% (5) D is stopped by MIN AREA — the CONFINED case ------------------------------------------------------
% This is the one behind "it is clearly above background, why is it not a site?". D is BRIGHTER than
% the threshold and inside the support; it fails only because too few pixels clear the threshold.
assert(mask(95,95), 'spot D must be inside the support for min area to be what stops it');
assert(dens(95,95) > dthr, ...
    'the confined spot is not above threshold (%.3g vs %.3g) — it cannot demonstrate the min-area gate', ...
    dens(95,95), dthr);
assert(dbg.bwThr(95,95), 'the confined spot did not reach bwThr');
assert(~dbg.bwOpen(95,95), ...
    ['a bright but spatially CONFINED spot survived the min-area filter, so this fixture does not ' ...
     'exercise the gate that produces the reported surprise']);
nAbove = nnz(dbg.bwThr(88:102, 88:102));
fprintf('confined spot: %.3g (%.1fx the %.3g threshold) but only %d px above it, min area %d\n', ...
    dens(95,95), dens(95,95)/dthr, dthr, nAbove, dbg.minArea);
assert(nAbove < dbg.minArea, 'the confined spot has %d px above threshold, not under min area %d', nAbove, dbg.minArea);

%% (6) the gate it names is one the user can act on -----------------------------------------------------
p2 = p; p2.minArea = 1;
[~,~,~,~,dbg2] = cs_detect(raw, mask, sig, 'relative', p2);
assert(dbg2.bwOpen(95,95), ...
    'dropping min area to 1 did not recover the confined spot, so naming that gate would not help');
fprintf('min area 1 recovers it — the verdict points at a setting that changes the answer\n');

fprintf('\nDETECT-EXPLAIN SMOKE PASSED.\n');
end

% ================================================================================================
function A = addSpot(A, r, c, amp, halfw)
% A square blob of counts. halfw = 0 gives a single pixel — bright but with no spatial extent, which
% after smoothing clears the threshold over only a handful of pixels.
rr = max(1,r-halfw):min(size(A,1), r+halfw);
cc = max(1,c-halfw):min(size(A,2), c+halfw);
A(rr,cc) = A(rr,cc) + amp;
end
