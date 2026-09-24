function spt_split_smoke()
% Verify the 3-tool split: spt_analyze_app builds in each mode with the right tab set + 1..N numbering,
% the Tool 2 wrapper (spt_curate_app == 'curate') opens the curate tabs, and setting a project in
% ANALYZE mode does not crash on the absent Import & Curate tab (the guarded embedImportCurate path).
% Four tools now: curation (Tool 2), building and reading the build (Tool 3), and the contact-site
% work (Tool 4). 'analyze' is kept as the old name for 'contactsites' and is checked below.
here = fileparts(mfilename('fullpath')); addpath(here);
addpath(fileparts(fileparts(here)));   % repo root, where spt_test_data lives
% The reference project is OPTIONAL to this test: every tab-set assertion below is built from the
% app alone and needs no data. A project only buys the extra setProject -> embedImportCurate leg, so
% when the dataset is absent the test still runs in full — it just says which leg it lost.
proj = spt_test_data('Project');
if isempty(proj)
    fprintf('NOTE %s — test dataset not installed, skipping the set-a-project step (see spt_test_data.m)\n', mfilename);
end

% Experiment is tab 1 in EVERY mode (and in Tool 1) — the manifest is the setup step and lives in
% the same place whichever tool you opened.
want = struct( ...
    'curate',       {{'Experiment','Import & Curate'}}, ...
    'analysis',     {{'Experiment','Build / Analyse'}}, ...
    'contactsites', {{'Experiment','Contact sites','Refine','Sites','Dwell','Engagement','Compare'}}, ...
    'full',         {{'Experiment','Import & Curate','Build / Analyse','Contact sites','Refine','Sites','Dwell','Engagement','Compare'}});

for m = {'curate','analysis','contactsites','full'}
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

% 'analyze' was this mode's name when the toolkit had three tools, and notes and scripts still say
% it — it has to keep opening the contact-site tool rather than erroring on an unknown mode.
fa = spt_analyze_app('analyze');
ta = tabTitles(findobj(fa,'Type','uitabgroup'));
assert(isequal(ta(:)', want.contactsites), ...
    'the old ''analyze'' name should still open the contact-site tool, got: %s', strjoin(ta,' | '));
delete(fa);
fd = spt_analyze_app();                                   % and the default is that tool too
td = tabTitles(findobj(fd,'Type','uitabgroup'));
assert(isequal(td(:)', want.contactsites), 'the default mode should be the contact-site tool');
delete(fd);

fprintf('\nALL 4-TOOL SPLIT ASSERTIONS PASSED.\n');
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
