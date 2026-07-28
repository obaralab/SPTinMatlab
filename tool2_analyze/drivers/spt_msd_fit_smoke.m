function spt_msd_fit_smoke()
% Verify the MSD fit-window tools: spt_msd_sweep (D & R² vs window) and spt_fit_msd's adaptive mode
% (largest window still linear). A confined MSD must fit FEWER lags than a fixed large %; on real data
% the adaptive fit-% must VARY per track (the whole point) while back-compat scalar % still works.
here = fileparts(mfilename('fullpath')); addpath(here);
dt = 0.02; D = 0.05; lags = (1:40)';

%% linear MSD: D constant across windows, adaptive uses the whole (capped) window --------
msd = 4*D*lags*dt + 0.004;
sw = spt_msd_sweep(msd, dt);
assert(all(abs(sw.D - D) < 1e-6) && all(sw.R2 > 0.999), 'linear sweep wrong');
ra = spt_fit_msd(msd, dt, struct('mode','adaptive','maxFrac',0.6,'r2thr',0.95));
assert(abs(ra.D - D) < 1e-6 && ra.nPts == floor(0.6*40), 'adaptive should use the full capped window on linear data');

%% confined MSD (linear then plateau): adaptive stops at the linear part -----------------
msd2 = min(4*D*lags*dt, 0.08) + 1e-4;                 % saturates at lag ~20 (of 40) -> curves over
sw2 = spt_msd_sweep(msd2, dt);
assert(sw2.D(1) > sw2.D(end), 'D should fall as the window grows into the plateau');
ra2 = spt_fit_msd(msd2, dt, struct('mode','adaptive','maxFrac',0.9,'r2thr',0.98));
rf2 = spt_fit_msd(msd2, dt, 90);                       % fixed 90%
assert(ra2.nPts < rf2.nPts, 'adaptive should use fewer lags than fixed 90%% on a curved MSD');
fprintf('confined: adaptive nPts=%d (%.0f%%) vs fixed nPts=%d (%.0f%%)\n', ra2.nPts, ra2.fracUsed, rf2.nPts, rf2.fracUsed);

%% back-compat: scalar spec = fixed % ----------------------------------------------------
rc = spt_fit_msd(msd, dt, 25);
assert(rc.nPts == round(40*0.25), 'scalar %% back-compat broken');

%% real data: adaptive fit-% varies per track -------------------------------------------
f = '/Users/safal-mac/Desktop/IntegratedPipeline/Project/analysis/TrackStruct.mat';
if isfile(f)
    S = load(f); fn = fieldnames(S); Tr = S.(fn{1}); dtc = 0.020064;
    Dfix = []; Dad = []; fr = [];
    for k = 1:numel(Tr)
        M = Tr(k).MSD; if isempty(M), continue; end
        for c = 1:size(M,2)
            rf = spt_fit_msd(M(:,c), dtc, 25);
            rA = spt_fit_msd(M(:,c), dtc, struct('mode','adaptive','maxFrac',0.6,'r2thr',0.95));
            if isfinite(rf.D) && rf.D > 0, Dfix(end+1) = rf.D; end %#ok<AGROW>
            if isfinite(rA.D) && rA.D > 0, Dad(end+1) = rA.D; fr(end+1) = rA.fracUsed; end %#ok<AGROW>
        end
    end
    fprintf('real: adaptive fit-%% %.0f-%.0f (median %.0f) · median D fixed25%%=%.3g adaptive=%.3g\n', ...
        min(fr), max(fr), median(fr), median(Dfix), median(Dad));
    assert(max(fr)-min(fr) > 5, 'adaptive fit-%% did not vary across tracks');
else
    fprintf('(no Project TrackStruct.mat — real-data check skipped)\n');
end

fprintf('\nMSD-FIT SMOKE PASSED.\n');
end
