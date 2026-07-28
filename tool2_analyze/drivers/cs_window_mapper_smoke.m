function cs_window_mapper_smoke()
% Headless validation of cs_window_mapper on real Project/analysis data + a synthetic
% 2-window check that proves the temporal (per-window) mask actually restricts membership.
here = fileparts(mfilename('fullpath'));
addpath(here);                                   % drivers/
addpath(fullfile(here,'..','ContactSites_robust'));
anaDir = '/Users/safal-mac/Desktop/IntegratedPipeline/Project/analysis';

fprintf('\n========== PART A: real data (whole-movie fallback) ==========\n');
CSW = cs_window_mapper(anaDir, struct('save',true,'verbose',true,'src','all'));
assert(~isempty(CSW), 'CSW empty');
assert(isfile(fullfile(anaDir,'CSW_final.mat')), 'CSW_final.mat not written');
assert(isfile(fullfile(anaDir,'cs_window_metrics.csv')), 'metrics csv not written');

% numel(CSW) must equal the txt rows for cells that EXIST in TrackStruct (orphan CSsites with no
% track data are correctly skipped — membership needs the tracked matrix).
St = load(fullfile(anaDir,'TrackStruct.mat')); fnT=fieldnames(St); Trk=St.(fnT{1});
tot = 0;
for i=1:numel(Trk)
    b = regexprep(char(Trk(i).file),'\.[^.]*$','');
    f = fullfile(anaDir,'csIDs',[b '_CSsites.txt']);
    if isfile(f)
        D = importdata(f);
        if isstruct(D)&&isfield(D,'data'), tot = tot + size(D.data,1); else, tot = tot + size(D,1); end
    end
end
fprintf('numel(CSW)=%d   txt rows (cells in TrackStruct)=%d\n', numel(CSW), tot);
assert(numel(CSW)==tot, 'CSW count != txt rows (%d vs %d)', numel(CSW), tot);

% footprint area cap: halfmax blobs <= pi*maxR^2 (+ tiny slack); box fallback area = (2*0.5)^2=1
maxR = 0.6; capHM = pi*maxR^2;
areas   = [CSW.areaUm2];
modes   = {CSW.footprintMode};
isHM    = strcmp(modes,'halfmax');
fprintf('footprint modes: halfmax=%d box=%d disk=%d\n', nnz(isHM), nnz(strcmp(modes,'box')), nnz(strcmp(modes,'disk')));
assert(all(areas(isHM) <= capHM*1.05 | isnan(areas(isHM))), 'halfmax area exceeds pi*maxR^2 cap');

% at least one mito site with members + enrichment>1
mito = [CSW.MitoFlag];
enr  = [CSW.enrichment];
nin  = [CSW.nMemberLocs];
fprintf('mito sites=%d   sites with member locs>0 = %d   median enrichment=%.2f\n', ...
    nnz(mito), nnz(nin>0), median(enr(isfinite(enr))));
assert(any(nin>0), 'no site has any member localizations');
assert(any(enr>1), 'no site has enrichment>1');
% report a representative mito site
im = find(mito & nin>0, 1);
if ~isempty(im)
    e = CSW(im);
    fprintf('example mito site: cell %d csID %d  area=%.4f um2  memberLocs=%d  tracks=%d  enrich=%.2f  peakProb=%.2e\n', ...
        e.cellIndex, e.csID, e.areaUm2, e.nMemberLocs, e.nTracks, e.enrichment, e.peakProb);
end

