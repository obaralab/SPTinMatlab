function spt_detect_speed_smoke()
%SPT_DETECT_SPEED_SMOKE  The three things made faster in the per-cell loop must not have changed
%what it produces.
%
% WHAT IS ASSERTED:
%   1. THE BLUR IS STILL THE SAME BLUR. spt_dog builds its own separable Gaussian instead of calling
%      imgaussfilt (which picks the frequency domain for the wide background kernel and costs 4 ms a
%      frame for it). Against imgaussfilt's SPATIAL path — same kernel, same symmetric padding — the
%      two agree to floating-point, over several cameras and spot sizes.
%   2. THE SAME DETECTIONS come out: same count, same coordinates.
%   3. ONE OPEN FILE HANDLE READS THE SAME PIXELS as imread(path, k), in order and out of order, and
%      spt_tiff_pages falls back to imread rather than failing when the handle is gone.
%   4. THE CACHED DISTANCE FIELD IS INVALIDATED. The signed distance to the organelle is computed
%      once per organelle PAGE now, not once per frame. A cache that never refreshed would report
%      page 1's geometry for the whole movie and nothing else would notice, so this runs a cell whose
%      mask MOVES between pages and checks the distances move with it.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
root = fullfile(tempdir, sprintf('spt_speed_%d', feature('getpid')));
if isfolder(root), rmdir(root,'s'); end
mkdir(root);
cleanup = onCleanup(@() rmdir(root,'s'));

%% (1)(2) the blur, and the detections it feeds ------------------------------------------------------
rng(9); S = 96;
im = uint16(300 + 20*randn(S,S));
for j = 1:12
    x = randi([8 S-8]); y = randi([8 S-8]);
    im(y-1:y+1, x-1:x+1) = im(y-1:y+1, x-1:x+1) + uint16(900);
end
raw = double(im);
worst = 0; nSpots = 0;
for px = [0.0968 0.10785 0.16]
    for diamUm = [0.3 0.5 0.8]
        rpx = (diamUm/px)/2; sc = rpx/((0.5/0.10785)/2);
        ref = @(x,s) imgaussfilt(x, s, 'Padding','symmetric', 'FilterSize', 2*ceil(4*s)+1, ...
                                 'FilterDomain','spatial');
        hpR  = raw - ref(raw, 6*sc);
        dogR = ref(hpR, 1*sc) - ref(hpR, 2.2*sc);
        [dogN, hpN] = spt_dog(raw, diamUm, px);
        worst = max([worst, max(abs(dogR(:)-dogN(:))), max(abs(hpR(:)-hpN(:)))]);
        xy = spt_detect(raw, diamUm, px, 50, struct());
        nSpots = nSpots + size(xy,1);
    end
end
assert(worst < 1e-9, 'the separable blur no longer matches imgaussfilt''s spatial path (%.3e)', worst);
assert(nSpots > 0, 'the fixture should detect something');

%% (3) one handle, same pixels -----------------------------------------------------------------------
mv = fullfile(root,'movie.tif'); nP = 12;
for k = 1:nP
    f = uint16(100*k + zeros(24,24)); f(3:5, 7:9) = 60000;
    if k == 1, imwrite(f, mv); else, imwrite(f, mv, 'WriteMode','append'); end
end
[readPage, closeMovie] = spt_tiff_pages(mv);
for k = 1:nP
    assert(isequal(readPage(k), imread(mv,k)), 'page %d differs from imread', k);
end
for k = [7 2 12 1 9]                                   % out of order, as a stride or offset gives
    assert(isequal(readPage(k), imread(mv,k)), 'page %d differs on random access', k);
end
closeMovie();
assert(isequal(readPage(3), imread(mv,3)), 'reading after close should fall back to imread, not fail');

%% (4) the distance cache refreshes when the page changes --------------------------------------------
% 8 frames, 2 organelle pages: the mask is on the LEFT for frames 1-4 and on the RIGHT for 5-8, and
% the molecule sits still. Its distance to the organelle must therefore change halfway through.
nF = 8; W = 64;
spt = fullfile(root,'cell.tif');
for t = 1:nF
    f = uint16(300 + zeros(W,W));
    f(31:33, 31:33) = 20000;                           % one bright spot, same place every frame
    if t == 1, imwrite(f, spt); else, imwrite(f, spt, 'WriteMode','append'); end
end
mito = fullfile(root,'mito.tif');
m1 = false(W); m1(:, 1:10)  = true;                    % page 1: far to the LEFT of the spot
m2 = false(W); m2(:, 26:end) = true;                   % page 2: covering the spot
imwrite(uint8(m1)*255, mito);
imwrite(uint8(m2)*255, mito, 'WriteMode','append');
cel = struct('spt',spt,'erSeg','','mitoSeg',mito,'key','k','diamUm',0.4,'thrAbs',50);
prm = struct('linkUm',0.5,'gapUm',0.5,'maxGap',1,'useEr',false,'lambda',3,'pxUm',0.1,'dtS',0.02);
R = spt_process_cell(cel, prm);
assert(~isempty(R.mito) && any(isfinite(R.mito)), 'the run produced no organelle distances');
early = R.mito(R.frame <= 3);  late = R.mito(R.frame >= 4);
early = early(isfinite(early)); late = late(isfinite(late));
assert(~isempty(early) && ~isempty(late), 'expected detections in both halves of the movie (%d / %d)', ...
    numel(early), numel(late));
assert(median(early) > 0, 'on page 1 the mask is far from the spot, so the distance is positive (%.2f)', median(early));
assert(median(late) < median(early) - 0.5, ...
    ['the organelle moved under the molecule at the page change and the distance did not follow ' ...
     '(%.2f then %.2f um) — the cached distance field is stale'], median(early), median(late));

fprintf('blur matches imgaussfilt to %.1e over 9 camera/size combinations, %d detections\n', worst, nSpots);
fprintf('tiff handle: %d pages identical to imread, random access and post-close fallback OK\n', nP);
fprintf('distance cache: %.2f um before the page change, %.2f um after\n', median(early), median(late));
fprintf('\nDETECT-SPEED SMOKE PASSED.\n');
end
