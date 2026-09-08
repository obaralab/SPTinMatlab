function cs_track_occupancy_smoke()
%CS_TRACK_OCCUPANCY_SMOKE  Occupancy must be per MOLECULE, and must show what pooling hides.
%
% WHAT IS ASSERTED:
%   1. THE ARITHMETIC — a track planted with a known fraction of its localizations inside the zone
%      scores exactly that fraction, recounted from the fixture rather than trusted.
%   2. IT IS PER TRACK, AND THAT MATTERS — the fixture is built so the POOLED (per-localization)
%      occupancy and the per-track median disagree strongly, because one long resident track carries
%      the pooled number. If they agreed, this metric would be a rename rather than a fix.
%   3. THE ENGAGED FRACTION counts molecules, not time: a cell where 2 of 10 tracks sit at the
%      organelle reports 0.2 however long those two were tracked.
%   4. SHORT TRACKS ARE REFUSED — 3 localizations can only score 0, 1/3, 2/3 or 1, which is noise
%      wearing the shape of a measurement. minLoc drops them, and the cell says how many it scored.
%   5. IT ANSWERS WHERE THE D RATIO CANNOT — a cell too sparse for cs_mito_engage's minSteps still
%      gets an occupancy, because counting localizations needs no step statistics.
%   6. CELLS ARE NEVER DROPPED — a trackless cell keeps its row with a reason, so perCell indices
%      line up with cs_mito_engage's output and nothing renumbers.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
d = 0.10; nF = 200;

% cellA: ONE long resident (200 loc, all inside) + NINE short free tracks (20 loc, all outside).
% Pooled occupancy = 200/(200+180) = 0.53 — "half the signal is at mitochondria".
% Per track      = 1 resident of 10 -> median 0, engaged fraction 0.1.
% The two tell opposite stories, which is the point of the change.
T1 = mkCell('cellA', [ 200 1.0 ; repmat([20 0.0], 9, 1) ], nF, d);
% cellB: half the molecules are engaged, and each spends 60 % of its time inside.
T2 = mkCell('cellB', [ repmat([50 0.6], 5, 1) ; repmat([50 0.0], 5, 1) ], nF, d);
% cellC: nothing linked at all.
T3 = mkCell('cellC', zeros(0,2), nF, d);
T  = [T1 T2 T3];

[pt, pc] = cs_track_occupancy(T, struct('dUm',d,'key','mito','minLoc',5,'engFrac',0.5));

%% (1) the arithmetic, recounted from the fixture --------------------------------------------------
for i = 1:numel(pt)
    Tk = T(pt(i).cellIndex);
    dcol = Tk.dist.mito(:, pt(i).col);
    xcol = Tk.matrix(:, pt(i).col, 2);
    rr = isfinite(xcol) & isfinite(dcol);
    want = sum(dcol(rr) <= d) / sum(rr);
    assert(abs(pt(i).occ - want) < 1e-12, ...
        '%s track %d scored %.4f, recount says %.4f', pt(i).file, pt(i).col, pt(i).occ, want);
end

%% (2) per-track and pooled must DISAGREE on cellA -------------------------------------------------
Dm = T1.dist.mito; Xm = T1.matrix(:,:,2);
pooled = sum(Dm(isfinite(Xm)) <= d) / sum(isfinite(Xm(:)));
a = pc(1);
fprintf('cellA: pooled occupancy %.3f · per-track median %.3f · engaged fraction %.3f\n', ...
    pooled, a.occMedian, a.engagedFrac);
assert(pooled > 0.45, 'the fixture pooled to %.3f — it was supposed to be dominated by the resident', pooled);
assert(a.occMedian < 0.1, ...
    ['the per-track median is %.3f. One resident among nine free molecules must not give a median ' ...
     'near the pooled %.3f, or per-track occupancy is measuring the same thing under a new name.'], ...
    a.occMedian, pooled);
assert(pooled - a.occMedian > 0.4, ...
    'pooled %.3f and per-track median %.3f differ by %.3f — too little for this test to prove anything', ...
    pooled, a.occMedian, pooled - a.occMedian);

