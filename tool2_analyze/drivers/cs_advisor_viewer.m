function fig = cs_advisor_viewer(folder, opts)
%CS_ADVISOR_VIEWER  Browse a folder in the lab's ContactSites layout - the published VAPB dataset, or
%an advisor_format/<condition>/ folder written by the Export - cell by cell and site by site.
%
%   cs_advisor_viewer                 asks for the folder
%   cs_advisor_viewer(folder)
%   fig = cs_advisor_viewer(folder, struct('Visible','off'))    headless (tests)
%
% Reads CS_final*.mat (CS), *_Tracks_final*.mat (Tracks), and when present *_EC.mat (EC),
% BindingInfo.mat and imaging_settings.csv. Nothing is written.
%
% For the selected site it draws what the original analysis measured on it: the localization
% density of the cell around the site, the refined outline (refboundary, nm about refCenter), the
% 1.024 um neighbourhood square (boundaries, centred on the original pick), the EllipseFit (stored
% in the refiner's 3 nm pixels, pixel 400 = the pick), the member tracks, and their localizations
% inside the outline (CSLocIDs) and in the square outside it (CSneighborIDs). Below, each member
% track's distance from refCenter against time - the view the original DwellTimeManual.m annotated
% on - with bound intervals shaded where the site has been annotated.
%
% The frame interval comes from imaging_settings.csv when the folder has one. The VAPB folder has
% none; its scripts hard-code 0.011 s, which is the default here. It is editable either way.
%
% fig.UserData (tests): .data  .selectCell(c)  .selectSite(k)  .state()

if nargin < 2 || ~isstruct(opts), opts = struct(); end
if nargin < 1 || isempty(folder)
    folder = uigetdir(pwd, 'Pick a ContactSites folder (CS_final*.mat + *_Tracks_final*.mat)');
    if isequal(folder, 0), fig = []; return; end
end
D = loadFolder(folder);

vis = 'on'; if isfield(opts,'Visible'), vis = opts.Visible; end
fig = uifigure('Name', ['ContactSites · ' D.label], 'Position', [60 60 1480 900], 'Visible', vis);
g = uigridlayout(fig, [2 1], 'RowHeight', {30, '1x'}, 'Padding', [8 8 8 8], 'RowSpacing', 6);

% ---- top row -------------------------------------------------------------------------------------
tr = uigridlayout(g, [1 5], 'ColumnWidth', {130, '1x', 110, 70, 150}, 'Padding', [0 0 0 0], 'ColumnSpacing', 6);
uibutton(tr, 'Text', '📂 Open folder…', 'ButtonPushedFcn', @(s,e) reopen());
lblTop = uilabel(tr, 'Text', topText(), 'FontColor', [0.2 0.4 0.5]);
uilabel(tr, 'Text', 'frame interval s', 'HorizontalAlignment', 'right');
eDt = uieditfield(tr, 'numeric', 'Value', D.dt, 'Limits', [1e-5 10], 'ValueDisplayFormat', '%.5g', ...
    'Tooltip', dtTip(), 'ValueChangedFcn', @(s,e) drawSite());
lblDtSrc = uilabel(tr, 'Text', D.dtSrc, 'FontColor', [0.45 0.45 0.5]);

% ---- main ----------------------------------------------------------------------------------------
mn = uigridlayout(g, [1 3], 'ColumnWidth', {450, '1x', 330}, 'Padding', [0 0 0 0], 'ColumnSpacing', 8);
lc = uigridlayout(mn, [4 1], 'RowHeight', {18, '0.9x', 18, '1.4x'}, 'Padding', [0 0 0 0], 'RowSpacing', 4);
uilabel(lc, 'Text', 'Cells', 'FontWeight', 'bold');
tCells = uitable(lc, 'ColumnName', {'#','cell','mito','other','enrich'}, 'ColumnWidth', {32, 'auto', 44, 52, 58}, ...
    'RowName', {}, 'SelectionType', 'row', 'Multiselect', 'off', 'SelectionChangedFcn', @(s,e) onCell(e), ...
    'Tooltip', ['mito / other = contact sites by MitoFlag. enrich = MitoEnrichCoeff: (localizations ' ...
                'in mito sites / all) / (localizations in other sites / all), as in the published sheet.']);
lblSites = uilabel(lc, 'Text', 'Sites', 'FontWeight', 'bold');
tSites = uitable(lc, 'ColumnName', {'CS','csID','mito','trk','in','out','µm²','axes nm','bound'}, ...
    'ColumnWidth', {38, 44, 44, 34, 44, 40, 50, 76, 52}, 'RowName', {}, 'SelectionType', 'row', ...
    'Multiselect', 'off', 'SelectionChangedFcn', @(s,e) onSite(e), ...
    'Tooltip', ['CS = CS_index (global). trk = member tracks. in = localizations inside the outline ' ...
                '(refLocIDs); out = in the square but outside it (neighborIDs). µm² = outline area. ' ...
                'axes = EllipseFit major x minor, nm. bound = annotated bound tracks (— = not annotated).']);

cc = uigridlayout(mn, [2 1], 'RowHeight', {'2.2x', '1x'}, 'Padding', [0 0 0 0], 'RowSpacing', 6);
ax = uiaxes(cc); ax.Toolbar.Visible = 'off'; spt_axes_policy(ax);
axRT = uiaxes(cc); axRT.Toolbar.Visible = 'off'; spt_axes_policy(axRT);

rc = uigridlayout(mn, [9 1], 'RowHeight', {18, '1x', 22, 22, 22, 22, 22, 22, 150}, 'Padding', [0 0 0 0], 'RowSpacing', 4);
uilabel(rc, 'Text', 'Member tracks — click one', 'FontWeight', 'bold');
tTrk = uitable(rc, 'ColumnName', {'track','locs','in','% in','bound','dwell s'}, ...
    'ColumnWidth', {52, 44, 40, 46, 52, 'auto'}, 'RowName', {}, 'SelectionType', 'row', ...
    'Multiselect', 'off', 'SelectionChangedFcn', @(s,e) onTrack(e), ...
    'Tooltip', ['track = column of Tracks(cell).matrix. locs = its localizations; in = of them inside ' ...
                'the outline. bound / dwell = the hand annotation (BindingInfo / CS.DwellTimes), if any.']);
chk.dens = uicheckbox(rc, 'Text', 'density', 'Value', true, 'ValueChangedFcn', @(s,e) drawSite());
chk.trk  = uicheckbox(rc, 'Text', 'member tracks', 'Value', true, 'ValueChangedFcn', @(s,e) drawSite());
chk.pts  = uicheckbox(rc, 'Text', 'inside (red) / neighbour (cyan) localizations', 'Value', true, 'ValueChangedFcn', @(s,e) drawSite());
chk.box  = uicheckbox(rc, 'Text', 'neighbourhood square + pick', 'Value', true, 'ValueChangedFcn', @(s,e) drawSite());
chk.ell  = uicheckbox(rc, 'Text', 'EllipseFit', 'Value', true, 'ValueChangedFcn', @(s,e) drawSite());
chk.deff = uicheckbox(rc, 'Text', 'colour localizations by Deff', 'Value', false, 'ValueChangedFcn', @(s,e) drawSite(), ...
    'Tooltip', 'The JBM tessellation diffusion coefficient per localization - present in the published dataset, empty in exports.');
lblInfo = uilabel(rc, 'Text', '', 'WordWrap', 'on', 'VerticalAlignment', 'top', 'FontColor', [0.3 0.3 0.4]);

st = struct('cell', 0, 'site', 0, 'track', 0);
fillCells();
if D.nCells > 0, selectCell(1); end
fig.UserData = struct('data', D, 'selectCell', @selectCell, 'selectSite', @selectSite, ...
                      'selectTrack', @selectTrack, 'state', @stateNow);   % nested: an anonymous @() st would freeze st

% =================================================================================================
    function v = stateNow(), v = st; end

    function reopen()
        f = uigetdir(D.folder, 'Pick a ContactSites folder');
        if isequal(f, 0), return; end
        try, D = loadFolder(f); catch ME, uialert(fig, ME.message, 'Could not open'); return; end
        fig.Name = ['ContactSites · ' D.label]; lblTop.Text = topText();
        eDt.Value = D.dt; eDt.Tooltip = dtTip(); lblDtSrc.Text = D.dtSrc;
        st = struct('cell', 0, 'site', 0, 'track', 0);
        fillCells(); if D.nCells > 0, selectCell(1); end
        fig.UserData.data = D;
    end

    function t = topText()
        t = sprintf('%s  ·  %d cells · %d sites (%d mito, %d other)%s', D.folder, D.nCells, numel(D.CS), ...
            nnz([D.CS.MitoFlag]), nnz(~[D.CS.MitoFlag]), tern(D.nAnnot > 0, sprintf(' · %d annotated for binding', D.nAnnot), ''));
    end
    function t = dtTip()
        t = ['Seconds per frame, for the time axis and dwell times. ' D.dtSrc '. The original scripts ' ...
             'hard-code 0.011 s; data acquired otherwise needs its own value.'];
    end

    function fillCells()
        n = D.nCells; C = cell(n, 5);
        for c = 1:n
            fl = [D.CS(D.sitesOf{c}).MitoFlag];
            C(c,:) = {c, D.cellName{c}, nnz(fl), nnz(~fl), fmt(D.enrich(c), '%.3g')};
        end
        tCells.Data = C;
    end

    function onCell(e)
        try, r = e.Selection(1); catch, return; end
        if ~isempty(r), selectCell(r); end
    end
    function selectCell(c)
        if c < 1 || c > D.nCells, return; end
        st.cell = c; try, tCells.Selection = c; catch, end
        ks = D.sitesOf{c}; C = cell(numel(ks), 9);
        for q = 1:numel(ks)
            s = D.CS(ks(q));
            ef = s.EllipseFit; ax_ = '—';
            if isstruct(ef) && isfield(ef,'MajorAxisLength') && ~isempty(ef.MajorAxisLength) && isfinite(ef.MajorAxisLength)
                ax_ = sprintf('%.0f×%.0f', 3*ef.MajorAxisLength, 3*ef.MinorAxisLength);
            end
            C(q,:) = {s.CS_index, s.csID, tern(s.MitoFlag, 'mito', ''), numel(s.tracks), numel(s.refLocIDs), ...
                      numel(s.neighborIDs), sprintf('%.3f', polyarea(s.refboundary(:,1), s.refboundary(:,2))/1e6), ...
                      ax_, boundTxt(s)};
        end
        tSites.Data = C;
        lblSites.Text = sprintf('Sites in %s (%d)', D.cellName{c}, numel(ks));
        if ~isempty(ks), selectSite(ks(1)); else, st.site = 0; cla(ax); cla(axRT); tTrk.Data = {}; end
    end

    function onSite(e)
        try, r = e.Selection(1); catch, return; end
        ks = D.sitesOf{st.cell};
        if ~isempty(r) && r <= numel(ks), selectSite(ks(r)); end
    end
    function selectSite(k)
        if k < 1 || k > numel(D.CS), return; end
        if D.CS(k).cellIndex ~= st.cell, st.cell = D.CS(k).cellIndex; selectCell(st.cell); end
        st.site = k; st.track = 0;
        r = find(D.sitesOf{st.cell} == k, 1); try, tSites.Selection = r; catch, end
        fillTracks(); drawSite();
    end

    function fillTracks()
        s = D.CS(st.site); n = numel(s.tracks);
        [~, nIn] = insideByTrack(s);
        C = cell(n, 6);
        for j = 1:n
            nl = nnz(isfinite(s.CSmatrix(:,j,2)));
            [nb, dw] = bindingOf(s, j);
            C(j,:) = {s.tracks(j), nl, nIn(j), sprintf('%.0f', 100*nIn(j)/max(nl,1)), nb, dw};
        end
        tTrk.Data = C;
    end

    function onTrack(e)
        try, r = e.Selection(1); catch, return; end
        if ~isempty(r), selectTrack(r); end
    end
    function selectTrack(j)
        st.track = j; drawSite();
    end

    % ---- drawing -------------------------------------------------------------------------------
    function drawSite()
        if st.site < 1, return; end
        s = D.CS(st.site); T = D.Tracks(s.cellIndex);
        rcn = s.refCenter(:)';
        pick = [mean(s.boundaries.x) mean(s.boundaries.y)];          % the square is centred on the pick
        % Frame the square AND the outline: an outline drawn larger than the 1.024 um square (half the
        % sites in some datasets) would otherwise run off the view.
        ob = s.refboundary/1000 + rcn;
        lo = [min([s.boundaries.x(:); ob(:,1)]) min([s.boundaries.y(:); ob(:,2)])];
        hi = [max([s.boundaries.x(:); ob(:,1)]) max([s.boundaries.y(:); ob(:,2)])];
        half = max([0.8, (hi - lo)/2 + 0.2]); mid = (lo + hi)/2;
        xl = mid(1) + [-half half]; yl = mid(2) + [-half half];
        cla(ax); hold(ax, 'on');
        A = T.matrix(:,:,2); B = T.matrix(:,:,3);
        if chk.dens.Value
            inV = isfinite(A) & A >= xl(1) & A <= xl(2) & B >= yl(1) & B <= yl(2);
            e = 0.030; ex = xl(1):e:xl(2); ey = yl(1):e:yl(2);
            H = histcounts2(B(inV), A(inV), ey, ex);
            H = imgaussfilt(H, 1.5);
            imagesc(ax, ex(1:end-1) + e/2, ey(1:end-1) + e/2, H); colormap(ax, turbo);
        end
        if chk.trk.Value
            for j = 1:numel(s.tracks)
                x = s.CSmatrix(:,j,2) + rcn(1); y = s.CSmatrix(:,j,3) + rcn(2); ok = isfinite(x);
                if j == st.track, clr = [1 1 1]; lw = 2; else, clr = [1 0.95 0.4 0.6]; lw = 0.6; end
                plot(ax, x(ok), y(ok), '-', 'Color', clr, 'LineWidth', lw, 'HitTest', 'off');
            end
        end
        if chk.pts.Value
            X = s.CSmatrix(:,:,2) + rcn(1); Y = s.CSmatrix(:,:,3) + rcn(2);
            deffOn = chk.deff.Value && any(isfinite(s.Deff(:)));
            if deffOn
                idx = [s.CSLocIDs(:); s.CSneighborIDs(:)];
                scatter(ax, X(idx), Y(idx), 12, s.Deff(idx), 'filled', 'HitTest', 'off');
                colorbar(ax); spt_axes_policy(ax);   % a colorbar silently switches scroll-zoom off
            else
                scatter(ax, X(s.CSLocIDs), Y(s.CSLocIDs), 8, [1 0.2 0.2], 'filled', 'HitTest', 'off');
                scatter(ax, X(s.CSneighborIDs), Y(s.CSneighborIDs), 8, [0.3 0.9 1], 'filled', 'HitTest', 'off');
            end
        end
        if chk.box.Value
            bx = s.boundaries.x; by = s.boundaries.y;
            plot(ax, bx([1 2 2 1 1]), by([1 1 2 2 1]), '--', 'Color', [1 1 1 0.8], 'LineWidth', 1, 'HitTest', 'off');
            plot(ax, pick(1), pick(2), 'x', 'Color', [1 1 1], 'MarkerSize', 10, 'LineWidth', 1.5, 'HitTest', 'off');
        end
        plot(ax, ob(:,1), ob(:,2), '-', 'Color', [1 1 1], 'LineWidth', 1.8, 'HitTest', 'off');
        if chk.ell.Value, drawEllipse(s.EllipseFit, pick); end
        plot(ax, rcn(1), rcn(2), '+', 'Color', [1 0 1], 'MarkerSize', 13, 'LineWidth', 1.6, 'HitTest', 'off');
        hold(ax, 'off');
        if ~(chk.pts.Value && chk.deff.Value && any(isfinite(s.Deff(:)))), colorbar(ax, 'off'); end
        ax.YDir = 'reverse'; axis(ax, 'equal'); xlim(ax, xl); ylim(ax, yl);
        xlabel(ax, 'x (µm)'); ylabel(ax, 'y (µm)');
        title(ax, sprintf('%s · CS %d (csID %d) · %s', D.cellName{s.cellIndex}, s.CS_index, s.csID, ...
            tern(s.MitoFlag, 'mito', 'other')), 'Interpreter', 'none');
        drawRT(s);
        [inN, ~] = insideByTrack(s);
        ef = s.EllipseFit; efT = 'no EllipseFit';
        if isstruct(ef) && isfield(ef,'MajorAxisLength') && ~isempty(ef.MajorAxisLength) && isfinite(ef.MajorAxisLength)
            efT = sprintf('EllipseFit %.0f × %.0f nm at %.0f°', 3*ef.MajorAxisLength, 3*ef.MinorAxisLength, ef.Orientation);
        end
        lblInfo.Text = sprintf(['refCenter (%.3f, %.3f) µm · pick (%.3f, %.3f) µm\noutline area %.3f µm² · %s\n' ...
            '%d member tracks · %d localizations inside (refLocIDs) · %d neighbours (neighborIDs) · %d in the square (LocIDs)\n%s'], ...
            rcn, pick, polyarea(s.refboundary(:,1), s.refboundary(:,2))/1e6, efT, numel(s.tracks), inN, ...
            numel(s.neighborIDs), numel(s.LocIDs), tern(any(isfinite(s.Deff(:))), ...
            sprintf('median Deff inside %.3g, neighbours %.3g', median(s.refDeff,'omitnan'), median(s.neighborDeff,'omitnan')), ...
            'Deff not measured (JBM)'));
    end

    function drawEllipse(ef, pick)
        % CS_refiner_v2_wacom.m: regionprops in the refiner's image - 3 nm pixels, pixel 400 = the pick,
        % image rows running with +y. Orientation is regionprops' angle (counter-clockwise on screen,
        % rows downward), so the major axis points along (cos, -sin) in (x, y).
        if ~isstruct(ef) || ~isfield(ef,'MajorAxisLength') || isempty(ef.MajorAxisLength) || ~isfinite(ef.MajorAxisLength), return; end
        c0 = pick + (ef.Centroid - 400) * 0.003;
        a = 0.003*ef.MajorAxisLength/2; b = 0.003*ef.MinorAxisLength/2; th = deg2rad(ef.Orientation);
        t = linspace(0, 2*pi, 90);
        u = [cos(th), -sin(th)]; v = [sin(th), cos(th)];
        P = c0 + (a*cos(t))'*u + (b*sin(t))'*v;
        plot(ax, P(:,1), P(:,2), ':', 'Color', [1 0.6 1], 'LineWidth', 1.4, 'HitTest', 'off');
    end

    function drawRT(s)
        % Distance of each member track from refCenter against time - the original's second figure.
        cla(axRT); hold(axRT, 'on');
        dt = eDt.Value;
        for j = 1:numel(s.tracks)
            t = s.CSmatrix(:,j,1) * dt; r = hypot(s.CSmatrix(:,j,2), s.CSmatrix(:,j,3)); ok = isfinite(r);
            if j == st.track, clr = [0.85 0.1 0.1]; lw = 1.8; else, clr = [0.5 0.5 0.6 0.5]; lw = 0.7; end
            plot(axRT, t(ok), r(ok), '-', 'Color', clr, 'LineWidth', lw, 'HitTest', 'off');
        end
        if st.track > 0
            dT = dwellOf(s, st.track);
            for q = 1:size(dT, 1)
                yl_ = axRT.YLim;
                patch(axRT, [dT(q,1) dT(q,2) dT(q,2) dT(q,1)], [yl_(1) yl_(1) yl_(2) yl_(2)], [0.9 0.3 0.3], ...
                    'FaceAlpha', 0.15, 'EdgeColor', 'none', 'HitTest', 'off');
            end
        end
        yline(axRT, 0, ':', 'HitTest', 'off');
        hold(axRT, 'off');
        xlabel(axRT, sprintf('time (s) — %.4g s/frame', dt)); ylabel(axRT, 'distance from refCenter (µm)');
        if st.track > 0 && st.track <= numel(s.tracks)
            title(axRT, sprintf('track %d highlighted', s.tracks(st.track)));
        else
            title(axRT, 'all member tracks');
        end
    end

    % ---- per-site helpers ------------------------------------------------------------------------
    function [nTot, nIn] = insideByTrack(s)
        % CSLocIDs index the tracks' own M x N space: the column is the member track.
        nIn = zeros(1, numel(s.tracks)); nTot = numel(s.CSLocIDs);
        if isempty(s.CSLocIDs), return; end
        [~, col] = ind2sub(size(s.CSmatrix(:,:,1)), s.CSLocIDs);
        nIn = accumarray(col(:), 1, [numel(s.tracks) 1])';
    end

    function t = boundTxt(s)
        if isempty(s.trackBinding), t = '—'; else, t = sprintf('%d', nnz(s.trackBinding)); end
    end

    function [nb, dw] = bindingOf(s, j)
        nb = '—'; dw = '';
        if isempty(s.trackBinding) || j > numel(s.trackBinding), return; end
        nb = sprintf('%d', s.trackBinding(j));
        d = dwellOf(s, j);
        if ~isempty(d), dw = strjoin(arrayfun(@(x) sprintf('%.2f', x), d(:,2) - d(:,1), 'uni', 0), ', '); end
    end

    function d = dwellOf(s, j)
        % Entry/exit times as annotated: EntryPts / ExitPts x = seconds on the time axis the
        % annotation was made on. Not rescaled - the README tells whoever annotates to set that axis
        % to the data's own frame interval first, and on the VAPB data it is 0.011 s either way.
        d = zeros(0, 2);
        if isempty(s.DwellTimes) || ~isstruct(s.DwellTimes) || j > numel(s.DwellTimes), return; end
        w = s.DwellTimes(j);
        if ~isfield(w, 'EntryPts') || isempty(w.EntryPts), return; end
        d = [w.EntryPts(:,1) w.ExitPts(:,1)];
    end
