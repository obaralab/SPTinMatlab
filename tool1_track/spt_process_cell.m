function R = spt_process_cell(cel, prm)
%SPT_PROCESS_CELL  Detect (all frames) -> track -> per-spot mito distance for one matched cell.
%
%   R = spt_process_cell(cel, prm)
%
% cel : matched-cell struct with fields spt, erSeg, mitoSeg, key, and (from the Detect tab) diamUm,
%       thrAbs (absolute DoG threshold) or keepPct (top-percentile fallback).
% prm : struct with linkUm, gapUm, maxGap, useEr (or the legacy erAware), lambda, pxUm, dtS;
%       optional maxFrames,
%       progressFcn(@(frac,msg)).
%
% Returns R with the FULL detection set (every spot — the localization cloud) plus the linked
% tracks: fields frame(0-based), x/y (1-based px), q, mean/max/total, mito (signed µm; NaN if no
% mito), spotId(0-based), trackId(NaN if untracked), xmlTracks (per-track spotId lists), base, dtS,
% pxUm, nFrames, nTracks, haveMito, useEr. Feed to spt_write_outputs.
px = prm.pxUm;
diamUm = getf_(cel,'diamUm',0.5);
[~, base] = fileparts(cel.spt);
info = imfinfo(cel.spt); nPages = numel(info);

% ---- DE-INTERLEAVING: which PAGES of the stack are this channel ----
% A two-colour acquisition saved as one stack has the channels alternating page by page. Detecting
% on all of them means every second "frame" is an organelle image. frameStride/frameOffset select
% one channel's pages: stride 2 offset 0 = pages 1,3,5… (the first channel), offset 1 = 2,4,6….
%
% The pages are then RENUMBERED to consecutive frames 0,1,2,…, which is what tracking must see: the
% SPT frames really are consecutive in time, and linking with a gap of one because the page numbers
% jump by two would forbid every link at maxGap 1.
frameStride = max(1, round(getf_(cel,'frameStride', getf_(prm,'frameStride',1))));
frameOffset = max(0, round(getf_(cel,'frameOffset', getf_(prm,'frameOffset',0))));
pages = (frameOffset+1) : frameStride : nPages;
nfrFull = numel(pages);        % what the WHOLE stack yields, before any maxFrames truncation
if isfield(prm,'maxFrames') && ~isempty(prm.maxFrames), pages = pages(1:min(numel(pages), prm.maxFrames)); end
nfr = numel(pages);
assert(nfr > 0, 'spt_process_cell:noFrames', ...
    '%s: frame stride %d / offset %d selects no pages from a %d-page stack', ...
    cel.spt, frameStride, frameOffset, nPages);

% THE FRAME INTERVAL DOUBLES. Calibration resolves the interval between PAGES; taking every other
% page makes the real time between SPT frames twice that. Everything downstream — MSD, D, dwell
% seconds, k_out — reads dtS, so getting this wrong scales every diffusion coefficient by the
% stride and nothing anywhere would look wrong.
% WHICH interval was handed in? Doubling is only right if prm.dtS is the PAGE interval. The
% interleaved file records half the de-interleaved one (measured: 0.01003212 s/page against
% 0.02006423 s/frame on the same acquisition), so typing in the frame interval you know from the
% single-channel export — the natural thing to do — would be doubled again and make every diffusion
% coefficient twice too slow. The stack's own metadata describes its own pages, so ask the file,
% and say plainly which reading was used.
dtPage = prm.dtS;
if frameStride > 1
    dtMeta = NaN;
    try, tc = spt_tiff_calib(cel.spt); if isstruct(tc) && isfield(tc,'dt_s'), dtMeta = tc.dt_s; end, catch, end
    if isfinite(dtMeta) && dtMeta > 0
        near = @(a,b) abs(a-b) <= 0.02*abs(b);
        if near(prm.dtS, dtMeta)
            dtPage = prm.dtS;                                   % page interval, as expected
        elseif near(prm.dtS, dtMeta*frameStride)
            dtPage = dtMeta;                                    % a FRAME interval was supplied
            warning('spt_process_cell:dtAlreadyPerFrame', ...
                ['%s: the frame interval given (%.6g s) is the DE-INTERLEAVED one, but this stack ' ...
                 'records %.6g s per page. Taking %.6g s/page x %d = %.6g s/frame — the supplied ' ...
                 'value was NOT doubled again.'], base, prm.dtS, dtMeta, dtMeta, frameStride, dtMeta*frameStride);
        else
            warning('spt_process_cell:dtDisagrees', ...
                ['%s: the frame interval given (%.6g s) matches neither this stack''s own %.6g s ' ...
                 'per page nor %.6g s per de-interleaved frame. Using the given value as the PAGE ' ...
                 'interval, so frames are %.6g s apart — check the calibration.'], ...
                base, prm.dtS, dtMeta, dtMeta*frameStride, prm.dtS*frameStride);
        end
    end
