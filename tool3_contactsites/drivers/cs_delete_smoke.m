function cs_delete_smoke()
% Validate the delete-and-sync contract: a CSdeleted entry in CS_footprints.mat makes the mapper
% SKIP that site (pickPx-guarded), while every other site is unaffected.
here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));          % the two tools share the build, the channels and the manifest
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'), ...
        fullfile(root_,'tool3_contactsites','app'));
addpath(fileparts(fileparts(here)));   % repo root, where spt_test_data lives
% Needs a REAL built project: deleting site #2 and #3 only means something on a real picked list.
src = spt_test_data(fullfile('Project','analysis'));
if isempty(src)
    fprintf('SKIP %s — test dataset not installed (see spt_test_data.m)\n', mfilename);
    return
end
tmp = fullfile(tempdir,'cs_del_smoke'); if isfolder(tmp), rmdir(tmp,'s'); end
mkdir(tmp); mkdir(fullfile(tmp,'csIDs')); mkdir(fullfile(tmp,'Densities'));
copyfile(fullfile(src,'TrackStruct.mat'), fullfile(tmp,'TrackStruct.mat'));
for L = dir(fullfile(src,'csIDs','*_CSsites.txt'))', copyfile(fullfile(L.folder,L.name), fullfile(tmp,'csIDs',L.name)); end
for L = dir(fullfile(src,'Densities','*_rho.tif'))', copyfile(fullfile(L.folder,L.name), fullfile(tmp,'Densities',L.name)); end

CSW0 = cs_window_mapper(tmp, struct('save',false,'verbose',false,'useRefined',false));
n0 = numel(CSW0);
CSfoot = cs_footprints_build(tmp, struct('save',false,'verbose',false));
CSfoot0 = CSfoot;   % keep the unedited list; CSfoot is emptied below

% delete site #2 (record file/csID/window/pickPx)
d = CSfoot(2);
CSdeleted = struct('file',d.file,'csID',d.csID,'window',d.window,'pickPx',d.pickPx); %#ok<NASGU>
CSfoot = CSfoot([]); %#ok<NASGU>   % no footprint edits, only a deletion
save(fullfile(tmp,'CS_footprints.mat'),'CSfoot','CSdeleted');

CSW1 = cs_window_mapper(tmp, struct('save',false,'verbose',false,'useRefined',true));
n1 = numel(CSW1);
fprintf('sites before delete = %d, after = %d (expect %d)\n', n0, n1, n0-1);
assert(n1 == n0-1, 'mapper did not drop exactly one deleted site');
key = @(e) sprintf('%s|%d|%d', e.file, e.csID, e.window);
assert(~any(strcmp(arrayfun(key,CSW1,'uni',0), key(d))), 'the deleted site is still present');
% a stale deletion (pickPx moved) must NOT drop a site
CSdeleted.pickPx = d.pickPx + [50 50]; %#ok<STRNU>
save(fullfile(tmp,'CS_footprints.mat'),'CSfoot','CSdeleted');
CSW2 = cs_window_mapper(tmp, struct('save',false,'verbose',false,'useRefined',true));
assert(numel(CSW2)==n0, 'a stale (pickPx-mismatched) deletion wrongly dropped a site');
fprintf('stale deletion ignored: sites = %d (expect %d)\n', numel(CSW2), n0);

% The Sites tab writes into this SAME list, so the two tabs' entries must concatenate and both
% apply. A Sites-tab entry with no pickPx deletes by file|csID|window alone (no position guard).
d2 = CSfoot0(3);
CSdeleted = struct('file',d.file,'csID',d.csID,'window',d.window,'pickPx',d.pickPx);      % Refine-shaped
CSdeleted(2) = struct('file',d2.file,'csID',d2.csID,'window',d2.window,'pickPx',[]); %#ok<STRNU> % Sites-shaped
save(fullfile(tmp,'CS_footprints.mat'),'CSfoot','CSdeleted');
CSW3 = cs_window_mapper(tmp, struct('save',false,'verbose',false,'useRefined',true));
fprintf('two mixed-shape deletions: sites = %d (expect %d)\n', numel(CSW3), n0-2);
assert(numel(CSW3)==n0-2, 'a Refine + Sites deletion pair did not drop both sites');
have = arrayfun(key,CSW3,'uni',0);
assert(~any(strcmp(have,key(d))) && ~any(strcmp(have,key(d2))), 'a merged deletion left its site behind');

fprintf('\nALL DELETE-SYNC ASSERTIONS PASSED.\n');
end
