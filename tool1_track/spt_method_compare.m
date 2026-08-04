function cmp = spt_method_compare(cel, prm, varargin)
%SPT_METHOD_COMPARE  Compare the THREE linking methods (Euclidean · ER-penalty · ER-geodesic) on one
%   cell: how many TRACKS each produces, and exactly which frame-to-frame links they disagree on.
%
%   cmp = spt_method_compare(cel, prm)
%   cmp = spt_method_compare(cel, prm, 'Frames',[f0 f1], 'MaxInstances',9, 'ProgressFcn',@(f,m)...)
%
% Over a frame window it (1) detects spots once (same DoG as tracking), (2) runs FULL tracking
% (LAP + gap-close) under each of the three modes to count tracks, and (3) re-solves each frame->frame
% assignment under all three modes and records every source spot whose partner differs between methods
% — the concrete places where the choice of method changes a track. `cel` needs ER segmentation.
%
% cel : matched cell {spt, erSeg, ...} (+ optional diamUm/thrAbs/keepPct from the Detect tab).
% prm : struct with linkUm, gapUm, maxGap, lambda, pxUm (the tracking params).
%
% Returns cmp with:
%   .counts    struct: euclid/penalty/geodesic -> #tracks, medLen, nLinkedSpots (full gap-closed tracking)
%   .tracks    struct: euclid/penalty/geodesic -> the 1xM track cells (each Kx4 [frame x y quality])
%   .summary   struct: framesScanned, nLinks, nDiff (any method differs), nExcelGeo/nExcelPen
%              (that method keeps the link on-ER where Euclidean crosses a gap), lambda, linkUm
%   .instances table: one row per disagreeing source link, ranked by biggest on-ER improvement over
%              Euclidean (frame, src x/y, and each method's partner x/y + off-ER fraction + distance)
%   .dets/.ERs/.fr : per-frame detections, ER masks, and [f0 f1] — for the app to draw example regions.

ip = inputParser;
ip.addParameter('Frames', [], @(x) isempty(x) || (isnumeric(x)&&numel(x)==2));
ip.addParameter('MaxInstances', 9, @isnumeric);
ip.addParameter('ProgressFcn', []);
ip.parse(varargin{:});
o = ip.Results;
prog = @(f,m) progCall_(o.ProgressFcn, f, m);   % callback may return nothing — never use && here

px = prm.pxUm; lambda = getf_(prm,'lambda',3); diamUm = getf_(cel,'diamUm',0.5);
R = prm.linkUm/px;
d0e = R + 1;                  % euclid cost-of-no-link
d0  = R*(1+lambda) + 1;       % penalty/geodesic cost-of-no-link
assert(isfield(cel,'erSeg') && ~isempty(cel.erSeg) && isfile(cel.erSeg), ...
    'spt_method_compare: this cell has no ER segmentation — nothing to compare (Euclidean == ER modes).');

info = imfinfo(cel.spt); nfr = numel(info);
if isempty(o.Frames), fr = [1 min(nfr, 500)]; else, fr = [max(1,round(o.Frames(1))) min(nfr,round(o.Frames(2)))]; end
nF = fr(2)-fr(1)+1;

% ---- per-file detection threshold (same rule as spt_process_cell) ----
thr = [];
if isfield(cel,'thrAbs') && ~isempty(cel.thrAbs), thr = cel.thrAbs; end
if isempty(thr)
    q = spt_pool_quality(cel.spt, diamUm, px, 40);
    if ~isempty(q), thr = prctile(q, 100 - getf_(cel,'keepPct',6)); end
end

% ---- detect + ER over the frame range (once) ----
dets = cell(1,nF); ERs = cell(1,nF);
for k = 1:nF
    t = fr(1)+k-1;
    dets{k} = spt_detect(double(imread(cel.spt,t)), diamUm, px, thr);
    ERs{k}  = seg_frame_(cel.erSeg, t);
    if mod(k,40)==0 || k==nF, prog(0.45*k/nF, sprintf('detect %d/%d', k, nF)); end
end

% ---- FULL tracking under each mode (LAP + gap-close) -> track counts ----
supAll = ERs;
prog(0.5, 'tracking · Euclidean');   trkE = spt_track(dets, supAll, prm.linkUm, prm.gapUm, prm.maxGap, px, false, lambda, 'euclid');
prog(0.6, 'tracking · ER-penalty');  trkP = spt_track(dets, supAll, prm.linkUm, prm.gapUm, prm.maxGap, px, true,  lambda, 'penalty');
prog(0.7, 'tracking · ER-geodesic'); [trkG, infG] = spt_track(dets, supAll, prm.linkUm, prm.gapUm, prm.maxGap, px, true,  lambda, 'geodesic');
gStats = trkStats_(trkG);
gStats.nDetsOffEr      = infG.nDetsOffEr;        % detections the strict pre-filter excluded (exact)
gStats.nFramesNoErMask = infG.nFramesNoErMask;
gStats.nDets           = infG.nDets;             % all detections over the compared frames
cmp.counts = struct('euclid',   trkStats_(trkE), ...
                    'penalty',  trkStats_(trkP), ...
                    'geodesic', gStats);
cmp.tracks = struct('euclid',{trkE}, 'penalty',{trkP}, 'geodesic',{trkG});

% ---- per-frame 3-way link disagreements ----
rows = {}; nLinks = 0;
for k = 1:nF-1
    P = dets{k}; Q = dets{k+1};
    if isempty(P) || isempty(Q), continue; end
    sup = ERs{k};
    jE = partner_(spt_link_cost(P, Q, R, false, lambda, []),   d0e, size(P,1));
    jP = partner_(spt_link_cost(P, Q, R, true,  lambda, sup),  d0,  size(P,1));
    jG = partner_(spt_link_cost_geo(P, Q, R, sup, lambda, ERs{k+1}), d0, size(P,1));   % target judged on ITS own frame
    nLinks = nLinks + sum(jE>0 | jP>0 | jG>0);
    for i = 1:size(P,1)
        parts = [jE(i) jP(i) jG(i)];
        if numel(unique(parts(parts>0)))<=1 && all(parts>0), continue; end   % all agree -> skip
        if all(parts==0), continue; end
        p = P(i,1:2);
        [ex,ey,eoff,de] = partnerXY_(jE(i), Q, p, sup);
        [pxx,pyy,poff,dp] = partnerXY_(jP(i), Q, p, sup);
        [gx,gy,goff,dg] = partnerXY_(jG(i), Q, p, sup);
        rows{end+1} = [fr(1)+k-1, p, ex,ey,eoff,de, pxx,pyy,poff,dp, gx,gy,goff,dg]; %#ok<AGROW>
    end
    if mod(k,40)==0 || k==nF-1, prog(0.75+0.25*k/max(nF-1,1), sprintf('link %d/%d', k, nF-1)); end
end

vn = {'frame','srcX','srcY','euX','euY','euOff','euD','peX','peY','peOff','peD','geX','geY','geOff','geD'};
if isempty(rows)
    T = cell2table(cell(0,numel(vn)), 'VariableNames', vn);
else
    T = array2table(cell2mat(rows.'), 'VariableNames', vn);
    % rank best-first by the biggest on-ER improvement of an ER link mode over Euclidean; NaN
    % (a method left the spot unlinked — birth/death difference) sinks below the on-ER-crossing cases.
    improve = T.euOff - min(T.peOff, T.geOff);
    improve(isnan(improve)) = -Inf;
    [~,ord] = sort(improve, 'descend'); T = T(ord,:);
end
% "excels" = Euclidean link crosses an ER gap (off>0.5) but that ER link mode keeps it on-ER (off<0.5)
nExcelGeo = 0; nExcelPen = 0;
if ~isempty(rows)
    nExcelGeo = sum(T.euOff>0.5 & T.geOff<0.5 & (T.geX~=T.euX | T.geY~=T.euY));
    nExcelPen = sum(T.euOff>0.5 & T.peOff<0.5 & (T.peX~=T.euX | T.peY~=T.euY));
end
cmp.summary = struct('framesScanned',nF, 'nLinks',nLinks, 'nDiff',height(T), ...
    'nExcelGeo',nExcelGeo, 'nExcelPen',nExcelPen, 'lambda',lambda, 'linkUm',prm.linkUm, 'frames',fr);
cmp.instances = T;
cmp.dets = dets; cmp.ERs = ERs; cmp.fr = fr;

fprintf(['spt_method_compare [%d–%d]: tracks  euclid=%d  penalty=%d  geodesic=%d | links=%d · ' ...
    'method-disagreements=%d · geodesic-excels=%d · penalty-excels=%d\n'], fr(1), fr(2), ...
    cmp.counts.euclid.nTracks, cmp.counts.penalty.nTracks, cmp.counts.geodesic.nTracks, ...
    nLinks, height(T), nExcelGeo, nExcelPen);
end

% =========================================================================
function progCall_(fn, f, m)
if ~isempty(fn), fn(f, m); end   % call as a statement — the callback need not return anything
end

function s = trkStats_(trk)
n = numel(trk);
if n==0, s = struct('nTracks',0,'medLen',0,'nLinkedSpots',0); return; end
lens = cellfun(@(t) size(t,1), trk);
s = struct('nTracks',n, 'medLen',median(lens), 'nLinkedSpots',sum(lens));
end

function pr = partner_(C, d0, np)
pr = zeros(np,1); Mm = matchpairs(C, d0);
for r = 1:size(Mm,1)
    i = Mm(r,1); j = Mm(r,2);
    if i>=1 && i<=np && isfinite(C(i,j)), pr(i) = j; end
end
end

function [x,y,off,d] = partnerXY_(j, Q, p, sup)
if j<=0, x=NaN; y=NaN; off=NaN; d=NaN; return; end
x = Q(j,1); y = Q(j,2); off = spt_seg_off_fraction(p, [x y], sup); d = hypot(p(1)-x, p(2)-y);
end

function m = seg_frame_(segPath, t)
% Stack-wide foreground label (see spt_seg_fg_label) — deriving it per frame would turn an
% all-background page into an ALL-TRUE mask, i.e. "the whole field is ER", so the comparison would
% fail OPEN for exactly the frames where tracking fails closed.
m = (imread(segPath, t) == spt_seg_fg_label(segPath));
end

function v = getf_(s, f, d)
if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
