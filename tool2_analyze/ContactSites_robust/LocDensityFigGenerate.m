function imG = LocDensityFigGenerate(X, Y, PixSize, ROI)
%LOCDENSITYFIGGENERATE  2-D localization-density image from (X,Y).
%
% Self-contained reconstruction of the advisor's external helper (not shipped
% with the suite), matching the binning used by DensityVisualization /
% LocDensityFigIntUse so the pipeline runs without the external dependency.
%
%   imG = LocDensityFigGenerate(X, Y, PixSize, ROI)
%
%   X, Y    : localization coordinates in MICRONS (may contain NaN/Inf).
%   PixSize : density bin size in nm (e.g. 30).
%   ROI     : [lo hi] window in PixSize-units (bins), centered at 0. The image
%             spans ROI(1)*PixSize .. ROI(2)*PixSize nm on each axis
%             (e.g. [-40 40] at PixSize 30 -> +/-1.2 um).
%
% Returns imG: Gaussian-smoothed 2-D histogram in image convention (Y down),
% same as the suite's other density maps.
%
% If you obtain the advisor's original LocDensityFigGenerate, delete this file.

x = 1000*double(X(:));                 % um -> nm
y = 1000*double(Y(:));
ok = isfinite(x) & isfinite(y);
edges  = PixSize * (ROI(1):ROI(2));    % bin edges in nm
NumLoc = histcounts2(x(ok), y(ok), edges, edges);
imG = imgaussfilt(NumLoc, [2 2]);      % same smoothing as the density stage
% Scale to 0-255: callers (ConditionAccumulatorFinal*, CS_reorienter, refiners)
% imshow(imG,turbo) it as an INDEXED image with no autoscaling, so raw counts
% would render near-black. Idempotent on an already-0-255 image.
mn = min(imG,[],'all','omitnan'); mx = max(imG,[],'all','omitnan');
if mx>mn, imG = 255*(imG-mn)/(mx-mn); end
imG = imG';                            % match DensityVisualization orientation (Y down)
end
