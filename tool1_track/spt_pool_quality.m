function q = spt_pool_quality(sptPath, diamUm, pxUm, nSample)
%SPT_POOL_QUALITY  Pool DoG candidate qualities over evenly-spaced frames (drives the % tuner).
%
%   q = spt_pool_quality(sptPath, diamUm, pxUm, nSample)
%
% For each of nSample evenly-spaced frames, take the 5x5 local maxima above a LIGHT per-frame MAD
% floor (k=2, matching ERAware candidate_qualities) and collect their DoG values. The pooled
% vector `q` is the movie-level quality distribution: its histogram + a top-percentile cut give a
% single absolute threshold for the whole file (percentile detection is the proven, per-file way
% to set the threshold). Absolute threshold for keep_pct% = prctile(q, 100 - keep_pct).
%
%   sptPath : path to a multi-page single-particle TIFF
%   diamUm  : spot diameter in µm (default 0.5)
%   pxUm    : µm per pixel (default 0.10785)
%   nSample : number of frames to pool (default 40)
% OUTPUT q : pooled candidate DoG qualities (column vector)
if nargin<2 || isempty(diamUm),  diamUm  = 0.5; end
if nargin<3 || isempty(pxUm),    pxUm    = 0.10785; end
if nargin<4 || isempty(nSample), nSample = 40; end

info = imfinfo(sptPath); nfr = numel(info);
idx  = unique(round(linspace(1, nfr, min(nfr, nSample))));
q = zeros(0,1);
for k = idx
    f   = double(imread(sptPath, k));
    dog = spt_dog(f, diamUm, pxUm);
    md  = median(dog(:)); madN = 1.4826*median(abs(dog(:)-md)) + 1e-6;
    thr = md + 2.0*madN;                          % light floor (k=2) = plausible candidates
    mx  = imdilate(dog, ones(5,5));
    cand = (dog >= mx) & (dog > thr);
    q = [q; dog(cand)]; %#ok<AGROW>
end
end
