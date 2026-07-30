function [confined, stateChange] = spt_confine_flags(Dt, opts)
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
%   .confMode  'drop' (default) | 'relative' | 'absolute'
%   .confFrac  fraction of the baseline that counts as confined; default 0.30
%   .baseWin   drop mode: mobile localizations forming the baseline; default 10
%   .confineD  absolute mode: fixed threshold in um^2/s; default 0.15
%   .minRun    a confined run must span this many localizations to count; default 5
%
% See spt_track_diffusion's header for the measured comparison of the three modes against a matched
% Brownian null, and for why 'drop' is the default despite 'relative' scoring better in aggregate.

if nargin < 2 || ~isstruct(opts), opts = struct(); end
mode    = lower(char(gf(opts,'confMode','drop')));
frac    = gf(opts,'confFrac', 0.30);
baseWin = max(3, round(gf(opts,'baseWin', 10)));
confineD= gf(opts,'confineD', 0.15);
minRun  = max(1, round(gf(opts,'minRun', 5)));

[nF, nT] = size(Dt);
confined = false(nF, nT);

switch mode
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
