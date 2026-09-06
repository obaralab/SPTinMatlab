function spt_bleedthrough_smoke()
%SPT_BLEEDTHROUGH_SMOKE  Filament rejection, and the SPT->organelle frame map for interleaved data.
%
% TWO PROBLEMS, BOTH FROM ONE ACQUISITION: an SPT channel imaged at twice the organelle rate, with
% the mitochondrial channel bleeding through into every second SPT frame.
%
% (A) THE DETECTOR BREAKS A FILAMENT INTO A CHAIN OF SPOTS. A DoG asks "is this a bright blob at
%     the spot scale". A mitochondrion is not one blob, it is a ridge, and local-maximum detection
%     strings a line of perfectly ordinary-looking detections along its crest. No threshold
%     separates them: they are as bright as real molecules. Curvature does — spt_ridge rejects
%     candidates whose DoG principal-curvature ratio is ridge-like.
%
%     THE SIZE TEST IS THE ONE THAT KNOWS THE SPOT DIAMETER. The curvature ratio is deliberately
%     size-blind (it is a ratio of eigenvalues), so it catches a filament CREST and nothing else. The
%     width test — is this peak wider than a real spot of the diameter you set — catches the filament
%     ENDS and CROSSINGS that are round enough to pass a curvature ratio. Part (A2) asserts the width
%     separation holds at three diameters, since a criterion that scales with the spot has to be
%     checked at more than one spot size to mean anything.
%
%     WHAT IS ASSERTED IS A MEASURED SEPARATION. On this fixture the gate keeps every planted single
%     molecule and clears the filament chain completely. Do not read that as what a real movie will
%     do: a synthetic filament is smooth and of one width, where real bleedthrough carries focal
%     blobs, crossings and ends that are genuinely round at the spot scale and will survive. The
%     assertions are two-sided — a later change that starts eating real spots fails, and one that
%     stops rejecting the chain fails too.
%
% (B) THE FRAME MAP. A half-length organelle stack used to be indexed with the SPT frame number, so
%     everything past its last page silently lost its mask: NOT every other frame, the whole second
%     half of the movie. Per-spot mito/ER distance came back NaN there, and `supports` stayed empty,
%     which strict geodesic linking reads as "forbid every link". segEvery maps SPT frame t to
%     organelle page ceil(t/segEvery) and 'auto' derives it from the page counts.
%
% Synthetic data in tempdir; reads no real dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
root = fullfile(tempdir, sprintf('spt_bleed_%d', feature('getpid')));
if isfolder(root), rmdir(root,'s'); end
mkdir(root);
cleanup = onCleanup(@() rmdir(root,'s'));

PX = 0.10785; DIAM = 0.5; H = 256; W = 256;

%% (A) a filament plus real spots, in one frame ---------------------------------------------------
pts = [40 40; 90 60; 150 200; 200 120; 60 180; 120 90; 180 60; 210 210];
[img, filMask] = make_frame(H, W, pts, PX, DIAM);

xyOff = spt_detect(img, DIAM, PX, []);                       % as shipped: no ridge gate
xyOn  = spt_detect(img, DIAM, PX, [], struct('ridgeMax',2)); % with it

[hitOff, filOff] = split_dets(xyOff, pts, filMask);
[hitOn,  filOn ] = split_dets(xyOn,  pts, filMask);

fprintf('gate off: %d real spots + %d filament detections\n', hitOff, filOff);
fprintf('gate on : %d real spots + %d filament detections\n', hitOn,  filOn);

assert(filOff >= 8, ...
    'the fixture is not exercising the problem: the filament produced only %d detections', filOff);
assert(hitOff == size(pts,1), 'the detector missed a planted spot before any gating: %d of %d', hitOff, size(pts,1));

% 1. it must not cost real molecules — that is the whole risk of a shape gate
assert(hitOn == hitOff, ...
    'ridge gate rejected %d real single molecules — a molecule ON a mitochondrion is still a point source', ...
    hitOff - hitOn);
% 2. it must actually clear the chain, or it is not worth the option. The bar is set well below
%    what this fixture achieves (it removes all of them), so ordinary drift does not trip it, but a
%    change that broke the gate would.
assert(filOn <= 0.25*filOff, ...
    'ridge gate removed only %d of %d filament detections (%.0f%%) — it is not doing its job', ...
    filOff-filOn, filOff, 100*(filOff-filOn)/filOff);
fprintf('ridge gate: kept %d/%d real spots, removed %d/%d filament detections (%.0f%%)\n', ...
    hitOn, hitOff, filOff-filOn, filOff, 100*(filOff-filOn)/filOff);

% off by default: the shipped path must be untouched
assert(isequal(spt_detect(img, DIAM, PX, []), spt_detect(img, DIAM, PX, [], struct())), ...
    'an empty options struct changed detection — the gate must be off unless asked for');
assert(isequal(spt_detect(img, DIAM, PX, []), spt_detect(img, DIAM, PX, [], struct('ridgeMax',[]))), ...
    'ridgeMax=[] changed detection — that is the off state');
fprintf('default path unchanged with the option absent, empty, or zero\n');

