function [T, B] = spt_bleaching(T, opts)
%SPT_BLEACHING  Photobleaching, read two ways: per track (how many fluorophores, and what the
%background under them is) and per movie (how the signal decays, so early and late are comparable).
%
%   [T, B] = spt_bleaching(T)            % T is a TrackStruct; every cell is analysed
%   [T, B] = spt_bleaching(T, opts)
%
% Needs T(i).intens, the per-localization intensity the build attaches from the spots CSV
% (pages 1/2/3 = MEAN / MAX / TOTAL). Without it a cell is skipped and says so.
%
% PER TRACK - STEPS AND BACKGROUND. A single fluorophore bleaches in one go: its trace is a
% plateau, one drop, then background. spt_pbsa_steps (Kalafut-Visscher + SIC) finds those drops
% without being told how many to expect. What comes back per track:
%   nSteps        drops kept. 1 = one emitter, 2+ = more than one thing in the spot, 0 = it never
%                 bleached inside the track (common for short tracks - then there is no plateau to
%                 read a background from, and bg is NaN).
%   stepHeight    median drop height: the intensity of ONE fluorophore, in camera units.
%   bg            the level AFTER the last drop - the background under that molecule: camera
%                 offset plus whatever the cell contributes there. This is the correction.
%   intensCorr    T(i).intensCorr, the intensity page with each track's own bg subtracted, so
%                 intensities from different parts of the cell are on one scale. Where bg could
%                 not be measured the movie's median track bg is used instead (bgSrc says which).
%   mixed         true when the fitted heights are not all drops - blinking, a crossing, a linkage
%                 error. Counting those as fluorophores is how stoichiometry goes wrong, so they
%                 are flagged rather than averaged in.
%
% PER MOVIE - DECAY AND THE COMPARABILITY CORRECTION. Localizations get rarer as the movie runs,
% so a density measured late is not the same quantity as one measured early - which matters
% directly here, because contact sites are picked on per-window densities. The number of
% localizations per frame is fitted with N(t) = A*exp(-t/tau) + c (least squares over a log grid of
% tau; no toolbox needed), and the result is:
%   corr(t) = N_fit(0) / N_fit(t)     multiply a count (or a density) measured at frame t by this
%                                     and it is on the scale of the start of the movie.
% tau is reported in frames and seconds. A movie that does not decay gives tau = Inf and corr = 1,
% which is the honest answer rather than a fitted ghost.
%
% opts: .page (3) intensity page to use: 1 MEAN, 2 MAX, 3 TOTAL. TOTAL is the one that bleaches in
%                 clean steps; MEAN is fine when the spot size is fixed.
%       .minLen (10) localizations a track needs before it is fitted
%       .minStep ('auto') passed to spt_pbsa_steps; a number sets the height floor by hand
%       .correct (true) write T(i).intensCorr
%       .verbose (true)
%
% OUTPUT  T gains, per cell: .bleach (everything below) and .intensCorr (when .correct).
%   B(i): file, nTracks, nFitted, nSteps [nTracks x 1], stepHeight, bg, bgSrc {'track'|'movie'},
%         mixed, firstBleachFrame, singleFrac (share of fitted tracks with exactly one step),
%         movieBg, tauFrames, tauSeconds, A, c, corr [nFrames x 1], frames, counts, r2, page.

if nargin < 2 || ~isstruct(opts), opts = struct(); end
page    = getf(opts, 'page', 3);
minLen  = getf(opts, 'minLen', 10);
minStep = getf(opts, 'minStep', 'auto');
doCorr  = getf(opts, 'correct', true);
verb    = getf(opts, 'verbose', true);

