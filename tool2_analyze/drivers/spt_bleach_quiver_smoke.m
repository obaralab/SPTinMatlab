function spt_bleach_quiver_smoke()
%SPT_BLEACH_QUIVER_SMOKE  Two things the build should say about tracks it already holds: how many
%fluorophores were in a spot and what the background under it was, and what each step looked like.
%
% WHAT IS ASSERTED:
%   1. STEPS ARE COUNTED and the step height recovered on clean traces - one drop for one emitter,
%      two for two - and the level after the last drop is that track's BACKGROUND.
%   2. THE CORRECTION USES IT: intensCorr is the intensity with each track's own background taken
%      off, so a corrected trace ends at zero wherever the background could be measured.
%   3. A TRACE THAT IS NOT A CLEAN BLEACH IS FLAGGED (mixed), not counted as fluorophores.
%   4. THE MOVIE DECAY IS FITTED when there is one (tau within 30% of the truth, and the correction
%      factor puts a late count back on the early scale) and REFUSED when there is not: a flat
%      movie gives tau = Inf and corr = 1 rather than a fitted ghost. sptPALM data is usually flat.
%   5. NO INTENSITIES = skipped cleanly, not an error.
%   6. THE QUIVER draws one arrow per step at the localization it starts from, with the step's own
%      vector and NO autoscaling (two tracks in one axes must be comparable), honours a frame
%      window, and can group arrows by speed instead of by track.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);

%% fixture ------------------------------------------------------------------------------------------
rng(3);
nF = 90; nTr = 60; bgTrue = 500; stepTrue = 120; noise = stepTrue/8;
Y = nan(nF, nTr); X = nan(nF, nTr); Yx = nan(nF, nTr); Fr = nan(nF, nTr);
nEmit = 1 + (rand(1,nTr) < 0.35);                       % most spots hold one fluorophore, some two
for j = 1:nTr
    lvl = bgTrue + nEmit(j)*stepTrue;
    y = lvl*ones(nF,1);
    ts = sort(randsample(20:nF-20, nEmit(j)));           % bleach times, well inside the track
    for q = 1:nEmit(j), y(ts(q)+1:end) = y(ts(q)+1:end) - stepTrue; end
    Y(:,j) = y + noise*randn(nF,1);
    X(:,j) = 5 + 0.05*cumsum(randn(nF,1)); Yx(:,j) = 5 + 0.05*cumsum(randn(nF,1));
    Fr(:,j) = (0:nF-1)';
end
mixedCols = 1:5;                                          % blinking: a jump UP as well as down
for j = mixedCols, Y(40:50, j) = Y(40:50, j) + 3*stepTrue; end
T = struct('file','cellA','matrix',cat(3,Fr,X,Yx),'frameInterval',0.02,'lengths',repmat(nF,nTr,1), ...
    'intens',cat(3, Y/10, Y, Y), 'vector',cat(3,diff(X,1,1),diff(Yx,1,1)));

