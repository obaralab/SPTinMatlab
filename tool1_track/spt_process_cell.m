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
info = imfinfo(cel.spt); nfr = numel(info);
if isfield(prm,'maxFrames') && ~isempty(prm.maxFrames), nfr = min(nfr, prm.maxFrames); end
prog = []; if isfield(prm,'progressFcn'), prog = prm.progressFcn; end

% ---- per-file absolute threshold (stored from the Detect tab, else pool + percentile) ----
thr = [];
if isfield(cel,'thrAbs') && ~isempty(cel.thrAbs), thr = cel.thrAbs; end
if isempty(thr)
    q = spt_pool_quality(cel.spt, diamUm, px, 40);
    if ~isempty(q), thr = prctile(q, 100 - getf_(cel,'keepPct',10)); end
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
supports = cell(1, nfr); ER = [];
if haveEr
    if ~isempty(prog), prog(0, 'loading ER masks…'); end
    ER = spt_load_seg(cel.erSeg, nfr);                     % raw ER masks: used for per-spot ER distance...
    if useEr
        for t = 1:size(ER,3)
            if strcmp(mode,'geodesic'), supports{t} = ER(:,:,t);                             % geodesic dilates internally
            else,                       supports{t} = imdilate(ER(:,:,t), strel('diamond',2)); end % penalty on dilated ER
        end
    end
end
MI = []; if haveMito, if ~isempty(prog), prog(0,'loading mito masks…'); end, MI = spt_load_seg(cel.mitoSeg, nfr); end

% ---- detect + measure + mito-distance per frame ----
dets = cell(1, nfr);
fr = {}; xs = {}; ys = {}; qs = {}; me = {}; mx = {}; tt = {}; md = {}; er = {}; el = {}; an = {};
for t = 1:nfr
    raw = double(imread(cel.spt, t));
    [xy, shp] = spt_detect(raw, diamUm, px, thr);    % shp = [sigMaj sigMin elong angle] per spot (motion blur)
    dets{t} = xy;
    n = size(xy,1);
    if n > 0
        m = spt_measure(raw, xy(:,1:2), rPx);
        dmi = nan(n,1); der = nan(n,1);
        if haveMito && t <= size(MI,3), dmi = signed_dist_at(MI(:,:,t), xy(:,1:2), px); end
        if haveEr   && t <= size(ER,3), der = signed_dist_at(ER(:,:,t), xy(:,1:2), px); end
        fr{end+1}=repmat(t-1,n,1); xs{end+1}=xy(:,1); ys{end+1}=xy(:,2); qs{end+1}=xy(:,3); %#ok<AGROW>
        me{end+1}=m(:,1); mx{end+1}=m(:,2); tt{end+1}=m(:,3);                              %#ok<AGROW>
        md{end+1}=dmi; er{end+1}=der; el{end+1}=shp(:,3); an{end+1}=shp(:,4);              %#ok<AGROW>
    end
    if ~isempty(prog) && (mod(t,100)==0 || t==nfr), prog(0.85*t/nfr, sprintf('detect %d/%d', t, nfr)); end
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
    'nFrames',nfr,'nTracks',numel(tracks), ...
    'imW',info(1).Width,'imH',info(1).Height, ...
    'frame',frame,'x',x,'y',y,'q',q,'mean',meanI,'max',maxI,'total',totI,'mito',mito,'er',erd, ...
    'elong',elong,'orient',orient, ...
    'spotId',spotId,'trackId',trackId,'xmlTracks',{xmlTracks},'dtS',prm.dtS,'pxUm',px, ...
    'haveMito',haveMito,'haveEr',haveEr,'useEr',useEr, ...
    'linkMode',mode,'linkModeReq',modeReq, ...                     % effective vs requested (see downgrade above)
    'nFramesNoErMask',tinfo.nFramesNoErMask,'nDetsOffEr',tinfo.nDetsOffEr);
end

% -------------------------------------------------------------------------
function d = signed_dist_at(mask, xy, px)
% Signed distance (µm) from each 1-based (x,y) to the mask foreground: + outside, − inside, ~0 boundary.
[H, W] = size(mask); big = max(H, W);
if any(mask(:)) && any(~mask(:)), sd = bwdist(mask) - bwdist(~mask);
elseif any(mask(:)),               sd = -bwdist(mask);
else,                               sd = ones(H, W) * big; end
sd(isinf(sd) & sd > 0) =  big; sd(isinf(sd) & sd < 0) = -big;
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
function v = getf_(s, f, d)
if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
