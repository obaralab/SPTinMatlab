function [xy, dens, dthr, stats, dbg] = cs_detect(rawCounts, erMask, sig, method, p)
%CS_DETECT  Detect contact-site candidate peaks in a window's localization-count image.
%
%   [xy, dens, dthr, stats] = cs_detect(rawCounts, erMask, sig, method, p)
%
% Confines detection to the ER footprint (erMask) and returns sub-pixel peak centroids + per-site
% stats. Used by the windowed contact-site picker.
%
% INPUT
%   rawCounts : [H x W] localization-count image (from cs_window_density; row=y, col=x).
%   erMask    : [H x W] logical ER support at the SAME grid resolution. Detection is restricted to it
%               (a site must sit on the ER). Pass [] / true(size) to detect over the whole FOV.
%   sig       : Gaussian sigma (px) for the detection-scale smoothing (the pipeline uses 8).
%   method    : 'ermc' | 'local' | 'relative'.
%   dbg       : (5th output) the intermediates — .bwThr (above threshold AND in the support),
%               .bwOpen (after the minArea speck removal), .L (labelled regions after splitting),
%               .dthr, .bgMed, .minArea. For callers that must explain why a particular pixel did
%               not become a site; deriving that from a second copy of the gate chain is how an
%               explanation comes to disagree with the detection it claims to explain.
%   p         : struct of knobs:
%       alpha (0.01), M (100), minArea (3 px), localSig (40), localK (1.6), relFrac (0.5)
%       Dthr        — caller-supplied cached MC cutoff (skips re-running the null)
%       nullMax     — the M Monte-Carlo peak maxima (for per-site p-values; from cs_mc_threshold)
%       splitPeaks  (true)  — marker-controlled watershed so two touching real peaks become two sites
%                             instead of one blob centroid at the saddle
%       minEnrich   (1.0)   — keep a peak only if peakDensity / ER-median-background >= this
%       minSiteLocs (0)     — keep a peak only if the localizations it encloses >= this
%
% OUTPUT
%   xy    : [K x 2] candidate centroids in density pixels, [colX rowY] (sub-pixel WeightedCentroid).
%   dens  : imgaussfilt(rawCounts, sig) — the smoothed detection density.
%   dthr  : the scalar threshold used ([] for 'local', which thresholds per-pixel).
%   stats : [K x 1] struct — one per RETURNED site: .peak .pval .enrich .nLocs .areaPx .pixels
%           (.pixels = linear indices of the site footprint, so callers can map localizations to it).
%   dbg   : detection intermediates, so a caller can explain a near-miss without reimplementing any
%           of this. .bwThr .bwOpen .L .dthr .bgMed .minArea, plus the background reference:
%             .thrPix  what each pixel was compared against - scalar (ermc, relative) or MAP (local)
%             .bgPix   the reference the threshold was built from, where it differs: the window peak
%                      for relative, the sigma=40 local-background map for local, [] for ermc
%             .bgKind  'mc' | 'peak' | 'local'
%           .bgMed is a DIFFERENT number from all of these: the median density over the support,
%           which is the denominator of .enrich and is the same for every method.

if nargin < 3 || isempty(sig),    sig = 8;         end
if nargin < 4 || isempty(method), method = 'ermc'; end
if nargin < 5 || ~isstruct(p),    p = struct();    end
if nargin < 2 || isempty(erMask), erMask = true(size(rawCounts)); end
erMask = logical(erMask);
if ~isequal(size(erMask), size(rawCounts)), erMask = true(size(rawCounts)); end

dens = imgaussfilt(rawCounts, sig);
% WHAT EACH METHOD CALLS "BACKGROUND", recorded rather than left implicit. All three threshold the
% same smoothed density; they differ entirely in what they compare it AGAINST, and the reference is
% a scalar for two of them and a MAP for the third:
%
%   ermc     a Monte-Carlo null: the localizations re-scattered at random inside the support. The
%            reference is the (1-alpha) quantile of the null's PEAK densities — one number for the
%            whole window, and the only one of the three with a false-positive rate attached.
%   relative a fraction of THIS window's brightest pixel. Not a background at all: a bright site
%            raises the bar for every other site in the same window.
%   local    k x the pixel's OWN large-scale neighbourhood (a sigma=40 blur of the map), so the
%            threshold differs at every pixel and no single number describes it.
%
% thrPix is what each pixel was actually compared against: scalar for ermc/relative, a map for
% local. Before it existed, "below the local threshold %.3g" of an empty dthr printed nothing at
% all, which is the one method where the number is least guessable. bgPix is the reference the
% threshold was built from, where that differs from the threshold itself.
dthr = [];  thrPix = [];  bgPix = [];  bgKind = '';
switch lower(method)
    case 'ermc'
        dthr = getf(p,'Dthr',[]);   % caller may pass a precomputed (cached) cutoff to avoid re-running the MC
        if isempty(dthr), dthr = cs_mc_threshold(rawCounts, erMask, sig, getf(p,'alpha',0.01), getf(p,'M',100)); end
        bw = (dens > dthr) & erMask;
        thrPix = dthr; bgKind = 'mc';
    case 'relative'
        pk = max(dens(erMask)); if isempty(pk) || ~(pk>0), pk = max(dens(:)); end
        dthr = getf(p,'relFrac',0.5) * pk;
        bw = (dens > dthr) & erMask;
        thrPix = dthr; bgPix = pk; bgKind = 'peak';
    case 'local'
        bg = imgaussfilt(dens, getf(p,'localSig',40));      % large-scale local background
        k  = getf(p,'localK',1.6);
        bw = (dens > k * bg) & erMask;
        thrPix = k * bg; bgPix = bg; bgKind = 'local';
    otherwise
        dthr = cs_mc_threshold(rawCounts, erMask, sig, getf(p,'alpha',0.01), getf(p,'M',100));
        bw = (dens > dthr) & erMask;
        thrPix = dthr; bgKind = 'mc';