fprintf('\n========== PART B: synthetic 2-window temporal-mask check ==========\n');
% Build a tmp analysis dir with the SAME TrackStruct but a fake 2-window CSwindows + a fake
% CSsites that places ONE site (same px) in window 1 and the SAME px in window 2. Membership
% must differ between the windows (proves the temporal mask is live), and winFrames must match.
tmp = fullfile(tempdir,'cswm_smoke'); if isfolder(tmp), rmdir(tmp,'s'); end
mkdir(tmp); mkdir(fullfile(tmp,'csIDs')); mkdir(fullfile(tmp,'Densities'));
copyfile(fullfile(anaDir,'TrackStruct.mat'), fullfile(tmp,'TrackStruct.mat'));
Lr = dir(fullfile(anaDir,'Densities','*_rho.tif'));
for k=1:numel(Lr), copyfile(fullfile(Lr(k).folder,Lr(k).name), fullfile(tmp,'Densities',Lr(k).name)); end

S = load(fullfile(tmp,'TrackStruct.mat')); fn=fieldnames(S); Tr=S.(fn{1});
base = regexprep(char(Tr(1).file),'\.[^.]*$','');
% split the movie in half by frame
F = Tr(1).matrix(:,:,1); fmax = max(F(:),[],'omitnan'); fmin = min(F(:));
mid = floor((fmin+fmax)/2);
ranges = [fmin mid; mid+1 fmax];                        %#ok<NASGU>
grid = 921; SF = 27.61/grid;
windows = struct('ranges',ranges,'SF_umPerPx',SF,'grid',grid,'frameInterval',Tr(1).frameInterval); %#ok<NASGU>
save(fullfile(tmp,['Density_' base '_CSwindows.mat']),'windows');

% choose a pick at a busy location (centroid of that cell's tracked locs, in px)
X = Tr(1).matrix(:,:,2); Y = Tr(1).matrix(:,:,3); ok=isfinite(X)&isfinite(Y);
cx = median(X(ok))/SF; cy = median(Y(ok))/SF;
fid = fopen(fullfile(tmp,'csIDs',[base '_CSsites.txt']),'w');
fprintf(fid,' \tX\tY\tXM\tYM\tSlice\tCounter\tCount\n');
fprintf(fid,'1\t%.3f\t%.3f\t%.3f\t%.3f\t1\t1\t0\n', cx,cy,cx,cy);
fprintf(fid,'2\t%.3f\t%.3f\t%.3f\t%.3f\t2\t1\t0\n', cx,cy,cx,cy);
fclose(fid);
% only keep cell 1 to keep it simple: trim TrackStruct to cell 1
Tracks = Tr(1); save(fullfile(tmp,'TrackStruct.mat'),'Tracks'); %#ok<NASGU>

CSW2 = cs_window_mapper(tmp, struct('save',false,'verbose',true,'src','tracked'));
assert(numel(CSW2)==2,'expected 2 site-windows, got %d',numel(CSW2));
w1 = CSW2([CSW2.window]==1); w2 = CSW2([CSW2.window]==2);
fprintf('winFrames w1=%s  w2=%s\n', mat2str(w1.winFrames), mat2str(w2.winFrames));
assert(isequal(w1.winFrames,[fmin mid]) && isequal(w2.winFrames,[mid+1 fmax]), 'winFrames mismatch');
fprintf('memberLocs w1=%d  w2=%d   (union check)\n', w1.nMemberLocs, w2.nMemberLocs);
% temporal mask live: the two windows must select DIFFERENT member sets (same footprint px, disjoint frames)
assert(~isequal(sort(w1.LocIDs(:)), sort(w2.LocIDs(:))), 'per-window membership identical -> temporal mask NOT applied');
% and each window's member frames must lie inside its own range
if ~isempty(w1.LocIDs), fr1 = w1.CSmatrix(:,:,1); fr1=fr1(isfinite(fr1)); assert(all(fr1>=fmin & fr1<=mid),'w1 frames out of range'); end
if ~isempty(w2.LocIDs), fr2 = w2.CSmatrix(:,:,1); fr2=fr2(isfinite(fr2)); assert(all(fr2>=mid+1 & fr2<=fmax),'w2 frames out of range'); end

fprintf('\nALL SMOKE ASSERTIONS PASSED.\n');
end
