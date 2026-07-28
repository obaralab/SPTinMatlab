function sb = cs_close_boundary(poly, nSeam, passes)
%CS_CLOSE_BOUNDARY  Close a hand-traced boundary SMOOTHLY at the seam, keeping the drawn shape.
%
%   sb = cs_close_boundary(poly)                 % round only the closing join
%   sb = cs_close_boundary(poly, nSeam, passes)  % nSeam points each side of the seam, `passes` rounds
%
% A freehand trace closes with a straight chord from the last point back to the first, leaving a sharp
% notch/corner. This rounds ONLY that closing seam (a few vertices where end meets start) with light
% Laplacian smoothing, and leaves every other traced vertex EXACTLY as drawn — so the actual shape is
% preserved, just the closure is smooth. (For rounding the whole outline, use cs_smooth_boundary.)
%
% poly : [K x 2] polygon (any units). Returns a closed polygon (last row == first).
if nargin < 2 || isempty(nSeam),  nSeam  = 4; end
if nargin < 3 || isempty(passes), passes = 3; end
sb = poly;
if isempty(poly) || size(poly,1) < 4, return; end

P = poly;
if isequal(P(1,:), P(end,:)), P(end,:) = []; end     % open the ring (unique vertices)
n = size(P,1);
if n < 2*nSeam + 2, sb = P; sb(end+1,:) = sb(1,:); return; end

seam = [n-nSeam+1:n, 1:nSeam];                        % vertices straddling the seam (periodic)
Q = P;
for p = 1:passes
    Qn = Q;
    for ii = seam
        a = mod(ii-2, n) + 1; b = mod(ii, n) + 1;     % periodic neighbours
        Qn(ii,:) = 0.25*Q(a,:) + 0.5*Q(ii,:) + 0.25*Q(b,:);   % gentle corner rounding at the seam only
    end
    Q = Qn;
end
sb = Q; sb(end+1,:) = sb(1,:);                        % close
end
