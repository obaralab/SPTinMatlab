function [m, fg] = cs_channel_mask(segPath, nFrames, frame0, gridSize, varargin)
%CS_CHANNEL_MASK  Binary organelle footprint from a segmentation stack at one frame.
%
%   [m, fg] = cs_channel_mask(segPath, nFrames, frame0, gridSize, ...)
%
% Channel-agnostic: the SAME reader serves the ER support mask and the mito contour, so neither
% organelle needs its own copy of the label/resize/clamp rules.
%
% INPUT
%   segPath  : path to the segmentation stack; '' -> m = [] (channel not imaged).
%   nFrames  : number of pages in the stack; < 1 -> m = [].
%   frame0   : ZERO-based frame index. Rounded, then clamped into [1, nFrames] as a page number —
%              a window that starts past the end of a shorter seg stack gets the last page, which is
%              what the callers relied on rather than an error.
%   gridSize : [H W] (or a scalar for square) to resize to. Empty -> native stack size, no resize.
%
% OPTIONS
%   'FgLabel' : foreground label to use instead of the per-page rule below.
%
% OUTPUT
%   m  : [H x W] logical, true on the organelle. [] when unavailable OR unreadable — callers must
%        handle [], which for a support mask means "no restriction" and for a contour means "skip".
%   fg : the foreground label actually used (NaN when m is []).
%
% FOREGROUND LABEL. Default is the minimum non-zero value ON THAT PAGE — 1 for an ilastik label map,
% 255 for a 0/255 binary. Note this is the per-page rule the picker has always used, NOT the
% stack-wide sample that spt_load_seg takes; a page containing none of the organelle is entirely
% label 2, so the per-page rule reads fg = 2 there and INVERTS that one frame. Pass 'FgLabel' (e.g.
% from spt_seg_fg_label) to get the stack-wide behaviour. Kept as the default only because changing
% it would move published masks — a silent fix would change numbers already reported, so the
% inversion is surfaced to the user rather than corrected behind their back.
p = inputParser; p.addParameter('FgLabel', []);
p.parse(varargin{:});
fgOpt = p.Results.FgLabel;

m = []; fg = NaN;
if ~(ischar(segPath) || isstring(segPath)) || isempty(char(segPath)), return; end
if isempty(nFrames) || ~isscalar(nFrames) || nFrames < 1, return; end
page = min(max(round(frame0)+1, 1), nFrames);
try
    a = imread(char(segPath), page);
    if isempty(fgOpt)
        v = unique(a(:)); nz = v(v > 0);
        fg = 1; if ~isempty(nz), fg = double(min(nz)); end
    else
        fg = double(fgOpt);
    end
    b = (a == fg);
    if isempty(gridSize)
        m = b;
    else
        if isscalar(gridSize), gridSize = [gridSize gridSize]; end
        m = imresize(double(b), gridSize, 'nearest') > 0.5;   % nearest: a label map must not blur
    end
catch
    m = []; fg = NaN;
end
end
