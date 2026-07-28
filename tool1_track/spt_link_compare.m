function cmp = spt_link_compare(cel, prm, varargin)
%SPT_LINK_COMPARE  Compare the three frame-to-frame linking modes on one cell and find where the
%   geodesic mode makes a BETTER choice than plain Euclidean / straight-line penalty.
%
%   cmp = spt_link_compare(cel, prm)
%   cmp = spt_link_compare(cel, prm, 'Frames',[f0 f1], 'Plot',true, 'MaxInstances',12)
%
% For each frame it detects spots (same DoG as tracking), then for frame t->t+1 solves the link
% assignment (matchpairs) under each mode: 'euclid' (no ER), 'penalty' (straight-line off-ER fraction)
% and 'geodesic' (shortest path THROUGH the ER). Whenever geodesic links a source to a DIFFERENT
% partner than Euclidean, it records the case; a "geodesic-excels" case is one where the Euclidean
% partner's link crosses the ER (off-ER > 0.5) but the geodesic partner stays on it.
%
% cel : matched cell {spt, erSeg, ...} + optional diamUm/thrAbs/keepPct (from the Detect tab).
% prm : struct with linkUm, lambda, pxUm (gapUm/maxGap unused here — this compares linking only).
%
% Returns cmp with:
%   .summary   struct: nFrames, nLinks, nDiff (geodesic≠euclid), nExcel (geodesic-excels), pctExcel
%   .instances table : one row per geodesic≠euclid link, sorted best-first
%                      (frame, src x/y, euclid partner x/y + offER, geodesic partner x/y + offER, dEuclid, dGeo)
%   .figure    handle to the instance panel (if Plot)

ip = inputParser;
ip.addParameter('Frames', [], @(x) isempty(x) || (isnumeric(x)&&numel(x)==2));
ip.addParameter('Plot', true, @islogical);
ip.addParameter('MaxInstances', 12, @isnumeric);
ip.addParameter('ProgressFcn', []);
ip.parse(varargin{:});
o = ip.Results;

px = prm.pxUm; lambda = getf_(prm,'lambda',3); diamUm = getf_(cel,'diamUm',0.5);
R = prm.linkUm/px; rPx = (diamUm/px)/2; %#ok<NASGU>
d0e = R + 1;                 % euclid no-link cost
d0  = R*(1+lambda) + 1;      % penalty/geodesic no-link cost
assert(~isempty(cel.erSeg) && isfile(cel.erSeg), 'spt_link_compare: needs ER segmentation for this cell.');

info = imfinfo(cel.spt); nfr = numel(info);
if isempty(o.Frames), fr = [1 min(nfr, 800)]; else, fr = [max(1,o.Frames(1)) min(nfr,o.Frames(2))]; end

% ---- per-file detection threshold (same rule as spt_process_cell) ----
thr = [];
if isfield(cel,'thrAbs') && ~isempty(cel.thrAbs), thr = cel.thrAbs; end
if isempty(thr)
    q = spt_pool_quality(cel.spt, diamUm, px, 40);
    if ~isempty(q), thr = prctile(q, 100 - getf_(cel,'keepPct',10)); end
end

% ---- detect + ER over the frame range ----
nF = fr(2)-fr(1)+1;
dets = cell(1,nF); ERs = cell(1,nF);
for k = 1:nF
    t = fr(1)+k-1;
    dets{k} = spt_detect(double(imread(cel.spt,t)), diamUm, px, thr);
    ERs{k}  = spt_load_seg_frame(cel.erSeg, t);
    if ~isempty(o.ProgressFcn) && (mod(k,50)==0 || k==nF), o.ProgressFcn(0.5*k/nF, sprintf('detect %d/%d',k,nF)); end
end

% ---- per-frame linking under the 3 modes; collect disagreements ----
rows = {};   % each: [frame sx sy ex ey eoff gx gy goff dE dG]
nLinks = 0;
for k = 1:nF-1
    P = dets{k}; Q = dets{k+1};
    if isempty(P) || isempty(Q), continue; end
    supRaw = ERs{k}; supDil = imdilate(supRaw, strel('diamond',2));
    Ce = spt_link_cost(P, Q, R, false, lambda, []);       jE = assign_partner(Ce, d0e, size(P,1));
    Cg = spt_link_cost_geo(P, Q, R, supRaw, lambda, ERs{k+1});   jG = assign_partner(Cg, d0, size(P,1));   % target on ITS own frame
    nLinks = nLinks + sum(jE>0 | jG>0);
    for i = 1:size(P,1)
        if jG(i)==0 || jE(i)==0 || jG(i)==jE(i), continue; end   % geodesic disagrees with euclid
        qE = Q(jE(i),1:2); qG = Q(jG(i),1:2); p = P(i,1:2);
        eoff = spt_seg_off_fraction(p, qE, supRaw);
        goff = spt_seg_off_fraction(p, qG, supRaw);
        rows{end+1} = [fr(1)+k-1, p, qE, eoff, qG, goff, norm(p-qE), norm(p-qG)]; %#ok<AGROW>
    end
    if ~isempty(o.ProgressFcn) && (mod(k,50)==0 || k==nF-1), o.ProgressFcn(0.5+0.5*k/(nF-1), sprintf('link %d/%d',k,nF-1)); end
