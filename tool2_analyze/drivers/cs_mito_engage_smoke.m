function cs_mito_engage_smoke()
%CS_MITO_ENGAGE_SMOKE  The diffusion-contrast readout must see tethering, and must NOT see it when
%it is not there.
%
% A metric that only ever moves in one direction is not a measurement. Both halves are asserted:
%
%   1. TETHERED CELL      — molecules slowed to D_slow inside the zone give Dratio ~ D_slow/D_fast,
%                           recovering the planted contrast.
%   2. UNTETHERED CELL    — the SAME geometry with one uniform D gives Dratio ~ 1. This is the
%                           control that says the zone geometry alone cannot manufacture a contrast.
%   3. GAPS DO NOT MOVE IT — dropping 25 % of localizations leaves the ratio where it was. Each step
%                           is weighted by the frames it spans, so a gap-closed step is not credited
%                           to a single interval (see spt_gap_diffusion_smoke for the estimator).
%   4. CROSSINGS ARE COUNTED — steps that leave the zone are attributed to where they STARTED and
%                           reported separately, because they are what dilutes the contrast.
%   5. HONEST REFUSAL     — a cell with too few steps in either class reports ok=false and a reason
%                           rather than a ratio computed from a handful of steps.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
rng(23);
dt = 0.02; sig = 0.0;           % no localization noise: isolate the contrast
Dfast = 0.40; Dslow = 0.08;     % a 5x slowdown on engagement
dZone = 0.10;                   % um: the engagement distance

% A vertical organelle band down the middle of the field; distance = |x - xc|, signed the way the
% importer signs it (+ outside). Molecules that wander into the band are slowed, in the tethered
% cell only.
xc = 5.0;
Tteth = make_cell(xc, dZone, dt, Dfast, Dslow, false);
Tfree = make_cell(xc, dZone, dt, Dfast, Dfast, false);   % same geometry, ONE diffusion coefficient
Tgap  = make_cell(xc, dZone, dt, Dfast, Dslow, true);    % tethered, with 25 % of frames dropped

o = struct('dUm', dZone, 'sigmaUm', sig, 'dt', dt, 'minSteps', 30);
Et = cs_mito_engage(Tteth, o);
Ef = cs_mito_engage(Tfree, o);
Eg = cs_mito_engage(Tgap,  o);

fprintf('%-22s %9s %9s %8s %8s %8s %9s\n','cell','D_bound','D_free','ratio','nBound','nFree','straddle');
show('tethered',   Et); show('untethered', Ef); show('tethered+gaps', Eg);

%% (1) the tethered cell must recover the planted contrast ----------------------------------------
assert(Et.ok, 'tethered cell not computed: %s', Et.why);
want = Dslow/Dfast;
assert(abs(Et.Dratio - want)/want < 0.40, ...
    ['tethered Dratio %.3f against a planted %.3f — the contrast is not being recovered. ' ...
     'D_bound %.4f (planted %.4f), D_free %.4f (planted %.4f).'], ...
    Et.Dratio, want, Et.Dbound, Dslow, Et.Dfree, Dfast);
assert(Et.Dratio < 0.5, 'tethered Dratio %.3f is not clearly below 1 — the readout would not call this a hit', Et.Dratio);

%% (2) THE CONTROL: same geometry, no tethering, must give ~1 -------------------------------------
% Without this the metric could be reporting an artefact of the zone (edge effects, a boundary that
% clips fast excursions) and would look like a hit in every cell.
assert(Ef.ok, 'untethered cell not computed: %s', Ef.why);
assert(abs(Ef.Dratio - 1) < 0.25, ...
    ['untethered Dratio %.3f, expected ~1. The zone geometry alone is producing a contrast, so a ' ...
     'cell with no engagement at all would read as engaged.'], Ef.Dratio);
assert(Ef.Dratio > Et.Dratio*1.5, ...
    'tethered (%.3f) and untethered (%.3f) are not separated — the metric cannot tell them apart', ...
    Et.Dratio, Ef.Dratio);

%% (3) gaps must not move it ----------------------------------------------------------------------
assert(Eg.ok, 'gapped cell not computed: %s', Eg.why);
assert(abs(Eg.Dratio - Et.Dratio)/Et.Dratio < 0.25, ...
    ['dropping 25%% of localizations moved the ratio from %.3f to %.3f. Gap-closed steps must be ' ...
     'weighted by the frames they span, not credited to one interval.'], Et.Dratio, Eg.Dratio);

%% (4) crossings counted, and every step classified -------------------------------------------------
assert(Et.nStraddle > 0, ...
    'no boundary crossings at all — molecules never enter or leave, so the dilution is untested');
