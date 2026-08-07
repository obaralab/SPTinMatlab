function cs_channel_accessor_smoke()
% Headless validation of the reference-channel accessor layer (cs_channel_fields / _keys / _dist /
% _has / cs_site_near / cs_channel_mask).
%
% The accessors exist to remove ~200 hard-coded spellings of "ER" and "mito" from the pipeline
% WITHOUT changing what any of them computed. So the core of this test is not "does the accessor
% work" — it is EQUIVALENCE: each block below re-states the original inline expression verbatim, as
% it stood before the conversion, and asserts the accessor returns exactly that (isequaln, because
% every one of these arrays is NaN-padded and isequal(NaN,NaN) is false).
%
% Everything is synthetic. No dataset is read, so this runs anywhere and cannot touch live data.
here = fileparts(mfilename('fullpath'));
addpath(here);

fprintf('\n========== PART A: the name map ==========\n');
keys = cs_channel_keys();
assert(iscellstr(keys) && numel(keys)==2, 'expected two channels'); %#ok<ISCLSTR>
assert(isequal(cs_channel_keys('support'),   {'er'}),   'ER must be the support channel');
assert(isequal(cs_channel_keys('proximity'), {'mito'}), 'mito must be the proximity channel');
for i = 1:numel(keys)
    F = cs_channel_fields(keys{i});
    assert(strcmp(F.key, keys{i}), 'key not canonical');
    fprintf('  %-5s role=%-9s mat=%-8s spots=%-8s site=%-8s seg=%-7s folder=%s\n', ...
        F.key, F.role, F.mat, F.spots, ternStr(F.site), F.seg, F.folder);
end
assert(isequal(cs_channel_fields('MITO'), cs_channel_fields('mito')), 'key must be case-insensitive');
assert(isempty(cs_channel_fields('er').site), 'a support channel has no per-site flag');
threw = false; try, cs_channel_fields('lyso'); catch, threw = true; end
assert(threw, 'an unknown channel key must error, not read as "absent"');