end
dtFrame = dtPage * frameStride;
dtSrcCh = 'page x stride';
% A TRACKED CHANNEL MAY STATE ITS OWN FRAME INTERVAL, and then it wins. Deriving dt as page x stride
% assumes the only reason a colour has fewer frames is that it shares pages with another; a strobed
% colour in its own stack has stride 1 and a dt that is nothing to do with the page interval.
% Getting it wrong scales every diffusion coefficient, dwell time and rate by that factor, silently.
dtCh = getf_(cel,'dt_s', getf_(prm,'dtFrame', NaN));
if ~isempty(dtCh) && isfinite(dtCh) && dtCh > 0
    if isfinite(dtFrame) && dtFrame > 0 && abs(dtCh - dtFrame) > 0.02*dtFrame
        warning('spt_process_cell:dtChannelOverride', ...
            ['%s: this channel declares %.6g s per frame, but the stack and stride give %.6g s. ' ...
             'Using the channel''s own value — check it is the one you meant.'], base, dtCh, dtFrame);
    end
    dtFrame = dtCh; dtSrcCh = 'channel';
end
% THE TIME ORIGIN. Interleaved colours do not start at the same instant: the colour on the even
% pages begins one page interval after the odd one. Recording it is what lets the two be put on one
% clock later; without it both claim t = 0 and the offset becomes a systematic half-frame lie.
t0_s = frameOffset * dtPage;
chKey = char(getf_(cel,'chKey', getf_(prm,'chKey','')));
prog = []; if isfield(prm,'progressFcn'), prog = prm.progressFcn; end

% Detector options. ridgeMax rejects filament-shaped candidates (mito bleedthrough); off unless
% asked for, so an existing project re-runs bit-for-bit identically.
dopts = struct('ridgeMax', getf_(cel,'ridgeMax', getf_(prm,'ridgeMax', [])), ...
               'sizeMax',  getf_(cel,'sizeMax',  getf_(prm,'sizeMax',  [])), ...
               'alignDeg', getf_(cel,'alignDeg', getf_(prm,'alignDeg', [])));
% Which frames the filter applies to. In an interleaved acquisition the bleedthrough is in every
% SECOND frame, so gating all of them would pay the filter's (small but real) cost on the clean
% half for nothing. 'all' | 'odd' (1,3,5…) | 'even' (2,4,6…), 1-based to match the Detect tab's
% frame slider, NOT the 0-based frame column in the spots CSV.
bleedOn = lower(char(getf_(cel,'bleedFrames', getf_(prm,'bleedFrames','all'))));
if ~any(strcmp(bleedOn,{'all','odd','even'})), bleedOn = 'all'; end
% Which frames the Top-% threshold is POOLED from. Separate from bleedFrames on purpose: you gate
% the dirty parity but want the threshold set by the clean one.
thrOn = lower(char(getf_(cel,'thrFrames', getf_(prm,'thrFrames','all'))));
if ~any(strcmp(thrOn,{'all','odd','even'})), thrOn = 'all'; end

% ---- per-file absolute threshold (stored from the Detect tab, else pool + percentile) ----
thr = [];
if isfield(cel,'thrAbs') && ~isempty(cel.thrAbs), thr = cel.thrAbs; end
if isempty(thr)
    % WHICH FRAMES SET THE THRESHOLD. Top % takes a percentile of the pooled candidate qualities,
    % and bleedthrough contributes a flood of candidates — so pooling over contaminated frames lets
    % the contamination set the sensitivity for the CLEAN frames too, cell by cell, in proportion to
    % how contaminated each cell happens to be. Measured across three cells: pooling over all frames
    % put the threshold at 25.1 / 32.0 / 36.6 and the clean channel at 16.8 / 35.4 / 47.6 detections
    % per frame — a 2.8x spread. Pooling the clean parity alone gave 82.7 / 63.7 / 65.1, a 1.3x
    % spread. Most of that apparent cell-to-cell variation was the threshold moving, not the biology.
    qopts = dopts; qopts.stride = frameStride; qopts.offset = frameOffset;
    qopts.bleedFrames = bleedOn;
    switch thrOn
        case 'odd',  qopts.stride = 2*frameStride; qopts.offset = frameOffset;
        case 'even', qopts.stride = 2*frameStride; qopts.offset = frameOffset + frameStride;
    end
    q = spt_pool_quality(cel.spt, diamUm, px, 40, qopts);
    if ~isempty(q), thr = prctile(q, 100 - getf_(cel,'keepPct',10)); end
    thrSrc = 'pooled';                      % resolved from THIS cell's own frames
