function [confined, stateChange] = spt_confine_flags(Dt, opts, M)
%SPT_CONFINE_FLAGS  Confinement + state-change flags from a per-localization D(t) matrix.
%
%   [confined, stateChange] = spt_confine_flags(Dt, opts)
%
% Dt is [nF x nT], NaN where the track has no localization. Both outputs match its shape.
%
% This is the ONE implementation of the rule. spt_track_diffusion calls it at build time, and the
% Build & QC tab calls it again when you change a setting — re-deriving from the stored Dt instead of
% re-rolling the estimator. They used to be separate copies, and they had already drifted: the app
% still had a sliding baseline after the driver moved to a frozen one, so re-deriving a build
% silently produced different flags from building it.
%
% opts:
%   .confMode  'segment' (default) | 'drop' | 'relative' | 'absolute'
%   .confFrac  fraction of the baseline that counts as confined; default 0.30
%   .baseWin   drop mode: mobile localizations forming the baseline; default 10
%   .confineD  absolute mode: fixed threshold in um^2/s; default 0.15
%   .minRun    a confined run must span this many localizations to count; default 5
%   .minSeg    segment mode: shortest segment the splitter may produce, in STEPS; default 3
%   .penalty   segment mode: split accepted when the likelihood ratio exceeds penalty*log(n);
%              default 1.5. Higher = fewer, more confident segments.
%   .dt/.sigmaUm  segment mode: needed to convert a segment's mean squared step into D
%
% M is the [nF x nT x 3] (frame,x,y) matrix. Required for 'segment', ignored otherwise.
%
% See spt_track_diffusion's header for the measured comparison of the three modes against a matched
% Brownian null, and for why 'drop' is the default despite 'relative' scoring better in aggregate.

if nargin < 2 || ~isstruct(opts), opts = struct(); end
mode    = lower(char(gf(opts,'confMode','segment')));
frac    = gf(opts,'confFrac', 0.30);
baseWin = max(3, round(gf(opts,'baseWin', 10)));
confineD= gf(opts,'confineD', 0.15);
% Segment mode already enforces a minimum length through minSeg, so applying minRun on top would
% double-filter and reject exactly the short segments the splitter was allowed to find.
if strcmp(mode,'segment'), minRun = max(1, round(gf(opts,'minRun', 1)));
else,                      minRun = max(1, round(gf(opts,'minRun', 5))); end

[nF, nT] = size(Dt);
confined = false(nF, nT);

