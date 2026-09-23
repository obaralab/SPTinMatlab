function cs_condition_field_smoke()
%CS_CONDITION_FIELD_SMOKE  A cell's CONDITION has to live on the mapped site, not only in the
%manifest - and once several conditions exist, the cell has to be the unit of replication.
%
% WHAT IS ASSERTED:
%   1. THE FIELD IS WRITTEN from the manifest onto every site, and re-saved: .condition, .day, and
%      .excluded for a cell the manifest excludes.
%   2. A CELL WITH NO MANIFEST ROW gets an empty condition and is REPORTED, not given a guess.
%   3. IT SURVIVES A RE-RUN OF THE MAPPER: the stamping happens on save, so re-mapping does not
%      quietly drop it.
%   4. THE CLASSIFIER INHERITS IT without knowing the manifest exists, and SKIPS excluded cells by
%      default (includeExcluded keeps them).
%   5. THE HISTOGRAM GROUPS BY IT, each condition getting its own tau.
%   6. THE CELL IS THE UNIT OF REPLICATION: .byCell carries each cell's own median, .cellTest
%      compares those (exactly, when the groups are small), and a condition with fewer than three
%      cells is flagged - because the visit-level test counts 600 visits from 8 cells as 600
%      independent observations, which is how a difference passes a test it should not.
%   7. RE-STAMPING AFTER AN EDIT overwrites, so the record and the manifest cannot drift.
%   8. THE EXPERIMENT TAB'S BUTTON does it, for sites mapped before the conditions were assigned.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'), ...
        fullfile(root_,'tool3_contactsites','app'));