else
    thrSrc = 'fixed';                       % carried in on the cell (previewed, or Quality >=)
end
rPx = (diamUm/px)/2;

% ---- ER masks (per-spot ER distance + link-mode supports) + mito masks ----
haveEr   = ~isempty(cel.erSeg) && isfile(cel.erSeg);
modeReq = ''; if isfield(prm,'linkMode') && ~isempty(prm.linkMode), modeReq = prm.linkMode; end
% prm.useEr was called prm.erAware before the three-way mode existed. Both are accepted so a
% caller written against the old name keeps working; nothing else in the pipeline uses erAware.
wantEr = false;
if     isfield(prm,'useEr')   && ~isempty(prm.useEr),   wantEr = logical(prm.useEr);
elseif isfield(prm,'erAware') && ~isempty(prm.erAware), wantEr = logical(prm.erAware); end
if isempty(modeReq), if wantEr, modeReq = 'penalty'; else, modeReq = 'euclid'; end, end
% An ER mode needs an ER segmentation. Downgrade to Euclidean HERE, once and explicitly, so the
% run provenance can record what actually ran — rather than letting it emerge from an all-empty
% supports array, which strict geodesic would (correctly) read as "forbid everything" and return
% zero tracks for the cell.
mode = modeReq;
if ~wantEr || ~haveEr, mode = 'euclid'; end
useEr = ~strcmp(mode,'euclid');
haveMito = ~isempty(cel.mitoSeg) && isfile(cel.mitoSeg);
% ---- SPT frame -> organelle frame (interleaved acquisition) ----
% An organelle channel imaged at half the SPT rate has half the pages, and the old code indexed the
% two stacks with the SAME t. That did not mean "every other frame has no mask": it meant every
% frame past the end of the shorter stack had none — the whole SECOND HALF of the movie silently
% lost its mito and ER distance, and `supports` past that point stayed empty, which strict geodesic
% reads as "forbid every link". segEvery says how many SPT frames share one organelle frame, so
% SPT frame t reads organelle page ceil(t/segEvery). 'auto' derives it from the page counts.
% NO CLAMPING. An earlier draft of this clamped an out-of-range frame to the LAST organelle page,
% which quietly applies page 4 to frames 5-8 when the map is wrong — inventing a mask rather than
% admitting there is none. segPage returns 0 instead, the frame keeps its NaN distance and its
% empty support exactly as before, and the count of such frames is reported below so the gap is
% visible instead of silent.
% Derived from the FULL frame count, never the truncated one. Reading it off a maxFrames-limited
% run compared (say) 400 frames against 5981 organelle pages, found no whole ratio, and fell back
% to 1 — and that failure is silent: every frame still lands on a page, so there is no NaN and no
% warning, just each frame reading the wrong one. The stack's shape does not depend on how much of
% it you chose to process.
segEvery = segEveryFor(cel, prm, nfrFull);
segPage  = @(t, nseg) (ceil(t/segEvery) <= nseg) * ceil(t/segEvery);

supports = cell(1, nfr); ER = [];
if haveEr
    if ~isempty(prog), prog(0, 'loading ER masks…'); end
    ER = spt_load_seg(cel.erSeg, ceil(nfr/segEvery));       % raw ER masks: used for per-spot ER distance...
    if useEr
        for t = 1:nfr                                      % one support per SPT frame, not per PAGE
            pg = segPage(t, size(ER,3));
            if pg == 0, continue; end                      % no page for this frame: support stays []
            m = ER(:,:,pg);
            if strcmp(mode,'geodesic'), supports{t} = m;                             % geodesic dilates internally
            else,                       supports{t} = imdilate(m, strel('diamond',2)); end % penalty on dilated ER
        end
    end
end
MI = []; if haveMito, if ~isempty(prog), prog(0,'loading mito masks…'); end, MI = spt_load_seg(cel.mitoSeg, ceil(nfr/segEvery)); end