switch mode
    case 'segment'
        % Segment the RAW squared-step series, then label segments — no smoothing anywhere.
        %
        % The rolling estimator behind Dt averages 7 localizations, which blurs every transition;
        % that blur is what made the drop rule's persistence requirement so marginal. Working on the
        % steps themselves locates a change sharply.
        %
        % For 2D Brownian motion with localization noise the single squared step r^2 = dx^2+dy^2 is
        % EXPONENTIAL with mean mu = 4*D*dt + 4*sigma^2, so a change in D is a change in an
        % exponential mean. On a block the MLE of mu is the block mean and the log-likelihood at the
        % MLE is -n(1+log mu), so splitting a block of n at k has likelihood ratio
        %     LR = 2*( n*log(mu) - k*log(mu1) - (n-k)*log(mu2) )
        % which is exact, has no tuning beyond the acceptance penalty, and needs no distributional
        % approximation. Binary segmentation recurses while LR > penalty*log(n).
        %
        % Segments are then compared IN D, not in mu: the noise floor 4*sigma^2 does not scale with
        % D, so a genuine 4x drop in D is only a ~3.5x drop in mu and would fall the wrong side of a
        % 0.30 ratio test. Each segment is confined when its D falls to frac x the D of the last
        % MOBILE segment — the same "previous state" semantics as 'drop', but on segment means
        % rather than a sliding window.
        if nargin < 3 || isempty(M)
            error('spt_confine_flags:needMatrix', ...
                  '''segment'' mode needs the [nF x nT x 3] matrix; pass it as the third argument.');
        end
        dtS  = gf(opts,'dt', 0.02);
        sigS = gf(opts,'sigmaUm', 0.030);
        minSeg  = max(2, round(gf(opts,'minSeg', 3)));
        penalty = gf(opts,'penalty', 1.5);
        X = M(:,:,2); Y = M(:,:,3);
        for j = 1:nT
            rr = find(isfinite(X(:,j)) & isfinite(Y(:,j)));
            if numel(rr) < 2*minSeg + 2, continue; end
            r2 = diff(X(rr,j)).^2 + diff(Y(rr,j)).^2;      % one per STEP (numel(rr)-1)
            cps = seg_exp(r2, minSeg, penalty);
            cs  = label_segments(r2, cps, frac, dtS, sigS);
            % a confined STEP means the molecule was slow crossing into its second localization
            c = false(numel(rr),1); c(2:end) = cs;
            confined(rr,j) = c;
        end
    case 'drop'
        % Confined when D falls to frac x what it was in the PREVIOUS state. The baseline is the
        % median of the last baseWin MOBILE localizations and FREEZES on entry — a baseline that
        % keeps sliding averages in the new slow values, catches up within baseWin points, and a
        % molecule that slows and stays slow registers only a flicker at the transition. Measured on
        % a synthetic 4x sustained slowdown: sliding gave confined runs of [3 1 1 1], frozen gives a
        % single run of 15. Recovery is hysteretic at 1.5x the entry threshold so noise cannot
        % chatter the state.
        for j = 1:nT
            rr = find(isfinite(Dt(:,j))); if numel(rr) <= baseWin, continue; end
            d = Dt(rr,j); n = numel(d); c = false(n,1);
            mob = d(1:baseWin); base = median(mob); state = false;
            for i = baseWin+1:n
                if ~state
                    if base > 0 && d(i) <= frac*base
                        state = true;                        % enter: the baseline freezes here
                    else
                        mob(end+1) = d(i); %#ok<AGROW>       % still mobile: baseline tracks it
                        if numel(mob) > baseWin, mob = mob(end-baseWin+1:end); end
                        base = median(mob);
                    end
                elseif base > 0 && d(i) > 1.5*frac*base
                    state = false;                           % recover, and restart the baseline
                    mob = d(max(1,i-baseWin+1):i); base = median(mob);
                end
                c(i) = state;
            end
            confined(rr,j) = c;
        end
    case 'relative'
        for j = 1:nT
            d = Dt(:,j); f = isfinite(d);
            if ~any(f), continue; end
            m = median(d(f));
            if m > 0, confined(f,j) = d(f) <= frac*m; end
        end
    otherwise
        confined = Dt <= confineD;                 % NaN<=x is false, so gaps are not "confined"
end

% Drop confined runs shorter than minRun, then take the rising edges of what survives.
stateChange = false(nF, nT);
for j = 1:nT
    rr = find(isfinite(Dt(:,j))); if numel(rr) < 2, continue; end
    c = confined(rr,j);
    if minRun > 1, c = drop_short_runs(c, minRun); confined(rr,j) = c; end
    edge = [false; c(2:end) & ~c(1:end-1)];        % rising edge: mobile -> confined
    stateChange(rr(edge), j) = true;
end
end

function cps = seg_exp(r2, minSeg, pen)
% Exact-likelihood binary segmentation of an exponential series. Returns the start index of each
% new segment (so [] means one segment).
cps = sort(recurse(1, numel(r2)));
    function c = recurse(a, b)
        c = []; n = b - a + 1;
        if n < 2*minSeg, return; end
        x = r2(a:b); mu = mean(x); if ~(mu > 0), return; end
        cs = cumsum(x); best = -inf; bk = 0;
        for k = minSeg:(n-minSeg)
            m1 = cs(k)/k; m2 = (cs(end)-cs(k))/(n-k);
            if m1 <= 0 || m2 <= 0, continue; end
            lr = 2*( n*log(mu) - k*log(m1) - (n-k)*log(m2) );
            if lr > best, best = lr; bk = k; end
        end
        if bk > 0 && best > pen*log(n)
            c = [recurse(a, a+bk-1), a+bk, recurse(a+bk, b)];
        end
    end
end

function c = label_segments(r2, cps, frac, dt, sig)
% Confined when a segment's D falls to frac x the D of the last MOBILE segment.
edges = [1, cps(:)', numel(r2)+1];
c = false(numel(r2),1); prev = NaN;
for s = 1:numel(edges)-1
    idx = edges(s):edges(s+1)-1;
    if isempty(idx), continue; end
    D = max(mean(r2(idx))/(4*dt) - sig^2/dt, 0);        % mu = 4*D*dt + 4*sigma^2
    if ~isnan(prev) && prev > 0 && D <= frac*prev
        c(idx) = true;
    else
        prev = D;                                        % baseline = the last mobile segment
    end
end
end

function c = drop_short_runs(c, minRun)
i = 1; n = numel(c);
while i <= n
    if ~c(i), i = i + 1; continue; end
    j = i; while j < n && c(j+1), j = j + 1; end
    if (j - i + 1) < minRun, c(i:j) = false; end
    i = j + 1;
end
end

function v = gf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
