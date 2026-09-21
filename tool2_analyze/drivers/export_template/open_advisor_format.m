%OPEN_ADVISOR_FORMAT  Load a ContactSites folder and reach every structure in it - the published
%VAPB dataset, or an export's advisor_format/<condition>/ folder (same layout). Base MATLAB only.
%
% Run it inside the folder, or set `folder` below. The numbered blocks are independent: copy the
% one you need. Every field is described in README_advisor_format.txt.

folder = fileparts(mfilename('fullpath'));      % or e.g. '/Users/you/Desktop/VAPB_nature'

%% 1. Load ----------------------------------------------------------------------------------------
CS     = loadVar(folder, 'CS_final*.mat',       'CS');           % 1 x nSites: one per contact site
Tracks = loadVar(folder, '*_Tracks_final*.mat', 'Tracks');       % 1 x nCells: one per cell
EC     = loadVar(folder, '*_EC.mat',            'EC');           % 1 x nCells: enrichment counts
BI     = loadVar(folder, 'BindingInfo.mat',     'BindingInfo');  % one per ANNOTATED site
dt = 0.011;                                    % s per frame: the constant the VAPB scripts use
f = fullfile(folder, 'imaging_settings.csv');  % an export records its own - use it when present
if isfile(f), I = readtable(f); dt = median(I.frame_interval_s, 'omitnan'); end
fprintf('%d cells · %d contact sites (%d mito) · %.4g s/frame\n', ...
    numel(Tracks), numel(CS), nnz([CS.MitoFlag]), dt);

%% 2. Cells, and the sites in each ---------------------------------------------------------------
for c = 1:numel(Tracks)
    name  = erase(Tracks(c).file, '_Tracks');
    sites = find([CS.cellIndex] == c);           % global CS indices = [Tracks(c).MCSindex Tracks(c).OCSindex]
    fprintf('cell %2d  %-40s %4d tracks  %3d sites (%d mito)\n', c, name, ...
        numel(Tracks(c).lengths), numel(sites), nnz([CS(sites).MitoFlag]));
end

%% 3. One contact site ---------------------------------------------------------------------------
k = 1;                                         % which site (CS index)
s = CS(k);  T = Tracks(s.cellIndex);           % the site, and the cell it is in
outline_um = s.refboundary/1000 + s.refCenter; % refboundary is nm, relative to refCenter (um)
area_um2   = polyarea(outline_um(:,1), outline_um(:,2));
pick_um    = [mean(s.boundaries.x) mean(s.boundaries.y)];   % the square is centred on the pick
% T.matrix is [localization x track x (frame, x um, y um)]; refLocIDs / neighborIDs / LocIDs are
% linear indices into one page of it
fr = T.matrix(:,:,1);  x = T.matrix(:,:,2);  y = T.matrix(:,:,3);
inside = [fr(s.refLocIDs)   x(s.refLocIDs)   y(s.refLocIDs)];     % inside the outline  (n x 3)
neigh  = [fr(s.neighborIDs) x(s.neighborIDs) y(s.neighborIDs)];   % in the square, outside it
fprintf('\nCS %d (cell %d, csID %d, %s): %.3f um^2 · %d tracks · %d inside · %d neighbours\n', ...
    s.CS_index, s.cellIndex, s.csID, tern(s.MitoFlag, 'mito', 'other'), area_um2, ...
    numel(s.tracks), size(inside,1), size(neigh,1));