proj = fullfile(tempdir, sprintf('cs_condfield_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
ana = fullfile(proj,'analysis'); mkdir(ana); mkdir(fullfile(proj,'spt'));
cleanup = onCleanup(@() rmdir(proj,'s'));

%% fixture: 6 cells - 3 ctrl, 2 drug, 1 with no manifest row; one ctrl cell excluded --------------
rng(3); dt = 0.02; nF = 400; R = 0.15; th = linspace(0,2*pi,40)';
files = {'cA','cB','cC','dA','dB','orphan'};
for k = 1:numel(files)                       % a movie each, so the Experiment panel's scan finds them
    mv = fullfile(proj,'spt',[files{k} '.tif']);
    imwrite(uint16(zeros(8,8)), mv); imwrite(uint16(zeros(8,8)), mv, 'WriteMode','append');
end
tau   = [0.6 0.6 0.6 2.0 2.0 0.6];
CSW = struct([]);
for c = 1:numel(files)
    nTr = 12; X = ones(nF,nTr); Y = zeros(nF,nTr); F = repmat((0:nF-1)',1,nTr);
    for j = 1:8
        len = max(20, round(exprnd(tau(c))/dt));
        t0 = 20 + randi(120); t1 = min(nF-10, t0+len);
        X(t0:t1,j) = 0.01; Y(t0:t1,j) = 0.01;
    end
    CSW(end+1).file = files{c}; %#ok<AGROW>
    CSW(end).cellIndex = c; CSW(end).csID = 1; CSW(end).window = 1;
    CSW(end).winFrames = [0 nF-1]; CSW(end).siteUID = c; CSW(end).tracks = 1:nTr;
    CSW(end).CSmatrix = cat(3,F,X,Y); CSW(end).refboundary = R*[cos(th) sin(th)];
    CSW(end).dt = dt; CSW(end).MitoFlag = 0; CSW(end).refCenter = [5 5]; CSW(end).SF = 30;
end
save(fullfile(ana,'CSW_final.mat'),'CSW','-v7.3');

manifest = struct('folders',{{ana}},'cells',struct( ...
    'file',   {'cA','cB','cC','dA','dB'}, ...
    'folder', {ana,ana,ana,ana,ana}, ...
    'day',    {'d1','d1','d2','d1','d2'}, ...
    'condition',{'ctrl','ctrl','ctrl','drug','drug'}, ...
    'exclude',{false,false,true,false,false}));
save(fullfile(proj,'experiment_details.mat'),'manifest','-v7.3');

%% (1)(2) the field is written, and the orphan reported -----------------------------------------------
Rc = cs_condition_apply(ana, struct('verbose',false));
S = load(fullfile(ana,'CSW_final.mat')).CSW;
assert(all(isfield(S, {'condition','day','excluded'})), 'the three fields should be on the record');
cond = string({S.condition});
assert(cond(1) == "ctrl" && cond(4) == "drug", 'each site should carry its cell''s condition');
assert(string(S(3).day) == "d2", 'the day should come across too');
assert(S(3).excluded && ~S(1).excluded, 'the excluded cell should be flagged, not dropped');
assert(cond(6) == "", 'a cell with no manifest row gets no condition');
assert(numel(Rc.unmatched) == 1 && strcmp(Rc.unmatched{1},'orphan'), ...
    'the unmatched cell should be reported: %s', strjoin(Rc.unmatched, ', '));
assert(numel(Rc.conditions) == 2 && Rc.nExcluded == 1, 'the summary should say what was stamped');
ctrlRow = Rc.conditions(strcmp({Rc.conditions.condition},'ctrl'));
assert(ctrlRow.nCells == 3 && ctrlRow.nExcludedSites == 1, 'ctrl: 3 cells, 1 of them excluded');

%% (3) it survives the mapper's own save ------------------------------------------------------------
CSW2 = load(fullfile(ana,'CSW_final.mat')).CSW;
CSW2 = rmfield(CSW2, {'condition','day','excluded'});              % as a fresh mapper run would build it
out = cs_condition_apply(CSW2, struct('verbose',false,'save',false,'anaDir',ana));
assert(string(out.CSW(4).condition) == "drug", 'the mapper''s save path should re-stamp from the manifest');

%% (4) the classifier inherits it, and skips the excluded cell ----------------------------------------
G = cs_engage_classify(S, struct('verbose',false));
pc = string({G.perTrack.condition});
assert(all(ismember(unique(pc), ["ctrl" "drug" ""])), 'the condition should reach the track rows');
assert(~any(string({G.perSite.file}) == "cC"), 'the excluded cell should be skipped by default');
Gi = cs_engage_classify(S, struct('verbose',false,'includeExcluded',true));
assert(any(string({Gi.perSite.file}) == "cC"), 'includeExcluded should keep it');
assert(numel(Gi.perSite) == numel(G.perSite) + 1, 'and that should be the only difference');

%% (5)(6) grouped, and the cell is the unit ----------------------------------------------------------
H = cs_dwell_histogram(G, struct('group','condition'));
nm = string({H.groups.name});
assert(all(ismember(["ctrl" "drug"], nm)), 'both conditions should appear: %s', strjoin(nm, ', '));
tg = [H.groups.tau];
assert(tg(nm=="drug") > 1.5*tg(nm=="ctrl"), 'the longer condition should read longer (%.2f vs %.2f)', ...
    tg(nm=="drug"), tg(nm=="ctrl"));
assert(H.groups(nm=="ctrl").nCells == 2, 'ctrl has 2 cells left after the exclusion (got %d)', H.groups(nm=="ctrl").nCells);
assert(numel(H.byCell) >= 4, 'every cell should get its own row');
bc = H.byCell(strcmp({H.byCell.group},'drug'));
assert(numel(bc) == 2 && all([bc.n] > 0), 'the drug cells should each carry their own n and median');
assert(~isempty(H.cellTest), 'the cell-level comparison should be made');
assert(H.cellTest(1).exact, 'with 2 cells a side it should be enumerated, not approximated');
assert(H.cellTest(1).n1 == 2 && H.cellTest(1).n2 == 2, 'it should compare cells, not visits');
assert(any(contains(H.warnings,'cell(s) behind it')), ...
    'a condition with fewer than 3 cells should be flagged: %s', strjoin(H.warnings, ' / '));
ks = H.test(1).p;
assert(isfinite(H.cellTest(1).pAdj) && H.cellTest(1).pAdj >= H.cellTest(1).p, ...
    'the Holm-adjusted p should be reported and never below the raw one (%.3g vs %.3g)', ...
    H.cellTest(1).pAdj, H.cellTest(1).p);
assert(isscalar(H.cellTest) && abs(H.cellTest(1).pAdj - H.cellTest(1).p) < 1e-12, ...
    'with a single comparison there is nothing to adjust for');
assert(ks < H.cellTest(1).p, ...
    'the visit-level test should read more confident than the cell-level one (%.3g vs %.3g) — that is the point', ...
    ks, H.cellTest(1).p);

%% (7) re-stamping after an edit ---------------------------------------------------------------------
manifest.cells(4).condition = 'drug-hi';
save(fullfile(proj,'experiment_details.mat'),'manifest','-v7.3');
cs_condition_apply(ana, struct('verbose',false));
S2 = load(fullfile(ana,'CSW_final.mat')).CSW;
assert(string(S2(4).condition) == "drug-hi", 'a manifest edit should reach the record on the next stamp');

%% (8) the Experiment tab's button --------------------------------------------------------------------
CSW3 = load(fullfile(ana,'CSW_final.mat')).CSW;
CSW3 = rmfield(CSW3, {'condition','day','excluded'});      % as if mapped before conditions existed
save(fullfile(ana,'CSW_final.mat'),'CSW3','-v7.3');        % (renamed below — the loader wants CSW)
clear CSW3; L3 = load(fullfile(ana,'CSW_final.mat')); CSW = L3.CSW3; %#ok<NASGU>
save(fullfile(ana,'CSW_final.mat'),'CSW','-v7.3');
fig = uifigure('Visible','off'); closeFig = onCleanup(@() delete(fig));
ctl = spt_experiment_panel(fig, struct('seedFolders',{{proj}}));
ctl.load(fullfile(proj,'experiment_details.mat'));
btn = findobj(fig,'Type','uibutton');
hit = btn(arrayfun(@(b) contains(string(b.Text),'Stamp'), btn));
assert(~isempty(hit), 'the Experiment tab should offer a stamp button');
assert(numel(ctl.getCells()) == numel(files), ...
    'the panel should have loaded all %d cells (a manifest with no notes/reason field must not fail the load)', numel(files));
hit(1).ButtonPushedFcn(hit(1), struct());
S4 = load(fullfile(ana,'CSW_final.mat')).CSW;
assert(isfield(S4,'condition') && string(S4(4).condition) == "drug-hi", ...
    'the button should have written the conditions onto the mapped sites');
stat = '';
lb = findobj(fig,'Type','uilabel');
for q = 1:numel(lb)
    t = char(strjoin(string(lb(q).Text),' '));
    if contains(t,'Stamped'), stat = t; break; end
end
assert(contains(stat,'Stamped') && contains(stat,'site'), 'it should say what it did: "%s"', stat);
% a manifest that lists its folders only at the top level must work too
mTop = rmfield(manifest, 'cells');
mTop.cells = rmfield(manifest.cells, 'folder');
S5 = load(fullfile(ana,'CSW_final.mat')).CSW;
S5 = rmfield(S5, {'condition','day','excluded'}); CSW = S5; %#ok<NASGU>
save(fullfile(ana,'CSW_final.mat'),'CSW','-v7.3');
R5 = cs_condition_apply(ana, struct('manifest',mTop,'verbose',false));
assert(string(R5.CSW(4).condition) == "drug-hi", 'a manifest with folders only at the top level should still stamp');

fprintf(['conditions: stamped onto %d sites (%d conditions, 1 excluded cell, 1 orphan reported); ' ...
         'tau ctrl %.2f s vs drug %.2f s\n'], numel(S), numel(Rc.conditions), tg(nm=="ctrl"), tg(nm=="drug"));
fprintf('button: %s\n', stat);
fprintf('replication: %d cells behind the test — visits p=%.3g, cells p=%.3g (exact)\n', ...
    numel(H.byCell), ks, H.cellTest(1).p);
fprintf('\nCONDITION-FIELD SMOKE PASSED.\n');
end
