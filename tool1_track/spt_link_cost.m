function C = spt_link_cost(P, Q, R, erAware, lambda, sup)
%SPT_LINK_COST  Frame-to-frame link cost matrix (np x nq). Euclidean distance, Inf beyond R.
%   When erAware, multiply by (1 + lambda·off) where off = spt_seg_off_fraction (straight-line off-ER
%   fraction) — the 'penalty' linking mode.
dx = P(:,1) - Q(:,1).'; dy = P(:,2) - Q(:,2).';
C  = hypot(dx, dy);
C(C > R) = Inf;
if erAware && ~isempty(sup)
    [ii, jj] = find(isfinite(C));
    for k = 1:numel(ii)
        off = spt_seg_off_fraction(P(ii(k),1:2), Q(jj(k),1:2), sup);
        C(ii(k),jj(k)) = C(ii(k),jj(k)) * (1 + lambda*off);
    end
end
end
