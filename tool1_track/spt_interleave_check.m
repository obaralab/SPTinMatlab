function S = spt_interleave_check(sptPath, nSample, segPath)
%SPT_INTERLEAVE_CHECK  Is this stack a RAW INTERLEAVED two-channel movie rather than one channel?
%
%   S = spt_interleave_check(sptPath)
%   S = spt_interleave_check(sptPath, nSample)     % frame triples to sample (default 25)
%   S = spt_interleave_check(sptPath, nSample, segPath)   % ...and say WHICH parity is the organelle
%
% WHY THIS EXISTS. A two-colour acquisition can be saved as one stack with the channels alternating
% page by page: page 1 the particle channel, page 2 the organelle channel, page 3 the particle
% channel again. Point a spot detector at that and every second page is an ORGANELLE image, which a
% DoG shreds into a chain of bright, spot-sized, entirely spurious detections along each
% mitochondrion — and nothing about the run announces it. The tracks come out, the counts look
% plausible, and half the localizations are mitochondrial edges. That is the failure this catches.
%
% Filtering those detections by shape is the wrong remedy for this case and this function exists so
% that nobody reaches for it: if alternate frames are a DIFFERENT CHANNEL, the answer is to use the
% de-interleaved single-channel stack (or drop that parity), not to clean up after detecting on it.
%
% HOW. In an interleaved stack a frame resembles the frame TWO later (same channel) more than the
% one immediately after it (other channel). In an ordinary movie the opposite holds, because
% adjacent frames are closer in time and decorrelate with separation. So the discriminator is
%
%       delta = mean corr(f_t, f_t+2) - mean corr(f_t, f_t+1)
%
% which is POSITIVE for an interleaved stack and NEGATIVE for a normal one. Measured BY THIS
% FUNCTION on three real cells, each as a raw interleaved stack and as its own de-interleaved
% export of the same acquisition:
%
%       interleaved    delta = +0.279, +0.259, +0.268     (adj ~0.34, skip ~0.61)
%       single channel delta = -0.108, -0.099, -0.088     (adj ~0.42, skip ~0.33)
%
% The two groups are separated by about 0.35 with no overlap, so the cut sits at +0.02 — inside the
% gap, and far enough from zero that a movie with genuinely little frame-to-frame change does not
% trip it. delta is reported alongside the verdict so a borderline stack can be judged by eye.
%
% OUTPUT S
%   .adj, .skip      mean correlation at separation 1 and 2
%   .delta           skip - adj  (positive => alternating content)
%   .isInterleaved   logical verdict
%   .nFrames         pages in the stack
%   .why             one-line human-readable explanation
%   .enrichOdd/.enrichEven   mean intensity inside the organelle mask / outside, per parity (NaN
%                            without segPath). >1 means that parity lights up where the organelle is.
%   .organelleParity 'odd' | 'even' | '' — which parity IS the organelle channel, when the two are
%                    clearly separated. '' when there is no mask, or no clear difference.
%   .particleParity  the other one — the pages to keep. '' when undecided.
%   .crosstalk       the particle parity's enrichment: ~1 means no meaningful leak-through.
%
% WHAT THE ORGANELLE MASK IS FOR HERE, AND WHAT IT IS NOT.
% Given segPath, this also measures the MEAN IMAGE INTENSITY inside the organelle mask against
% outside it, separately for each parity. Two legitimate uses, one forbidden one.
%
%   USE IT to say which parity CARRIES ORGANELLE SIGNAL — measured 1.65x vs 1.05x, 1.43x vs 1.03x
%   and 1.36x vs 1.03x on three real cells. But read that number carefully, because TWO different
%   situations produce it and they call for opposite actions:
%
%     (a) that parity IS the organelle channel — a two-colour stack with the channels alternating.
%         Then de-interleave to the OTHER parity; detecting these pages tracks mitochondria.
%     (b) that parity is a PARTICLE channel carrying BLEEDTHROUGH from a simultaneously-acquired
%         organelle channel. Then de-interleaving would throw away half your real data. Keep every
%         frame and gate only the contaminated parity ('on frames' + the ridge/size tests).
%
%   Additive leak onto a real particle frame lifts the in-mask mean exactly as an organelle image
%   does, so THIS NUMBER CANNOT TELL (a) FROM (b) and must not be reported as if it could. What
%   distinguishes them is whether that parity still contains moving single molecules, which is a
%   question for the person who ran the microscope. The message below therefore states the
%   measurement and both readings, and does not pick one.
%
%   USE IT to say whether there is any crosstalk to worry about. Leak from the other channel raises
%   the whole image inside the mask; single molecules barely move a frame mean. On those same three
%   cells the particle parity sat at 1.03-1.05x, i.e. no meaningful bleedthrough at all.
%
%   NEVER USE IT to filter detections. A real molecule sitting ON a mitochondrion is exactly what
%   these experiments measure, so rejecting detections inside the mask deletes the signal. Nor
%   should the shape/size gates be applied only inside it: enrichment is local density over
%   background density, so a gate with any false-rejection rate, applied only where the biology is,
%   biases enrichment and mito fraction DOWNWARD. A gate applied everywhere is at least unbiased
%   with respect to the mask. This function therefore reports and never rejects.
%
% The interleave verdict itself is STRUCTURAL and needs no organelle channel; segPath only adds the
% parity attribution and the crosstalk level.

