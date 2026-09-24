function spt_time_match_smoke()
%SPT_TIME_MATCH_SMOKE  Two colours acquired at different rates, put on one clock.
%
% WHAT IS ASSERTED:
%   1. SAME RATE, SAME CLOCK: every localization matches its own frame, with a zero time gap.
%   2. HALF THE FRAMES — the case this exists for. Every A localization still finds a partner: the
%      ones sharing a frame at gap 0, the ones between B frames at half a B interval. The gap is
%      REPORTED rather than hidden, because it is the part of any distance that is really time.
%   3. A GAP IN B IS NOT CROSSED: where B stops imaging, A's localizations there come back
%      UNMATCHED rather than snapped to the far side of the gap. Unmeasured is not far.
%   4. THE TOLERANCE IS THE CONTROL: tightening it to exact simultaneity leaves only the shared
%      frames matched; the default is half of B's spacing and is reported with the result.
%   5. 'previous' AND 'next' NEVER LOOK THE WRONG WAY, which is what makes 'previous' usable for a
%      partner that persists between its frames.
%   6. IT DOES NOT ASSUME SORTED INPUT, and an empty or all-NaN partner is empty, not an error.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);

%% (1) same rate ---------------------------------------------------------------------------------
dt = 0.02; tA = (0:99)'*dt;
M = spt_time_match(tA, tA);
assert(isequal(M.idx, (1:100)'), 'same-rate matching should be the identity');
assert(all(M.dt_s == 0) && M.nUnmatched == 0, 'and every gap zero');

%% (2) B at half the rate ------------------------------------------------------------------------
tB = (0:2:98)'*dt;                       % every other frame of A
M2 = spt_time_match(tA, tB);
assert(M2.nUnmatched == 0, ...
    'with B at half rate every A localization still has a nearest partner, %d had none', M2.nUnmatched);
shared = 1:2:100;                        % A frames 0,2,4… share a time with B
assert(all(M2.dt_s(shared) == 0), 'the shared frames should match at gap 0');
between = 2:2:98;
assert(all(abs(abs(M2.dt_s(between)) - dt) < 1e-12), ...
    'the ones between B frames should report a one-frame gap, not zero (%.4f)', max(abs(M2.dt_s(between))));
assert(abs(M2.medianSpacingB - 2*dt) < 1e-12, 'B''s spacing should be reported as twice A''s');
assert(abs(M2.tol_s - dt) < 1e-12, 'the default tolerance should be half of B''s spacing');

%% (3) a gap in B is not crossed ------------------------------------------------------------------
tB3 = [(0:2:40)'; (80:2:98)']*dt;        % B stops imaging in the middle
M3 = spt_time_match(tA, tB3);
mid = tA > 45*dt & tA < 75*dt;
assert(all(~M3.matched(mid)), ...
    'A localizations inside B''s gap must come back unmatched, %d were matched across it', nnz(M3.matched(mid)));
assert(all(M3.idx(mid) == 0) && all(isnan(M3.dt_s(mid))), 'and carry no index and no gap');
assert(M3.nUnmatched == nnz(mid) || M3.nUnmatched >= nnz(mid), 'the count should include them');
assert(any(M3.matched), 'the parts B did image should still match');

%% (4) the tolerance is the control ---------------------------------------------------------------
M4 = spt_time_match(tA, tB, struct('tol_s', 0));
assert(nnz(M4.matched) == numel(shared), ...
    'at exact simultaneity only the %d shared frames match, %d did', numel(shared), nnz(M4.matched));
assert(all(M4.dt_s(M4.matched) == 0), 'and all at gap 0');
M4b = spt_time_match(tA, tB, struct('tol_s', Inf));
assert(M4b.nUnmatched == 0, 'an infinite tolerance always takes the nearest');

%% (5) previous and next --------------------------------------------------------------------------
Mp = spt_time_match(tA, tB, struct('rule','previous','tol_s',Inf));
gp = Mp.dt_s(Mp.matched);
assert(all(gp <= 1e-12), '''previous'' must never look forward (max gap %+.4f)', max(gp));
Mn = spt_time_match(tA, tB, struct('rule','next','tol_s',Inf));
gn = Mn.dt_s(Mn.matched);
assert(all(gn >= -1e-12), '''next'' must never look back (min gap %+.4f)', min(gn));
assert(Mp.matched(1) && abs(Mp.dt_s(1)) < 1e-12, 'a time sitting exactly on a B frame is its own previous');

%% (6) unsorted, empty, NaN -------------------------------------------------------------------------
rng(3); perm = randperm(numel(tB));
Mu = spt_time_match(tA, tB(perm));
assert(isequal(Mu.matched, M2.matched), 'shuffling the partner should not change WHICH times match');
mm = M2.matched;
assert(isequal(perm(Mu.idx(mm))', M2.idx(mm)), ...
    ['an unsorted partner should give the same matches, indexed into the order it was given in ' ...
     '(so perm(idx) recovers the sorted answer)']);
assert(isequaln(Mu.dt_s, M2.dt_s), 'and the same gaps');
Me = spt_time_match(tA, []);
assert(Me.nUnmatched == numel(tA) && all(Me.idx == 0), 'no partner at all is no match, not an error');
Mn2 = spt_time_match([0.1; NaN; 0.3], tB);
assert(~Mn2.matched(2) && Mn2.matched(1), 'a NaN time matches nothing and does not stop the rest');

fprintf('time match: half-rate partner matched %d/%d (gap 0 on shared frames, %.0f ms between), ', ...
    nnz(M2.matched), numel(tA), 1000*max(abs(M2.dt_s)));
fprintf('B''s gap left %d unmatched rather than crossed\n', nnz(~M3.matched));
fprintf('\nTIME-MATCH SMOKE PASSED.\n');
end