end

% =================================================================================================
function D = loadFolder(folder)
folder = char(folder);
f = @(pat) pickFile(folder, pat);
fc = f('CS_final*.mat'); ft = f('*_Tracks_final*.mat');
assert(~isempty(fc) && ~isempty(ft), 'cs_advisor_viewer:notAFolder', ...
    '%s does not hold CS_final*.mat and *_Tracks_final*.mat', folder);
L = load(fc); D.CS = L.CS;
L = load(ft); D.Tracks = L.Tracks;
D.EC = []; fe = f('*_EC.mat'); if ~isempty(fe), L = load(fe); D.EC = L.EC; end
D.folder = folder;
[~, D.label] = fileparts(folder);
D.nCells = numel(D.Tracks);
D.cellName = arrayfun(@(t) regexprep(char(t.file), '_Tracks$', ''), D.Tracks, 'uni', 0);
D.sitesOf = arrayfun(@(c) find([D.CS.cellIndex] == c), 1:D.nCells, 'uni', 0);
D.nAnnot = nnz(arrayfun(@(s) ~isempty(s.trackBinding), D.CS));
% MitoEnrichCoeff per cell, as the published EnrichmentByCell sheet computes it
D.enrich = nan(1, D.nCells);
for c = 1:D.nCells
    ks = D.sitesOf{c}; fl = [D.CS(ks).MitoFlag];
    ms = sum(arrayfun(@(k) numel(D.CS(k).refLocIDs), ks(fl)));
    os = sum(arrayfun(@(k) numel(D.CS(k).refLocIDs), ks(~fl)));
    if os > 0, D.enrich(c) = ms / os; end                  % (ms/total)/(os/total)
end
% frame interval: this folder's own record, else the original scripts' constant
D.dt = 0.011; D.dtSrc = 'not recorded here - 0.011 s, the original scripts'' constant';
fi = fullfile(folder, 'imaging_settings.csv');
if isfile(fi)
    try
        I = readtable(fi);
        v = I.frame_interval_s(isfinite(I.frame_interval_s));
        if ~isempty(v), D.dt = median(v); D.dtSrc = 'from imaging_settings.csv'; end
    catch
    end
end
end

function p = pickFile(folder, pat)
d = dir(fullfile(folder, pat)); p = '';
if ~isempty(d), p = fullfile(d(1).folder, d(1).name); end
end

function s = fmt(v, f), if isfinite(v), s = sprintf(f, v); else, s = ''; end, end
function y = tern(c, a, b), if c, y = a; else, y = b; end, end
