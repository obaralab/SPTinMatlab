function idx = cs_radial_plot(ax, Xrel, Yrel, Rwin, pctInside, refined, erNull)
%CS_RADIAL_PLOT  Local-density profile: localization COUNT within a circle of radius r.
%
%   idx = cs_radial_plot(ax, Xrel, Yrel, Rwin, pctInside, refined, erNull)
%
%   Draws, on axes AX, how many localizations fall within a circle of radius r of the site
%   centre, for growing r — i.e. concentric circles of different radii and the number of
%   localizations each encloses. A curve that rises steeply near the centre and then flattens,
%   sitting well ABOVE the dashed uniform-density expectation, is a real, compact site; a curve
%   that tracks the dashed line is diffuse (localizations just accumulate with area, as random).
%
%   Xrel, Yrel : localization coordinates in um, RELATIVE to the site centre (centre = 0,0).
%                Pass ALL localizations in the local region so the background is represented.
%   Rwin       : outer window radius in um (localizations beyond it are ignored).
%   pctInside  : (optional) % of the WHOLE cell's localizations inside the refined boundary,
%                annotated in the title. Pass [] or NaN to omit.
%   refined    : (optional, default true) is the centre the user-refined centre (true) or the
%                auto-detected pick centre (false) — labels the x axis so the profile is not
%                mistaken for a refined result before a boundary is drawn.
%   erNull     : (optional) struct that REPLACES the disk-uniform null with a CELL-WIDE
%                ER-uniform null — "what if the localizations were spread uniformly over ALL the
%                cell's ER at the cell-average density?". Fields:
%                  .r    ascending radii (um), spanning 0..>=Rwin
%                  .Acum ER area (um^2) within each .r of the site centre (from the cell ER mask)
%                  .rho  cell-wide localization density over ER (locs per um^2) = N_onER / A_ER_cell
%                Then ref(r) = rho * interp1(.r,.Acum,r). Omit / [] -> the legacy disk-uniform
%                null n*(r/Rwin)^2 (density read from the local field of view).
%
%   Returns IDX = concentration index = max over r of (observed count − null count) / n, where the
%   null is the ER-uniform expectation when erNull is given (else the disk-uniform (r/Rwin)^2).
%   0 = tracks the null (diffuse); ->1 = tightly central; <0 = below the cell-wide ER background.
%
%   Shared by the freehand refiner (drivers/cs_refine.m) and CS Results (gui/spt_pipeline_app.m).

    idx = 0;
    if nargin < 5, pctInside = NaN; end
    if nargin < 6, refined = true; end
    if nargin < 7, erNull = []; end
    if isempty(ax) || ~isgraphics(ax), return; end
    if ~(isscalar(Rwin) && isfinite(Rwin) && Rwin > 0), Rwin = 1.2; end

    d = hypot(Xrel(:), Yrel(:));
    d = sort(d(isfinite(d) & d <= Rwin));
    n = numel(d);

    cla(ax);
    ctrWord = 'auto-detected'; if refined, ctrWord = 'refined'; end
    if n < 3
        title(ax, 'local density — too few localizations in view', 'FontSize', 9);
        xlabel(ax, sprintf('radius from %s centre (nm)', ctrWord), 'FontSize', 9);
        ax.XTick = []; ax.YTick = []; return;
    end

    rn  = d * 1000;                          % radius of each enclosing circle, nm
    Nr  = (1:n)';                            % localizations within that radius (cumulative count)
    useER = isstruct(erNull) && all(isfield(erNull,{'r','Acum','rho'})) ...
            && numel(erNull.r) >= 2 && isfinite(erNull.rho);
    if useER
        ref = erNull.rho * max(interp1(erNull.r(:), erNull.Acum(:), d, 'linear', 'extrap'), 0);
        refWord = 'uniform over ER (cell density)';
    else
        ref = n * (d / Rwin).^2;             % uniform-density expectation: count grows with disk area
        refWord = 'uniform (random)';
    end
    idx = max(Nr - ref) / max(n,1);          % peak excess over the null, as a fraction of observed total

    hold(ax, 'on');
    area(ax, rn, Nr, 'FaceColor',[0.20 0.45 0.70], 'FaceAlpha',0.15, 'EdgeColor','none', 'HitTest','off');
    hRef = plot(ax, rn, ref, '--', 'Color',[0.55 0.57 0.60], 'LineWidth',1);       % uniform-density expectation
    hObs = plot(ax, rn, Nr,  '-',  'Color',[0.13 0.40 0.66], 'LineWidth',1.8);     % localizations within r (observed)
    hold(ax, 'off');
    % legend so the dashed line is self-explanatory: it is what a spatially-uniform density would
    % enclose at each radius (over ER, cell-wide, when erNull is given); solid above it = concentration
    try, legend([hObs hRef], {'observed', refWord}, 'Location','northwest', ...
            'FontSize',7, 'Box','off', 'TextColor',[0.3 0.33 0.4]); catch, end

    box(ax, 'on'); grid(ax, 'on');
    xlim(ax, [0 Rwin*1000]); ylim(ax, [0 max([n; ref(:)])*1.05]);   % keep the null line visible even if it exceeds n
    ax.FontSize = 8;
    xlabel(ax, sprintf('radius from %s centre (nm)', ctrWord), 'FontSize', 9);
    ylabel(ax, 'localizations within radius', 'FontSize', 9);

    ttl = sprintf('local density \\cdot concentration %.2f', idx);
    if ~isempty(pctInside) && isfinite(pctInside)
        ttl = sprintf('%s \\cdot %.1f%% of cell inside', ttl, pctInside);
    end
    title(ax, ttl, 'FontSize', 9);
end