fprintf('\n========== PART B: per-spot distances, cloud + tracked ==========\n');
nF = 4; nT = 3;
F0 = repmat((0:nF-1)', 1, nT);
X0 = reshape(linspace(0.1, 2.4, nF*nT), nF, nT);
Y0 = X0 + 0.5;
X0(2,3) = NaN; Y0(2,3) = NaN;                       % a hole, as a real matrix has
T = struct('file','cellA.tif', ...
    'matrix', cat(3, F0, X0, Y0), ...
    'allSpots', struct('FRAME',(0:19)','X',(1:20)'/10,'Y',(1:20)'/5, ...
                       'MITODIST',(1:20)'/100,'ERDIST',-(1:20)'/50), ...
    'mitoDist', reshape((1:nF*nT)'/7, nF, nT), ...
    'erDist',   reshape(-(1:nF*nT)'/9, nF, nT));

% -- cloud, both channels present. Original (spt_analyze_app densCoords / cs_window_picker cellLocs):
%      md = nan(size(x)); if isfield(T.allSpots,'MITODIST') && numel(...)==numel(x), md = double(...(:)); end
x = T.allSpots.X(:);
mdOrig = nan(size(x));
if isfield(T.allSpots,'MITODIST') && numel(T.allSpots.MITODIST)==numel(x), mdOrig = double(T.allSpots.MITODIST(:)); end
edOrig = nan(size(x));
if isfield(T.allSpots,'ERDIST') && numel(T.allSpots.ERDIST)==numel(x), edOrig = double(T.allSpots.ERDIST(:)); end
[md, haveMd, nMd] = cs_channel_dist(T,'mito','cloud');
[ed, haveEd]      = cs_channel_dist(T,'er','cloud');
assert(isequaln(md, mdOrig) && isequaln(ed, edOrig), 'cloud distances differ from the original expression');
assert(haveMd && haveEd && nMd==numel(x), 'cloud have/count wrong');
fprintf('  cloud   : n=%d  mito have=%d  er have=%d  (equivalence OK)\n', nMd, haveMd, haveEd);

% -- tracked, both channels present. Original (densCoords / cellLocs):
%      if isfield(T,'mitoDist') && isequal(size(T.mitoDist), size(M(:,:,1))), md = reshape(T.mitoDist,[],1); end
M = T.matrix;
mdOrigT = nan(numel(M(:,:,1)),1);
if isfield(T,'mitoDist') && isequal(size(T.mitoDist), size(M(:,:,1))), mdOrigT = reshape(T.mitoDist,[],1); end
[mdT, haveMdT, nT2] = cs_channel_dist(T,'mito','tracked');
assert(isequaln(mdT, mdOrigT), 'tracked distances differ from the original reshape');
assert(haveMdT && nT2==nF*nT, 'tracked have/count wrong');

% -- the cs_identify form: MD0(ok0) with a logical mask over the matrix, NOT a reshape. Column-major
%    order makes these identical; that is the whole reason the accessor may return a flat column.
ok0 = isfinite(M(:,:,2)) & isfinite(M(:,:,3));
assert(isequaln(T.mitoDist(ok0), mdT(ok0(:))), 'MD0(ok0) != d(ok0(:)) — column-major assumption broken');
fprintf('  tracked : n=%d  reshape-equivalent=1  mask-equivalent=1\n', nT2);

% -- SIGN. The convention is + outside the organelle, - INSIDE, ~0 on the boundary. Every fixture in
%    the repo writes non-negative distances (0.3*rand, 0.05*rand, the constants 0.1/0.05), so the
%    inside branch is produced by no other test: an abs(), a negation or a clamp-at-zero anywhere in
%    the accessor would pass the whole suite while inverting every contact classification downstream
%    (a site is mito when its median signed distance is BELOW the threshold). Pinned here explicitly.
Tsign = T;
signed = [-0.75; -0.0; 0.0; 0.31; NaN; -1e-9; 2.5];
Tsign.allSpots = struct('FRAME',(0:6)','X',(1:7)','Y',(1:7)','MITODIST',signed);
dSign = cs_channel_dist(Tsign,'mito','cloud');
assert(isequaln(dSign, signed), 'cloud distances must pass through unmodified, sign included');
assert(any(dSign < 0) && any(dSign > 0), 'premise: the fixture must span both signs');
Tsign2 = T; Tsign2.mitoDist = reshape([-1 -0.5 0 0.5 1 1.5 -2 -2.5 3 3.5 -4 4.5], nF, nT);
assert(isequaln(cs_channel_dist(Tsign2,'mito','tracked'), reshape(Tsign2.mitoDist,[],1)), ...
    'tracked distances must pass through unmodified, sign included');
fprintf('  sign    : negatives, zero and NaN pass through untouched (inside/outside preserved)\n');

% -- allSpots stored as [] rather than a struct — what TrackImporter_direct leaves behind when the
%    spots CSV is not attached. Must fall back, never dereference.
Tnil = T; Tnil.allSpots = [];
[dn, hn, nn_] = cs_channel_dist(Tnil,'mito','cloud');
assert(~hn && nn_==0 && isempty(dn), 'allSpots = [] must read as an empty cloud, not throw');
assert(~cs_channel_has(Tnil,'mito','cloud') && cs_channel_has(Tnil,'mito','any'), ...
    'cloud absent, tracked present');

% -- absent channel: all-NaN of the RIGHT LENGTH, never []. Callers concatenate this straight onto a
%    coordinate vector, so a short/empty return would silently misalign every downstream distance.
Tno = rmfield(T,'mitoDist'); Tno.allSpots = rmfield(Tno.allSpots,'MITODIST');
[dc, hc, nc] = cs_channel_dist(Tno,'mito','cloud');
[dt, ht, nt] = cs_channel_dist(Tno,'mito','tracked');
assert(~hc && all(isnan(dc)) && nc==numel(x),   'absent cloud channel must be NaN x numel(X)');
assert(~ht && all(isnan(dt)) && nt==nF*nT,      'absent tracked channel must be NaN x numel(matrix page)');
assert(iscolumn(dc) && iscolumn(dt) && isa(dc,'double'), 'must be a double column');
fprintf('  absent  : cloud n=%d tracked n=%d, all-NaN columns (no misalignment)\n', nc, nt);

% -- MISMATCHED size reads as absent rather than throwing. cs_identify guarded only on ~isempty and
%    would have indexed a wrong-sized array; this is the one deliberate hardening in the layer.
Tbad = T; Tbad.mitoDist = [1 2 3];
[db, hb] = cs_channel_dist(Tbad,'mito','tracked');
assert(~hb && numel(db)==nF*nT && all(isnan(db)), 'size-mismatched channel must read as absent');
Tbad2 = T; Tbad2.allSpots.MITODIST = (1:3)';
[db2, hb2] = cs_channel_dist(Tbad2,'mito','cloud');
assert(~hb2 && numel(db2)==numel(x), 'size-mismatched cloud channel must read as absent');
fprintf('  mismatch: reads as absent, does not throw\n');

% -- degenerate structs must not throw
Tempty = struct('matrix',[],'allSpots',struct());
[de, he, ne] = cs_channel_dist(Tempty,'mito','cloud');
[df, hf, nf] = cs_channel_dist(Tempty,'mito','tracked');
assert(ne==0 && nf==0 && ~he && ~hf && isempty(de) && isempty(df), 'empty struct must give an empty column');
threw = false; try, cs_channel_dist(T,'mito','sideways'); catch, threw = true; end
assert(threw, 'an unknown src must error');

fprintf('\n========== PART C: availability + site flag ==========\n');
% Original (spt_analyze_app QC): hm = isfield(Tracks,'mitoDist') && ~isempty(Tracks(k).mitoDist);
assert(cs_channel_has(T,'mito') == (isfield(T,'mitoDist') && ~isempty(T.mitoDist)), 'has() differs');
assert(cs_channel_has(T,'er')   == (isfield(T,'erDist')   && ~isempty(T.erDist)),   'has() differs');
Tblank = T; Tblank.mitoDist = [];
assert(~cs_channel_has(Tblank,'mito'), 'an empty array is not "present"');
assert(cs_channel_has(Tblank,'mito','cloud'), 'the cloud column is still there');
assert(cs_channel_has(Tblank,'mito','any'),   '''any'' must find the cloud column');
[~, raw] = cs_channel_has(T,'mito');
assert(isequaln(raw, T.mitoDist), 'raw passthrough must be the stored array');

% Original: logical(CS(k).MitoFlag), with three different levels of guarding across the codebase.
assert(cs_site_near(struct('MitoFlag',1),'mito'),      'double 1 is near');
assert(cs_site_near(struct('MitoFlag',true),'mito'),   'logical true is near');
assert(~cs_site_near(struct('MitoFlag',0),'mito'),     'double 0 is not near');
assert(~cs_site_near(struct('MitoFlag',false),'mito'), 'logical false is not near');
assert(~cs_site_near(struct(),'mito'),                 'missing flag is not near');
assert(~cs_site_near(struct('MitoFlag',[]),'mito'),    'empty flag is not near');
assert(~cs_site_near(struct('MitoFlag',NaN),'mito'),   'NaN must read false, not throw');
assert(~cs_site_near(struct('MitoFlag',1),'er'),       'a support channel has no site flag');
% Non-scalar: match the `if c` (all-non-zero) semantics of the bare tern(logical(...)) call sites,
% not the scalar-only `&&` of the two guarded ones. No producer makes one; pinned so it stays defined.
assert(cs_site_near(struct('MitoFlag',[1 1]),'mito'),   'all-non-zero is near');
assert(~cs_site_near(struct('MitoFlag',[1 0]),'mito'),  'any zero is not near');
assert(~cs_site_near(struct('MitoFlag',[1 NaN]),'mito'),'a NaN anywhere reads false, not an error');
assert(~cs_site_near(struct('MitoFlag','x'),'mito'),    'a non-numeric flag reads false');
% 1/2 encoding is NOT this accessor''s job — CSsites.txt column 7 uses 1=mito / 2=non-mito, and
% logical(2) is true. That decode lives once, in cs_read_sites; never route it through here.
assert(cs_site_near(struct('MitoFlag',2),'mito'), 'premise: a raw 2 reads TRUE — do not feed col 7 here');
% THREE spellings of one boolean: 'MitoFlag' on CS/CSW records, 'mito' on footprint records
% (cs_footprints_build) and on dwell events / per-site rows (cs_window_dwell). Reads accept any.
assert(cs_site_near(struct('mito',true),'mito'),      'the footprint/dwell spelling must read');
assert(~cs_site_near(struct('mito',false),'mito'),    'the footprint/dwell spelling must read false');
assert(isequal(cs_channel_fields('mito').siteAny, {'MitoFlag','mito'}), 'read spellings, canonical first');
assert(isempty(cs_channel_fields('er').siteAny),      'a support channel has no site spellings');
% Canonical wins if a record somehow carried both (no producer does).
assert(cs_site_near(struct('MitoFlag',1,'mito',false),'mito'), 'MitoFlag takes priority over mito');
assert(islogical(cs_site_near(struct('MitoFlag',1),'mito')) && isscalar(cs_site_near(struct('MitoFlag',1),'mito')), ...
    'must be a scalar logical');
CS = struct('MitoFlag',{1,0,1,1});
got = cs_sites_near(CS,'mito');
assert(isequal(got, logical([1 0 1 1])) && isequal(got, logical([CS.MitoFlag])), ...
    'bulk read must match the logical([CS.MitoFlag]) idiom');
assert(isrow(got) && islogical(got) && numel(got)==numel(CS), 'bulk read must be a logical row');
% The reason the bulk helper exists: [CS.MitoFlag] SHORTENS on an empty flag, so nnz() and any index
% built from it silently misalign. The accessor keeps one entry per site.
CSgap = struct('MitoFlag',{1,[],1,1});
assert(numel([CSgap.MitoFlag])==3, 'premise: concatenation drops the empty');
assert(isequal(cs_sites_near(CSgap,'mito'), logical([1 0 1 1])), 'bulk read must not shorten');
assert(isequal(cs_sites_near(struct('MitoFlag',{}),'mito'), false(1,0)), 'empty array gives an empty row');
fprintf('  site flag: double / logical / missing / empty / NaN all give a scalar logical\n');
fprintf('  bulk     : keeps length where [CS.MitoFlag] would shorten (4 sites -> %d vs %d)\n', ...
    numel(cs_sites_near(CSgap,'mito')), numel([CSgap.MitoFlag]));

fprintf('\n========== PART C2: the flag is a BOOLEAN on write ==========\n');
% One writer, one stored class. Before this, cs_refine wrote double(0/1) and the pipeline app wrote
% a logical into the same field, so a single CS_final.mat could hold both depending on which tool
% last touched each site. Reads stay permissive (Part C) so old .mat files still load; writes do not.
for v = {true, false, 1, 0, int8(1), single(0)}
    out = cs_site_set_near(struct('csID',7), 'mito', v{1});
    assert(islogical(out.MitoFlag) && isscalar(out.MitoFlag), ...
        'every write must store a 1x1 logical, got %s', class(out.MitoFlag));
    assert(out.MitoFlag == logical(double(v{1})), 'value must round-trip');
end
assert(isfield(cs_site_set_near(struct(),'mito',true),'MitoFlag'), 'a bare record gets the canonical name');
% Spelling follows the record, so field order at the call site is untouched.
r = cs_site_set_near(struct('csID',1,'mito',false,'area',2), 'mito', true);
assert(r.mito && ~isfield(r,'MitoFlag'), 'an existing ''mito'' spelling must be written in place');
assert(isequal(fieldnames(r), {'csID';'mito';'area'}), 'field order must be preserved');
% Round-trip through the reader, including from the legacy classes the reader still accepts.
for v = {1, 0, true, false}
    assert(cs_site_near(cs_site_set_near(struct(),'mito',v{1}),'mito') == logical(double(v{1})), 'round-trip');
end
% A writer must not quietly absorb what a reader tolerates — that hides the bug that made it.
for bad = {NaN, [], [1 1], 'x'}
    threw = false; try, cs_site_set_near(struct(),'mito',bad{1}); catch, threw = true; end
    assert(threw, 'the writer must reject a non-scalar / non-finite value');
end
threw = false; try, cs_site_set_near(struct(),'er',true); catch, threw = true; end
assert(threw, 'a support channel has no per-site flag to write');
fprintf('  writer   : logical/double/int/single all stored as a 1x1 logical; NaN, [], vectors rejected\n');

fprintf('\n========== PART D: segmentation mask reader ==========\n');
sp = fullfile(tempdir, sprintf('cs_channel_mask_smoke_%d.tif', feature('getpid')));
cleanup = onCleanup(@() delete_if(sp));
if isfile(sp), delete(sp); end
page1 = uint8(2*ones(8,8)); page1(2:5,2:5) = 1;      % ilastik style: label 1 = organelle, 2 = background
page2 = uint8(2*ones(8,8));                          % a frame with NONE of the organelle in it
imwrite(page1, sp); imwrite(page2, sp, 'WriteMode','append');

% Equivalence with cs_window_picker's segMaskAt: page = min(max(round(frame0)+1,1),nfr); fg = min
% nonzero label ON THAT PAGE; imresize(...,'nearest') > 0.5.
grid = 16;
for f0 = [0 1 99 -5]
    page = min(max(round(f0)+1,1), 2);
    a = imread(sp, page); v = unique(a(:)); nz = v(v>0); fgO = 1; if ~isempty(nz), fgO = double(min(nz)); end
    mOrig = imresize(double(a==fgO), [grid grid], 'nearest') > 0.5;
    [m, fg] = cs_channel_mask(sp, 2, f0, grid);
    assert(isequal(m, mOrig) && isequal(fg, fgO), 'mask differs from segMaskAt at frame0=%g', f0);
end
m1 = cs_channel_mask(sp, 2, 0, grid);
assert(islogical(m1) && isequal(size(m1),[grid grid]), 'mask must be logical at the requested grid');
assert(abs(mean(m1(:)) - 0.25) < 1e-9, 'a 4x4 blob in 8x8 must resize to a quarter of the grid');
assert(isequal(cs_channel_mask(sp,2,99,grid), cs_channel_mask(sp,2,1,grid)), 'frame past the end must clamp to the last page');
mNative = cs_channel_mask(sp, 2, 0, []);
assert(isequal(size(mNative),[8 8]), 'empty gridSize must keep the native size');

% PINNED QUIRK — not a wish, a record. The per-page label rule reads fg=2 on a frame containing none
% of the organelle, so that frame comes back INVERTED (all true). Downstream, werMask's
% "if isempty(m) || ~any(m(:))" fallback does not catch an all-true mask, so such a window is
% detected unconfined and its background median is taken over the whole field. Documented in
% cs_channel_mask; 'FgLabel' is the escape hatch. If this assert ever fails, the default rule was
% changed on purpose — update the callers' expectations with it.
[mInv, fgInv] = cs_channel_mask(sp, 2, 1, grid);
assert(fgInv==2 && all(mInv(:)), 'the per-page label quirk is no longer reproduced — see the comment above');
mFixed = cs_channel_mask(sp, 2, 1, grid, 'FgLabel', 1);
assert(~any(mFixed(:)), 'FgLabel must override the per-page rule');
fprintf('  reader   : segMaskAt-equivalent at 4 frame indices; clamp, native size, FgLabel override OK\n');
fprintf('  quirk    : empty page reads fg=%g -> mask all-true (pinned, see cs_channel_mask header)\n', fgInv);

% unavailable channel -> [], never an error and never an all-true mask by accident
assert(isempty(cs_channel_mask('',  2, 0, grid)), 'no path must give []');
assert(isempty(cs_channel_mask(sp,  0, 0, grid)), 'nFrames<1 must give []');
assert(isempty(cs_channel_mask(sp, [], 0, grid)), 'empty nFrames must give []');
assert(isempty(cs_channel_mask(fullfile(tempdir,'no_such_file_xyz.tif'), 2, 0, grid)), 'unreadable must give []');
fprintf('  absent   : missing path / no frames / unreadable all give [] (caller decides the fallback)\n');

fprintf('\ncs_channel_accessor_smoke: PASS\n');
end

% ------------------------------------------------------------------------------------------------
function s = ternStr(v)
s = v; if isempty(s), s = '—'; end
end

function delete_if(p)
if isfile(p), try, delete(p); catch, end, end
end
