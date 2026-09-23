function R = cs_condition_apply(src, opts)
%CS_CONDITION_APPLY  Write each cell's CONDITION onto the mapped sites, as a field they carry.
%
%   R = cs_condition_apply(anaDir)              % stamps and re-saves analysis/CSW_final.mat
%   R = cs_condition_apply(anaDir, opts)
%   R = cs_condition_apply(CSW, opts)           % or stamp an array in memory
%
% The experiment manifest (<project>/experiment_details.mat) is where a cell's condition is assigned,
% and until now that was the ONLY place it lived: cs_experiment_aggregate attached it to a combined
% array it built in memory, so anything reading analysis/CSW_final.mat on its own - the Dwell tab, the
% engagement classifier, an export - saw no condition at all and pooled every cell together. This
% puts it ON the record, next to the site it belongs to, so every stage downstream inherits it without
% knowing the manifest exists.
%
% THREE FIELDS, from the manifest row that matches the site's cell file:
%   .condition  the condition name ('' when that cell has no row - reported, not invented)
%   .day        the day/batch it was collected on, when the manifest carries one
%   .excluded   true when the manifest excludes that cell. The cell is NOT dropped here: a site that
%               is excluded still exists, and a stage that pools should say so. cs_engage_classify
%               skips excluded sites by default; cs_experiment_aggregate drops them outright.
%
% Fields already on the record are overwritten, so re-running after an edit in the Experiment tab is
% how you keep the two in step. Nothing else on the record is touched.
%
% opts: .manifest (struct, or a path to one; default: found from the project folder)
%       .anaDir where to look for it when a CSW array was passed rather than a folder
%       .save (true when a folder was given) .verbose (true)
%
% OUTPUT R: .CSW the stamped array; .conditions one row per condition with its site and cell counts;
%           .unmatched the cell files with no manifest row; .nExcluded sites flagged excluded.

if nargin < 2 || ~isstruct(opts), opts = struct(); end
here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));
addpath(fullfile(root_,'tool2_analyze','drivers'));
verb = getf(opts,'verbose',true);

anaDir = '';
if ischar(src) || isstring(src)
    anaDir = char(src);
    f = fullfile(anaDir,'CSW_final.mat');
    assert(isfile(f),'cs_condition_apply:noCSW','Run the mapper first — missing %s', f);
    CSW = load(f).CSW;
else
    CSW = src;
end
anaDir = getf(opts,'anaDir',anaDir);     % a caller holding CSW can still say where to find the manifest
doSave = getf(opts,'save',~isempty(anaDir));
assert(~isempty(CSW),'cs_condition_apply:empty','no mapped sites to stamp');

man = getf(opts,'manifest',[]);
if isempty(man) || ischar(man) || isstring(man)
    man = loadManifest(man, anaDir);
end
assert(isstruct(man) && isfield(man,'cells') && ~isempty(man.cells), 'cs_condition_apply:noManifest', ...
    ['no experiment manifest with cells — assign conditions in the Experiment tab first, or pass ' ...
     'opts.manifest']);
cells = man.cells;

% file -> row. Matched on the cell file, by its exact spelling first and then by base name, because
% a manifest row can carry the name with or without its extension.
byName = containers.Map('KeyType','char','ValueType','double');
for k = 1:numel(cells)
    nm = char(cells(k).file);
    byName(nm) = k;
    [~, b] = fileparts(nm);
    if ~isKey(byName, b), byName(b) = k; end
end

nEx = 0; unmatched = {};
for k = 1:numel(CSW)
    nm = char(CSW(k).file);
    [~, b] = fileparts(nm);
    idx = 0;
    if isKey(byName, nm), idx = byName(nm);
    elseif isKey(byName, b), idx = byName(b); end
    if idx == 0
        CSW(k).condition = ''; CSW(k).day = ''; CSW(k).excluded = false;
        if ~any(strcmp(unmatched, nm)), unmatched{end+1} = nm; end %#ok<AGROW>
        continue;
    end
    c = cells(idx);
    CSW(k).condition = char(fieldOr(c,'condition',''));
    CSW(k).day       = char(string(fieldOr(c,'day','')));
    ex = fieldOr(c,'exclude',false);
    CSW(k).excluded  = ~isempty(ex) && logical(ex);
    nEx = nEx + CSW(k).excluded;
end

% ---- what was stamped ----
cond = string({CSW.condition}); files = string({CSW.file});
u = unique(cond(cond ~= ""), 'stable');
C = struct('condition',{},'nSites',{},'nCells',{},'nExcludedSites',{});
for q = 1:numel(u)
    m = cond == u(q);
    C(end+1) = struct('condition',char(u(q)),'nSites',nnz(m), ...
        'nCells',numel(unique(files(m))),'nExcludedSites',nnz(m & [CSW.excluded])); %#ok<AGROW>
end
R = struct('CSW',CSW,'conditions',C,'unmatched',{unmatched},'nExcluded',nEx);

if doSave && ~isempty(anaDir)
    save(fullfile(anaDir,'CSW_final.mat'),'CSW','-v7.3');
end
if verb
    fprintf('conditions stamped onto %d site-windows: ', numel(CSW));
    fprintf('%s ', string(strjoin(arrayfun(@(x) sprintf('%s (%d sites/%d cells)', x.condition, x.nSites, x.nCells), C, 'uni', 0), ', ')));
    fprintf('\n');
    if nEx > 0, fprintf('  %d site(s) belong to cells the manifest excludes (.excluded = true, not dropped here)\n', nEx); end
    if ~isempty(unmatched)
        fprintf('  %d cell(s) have no manifest row, so no condition: %s\n', numel(unmatched), ...
            strjoin(unmatched(1:min(3,end)), ', '));
    end
    if doSave && ~isempty(anaDir), fprintf('  re-saved %s\n', fullfile(anaDir,'CSW_final.mat')); end
end
end

% =================================================================================================
function man = loadManifest(p, anaDir)
man = [];
if ~isempty(p) && (ischar(p) || isstring(p))
    p = char(p);
else
    assert(~isempty(anaDir),'cs_condition_apply:noManifest', ...
        'pass opts.manifest, or a project folder to find experiment_details.mat in');
    [~, existing] = cs_experiment_file(fileparts(anaDir));   % the project folder holds it, not analysis/
    p = existing;
end
assert(~isempty(p) && isfile(p),'cs_condition_apply:noManifest', ...
    'no experiment_details.mat found — assign conditions in the Experiment tab first');
L = load(p);
if isfield(L,'manifest'), man = L.manifest; elseif isfield(L,'cells'), man = L; end
end

function v = fieldOr(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