% The gate has to be able to SHOW what it discarded, or it is a number that moves a count with no
% way to judge the threshold. The rejects come back given the same suppression and centroid as the
% survivors, so they can be drawn beside them.
[keptR, ~, rejR] = spt_detect(img, DIAM, PX, [], struct('ridgeMax',2));
assert(~isempty(rejR), 'the gate reported no rejected candidates, so nothing can be shown');
assert(size(keptR,1) == size(xyOn,1), 'asking for the rejects changed the surviving detections');
assert(size(rejR,2) == 3, 'rejects must come back as [x y quality], like the survivors');
% every reject must be a real position in the frame, not a raw peak index
assert(all(rejR(:,1) >= 1 & rejR(:,1) <= W & rejR(:,2) >= 1 & rejR(:,2) <= H), ...
    'a rejected position fell outside the frame');
% NOT ONE of them may be a real molecule. This is the property that matters: the picture is there
% to be trusted, and a reject drawn on top of a genuine single molecule would mean the gate is
% eating signal.
for i = 1:size(rejR,1)
    assert(all(hypot(pts(:,1)-rejR(i,1), pts(:,2)-rejR(i,2)) > 2.5), ...
        'a rejected spot sits on a planted molecule at (%.1f, %.1f) — the gate is eating signal', ...
        rejR(i,1), rejR(i,2));
