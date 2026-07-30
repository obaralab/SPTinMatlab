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
%   .confineD  ABSOLUTE confinement threshold (um^2/s), used when confMode='absolute'; default 0.15
%   .confMode  'drop' (default) | 'relative' | 'absolute'.
%                drop     - confined when D falls to confFrac x what it was in the PREVIOUS state.
%                           The baseline is the median of the last baseWin MOBILE localizations and
%                           freezes on entry, so a sustained slowdown stays detected.
%                relative - confined when D <= confFrac x this track's median over its whole life.
%                           Blind to a sustained slowdown: the median follows the track down.
%                absolute - the legacy fixed cut, D <= confineD, for every track alike.
%   .confFrac  drop/relative fraction; default 0.30
%   .baseWin   drop mode: mobile localizations forming the baseline; default 10
%   .minRun    a confined run must span at least this many localizations to count; default 5. This is
%              the single biggest lever on specificity — see the table below.
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
confMode= lower(string(getf(opts,'confMode','segment')));  % 'segment' | 'drop' | 'relative' | 'absolute'
minSeg  = max(2, round(getf(opts,'minSeg', 3)));    % segment mode: shortest segment, in steps
penalty = getf(opts,'penalty', 1.5);                % segment mode: LR must exceed penalty*log(n)
confFrac= getf(opts,'confFrac', 0.30);    % drop/relative: the fraction of the baseline that counts
baseWin = max(3, round(getf(opts,'baseWin', 10)));  % drop mode: mobile localizations forming the baseline
minRun  = max(1, round(getf(opts,'minRun', 5)));   % a confined run must last this many localizations

M = T.matrix; [nF, nT, ~] = size(M);
X = M(:,:,2); Y = M(:,:,3);
Dt = nan(nF, nT);
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
        % Each step is weighted by the TIME IT ACTUALLY SPANS. diff() runs over localizations, not
        % frames, so a gap-closed step covers more than one frame interval: its <r^2> is 4*D*(g*dt)
        % but dividing by 4*dt alone would attribute all of that to a single frame and inflate D by
        % the factor g. Measured on the WithER cell, 3.2% of steps span 2 frames (2,193 of 69,009),
        % so the bulk D was ~3% high on average and individual gap-closed steps ~2x high.
        %
        % The estimator is the pooled MLE over the window: summing numerator and denominator
        % separately rather than averaging per-step ratios, so each step contributes in proportion
        % to the time it observed.
        %     sum(r^2) = 4*D*dt*sum(g) + 4*sigma^2*nSteps
        %  -> D = ( sum(r^2) - 4*sigma^2*nSteps ) / ( 4 * sum(tau) ),   tau = g*dt
        % With every g = 1 this is identical to the previous mean(r^2)/(4*dt) - sigma^2/dt, so an
        % ungapped track is unchanged to the bit.
        s2 = sum(diff([x y],1,1).^2, 2);                       % single-step squared displacement (n-1)
        tcol = M(rr,j,1);                                      % frame index, or seconds under TimeUnit='seconds'
        dtau = diff(tcol);
        if all(abs(tcol - round(tcol)) < 1e-6)                 % integer-valued => frame indices
            tau = dtau * dt;
        else                                                   % already elapsed seconds
            tau = dtau;
        end
        tau(~(tau > 0)) = dt;                                  % duplicate/non-increasing frame: fall back to one interval
        for i = 1:n
            lo = max(1,i-h); hi = min(n-1,i+h);                % steps s2(lo:hi)
            ok = isfinite(s2(lo:hi)) & isfinite(tau(lo:hi));
            sg = s2(lo:hi); sg = sg(ok); tg = tau(lo:hi); tg = tg(ok);
            if ~isempty(sg) && sum(tg) > 0
                d(i) = max( (sum(sg) - 4*sigmaUm^2*numel(sg)) / (4*sum(tg)), 0 );
            end
        end
    end
    Dt(rr,j) = d;
end

% ---- confinement + state changes --------------------------------------------------------------
% Two knobs, because one absolute threshold for every track does not work. Measured on the WithER
% cell against a NULL of pure Brownian tracks matched to the real per-track D distribution and track
% lengths — where every detection is by construction a false positive:
%
%   criterion (as implemented)          real    null    enrichment
%   absolute 0.15, no minRun (OLD)       67%     45%       1.49x
%   drop 0.3x, baseWin 10, minRun 3      67%     35%       1.94x
%   drop 0.3x, baseWin 10, minRun 5      52%     22%       2.36x   <- the default
%   drop 0.3x, baseWin 10, minRun 8      35%     12%       3.00x
%   drop 0.4x, baseWin 10, minRun 5      80%     53%       1.50x
%   relative 0.3x own median, minRun 5   27%      6%       4.29x
%
% NEITHER OF THE TOP TWO DOMINATES, and the choice is scientific rather than statistical.
% 'relative' has the best aggregate specificity but is BLIND TO A SUSTAINED SLOWDOWN: a track that
% slows and stays slow drags its own median down with it, and the test stops firing. A molecule
% captured at a contact site does exactly that — it slows and remains slow while bound — so 'drop'
% is the default despite its lower enrichment, because it is the one that can see the event of
% interest. Verified on a synthetic 4x sustained slowdown: 'drop' reports one confined run of 15
% localizations, 'relative' and 'absolute' report nothing at all.
% Raise minRun to buy specificity back (minRun 8 -> 3.00x) at the cost of short events.
%
% Why not an absolute cut: it conflates "this track is slow" with "this track changed state". A
% molecule whose baseline D is 1.0 can halve twice over and never reach 0.15, while one whose
% baseline is 0.18 flickers across it on estimator noise alone.
% Why minRun: a noise dip in a 7-point rolling estimator is short, a real confinement episode is not.
% It is the main specificity lever — on the matched null it takes the default's false-positive rate
% from 41% to 12%.
[confined, stateChange] = spt_confine_flags(Dt, struct( ...
    'confMode',char(confMode),'confFrac',confFrac,'baseWin',baseWin, ...
    'confineD',confineD,'minRun',minRun,'minSeg',minSeg,'penalty',penalty, ...
    'dt',dt,'sigmaUm',sigmaUm), M);

T.Dt = Dt; T.confined = confined; T.stateChange = stateChange;
T.diffOpts = struct('dt',dt,'sigmaUm',sigmaUm,'win',win,'mode',char(mode),'confineD',confineD, ...
                    'confMode',char(confMode),'confFrac',confFrac,'baseWin',baseWin,'minRun',minRun, ...
                    'minSeg',minSeg,'penalty',penalty, ...
                    'method','rolling (native, noise-corrected)');
end

function v = getf(s,f,d),  if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
function v = getf2(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
