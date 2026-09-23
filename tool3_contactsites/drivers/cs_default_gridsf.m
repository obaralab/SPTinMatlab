function [grid, SF] = cs_default_gridsf(anaDir)
%CS_DEFAULT_GRIDSF  Default density-grid size + microns-per-pixel for a project's analysis folder.
%   [grid, SF] = cs_default_gridsf(anaDir)
% grid from a Densities/*_rho.tif height (falls back to 921); SF = cs_config.SnapFOV_um/grid
% (falls back to 27.61/grid). Used when a cell has no per-window CSwindows.mat to carry its own SF.
grid = 921; SF = 27.61/921;
D = dir(fullfile(anaDir,'Densities','*_rho.tif'));
if ~isempty(D)
    try, info = imfinfo(fullfile(D(1).folder,D(1).name)); grid = info(1).Height; catch, end
end
SF = 27.61/grid;
try
    cfg = cs_config(anaDir);
    if isfield(cfg,'SnapFOV_um') && cfg.SnapFOV_um>0, SF = cfg.SnapFOV_um/grid; end
catch
end
end
