function [ranges, SF, grid, source] = cs_load_windows(anaDir, base, wcol, gridDef, SFdef)
%CS_LOAD_WINDOWS  Authoritative per-window frame ranges for a cell (from the picker), with fallback.
%   [ranges, SF, grid, source] = cs_load_windows(anaDir, base, wcol, gridDef, SFdef)
% Reads Density_<base>_CSwindows.mat (windows.ranges [nW x 2] INCLUSIVE frame bins, .SF_umPerPx,
% .grid, .source = the density source the picker used: 'all'|'tracked'). If absent, falls back to ONE
% whole-movie window ([-Inf Inf]) per distinct Slice in wcol and returns source = '' (unknown).
SF = SFdef; grid = gridDef; source = '';
f = fullfile(anaDir,['Density_' base '_CSwindows.mat']);
if isfile(f)
    W = load(f); win = []; if isfield(W,'windows'), win = W.windows; end
    if ~isempty(win) && isfield(win,'ranges') && ~isempty(win.ranges)
        ranges = double(win.ranges);
        if isfield(win,'SF_umPerPx') && ~isempty(win.SF_umPerPx), SF = win.SF_umPerPx; end
        if isfield(win,'grid') && ~isempty(win.grid), grid = win.grid; end
        if isfield(win,'source') && ~isempty(win.source), source = char(win.source); end
        return;
    end
end
nW = max([1; wcol(:)]);
ranges = repmat([-Inf Inf], nW, 1);
end
