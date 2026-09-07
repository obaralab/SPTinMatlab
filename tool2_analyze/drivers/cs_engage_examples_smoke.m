function cs_engage_examples_smoke()
%CS_ENGAGE_EXAMPLES_SMOKE  The example tracks must be the population D_bound is built from, and the
%sliced TrackStruct must still be a valid TrackStruct.
%
% WHAT IS ASSERTED:
%   1. THE SAME RULE AS THE METRIC — a track is kept exactly when at least one of its steps STARTS
%      inside the zone. Checked against an independent recount from the fixture, not against the
%      function's own arithmetic.
%   2. NO RANKING — every qualifying track is kept, not the best N. Selecting on the quantity being
%      measured would make an inactive compound look engaged.
%   3. THE SLICE IS COMPLETE — MSD, Dt, CSD and the channel distances all follow their tracks. A
%      field left unsliced would leave a struct whose columns no longer correspond, which is a
%      silent mis-association rather than an error.
%   4. CELLS ARE KEPT — a cell with no qualifying track stays in the array with zero tracks, so
%      cellIndex still lines up with cs_mito_engage's output.
%   5. IT NARROWS WITH d — a smaller zone keeps fewer tracks. If it did not, the distance is not
%      reaching the selection.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
rng(4);
dt = 0.02; nF = 40;

% Cell 1: three tracks against a line at x = 5 — one sitting inside the zone, one DRIFTING across
% it (so some of its steps start inside and some outside), one far away. The drifting one matters:
% it is the case a both-endpoints rule would treat differently, and 5.60 — which an earlier version
% of this fixture called "straddling" — is 0.6 µm out and never enters the zone at all.
% Cell 2: everything far, so it must survive with zero tracks.
T1 = mkCell('cellA', [4.95 NaN; 5.35 4.85; 8.00 NaN], nF, dt);
T2 = mkCell('cellB', [9.00 NaN; 9.40 NaN; 9.80 NaN], nF, dt);
T  = [T1 T2];

d = 0.10;
[sel, Tsub] = cs_engage_examples(T, struct('dUm',d,'key','mito'));

%% (1) the same rule as the metric, recounted from the fixture ------------------------------------
for k = 1:numel(T)
    M = T(k).matrix; X = M(:,:,2); Y = M(:,:,3); Dm = T(k).dist.mito;
    want = [];
    for j = 1:size(X,2)
        rr = find(isfinite(X(:,j)) & isfinite(Y(:,j)));
        if numel(rr) < 2, continue; end
        if any(Dm(rr(1:end-1), j) <= d), want(end+1) = j; end %#ok<AGROW>
    end
    assert(isequal(sel(k).cols(:)', want(:)'), ...   % (:)' on BOTH: 1x0 and 0x0 are both empty and not isequal
        ['%s kept columns %s but a step STARTING within %.3g µm happens in %s. The examples must be ' ...
         'the population D_bound is built from, or they illustrate a different measurement.'], ...
        T(k).file, mat2str(sel(k).cols), d, mat2str(want));
end

%% (2) no ranking: everything that qualifies is kept -------------------------------------------------
assert(numel(sel(1).cols) == 2, ...
    'cellA kept %d tracks; the resident and the drifting track both qualify, the far one does not', numel(sel(1).cols));
assert(isequal(sel(1).cols(:)', [1 2]), 'cellA kept %s, wanted tracks 1 and 2', mat2str(sel(1).cols));
assert(all(sel(1).nBound > 0), 'a kept track reports zero bound steps');

%% (3) every per-track field followed its tracks -------------------------------------------------------
c = sel(1).cols;
assert(size(Tsub(1).matrix,2) == numel(c), 'matrix has %d tracks, kept %d', size(Tsub(1).matrix,2), numel(c));
assert(isequal(Tsub(1).matrix(:,:,2), T(1).matrix(:,c,2)), 'the sliced matrix is not the kept columns');
for f = {'MSD','Dt','CSD'}
    assert(isfield(Tsub(1),f{1}), 'the slice dropped %s entirely', f{1});
    assert(size(Tsub(1).(f{1}),2) == numel(c), ...
        '%s has %d columns after slicing %d tracks — it was left at full width, so its columns no longer match the matrix', ...
        f{1}, size(Tsub(1).(f{1}),2), numel(c));
    assert(isequal(Tsub(1).(f{1}), T(1).(f{1})(:,c)), '%s was sliced to the wrong columns', f{1});
end
assert(size(Tsub(1).dist.mito,2) == numel(c), ...
    'dist.mito was not sliced — the distances would belong to different tracks than the coordinates');
assert(isequal(Tsub(1).dist.mito, T(1).dist.mito(:,c)), 'dist.mito was sliced to the wrong columns');
assert(Tsub(1).frameInterval == T(1).frameInterval, 'a scalar field was sliced as though it were per track');

%% (4) an empty cell survives ---------------------------------------------------------------------------
assert(numel(Tsub) == numel(T), 'the slice dropped a cell: %d in, %d out', numel(T), numel(Tsub));
assert(isempty(sel(2).cols), 'cellB has no track near the organelle but kept %s', mat2str(sel(2).cols));
assert(size(Tsub(2).matrix,2) == 0, 'the empty cell kept %d tracks', size(Tsub(2).matrix,2));
assert(sel(2).cellIndex == 2, 'cellIndex no longer lines up with the input');

%% (5) a smaller zone keeps fewer ------------------------------------------------------------------------
selTight = cs_engage_examples(T, struct('dUm',0.02,'key','mito'));
nWide = sum(arrayfun(@(x) numel(x.cols), sel));
nTight = sum(arrayfun(@(x) numel(x.cols), selTight));
assert(nTight < nWide, ...
    'tightening the zone from %.3g to 0.02 µm kept %d tracks against %d — the distance is not reaching the selection', ...
    d, nTight, nWide);

fprintf('d=%.2g: %d track(s) over %d cell(s) · d=0.02: %d · empty cell kept with 0 tracks\n', ...
    d, nWide, numel(T), nTight);
fprintf('\nENGAGE-EXAMPLES SMOKE PASSED.\n');
end

% ================================================================================================
function T = mkCell(name, xs, nF, dt)
% One cell, one track per ROW of xs = [xStart xEnd]. xEnd NaN holds the track at xStart; otherwise
% it drifts linearly from one to the other, which is how a track is made to cross the boundary.
% The organelle is a line at x = 5, so the signed distance is |x-5|.
nT = size(xs,1);
F = repmat((1:nF)', 1, nT); X = nan(nF,nT); Y = nan(nF,nT);
for j = 1:nT
    if isnan(xs(j,2)), base = repmat(xs(j,1), nF, 1);
    else,              base = linspace(xs(j,1), xs(j,2), nF)'; end
    X(:,j) = base + 0.01*randn(nF,1);
    Y(:,j) = 3 + cumsum(0.02*randn(nF,1));
end
T = struct();
T.matrix = cat(3, F, X, Y);
T.frameInterval = dt;
T.file = name;
T.dist = struct('mito', abs(X - 5));
T.MSD  = rand(8, nT);            % shapes only: the test cares that they FOLLOW their tracks
T.Dt   = rand(nF, nT);
T.CSD  = rand(nF-1, nT);
end
