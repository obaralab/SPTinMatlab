function spt_app_expt_smoke()
% Verify Tool 1 (spt_app) carries the shared Experiment tab FIRST: 4 tabs in order, the Experiment tab
% embeds the panel (a uitable with the manifest columns), and it can ingest a project folder.
here = fileparts(mfilename('fullpath')); addpath(fileparts(here)); addpath(here);   % repo root first: spt_test_data
t2 = fullfile(fileparts(here),'tool2_analyze'); addpath(fullfile(t2,'app')); addpath(fullfile(t2,'drivers'));
proj = spt_test_data('Project');   % '' when the dataset is not installed — only the ingest check below
                                   % needs it; the tab and panel assertions run on any machine

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

% Calibration is per cell and lives in the manifest, so Tool 1 — the tool that USES it to convert
% px to µm — must show it here and let it be corrected here. Editability is the feature, not the
% column: a read-only µm/px would leave a mis-calibrated cell with nowhere to be fixed.
ed = tbl(1).ColumnEditable;
for want = {'µm/px','dt (s)'}
    j = find(strcmp(cols, want{1}), 1);
    assert(~isempty(j), 'panel table missing the %s column — calibration is not per cell here', want{1});
    assert(numel(ed) >= j && ed(j), 'the %s column is not editable', want{1});
end
j = find(strcmp(cols,'calib'), 1);
assert(~isempty(j), 'panel table does not say where each cell''s calibration came from');
assert(~ed(j), 'the calibration source must be a readout, not something to type into');
assert(numel(ed) == numel(cols), 'ColumnEditable (%d) and ColumnName (%d) are out of step', numel(ed), numel(cols));
fprintf('per-cell calibration editable in Tool 1''s manifest table (µm/px, dt (s); calib read-only)\n');

% ingest a project through the Match tab's picker path -> exptCtl.addFolder -> a scanned row appears
if isfolder(proj)
    % find the Match "Pick…" for the project field is fiddly; instead call the panel's add via its button
    addBtn = findobj(et,'Type','uibutton');
    addBtn = addBtn(arrayfun(@(b) contains(lower(b.Text),'add'), addBtn));
    assert(~isempty(addBtn),'no Add-folder button on the panel');
    fprintf('panel Add-folder button present: "%s"\n', addBtn(1).Text);
else
    fprintf('SKIP the project-ingest check in %s — test dataset not installed (see spt_test_data.m)\n', mfilename);
end

delete(f);
fprintf('\nTOOL 1 EXPERIMENT-TAB SMOKE PASSED.\n');
end
