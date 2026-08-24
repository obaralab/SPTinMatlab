function spt_pbsa_smoke()
%SPT_PBSA_SMOKE  The step detector must recover a KNOWN number of bleaching steps.
%
% Photobleaching step counting is a measurement, not a display: the number this returns becomes a
% claimed stoichiometry. So the test is not "does it run" but "does it get the right answer, and
% does it say so when it cannot". Every trace here has a step count fixed by construction, and the
% assertions are on the recovered count.
here = fileparts(mfilename('fullpath')); addpath(here);
rng(7);   % fixed: a flaky statistical test is worse than no test

fprintf('\n========== PART A: exact recovery on clean traces ==========\n');
% The default threshold is 'auto' = 3x a robust noise estimate. Without it, SIC alone reliably adds
% one noise-sized step here (measured: a spurious step of height ~= the noise sd), so this part also
% pins that the DEFAULT is the safe one — a user who sets nothing must not get a phantom fluorophore.
% One fluorophore bleaching = one drop to background. Then 2, 3, 5 fluorophores.
for nStep = 1:5
    y = buildTrace(nStep, 60, 1000, 8);          % 8 = tiny noise vs a 1000-count step
    R = spt_pbsa_steps(y);
    assert(R.k == nStep, 'clean trace with %d step(s): detector found %d', nStep, R.k);
    assert(all(R.heights < 0), '%d-step bleach must give only DROPS; got %s', nStep, mat2str(round(R.heights)));
end
fprintf('  1-5 steps recovered exactly on clean traces, all heights negative\n');

fprintf('\n========== PART B: recovery under realistic noise ==========\n');
% Sweep SNR (step height / noise sd). This is the number that decides whether a real dataset can be
% counted at all, so the test records it rather than just passing.
fprintf('  %-10s %-9s %s\n', 'SNR', 'accuracy', '(50 traces of 3 steps each)');
acc = zeros(1,0); snrs = [2 4 8 16];
for s = snrs
    ok = 0;
    for t = 1:50
        y = buildTrace(3, 50, 1000, 1000/s);
        R = spt_pbsa_steps(y);
        ok = ok + (R.k == 3);
    end
    acc(end+1) = ok/50; %#ok<AGROW>
    fprintf('  %-10g %-9.0f%%\n', s, 100*ok/50);
end
assert(acc(end) >= 0.9, 'at SNR 16 the detector should be near-perfect; got %.0f%%', 100*acc(end));
assert(acc(end) >= acc(1), 'accuracy must improve with SNR');
fprintf('  accuracy rises with SNR and is >=90%% at SNR 16\n');

fprintf('\n========== PART C: a flat trace has NO steps ==========\n');
% The failure that would matter most: inventing steps in noise, which would report a monomer as an
% oligomer. SIC is supposed to prevent exactly this.
nFalse = 0;
for t = 1:100
    y = 1000 + 60*randn(80,1);                   % pure noise, no step anywhere
    R = spt_pbsa_steps(y);
    nFalse = nFalse + (R.k > 0);
end
fprintf('  pure-noise traces given a step: %d/100\n', nFalse);
assert(nFalse <= 5, 'SIC is over-fitting noise: %d/100 flat traces got a step', nFalse);

fprintf('\n========== PART D: MinStep drops sub-threshold steps ==========\n');
y = [repmat(1000,30,1); repmat(960,30,1); repmat(200,30,1)];   % one tiny step, one huge
R0 = spt_pbsa_steps(y, 'MinStep', 0);          % pure SIC, no height filter
R1 = spt_pbsa_steps(y, 'MinStep', 100);
assert(R0.k == 2, 'both steps should be found without a threshold; got %d', R0.k);
assert(R1.k == 1, 'MinStep 100 should drop the 40-count step; got %d', R1.k);
assert(abs(R1.heights(1)) > 100, 'the surviving step must be the big one');
fprintf('  2 steps found; MinStep=100 keeps only the 760-count drop\n');

fprintf('\n========== PART E: degenerate input never throws ==========\n');
for tc = {[], 5, [1 2], [NaN NaN NaN], repmat(7,50,1)}
    R = spt_pbsa_steps(tc{1});
    assert(isstruct(R) && isfield(R,'k'), 'must always return the result struct');
end
assert(spt_pbsa_steps([]).k == 0, 'empty input -> 0 steps');
assert(spt_pbsa_steps(repmat(7,50,1)).k == 0, 'a constant trace has no steps');
% NaNs are dropped, not fitted: a gap-filled track legitimately carries them.
y = buildTrace(2, 40, 1000, 10); y([5 6 7]) = NaN;
R = spt_pbsa_steps(y);
assert(R.nDropped == 3, 'should report 3 dropped NaNs, got %d', R.nDropped);
assert(R.k == 2, 'NaNs must not change the step count; got %d', R.k);
assert(numel(R.fit) == numel(y) && all(isnan(R.fit([5 6 7]))), 'fit must align with the INPUT and stay NaN in the gaps');
fprintf('  empty/scalar/constant/all-NaN handled; NaNs dropped without moving the count\n');

fprintf('\n========== PART F: fit is faithful and monotone in k ==========\n');
y = buildTrace(4, 40, 1000, 20);
R = spt_pbsa_steps(y);
assert(numel(R.levels) == R.k + 1, 'k steps must give k+1 levels');
assert(numel(R.heights) == R.k, 'k steps must give k heights');
assert(R.sigma < 60, 'residual sd %.1f is too large for a correct fit', R.sigma);
assert(all(diff(R.sic) < 0), 'SIC must strictly decrease at every accepted step');
fprintf('  levels/heights/fit consistent; SIC strictly decreasing (%d steps, sigma %.1f)\n', R.k, R.sigma);

fprintf('\n========== PART G: speed — the viewer re-runs this on every click ==========\n');
y = buildTrace(6, 100, 1000, 30);           % 600 points, longer than any real track here
t0 = tic; for i = 1:20, spt_pbsa_steps(y); end
ms = 1000*toc(t0)/20;
fprintf('  %.1f ms per 600-point trace\n', ms);
assert(ms < 100, 'too slow for interactive use: %.1f ms', ms);

fprintf('\nALL PBSA STEP-DETECTION ASSERTIONS PASSED.\n');
end

% ------------------------------------------------------------------------------------------------
function y = buildTrace(nStep, segLen, stepH, noiseSd)
% A bleaching trace: nStep fluorophores, each dropping stepH, ending at background 0.
% Levels go nStep*stepH down to 0 in equal drops, segLen frames apiece.
lv = (nStep:-1:0) * stepH;
y  = repelem(lv(:), segLen);
y  = y + noiseSd*randn(size(y));
end