if nargin < 2 || isempty(nSample), nSample = 25; end
if nargin < 3, segPath = ''; end
DELTA_MIN = 0.02;
ENRICH_SEP = 1.15;      % the organelle parity must beat the other by this factor to be named

S = struct('adj',NaN, 'skip',NaN, 'delta',NaN, 'isInterleaved',false, 'nFrames',0, 'why','', ...
           'enrichOdd',NaN, 'enrichEven',NaN, 'organelleParity','', 'particleParity','', 'crosstalk',NaN);

try, info = imfinfo(sptPath); catch, S.why = 'could not read the stack'; return; end
n = numel(info);
S.nFrames = n;
if n < 6, S.why = sprintf('only %d pages — too short to judge', n); return; end

ts = unique(round(linspace(3, n-3, min(nSample, max(n-5,1)))));
a = nan(numel(ts),1); b = nan(numel(ts),1);
for i = 1:numel(ts)
    t = ts(i);
    try
        f0 = double(imread(sptPath, t));
        f1 = double(imread(sptPath, t+1));
        f2 = double(imread(sptPath, t+2));
    catch, continue; end
    a(i) = corr2_(f0, f1);
    b(i) = corr2_(f0, f2);
end
a = a(isfinite(a)); b = b(isfinite(b));
if isempty(a) || isempty(b), S.why = 'no readable frame triples'; return; end

S.adj = mean(a); S.skip = mean(b); S.delta = S.skip - S.adj;
S.isInterleaved = S.delta > DELTA_MIN;
% ---- which parity is the organelle channel? (needs the mask; never used to reject anything) ----
if ~isempty(segPath) && isfile(segPath)
    [S.enrichOdd, S.enrichEven] = parity_enrichment(sptPath, segPath, ts);
    eo = S.enrichOdd; ee = S.enrichEven;
    if isfinite(eo) && isfinite(ee)
        if     ee > eo*ENRICH_SEP, S.organelleParity = 'even'; S.particleParity = 'odd';  S.crosstalk = eo;
        elseif eo > ee*ENRICH_SEP, S.organelleParity = 'odd';  S.particleParity = 'even'; S.crosstalk = ee;
        end
    end
end

if S.isInterleaved
    S.why = sprintf(['pages alternate between two different contents (frame t matches t+2 better ' ...
        'than t+1; delta=%+.3f). This looks like a RAW INTERLEAVED two-channel stack — every ' ...
        'second page is the other channel. '], S.delta);
    if ~isempty(S.particleParity)
        S.why = [S.why sprintf(['The %s pages carry far more organelle signal (%.2fx inside the ' ...
            'mask against %.2fx for the %s pages). EITHER they are the organelle channel — then ' ...
            'de-interleave to the %s pages — OR they are a particle channel with bleedthrough, in ' ...
            'which case keep every frame and gate only the %s parity ("on frames"). The intensity ' ...
            'alone cannot tell these apart; you know which acquisition you ran.'], ...
            S.organelleParity, max(S.enrichOdd,S.enrichEven), min(S.enrichOdd,S.enrichEven), ...
            S.particleParity, S.particleParity, S.organelleParity)];
    else
        S.why = [S.why ['If the two parities are different CHANNELS, de-interleave to the particle ' ...
            'one; if they are both particle frames and one carries bleedthrough, keep them all and ' ...
            'gate that parity with "on frames".']];
    end
else
    S.why = sprintf('no alternating structure (delta=%+.3f)', S.delta);
end
end

% -------------------------------------------------------------------------
function [eOdd, eEven] = parity_enrichment(sptPath, segPath, ts)
% Mean image intensity inside the organelle mask over outside it, averaged per parity. Intensity,
% not detections: leak-through lifts the whole image inside the mask, whereas single molecules
% barely move a frame mean — and a DETECTION-based enrichment would be the biological readout
% itself, which cannot then be used to judge whether the data are contaminated.
eOdd = NaN; eEven = NaN;
try
    si = imfinfo(segPath); nSeg = numel(si);
    pi_ = imfinfo(sptPath); nPg = numel(pi_);
    if nSeg < 1 || nPg < 1, return; end
    m1 = imread(segPath, 1);
    nz = double(unique(m1(m1 > 0)));
    if isempty(nz), return; end
    fg = min(nz);                                  % 1 for an ilastik label map, 255 for 0/255
    ro = []; re = [];
    for t = ts(:)'
        p = max(1, min(nSeg, ceil(t * nSeg / nPg)));
        M = imread(segPath, p) == fg;
        if ~any(M(:)) || all(M(:)), continue; end
        f = double(imread(sptPath, t));
        r = mean(f(M)) / max(mean(f(~M)), eps);
        if mod(t,2) == 1, ro(end+1) = r; else, re(end+1) = r; end %#ok<AGROW>
    end
    if ~isempty(ro), eOdd  = mean(ro); end
    if ~isempty(re), eEven = mean(re); end
catch
end
end

% -------------------------------------------------------------------------
function r = corr2_(x, y)
% Pearson correlation of two images, without the Statistics toolbox.
x = double(x(:)); y = double(y(:));
x = x - mean(x); y = y - mean(y);
d = sqrt(sum(x.*x) * sum(y.*y));
if d <= 0, r = NaN; else, r = sum(x.*y) / d; end
end
