function spt_gap_diffusion_smoke()
%SPT_GAP_DIFFUSION_SMOKE  D must not be inflated by gap-closed steps, in EITHER estimator.
%
% THE PROBLEM. Gap-closing linking (Tool 1's "Max gap (fr)", routinely 1) lets a track skip a frame,
% so a single step can span two frame intervals. Its squared displacement is then 4*D*(2*dt), and
% dividing by 4*dt attributes a two-frame journey to one frame — D comes out DOUBLE for that step.
% The lag1 estimator was fixed for this; the msdfit mode was not, and lagged over LOCALIZATIONS
% while fitting against 4*k*dt, which is the same error by a different route.
%
% WHAT IS ASSERTED, on Brownian tracks with a KNOWN D and a controlled fraction of dropped frames:
%   1. UNGAPPED BASELINE  — both modes recover D on a track with no gaps at all.
%   2. GAPS DO NOT INFLATE — the same tracks with 25% of localizations dropped give the same D, not
%      a larger one. The bar is two-sided: a mode that over-corrects fails too.
%   3. THE CENSUS IS RIGHT — gapSteps / maxGapFr / nSteps describe the gaps actually present, so a
%      run can be checked rather than trusted.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
rng(11);
dt = 0.02; D = 0.35; nT = 60; nF = 120; sig = 0.0;   % no localization noise: isolate the gap effect

% ---- Brownian tracks, fully sampled -------------------------------------------------------------
X = nan(nF,nT); Y = nan(nF,nT); F = repmat((1:nF)', 1, nT);
step = sqrt(2*D*dt);
for j = 1:nT
    X(:,j) = cumsum([0; step*randn(nF-1,1)]);
    Y(:,j) = cumsum([0; step*randn(nF-1,1)]);
end
Tfull = mkT(F, X, Y, dt);

% ---- the same tracks with 25% of localizations dropped (gap-closed links) ------------------------
Xg = X; Yg = Y;
for j = 1:nT
    drop = false(nF,1);
    drop(2:nF-1) = rand(nF-2,1) < 0.25;
    for t = 3:nF                             % no two in a row: every gap-closed step spans exactly 2
        if drop(t) && drop(t-1), drop(t) = false; end
    end
    Xg(drop,j) = NaN; Yg(drop,j) = NaN;
end
Tgap = mkT(F, Xg, Yg, dt);

fprintf('%-10s %14s %14s %10s\n','mode','D ungapped','D with gaps','ratio');
for md = {'lag1','msdfit'}
    a = spt_track_diffusion(Tfull, struct('dt',dt,'sigmaUm',sig,'mode',md{1}));
    b = spt_track_diffusion(Tgap,  struct('dt',dt,'sigmaUm',sig,'mode',md{1}));
    Da = median(a.Dt(isfinite(a.Dt)));
    Db = median(b.Dt(isfinite(b.Dt)));
    fprintf('%-10s %14.4f %14.4f %10.3f\n', md{1}, Da, Db, Db/Da);

    % Sanity only, deliberately loose. msdfit carries a SEPARATE, pre-existing downward bias: over a
    % 7-localization window it fits four strongly correlated MSD points with a free intercept, and
    % the slope comes out ~30 % low (0.247 against a planted 0.350 here) even with no gaps and no
    % localization noise. That is a property of the estimator, not of gap handling, and it is why
    % lag1 is the default. Asserted only as "in the right ballpark" so this test stays about gaps.
    assert(Da > 0.4*D && Da < 1.6*D, ...
        '%s: D on an UNGAPPED track came out %.4f against a planted %.4f — too far off for the gap ratio below to mean anything', ...
        md{1}, Da, D);
    % Two-sided. A gap-blind estimator reads high (a 2-frame step credited to 1 frame); an
    % over-correcting one reads low. Neither is acceptable.
    assert(Db/Da < 1.20, ...
        ['%s: dropping 25%% of localizations raised D from %.4f to %.4f (x%.2f). Gap-closed steps ' ...
         'are being credited to a single frame interval — divide by the span they actually cover.'], ...
        md{1}, Da, Db, Db/Da);
    assert(Db/Da > 0.80, ...
        '%s: gaps LOWERED D from %.4f to %.4f (x%.2f) — the span correction is over-applied', ...
        md{1}, Da, Db, Db/Da);
end

% ---- the fix must BITE: the old localization-lagged msdfit inflates D on the same tracks ---------
% Reproduce what msdfit did before — lag by localization index, fit against 4*k*dt — so the
% regression carries its own proof rather than asserting a ratio nobody can attribute.
Dold = old_style_msdfit(Tgap, dt);
Dnew = median(reshape(getfield(spt_track_diffusion(Tgap, ...
        struct('dt',dt,'sigmaUm',sig,'mode','msdfit')),'Dt'), [], 1), 'omitnan');
fprintf('msdfit on gapped tracks: localization-lagged %.4f vs frame-lagged %.4f (x%.2f)\n', ...
    Dold, Dnew, Dold/Dnew);
assert(Dold > Dnew*1.10, ...
    ['the old localization-lagged msdfit gave %.4f and the frame-lagged one %.4f — barely different, ' ...
     'so this fixture is not exercising the defect the fix exists for'], Dold, Dnew);

% ---- the census must describe the gaps that are actually there -----------------------------------
g = spt_track_diffusion(Tgap, struct('dt',dt,'sigmaUm',sig));
u = spt_track_diffusion(Tfull, struct('dt',dt,'sigmaUm',sig));
assert(all(u.gapSteps == 0), 'a fully sampled track reported %d gap-closed steps', max(u.gapSteps));
assert(all(u.maxGapFr <= 1), 'a fully sampled track reported a frame span of %d', max(u.maxGapFr));
assert(sum(g.gapSteps) > 0, 'the gapped fixture reported no gap-closed steps at all');
assert(all(g.gapSteps <= g.nSteps), 'a track reported more gap steps than steps');
% Against GROUND TRUTH from the fixture itself, not a hardcoded number: the first version of this
% asserted "largest span == 2" and the census truthfully reported 8, because the drop mask allowed
% runs of consecutive drops. The census was right and the expectation was wrong — so compare with
% what the fixture actually contains.
expGap = zeros(1,nT); expMax = zeros(1,nT); expN = zeros(1,nT);
for j = 1:nT
    ff = find(isfinite(Xg(:,j)));
    dd = diff(ff);
    expN(j) = numel(dd); expGap(j) = sum(dd > 1);
    if ~isempty(dd), expMax(j) = max(dd); end
end
assert(isequal(g.gapSteps, expGap), 'gapSteps disagrees with the gaps actually in the fixture');
assert(isequal(g.maxGapFr, expMax), 'maxGapFr disagrees with the fixture');
assert(isequal(g.nSteps,   expN),   'nSteps disagrees with the fixture');
assert(max(expMax) == 2, 'the fixture should now contain only 2-frame spans, largest is %d', max(expMax));
frac = sum(g.gapSteps) / sum(g.nSteps);
assert(frac > 0.10 && frac < 0.40, 'gap fraction %.2f is nowhere near the 25%% planted', frac);
fprintf('census: %d of %d steps span >1 frame (%.0f%%), largest span %d\n', ...
    sum(g.gapSteps), sum(g.nSteps), 100*frac, max(g.maxGapFr));

fprintf('\nGAP-DIFFUSION SMOKE PASSED.\n');
end

% ================================================================================================
function Dmed = old_style_msdfit(T, dt)
% msdfit as it was: lags over LOCALIZATIONS, fitted against 4*k*dt. On an ungapped track this is
% identical to the frame-lagged version; on a gapped one it credits a multi-frame displacement to a
% single frame interval.
M = T.matrix; [~, nT, ~] = size(M); X = M(:,:,2); Y = M(:,:,3);
h = 3; acc = [];
for j = 1:nT
    rr = find(isfinite(X(:,j)) & isfinite(Y(:,j)));
    if numel(rr) < 2, continue; end
    x = X(rr,j); y = Y(rr,j); n = numel(x);
    for i = 1:n
        lo = max(1,i-h); hi = min(n,i+h); seg = [x(lo:hi) y(lo:hi)]; m = size(seg,1);
        kmax = min(4, m-1); if kmax < 2, continue; end
        ks = (1:kmax)'; msd = zeros(kmax,1);
        for k = 1:kmax, dd = seg(k+1:end,:)-seg(1:end-k,:); msd(k) = mean(sum(dd.^2,2)); end
        b = [4*ks*dt ones(kmax,1)] \ msd;
        acc(end+1,1) = max(b(1),0); %#ok<AGROW>
    end
end
Dmed = median(acc, 'omitnan');
end

function T = mkT(F, X, Y, dt)
T = struct();
T.matrix = cat(3, F, X, Y);
T.frameInterval = dt;
end