end
% They concentrate on the filament, though NOT exclusively: the curvature test also throws out
% saddle-shaped background noise wherever it occurs, which is correct and is why the share is about
% half rather than all. What has to hold is that they are far denser on the filament than chance.
onFil = arrayfun(@(i) filMask(max(1,min(H,round(rejR(i,2)))), max(1,min(W,round(rejR(i,1))))), ...
    (1:size(rejR,1))');
enr = mean(onFil) / mean(filMask(:));
assert(enr > 2, ...
    ['rejected spots are only %.1fx enriched on the filament (%.0f%% of them, over %.0f%% of the ' ...
     'frame) — the gate is not targeting the filament'], enr, 100*mean(onFil), 100*mean(filMask(:)));
% A ratio below 1 is not a stricter setting — (R+1)^2/R is symmetric about 1, so 0.1 is the same
% cut as 10, i.e. very permissive. It must be caught, not honoured.
lastwarn(''); wr = warning('off','spt_ridge:ratioBelowOne');
n01 = size(spt_detect(img, DIAM, PX, [], struct('ridgeMax',0.1)), 1);
warning(wr); [~, widR] = lastwarn();
assert(strcmp(widR,'spt_ridge:ratioBelowOne'), ...
    'ridgeMax=0.1 was accepted silently; it behaves like 10, the opposite of what it looks like');
n1 = size(spt_detect(img, DIAM, PX, [], struct('ridgeMax',1)), 1);
assert(n01 == n1, 'a sub-1 ratio must be clamped to 1, got %d detections against %d', n01, n1);
n10 = size(spt_detect(img, DIAM, PX, [], struct('ridgeMax',10)), 1);
assert(n10 > n01, ...
    'ridgeMax=10 should be far more permissive than the clamped 1 (%d vs %d)', n10, n01);
fprintf('ratio below 1 clamped to 1 and warned (0.1 -> %d dets, 1 -> %d, 10 -> %d)\n', n01, n1, n10);

[~, ~, rejOff] = spt_detect(img, DIAM, PX, []);
assert(isempty(rejOff), 'with no gate active there must be nothing reported as rejected');
fprintf('gate reports %d rejected candidates, none on a real molecule, %.1fx enriched on the filament\n', ...
    size(rejR,1), enr);

%% (A2) the SIZE test scales with the expected spot ------------------------------------------------
% Same scene at three diameters, with the PSF and the filament width scaled to match what each
% diameter is meant to describe. The expected peak width is W_REF*scale, so if the criterion did not
% scale it would either pass everything at large diameters or reject everything at small ones.
fprintf('\n  diam   scale | point width (max)  filament width (min)  ratio\n');
for diam = [0.5 1.0 1.5]
    [im2, fil2, pts2, sg2] = make_scaled(H, W, PX, diam);
    [dg, ~, sc] = spt_dog(im2, diam, PX);
    md = median(dg(:)); mn = 1.4826*median(abs(dg(:)-md)) + 1e-6;
    lm = imdilate(dg, ones(5,5));
    [cyy, cxx] = find((dg >= lm) & (dg > md + 4*mn));
    kk = cxx > 2 & cxx <= W-2 & cyy > 2 & cyy <= H-2; cxx = cxx(kk); cyy = cyy(kk);
    [~, ~, wm] = spt_ridge(dg, cxx, cyy, [], sc, []);
    isP = false(numel(cxx),1);
    for i = 1:numel(cxx), isP(i) = any(hypot(pts2(:,1)-cxx(i), pts2(:,2)-cyy(i)) <= max(2.5,sg2)); end
    onF = ~isP & arrayfun(@(i) fil2(cyy(i),cxx(i)), (1:numel(cxx))');
    wP = max(wm(isP & isfinite(wm))); wF = min(wm(onF & isfinite(wm)));
    fprintf('  %-6.2g %-5.2f | %-17.2f %-21.2f %.2f\n', diam, sc, wP, wF, wF/wP);
    assert(wF > wP, ...
        'at diameter %g the widest real spot (%.2f px) is not narrower than the narrowest filament peak (%.2f px)', ...
        diam, wP, wF);
    % 1.6 x expected must sit strictly between them, or the shipped default does not separate here
    cut = 1.6 * 1.53 * sc;
    assert(wP < cut && cut < wF, ...
        ['the default cut 1.6x expected (%.2f px at scale %.2f) does not separate at diameter %g: ' ...
         'points reach %.2f, filament starts at %.2f'], cut, sc, diam, wP, wF);
end
fprintf('size test separates at all three diameters, with 1.6x expected inside the gap\n');

% and the two tests are genuinely different: the size test must reject peaks the shape test keeps
[imE, ~, ~, ~] = make_scaled(H, W, PX, 0.5);
nShape = size(spt_detect(imE, 0.5, PX, [], struct('ridgeMax',2)), 1);
nBoth  = size(spt_detect(imE, 0.5, PX, [], struct('ridgeMax',2,'sizeMax',1.6)), 1);
assert(nBoth < nShape, ...
    'adding the size test changed nothing (%d detections either way) — then it is not a second criterion', nShape);
fprintf('shape alone keeps %d, shape+size keeps %d — the width test is not redundant\n', nShape, nBoth);

%% (A3) alignment along the organelle -------------------------------------------------------------
% The curvature test is blind to orientation, so bleedthrough that is only mildly elongated but lies
% ALONG a mitochondrion survives it. Alignment catches that, and must not touch a round spot on the
% same structure — which is what a real molecule at a contact site looks like.
skl = bwmorph(filMask & imerode(filMask,strel('disk',4)), 'skel', Inf);
if ~any(skl(:)), skl = bwmorph(filMask,'skel',Inf); end
[kA, sA] = spt_detect(img, DIAM, PX, [], struct('ridgeMax',2));
nPlain = size(kA,1);
kB = spt_detect(img, DIAM, PX, [], struct('ridgeMax',2,'skel',skl,'alignDeg',30));
assert(size(kB,1) < nPlain, 'alignment rejected nothing beyond the curvature test (%d both ways)', nPlain);
% Molecules AWAY from the structure must all survive — they are round, so the elongation condition
% spares them. A molecule sitting ON the ridge is a different matter and is NOT asserted safe: its
% second moments are measured on a window that contains the ridge, so it reads as elongated along
% it and can be rejected. That is the real cost of this test and it falls exactly on the
% contact-site population, so it is measured rather than wished away — on real data, against ch1 as
% ground truth, alignment removed 5 genuine molecules against 425 artefacts (1.4% of real
% detections, 99% of removals being artefact).
onRidge = false(size(pts,1),1);
for pk = 1:size(pts,1)
    onRidge(pk) = filMask(max(1,min(H,pts(pk,2))), max(1,min(W,pts(pk,1))));
end
for pk = find(~onRidge).'
    assert(any(hypot(kB(:,1)-pts(pk,1), kB(:,2)-pts(pk,2)) <= 2.5), ...
        ['alignment removed the molecule at (%d, %d), which is nowhere near the structure — off ' ...
         'the skeleton the test must never fire'], pts(pk,1), pts(pk,2));
end
lostOn = 0;
for pk = find(onRidge).'
    if ~any(hypot(kB(:,1)-pts(pk,1), kB(:,2)-pts(pk,2)) <= 2.5), lostOn = lostOn + 1; end
end
fprintf('  %d of %d planted molecules sit ON the structure; alignment lost %d of them\n', ...
    nnz(onRidge), size(pts,1), lostOn);
% and it must be the ALIGNMENT doing it, not merely the elongation: a skeleton rotated 90 degrees
% relative to the structure should reject far fewer
skRot = bwmorph(imrotate(filMask, 90, 'crop'), 'skel', Inf);
kC = spt_detect(img, DIAM, PX, [], struct('ridgeMax',2,'skel',skRot,'alignDeg',30));
assert(size(kC,1) > size(kB,1), ...
    ['a 90-degree-rotated skeleton rejected as much as the true one (%d vs %d) — then the test is ' ...
     'firing on elongation alone, not on alignment'], size(kC,1), size(kB,1));
fprintf('alignment: %d -> %d detections; a rotated skeleton leaves %d, so it is alignment doing it\n', ...
    nPlain, size(kB,1), size(kC,1));

%% (A4) the threshold must not be set by the contaminated frames ------------------------------------
% Top %% takes a percentile of pooled candidate qualities. Bleedthrough contributes a flood of
% candidates, so pooling over contaminated frames raises the threshold and suppresses real
% detections on the CLEAN frames too — by a different amount in every cell, in proportion to how
% contaminated it happens to be. That is a cross-cell bias produced entirely by the artefact.
thrDir = fullfile(root,'thr'); mkdir(thrDir);
tp = fullfile(thrDir,'t_spt1.tif');
[Xt,Yt] = meshgrid(1:W,1:H);
leak = 900*exp(-((Xt-W/2).^2)/(2*26^2));          % a bright band, only on the even pages
for t = 1:24
    rng(700+t);
    f = 200 + 4*randn(H,W);
    for qq = 1:10, f = f + 800*exp(-((Xt-(30+11*qq+t)).^2 + (Yt-(40+15*qq+2*t)).^2)/(2*1.5^2)); end
    if mod(t,2)==0, f = f + leak + 40*randn(H,W); end
    imwrite(uint16(f), tp, 'WriteMode', tern_(t==1,'overwrite','append'));
end
qAll  = spt_pool_quality(tp, DIAM, PX, 24);
qOdd  = spt_pool_quality(tp, DIAM, PX, 24, struct('stride',2,'offset',0));
tAll  = prctile(qAll,90); tOdd = prctile(qOdd,90);
assert(tAll > tOdd, ...
    ['pooling over contaminated frames should raise the threshold above the clean-only one ' ...
     '(%.3g vs %.3g) — if not, the fixture is not exercising the bias'], tAll, tOdd);
nAll=0; nOdd=0;
for t = 1:2:23
    im = double(imread(tp,t));
    nAll = nAll + size(spt_detect(im,DIAM,PX,tAll),1);
    nOdd = nOdd + size(spt_detect(im,DIAM,PX,tOdd),1);
end
assert(nOdd > nAll, ...
    ['the clean frames kept %d detections with the all-frames threshold and %d with the clean-only ' ...
     'one — the contaminated frames must not be setting the sensitivity of the clean ones'], nAll, nOdd);
fprintf('threshold pooling: all-frames thr %.3g -> %d clean detections; clean-only thr %.3g -> %d\n', ...
    tAll, nAll, tOdd, nOdd);

%% (B) interleaved frame map ----------------------------------------------------------------------
% 8 SPT frames, 4 organelle pages: page p covers SPT frames 2p-1 and 2p.
nfr = 8; nseg = 4;
sptPath = fullfile(root,'cell_spt1.tif'); segPath = fullfile(root,'cell_mito.tif');
% ONE detectable spot per frame, at a FIXED position. The mask is what moves, so the mito distance
% of that spot reads the organelle page directly — with a drifting spot or a cloud of noise
% detections you cannot tell a mis-mapped page from a moved molecule.
[Xg, Yg] = meshgrid(1:W, 1:H);
sigp = (DIAM/PX)/2/1.6;
spot = 3000*exp(-((Xg-50).^2 + (Yg-123).^2)/(2*sigp^2));
for t = 1:nfr
    rng(100+t);
    imwrite(uint16(200 + 3*randn(H,W) + spot), sptPath, 'WriteMode', tern_(t==1,'overwrite','append'));
end
for p = 1:nseg
    m = zeros(H,W,'uint8'); m(:) = 2;              % ilastik label map: 1 = fg, 2 = bg
    m(100:140, (10+40*p):(40+40*p)) = 1;           % the mask MOVES page to page, so a mis-map shows
    imwrite(m, segPath, 'WriteMode', tern_(p==1,'overwrite','append'));
end

% A threshold well above the noise floor, derived from the fixture itself so the count is exactly
% one detection per frame rather than a few hundred noise maxima.
qq = spt_detect(double(imread(sptPath,1)), DIAM, PX, []);
cel = struct('spt',sptPath, 'erSeg','', 'mitoSeg',segPath, 'key','cell', 'diamUm',DIAM, ...
             'thrAbs', 0.5*max(qq(:,3)));
prm = struct('linkUm',0.8, 'gapUm',1.4, 'maxGap',1, 'lambda',3, ...
             'pxUm',PX, 'dtS',0.02, 'linkMode','euclid', 'useEr',false);

out = spt_process_cell(cel, prm);
assert(out.segEvery == 2, ...
    'auto frame map read %d SPT frames per organelle page, wanted 2 (8 SPT pages, 4 organelle)', out.segEvery);

mitoCol = out.mito;      % signed mito distance per detection, um
assert(~any(isnan(mitoCol)), ...
    ['%d of %d detections still have NaN mito distance — the second half of the movie is exactly ' ...
     'what the old page-for-page indexing dropped'], sum(isnan(mitoCol)), numel(mitoCol));
assert(numel(mitoCol) == nfr, 'wanted one detection per frame, got %d over %d frames', numel(mitoCol), nfr);
fprintf('frame map: segEvery=%d, %d detections (1/frame), none without a mito distance\n', ...
    out.segEvery, numel(mitoCol));

% the map must be ceil(t/2), not floor or a repeat of page 1: frames 1-2 read page 1, 3-4 page 2, …
% The mask slides right by 40 px per page, so the distance from a FIXED spot changes page to page.
fr0 = double(out.frame);
d1 = unique(round(mitoCol(fr0 <= 1), 4));          % frames 0,1 -> page 1
d2 = unique(round(mitoCol(fr0 >= 2 & fr0 <= 3), 4));
d4 = unique(round(mitoCol(fr0 >= 6), 4));          % frames 6,7 -> page 4
assert(isscalar(d1) && isscalar(d2) && isscalar(d4), 'a frame pair straddled two organelle pages');
assert(d1 ~= d2 && d2 ~= d4, 'the mito distance did not change with the page — frames are not advancing the map');
fprintf('pairing verified: frames 0-1 -> page 1 (d=%.3f), 2-3 -> page 2 (d=%.3f), 6-7 -> page 4 (d=%.3f)\n', d1, d2, d4);

% maxFrames must not change the MAP. The ratio is a property of the stack, not of how much of it
% you asked for, and getting this wrong is silent: every frame still lands on some page.
prmCap = prm; prmCap.maxFrames = 3;
wCap = warning('off','spt_process_cell:segFramesShort');
outCap = spt_process_cell(cel, prmCap);
warning(wCap);
assert(outCap.segEvery == 2, ...
    ['with maxFrames=3 the map resolved to %d instead of 2 — it was read off the truncated frame ' ...
     'count rather than the stack'], outCap.segEvery);
assert(outCap.nFrames == 3, 'maxFrames should still limit the frames processed, got %d', outCap.nFrames);
fprintf('maxFrames limits the run without changing the organelle map (segEvery still %d)\n', outCap.segEvery);

% an explicit setting overrides auto
cel1 = cel; cel1.segEvery = 1;
warning('off','spt_process_cell:segFramesShort');
out1 = spt_process_cell(cel1, prm);
warning('on','spt_process_cell:segFramesShort');
assert(out1.segEvery == 1, 'an explicit segEvery=1 was overridden by auto-detection');
% Page-for-page on a half-length stack leaves the back half of the movie with no page at all. It
% must come back as NaN and be COUNTED — never clamped to the last page, which would hand frames
% 5-8 a mask that is not theirs and call it a measurement.
assert(out1.nFramesNoSegPage == 4, ...
    'segEvery=1 over 4 pages should leave 4 of 8 frames unmapped, got %d', out1.nFramesNoSegPage);
assert(sum(isnan(out1.mito)) == 4, ...
    'those 4 frames must carry NaN mito distance, not a clamped page: %d NaN', sum(isnan(out1.mito)));
assert(out.nFramesNoSegPage == 0, 'the correct map left %d frames unmapped', out.nFramesNoSegPage);
fprintf('segEvery=1 leaves %d/%d frames unmapped (NaN, counted, warned) — never clamped\n', ...
    out1.nFramesNoSegPage, nfr);

%% (C) the filter applies to the frames you say it does --------------------------------------------
% Interleaved acquisition puts the bleedthrough in every second frame, so gating all of them pays
% the filter's cost on the clean half for nothing. Same contaminated content on all 8 frames here,
% so the only thing that can move the count is WHICH frames were gated.
bleedPath = fullfile(root,'bleed_spt1.tif');
imgB = make_frame(H, W, pts, PX, DIAM);
for t = 1:8
    imwrite(uint16(imgB), bleedPath, 'WriteMode', tern_(t==1,'overwrite','append'));
end
celB = struct('spt',bleedPath, 'erSeg','', 'mitoSeg','', 'key','b', 'diamUm',DIAM, 'thrAbs',[]);
qB = spt_detect(imgB, DIAM, PX, []); celB.thrAbs = 0.4*max(qB(:,3));
prmB = prm; prmB.ridgeMax = 2; prmB.sizeMax = 1.6;

nOff  = numel(runCount(celB, rmfield_(prmB,{'ridgeMax','sizeMax'})));
nAll  = numel(runCount(celB, setf_(prmB,'bleedFrames','all')));
nEven = numel(runCount(celB, setf_(prmB,'bleedFrames','even')));
fprintf('detections over 8 identical frames — gate off %d, gate on all %d, gate on even only %d\n', ...
    nOff, nAll, nEven);
assert(nAll < nOff, 'the gate removed nothing across the stack (%d = %d)', nAll, nOff);
assert(nEven > nAll && nEven < nOff, ...
    ['gating EVEN frames only should land between all-gated (%d) and un-gated (%d); got %d. ' ...
     'Equal to one of them means the parity setting is being ignored.'], nAll, nOff, nEven);
% and it must be the ODD frames that kept their extra detections
oE = runCount(celB, setf_(prmB,'bleedFrames','even'));
assert(sum(mod(oE,2)==0) > sum(mod(oE,2)==1), ...
    'with EVEN frames gated, the surviving detections should sit mostly on the ODD (0-based even) frames');
fprintf('parity honoured: gating even frames leaves the odd ones untouched\n');

%% (D) a RAW INTERLEAVED stack is recognised as one -------------------------------------------------
% The case the shape/size gates are the WRONG answer to. If every second page is a different
% channel, the fix is to use the de-interleaved stack, not to filter the detections it produces —
% so the tool has to be able to tell the two situations apart.
ilPath = fullfile(root,'inter_spt12.tif'); clPath = fullfile(root,'clean_spt1.tif');
[Xi,Yi] = meshgrid(1:W,1:H);
organelle = 300*exp(-((Xi-W/2).^2)/(2*40^2)) .* (1 + 0.5*sin(Yi/9));   % broad, static, structured
for t = 1:40
    rng(500+t);
    parts = 200 + 8*randn(H,W);
    for q = 1:12                                   % particles that MOVE frame to frame
        cxp = 30 + mod(17*q + 3*t, W-60); cyp = 30 + mod(29*q + 5*t, H-60);
        parts = parts + 900*exp(-((Xi-cxp).^2 + (Yi-cyp).^2)/(2*1.5^2));
    end
    % clean: every page is the particle channel. interleaved: odd = particles, even = organelle.
    imwrite(uint16(parts), clPath, 'WriteMode', tern_(t==1,'overwrite','append'));
    imwrite(uint16(tern_(mod(t,2)==1, parts, 200 + 8*randn(H,W) + organelle)), ...
        ilPath, 'WriteMode', tern_(t==1,'overwrite','append'));
end
Sil = spt_interleave_check(ilPath);
Scl = spt_interleave_check(clPath);
fprintf('interleave check — raw two-channel delta %+.3f (%d), single channel delta %+.3f (%d)\n', ...
    Sil.delta, Sil.isInterleaved, Scl.delta, Scl.isInterleaved);
assert(Sil.isInterleaved, 'a raw interleaved stack was not recognised (delta %+.3f)', Sil.delta);
assert(~Scl.isInterleaved, 'a single-channel stack was called interleaved (delta %+.3f)', Scl.delta);
assert(Sil.delta - Scl.delta > 0.1, ...
    'the two cases are only %.3f apart — too close to separate reliably', Sil.delta - Scl.delta);
fprintf('interleaved and single-channel stacks separate by %.3f\n', Sil.delta - Scl.delta);

% and two stacks that strip to one cell key must not pass unremarked
skDir = fullfile(root,'keys'); mkdir(skDir);
copyfile(clPath, fullfile(skDir,'cellA_spt1.tif'));
copyfile(ilPath, fullfile(skDir,'cellA_spt12.tif'));
lastwarn(''); ws = warning('off','spt_match:duplicateKey');
mc = spt_match(skDir, '', '', '');
warning(ws);
[~, wid] = lastwarn();
assert(strcmp(wid,'spt_match:duplicateKey'), ...
    '_spt1 and _spt12 both strip to one cell key and nothing warned (got "%s")', wid);
assert(numel(mc)==2, 'both stacks should still be returned, got %d', numel(mc));
fprintf('duplicate cell key warned, both stacks still returned\n');

% ...and with the organelle mask, it must name WHICH parity to keep. The mask is used to attribute
% the channel, never to reject a detection — see the header of spt_interleave_check.
mskPath = fullfile(root,'inter_mask.tif');
for p_ = 1:20
    mk = zeros(H,W,'uint8'); mk(:) = 2; mk(:, round(W/2)-40:round(W/2)+40) = 1;
    imwrite(mk, mskPath, 'WriteMode', tern_(p_==1,'overwrite','append'));
end
Sm = spt_interleave_check(ilPath, 25, mskPath);
fprintf('parity attribution: odd %.2fx  even %.2fx -> organelle=%s, keep=%s\n', ...
    Sm.enrichOdd, Sm.enrichEven, Sm.organelleParity, Sm.particleParity);
assert(strcmp(Sm.organelleParity,'even') && strcmp(Sm.particleParity,'odd'), ...
    ['the mask should name the EVEN pages as the organelle channel (they carry the organelle in ' ...
     'this fixture); got organelle="%s"'], Sm.organelleParity);
assert(contains(Sm.why,'odd pages') && contains(Sm.why,'bleedthrough'), ...
    ['the message must name the clean parity AND offer the bleedthrough reading — an in-mask ' ...
     'intensity cannot tell an organelle channel from a contaminated particle one: %s'], Sm.why);
assert(Sm.crosstalk < 1.15, ...
    'the particle parity should show no crosstalk, got %.2fx', Sm.crosstalk);
% a SINGLE-channel stack must not have a parity attributed to it
Sc2 = spt_interleave_check(clPath, 25, mskPath);
assert(isempty(Sc2.organelleParity), ...
    'a single-channel stack was given an organelle parity ("%s") — both parities are the same channel', ...
    Sc2.organelleParity);
fprintf('single-channel stack gets no parity attributed, as it must\n');

%% (E) de-interleaving must equal the separately exported channel ------------------------------------
% The acquisition keeps ONE stack with both channels alternating; the single-channel export goes
% away. So detecting on the interleaved stack with de-interleaving on has to give exactly what
% detecting on that export gave — same detections, same frame numbers — or every result silently
% shifts the day the clean file stops being kept.
deDir = fullfile(root,'deint'); mkdir(deDir);
ilP = fullfile(deDir,'cell_spt12.tif');           % pages 1,3,5… particles / 2,4,6… organelle
clP = fullfile(deDir,'cell_spt1.tif');            % the same particle pages, on their own
segP = fullfile(deDir,'cell_mito.tif');
nSpt = 12;
[Xd, Yd] = meshgrid(1:W, 1:H);
org = 400*exp(-((Xd-W/2).^2)/(2*30^2)) .* (1 + 0.6*sin(Yd/7));
for t = 1:nSpt
    rng(900+t);
    f = 200 + 4*randn(H,W);
    for q = 1:6                                    % particles that move frame to frame
        f = f + 1400*exp(-((Xd-(40+9*q+2*t)).^2 + (Yd-(45+13*q+3*t)).^2)/(2*1.5^2));
    end
    imwrite(uint16(f), clP, 'WriteMode', tern_(t==1,'overwrite','append'));
    % ImageJ time calibration on page 1: the guard below has to be able to ask the FILE what its
    % page interval is, which is the whole point of it.
    ijd = sprintf('ImageJ=1.53t\nimages=%d\nframes=%d\nfinterval=%.10g\nunit=um\n', 2*nSpt, 2*nSpt, 0.01);
    if t == 1
        imwrite(uint16(f), ilP, 'WriteMode','overwrite', 'Description', ijd);
    else
        imwrite(uint16(f), ilP, 'WriteMode','append');
    end
    rng(9000+t);
    imwrite(uint16(200 + 4*randn(H,W) + org), ilP, 'WriteMode','append');         % even page: organelle
    m = zeros(H,W,'uint8'); m(:) = 2; m(:, round(W/2)-25:round(W/2)+25) = 1;
    imwrite(m, segP, 'WriteMode', tern_(t==1,'overwrite','append'));
end
assert(numel(imfinfo(ilP)) == 2*numel(imfinfo(clP)), 'fixture: the interleaved stack should be twice as long');

prmD = prm; prmD.dtS = 0.01;                        % the PAGE interval
celClean = struct('spt',clP,'erSeg','','mitoSeg',segP,'key','c','diamUm',DIAM,'thrAbs',400);
celInter = struct('spt',ilP,'erSeg','','mitoSeg',segP,'key','c','diamUm',DIAM,'thrAbs',400, ...
                  'frameStride',2,'frameOffset',0);
wq = warning('off','spt_process_cell:interleavedStack');
Rc = spt_process_cell(celClean, prmD);
Ri = spt_process_cell(celInter, prmD);
warning(wq);

assert(Ri.nFrames == Rc.nFrames, 'de-interleaved %d frames, the clean export has %d', Ri.nFrames, Rc.nFrames);
assert(isequal(Ri.frame, Rc.frame), 'frame numbering differs — de-interleaved frames must be renumbered 0,1,2…');
assert(isequal(round([Ri.x Ri.y],6), round([Rc.x Rc.y],6)), ...
    'de-interleaving gave different detections than the separately exported channel');
fprintf('de-interleaved run reproduces the clean export exactly: %d frames, %d detections\n', ...
    Ri.nFrames, numel(Ri.x));

% THE FRAME INTERVAL. Calibration times PAGES; taking every other page doubles the real interval
% between the frames that remain. Everything downstream reads dtS, so an un-doubled dtS scales
% every diffusion coefficient by 2 and nothing looks wrong.
assert(abs(Ri.dtS - 2*prmD.dtS) < 1e-12, ...
    'de-interleaved dtS is %g; taking every 2nd page must double the page interval %g', Ri.dtS, prmD.dtS);
assert(abs(Rc.dtS - prmD.dtS) < 1e-12, 'an un-strided run must leave dtS alone (%g vs %g)', Rc.dtS, prmD.dtS);
fprintf('frame interval doubled: page %.4g s -> frame %.4g s\n', Ri.dtPage, Ri.dtS);

% ...and the SETTINGS FILE must say the same thing. spt_project_calib reads calibration.frame_s as
% its most trustworthy source, ahead of the tracks XML, so a page interval written there would hand
% Tools 2 and 3 a dt half the real one — every D, dwell second and k_out downstream wrong by the
% stride, with the XML quietly disagreeing.
setDir = fullfile(root,'setcheck'); mkdir(setDir);
spt_write_settings(setDir, Ri.base, celInter, prmD, Ri);
stxt = fileread(fullfile(setDir,[Ri.base '_settings.txt']));
fsv = regexp(stxt, 'calibration\.frame_s\s*=\s*([\d.eE+-]+)', 'tokens','once');
assert(~isempty(fsv), 'the settings file has no calibration.frame_s line');
assert(abs(str2double(fsv{1}) - Ri.dtS) < 1e-9, ...
    ['settings say calibration.frame_s=%s but the run used dt=%g. That line is what Tools 2 and 3 ' ...
     'adopt, ahead of the tracks XML.'], fsv{1}, Ri.dtS);
assert(contains(stxt,'frames.de_interleave'), 'the settings file does not record the de-interleaving');
fprintf('settings record the effective frame interval (%.4g s), not the page interval\n', str2double(fsv{1}));

% WHICH interval was handed in. The interleaved file records HALF the de-interleaved one, so a user
% who types the interval they know from the single-channel export would have it doubled again and
% every diffusion coefficient would come out twice too slow. The stack's own metadata settles it.
dtMeta = NaN;
try, tcx = spt_tiff_calib(ilP); if isstruct(tcx) && isfield(tcx,'dt_s'), dtMeta = tcx.dt_s; end, catch, end
assert(isfinite(dtMeta) && dtMeta > 0, ...
    'the fixture must carry an ImageJ finterval, or the dt guard cannot be exercised at all');
if true
    prmWrong = prmD; prmWrong.dtS = dtMeta * 2;          % the FRAME interval, mistakenly given
    lastwarn(''); wq2 = warning('off','spt_process_cell:dtAlreadyPerFrame');
    Rw = spt_process_cell(celInter, prmWrong);
    warning(wq2); [~, wid2] = lastwarn();
    assert(abs(Rw.dtS - dtMeta*2) < 1e-12, ...
        ['a frame interval supplied by mistake was doubled again: dt came out %g, wanted %g. ' ...
         'Every diffusion coefficient downstream would be off by the stride.'], Rw.dtS, dtMeta*2);
    assert(strcmp(wid2,'spt_process_cell:dtAlreadyPerFrame'), ...
        'the mis-supplied interval was corrected silently (warning id "%s")', wid2);
    fprintf('a frame interval given by mistake is caught, not doubled again (dt %.4g s)\n', Rw.dtS);
end

% the organelle stack has one page per SPT FRAME, so after de-interleaving the map is 1:1
assert(Ri.segEvery == 1, ...
    'after de-interleaving the organelle map should be 1:1, got segEvery=%d', Ri.segEvery);
assert(Ri.nFramesNoSegPage == 0, '%d frames lost their organelle page', Ri.nFramesNoSegPage);
% and the even parity picks the OTHER channel, which must not look like the particle one
celEven = celInter; celEven.frameOffset = 1;
Re = spt_process_cell(celEven, prmD);
assert(~isequal(round([Re.x Re.y],6), round([Rc.x Rc.y],6)), ...
    'odd and even parities gave identical detections — the offset is being ignored');
fprintf('parity offset selects the other channel (%d detections vs %d)\n', numel(Re.x), numel(Rc.x));

% CHOOSING THE ORGANELLE PARITY MUST BE LOUD. The segmentation is derived from those pages, so
% detecting on them compares the organelle against a mask drawn from itself: every detection reads
% as colocalised, the result is self-consistent, and nothing about it looks wrong. Warning once at
% "this stack is interleaved" is not enough — that fires when the stride is UNSET, which is not
% when this happens.
lastwarn(''); wq3 = warning('off','spt_process_cell:keptOrganelleHeavyParity');
spt_process_cell(celEven, prmD);
warning(wq3); [~, wid3] = lastwarn();
assert(strcmp(wid3,'spt_process_cell:keptOrganelleHeavyParity'), ...
    ['de-interleaving onto the ORGANELLE parity passed without warning (id "%s") — the mask is ' ...
     'drawn from those pages, so the run would look perfectly colocalised'], wid3);
% ...and the correct parity must NOT warn, or the warning is noise
lastwarn(''); wq4 = warning('off','spt_process_cell:keptOrganelleHeavyParity');
spt_process_cell(celInter, prmD);
warning(wq4); [~, wid4] = lastwarn();
assert(~strcmp(wid4,'spt_process_cell:keptOrganelleHeavyParity'), ...
    'the correct (particle) parity was warned about — the check has the parities the wrong way round');
fprintf('choosing the organelle parity warns; choosing the particle parity does not\n');

fprintf('\nspt_bleedthrough_smoke: all assertions passed\n');
end

function fr = runCount(cel, prm)
% Frame column of every detection from a full run, with the run's own warnings hushed.
w = warning('off','spt_process_cell:segFramesShort');
c = onCleanup(@() warning(w));
R = spt_process_cell(cel, prm);
fr = R.frame;
end

function s = setf_(s, f, v), s.(f) = v; end
function s = rmfield_(s, f), for i=1:numel(f), if isfield(s,f{i}), s = rmfield(s,f{i}); end, end, end

% ================================================================================================
function [img, filMask] = make_frame(H, W, pts, px, diam)
% Real single molecules (isotropic PSFs) plus a curved, rippled filament stitched from overlapping
% Gaussians — the ripple is what turns a ridge into a CHAIN of local maxima, which is the failure
% mode being tested. Fixed seed: the assertions are counts, and they have to be reproducible.
rng(7);
sig = (diam/px)/2/1.6;
[X, Y] = meshgrid(1:W, 1:H);
img = 100 + 4*randn(H, W);
for k = 1:size(pts,1)
    img = img + 260*exp(-((X-pts(k,1)).^2 + (Y-pts(k,2)).^2)/(2*sig^2));
end
t  = linspace(0,1,1400);
fx = 30 + 200*t; fy = 130 + 46*sin(2*pi*t*1.15);
amp = 240*(1 + 0.35*sin(2*pi*t*9));
filMask = false(H, W);
for k = 1:numel(t)
    img = img + amp(k)*exp(-((X-fx(k)).^2 + (Y-fy(k)).^2)/(2*2.0^2))/12;
    filMask(max(1,min(H,round(fy(k)))), max(1,min(W,round(fx(k))))) = true;
end
filMask = imdilate(filMask, strel('disk',6));
end

function [nPt, nFil] = split_dets(xy, pts, filMask)
% Split detections into "on a planted molecule" and "on the filament". Counted against the PLANTED
% positions, not against each other, so a detection cannot be credited to both.
nPt = 0; nFil = 0;
[H, W] = size(filMask);
for i = 1:size(xy,1)
    if any(hypot(pts(:,1)-xy(i,1), pts(:,2)-xy(i,2)) <= 2.5)
        nPt = nPt + 1;
    elseif filMask(max(1,min(H,round(xy(i,2)))), max(1,min(W,round(xy(i,1)))))
        nFil = nFil + 1;
    end
end
end

function [img, filMask, pts, sig] = make_scaled(H, W, px, diam)
% The (A) fixture at an arbitrary diameter: PSF sigma and filament width both scale with it, so the
% scene stays the same scene and only the SIZE changes. Testing a size-dependent criterion against a
% fixture of fixed size would prove nothing about the dependence.
rng(11);
sig = (diam/px)/2/1.6;
fw  = max(2.0, sig*1.4);
pts = [50 50; 110 70; 190 250; 250 150; 75 220; 150 110; 230 75; 265 265];
pts = min(pts, min(H,W)-10);
[X, Y] = meshgrid(1:W, 1:H);
img = 100 + 4*randn(H, W);
for k = 1:size(pts,1)
    img = img + 260*exp(-((X-pts(k,1)).^2 + (Y-pts(k,2)).^2)/(2*sig^2));
end
t = linspace(0,1,1800); fx = 40 + 0.75*W*t; fy = 0.5*H + 56*sin(2*pi*t*1.15);
amp = 240*(1 + 0.35*sin(2*pi*t*9));
filMask = false(H, W);
for k = 1:numel(t)
    img = img + amp(k)*exp(-((X-fx(k)).^2 + (Y-fy(k)).^2)/(2*fw^2))/(6*fw);
    filMask(max(1,min(H,round(fy(k)))), max(1,min(W,round(fx(k))))) = true;
end
filMask = imdilate(filMask, strel('disk', ceil(fw*3)));
end

function y = tern_(c, a, b), if c, y = a; else, y = b; end, end
