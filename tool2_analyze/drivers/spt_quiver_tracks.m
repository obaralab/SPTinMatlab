function h = spt_quiver_tracks(ax, T, cols, opts)
%SPT_QUIVER_TRACKS  Every step of every track drawn as an arrow, one colour per track.
%
%   h = spt_quiver_tracks(ax, T, cols)
%   h = spt_quiver_tracks(ax, T, cols, opts)
%
% The view the VAPB work used per contact site (ConditionAccumulatorFinal.m: one quiver call per
% member track, over the track's own step vectors). A trajectory drawn as a line says where the
% molecule went; the same trajectory drawn as arrows says how far it moved at each step and in
% which direction, so a run of long arrows pointing the same way (directed motion, or stage drift)
% separates from a knot of short ones pointing everywhere (a molecule held in place).
%
% INPUT
%   ax    axes to draw in (gca if empty)
%   T     a TrackStruct element - needs .matrix [m x n x 3] (frame, x, y in um) and .vector
%         [m-1 x n x 2] (the per-frame step vector, um/frame). A contact site works too:
%         pass struct('matrix', s.CSmatrix, 'vector', s.CSvec) and the arrows are drawn in the
%         site's own frame, centred on refCenter.
%   cols  track columns to draw (default: all of them)
%
% OPTIONS
%   .frames    [f0 f1] draw only steps whose first localization is in this frame window ([] = all)
%   .scale     arrow length multiplier (1 = true length in um, the default). MATLAB's quiver
%              autoscaling is OFF: with it on, each track is scaled by its own longest arrow and
%              two tracks in one figure cannot be compared - which is exactly what this plot is for.
%   .colorBy   'track' (default) one colour per track, cycling through .colors
%              'speed'  arrows grouped into .nBins speed classes and coloured by a colormap, so one
%                       track's fast and slow stretches separate (adds a colorbar)
%   .colors    colour matrix for 'track' (default: the axes colour order)
%   .cmap      colormap for 'speed' (default parula)
%   .nBins     speed classes for 'speed' (default 5)
%   .lineWidth (0.75)   .maxHeadSize (0.4)   .alpha (1)
%   .tracks    draw the trajectory lines faintly underneath (default false)
%
% OUTPUT h: the quiver handles (one per track, or one per speed class).

if nargin < 4 || ~isstruct(opts), opts = struct(); end
if isempty(ax), ax = gca; end
M = T.matrix; V = getf(T, 'vector', []);
if isempty(V), V = cat(3, diff(M(:,:,2),1,1), diff(M(:,:,3),1,1)); end   % fall back to raw steps
n = size(M,2);
if nargin < 3 || isempty(cols), cols = 1:n; end
cols = cols(:)';
win   = getf(opts, 'frames', []);
scale = getf(opts, 'scale', 1);
by    = lower(getf(opts, 'colorBy', 'track'));
lw    = getf(opts, 'lineWidth', 0.75);
hs    = getf(opts, 'maxHeadSize', 0.4);
nBins = getf(opts, 'nBins', 5);
cmap  = getf(opts, 'cmap', parula(256));
colr  = getf(opts, 'colors', get(ax, 'ColorOrder'));
drawT = getf(opts, 'tracks', false);

X = M(:,:,2); Y = M(:,:,3); F = M(:,:,1);
U = V(:,:,1); W = V(:,:,2);
keep = isfinite(X(1:end-1,:)) & isfinite(Y(1:end-1,:)) & isfinite(U) & isfinite(W);
if ~isempty(win)
    keep = keep & F(1:end-1,:) >= win(1) & F(1:end-1,:) <= win(2);
end

washold = ishold(ax); hold(ax, 'on');
if drawT
    for j = cols
        ok = isfinite(X(:,j));
        if nnz(ok) > 1, plot(ax, X(ok,j), Y(ok,j), '-', 'Color', [0.6 0.6 0.6 0.5], 'LineWidth', 0.4, 'HitTest','off'); end
    end
end

switch by
    case 'speed'
        sp = hypot(U, W);
        m = keep(:, cols); s = sp(:, cols);
        v = s(m);
        if isempty(v), h = gobjects(0); if ~washold, hold(ax,'off'); end, return; end
        edges = quantile(v, linspace(0, 1, nBins+1)); edges(1) = -inf; edges(end) = inf;
        h = gobjects(1, nBins);
        for b = 1:nBins
            sel = keep & sp > edges(b) & sp <= edges(b+1);
            sel(:, setdiff(1:n, cols)) = false;
            c = cmap(max(1, round((b-0.5)/nBins * size(cmap,1))), :);
            [r, cc] = find(sel);
            if isempty(r), h(b) = quiver(ax, NaN, NaN, NaN, NaN, 0, 'Color', c); continue; end
            idx = sub2ind(size(X), r, cc);
            h(b) = quiver(ax, X(idx), Y(idx), scale*U(sub2ind(size(U), r, cc)), scale*W(sub2ind(size(W), r, cc)), ...
                0, 'Color', c, 'LineWidth', lw, 'MaxHeadSize', hs);
        end
        colormap(ax, cmap); clim(ax, [edges(2) edges(end-1)]);
    otherwise
        h = gobjects(1, numel(cols));
        for q = 1:numel(cols)
            j = cols(q);
            sel = keep(:, j);
            c = colr(mod(q-1, size(colr,1)) + 1, :);
            if ~any(sel), h(q) = quiver(ax, NaN, NaN, NaN, NaN, 0, 'Color', c); continue; end
            h(q) = quiver(ax, X(sel, j), Y(sel, j), scale*U(sel, j), scale*W(sel, j), 0, ...
                'Color', c, 'LineWidth', lw, 'MaxHeadSize', hs);
        end
end
axis(ax, 'image'); set(ax, 'YDir', 'reverse');     % image convention, as everywhere else
if ~washold, hold(ax, 'off'); end
end

function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
