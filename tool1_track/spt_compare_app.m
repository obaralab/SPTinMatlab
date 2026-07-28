function fig = spt_compare_app(cel, prm, opts)
%SPT_COMPARE_APP  Standalone window comparing the three linking methods on one cell:
%   Euclidean · ER-penalty · ER-geodesic.
%
%   spt_compare_app(cel, prm)              % opens the window and auto-runs on the default frame window
%   spt_compare_app(cel, prm, opts)        % opts.frames=[f0 f1], opts.maxImages=N, opts.autorun=false
%
% Shows (1) how many TRACKS each method produces (bar chart + medians), and (2) a grid of example
% regions where the methods link a spot to a DIFFERENT partner — the concrete places a track changes
% because of the method (source = black; Euclidean = red ✕; ER-penalty = orange ▢; ER-geodesic =
% green ✚, drawn over the ER mask). Runs on a frame window (default first 300) for speed; adjustable.
%
% cel : matched cell {spt, erSeg, key, diamUm, ...}; prm : {linkUm, gapUm, maxGap, lambda, pxUm}.
% Engine: spt_method_compare.m.

if nargin < 2, error('spt_compare_app(cel, prm)'); end
if nargin < 3 || isempty(opts), opts = struct(); end
f0Def = 1; f1Def = 300; nDef = 9; minLenDef = 1; autorun = true;
if isfield(opts,'frames') && numel(opts.frames)==2, f0Def = round(opts.frames(1)); f1Def = round(opts.frames(2)); end
if isfield(opts,'maxImages') && ~isempty(opts.maxImages), nDef = max(1,round(opts.maxImages)); end
if isfield(opts,'minLen') && ~isempty(opts.minLen), minLenDef = max(1,round(opts.minLen)); end
if isfield(opts,'autorun'), autorun = logical(opts.autorun); end
here = fileparts(mfilename('fullpath')); addpath(here);

% ---- state ----
cmp = []; R = prm.linkUm / prm.pxUm;
COL = struct('euclid',[0.85 0.12 0.12], 'penalty',[0.95 0.55 0.10], 'geodesic',[0.12 0.62 0.22]);
axEx = gobjects(0); ddBackdrop = []; sldC = []; axTime = [];

% ---- window ----
fig = uifigure('Name', sprintf('Linking-method comparison — %s', getf(cel,'key','cell')), ...
    'Position',[70 70 1240 780]);
gl = uigridlayout(fig,[2 1],'RowHeight',{40,'1x'},'Padding',[8 8 8 8],'RowSpacing',6);

top = uigridlayout(gl,[1 12],'ColumnWidth',{215,48,56,20,56,52,58,52,50,'1x',140,105}, ...
    'Padding',[0 0 0 0],'ColumnSpacing',6);
uilabel(top,'Text',sprintf('Cell: %s', getf(cel,'key','?')),'FontWeight','bold','FontColor',[0.25 0.25 0.3]);
uilabel(top,'Text','Frames','HorizontalAlignment','right');
eF0 = uieditfield(top,'numeric','Value',f0Def,'Limits',[1 Inf],'RoundFractionalValues',true,'ValueDisplayFormat','%d');
uilabel(top,'Text','to','HorizontalAlignment','center');
eF1 = uieditfield(top,'numeric','Value',f1Def,'Limits',[2 Inf],'RoundFractionalValues',true,'ValueDisplayFormat','%d');
uilabel(top,'Text','Min len','HorizontalAlignment','right', ...
    'Tooltip','Count only tracks at least this many frames long. Set it to your curation min length (e.g. 50) to compare the tracks that survive filtering. Changing it re-counts instantly — no re-tracking.');
eMin = uispinner(top,'Limits',[1 1e5],'Value',minLenDef,'Step',1,'RoundFractionalValues',true,'ValueChangedFcn',@(s,e) recount());
uilabel(top,'Text','Max img','HorizontalAlignment','right');
eN = uispinner(top,'Limits',[1 25],'Value',nDef,'Step',1,'RoundFractionalValues',true);
uilabel(top,'Text','');   % spacer
btnRun = uibutton(top,'Text','▶ Run comparison','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70], ...
    'FontColor','w','ButtonPushedFcn',@(s,e) run_());
