function spt_page_map_smoke()
%SPT_PAGE_MAP_SMOKE  Which segmentation page belongs to a tracked frame, read from the file rather
%than assumed — and the case where the assumption is wrong by a whole channel.
%
% WHAT IS ASSERTED:
%   1. THE LABELS ARE READ. spt_tiff_labels recovers the channel and timepoint of each page from an
%      ImageJ-labelled stack, for a single-colour stack as well as an interleaved one.
%   2. WHAT THE LABELS ADD IS NOT THE PAGE NUMBER. The arithmetic follows from the counts either way;
%      what the labels change is what the mask MEANS (the organelle at that timepoint, or averaged
%      over a window) and whether the movie should have been tracked as it was at all. Both relations
%      are named, and the interleaving is reported separately from the mapping.
%   3. THE INTERLEAVED CASE DISAGREES WITH frame+1, and says so rather than correcting it quietly:
%      frame 2 of a two-channel movie is timepoint 2, not page 3, and past the segmentation's end the
%      old rule clamps to the last page for the whole rest of the movie.
%   4. A WINDOW IS CONTAINMENT. Page p covers frames [(p-1)w, pw), so a frame on the boundary belongs
%      to the page that contains it rather than the nearer centre.
%   5. cs_channel_mask APPLIES A MAPPING WHEN GIVEN ONE and is unchanged without it — the default has
%      to stay put, because it is in published masks.
%   6. NO LABELS IS NOT AN ERROR: the counts are used, and the fallback is named.
%   7. THE INTERLEAVE CHECK ASKS THE FILE FIRST, and labels naming two channels are proof — no pixel
%      correlation needed, and the (a)-vs-(b) ambiguity that check documents is resolved. But labels
%      naming ONE channel do NOT clear a stack whose pages alternate anyway: a label survives a crop
%      or a concatenation that rearranged the pages under it, and a needless warning costs far less
%      than half a run of mitochondrial edges.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath'));
addpath(here, fullfile(fileparts(fileparts(here)),'tool1_track'));
root = fullfile(tempdir, sprintf('spt_pagemap_%d', feature('getpid')));
if isfolder(root), rmdir(root,'s'); end
mkdir(root);
cleanup = onCleanup(@() rmdir(root,'s'));

%% (1) the labels ------------------------------------------------------------------------------------
nTp = 20;
lab2 = {};
for t = 1:nTp
    lab2{end+1} = sprintf('c:1/2 t:%d/%d - cellA #1', t, nTp); %#ok<AGROW>
    lab2{end+1} = sprintf('c:2/2 t:%d/%d - cellA #1', t, nTp); %#ok<AGROW>
end
spt2 = fullfile(root,'interleaved.tif'); ijwrite(spt2, lab2);
L = spt_tiff_labels(spt2);
assert(L.ok && L.nCh == 2 && L.nPages == 2*nTp, 'the interleaved labels should read: %s', L.text);
assert(isequal(L.tp(1:4)', [1 1 2 2]), 'two pages per timepoint, got %s', mat2str(L.tp(1:4)'));

lab1 = arrayfun(@(t) sprintf('c:1/4 t:%d/%d - cellB #1', t, nTp), 1:nTp, 'uni', 0);
spt1 = fullfile(root,'single.tif'); ijwrite(spt1, lab1);
L1 = spt_tiff_labels(spt1);
assert(L1.ok && L1.nCh == 4 && numel(unique(L1.tp)) == nTp, ...
    'a de-interleaved single colour reads too, with its timepoints renumbered to its pages: %s', L1.text);

%% a segmentation with one page per timepoint --------------------------------------------------------
seg = fullfile(root,'mito.tif');
for k = 1:nTp
    m = false(16,16); m(2+mod(k,4) : 8+mod(k,4), 4:12) = true;
    if k == 1, imwrite(uint8(m)*255, seg); else, imwrite(uint8(m)*255, seg, 'WriteMode','append'); end
end

%% (2)(3) the interleaved movie -----------------------------------------------------------------------
M = spt_page_map(spt2, seg);
assert(strcmp(M.relation,'perTimepoint'), ...
    'labels + counts should identify the interleaved case, got %s', M.relation);
assert(M.perPage == 2 && M.nTp == nTp, '2 frames per page over %d timepoints (got %g, %g)', nTp, M.perPage, M.nTp);
assert(isequal(M.pageOf([0 1 2 3]), [1 1 2 2]), ...
    'frames 0 and 1 are timepoint 1, frames 2 and 3 timepoint 2, got %s', mat2str(M.pageOf([0 1 2 3])));
assert(~M.agreesWithLegacy, 'and this must be reported as disagreeing with the frame+1 rule');
assert(contains(M.text,'NOT f+1') && contains(M.text,'DISAGREES'), 'plainly: "%s"', M.text);
assert(M.interleaved && contains(M.text,'SEPARATELY'), ...
    ['and the movie being interleaved at all must be reported as its own problem — a stack tracked ' ...
     'as 2N frames when it holds N timepoints of two colours links across the colours, whatever the ' ...
     'mask mapping does: "%s"'], M.text);
