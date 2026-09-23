function info = cs_engage_plot(ax, e, opts)
%CS_ENGAGE_PLOT  Distance from the contact-site centre against time, with each engagement marked -
%the plot the VAPB dwell times were read off (Obara et al., Nature 626:169, Fig. 2c).
%
%   info = cs_engage_plot(ax, e)
%   info = cs_engage_plot(ax, e, opts)
%
% e is one site-window record from cs_window_mapper (CSW): it carries the member tracks already
% re-centred on the site (CSmatrix), the outline, the frame interval and the window. Each member
% track becomes one coloured trace of r(t) = its distance from the centre; a molecule that engages
% falls to the dashed zero line, stays, and leaves. Every detected engagement is bracketed by two
% dotted verticals and labelled with its dwell time, as the paper's figure does.
%
% opts
%   .tracks     which member tracks (indices into e.tracks); default all
%   .highlight  one of them to draw thick and in colour, the rest grey - the reading view for a
%               single track, which is how the annotation was done
%   .events     supply the events yourself ([] = detect them here with cs_engage_detect)
%   .detect     options passed to cs_engage_detect (thresholds, durations, .method)
%   .label      true (default) writes t_dwell = ... above each event
%   .maxLabels  (6) stop labelling beyond this many, so a busy site stays readable
%   .showRadius true (default) draws the site's own radius as a faint line: the scale every
%               threshold in the detector is expressed in
%
% info: .nTracks .nEvents .dwell_s (one per event) .radiusUm .events (the struct array drawn)

if nargin < 3 || ~isstruct(opts), opts = struct(); end
if isempty(ax), ax = gca; end
cols  = getf(opts, 'tracks', 1:numel(e.tracks));
hi    = getf(opts, 'highlight', []);
lab   = getf(opts, 'label', true);
maxL  = getf(opts, 'maxLabels', 6);
showR = getf(opts, 'showRadius', true);
dOpt  = getf(opts, 'detect', struct());
dt    = getf(e, 'dt', NaN); if ~isfinite(dt), dt = 0.02; end
R     = sqrt(max(polyarea(e.refboundary(:,1), e.refboundary(:,2)), eps)/pi);

cla(ax); hold(ax, 'on');
co = get(ax, 'ColorOrder');
evAll = []; dwell = [];
tmax = 0; rmax = 0;
for q = 1:numel(cols)
    j = cols(q);
    fr = e.CSmatrix(:,j,1); x = e.CSmatrix(:,j,2); y = e.CSmatrix(:,j,3);
    ok = isfinite(x) & isfinite(y) & inWindow(fr, e.winFrames);
    if nnz(ok) < 2, continue; end
    t = fr(ok)*dt; r = hypot(x(ok), y(ok));
    tmax = max(tmax, max(t)); rmax = max(rmax, max(r));
    isHi = ~isempty(hi) && j == hi;
    if isempty(hi)
        c = co(mod(q-1, size(co,1))+1, :); w = 1.1;
    elseif isHi
        c = [0.85 0.15 0.15]; w = 1.8;
    else
        c = [0.65 0.65 0.7]; w = 0.6;
    end
    plot(ax, t, r, '-', 'Color', c, 'LineWidth', w);
    if ~isempty(hi) && ~isHi, continue; end                 % events only for what is being read
    E = getf(opts, 'events', []);
    if isempty(E)
        o = dOpt; o.dt = dt; if ~isfield(o,'siteRadius'), o.siteRadius = R; end
        E = cs_engage_detect(r, fr(ok), o);
    end
    for m = 1:numel(E)
        t0 = E(m).entryFrame*dt; t1 = E(m).exitFrame*dt;
        xline(ax, t0, ':', 'Color', [0.25 0.25 0.25 0.8], 'LineWidth', 0.9);
        xline(ax, t1, ':', 'Color', [0.25 0.25 0.25 0.8], 'LineWidth', 0.9);
        dwell(end+1) = E(m).dwell_s; %#ok<AGROW>
        if isempty(evAll), evAll = E(m); else, evAll(end+1) = E(m); end %#ok<AGROW>
    end
end
if showR
    yline(ax, R, '-', 'Color', [0.6 0.75 0.85], 'LineWidth', 1);
    text(ax, 0, R, ' site radius', 'Color', [0.35 0.5 0.62], 'FontSize', 9, 'VerticalAlignment','bottom');
end
yline(ax, 0, '--', 'Color', [0.4 0.4 0.4]);
% The labels last, so they sit above every trace - and staggered: events cluster in time, and two
% labels at the same height overprint into something unreadable. Longest first, so if there is only
% room for a few it is the long dwells that get named.
if lab && ~isempty(evAll)
    [~, order] = sort([evAll.dwell_s], 'descend');
    span = max(tmax, dt); base = 1.02*max(rmax, R); step = 0.055*max(rmax, R);
    placed = zeros(0, 2);                                   % [x level]
    for m = order(1:min(maxL, numel(order)))
        t0 = evAll(m).entryFrame*dt; t1 = evAll(m).exitFrame*dt; xc = (t0+t1)/2;
        lvl = 0;
        while any(abs(placed(placed(:,2) == lvl, 1) - xc) < 0.16*span), lvl = lvl + 1; end
        placed(end+1, :) = [xc lvl]; %#ok<AGROW>
        text(ax, xc, base + lvl*step, dwellLabel(evAll(m).dwell_s), ...
            'HorizontalAlignment','center', 'VerticalAlignment','bottom', 'FontSize', 9.5);
    end
    ylim(ax, [-0.05*max(rmax,R) base + (max(placed(:,2)) + 1.6)*step]);
end
hold(ax, 'off');
xlabel(ax, 'Time (s)'); ylabel(ax, 'Distance from site centre (\mum)');
xlim(ax, [0 max(tmax, dt)]);
if ~(lab && ~isempty(evAll)), ylim(ax, [-0.05*max(rmax,R) 1.18*max(rmax, R)]); end
info = struct('nTracks', numel(cols), 'nEvents', numel(dwell), 'dwell_s', dwell(:), ...
              'radiusUm', R, 'events', evAll);
end

% =================================================================================================
function s = dwellLabel(d)
if d < 1, s = sprintf('t_{dwell} = %.0f ms', 1000*d); else, s = sprintf('t_{dwell} = %.3f s', d); end
end

function m = inWindow(fr, wf)
if numel(wf) < 2 || (isinf(wf(1)) && isinf(wf(2))), m = isfinite(fr); return; end
m = fr >= wf(1) & fr <= wf(2) & isfinite(fr);
end

function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
