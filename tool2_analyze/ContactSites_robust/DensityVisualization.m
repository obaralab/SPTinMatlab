function DensityVisualization(Tracks,PixSize,SaveFlag)
% Whole-cell localization-density map (_rho.tif), one per cell.
%
% WHAT CHANGED (and why your _rho.tif used to be 1600x1600):
% The old version rendered the density into a 768-pt figure and wrote it with
% saveas(figure,...). saveas rasterizes at the SCREEN's DPI, so the saved file
% size — and therefore SF = FOV_um/size(imG,1) — depended on the machine: a
% 768-pt figure becomes ~1600 px on a Retina Mac (2.08x) but 768 px on a
% standard display, and it carried a few-pixel figure margin. That made the map
% resolution non-reproducible and left a small border offset under the boundary.
%
% Now we write the RAW density array directly with imwrite, at its native
% resolution (~FOV_um/PixSize = ~922 px at 30 nm bins over the 27.61 um FOV).
% This is display-INDEPENDENT (same on every machine), exactly PixSize per pixel,
% and has no border slop. Every consumer (ContactSiteMapper, cs_identify picker,
% the app) derives SF = FOV_um/size(imG,1) from the actual file, so coordinates
% stay correct at any resolution — including any older 1600 px maps still on disk.

if nargin==2, SaveFlag=false; end
cfg = cs_config();

for i=1:size(Tracks,2)
    % 30 nm localization-count histogram over the FOV, lightly smoothed.
    % (Bins/orientation are unchanged from the original so the pixel->um contract
    %  the mapper relies on is identical — only the FILE format/size changes.)
    Bins = PixSize*(1:ceil(cfg.FOV_um/(PixSize/1000))+1);
    NumLoc = histcounts2(1000*Tracks(i).matrix(:,:,2), 1000*Tracks(i).matrix(:,:,3), Bins, Bins);
    imG = imgaussfilt(NumLoc,[2 2])';                 % row = y, col = x

    lo = min(imG,[],'all','omitnan'); hi = max(imG,[],'all','omitnan');
    if ~(hi>lo), hi = lo + 1; end                     % flat map -> avoid /0
    idx = uint8(round(255*(imG-lo)/(hi-lo)));          % 0..255 at native resolution
    rgb = ind2rgb(idx, turbo(256));                    % same turbo look as before

    if SaveFlag
        imwrite(rgb, strcat(Tracks(i).file,'_rho.tif'));   % raw raster: no figure, no flash, no DPI dependence
    else
        figure('Name',sprintf('rho: %s',Tracks(i).file));  % interactive view only
        imshow(rgb,'Border','tight');
    end
end
end
