function spt_statechange_smoke()
%SPT_STATECHANGE_SMOKE  A "state change" must beat chance, and be measured relative to each track.
%
% THE PROBLEM THIS FIXES
%   Confinement was one absolute cut — D <= 0.15 µm²/s — applied to every track, with no requirement
%   that the confined stretch last. That conflates two different things: a molecule that is SLOW
%   (baseline below the cut, permanently "confined") and one that CHANGED STATE (slowed relative to
%   its own behaviour). It is also unguarded against noise in the 7-point rolling estimator.
%
%   Measured on the WithER cell against a null of pure Brownian tracks matched to the real per-track
%   D distribution and track lengths — where every detection is by construction a false positive:
%
%     criterion (as implemented)          real    null    enrichment
%     absolute 0.15, no minRun (OLD)       67%     45%       1.49x
%     drop 0.3x, baseWin 10, minRun 5      52%     22%       2.36x   <- the default
%     drop 0.3x, baseWin 10, minRun 8      35%     12%       3.00x
%     relative 0.3x own median, minRun 5   27%      6%       4.29x
%
%   'relative' scores best in aggregate but is blind to a SUSTAINED slowdown — the very thing a
%   capture event looks like — which is why 'drop' is the default. Assertion (1) pins that down.
%
% WHAT IS ASSERTED, on synthetic tracks where the truth is known by construction:
%   1. RELATIVE FINDS WHAT ABSOLUTE MISSES — a fast track that halves its D is a real state change,
%      but never crosses an absolute cut set for slower molecules.
%   2. RELATIVE IGNORES A UNIFORMLY SLOW TRACK — which an absolute cut calls confined for its whole
%      length, reporting a "state change" where nothing changed.
%   3. PERSISTENCE BEATS CHANCE — against a matched Brownian null with no state change anywhere, the
%      default settings must be markedly more specific than the same rule without persistence.
%   4. PROVENANCE — the criterion actually used is recorded in diffOpts.
%
% Pure synthetic; never reads or writes WithER.
here = fileparts(mfilename('fullpath')); addpath(here);

dt = 0.02006; sig = 0.030;

%% (1) a FAST track that genuinely slows down --------------------------------------------------
% D goes 1.0 -> 0.25 halfway. That is a real, four-fold slowdown — and it never reaches 0.15, so an
% absolute cut set for slower molecules cannot see it at all.
rng(3);
n = 120; half = n/2;
T1 = one_track(make_xy([repmat(1.0,half,1); repmat(0.25,n-half,1)], dt, sig), dt);
dropOn = spt_track_diffusion(T1, o(dt,sig,'drop',0.30,5));
relOn  = spt_track_diffusion(T1, o(dt,sig,'relative',0.30,5));
absOn  = spt_track_diffusion(T1, o(dt,sig,'absolute',0.15,5));
nDrop = sum(dropOn.stateChange(:)); nRel = sum(relOn.stateChange(:)); nAbs = sum(absOn.stateChange(:));
fprintf('fast track slowing 1.0 -> 0.25 and STAYING slow:  drop %d · relative %d · absolute %d\n', ...
    nDrop, nRel, nAbs);
% This is the case that motivates 'drop' being the default. The absolute cut cannot see it because D
% never reaches 0.15. The relative-to-own-median cut cannot see it either, because a track that
% spends half its life slow has a median BETWEEN the two states, and 0.3x that sits below the slow
% state. Only a preceding baseline still remembers the fast stretch.
assert(nDrop >= 1, 'the drop rule missed a sustained four-fold slowdown — the case it exists for');
assert(nAbs == 0, 'the absolute rule was expected to miss this (D never reaches 0.15) but found %d', nAbs);
assert(nRel == 0, ...
    ['the relative-to-median rule found %d here. It is expected to miss a SUSTAINED slowdown, ' ...
     'because the median moves with the track — if this now fires, re-check which rule is default.'], nRel);

%% (2) a uniformly SLOW track that never changes ------------------------------------------------
% Constant D = 0.08, below the absolute cut for its whole length. Nothing changes, so nothing should
% be reported — but an absolute cut calls every localization confined.
rng(4);
T2 = one_track(make_xy(repmat(0.08,n,1), dt, sig), dt);
drop2= spt_track_diffusion(T2, o(dt,sig,'drop',0.30,5));
abs2 = spt_track_diffusion(T2, o(dt,sig,'absolute',0.15,5));
fprintf('uniformly slow track (D=0.08): drop %.0f%% confined, absolute %.0f%% confined\n', ...
    100*mean(drop2.confined(isfinite(drop2.Dt))), 100*mean(abs2.confined(isfinite(abs2.Dt))));
assert(mean(abs2.confined(isfinite(abs2.Dt))) > 0.8, ...
    'fixture check: the absolute rule should call this track confined throughout');
