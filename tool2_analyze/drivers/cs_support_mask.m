function [m, info] = cs_support_mask(locCounts, varargin)
%CS_SUPPORT_MASK  Detection support derived from the localizations, for a project with no support
%                 channel.
%
%   [m, info] = cs_support_mask(locCounts, ...)
%
% A support channel (ER) does three jobs in cs_detect: it restricts the detection domain, it defines
% the Monte-Carlo null, and it is the background denominator. With no such channel the old fallback
% was true(size(...)) — the whole frame — and that is not a neutral choice. On a 128x128 field where
% the cell covers ~40%, median(dens(wholeFrame)) is taken mostly over empty background, collapses
% toward the eps guard at cs_detect.m:67, and enrichment = peak/background inflates without bound.
% The Monte-Carlo threshold falls at the same time, so more sites also pass. A no-support run on the
% whole frame is not comparable to any with-support run.
%
% This derives the support from where molecules were ACTUALLY SEEN: the occupancy of all
% localizations, dilated to close the gaps between them and filled so the cell interior counts.
% The background median is then taken over the cell rather than over the coverslip, which is what
% the ER mask was doing all along.
%
% INPUT
%   locCounts : [H x W] localization-count image for the WHOLE CELL — every localization, not one
%               window. Pass the cell-level counts even when detecting per window: deriving the
%               support from the same window being tested makes the statistic even less pivotal
%               than docs/HANDOFF.md open item 7.4 already describes.
%
% OPTIONS
%   'DilateR'  (6)     dilation radius in density pixels. Roughly "how far apart two localizations
%                      can be and still be the same piece of cell".
%   'MinFrac'  (0.02)  drop connected components smaller than this fraction of the total occupied
%                      area — isolated specks are noise, not cell.
%   'Fill'     (true)  fill enclosed holes, so an interior the molecules happened not to visit in
%                      this movie still counts as support.
%
% OUTPUT
%   m    : [H x W] logical. Never all-false — if the derivation yields nothing (no localizations at
%          all) it returns all-true and says so in info, because an empty domain would detect
%          nothing at all and hide the problem rather than show it.
%   info : .frac      fraction of the field the support covers — the number to report
%          .nComp     connected components kept
%          .degenerate true when it fell back to the whole frame
%          .why       one line of plain English for a status bar or a log
%
% REPORT THIS, DO NOT HIDE IT. The support is now estimated from the same localizations the sites
% are detected in, which is a real circularity on top of the one already flagged in the handoff.
% Callers should surface info.why so a reader of the numbers knows the denominator was derived
% rather than measured.
p = inputParser;
p.addParameter('DilateR', 6, @(x) isnumeric(x) && isscalar(x) && x >= 0);
p.addParameter('MinFrac', 0.02, @(x) isnumeric(x) && isscalar(x) && x >= 0 && x < 1);
p.addParameter('Fill', true, @(x) islogical(x) || isnumeric(x));
p.parse(varargin{:});
R    = double(p.Results.DilateR);
minF = double(p.Results.MinFrac);
doFill = logical(p.Results.Fill);

info = struct('frac',1,'nComp',0,'degenerate',true,'why','');
if isempty(locCounts)
    m = true(0); info.why = 'no count image — support undefined'; return
end
occ = locCounts > 0;
if ~any(occ(:))
    m = true(size(locCounts));
    info.why = 'no localizations at all — support fell back to the whole frame';
    info.frac = 1; return
end

if R > 0, m = imdilate(occ, strel('disk', round(R))); else, m = occ; end
if doFill, m = imfill(m, 'holes'); end

% Drop specks: a component holding a negligible share of the occupied area is noise, not cell.
if minF > 0
    cc = bwconncomp(m);
    if cc.NumObjects > 1
        areas = cellfun(@numel, cc.PixelIdxList);
        keep = areas >= minF * sum(areas);
        if ~any(keep), keep(find(areas == max(areas), 1)) = true; end   % never delete everything
        m2 = false(size(m));
        for i = find(keep), m2(cc.PixelIdxList{i}) = true; end
        m = m2;
    end
end

ccOut = bwconncomp(m);
info.nComp = ccOut.NumObjects;
info.frac  = nnz(m) / numel(m);
info.degenerate = false;
info.why = sprintf(['support derived from %d localization pixels (dilated %g px): covers %.0f%% ' ...
    'of the field in %d component(s) — the background median is over this, not the whole frame'], ...
    nnz(occ), R, 100*info.frac, info.nComp);
end
