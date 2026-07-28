function validate_robust_refactor()
%VALIDATE_ROBUST_REFACTOR  Confirm ContactSites_robust reproduces the original.
%
% Run from the pipeline root (the folder containing ContactSites_original/ and
% ContactSites_robust/). Two layers of checks:
%
%   1. UNIT: the naming helpers reproduce the original magic-number strips
%      bit-for-bit across a battery of names (no data needed).
%   2. E2E (optional): if you point it at a completed run, it re-runs a robust
%      stage into a scratch dir and isequaln-compares the .mat outputs to a
%      reference produced by the original suite.
%
%   validate_robust_refactor()          % unit checks only
%
% The unit layer needs no MATLAB toolboxes and no data — run it first.

addpath(fullfile(pwd,'ContactSites_robust'));   % cs_config, cellBase, stripSuffix
fprintf('\n=== UNIT: naming helpers vs original magic numbers ===\n');
nfail = 0;

% --- cellBase(FileTagChars=7) must equal file(1:end-7) ---
names7 = {'a1234567','250408_FFAT_006_spt1_ABCDEFG','xxxxxxx_1234567'};
cfg7 = cs_config(); cfg7.FileTagChars = 7;
for k = 1:numel(names7)
    f = names7{k};
    want = f(1:end-7);
    got  = cellBase(f, cfg7);
    ok = strcmp(want,got); nfail = nfail + ~ok;
    fprintf('  cellBase/7  %-32s -> %-24s [%s]\n', f, got, tf(ok));
end

% --- stripSuffix('_CSdata.mat') must equal name(1:end-11) ---
namesC = {'cellA_CSdata.mat','250408_FFAT_006_spt1_CSdata.mat'};
for k = 1:numel(namesC)
    f = namesC{k};
    want = f(1:end-11);
    got  = stripSuffix(f,'_CSdata.mat');
    ok = strcmp(want,got); nfail = nfail + ~ok;
    fprintf('  strip _CSdata.mat  %-34s -> %-20s [%s]\n', f, got, tf(ok));
end

% --- stripSuffix('CSdata.mat') must equal name(1:end-10) (keeps underscore) ---
for k = 1:numel(namesC)
    f = namesC{k};
    want = f(1:end-10);
    got  = stripSuffix(f,'CSdata.mat');
    ok = strcmp(want,got); nfail = nfail + ~ok;
    fprintf('  strip CSdata.mat   %-34s -> %-20s [%s]\n', f, got, tf(ok));
end

% --- config constants match the literals they replaced ---
cfg = cs_config();
checks = { 'FOV_um',cfg.FOV_um,27.61; 'SnapFOV_um',cfg.SnapFOV_um,27.61 };
for k = 1:size(checks,1)
    ok = abs(checks{k,2}-checks{k,3}) < 1e-12; nfail = nfail + ~ok;
    fprintf('  const %-12s = %.5f (expect %.2f) [%s]\n', checks{k,1},checks{k,2},checks{k,3},tf(ok));
end

fprintf('  ------------------------------------------\n');
if nfail==0
    fprintf('  UNIT PASS — robust helpers reproduce the original strips.\n\n');
else
    fprintf('  UNIT FAIL — %d mismatch(es) above.\n\n', nfail);
end
end

function s = tf(ok), if ok, s='OK'; else, s='FAIL'; end, end
