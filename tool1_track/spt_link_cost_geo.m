function C = spt_link_cost_geo(P, Q, R, supP, lambda, supQ)
%SPT_LINK_COST_GEO  Geodesic-through-ER link cost matrix (np x nq) — the 'geodesic' linking mode.
%
%   C = spt_link_cost_geo(P, Q, R, supP, lambda)          % supQ defaults to supP
%   C = spt_link_cost_geo(P, Q, R, supP, lambda, supQ)
%
% STRICT (hard) ER constraint. A link p(frame t) -> q(frame t+1) is allowed ONLY when all three
% hold, and its cost is then the along-ER path length:
%   1. p sits on frame t's ER support     (spt_er_support / spt_on_er — 1 px registration slack)
%   2. q sits on frame t+1's ER support   (its OWN frame — the ER moves between frames)
%   3. q is reachable from p along frame t's ER within R (bwdistgeodesic on a local crop)
% Anything else — off-ER source, off-ER target, unreachable, or an ER detour longer than R — is
% FORBIDDEN (Inf). This is unlike the soft 'penalty' mode, which merely up-weights off-ER links.
%
% A MISSING mask ([]) forbids every link: strict mode fails CLOSED. It must never be read as
% "no ER constraint here", which would silently degrade this to plain Euclidean linking.
%
% supP : ER mask for the SOURCE frame.  supQ : ER mask for the TARGET frame (default supP).
% lambda is kept in the signature for interface parity but is not used in strict geodesic.
if nargin < 6, supQ = supP; end
np = size(P,1); nq = size(Q,1);
dx = P(:,1) - Q(:,1).'; dy = P(:,2) - Q(:,2).'; E = hypot(dx, dy);
C = E; C(E > R) = Inf;
if np == 0 || nq == 0, return; end

supPD = spt_er_support(supP); supQD = spt_er_support(supQ);
if isempty(supPD) || isempty(supQD), C(:) = Inf; return; end   % no ER this frame -> forbid all links

okP = spt_on_er(P(:,1:2), supPD);          % source on its own frame's ER?
okQ = spt_on_er(Q(:,1:2), supQD);          % target on its own frame's ER?
C(~okP, :) = Inf;
C(:, ~okQ) = Inf;

[Hh, Ww] = size(supPD);
rad = ceil(R) + 2;
for i = 1:np
    if ~okP(i) || ~any(isfinite(C(i,:))), continue; end
    px = round(P(i,1)); py = round(P(i,2));
    x0 = max(1,px-rad); x1 = min(Ww,px+rad); y0 = max(1,py-rad); y1 = min(Hh,py+rad);
    crop = supPD(y0:y1, x0:x1); sx = px-x0+1; sy = py-y0+1;
    D = bwdistgeodesic(crop, sx, sy, 'quasi-euclidean');
    for j = 1:nq
        if ~isfinite(C(i,j)), continue; end     % beyond Euclidean R, or an endpoint is off-ER
        qx = round(Q(j,1))-x0+1; qy = round(Q(j,2))-y0+1;
        if qx>=1 && qy>=1 && qx<=size(crop,2) && qy<=size(crop,1) && isfinite(D(qy,qx)) && D(qy,qx)<=R
            C(i,j) = D(qy,qx);                  % reachable along ER within range -> geodesic length
        else
            C(i,j) = Inf;                       % unreachable / detour > R -> FORBID (strict geodesic)
        end
    end
end
end