end

% ---- assemble + rank (best-first: euclid crosses ER, geodesic doesn't) ----
if isempty(rows)
    T = cell2table(cell(0,11), 'VariableNames', ...
        {'frame','srcX','srcY','euX','euY','euOff','geoX','geoY','geoOff','dEuclid','dGeo'});
else
    M = cell2mat(rows.');
    T = array2table(M, 'VariableNames', ...
        {'frame','srcX','srcY','euX','euY','euOff','geoX','geoY','geoOff','dEuclid','dGeo'});
    [~,ord] = sort(T.euOff - T.geoOff, 'descend'); T = T(ord,:);   % biggest on-ER improvement first
end
isExcel = ~isempty(rows) && any(T.euOff>0.5 & T.geoOff<0.5);
nExcel = 0; if ~isempty(rows), nExcel = sum(T.euOff>0.5 & T.geoOff<0.5); end

cmp.summary = struct('framesScanned', nF, 'nLinks', nLinks, 'nDiff', height(T), ...
    'nExcel', nExcel, 'pctExcel', 100*nExcel/max(nLinks,1), 'lambda', lambda, 'linkUm', prm.linkUm);
cmp.instances = T;
cmp.figure = [];

fprintf(['spt_link_compare: %d frames, %d links | geodesic≠euclid: %d | geodesic-excels ' ...
    '(euclid crosses ER, geodesic stays on): %d (%.2f%% of links)\n'], ...
    nF, nLinks, height(T), nExcel, cmp.summary.pctExcel);

if o.Plot && height(T)>0
    cmp.figure = plot_instances(T, dets, ERs, fr, min(o.MaxInstances, height(T)), R);
end
end

% =========================================================================
function pr = assign_partner(C, d0, np)
% partner index in Q for each source row (0 if unlinked)
pr = zeros(np,1);
Mm = matchpairs(C, d0);
for r = 1:size(Mm,1)
    i = Mm(r,1); j = Mm(r,2);
    if i>=1 && i<=np && isfinite(C(i,j)), pr(i) = j; end
end
end

% =========================================================================
function m = spt_load_seg_frame(segPath, t)
% One frame of a seg stack as a logical fg mask. The foreground label comes from the whole stack
% (spt_seg_fg_label), not this page: an all-background page would otherwise come back ALL TRUE.
m = (imread(segPath, t) == spt_seg_fg_label(segPath));
end

% =========================================================================
function h = plot_instances(T, dets, ERs, fr, K, R)
h = figure('Name','Geodesic vs Euclidean linking — where geodesic excels','Color','w');
nc = ceil(sqrt(K)); nr = ceil(K/nc);
tl = tiledlayout(h, nr, nc, 'Padding','compact','TileSpacing','compact');
title(tl, 'source (black) · Euclidean partner (red, crosses ER) · geodesic partner (green, on ER)');
rad = ceil(R)+4;
for m = 1:K
    r = T(m,:); k = r.frame - fr(1) + 1;
    sup = ERs{k};
    p=[r.srcX r.srcY]; qE=[r.euX r.euY]; qG=[r.geoX r.geoY];
    cx=round(p(1)); cy=round(p(2)); [H,W]=size(sup);
    x0=max(1,cx-rad); x1=min(W,cx+rad); y0=max(1,cy-rad); y1=min(H,cy+rad);
    ax = nexttile(tl); imshow(sup(y0:y1,x0:x1), 'Parent', ax, 'XData',[x0 x1],'YData',[y0 y1]);
    colormap(ax,[1 1 1; 0.75 0.9 0.75]); hold(ax,'on');   % ER = light green, gap = white
    plot(ax,[p(1) qE(1)],[p(2) qE(2)],'-','Color',[0.85 0.1 0.1],'LineWidth',1.5);
    plot(ax,[p(1) qG(1)],[p(2) qG(2)],'-','Color',[0.1 0.6 0.2],'LineWidth',1.5);
    plot(ax,p(1),p(2),'ko','MarkerFaceColor','k','MarkerSize',5);
    plot(ax,qE(1),qE(2),'x','Color',[0.85 0.1 0.1],'MarkerSize',9,'LineWidth',1.5);
    plot(ax,qG(1),qG(2),'+','Color',[0.1 0.6 0.2],'MarkerSize',9,'LineWidth',1.5);
    hold(ax,'off'); axis(ax,'image');
    title(ax, sprintf('f%d  euOff=%.2f geoOff=%.2f', r.frame, r.euOff, r.geoOff), 'FontSize',8);
end
end

% =========================================================================
function v = getf_(s, f, d)
if isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
