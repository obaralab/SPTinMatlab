function [dog, hp, scale] = spt_dog(frame, diamUm, pxUm)
%SPT_DOG  Difference-of-Gaussians spot filter, scaled by spot diameter. Port of ERAware _dog().
%
%   [dog, hp] = spt_dog(frame, diamUm, pxUm)
%
% Background-subtract with a wide Gaussian, then take a DoG at the spot scale. The three sigmas
% scale with the spot's pixel radius (diamUm/pxUm/2); at the reference (0.5 µm @ 0.10785 µm/px,
% radius ≈ 2.32 px) they equal ERAware's exact values (background σ=6, DoG σ=1.0 and 2.2 px), so
% detection matches ERAware at the default and scales sensibly for other diameters/cameras.
%
%   dog   : the detection image (local maxima above threshold are spots)
%   hp    : the high-pass (background-subtracted) image, used for the sub-pixel centroid
%   scale : this spot's size relative to the reference (1.0 at 0.5 µm / 0.10785 µm/px). Every
%           structure in `dog` is this many times bigger than at the reference, so anything that
%           MEASURES the DoG surface — spt_ridge's curvature step — has to scale by it too. Handed
%           out rather than recomputed by the caller: REF_RPX belongs in one place.
% Gaussian blur matches scipy (symmetric padding, kernel radius ceil(4σ)) for detection parity.
if nargin<2 || isempty(diamUm), diamUm = 0.5; end
if nargin<3 || isempty(pxUm),   pxUm   = 0.10785; end
f = double(frame);
REF_RPX = (0.5/0.10785)/2;                      % reference spot radius in px (≈2.318) at ERAware sigmas
rpx   = (max(diamUm,1e-3)/max(pxUm,1e-6)) / 2;  % this spot's radius in px
scale = rpx / REF_RPX;                          % 1.0 at the reference
sBg = 6.0*scale; s1 = 1.0*scale; s2 = 2.2*scale;
hp  = f - gblur(f, sBg);
dog = gblur(hp, s1) - gblur(hp, s2);
end

function y = gblur(x, s)
y = imgaussfilt(x, s, 'Padding','symmetric', 'FilterSize', 2*ceil(4*s)+1);
end