% the old rule, on the second half of this movie, is stuck on the last page
legacy = min(max((0:2*nTp-1)+1, 1), nTp);
assert(nnz(legacy == nTp) > nTp, ...
    'the frame+1 rule should be pinned to the last page for most of an interleaved movie (%d frames)', ...
    nnz(legacy == nTp));

% the same page counts, but a single-channel movie: one for one, and no disagreement
Mone = spt_page_map(spt1, seg);
assert(strcmp(Mone.relation,'perFrame') && Mone.agreesWithLegacy, ...
    'a single-colour movie with a page per segmented page maps one for one, got %s', Mone.relation);
assert(~Mone.interleaved, 'and c:1/4 on every page is ONE channel here, whatever the acquisition had');
assert(M.nSpt == 2*Mone.nSpt && M.nSeg == Mone.nSeg, ...
    'the two cases differ only in the movie''s page count, which is exactly why the labels are read');

%% (4) a window is containment -----------------------------------------------------------------------
segW = fullfile(root,'win.tif');
for k = 1:4
    if k == 1, imwrite(uint8(true(16))*255, segW); else, imwrite(uint8(true(16))*255, segW, 'WriteMode','append'); end
end
MW = spt_page_map('', segW, 'NSpt', 40, 'NSeg', 4);
assert(strcmp(MW.relation,'window') && MW.perPage == 10, ...
    '40 frames over 4 pages averages 10 to a page, got %s / %g', MW.relation, MW.perPage);
assert(isequal(MW.pageOf([0 9 10 19 39]), [1 1 2 2 4]), ...
    'the boundary between windows is a step, not a rounding: got %s', mat2str(MW.pageOf([0 9 10 19 39])));

%% (5) cs_channel_mask with and without the mapping ---------------------------------------------------
mDefault = cs_channel_mask(seg, nTp, 2, []);                       % page 3, the old rule
mMapped  = cs_channel_mask(seg, nTp, 2, [], 'PageOf', M.pageOf);   % page 2, the timepoint
mPage2   = cs_channel_mask(seg, nTp, 1, []);
assert(isequal(mMapped, mPage2), 'a supplied mapping must choose the page it names');
assert(~isequal(mDefault, mMapped), ...
    'and it must differ from the default here, or this test is not exercising anything');
mAgain = cs_channel_mask(seg, nTp, 2, []);
assert(isequal(mAgain, mDefault), 'while the default is untouched');

%% (6) no labels -------------------------------------------------------------------------------------
plain = fullfile(root,'plain.tif');
for k = 1:6
    if k == 1, imwrite(uint8(zeros(8)), plain); else, imwrite(uint8(zeros(8)), plain, 'WriteMode','append'); end
end
Lp = spt_tiff_labels(plain);
assert(~Lp.ok && strcmp(Lp.source,'none'), 'a stack without labels is not an error');
MP = spt_page_map(plain, seg);
assert(ismember(MP.relation, {'unknown','window','perFrame'}), ...
    'without labels the counts are all there is, got %s', MP.relation);
assert(~isempty(MP.text), 'and the fallback is named: "%s"', MP.text);

%% (7) the interleave check, asking the file ---------------------------------------------------------
% Flat pages: the pixel correlation has nothing to go on, so only the labels can answer.
flat2 = fullfile(root,'flat_two.tif'); ijwrite(flat2, lab2);
S2 = spt_interleave_check(flat2, 8);
assert(S2.isInterleaved && strcmp(S2.source,'labels'), ...
    'labels naming two channels are proof, with no correlation needed (source %s)', S2.source);
assert(isequal(S2.channels, [1 2]) && S2.nTp == nTp, ...
    'and they name which channels over how many timepoints, got %s / %g', mat2str(S2.channels), S2.nTp);
assert(contains(S2.why,'read from the file, not inferred'), 'said as read, not inferred: "%s"', S2.why);

flat1 = fullfile(root,'flat_one.tif'); ijwrite(flat1, lab1);
S1 = spt_interleave_check(flat1, 8);
assert(~S1.isInterleaved && strcmp(S1.source,'labels'), ...
    'one channel in the labels, and nothing in the pixels to contradict it (source %s)', S1.source);

% A stack whose labels say one channel but whose pages really do alternate: the warning must stand.
% Two fixed patterns, one per parity, so frame t matches t+2 (same pattern) better than t+1.
rng(7);
A = uint8(40 + 160*double(checkerboard(3, 4, 4) > 0.5));
B = uint8(40 + 160*double(repmat(linspace(0,1,size(A,2)), size(A,1), 1) > 0.5));
P = cell(1,24);
for t = 1:24
    base = A; if mod(t,2) == 0, base = B; end
    P{t} = uint8(max(0, min(255, double(base) + 4*randn(size(base)))));
