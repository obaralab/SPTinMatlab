function [sm, info] = cs_advisor_density(X, Y, fovUm, binNm)
%CS_ADVISOR_DENSITY  The density image the external ContactSites code expects, built exactly as it
%builds it (DensityVisualization + LocDensityFigIntUse), from whatever localizations you hand it.
%
%   [sm, info] = cs_advisor_density(X, Y, fovUm, binNm)
%
%   X, Y   localization coordinates in MICRONS (any shape; non-finite entries are ignored)
%   fovUm  field of view (um) — sets how many bins there are
%   binNm  bin size (nm)
%
%   sm     [n x n] smoothed counts, row = y, col = x.  n = ceil(fovUm / (binNm/1000)).
%          Density_<cell>.mat holds imG = 30*sm; Density_<cell>.tif is uint16(30*sm);
%          Densities/<cell>_rho.tif is sm rendered through turbo.
%   info   .n .binNm .fovUm .SF (= fovUm/n, the um per pixel the mapper uses) .edgesNm .nLoc
%
% THE GRID, stated because it is not the picker's. Edges are binNm*(1:n+1) nm, so column c holds
% x in [c*bin, (c+1)*bin) nm — a localization at x um lands in column floor(1000*x/bin). The picker
% and the mapper instead use col = round(x/SF), i.e. pixel c is centred on c*SF. With SF ~= bin the
% two agree to within half a pixel. This function reproduces the external code's convention on
% purpose, so its files stay a drop-in; site coordinates exported alongside it are given in um as
% well as in the picker's pixels, so nothing depends on which convention a reader assumes.
%
% Factored out of the analyze app so the export and the app's own density files cannot drift.

n     = ceil(fovUm / (binNm/1000));
edges = binNm * (1:n+1);
ok    = isfinite(X(:)) & isfinite(Y(:));
x = 1000*X(:); y = 1000*Y(:);
NumLoc = histcounts2(x(ok), y(ok), edges, edges);
sm = imgaussfilt(NumLoc, [2 2])';
info = struct('n',n,'binNm',binNm,'fovUm',fovUm,'SF',fovUm/n,'edgesNm',edges,'nLoc',nnz(ok));
end
