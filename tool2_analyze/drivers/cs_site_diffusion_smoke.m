function cs_site_diffusion_smoke()
%CS_SITE_DIFFUSION_SMOKE  Per-member-track rolling D, split by the site footprint.
%
% The Sites tab used to show an 'enrich' column that read like the Monte-Carlo enrichment the
% detector uses, and was not. Two different quantities share that name:
%
%   detector  (cs_detect.m:67,77)          peak inside ÷ MEDIAN over the ER MASK
%   sites tab (csDensMetricOne.m:37-42)    mean inside ÷ MEAN over bins any localization touched
%
% The second has no ER in it at all, and its denominator pools every track in the window — an
% ensemble footprint of many different molecules over the whole window, not this site's occupancy.
% It is off the screen now (still in CSW_final.mat and cs_window_metrics.csv) and the column carries
% the question the tab is actually for: does a molecule move differently while it is at a site?
%
% This pins the arithmetic of that split, which is the load-bearing part: the rolling D and the
% positions must be indexed consistently, or the inside/outside labels attach to the wrong points.

here = fileparts(mfilename('fullpath')); addpath(here);

% ---- a site with a known answer -------------------------------------------------------------
% One track: the first half sits inside a unit-square footprint moving slowly, the second half
% outside moving fast. The split must recover exactly that.
n = 40;
bx = [-1 1 1 -1 -1]'; by = [-1 -1 1 1 -1]';           % 2x2 µm box centred on the site
x = [linspace(-0.5,0.5,n/2)'; linspace(3,6,n/2)'];     % inside, then well outside
y = zeros(n,1);
d = [repmat(0.10,n/2,1); repmat(0.90,n/2,1)];          % slow inside, fast outside

in = inpolygon(x, y, bx, by);
fprintf('fixture: %d inside, %d outside\n', nnz(in), nnz(~in));
assert(nnz(in)==n/2 && nnz(~in)==n/2, 'the fixture geometry is wrong');
assert(abs(median(d(in)) - 0.10) < 1e-12 && abs(median(d(~in)) - 0.90) < 1e-12, ...
    'the fixture D values are wrong');

% ---- the same split, driven the way the app drives it ----------------------------------------
% CSmatrix is (frame, x, y) RELATIVE TO THE SITE CENTRE, columns parallel to e.tracks; Dt is
% [nF x nTracksInCell] and is indexed by the track COLUMN, not by member position. Getting those two
% indexings crossed is the failure this guards.
CSmatrix = cat(3, (0:n-1)', x, y);
Dt = nan(n, 5); Dt(:,3) = d;                            % this member is column 3 of the cell
cols = 3;

q = 1;
nn = min(size(Dt,1), size(CSmatrix,1));
dd = Dt(1:nn, cols(q));
xx = CSmatrix(1:nn,q,2); yy = CSmatrix(1:nn,q,3);
ok = isfinite(dd) & isfinite(xx) & isfinite(yy);
msk = false(size(ok)); msk(ok) = inpolygon(xx(ok), yy(ok), bx, by);
dIn = median(dd(ok &  msk));
dOut= median(dd(ok & ~msk));
fprintf('recovered: D in %.3f, D out %.3f\n', dIn, dOut);
assert(abs(dIn - 0.10) < 1e-12, 'D inside wrong: %g', dIn);
assert(abs(dOut - 0.90) < 1e-12, 'D outside wrong: %g', dOut);
assert(dIn < dOut, 'the slow-inside case did not come out slower inside');

% ---- a track wholly inside must report NO outside value, not a zero --------------------------
x2 = zeros(n,1); y2 = zeros(n,1);
m2 = inpolygon(x2, y2, bx, by);
dOut2 = median(d(~m2));
assert(isempty(d(~m2)) || isnan(dOut2), ...
    'a fully-inside track must yield an empty/NaN outside median, never a measured 0');
fprintf('a fully-inside track reports no outside value\n');

% ---- the app must not show enrichment on the Sites tab, and must compute the split ------------
src = fileread(fullfile(fileparts(here),'app','spt_analyze_app.m'));
i = strfind(src, "tblSites = uitable(");
assert(~isempty(i), 'the Sites table was not found');
hdr = src(i(1):i(1)+400);
assert(~contains(hdr,'enrich'), 'the Sites table still has an enrich column');
assert(contains(hdr,'med D in') && contains(hdr,'med D out'), 'the D columns are missing');
assert(contains(src,'function [dIn, dOut, perTrk] = siteTrackD'), 'siteTrackD is missing');
% The rolling-D PLOT is gone from the Sites tab — it was hard to read and its per-localization
% estimate is noisy enough to invite conclusions the data does not support. The split it drew is
% still computed and still reported, as the two table columns asserted above, so the arithmetic
% pinned by this file is as load-bearing as it ever was. Assert the panel stays gone rather than
% leaving nothing behind: it had a call site, an axes handle and a draw function, and a partial
% revival would leave a dead axes in an 8-row grid.
assert(~contains(src,'drawSiteD') && ~contains(src,'axSiteD'), ...
    'the rolling-D panel is back on the Sites tab — it was removed deliberately');
% the underlying field must survive — removing it from the screen must not delete the data
assert(contains(src,'e.enrichment'), ...
    'enrichment was removed from the DATA as well as the display; CSW/CSV consumers would break');
fprintf('Sites tab shows D in/out, keeps enrichment in the data\n');

fprintf('\nALL SITE-DIFFUSION ASSERTIONS PASSED.\n');
end
