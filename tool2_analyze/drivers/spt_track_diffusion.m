function T = spt_track_diffusion(T, opts)
%SPT_TRACK_DIFFUSION  Per-localization instantaneous diffusion D(t) + confinement state for every
%track in a TrackStruct — computed after curation, INDEPENDENT of contact sites, so Tool 3 can use
%diffusion state to help identify sites (confinement + fast->slow state changes).
%
%   T = spt_track_diffusion(T)
%   T = spt_track_diffusion(T, opts)
%
% This is the native-MATLAB equivalent of run_step.py's noise-corrected rolling estimator (the STEP
% "fallback"): at each localization, the local mean single-step MSD minus the localization-noise floor
%     D = <dr^2>/(4 dt) - sigma^2/dt        (2D; <dr^2> = 4 D dt + 4 sigma^2), floored at 0.
% Real STEP can later replace T.Dt via the Python bridge (run_step.py --weights) with zero downstream
% change — the fields below are the contract.
%
% opts (all optional):
%   .dt        frame interval (s); default T.frameInterval or 0.02
%   .sigmaUm   localization precision (um) for the noise floor; default 0.030
%   .win       rolling window in LOCALIZATIONS (odd); default 7
%   .mode      'lag1' (noise-corrected single-step, default) | 'msdfit' (local MSD slope)
%   .confineD  confinement threshold (um^2/s): D<=this is "confined"; default 0.15
%
% ADDS to T (aligned with T.matrix [nF x nT x 3] = frame,x,y in um; NaN where no localization):
%   .Dt          [nF x nT]  per-localization D (um^2/s)
%   .confined    [nF x nT]  logical, D <= confineD
%   .stateChange [nF x nT]  logical, a fast->slow ENTRY (rising edge into a confined run) — a capture event
%   .diffOpts    struct of the parameters used (provenance)

if nargin < 2 || ~isstruct(opts), opts = struct(); end
dt      = getf(opts,'dt', getf2(T,'frameInterval',0.02));
sigmaUm = getf(opts,'sigmaUm', 0.030);
win     = max(3, round(getf(opts,'win', 7)));
mode    = lower(string(getf(opts,'mode','lag1')));
confineD= getf(opts,'confineD', 0.15);

M = T.matrix; [nF, nT, ~] = size(M);
X = M(:,:,2); Y = M(:,:,3);
Dt = nan(nF, nT);
noise = sigmaUm^2 / dt;                       % localization-noise floor to subtract (lag1)
h = max(1, floor(win/2));

for j = 1:nT
    rr = find(isfinite(X(:,j)) & isfinite(Y(:,j)));   % localization rows of this track, frame order
    if numel(rr) < 2, continue; end
    x = X(rr,j); y = Y(rr,j); n = numel(x);
    d = nan(n,1);
    if startsWith(mode,'msd')
        for i = 1:n
            lo = max(1,i-h); hi = min(n,i+h); seg = [x(lo:hi) y(lo:hi)]; m = size(seg,1);
            kmax = min(4, m-1); if kmax < 2, continue; end
            ks = (1:kmax)'; msd = zeros(kmax,1);
            for k = 1:kmax, dd = seg(k+1:end,:)-seg(1:end-k,:); msd(k) = mean(sum(dd.^2,2)); end
            A = [4*ks*dt ones(kmax,1)]; b = A\msd;             % msd = 4 D (k dt) + b
            d(i) = max(b(1), 0);
        end
    else
        s2 = sum(diff([x y],1,1).^2, 2);                       % single-step squared displacement (n-1)
        for i = 1:n
            lo = max(1,i-h); hi = min(n-1,i+h);                % steps s2(lo:hi)
            seg = s2(lo:hi); seg = seg(isfinite(seg));
            if ~isempty(seg), d(i) = max(mean(seg)/(4*dt) - noise, 0); end
        end
    end
    Dt(rr,j) = d;
end

confined = Dt <= confineD;                     % NaN<=x is false, so gaps are not "confined"
stateChange = false(nF, nT);
for j = 1:nT
    rr = find(isfinite(Dt(:,j))); if numel(rr) < 2, continue; end
    c = confined(rr,j);
    edge = [false; c(2:end) & ~c(1:end-1)];    % rising edge: mobile -> confined (a fast->slow entry)
    stateChange(rr(edge), j) = true;
end

T.Dt = Dt; T.confined = confined; T.stateChange = stateChange;
T.diffOpts = struct('dt',dt,'sigmaUm',sigmaUm,'win',win,'mode',char(mode),'confineD',confineD, ...
                    'method','rolling (native, noise-corrected)');
end

function v = getf(s,f,d),  if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
function v = getf2(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
