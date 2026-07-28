function [Dthr, nullMax] = cs_mc_threshold(rawCounts, mask, sig, alpha, M, wmap)
%CS_MC_THRESHOLD  Monte-Carlo random-labelling CSR null threshold for density-peak detection.
%
% Scatter N points over the mask M times (N = the localization count on the mask), smooth each
% realization the SAME way as the data, and collect each run's MAXIMUM in-mask smoothed density.
% Dthr = (1-alpha) quantile of those maxima -> family-wise P[>=1 false site] ~ alpha. Fixed seed
% so a browse-back is reproducible.
%
% wmap (optional): a non-negative per-pixel weight over the mask that turns the UNIFORM CSR null
% into an INHOMOGENEOUS one — null points are drawn PROPORTIONAL to wmap (and only where wmap>0)
% instead of uniformly. This is the 'ermc' (ER Monte-Carlo) variant: redistribute the null
% localizations onto the ER-supported pixels so only peaks ABOVE the ER-expected density survive.
% Omit / pass [] for the classic uniform null (bit-identical to the legacy mc_threshold).
%
% N = round(sum(rawCounts(mask))). For the uniform null the caller's mask (detMask) is a superset
% of every count pixel, so this equals the legacy sum(rawCounts(:)); for the weighted null the
% caller passes the ER support as the mask, so N is the on-ER localization count (matches the
% analytic 'erweight' null's Non).
[Hh,Ww] = size(rawCounts); idx = find(mask); A = numel(idx);
N = round(sum(rawCounts(mask)));
nullMax = zeros(max(M,1),1);
if A<1 || N<1, Dthr = Inf; return; end
useW = nargin>=6 && ~isempty(wmap);
if useW
    w = double(wmap(idx)); w = w(:);
    pos = w > 0;
    if ~any(pos)
        useW = false;                                  % degenerate weight -> fall back to uniform
    else
        pidx = idx(pos); cw = cumsum(w(pos)) / sum(w(pos));   % strictly increasing (all >0)
        edges = [0; cw(:)];
    end
end
rng(20240713,'twister');
for m = 1:M
    if useW
        sel = pidx(discretize(rand(N,1), edges));      % inverse-CDF draw ~ wmap, on wmap>0 pixels
    else
        sel = idx(randi(A, N, 1));                     % uniform CSR on the grid
    end
    rc  = accumarray(sel, 1, [Hh*Ww 1]);
    Dm  = imgaussfilt(reshape(rc,[Hh Ww]), sig);
    nullMax(m) = max(Dm(idx));
end
Dthr = cs_quantile(nullMax, 1-alpha);
end

% -------------------------------------------------------------------------
function q = cs_quantile(x, p)   % linear-interpolated quantile (no Statistics Toolbox)
x = sort(x(:)); n = numel(x);
if n==0, q = Inf; return; end
if n==1, q = x(1); return; end
h = (n-1)*min(max(p,0),1) + 1; lo = floor(h);
q = x(lo) + (h-lo)*(x(min(lo+1,n)) - x(lo));
end
