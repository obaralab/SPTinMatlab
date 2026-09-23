function [a, b] = cs_outline_sigma(varargin)
%CS_OUTLINE_SIGMA  The smoothing that contact-site OUTLINES are made at (the Refine tab's "outline σ").
%
%   [sigNm, src] = cs_outline_sigma(anaDir)       the project's setting, in nm; src says where from
%   [sigPx, peakUm] = cs_outline_sigma('scale', sigNm, SF, maxRadiusUm)
%                                                 that σ on a grid of SF µm/px, and the radius the
%                                                 half-max rule looks for its local peak in
%
% DETECTION AND OUTLINE ARE DIFFERENT SCALES. The picker finds sites on a density smoothed with
% σ = 8 px (240 nm): wide enough to find a site in a sparse window. An outline traced on that
% density cannot be smaller than the blur - the half-max outline of a single point is already
% 0.25 µm² - so outlines drawn or computed on it came out ~5x the published VAPB outlines
% (median 0.45 vs 0.089 µm²). Outlines are therefore made on their own, finer density.
%
% THE DEFAULT, 100 nm, is the value at which the automatic half-max outline, run on the VAPB
% dataset's own localizations at its own picks, gives its hand-drawn median area (0.090 vs
% 0.089 µm²; 90 nm gives 0.076, 120 nm 0.120).
%
% The setting is stored as outlineSigmaNm in analysis/CS_footprints.mat (the Refine tab's Save,
% and cs_footprints_regenerate, write it). A project that never set it gets the default.
%
% THE PEAK RADIUS is min(maxRadiusUm, 3σ). At 240 nm that is the 0.6 µm size cap, exactly as
% before. At 100 nm a site's threshold comes from the density within 0.3 µm of it, not from a
% brighter neighbour 0.5 µm away, which at this resolution is often a separate spot.

DEFAULT_NM = 100;
if nargin >= 1 && ischar(varargin{1}) && strcmp(varargin{1}, 'scale')
    [sigNm, SF, maxRu] = varargin{2:4};
    a = sigNm / 1000 / SF;
    b = min(maxRu, 3 * sigNm / 1000);
    return;
end
a = DEFAULT_NM; b = 'default';
if nargin < 1 || isempty(varargin{1}), return; end
f = fullfile(char(varargin{1}), 'CS_footprints.mat');
if ~isfile(f), return; end
try
    w = whos('-file', f);
    if any(strcmp({w.name}, 'outlineSigmaNm'))
        L = load(f, 'outlineSigmaNm');
        if isscalar(L.outlineSigmaNm) && isfinite(L.outlineSigmaNm) && L.outlineSigmaNm > 0
            a = double(L.outlineSigmaNm); b = 'CS_footprints.mat';
        end
    end
catch
end
end
