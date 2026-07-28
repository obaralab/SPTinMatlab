function [xy, shp] = spt_detect(frame, diamUm, pxUm, thrAbs)
%SPT_DETECT  DoG spot detection on one frame, scaled by spot diameter. Port of ERAware detect().
%
%   xy        = spt_detect(frame, diamUm, pxUm, thrAbs)
%   [xy, shp] = spt_detect(...)   % also return per-spot shape (motion-blur metric)
%
% Runs spt_dog, thresholds, finds 5x5 local maxima (min-distance 2) above threshold away from a
% 2-px border, non-max-suppresses in descending quality, and refines each to a sub-pixel position
% by a 5x5 intensity-weighted centroid on the high-pass image (ERAware's method).
%
% INPUT
%   frame  : one image frame (numeric)
%   diamUm : spot diameter in µm (default 0.5)
%   pxUm   : µm per pixel (default 0.10785)
%   thrAbs : absolute DoG threshold (from the top-percentile tuner); [] -> per-frame MAD (k=4)
% OUTPUT
%   xy  : Nx3 = [x y quality], x/y 1-based sub-pixel; quality = DoG value at the integer peak.
%   shp : Nx4 = [sigMaj_px sigMin_px elong angle_deg] — the intensity second-moment shape of each spot
%         (principal-axis widths in px, elongation = sigMaj/sigMin, major-axis angle 0–180°). A round
%         spot has elong≈1; a particle that MOVES during the exposure smears into a streak, elong>~1.3
%         along the motion — a per-spot motion-blur indicator. Computed only when a 2nd output is asked.
if nargin<2 || isempty(diamUm), diamUm = 0.5; end
if nargin<3 || isempty(pxUm),   pxUm   = 0.10785; end
if nargin<4, thrAbs = []; end

[dog, hp] = spt_dog(frame, diamUm, pxUm);
if isempty(thrAbs)
    md = median(dog(:)); madN = 1.4826*median(abs(dog(:)-md)) + 1e-6;
    thr = md + 4.0*madN;
else
    thr = thrAbs;
end

[H, W] = size(dog);
mx   = imdilate(dog, ones(5,5));                 % 5x5 (min-distance 2) neighbourhood maximum
cand = (dog >= mx) & (dog > thr);                % local maxima above threshold
[py, px] = find(cand);
keep = px > 2 & px <= W-2 & py > 2 & py <= H-2;   % drop peaks within 2 px of the border
px = px(keep); py = py(keep);
if isempty(px), xy = zeros(0,3); if nargout>1, shp = zeros(0,4); end, return; end

q = dog(sub2ind([H W], py, px));
[q, ord] = sort(q, 'descend'); px = px(ord); py = py(ord);   % NMS: accept strongest first
n = 0; aX = zeros(numel(px),1); aY = aX; aQ = aX;
for i = 1:numel(px)
    if n == 0 || all(max(abs(aX(1:n)-px(i)), abs(aY(1:n)-py(i))) > 2)   % >2 px apart (Chebyshev)
        n = n+1; aX(n) = px(i); aY(n) = py(i); aQ(n) = q(i);
    end
end

xy = zeros(n, 3);
wantShape = nargout > 1; if wantShape, shp = zeros(n, 4); end
for i = 1:n
    x0 = aX(i); y0 = aY(i);
    rx = max(x0-2,1):min(x0+2,W); ry = max(y0-2,1):min(y0+2,H);
    win = hp(ry, rx); win(win < 0) = 0; s = sum(win(:));
    if s > 0
        [gx, gy] = meshgrid(rx, ry);
        cx = sum(gx(:).*win(:))/s; cy = sum(gy(:).*win(:))/s;
    else
        cx = x0; cy = y0;
    end
    xy(i,:) = [cx cy aQ(i)];
    if wantShape
        % intensity second-moment shape on a wider 7x7 window about the sub-pixel centre (the centroid
        % window stays 5x5 for ERAware parity). Elongation flags motion blur; orientation gives its axis.
        rxs = max(x0-3,1):min(x0+3,W); rys = max(y0-3,1):min(y0+3,H);
        ws = hp(rys, rxs); ws(ws < 0) = 0; ss = sum(ws(:));
        if ss > 0
            [gxs, gys] = meshgrid(rxs, rys);
            dx = gxs(:)-cx; dy = gys(:)-cy; w = ws(:);
            Mxx = sum(w.*dx.^2)/ss; Myy = sum(w.*dy.^2)/ss; Mxy = sum(w.*dx.*dy)/ss;
            [V, D] = eig([Mxx Mxy; Mxy Myy]); ev = diag(D);
            [ev, ix] = sort(ev, 'descend'); vmaj = V(:, ix(1));
            sigMaj = sqrt(max(ev(1),0)); sigMin = sqrt(max(ev(2),0));
            elong = sigMaj / max(sigMin, 1e-6);
            ang = mod(atan2d(vmaj(2), vmaj(1)), 180);
        else
            sigMaj = 0; sigMin = 0; elong = 1; ang = 0;
        end
        shp(i,:) = [sigMaj sigMin elong ang];
    end
end
end