% A raw interleaved two-channel stack detects as a chain of spurious spots along every organelle,
% and nothing else in the run says so. Check once, cheaply, and say it loudly.
% The organelle mask is passed in so the message can NAME the parity to keep — the difference
% between "this stack is interleaved" and "keep the odd pages". It is never used to reject a
% detection: a molecule on a mitochondrion is the measurement, not an artefact.
ILcross = NaN;
try
    segForCheck = ''; if haveMito, segForCheck = cel.mitoSeg; elseif haveEr, segForCheck = cel.erSeg; end
    IL = spt_interleave_check(cel.spt, 25, segForCheck);
    ILcross = IL.crosstalk;
    if isnan(ILcross) && isfinite(IL.enrichOdd) && isfinite(IL.enrichEven)
        ILcross = mean([IL.enrichOdd IL.enrichEven]);   % not interleaved: one population
    end
    if IL.isInterleaved && frameStride < 2
        warning('spt_process_cell:interleavedStack', '%s: %s', base, IL.why);
    end
    % De-interleaving is on — but ONTO WHICH PARITY? Picking the organelle one is not a small
    % mistake: the organelle segmentation is derived from those very pages, so every "particle"
    % would be compared against the mask drawn from its own image and come out perfectly
    % colocalised. The result is self-consistent, looks like a spectacular contact-site signal, and
    % is entirely an artefact. The old guard fell silent the moment a stride was set, whichever
    % parity it selected, which is exactly when this can happen.
    if frameStride == 2 && ~isempty(IL.organelleParity)
        chosen = 'odd'; if mod(frameOffset,2) == 1, chosen = 'even'; end
        if strcmp(chosen, IL.organelleParity)
            warning('spt_process_cell:keptOrganelleHeavyParity', ...
                ['%s: de-interleave kept the %s pages, which carry far more organelle signal ' ...
                 '(%.2fx inside the mask against %.2fx for the %s pages). If those pages are the ' ...
                 'ORGANELLE channel you are tracking mitochondria — switch to the %s pages. If ' ...
                 'they are a particle channel with bleedthrough, do not de-interleave at all: keep ' ...
                 'every frame and gate this parity with bleedFrames instead, or you discard half ' ...
                 'your particle data.'], ...
                base, chosen, max(IL.enrichOdd,IL.enrichEven), min(IL.enrichOdd,IL.enrichEven), ...
                IL.particleParity, IL.particleParity);
        end
    end
catch
end

lastSkelPg = -1; lastSkel = [];        % one skeleton per organelle page, reused across its frames
lastDistPgM = -1; lastDistM = [];      % and one signed-distance field per page, likewise
lastDistPgE = -1; lastDistE = [];

% ---- detect + measure + mito-distance per frame ----
dets = cell(1, nfr);
fr = {}; xs = {}; ys = {}; qs = {}; me = {}; mx = {}; tt = {}; md = {}; er = {}; el = {}; an = {};
[readPage, closeMovie] = spt_tiff_pages(cel.spt);   % one open handle for the whole movie
movieCleanup = onCleanup(closeMovie);
for t = 1:nfr
    raw = double(readPage(pages(t)));
    fopts = dopts;
    if ~gateThisFrame(bleedOn, t)
        fopts.ridgeMax = []; fopts.sizeMax = []; fopts.alignDeg = [];
    elseif ~isempty(dopts.alignDeg) && dopts.alignDeg > 0 && ~isempty(MI)
        % Skeleton of THIS frame's organelle page, cached: with one organelle page per N frames the
        % same skeleton serves N frames, and skeletonising a 256x256 mask per frame would otherwise
        % be most of the per-frame cost.
        pgS = segPage(t, size(MI,3));
        if pgS > 0
            if pgS ~= lastSkelPg, lastSkel = bwmorph(MI(:,:,pgS),'skel',Inf); lastSkelPg = pgS; end
            fopts.skel = lastSkel;
        end
    end
    [xy, shp] = spt_detect(raw, diamUm, px, thr, fopts);  % shp = [sigMaj sigMin elong angle] per spot (motion blur)
    dets{t} = xy;
    n = size(xy,1);
    if n > 0
        m = spt_measure(raw, xy(:,1:2), rPx);
        dmi = nan(n,1); der = nan(n,1);
        pgM = 0; if haveMito && ~isempty(MI), pgM = segPage(t, size(MI,3)); end
        pgE = 0; if haveEr   && ~isempty(ER), pgE = segPage(t, size(ER,3)); end
        % The distance FIELD depends only on the mask, and one organelle page covers segEvery frames
        % (100 of them on a 5,000-frame movie with 50 pages). Computing it per frame ran bwdist twice
        % on the full frame 5,000 times to get 50 distinct answers — 14% of the cell.
        if pgM > 0
            if pgM ~= lastDistPgM, lastDistM = signed_dist_field(MI(:,:,pgM)); lastDistPgM = pgM; end
            dmi = sample_dist(lastDistM, xy(:,1:2), px);
        end
        if pgE > 0
            if pgE ~= lastDistPgE, lastDistE = signed_dist_field(ER(:,:,pgE)); lastDistPgE = pgE; end
            der = sample_dist(lastDistE, xy(:,1:2), px);
        end
        fr{end+1}=repmat(t-1,n,1); xs{end+1}=xy(:,1); ys{end+1}=xy(:,2); qs{end+1}=xy(:,3); %#ok<AGROW>
        me{end+1}=m(:,1); mx{end+1}=m(:,2); tt{end+1}=m(:,3);                              %#ok<AGROW>
        md{end+1}=dmi; er{end+1}=der; el{end+1}=shp(:,3); an{end+1}=shp(:,4);              %#ok<AGROW>
    end
    if ~isempty(prog) && (mod(t,100)==0 || t==nfr), prog(0.85*t/nfr, sprintf('detect %d/%d', t, nfr)); end
