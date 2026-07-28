function T = pool_projects(source, varargin)
%POOL_PROJECTS  Pool ContactSites per-site metrics across collection days into one labelled table.
%
%   T = pool_projects(source)
%   T = pool_projects(source, 'Name',Value, ...)
%
% Reads the pipeline's per-site CSV(s) and returns ONE table with provenance columns added
% (day / condition / cellNum / sourceCSV), so you can group and compare across days. The day
% and condition are parsed from each row's `file` prefix (e.g. 250408_FFAT_001_spt1 -> day
% 2025-04-08, condition FFAT, cell 1), which is robust whether your data lives in one combined
% project or one project per day.
%
% SOURCE (any of):
%   - a single analysis folder, e.g. 'Project/analysis'         (ONE combined project: days come
%       that directly contains the CSV                            from the parsed file prefixes)
%   - a project folder that CONTAINS an 'analysis' subfolder, e.g. 'Project'
%   - a PARENT folder whose subfolders are per-day projects, e.g. 'AllDays'  (each subfolder that
%       has <Analysis>/<Metrics> or <Metrics> is pooled; the subfolder name is kept as sourceDir)
%   - a cell array / string array of any of the above, e.g. {'day1','day2/analysis'}
%
% NAME-VALUE:
%   'Analysis' (default 'analysis')                subfolder holding the CSV inside a project dir
%   'Metrics'  (default 'cs_density_metrics.csv')  the CSV to pool (any per-site/per-track pipeline CSV)
%   'Out'      (default '')                         if non-empty, write the pooled table to this .csv
%   'Verbose'  (default true)                       print a per-day QC summary
%
% OUTPUT: T (table) = every source CSV concatenated, with these columns prepended/appended:
%   sourceCSV  - which file the row came from (full provenance)
%   day        - parsed collection day as 'yyyy-MM-dd' (from the file prefix; '' if unparseable)
%   date       - the same as a datetime (NaT if unparseable)
%   condition  - the token(s) between the date and the trailing cell number (e.g. 'FFAT')
%   cellNum    - the trailing cell number in the prefix (NaN if none)
%
% EXAMPLES
%   % one combined project -> label its single CSV by day and save:
%   T = pool_projects('Project', 'Out','Project/combined_metrics.csv');
%
%   % several per-day project folders under one parent:
%   T = pool_projects('AllDays');
%
%   % explicit list of analysis dirs:
%   T = pool_projects({'2025-04-08/analysis','2025-04-11/analysis'});
%
%   % then, e.g., compare a metric across days:
%   groupsummary(T, {'day','condition'}, {'median','numel'}, 'prob_mass')
%
% Pools ANY of the pipeline's flat CSVs by changing 'Metrics' (e.g. a dwell export).

ip = inputParser;
ip.addParameter('Analysis','analysis',@(s)ischar(s)||isstring(s));
ip.addParameter('Metrics','cs_density_metrics.csv',@(s)ischar(s)||isstring(s));
ip.addParameter('Out','',@(s)ischar(s)||isstring(s));
ip.addParameter('Verbose',true,@(x)islogical(x)||isnumeric(x));
ip.parse(varargin{:});
opt = ip.Results; ana = char(opt.Analysis); metrics = char(opt.Metrics);

csvs = resolveSources(source, ana, metrics);
if isempty(csvs)
    error('pool_projects:noCSV', ['No "%s" found under the given source(s). Point at an analysis ' ...
        'folder, a project folder, a parent of per-day projects, or a list of those.'], metrics);
end

T = table();
for i = 1:numel(csvs)
    f = csvs{i};
    try
        t = readtable(f);
    catch ME
        warning('pool_projects:read','Skipping %s (%s)', f, ME.message); continue;
    end
    if isempty(t), continue; end
    n = height(t);
    % provenance + parsed day/condition/cell from the `file` column (fallback: folder name)
    t.sourceCSV = repmat(string(f), n, 1);
    day = strings(n,1); dt = NaT(n,1); cond = strings(n,1); cellNum = nan(n,1);
    if ismember('file', t.Properties.VariableNames)
        for r = 1:n
            [day(r), dt(r), cond(r), cellNum(r)] = parseFilePrefix(string(t.file(r)));
        end
    end
    % if the file prefix carried no date, fall back to the containing folder name as the day label
    if all(day=="")
        [~, folderDay] = fileparts(fileparts(fileparts(f)));   % <folderDay>/<Analysis>/<Metrics>
        if strcmpi(folderDay, ana) || folderDay=="", [~, folderDay] = fileparts(fileparts(f)); end
        day(:) = string(folderDay);
    end
    t.day = day; t.date = dt; t.condition = cond; t.cellNum = cellNum;
    T = appendRows(T, t);
end

if isempty(T), error('pool_projects:empty','All source CSVs were empty or unreadable.'); end

% move the provenance columns to the front for readability
front = intersect({'day','condition','cellNum','sourceCSV','date'}, T.Properties.VariableNames, 'stable');
rest  = setdiff(T.Properties.VariableNames, front, 'stable');
T = T(:, [front, rest]);

