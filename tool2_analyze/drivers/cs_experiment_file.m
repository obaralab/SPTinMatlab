function [p, existing] = cs_experiment_file(projectDir)
%CS_EXPERIMENT_FILE  Where a project's experiment DETAILS live.
%
%   p            = cs_experiment_file(projectDir)   path to write / auto-load
%   [p, existing] = ...                             existing = the file actually on disk, '' if none
%
% The canonical name is <project>/experiment_details.mat. It used to be experiment_manifest.mat, and
% projects created before the rename still carry that — so this reads the old name when the new one
% is absent and returns it, while `p` is always the new name so the next save migrates the project
% without asking. Both are read; only the new one is ever written.
%
% All three tools resolve through here so they cannot disagree about which file a project uses —
% Tool 1 and Tools 2/3 each computed the path independently before, which is exactly how the same
% project ended up in the manifest twice under two spellings.

NEW = 'experiment_details.mat';
OLD = 'experiment_manifest.mat';

p = ''; existing = '';
if nargin < 1 || isempty(projectDir), return; end
projectDir = char(projectDir);

p = fullfile(projectDir, NEW);
if isfile(p)
    existing = p;
elseif isfile(fullfile(projectDir, OLD))
    existing = fullfile(projectDir, OLD);
end
end