btnSave = uibutton(top,'Text','Save figure…','Enable','off','ButtonPushedFcn',@(s,e) saveFig());

body = uigridlayout(gl,[1 2],'ColumnWidth',{380,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',10);
left = uigridlayout(body,[2 1],'RowHeight',{250,'1x'},'Padding',[0 0 0 0],'RowSpacing',6);
axBar = uiaxes(left); axBar.Toolbar.Visible='off'; title(axBar,'tracks per method'); ylabel(axBar,'# tracks');
txt = uitextarea(left,'Editable','off','Value',{'Run the comparison to see track counts and where the methods differ.'}, ...
    'FontName','Menlo');

right = uigridlayout(body,[1 1],'Padding',[0 0 0 0]);
pnEx = uipanel(right,'Title','example links where the methods disagree  ·  spot rings coloured by FRAME time  ·  markers = the link decision (○ source@t · red ✕ Euclidean · orange ▢ ER-penalty · green ✚ ER-geodesic @ t+1)', ...
    'FontSize',11);
exWrap = uigridlayout(pnEx,[2 1],'RowHeight',{30,'1x'},'Padding',[6 6 6 6],'RowSpacing',5);
exCtl = uigridlayout(exWrap,[1 6],'ColumnWidth',{68,150,66,150,'1x',160},'Padding',[0 0 0 0],'ColumnSpacing',6);
uilabel(exCtl,'Text','Backdrop','HorizontalAlignment','right');
ddBackdrop = uidropdown(exCtl,'Items',{'Raw + ER outline','Raw frame','ER mask'}, ...
    'ItemsData',{'rawer','raw','mask'},'Value','rawer', ...
    'Tooltip','What to draw the example links on: the actual raw SPT frame (optionally with the ER outline), or the ER mask.', ...
    'ValueChangedFcn',@(s,e) redrawExamples());
uilabel(exCtl,'Text','Contrast','HorizontalAlignment','right','Tooltip','Raw-frame display contrast (lower = brighter).');
sldC = uislider(exCtl,'Limits',[0.05 1],'Value',0.7,'MajorTicks',[],'MinorTicks',[],'ValueChangedFcn',@(s,e) redrawExamples());
uilabel(exCtl,'Text','');
axTime = uiaxes(exCtl); axTime.Toolbar.Visible='off'; axTime.XTick=[]; axTime.YTick=[];   % time-colour legend
exGrid = uigridlayout(exWrap,[3 3],'Padding',[0 0 0 0],'RowSpacing',4,'ColumnSpacing',4);
makeExGrid(3,3);
drawTimeLegend();

% auto-run once on open (unless suppressed)
drawnow; if autorun, run_(); end

% ================= nested =================
    function makeExGrid(nr,nc)
        delete(exGrid.Children); axEx = gobjects(1, nr*nc);
        exGrid.RowHeight = repmat({'1x'},1,nr); exGrid.ColumnWidth = repmat({'1x'},1,nc);
        for i = 1:nr*nc
            a = uiaxes(exGrid); a.Toolbar.Visible='off'; a.XTick=[]; a.YTick=[];
            title(a,''); axEx(i) = a;
        end
    end

    function run_()
        f0 = round(eF0.Value); f1 = round(eF1.Value);
        if ~(f1 > f0), status('Frame end must exceed frame start.', [0.75 0.1 0.1]); return; end
        if ~(isfield(cel,'erSeg') && ~isempty(cel.erSeg) && isfile(cel.erSeg))
            status('This cell has no ER segmentation — the three methods are identical without it.', [0.75 0.1 0.1]); return;
        end
        btnRun.Enable='off'; btnSave.Enable='off';
        try
            cmp = spt_method_compare(cel, prm, 'Frames',[f0 f1], 'MaxInstances',round(eN.Value), ...
                'ProgressFcn', @(frac,msg) status(sprintf('Running… %s', msg), [0.2 0.4 0.5]));
            drawBar(); drawSummary(); drawExamples();
            status(sprintf('Done — %d–%d: euclid %d · penalty %d · geodesic %d tracks · %d disagreements.', ...
                cmp.summary.frames(1), cmp.summary.frames(2), cmp.counts.euclid.nTracks, ...
                cmp.counts.penalty.nTracks, cmp.counts.geodesic.nTracks, cmp.summary.nDiff), [0.2 0.5 0.2]);
            btnSave.Enable='on';
        catch ME
            status(['Compare failed: ' ME.message], [0.75 0.1 0.1]);
        end
        btnRun.Enable='on';
    end

    function drawBar()
        mm = round(eMin.Value); vals = countAt(mm);
        cla(axBar);
        b = bar(axBar, vals, 'FaceColor','flat');
        b.CData = [COL.euclid; COL.penalty; COL.geodesic];
        axBar.XTick = 1:3; axBar.XTickLabel = {'Euclidean','ER-penalty','ER-geodesic'};
        ylabel(axBar,'# tracks');
        if mm<=1, ttl = sprintf('tracks per method  (all, frames %d–%d)', cmp.summary.frames(1), cmp.summary.frames(2));
        else,     ttl = sprintf('tracks \\geq %d frames per method  (%d–%d)', mm, cmp.summary.frames(1), cmp.summary.frames(2)); end
        title(axBar, ttl);
        ymax = max(vals); if ymax<=0, ymax=1; end; ylim(axBar,[0 ymax*1.15]);
        for i=1:3, text(axBar, i, vals(i), sprintf('%d',vals(i)), 'HorizontalAlignment','center', ...
                'VerticalAlignment','bottom','FontWeight','bold','FontSize',11); end
    end

    function drawSummary()
        c = cmp.counts; s = cmp.summary; mm = round(eMin.Value);
        raw = [c.euclid.nTracks c.penalty.nTracks c.geodesic.nTracks];
        fil = countAt(mm);
        sp  = [c.euclid.nLinkedSpots c.penalty.nLinkedSpots c.geodesic.nLinkedSpots];
        % exact strict-exclusion count from the tracker (older cached cmp structs may not carry it)
        gOff = 0; if isfield(c.geodesic,'nDetsOffEr'), gOff = c.geodesic.nDetsOffEr; end
        gTot = 0; if isfield(c.geodesic,'nDets'),      gTot = c.geodesic.nDets;      end
        L = {
            sprintf('Frames %d–%d   ·   %d frame-to-frame links', s.frames(1), s.frames(2), s.nLinks)
            sprintf('link dist %.3g µm   ·   λ = %.2g', s.linkUm, s.lambda)
            ''
            sprintf('TRACKS            all\\geq2   \\geq%d fr', mm)
            sprintf('  Euclidean     %6d   %6d', raw(1), fil(1))
            sprintf('  ER-penalty    %6d   %6d', raw(2), fil(2))
            sprintf('  ER-geodesic   %6d   %6d', raw(3), fil(3))
            ''
            sprintf('Linked detections:  %d / %d / %d', sp(1), sp(2), sp(3))
            sprintf('ER-geodesic excluded %d detections outright (%.1f%% of all', ...
                    gOff, 100*gOff/max(gTot,1))
            sprintf('%d) for being off their own frame''s ER; %d fewer end up linked', gTot, max(sp(1)-sp(3),0))
            'than Euclidean, the rest being on-ER spots left unpartnered. That'
            'is the STRICT rule — excluded spots stay in the _spots CSV with a'
            'blank TRACK_ID and never join a track. ER-penalty excludes nothing; it only'
            'makes off-ER links dearer, so it links ~the same spots as Euclidean'
            'and differs only in HOW it groups them. Both ER modes also SPLIT'
            'tracks at ER gaps: more short fragments (raw count up), which can'
            'drop a long Euclidean track below the min length (filtered count'
            'down). Raising Min len shows the tracks that survive curation.'
            ''
            'WHERE THE METHODS DIFFER'
            sprintf('  %d links assigned a different partner', s.nDiff)
            sprintf('  geodesic keeps %d on-ER where Euclidean crosses a gap', s.nExcelGeo)
            sprintf('  penalty  keeps %d on-ER where Euclidean crosses a gap', s.nExcelPen)
            };
        txt.Value = L;
    end

    function v = countAt(minLen)
        v = [countMode(cmp.tracks.euclid, minLen), countMode(cmp.tracks.penalty, minLen), countMode(cmp.tracks.geodesic, minLen)];
    end

    function recount()   % Min-len changed: re-count from the stored tracks + redraw (no re-tracking)
        if isempty(cmp), return; end
        drawBar(); drawSummary();
    end

    function drawExamples()
        T = cmp.instances; nax = numel(axEx); K = min(height(T), nax);
        for i = 1:nax
            a = axEx(i); cla(a); title(a,''); a.XTick=[]; a.YTick=[];
            if i > K, a.Visible='off'; if ~isempty(a.Children), delete(a.Children); end, continue; end
            a.Visible='on'; drawExample(a, T(i,:));
        end
    end

    function redrawExamples()   % backdrop / contrast changed: redraw the panels from stored data (no re-run)
        if isempty(cmp), return; end
        drawExamples();
    end

    function drawTimeLegend()   % small colour-ramp legend: which ring colour = which frame time
        if isempty(axTime) || ~isgraphics(axTime), return; end
        gap = min(max(round(getf(prm,'maxGap',1)),0), 2);
        offs = -gap : (1+gap); nW = numel(offs); TC = cool(max(nW,2));
        cla(axTime); hold(axTime,'on');
        for i = 1:nW
            patch(axTime, [i-1 i i i-1], [0 0 1 1], TC(i,:), 'EdgeColor','none');
            lab = sprintf('t%+d', offs(i)); if offs(i)==0, lab = 't'; end
            text(axTime, i-0.5, 0.5, lab, 'HorizontalAlignment','center','VerticalAlignment','middle','FontSize',8, 'Color',[0.1 0.1 0.1]);
        end
        xlim(axTime,[0 nW]); ylim(axTime,[0 1]); axTime.XTick=[]; axTime.YTick=[];
        title(axTime,'ring = frame','FontSize',8); hold(axTime,'off');
    end

    function drawExample(a, r)
        k = r.frame - cmp.fr(1) + 1;
        if k < 1 || k > numel(cmp.ERs), return; end
        sup = cmp.ERs{k}; [H,W] = size(sup);
        p = [r.srcX r.srcY];
        pts = [r.euX r.euY; r.peX r.peY; r.geX r.geY];
        rad = ceil(R) + 6;
        allx = [p(1); pts(:,1)]; ally = [p(2); pts(:,2)]; allx = allx(~isnan(allx)); ally = ally(~isnan(ally));
        cx = round(mean([min(allx) max(allx)])); cy = round(mean([min(ally) max(ally)]));
        x0=max(1,cx-rad); x1=min(W,cx+rad); y0=max(1,cy-rad); y1=min(H,cy+rad);
        supC = sup(y0:y1, x0:x1);
        % temporal window around the t -> t+1 link, widened by the gap-closing reach (max gap frames)
        gap = min(max(round(getf(prm,'maxGap',1)),0), 2);
        fW = (r.frame - gap) : (r.frame + 1 + gap);
        fW = fW(fW >= cmp.fr(1) & fW <= cmp.fr(2));
        nW = numel(fW); TC = cool(max(nW,2));   % cyan (earliest) -> magenta (latest)
        mode = 'rawer'; if ~isempty(ddBackdrop) && isgraphics(ddBackdrop), mode = ddBackdrop.Value; end
        if strcmp(mode,'mask')
            imshow(supC, 'Parent', a, 'XData',[x0 x1], 'YData',[y0 y1]);
            colormap(a, [1 1 1; 0.80 0.92 0.80]);   % gap = white, ER = light green
            hold(a,'on');
        else
            % backdrop = grayscale max-projection over the whole time window (context); the coloured spot
            % rings below tell you WHICH frame each spot is from, so the overlaid frames don't just read
            % as "too many spots".
            crop = [];
            for i = 1:nW
                try, im = double(imread(cel.spt, fW(i))); imc = im(y0:y1, x0:x1);
                     if isempty(crop), crop = imc; else, crop = max(crop, imc); end
                catch, end
            end
            if isempty(crop), crop = double(supC); end
            lo = prctile(crop(:),1); hi = prctile(crop(:),99.5); if ~(hi>lo), hi = lo+1; end
            c = 0.7; if ~isempty(sldC) && isgraphics(sldC), c = sldC.Value; end
            imshow(crop, [lo, lo + max(c,0.05)*(hi-lo)], 'Parent', a, 'XData',[x0 x1], 'YData',[y0 y1]);
            colormap(a, gray(256));
            hold(a,'on');
            if strcmp(mode,'rawer')
                B = bwboundaries(supC);
                for bb = 1:numel(B), bn = B{bb}; plot(a, bn(:,2)+x0-1, bn(:,1)+y0-1, '-', 'Color',[0.6 0.6 0.6], 'LineWidth',0.8); end
            end
        end
        % ring the LINKABLE spots (within the link radius of the source — the candidate partners across
        % the window), coloured by their FRAME (time). Distant context spots are skipped to avoid clutter.
        th = linspace(0, 2*pi, 20); rr = 2.3; dwin = R*1.15;
        for i = 1:nW
            kf = fW(i) - cmp.fr(1) + 1; if kf < 1 || kf > numel(cmp.dets), continue; end
            D = cmp.dets{kf}; if isempty(D), continue; end
            d2 = (D(:,1)-p(1)).^2 + (D(:,2)-p(2)).^2;
            D = D(d2 <= dwin^2, :);
            for s = 1:size(D,1)
                plot(a, D(s,1)+rr*cos(th), D(s,2)+rr*sin(th), '-', 'Color', TC(i,:), 'LineWidth', 0.9);
            end
        end
        % the link decision on top: source (frame t) + each method's partner (frame t+1)
        cols = {COL.euclid, COL.penalty, COL.geodesic};
        mk   = {'x','s','+'};
        for m = 1:3
            q = pts(m,:); if any(isnan(q)), continue; end
            plot(a,[p(1) q(1)],[p(2) q(2)],'-','Color',cols{m},'LineWidth',1.6);
            plot(a,q(1),q(2),mk{m},'Color',cols{m},'MarkerSize',9,'LineWidth',1.8);
        end
        plot(a,p(1),p(2),'o','MarkerFaceColor','w','MarkerEdgeColor','k','MarkerSize',6,'LineWidth',1.2);   % source (frame t)
        hold(a,'off'); axis(a,'image'); a.XTick=[]; a.YTick=[];
        title(a, sprintf('f%d\\rightarrow%d  euOff %.2f · peOff %.2f · geOff %.2f', r.frame, r.frame+1, r.euOff, r.peOff, r.geOff), 'FontSize',8);
    end

    function saveFig()
        [fn,pp] = uiputfile({'*.png','PNG image'}, 'Save comparison figure', sprintf('%s_method_compare.png', getf(cel,'key','cell')));
        if isequal(fn,0), return; end
        try, exportapp(fig, fullfile(pp,fn)); status(sprintf('Saved %s', fn), [0.2 0.5 0.2]);
        catch ME, status(['Save failed: ' ME.message], [0.75 0.1 0.1]); end
    end

    function status(msg, col), if nargin<2, col=[0.2 0.4 0.5]; end
        txt.Value = [{['» ' msg]}; txt.Value]; drawnow limitrate; %#ok<AGROW>
    end
end

function v = getf(s,f,d), if isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end

function n = countMode(trk, minLen)   % # tracks at least minLen frames long
if isempty(trk), n = 0; return; end
n = sum(cellfun(@(t) size(t,1), trk) >= minLen);
end
