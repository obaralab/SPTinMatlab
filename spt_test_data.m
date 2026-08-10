function p = spt_test_data(rel)
%SPT_TEST_DATA  Resolve a path inside the optional test dataset. '' when it is not installed.
%
%   p = spt_test_data('WithER')
%   p = spt_test_data(fullfile('Project','analysis'))
%   p = spt_test_data(fullfile('WithER','spt','250408_WT_012_spt1.tif'))
%
% Most of the suite builds synthetic fixtures in tempdir and needs nothing external. About twenty
% tests need a REAL movie or a REAL built project — those datasets are large, are not in the repo,
% and on anyone else's machine are simply absent. This resolves them without hardcoding one person's
% home directory, and returns '' instead of erroring so the caller can skip loudly:
%
%   W = spt_test_data('WithER');
%   if isempty(W), fprintf('SKIP %s — dataset not installed\n', mfilename); return; end
%
% ROOT is resolved in this order:
%   1. $SPT_TEST_DATA           explicit override — point it anywhere
%   2. <repo>/..                the conventional layout, which needs no configuration at all:
%                                 IntegratedPipeline/
%                                   ├── SPTinMatlab/   (this repo)
%                                   ├── WithER/        reference movie + segmentations
%                                   └── Project/       a built project with analysis/
%
% OUTPUT
%   p : absolute path, or '' when the root is unset AND the conventional location has no such entry.
%       A non-empty return is guaranteed to EXIST (file or folder) at the time of the call.
p = '';
if nargin < 1 || isempty(rel), return; end

root = getenv('SPT_TEST_DATA');
if isempty(root)
    root = fileparts(fileparts(mfilename('fullpath')));   % this file sits at the repo root
end
if isempty(root) || ~isfolder(root), return; end

cand = fullfile(root, char(rel));
% isfolder OR isfile — callers ask for both directories and single movies.
if isfolder(cand) || isfile(cand), p = cand; end
end
