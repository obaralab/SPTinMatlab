function cs_footprints_smoke()
% Validate the Refine->mapper contract: build auto footprints, MODIFY one, save CS_footprints.mat,
% and confirm cs_window_mapper (useRefined=true) applies the override (mode 'refined', changed area
% + changed membership) while useRefined=false ignores it.
here = fileparts(mfilename('fullpath')); addpath(here);
addpath(fileparts(fileparts(here)));   % repo root, where spt_test_data lives


% stage a private copy of Project/analysis (so we don't leave a CS_footprints.mat behind)
src = spt_test_data(fullfile('Project','analysis'));
if isempty(src)
    fprintf('SKIP %s — test dataset not installed (see spt_test_data.m)\n', mfilename);
    return
end
tmp = fullfile(tempdir,'cs_foot_smoke'); if isfolder(tmp), rmdir(tmp,'s'); end
mkdir(tmp); mkdir(fullfile(tmp,'csIDs')); mkdir(fullfile(tmp,'Densities'));
copyfile(fullfile(src,'TrackStruct.mat'), fullfile(tmp,'TrackStruct.mat'));
for L = dir(fullfile(src,'csIDs','*_CSsites.txt'))', copyfile(fullfile(L.folder,L.name), fullfile(tmp,'csIDs',L.name)); end
for L = dir(fullfile(src,'Densities','*_rho.tif'))', copyfile(fullfile(L.folder,L.name), fullfile(tmp,'Densities',L.name)); end

% 1) auto footprints
CSfoot = cs_footprints_build(tmp, struct('save',false,'verbose',false,'src','all'));
assert(~isempty(CSfoot),'no footprints built');
fprintf('built %d auto footprints\n', numel(CSfoot));

% baseline map (no refinement)
CSa = cs_window_mapper(tmp, struct('save',false,'verbose',false,'useRefined',false,'src','all'));

% 2) MODIFY footprint #1: shrink to a tiny 0.05 um box about its own centre -> should drop membership
k = 1;
tiny = 0.05*[-1 -1; 1 -1; 1 1; -1 1; -1 -1];
CSfoot(k).refboundary = tiny; CSfoot(k).mode = 'freehand'; CSfoot(k).areaUm2 = polyarea(tiny(:,1),tiny(:,2)); %#ok<NASGU>
save(fullfile(tmp,'CS_footprints.mat'),'CSfoot');

% 3) map WITH refinement
CSr = cs_window_mapper(tmp, struct('save',false,'verbose',false,'useRefined',true,'src','all'));

% locate the same site (file,csID,window) in both runs
key = @(e) sprintf('%s|%d|%d', e.file, e.csID, e.window);
ka = arrayfun(key, CSa, 'uni',0); kr = arrayfun(key, CSr, 'uni',0);
tk = key(CSfoot(k));
ia = find(strcmp(ka,tk),1); ir = find(strcmp(kr,tk),1);
assert(~isempty(ia)&&~isempty(ir),'target site not found in both runs');
fprintf('auto : mode=%-8s area=%.4f  memberLocs=%d\n', CSa(ia).footprintMode, CSa(ia).areaUm2, CSa(ia).nMemberLocs);
fprintf('refn : mode=%-8s area=%.4f  memberLocs=%d\n', CSr(ir).footprintMode, CSr(ir).areaUm2, CSr(ir).nMemberLocs);
assert(startsWith(CSr(ir).footprintMode,'refined'), 'mapper did not tag the site refined');
assert(CSr(ir).areaUm2 < CSa(ia).areaUm2, 'refined area should be smaller (we shrank it)');
assert(CSr(ir).nMemberLocs <= CSa(ia).nMemberLocs, 'refined membership should not exceed the auto one');
% the OTHER sites must be unchanged between the two runs (override is per-site)
other = find(~strcmp(kr,tk),1);
jo = find(strcmp(ka, kr{other}),1);
assert(abs(CSr(other).areaUm2 - CSa(jo).areaUm2) < 1e-9, 'a non-refined site changed — override leaked');

fprintf('\nALL FOOTPRINT-OVERRIDE ASSERTIONS PASSED.\n');
end