end

% dbg carries the INTERMEDIATES so a caller can say WHY a given pixel is not a site without
% reimplementing any of this. Explaining a near-miss from a second copy of the gate chain is how the
% explanation and the detection drift apart, and an explanation that disagrees with the result is
% worse than none.
dbg = struct('bwThr',bw, 'bwOpen',[], 'L',[], 'dthr',dthr, 'bgMed',NaN, 'minArea',0, ...
             'thrPix',thrPix, 'bgPix',bgPix, 'bgKind',bgKind);
dbg.minArea = max(1, round(getf(p,'minArea',3)));
bw = bwareaopen(bw, dbg.minArea);                            % drop specks
dbg.bwOpen = bw;

% --- split touching peaks so two real maxima don't collapse into one centroid ---
if getf(p,'splitPeaks',true)
    L = cs_split_peaks(dens, bw);
else
    L = double(bwlabel(bw));
end
dbg.L = L;

% --- per-site stats + effect-size gate ---
bgMed = median(dens(erMask)); if ~(bgMed>0), bgMed = median(dens(bw)); end; if ~(bgMed>0), bgMed = eps; end
dbg.bgMed = bgMed;
nullMax   = getf(p,'nullMax',[]);
minEnrich = getf(p,'minEnrich',1.0);
minLocs   = getf(p,'minSiteLocs',0);
rp = regionprops(L, dens, 'WeightedCentroid','Area','MaxIntensity','PixelIdxList');
xy = zeros(0,2);
stats = struct('peak',{},'pval',{},'enrich',{},'nLocs',{},'areaPx',{},'pixels',{});
for i = 1:numel(rp)
    if isempty(rp(i).PixelIdxList) || rp(i).Area < 1, continue; end
    pk  = rp(i).MaxIntensity;
    enr = pk / bgMed;
    nl  = sum(rawCounts(rp(i).PixelIdxList));           % localizations enclosed by the footprint
    if enr < minEnrich || nl < minLocs, continue; end    % effect-size gate
    pv = NaN; if ~isempty(nullMax), pv = mean(nullMax >= pk); end
    c  = rp(i).WeightedCentroid;
    xy(end+1,:) = c;                                                                       %#ok<AGROW>
    stats(end+1) = struct('peak',pk,'pval',pv,'enrich',enr,'nLocs',nl, ...
                          'areaPx',rp(i).Area,'pixels',rp(i).PixelIdxList);                %#ok<AGROW>
end
end

% =========================================================================
function L = cs_split_peaks(dens, bw)
% Marker-controlled watershed: split merged above-threshold regions at their saddle points so each
% prominent local maximum becomes its own labelled region. A region with a single peak stays whole.
L = double(bwlabel(bw));
nB = max(L(:));
if nB < 1, return; end
v = dens(bw); h = 0.15*(max(v)-min(v));                 % prominence: 15% of the in-mask density range
if ~(h>0), return; end
mk = imregionalmax(imhmax(dens, h)) & bw;               % markers = peaks standing >= h above surroundings
for k = 1:nB                                            % guarantee every blob has >= 1 marker
    reg = (L==k);
    if ~any(mk(reg))
        sub = dens; sub(~reg) = -Inf; [~,im] = max(sub(:)); mk(im) = true;
    end
end
I = -dens; I(~bw) = Inf;                                % watershed the inverted density, walled off outside bw
I = imimposemin(I, mk);                                 % basins ONLY at the markers
W = watershed(I); W(~bw) = 0;
L = double(W);
end

% -------------------------------------------------------------------------
function v = getf(s, f, d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
