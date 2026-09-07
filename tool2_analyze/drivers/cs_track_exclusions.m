function out = cs_track_exclusions(action, varargin)
%CS_TRACK_EXCLUSIONS  Tracks the user has rejected by hand, shared by every tool that measures them.
%
%   ex   = cs_track_exclusions('load',   projectDir)
%          cs_track_exclusions('save',   projectDir, ex)
%   ex   = cs_track_exclusions('toggle', ex, file, col, reason)
%   tf   = cs_track_exclusions('has',    ex, file, col)
%   keep = cs_track_exclusions('mask',   ex, Tracks)        % {nCells} logical, true = keep
%   Tsub = cs_track_exclusions('apply',  ex, Tracks)        % the same array with rejects removed
%   n    = cs_track_exclusions('count',  ex)
%
% WHY A LIST AND NOT A REBUILD. Removing a bad track by rebuilding would discard every other
% decision in the build and take minutes on 93 cells. A rejection is a judgement about ONE track,
% so it is recorded as one, applied at the moment of measurement, and undone by deleting a row.
%
% IDENTITY is (cell file name, ORIGINAL track column). Not the column of whatever struct happened to
% be on screen: a subset renumbers its tracks from 1, so "track 30" of an examples file is not track
% 30 of the build. Callers holding a sliced struct must resolve through its .srcCols (cs_track_slice
% records it) before recording a decision — `srcColOf` here does that.
%
% THE FILE is analysis/track_exclusions.csv, plain text with a reason column:
%
%   cell,track_col,reason
%   HVK-3C-Plate4-328-012_ch24_spt,30,"drifts off the cell"
%
% CSV rather than a .mat so it can be read, diffed, edited in a spreadsheet and kept next to the
% results it explains. A rejection with no recorded reason is a number nobody can defend later, so
% the column exists even when it is empty.

switch lower(char(action))
    case 'load',   out = doLoad(varargin{:});
    case 'save',   out = doSave(varargin{:});
    case 'toggle', out = doToggle(varargin{:});
    case 'has',    out = doHas(varargin{:});
    case 'mask',   out = doMask(varargin{:});
    case 'apply',  out = doApply(varargin{:});
    case 'count',  out = numel(varargin{1});
    case 'file',   out = exFile(varargin{1});
    otherwise, error('cs_track_exclusions:action','unknown action "%s"', char(action));
end
end

% =================================================================================================
function f = exFile(projectDir)
f = '';
if isempty(projectDir), return; end
f = fullfile(char(projectDir), 'analysis', 'track_exclusions.csv');
end

function ex = doLoad(projectDir)
ex = emptyEx();
f = exFile(projectDir);
if isempty(f) || ~isfile(f), return; end
try
    T = readtable(f, 'TextType','string', 'Delimiter',',');
catch
    return                                    % an unreadable list must not stop the analysis
end
if isempty(T) || ~all(ismember({'cell','track_col'}, T.Properties.VariableNames)), return; end
for i = 1:height(T)
    r = emptyEx(); r(1).file = char(T.cell(i)); r(1).col = double(T.track_col(i));
    if ismember('reason', T.Properties.VariableNames), r(1).reason = char(T.reason(i)); end
    if ~isfinite(r(1).col) || r(1).col < 1, continue; end
    ex(end+1) = r; %#ok<AGROW>
end
end

function ok = doSave(projectDir, ex)
ok = false;
f = exFile(projectDir);
if isempty(f), return; end
d = fileparts(f); if ~isfolder(d), mkdir(d); end
try
    fid = fopen(f,'w'); if fid < 0, return; end
    fprintf(fid,'cell,track_col,reason\n');
    for i = 1:numel(ex)
        fprintf(fid,'%s,%d,"%s"\n', ex(i).file, ex(i).col, strrep(ex(i).reason,'"',''''));
    end
    fclose(fid); ok = true;
catch
end
end

function ex = doToggle(ex, file, col, reason)
if nargin < 4, reason = ''; end
if isempty(ex), ex = emptyEx(); end
hit = findRow(ex, file, col);
if isempty(hit)
    r = emptyEx(); r(1).file = char(file); r(1).col = double(col); r(1).reason = char(reason);
    ex(end+1) = r;
else
    ex(hit) = [];                              % toggling an excluded track restores it
end
end

function tf = doHas(ex, file, col)
tf = ~isempty(findRow(ex, file, col));
end

function keep = doMask(ex, Tracks)
% One logical row per cell, true where the track is KEPT. Built against the ORIGINAL columns via
% srcCols, so a sliced struct masks correctly too.
keep = cell(numel(Tracks),1);
for k = 1:numel(Tracks)
    T = Tracks(k);
    if ~isfield(T,'matrix') || isempty(T.matrix), keep{k} = true(1,0); continue; end
    nT = size(T.matrix,2);
    src = srcColOf(T, 1:nT);
    m = true(1,nT);
    if ~isempty(ex) && isfield(T,'file')
        for j = 1:nT, m(j) = ~doHas(ex, char(T.file), src(j)); end
    end
    keep{k} = m;
end
end

function Tsub = doApply(ex, Tracks)
Tsub = Tracks;
if isempty(ex), return; end
keep = doMask(ex, Tracks);
if all(cellfun(@(m) all(m), keep)), return; end     % nothing excluded here: hand back the input
% Slice EVERY cell, even untouched ones, so the array is uniform — cs_track_slice adds .srcCols and
% a mixed array (some with it, some without) cannot be concatenated.
Tc = cell(numel(Tracks),1);
for k = 1:numel(Tracks)
    if isempty(keep{k}), Tc{k} = Tracks(k); continue; end
    Tc{k} = cs_track_slice(Tracks(k), find(keep{k}));
end
Tsub = vertcat(Tc{:})';
end

function src = srcColOf(T, cols)
% The ORIGINAL build column of these columns of T. cs_track_slice records srcCols on any subset;
% a full build has none, and there the column IS the original.
if isfield(T,'srcCols') && numel(T.srcCols) >= max(cols)
    src = T.srcCols(cols);
else
    src = cols;
end
src = double(src(:)');
end

function i = findRow(ex, file, col)
i = [];
if isempty(ex), return; end
i = find(strcmp({ex.file}, char(file)) & [ex.col] == double(col), 1);
end

function e = emptyEx()
e = struct('file',{},'col',{},'reason',{});
e(1).file = ''; e(1).col = 0; e(1).reason = '';
e(1) = [];
end
