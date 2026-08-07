function spt_precision_smoke()
% Verify the MSD-intercept localization precision: spt_fit_msd recovers D AND the τ→0 intercept, and
% σ_loc = sqrt(intercept)/2 matches a known injected precision; also runs on a real TrackStruct.
here = fileparts(mfilename('fullpath')); addpath(here);

%% synthetic: MSD(τ) = 4·D·τ + 4·σ² with known D and σ ---------------------------
dt = 0.02; D = 0.05; sig = 0.030;          % D µm²/s, σ_loc = 30 nm
b = 4*sig^2;                                % exact intercept
lags = (1:20)';
msd = 4*D*(lags*dt) + b;                    % exact MSD
r = spt_fit_msd(msd, dt, 100);
fprintf('synthetic: D=%.4g (true %.4g) · σ_loc=%.1f nm (true %.1f)\n', r.D, D, 1000*r.sigLocUm, 1000*sig);
assert(abs(r.D - D) < 1e-6, 'D not recovered');
assert(abs(r.b - b) < 1e-9, 'intercept not recovered');
assert(abs(r.sigLocUm - sig) < 1e-4, 'σ_loc not recovered from the intercept');

% a track with NO static error (intercept 0) -> σ_loc 0; a negative intercept -> clamped to 0
r0 = spt_fit_msd(4*D*(lags*dt), dt, 100);
assert(r0.sigLocUm < 1e-6, 'σ_loc should be ~0 when intercept is 0');

%% real TrackStruct ---------------------------------------------------------------
f = '/Users/safal-mac/Documents/IntegratedPipeline/Project/analysis/TrackStruct.mat';
if isfile(f)
    S = load(f); fn = fieldnames(S); Tr = S.(fn{1});
    dtc = 0.020064; got = 0; sigs = [];
    for k = 1:numel(Tr)
        M = Tr(k).MSD; if isempty(M), continue; end
        for c = 1:size(M,2)
            rr = spt_fit_msd(M(:,c), dtc, 50);
            if isfinite(rr.sigLocUm) && rr.sigLocUm > 0, sigs(end+1) = rr.sigLocUm; got = got+1; end %#ok<AGROW>
        end
    end
    fprintf('real: %d tracks with a positive MSD intercept · median σ_loc ≈ %.0f nm\n', got, 1000*median(sigs));
    assert(got > 0, 'no real track gave a positive intercept precision');
else
    fprintf('(no Project TrackStruct.mat — skipped the real-data check)\n');
end

fprintf('\nMSD-INTERCEPT PRECISION SMOKE PASSED.\n');
end