end
% Frames the organelle stack does not reach. Zero when segEvery is right; a large number means the
% map is wrong (usually segEvery left at 1 for an interleaved acquisition), and it used to be the
% silent failure this whole mapping exists to remove.
nSegPages = 0;
if ~isempty(MI), nSegPages = size(MI,3); elseif ~isempty(ER), nSegPages = size(ER,3); end
nFramesNoSegPage = 0;
if nSegPages > 0, nFramesNoSegPage = sum(arrayfun(@(t) segPage(t,nSegPages)==0, 1:nfr)); end
if nFramesNoSegPage > 0
    warning('spt_process_cell:segFramesShort', ...
        ['%s: %d of %d SPT frames have no organelle page (segEvery=%d over %d pages). Those ' ...
         'detections get NO mito/ER distance and no link support. If this is an interleaved ' ...
         'acquisition, set segEvery to the frame ratio (2 for an organelle channel at half rate).'], ...
        base, nFramesNoSegPage, nfr, segEvery, nSegPages);
end

clear MI ER
frame=vc_(fr); x=vc_(xs); y=vc_(ys); q=vc_(qs); meanI=vc_(me); maxI=vc_(mx); totI=vc_(tt); mito=vc_(md); erd=vc_(er);
elong=vc_(el); orient=vc_(an);
N = numel(frame); spotId = (0:N-1)';

% ---- track + map track spots back to their detection rows ----
if ~isempty(prog), prog(0.9, 'linking…'); end
[tracks, tinfo] = spt_track(dets, supports, prm.linkUm, prm.gapUm, prm.maxGap, px, useEr, prm.lambda, mode);
map = containers.Map('KeyType','char','ValueType','double');
for i = 1:N, map(kf_(frame(i), x(i), y(i))) = i; end
trackId = nan(N,1); xmlTracks = {};
for tid = 1:numel(tracks)
    tr = tracks{tid}; ids = zeros(0,1);
    for r = 1:size(tr,1)
        k = kf_(tr(r,1)-1, tr(r,2), tr(r,3));    % spt_track frame is 1-based -> 0-based key
        if isKey(map,k), row = map(k); trackId(row) = tid-1; ids(end+1,1) = spotId(row); end %#ok<AGROW>
    end
    xmlTracks{end+1} = struct('tid', tid-1, 'spotIds', ids); %#ok<AGROW>
end
if ~isempty(prog), prog(1, sprintf('%d spots, %d tracks', N, numel(tracks))); end

