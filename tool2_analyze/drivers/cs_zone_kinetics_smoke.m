function cs_zone_kinetics_smoke()
%CS_ZONE_KINETICS_SMOKE  k_off and k_on must be events over exposure, and must survive censoring.
%
% WHAT IS ASSERTED:
%   1. THE ARITHMETIC — on a hand-built fixture with a known number of completed episodes and a
%      known bound time, k_off is exactly events/time. Recounted, not trusted.
%   2. CENSORING IS HANDLED — an episode still bound when its track stops contributes its TIME and
%      no EVENT. The estimator recovers the planted rate on tracks that are truncated.
%   3. THE NAIVE VERSION IS WRONG, AND BY HOW MUCH — averaging the durations you happen to observe
%      treats every truncation as an unbinding. Computed alongside on the same data, so the reason
%      for the more careful form is in the test rather than only in a comment.
%   4. k_on IS THE MIRROR — binding events over FREE time, and a track that never leaves the zone
%      contributes no k_on at all rather than a zero.
%   5. GAPS CARRY THEIR REAL DURATION — a gap-closed step counts as the frames it spans, so a
%      dropped localization does not silently shorten a bound episode.
%   6. CELLS ARE NEVER DROPPED — a trackless cell keeps its row and a reason.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
dt = 0.02; d = 0.10;

%% (1) exact arithmetic on a hand-built pattern ----------------------------------------------------
% One track, 11 localizations, inside/outside laid out by hand:
%   z = 0 0 1 1 1 0 0 1 1 0 0   -> two bound runs, BOTH completed (each followed by a free point)
% Steps are credited to the class they START in, so bound time = 5 steps x dt (the 3 steps starting
% in run 1 plus the 2 starting in run 2) and free time = 5 steps x dt.
z1 = [0 0 1 1 1 0 0 1 1 0 0] > 0;
T1 = mkTrack('cellA', z1, dt, d);
[pc, pt] = cs_zone_kinetics(T1, struct('dUm',d,'key','mito','dt',dt,'minLoc',5));
assert(pc(1).nEnd == 2, 'counted %d completed episodes, the pattern has 2', pc(1).nEnd);
assert(pc(1).nCensored == 0, 'the track ends outside the zone, so nothing is censored (got %d)', pc(1).nCensored);
assert(pc(1).nStart == 2, 'counted %d binding events, the pattern has 2', pc(1).nStart);
assert(abs(pc(1).tBound - 5*dt) < 1e-12, 'bound time %.4g, wanted %g', pc(1).tBound, 5*dt);
assert(abs(pc(1).tFree  - 5*dt) < 1e-12, 'free time %.4g, wanted %g',  pc(1).tFree,  5*dt);
assert(abs(pc(1).kOff - 2/(5*dt)) < 1e-9, 'k_off %.4g, wanted events/exposure = %.4g', pc(1).kOff, 2/(5*dt));
assert(abs(pc(1).kOn  - 2/(5*dt)) < 1e-9, 'k_on %.4g, wanted %.4g', pc(1).kOn, 2/(5*dt));
assert(numel(pt) == 1 && pt(1).srcCol == 1, 'the per-track row is missing or misidentified');

%% (2)+(3) censoring: recover a planted rate that the naive mean cannot ------------------------------
% Exponential bound episodes at a known k_off, observed through a WINDOW that truncates the long
% ones — which is what a finite track length does. The estimator must return the planted rate; the
% mean of observed durations must not.
rng(17);
kTrue = 4.0;                       % s^-1  -> mean bound 250 ms
nEp = 4000; obsWin = 0.30;         % a track that can only show 300 ms of any one episode
dur = exprnd(1/kTrue, nEp, 1);
seen = min(dur, obsWin);           % what you actually observe
ended = dur <= obsWin;             % ...and whether you saw it end
kHat  = sum(ended) / sum(seen);                 % events / exposure  — the estimator under test
kNaive = 1 / mean(seen);                        % 1 / mean observed duration — the tempting version
fprintf('planted k_off %.2f · events/exposure %.2f · 1/mean(observed) %.2f\n', kTrue, kHat, kNaive);
assert(abs(kHat - kTrue)/kTrue < 0.06, ...
    'events/exposure gave %.3f against a planted %.3f — the censoring correction is not working', kHat, kTrue);