% the member tracks re-centred on refCenter: CSmatrix(:, j, :) is track s.tracks(j) of the cell
j  = 1;
tj = squeeze(s.CSmatrix(:, j, :));             % [frame, x - refCenter(1), y - refCenter(2)]
ok = isfinite(tj(:,2));
t_s  = tj(ok,1) * dt;                          % time, s
r_um = hypot(tj(ok,2), tj(ok,3));              % distance from the site centre, um
% CSLocIDs / CSneighborIDs index CSmatrix(:,:,1): the column says which member track
[rowIn, colIn] = ind2sub(size(s.CSmatrix(:,:,1)), s.CSLocIDs);
nInsidePerTrack = accumarray(colIn(:), 1, [numel(s.tracks) 1])';
% the ellipse fit is in the refiner's pixels: 3 nm each, pixel 400 = the pick
ellCentre_um = pick_um + (s.EllipseFit.Centroid - 400) * 0.003;
ellAxes_nm   = 3 * [s.EllipseFit.MajorAxisLength s.EllipseFit.MinorAxisLength];

%% 4. Mito vs other sites, and the enrichment coefficient per cell -------------------------------
for c = 1:numel(Tracks)
    mcs = Tracks(c).MCSindex;  ocs = Tracks(c).OCSindex;      % global CS indices by MitoFlag
    if isempty(EC), continue; end
    e = EC(c);                                                % localizations are "steps" here
    MCSprob = sum(e.MCSsteps) / e.TotalSteps;                 % share of the cell in mito sites
    OCSprob = sum(e.OCSsteps) / e.TotalSteps;                 % share in other sites
    coeff = MCSprob / OCSprob;  if OCSprob == 0, coeff = NaN; end   % blank in the published sheet
    fprintf('cell %2d: %d mito / %d other sites · MCSprob %.4f · OCSprob %.4f · MitoEnrichCoeff %.3g\n', ...
        c, numel(mcs), numel(ocs), MCSprob, OCSprob, coeff);
end

%% 5. Binding and dwell times (only on sites that have been annotated) ----------------------------
for k2 = find(arrayfun(@(q) ~isempty(q.trackBinding), CS))
    q = CS(k2);
    for jj = find(q.trackBinding > 0)
        d = q.DwellTimes(jj);                  % EntryPts / ExitPts: x = time (s) on the annotation's axis
        fprintf('CS %d track %d: %d binding event(s), dwell %s s\n', k2, q.tracks(jj), ...
            q.trackBinding(jj), mat2str((d.ExitPts(:,1) - d.EntryPts(:,1))', 3));
    end
end

%% 6. Plot one site ------------------------------------------------------------------------------
figure('Name', sprintf('CS %d', s.CS_index), 'Color', 'w');
subplot(1,2,1); hold on
for jj = 1:numel(s.tracks)
    plot(s.CSmatrix(:,jj,2) + s.refCenter(1), s.CSmatrix(:,jj,3) + s.refCenter(2), '-', 'Color', [0.7 0.7 0.7]);
end
plot(inside(:,2), inside(:,3), '.r');  plot(neigh(:,2), neigh(:,3), '.c');
plot(outline_um(:,1), outline_um(:,2), 'k-', 'LineWidth', 1.5);
bx = s.boundaries.x; by = s.boundaries.y;
plot(bx([1 2 2 1 1]), by([1 1 2 2 1]), 'k--');
plot(s.refCenter(1), s.refCenter(2), 'm+', 'MarkerSize', 12, 'LineWidth', 1.5);
axis equal; set(gca, 'YDir', 'reverse'); xlabel('x (\mum)'); ylabel('y (\mum)');
title(sprintf('CS %d: outline, square, inside (red), neighbours (cyan)', s.CS_index));
subplot(1,2,2); hold on
for jj = 1:numel(s.tracks)
    plot(s.CSmatrix(:,jj,1) * dt, hypot(s.CSmatrix(:,jj,2), s.CSmatrix(:,jj,3)));
end
xlabel('time (s)'); ylabel('distance from refCenter (\mum)'); title('member tracks');

% ================================================================================================
function v = loadVar(folder, pattern, name)
d = dir(fullfile(folder, pattern)); v = [];
if isempty(d), return; end
L = load(fullfile(d(1).folder, d(1).name), name);
v = L.(name);
end

function y = tern(c, a, b), if c, y = a; else, y = b; end, end
