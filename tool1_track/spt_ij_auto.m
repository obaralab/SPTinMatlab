function [lo, hi] = spt_ij_auto(im, autoThreshold)
%SPT_IJ_AUTO  ImageJ's ContrastAdjuster.autoAdjust, transcribed.
%
% Shared by Tool 1's detect preview and Tool 2's selected-track player. It lived as a local
% function in spt_app.m until the same contrast problem turned up in track_viewer.m; two copies
% of a transcription is how they drift.
%
% ImageJ builds a 256-bin histogram over the image's own min..max, then walks in from each end until
% it finds a bin holding MORE than pixelCount/autoThreshold pixels. The bin edges of the first such
% bin at each end become the display range. autoThreshold starts at 5000 (so the threshold is 0.02%
% of the pixels) and halves on each repeated click.
%
% The count-based rule is the whole point. A percentile rule asks "where does the top 0.2% of the
% INTENSITY DISTRIBUTION start", which on a mostly-empty single-molecule frame is still background.
% The count rule asks "which is the first intensity level that is actually POPULATED", which walks
% past the sparse spot tail and leaves the spots unsaturated.
lo = NaN; hi = NaN;
v = double(im(:)); v = v(isfinite(v));
if isempty(v), return; end
mn = min(v); mx = max(v);
if ~(mx > mn), lo = mn; hi = mn + 1; return; end          % flat frame: any non-degenerate range

nb = 256;
edges = linspace(mn, mx, nb+1);
h = histcounts(v, edges);
thr = numel(v) / max(autoThreshold, 1);

i = find(h > thr, 1, 'first');
j = find(h > thr, 1, 'last');
if isempty(i) || isempty(j)                                % threshold too high for every bin
    lo = mn; hi = mx; return;
end
% ImageJ maps the found BIN INDICES back through the histogram's own scale.
lo = edges(i);
hi = edges(j+1);
if hi <= lo, lo = mn; hi = mx; end                         % degenerate -> full range, as ImageJ does
end
