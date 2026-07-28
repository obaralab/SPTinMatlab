function [frames, counts] = spt_count_per_frame(sptPath, diamUm, pxUm, thrAbs, nSample)
%SPT_COUNT_PER_FRAME  Detected-spot count per frame over nSample evenly-spaced frames.
%
%   [frames, counts] = spt_count_per_frame(sptPath, diamUm, pxUm, thrAbs, nSample)
%
% Drives the "spots / frame" trace in the Detect tab so the threshold's stability across the movie
% is visible at a glance. Uses the same absolute threshold (thrAbs, from the top-percentile tuner)
% as the live preview.
if nargin<5 || isempty(nSample), nSample = 120; end
info = imfinfo(sptPath); nfr = numel(info);
frames = unique(round(linspace(1, nfr, min(nfr, nSample))));
counts = zeros(size(frames));
for i = 1:numel(frames)
    im = double(imread(sptPath, frames(i)));
    counts(i) = size(spt_detect(im, diamUm, pxUm, thrAbs), 1);
end
end
