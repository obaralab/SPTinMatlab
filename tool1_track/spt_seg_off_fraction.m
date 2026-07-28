function off = spt_seg_off_fraction(p, q, sup)
%SPT_SEG_OFF_FRACTION  Fraction of the p->q segment's MIDDLE (20-80%) lying OFF the ER support mask.
%   Endpoints (the spots) are excluded, so it measures only whether the PATH between two spots crosses
%   a gap in the ER. off in [0,1]. Used by the ER-penalty link cost and the gap-close veto.
d = hypot(p(1)-q(1), p(2)-q(2));
n = max(ceil(d)+1, 3);
tt = linspace(0, 1, n);
[H, W] = size(sup);
xs = min(max(round(p(1) + (q(1)-p(1)).*tt), 1), W);
ys = min(max(round(p(2) + (q(2)-p(2)).*tt), 1), H);
onv = sup(sub2ind([H W], ys, xs));
lo = max(1, floor(0.2*n)+1); hi = min(n, floor(0.8*n));
if hi < lo, off = 0; return; end
off = mean(~onv(lo:hi));
end