assert(Et.nBound + Et.nFree == totalSteps(Tteth), ...
    ['bound (%d) + free (%d) = %d but the cell has %d steps. Classifying by the START of a step ' ...
     'must account for every step exactly once.'], ...
    Et.nBound, Et.nFree, Et.nBound + Et.nFree, totalSteps(Tteth));

%% (5) a thin cell must refuse rather than guess ---------------------------------------------------
Tthin = make_cell(xc, dZone, dt, Dfast, Dslow, false);
% Truncate the DISTANCE with the matrix. cs_channel_dist size-checks the two against each other and
% treats a mismatch as "no distance at all", so trimming only the matrix would test the wrong
% refusal — it reported 'no mito distance' rather than 'too few steps'.
Tthin.matrix = Tthin.matrix(1:4, 1:2, :);          % 2 tracks, 4 frames: nothing like enough
Tthin.dist.mito = Tthin.dist.mito(1:4, 1:2);
Eth = cs_mito_engage(Tthin, o);
assert(~Eth.ok, 'a 2-track, 4-frame cell reported ok=true with ratio %.3f', Eth.Dratio);
assert(isnan(Eth.Dratio), 'a refused cell must report NaN, not a number computed from a handful of steps');
assert(contains(Eth.why,'too few'), 'the refusal does not say why: "%s"', Eth.why);
fprintf('thin cell refused: %s\n', Eth.why);

%% a distance SCAN returns one record per distance -------------------------------------------------
Es = cs_mito_engage(Tteth, struct('dUm',[0.05 0.10 0.20],'sigmaUm',sig,'dt',dt,'minSteps',30));
assert(isequal(size(Es), [1 3]), 'a 3-distance scan returned a %s result', mat2str(size(Es)));
fprintf('distance scan: ');
for q = 1:3, fprintf('d=%.2f -> ratio %.3f  ', Es(q).dUm, Es(q).Dratio); end
fprintf('\n');

fprintf('\nMITO-ENGAGEMENT SMOKE PASSED.\n');
end

% ================================================================================================
function T = make_cell(xc, dZone, dt, Dfast, Dslow, withGaps)
% One cell: molecules diffusing in a field with a zero-width organelle line at x = xc. A molecule
% within dZone of it takes Dslow steps, outside Dfast — so the slowed region and the metric's zone
% are the same set.
nT = 80; nF = 150;
F = repmat((1:nF)', 1, nT); X = nan(nF,nT); Y = nan(nF,nT);
for j = 1:nT
    x = xc - 1.5 + 3*rand;  y = 5*rand;                % start anywhere across the band
    for i = 1:nF
        X(i,j) = x; Y(i,j) = y;
        inZone = abs(x - xc) <= dZone;
        s = sqrt(2*tern(inZone, Dslow, Dfast)*dt);
        x = x + s*randn; y = y + s*randn;
    end
end
if withGaps
    for j = 1:nT
        drop = false(nF,1); drop(2:nF-1) = rand(nF-2,1) < 0.25;
        for i = 3:nF, if drop(i) && drop(i-1), drop(i) = false; end, end
        X(drop,j) = NaN; Y(drop,j) = NaN;
    end
end
T = struct();
T.matrix = cat(3, F, X, Y);
T.frameInterval = dt;
T.file = 'synthetic';
% Distance to the organelle, shaped [nFrames x nTracks] to match the coordinate matrix:
% cs_channel_dist('tracked') size-checks against that and treats a mismatched array as ABSENT
% rather than mis-indexing it, so a column vector here would be silently no data at all.
%
% The organelle is a zero-width line at xc, so distance is |x - xc| and the metric's zone
% (dist <= dZone) is EXACTLY the slowed region. An earlier version stored |x - xc| - dZone, which
% made the tested zone twice as wide as the slow region: half the "bound" steps were fast ones and
% D_bound came out at 0.14 against a planted 0.08. The fixture was wrong, not the metric.
T.dist = struct('mito', abs(X - xc));
end

function n = totalSteps(T)
X = T.matrix(:,:,2); Y = T.matrix(:,:,3); n = 0;
for j = 1:size(X,2)
    n = n + max(0, numel(find(isfinite(X(:,j)) & isfinite(Y(:,j)))) - 1);
end
end

function show(name, E)
fprintf('%-22s %9.4f %9.4f %8.3f %8d %8d %9d\n', name, E.Dbound, E.Dfree, E.Dratio, ...
    E.nBound, E.nFree, E.nStraddle);
end

function y = tern(c,a,b), if c, y = a; else, y = b; end, end