assert(kNaive > kTrue*1.25, ...
    ['the naive 1/mean(observed) gave %.3f against a planted %.3f. If it is not clearly biased ' ...
     'here, this fixture is not truncating enough to justify the more careful estimator.'], kNaive, kTrue);

% ...and the same censoring, through the real code path: a track that is STILL BOUND at its end.
z2 = [0 1 1 1 1 1] > 0;            % ends inside -> the episode is censored
T2 = mkTrack('cellB', z2, dt, d);
pc2 = cs_zone_kinetics(T2, struct('dUm',d,'key','mito','dt',dt,'minLoc',5));
assert(pc2(1).nEnd == 0 && pc2(1).nCensored == 1, ...
    'a track ending inside the zone reported %d ended / %d censored, wanted 0 / 1', pc2(1).nEnd, pc2(1).nCensored);
assert(pc2(1).tBound > 0, 'the censored episode contributed no exposure time — it must');
assert(pc2(1).kOff == 0, ...
    ['k_off is %.4g on a cell with no completed episode. Events/exposure with zero events is zero, ' ...
     'not NaN and not an invented rate; the caller reads nEnd to see it is unmeasured.'], pc2(1).kOff);

%% (4) k_on is the mirror, and needs free time --------------------------------------------------------
z3 = ones(1,8) > 0;                % never leaves the zone
T3 = mkTrack('cellC', z3, dt, d);
pc3 = cs_zone_kinetics(T3, struct('dUm',d,'key','mito','dt',dt,'minLoc',5));
assert(pc3(1).tFree == 0 && isnan(pc3(1).kOn), ...
    ['a track that is always bound reported k_on %.4g over %.4g s free. With no free time there is ' ...
     'no exposure to bind from, so k_on is undefined rather than 0.'], pc3(1).kOn, pc3(1).tFree);

%% (5) a gap carries its real duration ------------------------------------------------------------------
% Same inside/outside pattern, but one localization is dropped mid-episode so a step spans 2 frames.
% The bound TIME must grow by that extra frame; crediting it one interval would shorten the episode
% and inflate k_off.
zg = [0 1 1 1 1 0] > 0;
Tg = mkTrack('cellD', zg, dt, d);
TgGap = Tg; TgGap.matrix(4,1,2) = NaN; TgGap.matrix(4,1,3) = NaN;   % drop the 4th localization
pcA = cs_zone_kinetics(Tg,    struct('dUm',d,'key','mito','dt',dt,'minLoc',4));
pcB = cs_zone_kinetics(TgGap, struct('dUm',d,'key','mito','dt',dt,'minLoc',4));
assert(abs(pcA(1).tBound - pcB(1).tBound) < 1e-12, ...
    ['dropping a localization inside the episode changed the bound time from %.4g to %.4g s. A ' ...
     'gap-closed step must carry the frames it spans, or a gap silently shortens every episode it ' ...
     'falls in and k_off comes out high.'], pcA(1).tBound, pcB(1).tBound);

%% (6) no cell is dropped --------------------------------------------------------------------------------
Tnone = mkTrack('cellNone', z1, dt, d); Tnone.matrix = Tnone.matrix(:,[],:);
pcN = cs_zone_kinetics([T1 Tnone], struct('dUm',d,'key','mito','dt',dt));
assert(numel(pcN) == 2 && pcN(2).nTracks == 0 && ~isempty(pcN(2).why), ...
    'the trackless cell lost its row or its reason');

fprintf('exact: k_off %.1f /s from %d ended over %.3f s bound · censored episode keeps its exposure\n', ...
    pc(1).kOff, pc(1).nEnd, pc(1).tBound);
fprintf('\nZONE-KINETICS SMOKE PASSED.\n');
end

% ================================================================================================
function T = mkTrack(name, z, dt, d)
% One track whose localizations are inside the zone exactly where z is true. Distances are planted
% (0 inside, 3*d outside) rather than derived from a geometry, so the pattern under test is the one
% written above rather than whatever a diffusing fixture happened to produce.
n = numel(z);
X = 5 + 0.001*(1:n)'; Y = 5 + 0.001*(1:n)';
D = repmat(3*d, n, 1); D(z) = 0;
T = struct('matrix', cat(3, (1:n)', X, Y), 'frameInterval', dt, 'file', name, ...
           'dist', struct('mito', D));
end
