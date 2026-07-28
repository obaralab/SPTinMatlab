function sw = spt_msd_sweep(msd, dt, maxFrac)
%SPT_MSD_SWEEP  Diffusion coefficient D and fit R² as a function of the fit-window size.
%
%   sw = spt_msd_sweep(msd, dt)              % all windows (2 lags .. all lags)
%   sw = spt_msd_sweep(msd, dt, maxFrac)     % cap at maxFrac of the lags (0..1)
%
% For a track's MSD (one value per lag), fit MSD = 4·D·τ over the first m lags for every m and report
% D and the fit R². This exposes how the diffusion estimate depends on how many MSD points you fit —
% D is stable + R²≈1 over the short, well-sampled lags, then drifts / R² drops where the MSD curves
% (confinement, directed motion) or gets noisy. Use it to pick a fit window per track.
%
% sw.npts (m), sw.frac (100·m/nLags), sw.D (µm²/s), sw.R2 — column vectors, one row per window.
if nargin < 3 || isempty(maxFrac), maxFrac = 1.0; end
sw = struct('npts',[],'frac',[],'D',[],'R2',[]);
if isempty(msd), return; end
lagN = find(isfinite(msd),1,'last'); if isempty(lagN) || lagN < 2, return; end
lag = (1:lagN)'*dt; y = msd(1:lagN);
mMax = max(2, min(lagN, floor(maxFrac*lagN)));
npts = (2:mMax)'; D = nan(size(npts)); R2 = nan(size(npts));
for i = 1:numel(npts)
    m = npts(i);
    pf = polyfit(lag(1:m), y(1:m), 1); D(i) = pf(1)/4;
    fit = polyval(pf, lag(1:m));
    sst = sum((y(1:m) - mean(y(1:m))).^2);
    if sst > 0, R2(i) = 1 - sum((y(1:m) - fit).^2)/sst; else, R2(i) = 1; end
end
sw.npts = npts; sw.frac = 100*npts/lagN; sw.D = D; sw.R2 = R2;
end
