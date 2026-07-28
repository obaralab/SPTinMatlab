function sb = cs_smooth_boundary(poly, amount, nOut)
%CS_SMOOTH_BOUNDARY  Smooth a closed contact-site boundary polygon into a clean, closed loop.
%
%   sb = cs_smooth_boundary(poly)              % default smoothing
%   sb = cs_smooth_boundary(poly, amount)      % amount in [0,1]: 0 = barely, 1 = near-circular
%   sb = cs_smooth_boundary(poly, amount, nOut)% resample to nOut points around the loop
%
% Resamples the polygon to nOut points equally spaced by arc length, then applies a PERIODIC (wrap-
% around) moving average to x and y so there is no seam/kink where the boundary closes — a jagged
% freehand trace or pixel-traced half-max ring becomes a smooth closed curve. Returns a closed
% polygon (last row == first). Handles too-short inputs by returning them unchanged.
%
% poly : [K x 2] closed or open polygon (any units). amount default 0.35, nOut default 120.
if nargin < 2 || isempty(amount), amount = 0.35; end
if nargin < 3 || isempty(nOut),   nOut   = 120;  end
amount = min(max(amount,0),1);
sb = poly;
if isempty(poly) || size(poly,1) < 4, return; end

P = poly;
if isequal(P(1,:), P(end,:)), P(end,:) = []; end     % drop the duplicate closing vertex
n = size(P,1);
if n < 4, sb = poly; return; end

% cumulative arc length around the CLOSED loop (append the first point after the last)
seg = hypot(diff([P(:,1); P(1,1)]), diff([P(:,2); P(1,2)]));
d   = [0; cumsum(seg)];                               % length n+1, d(end) = perimeter
per = d(end);
if ~(per > 0), sb = poly; return; end
PC  = [P; P(1,:)];                                    % closed vertex list (n+1)

tq = linspace(0, per, nOut+1)'; tq(end) = [];         % nOut samples, exclusive of the wrap
xr = interp1(d, PC(:,1), tq, 'linear');
yr = interp1(d, PC(:,2), tq, 'linear');

w = 3 + round(amount * nOut * 0.45);                  % smoothing window (odd), grows with amount
if mod(w,2)==0, w = w + 1; end
w = min(w, nOut - mod(nOut+1,2));                     % keep < nOut and odd
if w < 3, w = 3; end

xs = circSmooth(xr, w);
ys = circSmooth(yr, w);
sb = [xs, ys];
sb(end+1,:) = sb(1,:);                                % close the loop
end

% -------------------------------------------------------------------------
function y = circSmooth(x, w)
% moving average of window w over the PERIODIC signal x (no seam at the wrap)
x = x(:); n = numel(x); h = (w-1)/2;
xp = [x(n-h+1:n); x; x(1:h)];                         % wrap-pad both ends
yc = conv(xp, ones(w,1)/w, 'same');
y  = yc(h+1:h+n);
end