% The claim is that the drop rule does not mistake SLOW for CHANGED — not that it is noise-free. A
% single excursion on one random track is expected: the matched-null false-positive rate at these
% settings is 22%, which the null control in section (3) measures directly.
assert(mean(drop2.confined(isfinite(drop2.Dt))) < 0.25, ...
    'the drop rule called %.0f%% of a constant-D track confined; the absolute rule called %.0f%%', ...
    100*mean(drop2.confined(isfinite(drop2.Dt))), 100*mean(abs2.confined(isfinite(abs2.Dt))));
assert(sum(drop2.stateChange(:)) <= 1, ...
    'the drop rule reported %d state changes on a track where nothing changes', sum(drop2.stateChange(:)));

%% (3) persistence must beat chance on a matched Brownian null -----------------------------------
% Many tracks, each a single constant D drawn over a realistic range, none with any state change.
% Every detection here is a false positive.
rng(5);
nT = 300; nF = 71;
Ds = 0.15 + 1.2*rand(nT,1);
M = nan(nF, nT, 3);
for j = 1:nT
    xy = make_xy(repmat(Ds(j),nF,1), dt, sig);
    M(:,j,1) = (0:nF-1)'; M(:,j,2) = xy(:,1); M(:,j,3) = xy(:,2);
end
Tnull = struct('matrix',M,'frameInterval',dt);
noRun  = spt_track_diffusion(Tnull, o(dt,sig,'drop',0.30,1));   % no persistence guard
withRun= spt_track_diffusion(Tnull, o(dt,sig,'drop',0.30,5));   % the default
fpNo  = 100*mean(any(noRun.stateChange,1));
fpYes = 100*mean(any(withRun.stateChange,1));
fprintf('matched Brownian null: false positives %.0f%% without persistence -> %.0f%% with minRun 5\n', fpNo, fpYes);
assert(fpYes < 0.5*fpNo, ...
    'persistence barely helped (%.0f%% -> %.0f%%); it is supposed to be the main specificity lever', fpNo, fpYes);
assert(fpYes < 35, 'the default settings fire on %.0f%% of pure constant-D tracks', fpYes);

%% (4) the criterion used is on the record -------------------------------------------------------
d = withRun.diffOpts;
assert(strcmp(d.confMode,'drop') && d.confFrac==0.30 && d.minRun==5, ...
    'diffOpts does not record the criterion actually applied');
assert(isfield(d,'confineD') && isfield(d,'baseWin'), 'the criterion parameters are not fully recorded');
fprintf('provenance: confMode=%s confFrac=%.2f baseWin=%d minRun=%d\n', ...
    d.confMode, d.confFrac, d.baseWin, d.minRun);

%% (5) the shipped DEFAULTS are the measured ones -------------------------------------------------
dflt = spt_track_diffusion(T1, struct('dt',dt,'sigmaUm',sig)).diffOpts;
assert(strcmp(dflt.confMode,'drop') && dflt.confFrac==0.30 && dflt.baseWin==10 && dflt.minRun==5, ...
    'the defaults drifted from the measured best (drop / 0.30 / 10 / 5): got %s / %.2f / %d / %d', ...
    dflt.confMode, dflt.confFrac, dflt.baseWin, dflt.minRun);
fprintf('defaults are the measured best: drop 0.30x preceding 10, minRun 5\n');

%% (6) ONE implementation — the builder and the re-derive path cannot drift ----------------------
% These were separate copies and had already diverged: the app kept a sliding baseline after the
% driver moved to a frozen one, so re-deriving a build gave different flags from building it.
o6 = struct('confMode','drop','confFrac',0.30,'baseWin',10,'minRun',5,'confineD',0.15);
built = spt_track_diffusion(T1, o(dt,sig,'drop',0.30,5));
[cf, sc] = spt_confine_flags(built.Dt, o6);
assert(isequal(cf, built.confined) && isequal(sc, built.stateChange), ...
    'spt_track_diffusion and spt_confine_flags disagree — they are supposed to be the same code path');
fprintf('builder and re-derive agree exactly (one shared implementation)\n');

fprintf('\nSTATE-CHANGE SMOKE PASSED.\n');
end

% =====================================================================================
function opts = o(dt, sig, mode, frac, minRun)
opts = struct('dt',dt,'sigmaUm',sig,'confMode',mode,'confFrac',frac,'minRun',minRun, ...
              'confineD',0.15,'baseWin',10);
end

function T = one_track(xy, dt)
n = size(xy,1);
M = nan(n,1,3); M(:,1,1) = (0:n-1)'; M(:,1,2) = xy(:,1); M(:,1,3) = xy(:,2);
T = struct('matrix',M,'frameInterval',dt);
end

function xy = make_xy(Dseq, dt, sig)
% Brownian path whose per-step D follows Dseq, plus localization noise.
n = numel(Dseq);
s = sqrt(2*Dseq*dt);
x = cumsum([0; s(1:end-1).*randn(n-1,1)]) + sig*randn(n,1);
y = cumsum([0; s(1:end-1).*randn(n-1,1)]) + sig*randn(n,1);
xy = [x y];
end
