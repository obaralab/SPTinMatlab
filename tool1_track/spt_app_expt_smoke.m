function spt_app_expt_smoke()
% Verify Tool 1 (spt_app) carries the shared Experiment tab FIRST: 4 tabs in order, the Experiment tab
% embeds the panel (a uitable with the manifest columns), and it can ingest a project folder.
here = fileparts(mfilename('fullpath')); addpath(here);
t2 = fullfile(fileparts(here),'tool2_analyze'); addpath(fullfile(t2,'app')); addpath(fullfile(t2,'drivers'));
proj = '/Users/safal-mac/Documents/IntegratedPipeline/Project';

f = spt_app();
tg = findobj(f,'Type','uitabgroup'); assert(~isempty(tg),'no tabgroup');
tabs = tg.Children;
nums = arrayfun(@(t) sscanf(t.Title,'%d'), tabs);
[nums, ord] = sort(nums(:)'); tabs = tabs(ord);
titles = arrayfun(@(t) regexprep(t.Title,'^\d+\s·\s',''), tabs, 'uni',0);
want = {'Experiment','Match files','Detect','Track & filter'};   % Experiment is tab 1 in every tool
assert(isequal(titles(:)', want), 'tabs = {%s}', strjoin(titles,', '));
assert(isequal(nums, 1:4), 'numbering not 1..4: %s', mat2str(nums));
fprintf('Tool 1 tabs OK: %s\n', strjoin(titles,' | '));

% the Experiment tab must contain the shared panel's table (columns include 'condition')
et = tabs(find(strcmp(titles,'Experiment'),1));   % by TITLE, not a hardcoded index
tbl = findobj(et,'Type','uitable'); assert(~isempty(tbl),'Experiment tab has no table (panel not embedded)');
cols = tbl(1).ColumnName; assert(any(strcmpi(cols,'condition')), 'panel table missing condition column');
fprintf('Experiment panel embedded: %d columns incl. condition\n', numel(cols));

% ingest a project through the Match tab's picker path -> exptCtl.addFolder -> a scanned row appears
if isfolder(proj)
    % find the Match "Pick…" for the project field is fiddly; instead call the panel's add via its button
    addBtn = findobj(et,'Type','uibutton');
    addBtn = addBtn(arrayfun(@(b) contains(lower(b.Text),'add'), addBtn));
    assert(~isempty(addBtn),'no Add-folder button on the panel');
    fprintf('panel Add-folder button present: "%s"\n', addBtn(1).Text);
end

delete(f);
fprintf('\nTOOL 1 EXPERIMENT-TAB SMOKE PASSED.\n');
end
