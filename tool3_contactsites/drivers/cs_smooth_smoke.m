function cs_smooth_smoke()
% Verify cs_smooth_boundary: a jagged closed polygon becomes a smoother CLOSED loop, more smoothing
% reduces the perimeter, and degenerate inputs pass through.
here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));          % the two tools share the build, the channels and the manifest
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'), ...
        fullfile(root_,'tool3_contactsites','app'));
th = linspace(0,2*pi,60)'; r = 1 + 0.25*sin(9*th);          % deterministic jagged closed shape
P = [r.*cos(th), r.*sin(th)]; P(end,:) = P(1,:);

sb = cs_smooth_boundary(P, 0.4, 120);
assert(isequal(sb(1,:), sb(end,:)), 'result is not closed');
per = @(Q) sum(hypot(diff(Q(:,1)), diff(Q(:,2))));
fprintf('perimeter raw %.3f -> smooth %.3f | area raw %.3f -> %.3f\n', per(P), per(sb), polyarea(P(:,1),P(:,2)), polyarea(sb(:,1),sb(:,2)));
assert(per(sb) <= per(P)*1.02, 'smoothing should not lengthen the boundary');
assert(per(cs_smooth_boundary(P,0.9,120)) <= per(cs_smooth_boundary(P,0.05,120)) + 1e-9, 'more smoothing should shorten perimeter');
assert(isequal(cs_smooth_boundary([0 0;1 0],0.5), [0 0;1 0]), 'short polygon should pass through');

% cs_close_boundary: keeps the shape (area ≈ same), only rounds the seam ---------------------------
cb = cs_close_boundary(P);
assert(isequal(cb(1,:), cb(end,:)), 'closed result expected');
a0 = polyarea(P(:,1),P(:,2)); a1 = polyarea(cb(:,1),cb(:,2));
fprintf('close-seam: area raw %.3f -> %.3f (kept)  vs full-smooth area %.3f\n', a0, a1, polyarea(sb(:,1),sb(:,2)));
assert(abs(a1-a0)/a0 < 0.05, 'seam-only closing should preserve the shape/area (<5%%)');
% interior vertices (away from the seam) must be UNCHANGED
Popen = P(1:end-1,:); cbopen = cb(1:end-1,:);
mid = round(size(Popen,1)/2);
assert(max(abs(cbopen(mid,:)-Popen(mid,:))) < 1e-9, 'interior vertices must be untouched by seam closing');
fprintf('SMOOTH + CLOSE-SEAM SMOKE PASSED.\n');
end