end
staleLab = arrayfun(@(t) sprintf('c:1/2 t:%d/24 - stale #1', t), 1:24, 'uni', 0);
conf = fullfile(root,'conflict.tif'); ijwrite(conf, staleLab, P);
SC = spt_interleave_check(conf, 12);
assert(SC.isInterleaved, ...
    ['a label naming one channel must NOT clear a stack whose pages alternate (delta %+.3f) — the ' ...
     'label can be stale, and a missed interleaved stack fills the results with organelle edges'], ...
    SC.delta);
assert(strcmp(SC.source,'conflict') && contains(SC.why,'Both are reported'), ...
    'and the disagreement must be stated rather than resolved silently (source %s): "%s"', SC.source, SC.why);

fprintf('interleave: labelled two-channel -> %s; one channel -> %s; stale label over alternating pages -> %s\n', ...
    S2.source, S1.source, SC.source);
fprintf('page map: %s\n', M.text);
fprintf('single colour: %s\n', Mone.text);
fprintf('window: %s\n', MW.text);
fprintf('\nSPT-PAGE-MAP SMOKE PASSED.\n');
end

% =================================================================================================
function ijwrite(path, labels, pages)
% A TIFF carrying ImageJ slice labels. imwrite cannot write unknown tags, so the file is assembled
% byte by byte and handed to imfinfo like any other — a test that fed the reader a buffer it had also
% built would prove nothing about reading a FILE.
%
% pages : optional 1xN cell of uint8 images, one per label. Omitted, each page is a single pixel,
%         which is all the label reader needs; supplied, the pages carry real content so the pixel
%         correlation has something to measure and can be set AGAINST the labels.
n = numel(labels);
if nargin < 3 || isempty(pages)
    pages = arrayfun(@(k) uint8(mod(k*40,250)), 1:n, 'uni', 0);
end
assert(numel(pages) == n, 'one page per label');

hdr = uint8([uint8('IJIJ'), uint8('labl'), be32(n)]);
cnt = numel(hdr); body = uint8([]);
for k = 1:n
    b = utf16be(labels{k}); body = [body, b]; cnt(end+1) = numel(b); %#ok<AGROW>
end
ijm = [hdr, body];

out = uint8([uint8('II'), lo16(42), lo32(8)]);
pxOff = zeros(1,n); H = zeros(1,n); W = zeros(1,n);
for k = 1:n
    im = uint8(pages{k}); [H(k), W(k)] = size(im);
    pxOff(k) = numel(out);
    out = [out, reshape(im', 1, [])];                 % TIFF rows are contiguous %#ok<AGROW>
    if mod(numel(out),2), out = [out, uint8(0)]; end  %#ok<AGROW>
end
ijmOff = numel(out); out = [out, ijm];
if mod(numel(out),2), out = [out, uint8(0)]; end
cntOff = numel(out);
for i = 1:numel(cnt), out = [out, lo32(cnt(i))]; end  %#ok<AGROW>

ifdOff = zeros(1,n);
for k = 1:n
    ifdOff(k) = numel(out);
    E = [256 3 1 W(k); 257 3 1 H(k); 258 3 1 8; 259 3 1 1; 262 3 1 1; 273 4 1 pxOff(k); ...
         277 3 1 1; 278 3 1 H(k); 279 4 1 H(k)*W(k)];
    if k == 1
        E = sortrows([E; 50838 4 numel(cnt) cntOff; 50839 1 numel(ijm) ijmOff], 1);
    end
    e = uint8([]);
    for r = 1:size(E,1)
        e = [e, lo16(E(r,1)), lo16(E(r,2)), lo32(E(r,3)), lo32(E(r,4))]; %#ok<AGROW>
    end
    out = [out, lo16(size(E,1)), e, lo32(0)];         %#ok<AGROW>
end
for k = 1:n
    nxt = 0; if k < n, nxt = ifdOff(k+1); end
    nE = 9; if k == 1, nE = 11; end
    q = ifdOff(k) + 2 + 12*nE;                        % 0-based offset of the next-IFD pointer
    out(q+1 : q+4) = lo32(nxt);
end
out(5:8) = lo32(ifdOff(1));
fid = fopen(path,'w'); assert(fid > 0, 'cannot write %s', path);
fwrite(fid, out, 'uint8'); fclose(fid);
end

function b = lo16(v), b = uint8([mod(v,256), floor(v/256)]); end
function b = lo32(v)
v = double(v);
b = uint8([mod(v,256), mod(floor(v/256),256), mod(floor(v/65536),256), mod(floor(v/16777216),256)]);
end
function b = be32(v)
v = double(v);
b = uint8([floor(v/16777216), mod(floor(v/65536),256), mod(floor(v/256),256), mod(v,256)]);
end
function b = utf16be(s)
u = double(s); b = uint8(zeros(1, 2*numel(u)));
b(1:2:end) = floor(u/256); b(2:2:end) = mod(u,256);
end
