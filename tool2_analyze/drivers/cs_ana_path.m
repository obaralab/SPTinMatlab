function p = cs_ana_path(anaDir, kind, name)
%CS_ANA_PATH  Where an analysis artifact belongs, and where an existing one actually is.
%
%   p = cs_ana_path(anaDir, kind)          the folder for that kind (created on demand)
%   p = cs_ana_path(anaDir, kind, name)    the full path to WRITE that file
%   p = cs_ana_path(anaDir, 'find', name)  an EXISTING file: every subfolder, then the root
%
% WHY. analysis/ was flat, and a 93-cell plate put 186 density files in it — two per cell, plus the
% per-window ranges — around the handful of files a person actually opens. The build, its pointer
% and the calibration STAY at the root: they are the project's spine, every tool looks for them by
% name, and moving them would break every existing project for no gain.
%
%   analysis/
%     <build>.mat, active_trackstruct.txt, cs_calib.mat   the spine — unchanged
%     density/     Density_<base>.mat/.tif, Density_<base>_CSwindows.mat
%     Densities/   <base>_rho.tif        (unchanged: the advisor's pipeline expects this name)
%     exports/     the CSVs you take to Prism
%     examples/    examples_*.mat        (engagement subsets)
%     curation/    track_exclusions.csv
%
% BACKWARD COMPATIBILITY IS NOT OPTIONAL. Projects already have these files at the root, and a
% reader that only looks in the new folder would silently behave as though the data did not exist —
% a picker with no windows reads as "nothing was picked", not as "the file moved". So every read
% goes through 'find', which checks the new home first and then the root, and nothing is migrated:
% an old project keeps working untouched and a new one is tidy.

if nargin < 2, kind = ''; end
anaDir = char(anaDir);
if isempty(anaDir), p = ''; return; end

if strcmpi(kind,'find')
    p = findExisting(anaDir, name); return
end

sub = subFor(kind);
d = anaDir; if ~isempty(sub), d = fullfile(anaDir, sub); end
if nargin < 3 || isempty(name)
    p = d;
    if ~isempty(sub) && ~isfolder(d), try, mkdir(d); catch, end, end
    return
end
if ~isempty(sub) && ~isfolder(d), try, mkdir(d); catch, end, end
p = fullfile(d, char(name));
end

% =================================================================================================
function sub = subFor(kind)
switch lower(char(kind))
    case 'density',  sub = 'density';
    case 'export',   sub = 'exports';
    case 'examples', sub = 'examples';
    case 'curation', sub = 'curation';
    case {'root',''}, sub = '';
    otherwise,       sub = '';      % an unknown kind stays at the root rather than inventing a folder
end
end

function p = findExisting(anaDir, name)
% New homes first, then the root. Ordered so a project that has BOTH — one written before the move
% and one after — resolves to the newer file rather than the stale one it replaced.
p = '';
name = char(name);
for s = {'density','exports','examples','curation',''}
    d = anaDir; if ~isempty(s{1}), d = fullfile(anaDir, s{1}); end
    f = fullfile(d, name);
    if isfile(f), p = f; return; end
end
end
