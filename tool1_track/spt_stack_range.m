function st = spt_stack_range(sptPath, nSample)
%SPT_STACK_RANGE  What a contrast control needs, read once per cell.
%
%   st = spt_stack_range(sptPath, nSample)
%
%   .lo/.hi          robust range for SLIDER LIMITS (0.05/99.95 pct over the sampled frames). Kept
%                    percentile-based on purpose: one hot pixel must not make the sliders unusable.
%   .rawLo/.rawHi    the TRUE min/max over the sample — Fiji's Reset, and what a Fiji-saved file
%                    stores as min/max in its ImageJ metadata block.
%   .sample          a pooled subsample of pixel values across the sampled frames.
%
% The sample is the point. Computing a stretch from the CURRENT FRAME makes the brightness change
% every time you scrub; Fiji computes one range for the stack and holds it. Pooling a spread of
% frames makes an auto-stretch stack-representative and stable, for one read per cell.
%
% Shared by Tool 1's detect preview and Tool 2's selected-track player, so the two cannot drift.

if nargin < 2 || isempty(nSample), nSample = 12; end
st = struct('lo',0,'hi',1,'rawLo',0,'rawHi',1,'sample',[]);
if isempty(sptPath) || ~isfile(sptPath), return; end

try, info = imfinfo(sptPath); catch, return; end
nfr = numel(info);
if nfr < 1, return; end
idx = unique(round(linspace(1, nfr, min(nfr, max(1,nSample)))));

lo = inf; hi = -inf; rlo = inf; rhi = -inf; acc = cell(1,numel(idx));
for q = 1:numel(idx)
    try, im = double(imread(sptPath, idx(q))); catch, continue; end
    v = im(:); v = v(isfinite(v));
    if isempty(v), continue; end
    lo  = min(lo,  prctile(v,0.05));  hi  = max(hi,  prctile(v,99.95));
    rlo = min(rlo, min(v));           rhi = max(rhi, max(v));
    acc{q} = v(1:3:end);              % every 3rd pixel is plenty for a 256-bin histogram
end
if ~isfinite(lo) || ~isfinite(hi), return; end     % nothing readable — keep the 0..1 default
if ~(hi  > lo),  hi  = lo  + 1; end
if ~(rhi > rlo), rhi = rlo + 1; end
st.lo = lo; st.hi = hi; st.rawLo = rlo; st.rawHi = rhi; st.sample = vertcat(acc{:});
end
