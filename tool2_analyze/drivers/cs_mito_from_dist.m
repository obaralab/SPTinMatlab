function [fl, stat] = cs_mito_from_dist(xy, sX, sY, sMD, Rpx, contactUm, useFraction)
%CS_MITO_FROM_DIST  Classify a contact-site point as mito (1) / non-mito (2) from the per-frame,
% per-spot signed mito DISTANCE of the localizations around it — replacing the mito-MIP lookup.
%
% Each localization carries a signed distance to the nearest mito pixel IN ITS OWN FRAME
% (Tracks.allSpots.MITODIST / Tracks.mitoDist): + outside mito, - inside, ~0 on the boundary. So a
% MOVING mito is handled correctly — a site is judged by where its localizations actually sat
% relative to mito over time, not by a whole-movie mito projection.
%
% INPUT
%   xy         : site centre in density px [x y].
%   sX,sY      : localization coords in density px (Nx1), same set as sMD.
%   sMD        : signed mito distance in MICRONS per localization, 1:1 with sX/sY (Nx1); NaN allowed.
%   Rpx        : neighbourhood radius in density px — localizations within Rpx define the site.
%   contactUm  : contact-distance threshold in microns; a site is mito if its statistic <= contactUm.
%   useFraction: false (default) -> statistic = MEDIAN signed distance of nearby localizations;
%                true            -> mito if the FRACTION of nearby locs within contactUm is >= 0.5.
%
% OUTPUT
%   fl   : 1 (mito) or 2 (non-mito).
%   stat : struct('median',med,'fraction',frac,'n',nUsed) — BOTH statistics are always returned so
%          the caller can display them regardless of which one drove the flag.
fl = 2; stat = struct('median',NaN,'fraction',NaN,'n',0);
if nargin<7 || isempty(useFraction), useFraction = false; end
if isempty(sX) || numel(xy)<2, return; end
d = hypot(sX(:)-xy(1), sY(:)-xy(2));
md = sMD(:);
md = md(d <= Rpx);
md = md(isfinite(md));
n  = numel(md);
stat.n = n;
if n==0, return; end
med  = median(md);
frac = mean(md <= contactUm);
stat.median = med; stat.fraction = frac;
if useFraction
    if frac >= 0.5, fl = 1; end
else
    if med <= contactUm, fl = 1; end
end
end