%% (1)-(3) steps, background, the correction ------------------------------------------------------
[T2, B] = spt_bleaching(T, struct('verbose',false));
e = B(1); fit = isfinite(e.nSteps);
clean = fit & ~e.mixed;
assert(mean(e.nSteps(clean)' == nEmit(clean)) > 0.85, ...
    'the step count should match the number of emitters on clean traces (%.0f%% did)', 100*mean(e.nSteps(clean)' == nEmit(clean)));
assert(abs(e.medianStepHeight - stepTrue) < 0.15*stepTrue, 'step height %.0f, truth %d', e.medianStepHeight, stepTrue);
assert(abs(e.movieBg - bgTrue) < 0.05*bgTrue, 'background %.0f, truth %d', e.movieBg, bgTrue);
assert(all(e.mixed(mixedCols)), 'a trace that jumps up is not a bleach and must be flagged');
assert(mean(e.mixed(setdiff(1:nTr, mixedCols))) < 0.15, 'clean traces should not be flagged mixed');
tail = T2.intensCorr(end-9:end, clean);
assert(abs(median(tail(:))) < 0.4*stepTrue, ...
    'after subtracting each track''s background a corrected trace should end near zero (median %.0f)', median(tail(:)));
assert(abs(e.singleFrac - mean(nEmit == 1)) < 0.2, 'single-step share %.2f vs %.2f of spots with one emitter', e.singleFrac, mean(nEmit == 1));

%% (4) the movie decay, and refusing to fit one that is not there ----------------------------------
tauTrue = 300; nT2 = 900; nF2 = 1200;
life = min(nF2, max(5, round(exprnd(tauTrue, nT2, 1))));
m = max(life); F2 = nan(m, nT2); XY = nan(m, nT2);
for j = 1:nT2, F2(1:life(j), j) = (0:life(j)-1)'; XY(1:life(j), j) = 5; end
Tdec = struct('file','decay','matrix',cat(3,F2,XY,XY),'frameInterval',0.02,'lengths',life, ...
    'intens',cat(3,XY,XY,XY));
[~, Bd] = spt_bleaching(Tdec, struct('verbose',false));
assert(abs(Bd.tauFrames - tauTrue) < 0.3*tauTrue, 'decay tau %.0f frames, truth %d', Bd.tauFrames, tauTrue);
assert(Bd.corr(end) > Bd.corr(1) && Bd.corr(1) == 1, 'the correction should grow over the movie and start at 1');
late = round(0.8*numel(Bd.frames));
assert(abs(Bd.counts(late)*Bd.corr(late) - (Bd.A + Bd.c)) < 0.35*(Bd.A + Bd.c), ...
    'a late count times its correction should land near the start-of-movie level');
Tflat = Tdec; Tflat.matrix(:,:,1) = repmat((0:m-1)', 1, nT2); Tflat.matrix(:,:,2) = 5*ones(m, nT2);
Tflat.matrix(:,:,3) = Tflat.matrix(:,:,2); Tflat.intens = cat(3, Tflat.matrix(:,:,2), Tflat.matrix(:,:,2), Tflat.matrix(:,:,2));
[~, Bf] = spt_bleaching(Tflat, struct('verbose',false));
assert(isinf(Bf.tauFrames) && all(Bf.corr == 1), 'a movie that does not decay must not be given a decay');

%% (5) no intensities ------------------------------------------------------------------------------
Tno = rmfield(T, 'intens');
[~, Bn] = spt_bleaching(Tno, struct('verbose',false));
assert(isempty(Bn), 'a cell with no intensities should be skipped, not fitted');

%% (6) the quiver ----------------------------------------------------------------------------------
f = figure('Visible','off'); cleanup = onCleanup(@() close(f)); ax = axes(f);
h = spt_quiver_tracks(ax, T, 1:5);
assert(numel(h) == 5, 'one quiver per track, got %d', numel(h));
assert(numel(h(1).UData) == nF-1, 'a track of %d localizations has %d steps, got %d arrows', nF, nF-1, numel(h(1).UData));
assert(max(abs(h(1).UData(:) - T.vector(:,1,1))) < 1e-12, 'the arrows are not the track''s own step vectors (autoscaling on?)');
assert(strcmp(ax.YDir, 'reverse'), 'the plot should keep the image convention');
h2 = spt_quiver_tracks(ax, T, 1:5, struct('frames', [10 29]));
assert(numel(h2(1).UData) == 20, 'a frame window should cut the arrows down (got %d)', numel(h2(1).UData));
h3 = spt_quiver_tracks(ax, T, 1:5, struct('colorBy','speed','nBins',4));
assert(numel(h3) == 4, 'speed colouring should group the arrows into 4 classes, got %d', numel(h3));
assert(sum(arrayfun(@(q) numel(q.UData), h3)) == 5*(nF-1), 'every arrow should still be drawn once');

fprintf(['bleaching: %.0f%% of clean traces counted right, step %.0f (truth %d), background %.0f (truth %d), ' ...
         '%d mixed flagged; decay tau %.0f (truth %d), flat movie refused\n'], ...
    100*mean(e.nSteps(clean)' == nEmit(clean)), e.medianStepHeight, stepTrue, e.movieBg, bgTrue, nnz(e.mixed), Bd.tauFrames, tauTrue);
fprintf('quiver: one per track, %d arrows each, true lengths, frame window and speed grouping\n', nF-1);
fprintf('\nBLEACH-QUIVER SMOKE PASSED.\n');
end
