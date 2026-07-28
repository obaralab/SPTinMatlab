function r = spt_fit_msd(msd, dt, spec)
%SPT_FIT_MSD  Linear fit MSD(τ) = 4·D·τ + b over the first m leading lags; D = slope/4.
%
%   r = spt_fit_msd(msd, dt, fracPct)   % FIXED window: fit the first fracPct% of the lags (back-compat)
%   r = spt_fit_msd(msd, dt, spec)      % spec struct selects the window per track:
%       spec.mode = 'fixed'    : m = fracPct% of lags            (.fracPct)
%                 = 'firstn'   : m = a fixed number of lags      (.nPts)
%                 = 'adaptive' : the LARGEST window (≥minPts, ≤maxFrac) whose fit still has R² ≥ r2thr —
%                                so a track that stays linear uses more lags, one that curves uses fewer
%                                (.maxFrac 0..1, .r2thr, .minPts). Falls back to the most-linear window.
%
% Returns .D (µm²/s), .R2, .b (τ→0 intercept, µm²), .sigLocUm = sqrt(max(b,0))/2 (localization
% precision, a caveat — it is fit-window dependent), .nPts / .fracUsed (the window actually fit), and
% .lag/.y/.fitX/.fitY for plotting.
r = struct('D',NaN,'R2',NaN,'b',NaN,'sigLocUm',NaN,'nPts',NaN,'fracUsed',NaN,'lag',[],'y',[],'fitX',[],'fitY',[]);
if isempty(msd), return; end
lagN = find(isfinite(msd),1,'last'); if isempty(lagN) || lagN < 2, return; end
lag = (1:lagN)'*dt; y = msd(1:lagN); r.lag = lag; r.y = y;

if nargin < 3 || isempty(spec), spec = 50; end
if isnumeric(spec)
    m = round(lagN*spec/100);
elseif isstruct(spec)
    switch lower(getf_(spec,'mode','fixed'))
        case 'firstn'
            m = getf_(spec,'nPts',4);
        case 'adaptive'
            maxFrac = getf_(spec,'maxFrac',0.6); r2thr = getf_(spec,'r2thr',0.95); minPts = getf_(spec,'minPts',3);
            sw = spt_msd_sweep(msd, dt, maxFrac); m = minPts;
            if ~isempty(sw.npts)
                ok = sw.R2 >= r2thr & sw.npts >= minPts;
                if any(ok), m = max(sw.npts(ok));                 % largest window still linear enough
                else,       [~,ix] = max(sw.R2); m = sw.npts(ix); % else the most-linear window
                end
            end
        otherwise
            m = round(lagN*getf_(spec,'fracPct',50)/100);
    end
else
    m = round(lagN*0.5);
end
m = max(2, min(m, lagN));

pf = polyfit(lag(1:m), y(1:m), 1); r.D = pf(1)/4;
r.b = pf(2); r.sigLocUm = sqrt(max(pf(2),0))/2;
r.fitX = lag(1:m); r.fitY = polyval(pf, lag(1:m));
r.nPts = m; r.fracUsed = 100*m/lagN;
sst = sum((y(1:m) - mean(y(1:m))).^2);
if sst > 0, r.R2 = 1 - sum((y(1:m) - r.fitY).^2)/sst; end
end

% -------------------------------------------------------------------------
function v = getf_(s, f, d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
