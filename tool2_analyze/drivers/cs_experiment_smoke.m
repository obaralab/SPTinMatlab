function cs_experiment_smoke()
% Validate the experiment engine: build two "day" folders (each with its own TrackStruct + picked
% sites), map + dwell each, then scan + aggregate across both with per-cell CONDITIONS assigned, and
% confirm the combined CSW/DD carry the right condition labels and group correctly.
here = fileparts(mfilename('fullpath')); addpath(here); addpath(fullfile(here,'..','ContactSites_robust'));
src = '/Users/safal-mac/Desktop/IntegratedPipeline/Project/analysis';
S = load(fullfile(src,'TrackStruct.mat')); fn=fieldnames(S); Tr=S.(fn{1});
assert(numel(Tr)>=2,'need >=2 cells to split into two day-folders');

root = fullfile(tempdir,'cs_expt'); if isfolder(root), rmdir(root,'s'); end
dayA = fullfile(root,'dayA','analysis'); dayB = fullfile(root,'dayB','analysis');
mkFolder(dayA, Tr(1), src); mkFolder(dayB, Tr(2), src);

% map + dwell each folder (persist CSW_final + cs_window_dwell)
for fo = {dayA, dayB}
    cs_window_mapper(fo{1}, struct('save',true,'verbose',false,'useRefined',false));
    cs_window_dwell(fo{1}, struct('save',true,'verbose',false));
end

% scan both folders
cells = cs_experiment_scan({dayA, dayB});
fprintf('scanned %d cell(s) across 2 folders\n', numel(cells));
assert(numel(cells)==2, 'expected 2 cells');
assert(all([cells.hasCSW]) && all([cells.hasDwell]), 'CSW/dwell not detected');
% derived status matrix
st = [cells.status];
fprintf('status: built=%d mapped=%d dwelled=%d (of 2)\n', nnz([st.built]), nnz([st.mapped]), nnz([st.dwelled]));
assert(all([st.built]) && all([st.mapped]) && all([st.dwelled]), 'status not derived correctly');
assert(all(arrayfun(@(c) c.nTracks>0, cells)), 'nTracks not populated');

% assign conditions: dayA cell -> "WT", dayB cell -> "FFAT"
for k=1:numel(cells)
    if contains(cells(k).folder,'dayA'), cells(k).condition='WT'; else, cells(k).condition='FFAT'; end
end
manifest = struct('folders',{{dayA,dayB}}, 'cells', cells);

% aggregate
[CSW, DD] = cs_experiment_aggregate(manifest);
conds = unique({CSW.condition});
fprintf('combined %d sites; conditions present: %s\n', numel(CSW), strjoin(conds,', '));
assert(numel(CSW) >= 2, 'no sites combined');
assert(isequal(sort(conds), {'FFAT','WT'}), 'conditions not tagged correctly: %s', strjoin(conds,','));
% every site's condition must match its source folder
for k=1:numel(CSW)
    want = 'FFAT'; if contains(CSW(k).srcFolder,'dayA'), want='WT'; end
    assert(strcmp(CSW(k).condition,want), 'site condition mismatch');
end
% dwell events also tagged + groupable
assert(~isempty(DD.events),'no dwell events combined');
evConds = unique({DD.events.condition});
fprintf('combined %d dwell events; conditions: %s\n', numel(DD.events), strjoin(evConds,', '));
assert(isequal(sort(evConds), {'FFAT','WT'}), 'event conditions wrong');
% per-condition site counts
nWT   = nnz(strcmp({CSW.condition},'WT'));
nFFAT = nnz(strcmp({CSW.condition},'FFAT'));
fprintf('sites: WT=%d  FFAT=%d\n', nWT, nFFAT);
assert(nWT>0 && nFFAT>0, 'a condition has no sites');

% exclude: mark the FFAT cell excluded -> its sites drop from the aggregate
for k=1:numel(cells), cells(k).exclude = strcmp(cells(k).condition,'FFAT'); end
manifest.cells = cells;
[CSWx, DDx] = cs_experiment_aggregate(manifest);
fprintf('after excluding FFAT: %d sites (was %d); conditions: %s\n', numel(CSWx), numel(CSW), strjoin(unique({CSWx.condition}),','));
assert(numel(CSWx)==nWT, 'exclude did not drop the FFAT sites');
assert(~any(strcmp({CSWx.condition},'FFAT')), 'excluded FFAT still present');
assert(~any(strcmp({DDx.events.condition},'FFAT')), 'excluded FFAT events still present');

fprintf('\nALL EXPERIMENT-ENGINE ASSERTIONS PASSED.\n');
end

function mkFolder(anaDir, Tcell, src)
mkdir(anaDir); mkdir(fullfile(anaDir,'csIDs')); mkdir(fullfile(anaDir,'Densities'));
Tracks = Tcell; save(fullfile(anaDir,'TrackStruct.mat'),'Tracks'); %#ok<NASGU>
base = regexprep(char(Tcell.file),'\.[^.]*$','');
cp(fullfile(src,'csIDs',[base '_CSsites.txt']), fullfile(anaDir,'csIDs',[base '_CSsites.txt']));
Lr = dir(fullfile(src,'Densities',[base '*_rho.tif'])); if ~isempty(Lr), cp(fullfile(Lr(1).folder,Lr(1).name), fullfile(anaDir,'Densities',Lr(1).name)); end
end
function cp(a,b), if isfile(a), copyfile(a,b); end, end
