function fp = cs_window_footprint(Dens, pickPx, SF, opts)
%CS_WINDOW_FOOTPRINT  Automatic contact-site footprint around a pick (replaces the mouse refiner).
%
%   fp = cs_window_footprint(Dens, pickPx, SF, opts)
%
% Given a WINDOW's smoothed density (as the picker displayed) and a picked centre, derive a
% shape-aware footprint polygon deterministically and headlessly — the interactive freehand
% refiner (CSrefiner*/refineCSboundary) can't run without a display or at per-window scale.
%
% METHOD ('halfmax', default): take the connected component of (Dens >= frac*localPeak) that
% contains the pick, where localPeak is the max density in a maxRadius disk about the pick;
% clip that component to the disk; trace its outer ring. Falls back to a fixed box when the
% blob is empty, too small, or touches the FOV border (a truncated, unreliable footprint).
%
% INPUT
%   Dens    : [H x W] smoothed density (row=y, col=x) from cs_window_density.
%   pickPx  : [xCol yRow] pick in density pixels (sub-pixel ok).
%   SF      : microns per density pixel.
%   opts    : .mode ('halfmax'|'box'|'disk', default 'halfmax'), .frac (0.5),
%             .maxRadiusUm (0.6), .boxHalfWidthUm (0.5), .minBins (2), .nDiskPts (48).
%
% OUTPUT (struct fp)
%   .refboundary : [K x 2] polygon (um) RELATIVE to the pick centre (col=x, row=y mapping).
%   .centerUm    : [x y] pick centre in um (= pickPx*SF).
%   .areaUm2     : polyarea(refboundary).
%   .mode        : the mode actually used ('halfmax'|'box'|'disk' — reflects any fallback).
%   .EllipseFit  : struct(CentroidUm[abs x y], Orientation_deg, MajorAxisUm, MinorAxisUm) or [].
%   .bw          : logical footprint mask on the grid (display/debug).

if nargin < 4 || ~isstruct(opts), opts = struct(); end
mode  = lower(getf(opts,'mode','halfmax'));
frac  = getf(opts,'frac',0.5);
maxRu = getf(opts,'maxRadiusUm',0.6);
boxHu = getf(opts,'boxHalfWidthUm',0.5);
minB  = getf(opts,'minBins',2);
nDisk = getf(opts,'nDiskPts',48);

[H,W]   = size(Dens);
centerUm = pickPx(:)'*SF;              % [x y] um
maxR_px  = max(2, maxRu/SF);
pc = min(max(round(pickPx(1)),1),W);   % pick col (x)
pr = min(max(round(pickPx(2)),1),H);   % pick row (y)

fp = struct('refboundary',[],'centerUm',centerUm,'areaUm2',NaN, ...
            'mode',mode,'EllipseFit',[],'bw',[]);

% Disk of radius maxR_px about the pick (the physical size cap).
[XX,YY] = meshgrid(1:W,1:H);
disk = (XX-pickPx(1)).^2 + (YY-pickPx(2)).^2 <= maxR_px^2;

switch mode
    case 'disk'
        fp = boxOrDisk(fp, centerUm, maxRu, nDisk, 'disk');
        fp.bw = disk; return;
    case 'box'
        fp = boxOrDisk(fp, centerUm, boxHu, [], 'box');
        fp.bw = boxMask(H,W,pickPx,boxHu/SF); return;
end

% ---- halfmax ----
dloc = Dens; dloc(~disk) = -Inf;
localPeak = max(dloc(:));
if ~isfinite(localPeak) || localPeak <= 0
    fp = boxOrDisk(fp, centerUm, boxHu, [], 'box');  fp.bw = boxMask(H,W,pickPx,boxHu/SF); return;
end
bwAll = Dens >= frac*localPeak;

% Connected component containing the pick (snap to nearest above-thr pixel in the disk if needed).
if ~bwAll(pr,pc)
    [rr,cc] = find(bwAll & disk);
    if isempty(rr)
        fp = boxOrDisk(fp, centerUm, boxHu, [], 'box');  fp.bw = boxMask(H,W,pickPx,boxHu/SF); return;
    end
    [~,mi] = min((rr-pickPx(2)).^2 + (cc-pickPx(1)).^2);  pr = rr(mi); pc = cc(mi);
end
bw = bwselect(bwAll, pc, pr, 8) & disk;                 % component, clipped to the size cap

% Reject degenerate or FOV-edge-truncated blobs -> box fallback.
touchesBorder = any(bw(1,:)) || any(bw(end,:)) || any(bw(:,1)) || any(bw(:,end));
if nnz(bw) < minB || touchesBorder
    fp = boxOrDisk(fp, centerUm, boxHu, [], 'box');  fp.bw = boxMask(H,W,pickPx,boxHu/SF); return;
end

B = bwboundaries(bw,'noholes');
if isempty(B)
    fp = boxOrDisk(fp, centerUm, boxHu, [], 'box');  fp.bw = boxMask(H,W,pickPx,boxHu/SF); return;
end
[~,bi] = max(cellfun(@(b) size(b,1), B));
ring = B{bi};                                            % [row(y) col(x)]
% px -> um RELATIVE to pick centre; map to [x y] = [col-pickX, row-pickY]*SF
refb = [(ring(:,2)-pickPx(1))*SF, (ring(:,1)-pickPx(2))*SF];
if size(refb,1) < 3
    fp = boxOrDisk(fp, centerUm, boxHu, [], 'box');  fp.bw = boxMask(H,W,pickPx,boxHu/SF); return;
end
if ~isequal(refb(1,:),refb(end,:)), refb(end+1,:) = refb(1,:); end   % close ring

fp.refboundary = refb;
fp.areaUm2     = polyarea(refb(:,1),refb(:,2));
fp.mode        = 'halfmax';
fp.bw          = bw;

% Ellipse descriptors (scaled to um; centroid to absolute um).
try
    rp = regionprops(bw,'Centroid','Orientation','MajorAxisLength','MinorAxisLength');
    if ~isempty(rp)
        [~,li] = max([rp.MajorAxisLength]);
        fp.EllipseFit = struct('CentroidUm', rp(li).Centroid*SF, ...
            'Orientation_deg', rp(li).Orientation, ...
            'MajorAxisUm', rp(li).MajorAxisLength*SF, ...
            'MinorAxisUm', rp(li).MinorAxisLength*SF);
    end
catch
end
end

% ------------------------------------------------------------------------------------------------
function fp = boxOrDisk(fp, centerUm, halfUm, nPts, tag)
% Build a fixed box (nPts empty) or disk (nPts given) footprint, RELATIVE to centre, in um.
if strcmp(tag,'disk')
    th = linspace(0,2*pi,nPts+1)';
    refb = [halfUm*cos(th), halfUm*sin(th)];
else
    refb = halfUm*[-1 -1; 1 -1; 1 1; -1 1; -1 -1];
end
fp.refboundary = refb;
fp.centerUm    = centerUm;
fp.areaUm2     = polyarea(refb(:,1),refb(:,2));
fp.mode        = tag;
fp.EllipseFit  = [];
end

function bw = boxMask(H,W,pickPx,halfPx)
[XX,YY] = meshgrid(1:W,1:H);
bw = abs(XX-pickPx(1))<=halfPx & abs(YY-pickPx(2))<=halfPx;
end

function v = getf(s,f,d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
