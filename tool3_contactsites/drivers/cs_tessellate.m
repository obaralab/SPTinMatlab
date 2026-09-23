function varargout = cs_tessellate(varargin)
%CS_TESSELLATE  A diffusion map per cell: the localizations are divided into tessels that follow
%the cell, and each tessel gets its own D. The pipeline's stand-in for the VAPB dataset's JBM maps.
%
%   TS = cs_tessellate(anaDir)                     compute for every cell, save, return
%   TS = cs_tessellate(anaDir, opts)
%   TS = cs_tessellate('load', anaDir)             what was saved, or [] if never run
%   [D, idx] = cs_tessellate('cell', TS, base, sz) per-localization D and tessel index for one cell,
%                                                  as arrays the size of that cell's matrix page
%
% WHY THE TESSELS FOLLOW THE DATA. A grid, or a disc around a site, spends most of its area where
% there is no cell: the "outside" it measures is empty coverslip, and a site then looks enriched
% and slow against nothing. Here the tessels are seeded ON the localizations (k-means, one seed per
% opts.minLocs of them) and every tessel is CLIPPED TO THE SUPPORT - the region the molecules
% actually visited (cs_support_mask), which for an ER probe is the ER. So a tessel's area is cell
% area, its density is a real density, and the ring of tessels around a contact site is the ER
% around it, not the square around it.
%
%   'Mask' chooses that region: 'support' (default) derives it from the localizations. Pass your
%   own instead with opts.maskImage - a logical image on the density grid (grid x grid), e.g. an ER
%   segmentation resampled to it - and the tessels are clipped to that. With no ER channel the
%   support IS the ER for an ER probe, which is the case in this project (er_seg is empty).
%
% D PER TESSEL. Steps whose FIRST localization lies in the tessel, single-frame steps only (a step
% across a gap is not one step), pooled over every track that crossed it:
%   'lag1' (default) D = (<dr^2> - 4 sigma^2) / (4 dt)   the noise-corrected single-step estimator,
%                    the same one spt_track_diffusion uses per localization, floored at 0.
%   'cve'            D = <dx_n^2>/(2 dt) + <dx_n dx_{n+1}>/dt   averaged over x and y (Vestergaard
%                    et al. 2014): unbiased under localization noise AND motion blur, using the
%                    negative correlation the noise puts into consecutive steps. Needs step PAIRS,
%                    so it is noisier per tessel; prefer it when tessels are large.
% Both need sigma (opts.sigmaUm, default from the project calibration's precNm). A tessel with
% fewer than opts.minSteps steps gets D = NaN rather than a number made of nothing.
%
% opts: .minLocs (30) localizations per tessel (seeds = round(nLoc/minLocs))
%       .minSteps (20) steps a tessel needs before D is reported
%       .estimator ('lag1'|'cve')  .sigmaUm (project precNm, else 0.03)  .maskImage ([])
%       .cells (cellstr) .save (true) .verbose (true) .seed (0, for reproducible k-means)
%       .progress  f(frac, msg) called before each cell - a few seconds per cell is long enough
%                  that a window with no progress looks hung
%       .cancelled f() -> true to stop early. Nothing is saved when it does: half a diffusion map
%                  saved under the same name as a whole one is worse than no map.
%
% OUTPUT TS(k): file, nLoc, nTessels, centres [t x 2 um], D [t x 1 um^2/s], nLocs, nSteps,
%   areaUm2, density (locs/um^2), poly {t x 1} clipped polygons [p x 2 um] (NaN rows separate the
%   pieces when a clip leaves more than one, as polyshape writes them), locIdx/locTess (the
%   assignment, compactly: linear indices into a matrix page and the tessel of each), matrixSize,
%   supportFrac, and the settings used. Saved to analysis/CS_tessellation.mat.
%
% The mapper attaches each site's slice (Deff, TessIndex, refDeff, neighborDeff, DeffIn/DeffNear)
% when this has been run; without it those fields are NaN and nothing else changes.

mode = '';
if ~isempty(varargin) && ischar(varargin{1}) && any(strcmp(varargin{1}, {'load','cell'})), mode = varargin{1}; end
switch mode
    case 'load'
        varargout{1} = doLoad(varargin{2}); return;
    case 'cell'
        [varargout{1}, varargout{2}] = perCell(varargin{2:4}); return;
end

anaDir = varargin{1};
if numel(varargin) > 1 && isstruct(varargin{2}), opts = varargin{2}; else, opts = struct(); end
minLocs   = getf(opts, 'minLocs', 30);
minSteps  = getf(opts, 'minSteps', 20);
estimator = lower(getf(opts, 'estimator', 'lag1'));
maskImg   = getf(opts, 'maskImage', []);
doSave    = getf(opts, 'save', true);
onProg    = getf(opts, 'progress', []);
isCancel  = getf(opts, 'cancelled', []);
verb      = getf(opts, 'verbose', true);
seed      = getf(opts, 'seed', 0);
wantCells = getf(opts, 'cells', {});

tsPath = cs_active_trackstruct(anaDir);
assert(~isempty(tsPath) && isfile(tsPath), 'cs_tessellate:noTrackStruct', 'No TrackStruct build in %s', anaDir);
S = load(tsPath); fn = fieldnames(S); Tracks = S.(fn{1});
try, Tracks = cs_track_exclusions('blank', cs_track_exclusions('load', fileparts(regexprep(char(anaDir),'[\\/]+$',''))), Tracks); catch, end
[gridDef, SFdef] = cs_default_gridsf(anaDir);

TS = struct([]); nanFrac = [];
todo = 1:numel(Tracks);
if ~isempty(wantCells)
    todo = todo(arrayfun(@(i) ismember(cellBase(Tracks(i).file), wantCells), todo));
end
for q = 1:numel(todo)
    i = todo(q);
    [~, base] = fileparts(char(Tracks(i).file));
    if ~isempty(isCancel) && isCancel()
        if verb, fprintf('cs_tessellate: cancelled after %d of %d cells - nothing saved\n', q-1, numel(todo)); end
        varargout{1} = TS; return;
    end
    if ~isempty(onProg), onProg((q-1)/numel(todo), sprintf('%s (%d of %d)', base, q, numel(todo))); end
    M = Tracks(i).matrix;
    if isempty(M), continue; end
    X = M(:,:,2); Y = M(:,:,3); F = M(:,:,1);
    ok = isfinite(X) & isfinite(Y);
    if nnz(ok) < 2*minLocs, continue; end
    dt = getf2(Tracks(i), 'frameInterval', getf2(Tracks(i), 'dt', 0.02));
    sig = getf(opts, 'sigmaUm', calibSigma(Tracks(i)));
    [~, SF, grid] = cs_load_windows(anaDir, base, 1, gridDef, SFdef);

    % ---- the region the tessels must stay inside -------------------------------------------------
    [mask, mInfo] = regionMask(X(ok), Y(ok), SF, grid, maskImg);
    P = maskPoly(mask, SF);

    % ---- seeds on the localizations --------------------------------------------------------------
    xy = [X(ok) Y(ok)]; nLoc = size(xy, 1);
    k = max(1, round(nLoc / minLocs));
    rng(seed);
    if k == 1, lab = ones(nLoc,1); C = mean(xy,1);
    else
        ws = warning('off', 'stats:kmeans:FailedToConverge');   % tessel edges, not cluster identity
        [lab, C] = kmeans(xy, k, 'Start','plus', 'MaxIter',150, 'Replicates',1, 'EmptyAction','singleton');
        warning(ws);
    end

    % ---- steps: single-frame, assigned by the tessel of their FIRST localization -----------------
    labFull = nan(size(X)); labFull(ok) = lab;
    dx = diff(X,1,1); dy = diff(Y,1,1); df = diff(F,1,1);
    good = isfinite(dx) & isfinite(dy) & df == 1;
    sLab = labFull(1:end-1, :);
    g = good & isfinite(sLab);
    stepTess = sLab(g); dxs = dx(g); dys = dy(g);
    % second step of each consecutive pair (for 'cve'), NaN where the pair is broken
    dx2 = [dx(2:end,:); nan(1,size(dx,2))]; dy2 = [dy(2:end,:); nan(1,size(dy,2))];
    ok2 = [good(2:end,:); false(1,size(good,2))];
    dxs2 = dx2(g); dys2 = dy2(g); pairOK = ok2(g);

    nT = size(C,1);
    D = nan(nT,1); nStep = zeros(nT,1); nLocs = zeros(nT,1); areaUm2 = nan(nT,1); poly = cell(nT,1);
    for t = 1:nT
        m = stepTess == t; nStep(t) = nnz(m); nLocs(t) = nnz(lab == t);
        if nStep(t) >= minSteps
            if strcmp(estimator, 'cve')
                D(t) = cveD(dxs(m), dys(m), dxs2(m), dys2(m), pairOK(m), dt);
            else
                dr2 = dxs(m).^2 + dys(m).^2;
                D(t) = max(0, (mean(dr2) - 4*sig^2) / (4*dt));
            end
        end
    end

    % ---- polygons, clipped to the region ---------------------------------------------------------
    [poly, areaUm2] = clipCells(C, P, SF*grid);

    keep = nLocs > 0;
    e = struct('file', base, 'cellIndex', i, 'nLoc', nLoc, 'nTessels', nnz(keep), ...
        'centres', C(keep,:), 'D', D(keep), 'nLocs', nLocs(keep), 'nSteps', nStep(keep), ...
        'areaUm2', areaUm2(keep), 'density', nLocs(keep) ./ max(areaUm2(keep), eps), ...
        'poly', {poly(keep)}, 'matrixSize', size(X), ...
        'locIdx', uint32(find(ok)), 'locTess', uint16(relabel(lab, keep)), ...
        'minLocs', minLocs, 'minSteps', minSteps, 'estimator', estimator, 'sigmaUm', sig, 'dt', dt, ...
        'mask', mInfo.src, 'supportFrac', mInfo.frac, 'SF', SF, 'grid', grid);
    if isempty(TS), TS = e; else, TS(end+1) = e; end %#ok<AGROW>
    if verb
        fprintf('  %-46s %6d locs -> %4d tessels, median %d locs, D %.3f um^2/s (%d without enough steps)\n', ...
            base, nLoc, e.nTessels, median(e.nLocs), median(e.D, 'omitnan'), nnz(isnan(e.D)));
    end
    nanFrac(end+1) = mean(isnan(e.D)); %#ok<AGROW>
end

% Short tracks are the limit here, not the seeding: a tessel needs minSteps single-frame steps
% before it gets a D, and with a median track of a few dozen localizations most of a cell's steps
% are spread thin. Say so rather than returning a map that is half NaN without comment.
if ~isempty(nanFrac) && mean(nanFrac) > 0.2 && verb
    fprintf(['cs_tessellate: %.0f%% of tessels had fewer than %d single-frame steps and carry no D. ' ...
             'Raise minLocs (bigger tessels, coarser map) or lower minSteps (noisier D) - on data ' ...
             'with short tracks minLocs 60-100 typically leaves under 10%%.\n'], 100*mean(nanFrac), minSteps);
end
if ~isempty(onProg), onProg(1, 'done'); end
if doSave && ~isempty(TS)
    save(fullfile(anaDir, 'CS_tessellation.mat'), 'TS', '-v7.3');
    if verb, fprintf('cs_tessellate: %d cell(s) -> %s\n', numel(TS), fullfile(anaDir, 'CS_tessellation.mat')); end
end
varargout{1} = TS;
end

% =================================================================================================
function TS = doLoad(anaDir)
TS = [];
if isempty(anaDir), return; end
f = fullfile(char(anaDir), 'CS_tessellation.mat');
if ~isfile(f), return; end
try, L = load(f, 'TS'); TS = L.TS; catch, TS = []; end
end

function [D, idx] = perCell(TS, base, sz)
% per-localization tessel D and index for one cell, as full matrix-page arrays
D = nan(sz); idx = nan(sz);
if isempty(TS) || ~isstruct(TS), return; end
k = find(strcmp({TS.file}, char(base)), 1);
if isempty(k) || ~isequal(TS(k).matrixSize, sz), return; end
t = double(TS(k).locTess); keep = t > 0;
li = double(TS(k).locIdx);
idx(li(keep)) = t(keep);
D(li(keep)) = TS(k).D(t(keep));
end

function d = cveD(dx, dy, dx2, dy2, pairOK, dt)
% Vestergaard covariance estimator, per dimension, averaged
c = @(a, a2) mean(a.^2)/(2*dt) + mean(a(pairOK) .* a2(pairOK))/dt;
d = max(0, (c(dx, dx2) + c(dy, dy2)) / 2);
end

function [mask, info] = regionMask(x, y, SF, grid, maskImg)
% the region tessels are clipped to: a mask the caller supplies (an ER segmentation, say), else the
% support derived from the localizations themselves
if ~isempty(maskImg)
    mask = logical(maskImg);
    if ~isequal(size(mask), [grid grid]), mask = imresize(mask, [grid grid], 'nearest'); end
    info = struct('frac', mean(mask(:)), 'src', 'maskImage');
    return;
end
cnt = zeros(grid);
cx = round(x/SF); cy = round(y/SF);
in = cx >= 1 & cx <= grid & cy >= 1 & cy <= grid;
if any(in), cnt = accumarray([cy(in) cx(in)], 1, [grid grid]); end
[mask, info] = cs_support_mask(cnt);
info.src = 'support';
end

function P = maskPoly(mask, SF)
% mask -> polyshape in um (pixel c spans (c-0.5)*SF .. (c+0.5)*SF, matching round(x/SF))
B = bwboundaries(mask, 8, 'holes');
P = polyshape();
warnSt = warning('off', 'MATLAB:polyshape:repairedBySimplify');
for q = 1:numel(B)
    b = B{q};
    p = polyshape((b(:,2) - 0.5)*SF, (b(:,1) - 0.5)*SF, 'Simplify', true, 'KeepCollinearPoints', false);
    if q == 1, P = p; else, P = xor(P, p); end        % holes
end
warning(warnSt);
end

function [poly, areaUm2] = clipCells(C, P, fov)
% Voronoi cells of the seeds, clipped to the region. Four distant ghost seeds make every real cell
% bounded, so no region has to be closed by hand.
n = size(C,1); poly = cell(n,1); areaUm2 = nan(n,1);
if n == 1
    poly{1} = polyPoints(P); areaUm2(1) = area(P); return;
end
ghost = 50*fov*[-1 -1; -1 1; 1 -1; 1 1];
[V, R] = voronoin([C; ghost], {'Qbb','Qz'});
warnSt = warning('off', 'MATLAB:polyshape:repairedBySimplify');
for t = 1:n
    v = V(R{t}, :);
    if isempty(v) || any(~isfinite(v(:))), continue; end
    p = intersect(polyshape(v(:,1), v(:,2), 'Simplify', true), P);
    if p.NumRegions == 0, areaUm2(t) = 0; poly{t} = zeros(0,2); continue; end
    poly{t} = polyPoints(p); areaUm2(t) = area(p);
end
warning(warnSt);
end

function xy = polyPoints(p)
xy = p.Vertices;
if ~isempty(xy) && ~isequaln(xy(1,:), xy(end,:)), xy(end+1,:) = xy(1,:); end
end

function l = relabel(lab, keep)
% tessel numbers after dropping empty ones; 0 = dropped
map = zeros(numel(keep),1); map(keep) = 1:nnz(keep);
l = map(lab);
end

function s = calibSigma(T)
s = 0.030;
try
    c = T.calib;
    if isfield(c,'precNm') && ~isempty(c.precNm) && isfinite(c.precNm), s = c.precNm/1000; end
catch
end
end

function b = cellBase(f), [~, b] = fileparts(char(f)); end

function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
function v = getf2(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