erPath = ''; if haveEr, erPath = cel.erSeg; end          % kept for the movie/overlay tools
mitoPath = ''; if haveMito, mitoPath = cel.mitoSeg; end
R = struct('key',cel.key,'base',base,'sptPath',cel.spt,'erPath',erPath,'mitoPath',mitoPath, ...
    'thrUsed',thr,'thrSrc',thrSrc, ...     % the cut this cell ACTUALLY detected with, and whence
    'nFrames',nfr,'segEvery',segEvery,'nFramesNoSegPage',nFramesNoSegPage, ...
    'ridgeMax',dopts.ridgeMax,'sizeMax',dopts.sizeMax,'alignDeg',dopts.alignDeg, ...
    'bleedFrames',bleedOn,'thrFrames',thrOn, ...
    'nTracks',numel(tracks), ...
    'imW',info(1).Width,'imH',info(1).Height, ...
    'frame',frame,'x',x,'y',y,'q',q,'mean',meanI,'max',maxI,'total',totI,'mito',mito,'er',erd, ...
    'elong',elong,'orient',orient, ...
    'spotId',spotId,'trackId',trackId,'xmlTracks',{xmlTracks},'dtS',dtFrame,'dtPage',dtPage, ...
    'frameStride',frameStride,'frameOffset',frameOffset,'nPages',nPages, ...
    'chKey',chKey,'t0_s',t0_s,'dtSrcCh',dtSrcCh, ...   % which colour, when it starts, whose dt won
    'mitoIntensityEnrich',ILcross,'pxUm',px, ...
    'haveMito',haveMito,'haveEr',haveEr,'useEr',useEr, ...
    'linkMode',mode,'linkModeReq',modeReq, ...                     % effective vs requested (see downgrade above)
    'nFramesNoErMask',tinfo.nFramesNoErMask,'nDetsOffEr',tinfo.nDetsOffEr);
end

% -------------------------------------------------------------------------
function d = signed_dist_at(mask, xy, px)
% Signed distance (µm) from each 1-based (x,y) to the mask foreground: + outside, − inside, ~0 boundary.
% Kept as the one-shot form; the per-frame loop uses the two halves below so the field is computed
% once per organelle page rather than once per frame.
d = sample_dist(signed_dist_field(mask), xy, px);
end

function sd = signed_dist_field(mask)
% The signed distance field of one mask, in PIXELS. Depends on nothing else, which is what makes it
% cacheable per page.
[H, W] = size(mask); big = max(H, W);
if any(mask(:)) && any(~mask(:)), sd = bwdist(mask) - bwdist(~mask);
elseif any(mask(:)),               sd = -bwdist(mask);
else,                               sd = ones(H, W) * big; end
sd(isinf(sd) & sd > 0) =  big; sd(isinf(sd) & sd < 0) = -big;
end

function d = sample_dist(sd, xy, px)
[H, W] = size(sd);
xi = min(max(round(xy(:,1)),1), W); yi = min(max(round(xy(:,2)),1), H);
d = sd(sub2ind([H W], yi, xi)) * px;
end

% -------------------------------------------------------------------------
function v = vc_(c)
if isempty(c), v = zeros(0,1); else, v = vertcat(c{:}); end
end
function k = kf_(f, xx, yy)
k = sprintf('%d_%.4f_%.4f', f, xx, yy);
end
function tf = gateThisFrame(which, t)
switch which
    case 'odd',  tf = mod(t,2) == 1;      % 1-based: frames 1,3,5…
    case 'even', tf = mod(t,2) == 0;      % frames 2,4,6…
    otherwise,   tf = true;
end
end

function n = segEveryFor(cel, prm, nfr)
%SEGEVERYFOR  How many SPT frames share one organelle page.
% An explicit setting wins. 'auto' (the default) derives it from the page counts: an organelle
% stack with an exact 1/N of the SPT pages is an interleaved acquisition at 1/N the rate, which is
% the only reading under which its frames line up with the movie at all. Anything that is not a
% clean integer ratio falls back to 1 — better to index page-for-page and clip, as before, than to
% invent a mapping from a ratio nobody intended.
v = getf_(cel,'segEvery', getf_(prm,'segEvery','auto'));
if isnumeric(v) && ~isempty(v) && v >= 1, n = round(v); return; end
n = 1;
segs = {};
if isfield(cel,'erSeg')   && ~isempty(cel.erSeg)   && isfile(cel.erSeg),   segs{end+1} = cel.erSeg; end
if isfield(cel,'mitoSeg') && ~isempty(cel.mitoSeg) && isfile(cel.mitoSeg), segs{end+1} = cel.mitoSeg; end
for i = 1:numel(segs)
    try, nseg = numel(imfinfo(segs{i})); catch, continue; end
    if nseg < 1, continue; end
    ratio = nfr / nseg;
    if abs(ratio - round(ratio)) < 1e-9 && round(ratio) >= 1
        n = max(n, round(ratio));                 % the coarsest channel sets the mapping
    end
end
end

function v = getf_(s, f, d)
if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
