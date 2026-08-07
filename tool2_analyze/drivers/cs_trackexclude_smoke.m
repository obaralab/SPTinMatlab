function cs_trackexclude_smoke()
% Validate per-site track exclusion: a CS_trackedits.mat entry drops exactly that track column from
% the site's membership (pickPx-guarded), leaving other sites/tracks intact.
here = fileparts(mfilename('fullpath')); addpath(here); addpath(fullfile(here,'..','ContactSites_robust'));
src = '/Users/safal-mac/Documents/IntegratedPipeline/Project/analysis';
tmp = fullfile(tempdir,'cs_te_smoke'); if isfolder(tmp), rmdir(tmp,'s'); end
mkdir(tmp); mkdir(fullfile(tmp,'csIDs')); mkdir(fullfile(tmp,'Densities'));
copyfile(fullfile(src,'TrackStruct.mat'), fullfile(tmp,'TrackStruct.mat'));
for L = dir(fullfile(src,'csIDs','*_CSsites.txt'))', copyfile(fullfile(L.folder,L.name), fullfile(tmp,'csIDs',L.name)); end
for L = dir(fullfile(src,'Densities','*_rho.tif'))', copyfile(fullfile(L.folder,L.name), fullfile(tmp,'Densities',L.name)); end

CSW0 = cs_window_mapper(tmp, struct('save',false,'verbose',false,'useRefined',false));
% pick a site with >=2 member tracks
k = find(arrayfun(@(e) e.nTracks>=2, CSW0), 1); assert(~isempty(k),'no multi-track site');
e = CSW0(k); dropCol = e.tracks(1);
fprintf('site cell %d csID %d win %d: %d tracks; excluding track col %d\n', e.cellIndex, e.csID, e.window, e.nTracks, dropCol);

CSexclude = struct('file',e.file,'csID',e.csID,'window',e.window,'pickPx',e.pickPx,'trackCol',dropCol); %#ok<NASGU>
save(fullfile(tmp,'CS_trackedits.mat'),'CSexclude');

CSW1 = cs_window_mapper(tmp, struct('save',false,'verbose',false,'useRefined',true));
key = @(x) sprintf('%s|%d|%d', x.file, x.csID, x.window);
e1 = CSW1(strcmp(arrayfun(key,CSW1,'uni',0), key(e)));
assert(~isempty(e1),'site vanished'); e1 = e1(1);
fprintf('after exclusion: %d tracks (expect %d); track %d present? %d\n', e1.nTracks, e.nTracks-1, dropCol, any(e1.tracks==dropCol));
assert(e1.nTracks == e.nTracks-1, 'exclusion did not drop exactly one track');
assert(~any(e1.tracks==dropCol), 'excluded track still present');
assert(e1.nMemberLocs < e.nMemberLocs, 'member locs did not decrease');
% other sites unchanged
o = find(arrayfun(@(x) ~strcmp(key(x),key(e)), CSW1),1);
oo = CSW0(strcmp(arrayfun(key,CSW0,'uni',0), key(CSW1(o))));
assert(CSW1(o).nTracks == oo(1).nTracks, 'a non-target site changed');
% stale exclusion (pickPx moved) ignored
CSexclude.pickPx = e.pickPx + [50 50]; %#ok<STRNU>
save(fullfile(tmp,'CS_trackedits.mat'),'CSexclude');
CSW2 = cs_window_mapper(tmp, struct('save',false,'verbose',false,'useRefined',true));
e2 = CSW2(strcmp(arrayfun(key,CSW2,'uni',0), key(e))); e2=e2(1);
assert(e2.nTracks == e.nTracks, 'stale (pickPx-mismatched) exclusion wrongly applied');
fprintf('stale exclusion ignored: %d tracks\n', e2.nTracks);

fprintf('\nALL TRACK-EXCLUSION ASSERTIONS PASSED.\n');
end
