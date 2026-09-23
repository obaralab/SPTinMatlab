%ANALYSE_EXPORT_ONE_CELL  Load an exported cell and re-derive its contact-site numbers from the
%exported files alone - one cell at a time.
%
% Needs only base MATLAB (no pipeline code). Put this file in the export folder (it is written there)
% and run it. Edit the three settings below.
%
% For each cell it:
%   1. loads the density (imG), the refined and contact sites, the tracks and the windows
%   2. recounts, for every refined site, the localizations and tracks inside its outline during its
%      window, and checks them against the exported table (they must match exactly)
%   3. for every member track, measures how much of it sits inside the site
%   4. optionally plots the density with the refined (white) and automatic (cyan, dashed) outlines
% and collects one row per site into the table `results`, saved as results_per_site.csv.
%
% THE DATA, as loaded here (see README.txt for every field):
%   S.imG       n x n density, row = y, column = x; image column c covers x in [c*bin, (c+1)*bin) nm
%   S.refined   struct array, one per refined site: csID, window, frame0, frame1, x_um, y_um,
%               area_um2, n_loc_inside, n_tracks, member_tracks, boundary_um (K x 2 absolute um), ...
%   S.contact   struct array, one per pick: pick_*, detect_*, auto_*, auto_boundary_um, ...
%   S.tracks    struct: frame, x_um, y_um are [maxLength x nTracks] (NaN-padded); column j is track j,
%               the number used in member_tracks; frame is 0-based; frameInterval_s; build_col
%   S.windows   struct: ranges = [first last] frame of each picker window (if exported)

% ------------------------------------------------------------------------------------------------
exportDir = fileparts(mfilename('fullpath'));   % this folder; or set a path, e.g. '/data/exports/run1'
cellToRun = '';                                % '' = every cell, one after another; or a cell name
makePlots = true;                              % one figure per cell
% ------------------------------------------------------------------------------------------------

files = dir(fullfile(exportDir, 'sites', '*_refinedsites.mat'));
cellNames = erase({files.name}, '_refinedsites.mat');
if ~isempty(cellToRun), cellNames = cellNames(strcmp(cellNames, cellToRun)); end
assert(~isempty(cellNames), 'No exported cell found in %s (looked for sites/*_refinedsites.mat)', exportDir);
fprintf('%d cell(s) to analyse in %s\n', numel(cellNames), exportDir);

rows = {};
for c = 1:numel(cellNames)                      % ONE CELL AT A TIME
    S = loadExportedCell(exportDir, cellNames{c});
    fprintf('\n%s: %d refined site(s), %d pick(s), %d track(s), %d localization(s)\n', S.name, ...
        numel(S.refined), numel(S.contact), size(S.tracks.x_um,2), nnz(isfinite(S.tracks.x_um)));

    for k = 1:numel(S.refined)
        site = S.refined(k);
        m = measureSite(site.boundary_um, site.frame0, site.frame1, S.tracks);
        % the recount must reproduce the exported numbers exactly
        assert(m.n_loc_inside == site.n_loc_inside && m.n_tracks == site.n_tracks && ...
               isequal(m.member_tracks(:), site.member_tracks(:)), ...
            '%s site %d: recount %d loc / %d trk does not match the export (%d / %d)', ...
            S.name, site.csID, m.n_loc_inside, m.n_tracks, site.n_loc_inside, site.n_tracks);
        rows(end+1, :) = {S.name, site.csID, site.window, logical(site.mito), site.area_um2, ...
            m.n_loc_inside, m.n_tracks, m.median_pct_inside, m.median_time_inside_s, ...
            m.n_loc_inside / site.area_um2}; %#ok<SAGROW>
    end
    fprintf('  all %d refined site(s) recount exactly\n', numel(S.refined));

    if makePlots, plotCell(S); end
end

results = cell2table(rows, 'VariableNames', {'cell','csID','window','mito','area_um2', ...
    'n_loc_inside','n_tracks','median_pct_inside','median_time_inside_s','loc_per_um2'});
writetable(results, fullfile(exportDir, 'results_per_site.csv'));
fprintf('\n%d site(s) -> %s\n', height(results), fullfile(exportDir, 'results_per_site.csv'));

% ================================================================================================
function S = loadExportedCell(exportDir, name)
S.name = name;
D = load(fullfile(exportDir, ['Density_' name '.mat']));                S.imG = D.imG;
R = load(fullfile(exportDir, 'sites',  [name '_refinedsites.mat']));    S.refined = R.refinedsites;
C = load(fullfile(exportDir, 'sites',  [name '_contactsites.mat']));    S.contact = C.contactsites;
T = load(fullfile(exportDir, 'tracks', [name '_tracks.mat']));          S.tracks = T.tracks;
S.windows = [];
wf = fullfile(exportDir, ['Density_' name '_CSwindows.mat']);
if isfile(wf), W = load(wf); S.windows = W.windows; end
end

function m = measureSite(boundary_um, frame0, frame1, tracks)
% Localizations of the site's window that fall inside its outline, the tracks they belong to, and
% how much of each such track is inside.
inWin = tracks.frame >= frame0 & tracks.frame <= frame1;
ok = isfinite(tracks.x_um) & isfinite(tracks.y_um) & inWin;
inside = false(size(ok));
inside(ok) = inpolygon(tracks.x_um(ok), tracks.y_um(ok), boundary_um(:,1), boundary_um(:,2));
m.n_loc_inside = nnz(inside);
m.member_tracks = find(any(inside, 1));
m.n_tracks = numel(m.member_tracks);
% per member track: % of its window localizations inside, and the time that represents
nIn  = sum(inside(:, m.member_tracks), 1);
nWin = sum(ok(:, m.member_tracks), 1);
m.pct_inside = 100 * nIn ./ max(nWin, 1);
m.time_inside_s = nIn * tracks.frameInterval_s;          % localizations inside x frame interval
m.median_pct_inside = median(m.pct_inside);
m.median_time_inside_s = median(m.time_inside_s);
if isempty(m.member_tracks), m.median_pct_inside = NaN; m.median_time_inside_s = NaN; end
end

function plotCell(S)
% Density in microns, with every outline. Image column c covers [c, c+1) x bin, so its centre is
% (c + 0.5) x bin - drawing in microns keeps the outlines exactly on the image.
bin = S.refined(1).bin_nm / 1000;
n = size(S.imG, 1);
centres = ((1:n) + 0.5) * bin;
figure('Name', S.name, 'Color', 'w');
imagesc(centres, centres, S.imG); axis image; colormap(turbo); colorbar; hold on
for k = 1:numel(S.contact)
    b = S.contact(k).auto_boundary_um;
    plot(b(:,1), b(:,2), '--', 'Color', [0.3 0.9 1], 'LineWidth', 0.8);
end
for k = 1:numel(S.refined)
    b = S.refined(k).boundary_um;
    plot(b(:,1), b(:,2), 'w-', 'LineWidth', 1.2);
    text(S.refined(k).x_um, S.refined(k).y_um, sprintf('s%d', S.refined(k).csID), ...
        'Color', 'w', 'FontSize', 8, 'HorizontalAlignment', 'center');
end
hold off
xlabel('x (\mum)'); ylabel('y (\mum)');
title(sprintf('%s - refined (white), automatic (cyan)', S.name), 'Interpreter', 'none');
end