B = struct([]);
for i = 1:numel(T)
    [~, base] = fileparts(char(T(i).file));
    In = getf2(T(i), 'intens', []);
    if isempty(In) || size(In,3) < page
        if verb, fprintf('  %-46s no intensities (build with AttachCSV) - skipped\n', base); end
        continue;
    end
    Y = In(:,:,page);
    Fr = T(i).matrix(:,:,1);
    nTr = size(Y,2);
    nSteps = nan(nTr,1); stepHeight = nan(nTr,1); bg = nan(nTr,1);
    mixed = false(nTr,1); firstBleach = nan(nTr,1);
    for j = 1:nTr
        y = Y(:,j); ok = isfinite(y);
        if nnz(ok) < minLen, continue; end
        R = spt_pbsa_steps(y(ok), 'MinStep', minStep);
        nSteps(j) = R.k;
        if R.k > 0
            stepHeight(j) = median(abs(R.heights));
            bg(j) = R.levels(end);                         % the plateau after the last drop
            mixed(j) = any(R.heights > 0);                 % not a clean bleach
            f = Fr(ok, j); firstBleach(j) = f(min(R.idx(1)+1, numel(f)));
        end
    end
    fitted = isfinite(nSteps);
    movieBg = median(bg(isfinite(bg)), 'omitnan');
    bgSrc = repmat({'track'}, nTr, 1); bgSrc(~isfinite(bg)) = {'movie'};
    bgUse = bg; bgUse(~isfinite(bgUse)) = movieBg;

    % ---- per movie: how the number of localizations decays ----------------------------------------
    [frames, counts] = countsPerFrame(Fr);
    [A, tau, c, r2] = fitDecay(frames, counts);
    corr = ones(numel(frames),1);
    if isfinite(tau)
        n0 = A + c; nt = A*exp(-frames/tau) + c;
        corr = n0 ./ max(nt, eps);
    end

    e = struct('file', base, 'cellIndex', i, 'page', page, 'nTracks', nTr, 'nFitted', nnz(fitted), ...
        'nSteps', nSteps, 'stepHeight', stepHeight, 'bg', bg, 'bgSrc', {bgSrc}, 'mixed', mixed, ...
        'firstBleachFrame', firstBleach, ...
        'singleFrac', mean(nSteps(fitted) == 1), 'movieBg', movieBg, ...
        'medianStepHeight', median(stepHeight, 'omitnan'), ...
        'tauFrames', tau, 'tauSeconds', tau * getf2(T(i),'frameInterval',NaN), ...
        'A', A, 'c', c, 'r2', r2, 'corr', corr, 'frames', frames, 'counts', counts);
    if isempty(B), B = e; else, B(end+1) = e; end %#ok<AGROW>
    T(i).bleach = e;
    if doCorr, T(i).intensCorr = Y - repmat(bgUse(:)', size(Y,1), 1); end
    if verb
        fprintf('  %-46s %4d/%4d tracks fitted, %.0f%% single-step, step %.0f, bg %.0f, tau %.0f frames (%.1f s)\n', ...
            base, nnz(fitted), nTr, 100*e.singleFrac, e.medianStepHeight, movieBg, tau, e.tauSeconds);
    end
end
if verb && ~isempty(B)
    fprintf('spt_bleaching: %d cell(s); median single-step share %.0f%%, median tau %.0f frames\n', ...
        numel(B), 100*median([B.singleFrac]), median([B.tauFrames]));
end
end

% =================================================================================================
function [frames, counts] = countsPerFrame(Fr)
f = Fr(isfinite(Fr));
if isempty(f), frames = (0:0)'; counts = 0; return; end
edges = (min(f):max(f)+1)' - 0.5;
counts = histcounts(f, edges)';
frames = (min(f):max(f))';
end

function [A, tau, c, r2] = fitDecay(frames, counts)
% N(t) = A*exp(-t/tau) + c, fitted by scanning tau on a log grid and solving the linear part
% exactly for each one. No optimisation toolbox, no starting guess to get wrong.
A = NaN; tau = Inf; c = mean(counts); r2 = 0;
n = numel(counts);
if n < 10 || all(counts == counts(1)), return; end
span = max(frames) - min(frames);
taus = logspace(log10(max(span/200, 1)), log10(span*5), 60);
best = inf; t0 = frames - min(frames);
for q = 1:numel(taus)
    X = [exp(-t0/taus(q)), ones(n,1)];
    b = X \ counts;
    r = counts - X*b;
    s = sum(r.^2);
    if s < best && b(1) > 0, best = s; A = b(1); c = b(2); tau = taus(q); end
end
if ~isfinite(A), A = NaN; tau = Inf; c = mean(counts); r2 = 0; return; end
sst = sum((counts - mean(counts)).^2);
r2 = 1 - best/max(sst, eps);
if r2 < 0.1, A = NaN; tau = Inf; c = mean(counts); end   % no decay worth correcting for
end

function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
function v = getf2(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