if ~isempty(char(opt.Out))
    writetable(T, char(opt.Out));
    if opt.Verbose, fprintf('pool_projects: wrote %d rows -> %s\n', height(T), char(opt.Out)); end
end

if opt.Verbose
    fprintf('pool_projects: pooled %d row(s) from %d CSV(s), %d day(s).\n', ...
        height(T), numel(csvs), numel(unique(T.day)));
    % per-day QC so you can check reproducibility BEFORE pooling across days
    keyVars = intersect({'day','condition'}, T.Properties.VariableNames, 'stable');
    metricVar = firstPresent(T, {'prob_mass','probMass','dwell_s','enrichment'});
    try
        if ~isempty(metricVar)
            g = groupsummary(T, keyVars, {'numel','median'}, metricVar);
            disp('  per-day summary:'); disp(g);
        else
            disp('  per-day counts:'); disp(groupsummary(T, keyVars));
        end
    catch, end
    fprintf(['  TIP: check the days agree before pooling, e.g.\n' ...
             '       groupsummary(T, {''day'',''condition''}, {''median'',''numel''}, ''prob_mass'')\n']);
end
end

% ===================================================================================
function csvs = resolveSources(source, ana, metrics)
% expand `source` into a flat list of metrics-CSV file paths.
csvs = {};
if iscell(source) || (isstring(source) && numel(source) > 1)
    src = cellstr(string(source));
    for i = 1:numel(src), csvs = [csvs, resolveOne(char(src{i}), ana, metrics)]; end %#ok<AGROW>
else
    csvs = resolveOne(char(string(source)), ana, metrics);
end
csvs = unique(csvs, 'stable');
end

function out = resolveOne(d, ana, metrics)
out = {};
if isfile(d) && endsWith(lower(d), '.csv'), out = {d}; return; end     % a CSV path directly
if ~isfolder(d), return; end
direct    = fullfile(d, metrics);
directAna = fullfile(d, ana, metrics);
if isfile(direct),    out = {direct};    return; end                  % <d>/<Metrics>  (analysis folder itself)
if isfile(directAna), out = {directAna}; return; end                  % <d>/analysis/<Metrics> (project folder)
% otherwise treat d as a PARENT of per-day projects: scan its subfolders
s = dir(d); s = s([s.isdir] & ~startsWith({s.name}, '.'));
for i = 1:numel(s)
    sd = fullfile(d, s(i).name);
    if     isfile(fullfile(sd, ana, metrics)), out{end+1} = fullfile(sd, ana, metrics); %#ok<AGROW>
    elseif isfile(fullfile(sd, metrics)),      out{end+1} = fullfile(sd, metrics);      %#ok<AGROW>
    end
end
end

% ===================================================================================
function [dayStr, dt, cond, cellNum] = parseFilePrefix(fname)
% 250408_FFAT_001_spt1 -> day '2025-04-08', condition 'FFAT', cell 1.
dayStr = ""; dt = NaT; cond = ""; cellNum = NaN;
s = char(fname);
s = regexprep(s, '_spt\d+$', '', 'ignorecase');            % strip the _sptK acquisition tag
s = regexprep(s, '_tracks$', '', 'ignorecase');
tok = regexp(s, '^(\d{8}|\d{6})[_-](.*)$', 'tokens', 'once');
if isempty(tok)
    cond = string(s);                                       % no leading date -> keep whole prefix as condition
    return;
end
dnum = tok{1}; rest = tok{2};
if numel(dnum) == 6, y = 2000 + str2double(dnum(1:2)); mo = str2double(dnum(3:4)); da = str2double(dnum(5:6));
else,                y = str2double(dnum(1:4));        mo = str2double(dnum(5:6)); da = str2double(dnum(7:8)); end
try
    dt = datetime(y, mo, da); dt.Format = 'yyyy-MM-dd'; dayStr = string(dt);
catch, end
ct = regexp(rest, '(?i)[_-]?(?:cell)?(\d+)$', 'tokens', 'once');   % trailing cell number (with or without a "cell" word)
if ~isempty(ct), cellNum = str2double(ct{1}); end
cond = string(regexprep(rest, '(?i)[_-]?(?:cell)?\d+$', ''));      % condition = the rest minus the trailing cell token
end

% ===================================================================================
function T = appendRows(T, t)
% vertcat two tables that may not share every column (fill missing with NaN/"" so pooling never fails).
if isempty(T), T = t; return; end
allv = union(T.Properties.VariableNames, t.Properties.VariableNames, 'stable');
T = padTable(T, allv); t = padTable(t, allv);
T = [T; t(:, T.Properties.VariableNames)];
end

function t = padTable(t, allv)
missingV = setdiff(allv, t.Properties.VariableNames, 'stable');
for k = 1:numel(missingV)
    t.(missingV{k}) = repmat(missing, height(t), 1);       % `missing` fills numeric NaN / string <missing>
end
end

function v = firstPresent(T, names)
v = '';
for i = 1:numel(names)
    if ismember(names{i}, T.Properties.VariableNames), v = names{i}; return; end
end
end
