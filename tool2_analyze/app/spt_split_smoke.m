function spt_split_smoke()
% Verify the 3-tool split: spt_analyze_app builds in each mode with the right tab set + 1..N numbering,
% the Tool 2 wrapper (spt_curate_app == 'curate') opens the curate tabs, and setting a project in
% ANALYZE mode does not crash on the absent Import & Curate tab (the guarded embedImportCurate path).
here = fileparts(mfilename('fullpath')); addpath(here);
proj = '/Users/safal-mac/Desktop/IntegratedPipeline/Project';

want = struct( ...
    'curate',  {{'Import & Curate','Build & QC','Experiment'}}, ...
    'analyze', {{'Contact sites','Refine','Sites','Dwell','Experiment','Compare'}}, ...
    'full',    {{'Import & Curate','Build & QC','Contact sites','Refine','Sites','Dwell','Experiment','Compare'}});

for m = {'curate','analyze','full'}
    mode = m{1};
    f = spt_analyze_app(mode);
    tg = findobj(f,'Type','uitabgroup'); assert(~isempty(tg),'[%s] no tabgroup',mode);
    [titles, nums] = tabTitles(tg);   % sorted by displayed tab number (Children order isn't guaranteed)
    exp = want.(mode);
    assert(isequal(titles(:)', exp), '[%s] tabs = {%s}, wanted {%s}', mode, strjoin(titles,', '), strjoin(exp,', '));
    assert(isequal(nums(:)', 1:numel(exp)), '[%s] numbering not 1..N: %s', mode, mat2str(nums(:)'));

    % set a project through the public callback -> setProject -> embedImportCurate (guarded in analyze)
    setStatus = '';
    if isfolder(proj)
        pe = findProjectField(f);
        if ~isempty(pe)
            pe.Value = proj; cb = pe.ValueChangedFcn;
            if ~isempty(cb), cb(pe, struct('Value',proj)); end    % must NOT error in any mode
            setStatus = ' (+project set)';
        end
    end
    fprintf('[%s] %d tabs OK%s: %s\n', mode, numel(titles), setStatus, strjoin(titles,' | '));
    delete(f);
end

% the wrapper must open 'curate'
fw = spt_curate_app();
tg = findobj(fw,'Type','uitabgroup');
titles = tabTitles(tg);
assert(isequal(titles(:)', want.curate), 'wrapper did not open curate mode');
fprintf('spt_curate_app -> %s\n', strjoin(titles,' | '));
delete(fw);

fprintf('\nALL 3-TOOL SPLIT ASSERTIONS PASSED.\n');
end

function [titles, nums] = tabTitles(tg)
% tab titles + numbers, sorted by the displayed "N · " prefix (Children order isn't guaranteed)
tabs = tg.Children;
nums = arrayfun(@(t) sscanf(t.Title,'%d'), tabs);
[nums, ord] = sort(nums(:)');
tabs = tabs(ord);
titles = arrayfun(@(t) regexprep(t.Title,'^\d+\s·\s',''), tabs, 'uni',0);
end

function pe = findProjectField(f)
% the top-bar project box: the control whose placeholder mentions "project"
pe = [];
for e = findobj(f)'
    if isprop(e,'Placeholder')
        try, pl = e.Placeholder; catch, pl = ''; end
        if (ischar(pl)||isstring(pl)) && contains(lower(char(pl)),'project'), pe = e; return; end
    end
end
end