%% (3) the engaged fraction counts molecules -------------------------------------------------------
assert(abs(a.engagedFrac - 0.1) < 1e-9, ...
    ['cellA reports %.3f engaged. One of ten molecules is at the organelle; the resident being 10x ' ...
     'longer than the others must not change that.'], a.engagedFrac);
assert(abs(pc(2).engagedFrac - 0.5) < 1e-9, 'cellB reports %.3f engaged, wanted 0.5', pc(2).engagedFrac);
% 0.3, not 0.6: five tracks at 0.6 and five at 0.0 put the median BETWEEN the two populations.
% That is worth stating, because it is the trap in reading this number — the median over all tracks
% is not the median of the engaged ones, and on a bimodal cell it lands where nothing actually sits.
% The engaged FRACTION above is the number that survives bimodality; the median is a summary of the
% whole population and moves with the mixing ratio.
assert(abs(pc(2).occMedian - 0.3) < 0.06, ...
    'cellB median occupancy %.3f, wanted ~0.3 (five tracks at 0.6, five at 0)', pc(2).occMedian);

%% (4) short tracks are refused ---------------------------------------------------------------------
Tshort = mkCell('cellShort', repmat([3 1.0], 6, 1), nF, d);
[ptS, pcS] = cs_track_occupancy(Tshort, struct('dUm',d,'key','mito','minLoc',5));
assert(isempty(ptS), '%d three-localization tracks were scored; 3 points can only give 0, 1/3, 2/3 or 1', numel(ptS));
assert(pcS(1).nScored == 0 && contains(pcS(1).why,'localizations'), ...
    'a cell with only short tracks does not say why it scored none: "%s"', pcS(1).why);
[ptS2, ~] = cs_track_occupancy(Tshort, struct('dUm',d,'key','mito','minLoc',3));
assert(numel(ptS2) == 6, 'lowering minLoc to 3 scored %d tracks, wanted 6 — the threshold is inert', numel(ptS2));

%% (5) it answers where the D ratio refuses ----------------------------------------------------------
E = cs_mito_engage(T2, struct('dUm',d,'key','mito','sigmaUm',0,'dt',0.02,'minSteps',5000));
assert(~E.ok, 'the fixture cell was supposed to be too sparse for a D ratio at minSteps 5000');
assert(isfinite(pc(2).occMedian), ...
    ['the D ratio refused this cell and occupancy did too. Counting localizations needs no step ' ...
     'statistics, so a sparse cell should still get an occupancy — that is half the reason to have it.']);

%% (6) no cell is dropped ------------------------------------------------------------------------------
assert(numel(pc) == numel(T), 'perCell has %d rows for %d cells', numel(pc), numel(T));
assert(pc(3).cellIndex == 3 && pc(3).nScored == 0 && ~isempty(pc(3).why), ...
    'the trackless cell lost its row or its reason, so perCell no longer lines up with cs_mito_engage');

fprintf('cellB: median %.3f · engaged %.2f · %d/%d tracks scored\n', ...
    pc(2).occMedian, pc(2).engagedFrac, pc(2).nScored, pc(2).nTracks);
fprintf('\nTRACK-OCCUPANCY SMOKE PASSED.\n');
end

% ================================================================================================
function T = mkCell(name, spec, nF, d)
% spec rows: [nLoc, fracInside]. Each track gets nLoc localizations, of which fracInside lie at
% distance 0 (inside the zone) and the rest at 3*d (well outside). Distances are planted directly
% rather than derived from a geometry, so the expected occupancy is exactly fracInside and the test
% measures the metric rather than my ability to build a diffusing fixture.
rng(9);
nT = size(spec,1);
X = nan(nF,nT); Y = nan(nF,nT); D = nan(nF,nT);
F = repmat((1:nF)', 1, nT);
for j = 1:nT
    n = spec(j,1); fin = spec(j,2);
    nIn = round(n*fin);
    dj = [zeros(nIn,1); repmat(3*d, n-nIn, 1)];
    dj = dj(randperm(n));                       % interleaved, so it is not an artefact of ordering
    X(1:n,j) = 5 + 0.01*randn(n,1);
    Y(1:n,j) = 5 + 0.01*randn(n,1);
    D(1:n,j) = dj;
end
T = struct();
T.matrix = cat(3, F, X, Y);
T.frameInterval = 0.02;
T.file = name;
T.dist = struct('mito', D);
end
