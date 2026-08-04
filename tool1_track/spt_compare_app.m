function fig = spt_compare_app(cel, prm, opts)
%SPT_COMPARE_APP  Compare the three linking methods on one cell, as SIDE-BY-SIDE VIDEO.
%   Euclidean · ER-penalty · ER-geodesic.
%
%   spt_compare_app(cel, prm)          % opens and auto-runs on the default frame window
%   spt_compare_app(cel, prm, opts)    % opts.frames=[f0 f1], opts.maxImages=N, opts.autorun=false
%
% Left: how many TRACKS each method produces (bar chart + summary).
% Right: a list of the places the methods disagree, and — for the selected one — THREE SYNCHRONIZED
% PLAYERS, one per method, over the same cropped region and the same frame. Each panel animates the
% REAL frames (not a max projection) and draws only ITS OWN method's tracks, so the methods are
% compared side by side instead of overlaid on top of each other.
%
% Reading a panel:
%   · the FOCUS track — the chain containing the disagreeing spot — is bright in the method colour;
%   · every other track in the box is thin grey context;
%   · a dotted focus segment is a gap-closed jump (frames were skipped);
%   · the white/black ring is the source spot, the hollow ring that method's chosen partner.
% Two things the panel titles tell you, because they are the usual outcome and would otherwise read
% as a broken app: ER-penalty is frequently IDENTICAL to Euclidean here, and ER-geodesic frequently
% has NO track at all through the spot — under the strict rule the spot was off its own frame's ER
% and was excluded from tracking. The difference is usually an absence, which is why the panels are
% separated rather than overlaid.
%
% cel : matched cell {spt, erSeg, key, diamUm, ...}; prm : {linkUm, gapUm, maxGap, lambda, pxUm}.
% Engine: spt_method_compare.m.
%
% INDEX CONVENTIONS — three live in this file; convert once and never mix:
%   k   window index, 1..nF, into cmp.dets{k} / cmp.ERs{k} / cmp.tracks.<mode>{j}(:,1)
%   t   absolute movie frame,  t = cmp.fr(1) + k - 1
%   cmp.instances.frame is ABSOLUTE (t); cmp.tracks column 1 is WINDOW-relative (k).

if nargin < 2, error('spt_compare_app(cel, prm)'); end
if nargin < 3 || isempty(opts), opts = struct(); end
f0Def = 1; f1Def = 300; nDef = 200; minLenDef = 1; autorun = true;
if isfield(opts,'frames') && numel(opts.frames)==2, f0Def = round(opts.frames(1)); f1Def = round(opts.frames(2)); end
if isfield(opts,'maxImages') && ~isempty(opts.maxImages), nDef = max(1,round(opts.maxImages)); end
if isfield(opts,'minLen') && ~isempty(opts.minLen), minLenDef = max(1,round(opts.minLen)); end
if isfield(opts,'autorun'), autorun = logical(opts.autorun); end
here = fileparts(mfilename('fullpath')); addpath(here);

% ---- constants ----
MODES  = {'euclid','penalty','geodesic'};
MLBL   = {'Euclidean','ER-penalty','ER-geodesic'};
COLM   = [0.85 0.12 0.12; 0.95 0.55 0.10; 0.12 0.62 0.22];
GREY   = [0.55 0.55 0.60];      % context tracks
ERCOL  = [0.15 0.90 0.35];
STRIPQ = [0.88 0.88 0.90];      % strip: methods agree at this frame

% ---- state ----
cmp = []; R = prm.linkUm / prm.pxUm;
owner = {};          % owner{m}{k}(i) -> track id in cmp.tracks.(MODES{m}) for detection i of frame k
rank_ = [];          % scored example rows: struct array (row, score, what, firstAbs)
ex = [];             % the loaded example (window, crop, preloaded frames, per-method chains)
kcur = 1; playing = false; tmr = [];
axP = gobjects(1,3); axS = gobjects(1,3);
hImg = gobjects(1,3); hEr = gobjects(1,3); hCtx = gobjects(1,3); hFoc = gobjects(1,3);
hGap = gobjects(1,3); hHead = gobjects(1,3); hSrc = gobjects(1,3); hPar = gobjects(1,3);
hStrip = gobjects(1,3); hCur = gobjects(1,3); hTick = gobjects(1,3);

% ---- window ----
fig = uifigure('Name', sprintf('Linking-method comparison — %s', getf(cel,'key','cell')), ...
    'Position',[70 70 1240 780]);
fig.CloseRequestFcn = @(s,e) onClose();
gl = uigridlayout(fig,[2 1],'RowHeight',{40,'1x'},'Padding',[8 8 8 8],'RowSpacing',6);

top = uigridlayout(gl,[1 12],'ColumnWidth',{215,48,56,20,56,52,58,86,56,'1x',140,105}, ...
    'Padding',[0 0 0 0],'ColumnSpacing',6);
uilabel(top,'Text',sprintf('Cell: %s', getf(cel,'key','?')),'FontWeight','bold','FontColor',[0.25 0.25 0.3]);
uilabel(top,'Text','Frames','HorizontalAlignment','right');
eF0 = uieditfield(top,'numeric','Value',f0Def,'Limits',[1 Inf],'RoundFractionalValues',true,'ValueDisplayFormat','%d');
uilabel(top,'Text','to','HorizontalAlignment','center');
eF1 = uieditfield(top,'numeric','Value',f1Def,'Limits',[2 Inf],'RoundFractionalValues',true,'ValueDisplayFormat','%d');
uilabel(top,'Text','Min len','HorizontalAlignment','right', ...
    'Tooltip','Count only tracks at least this many frames long. Set it to your curation min length (e.g. 50) to compare the tracks that survive filtering. Changing it re-counts instantly — no re-tracking.');
eMin = uispinner(top,'Limits',[1 1e5],'Value',minLenDef,'Step',1,'RoundFractionalValues',true,'ValueChangedFcn',@(s,e) recount());
uilabel(top,'Text','Max examples','HorizontalAlignment','right', ...
    'Tooltip','How many disagreements to score and list (they are ranked by how much the methods actually differ).');
eN = uispinner(top,'Limits',[1 5000],'Value',nDef,'Step',25,'RoundFractionalValues',true);
uilabel(top,'Text','');   % spacer
btnRun = uibutton(top,'Text','▶ Run comparison','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70], ...
    'FontColor','w','ButtonPushedFcn',@(s,e) run_());
btnSave = uibutton(top,'Text','Save figure…','Enable','off','ButtonPushedFcn',@(s,e) saveFig());

body = uigridlayout(gl,[1 2],'ColumnWidth',{380,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',10);
left = uigridlayout(body,[2 1],'RowHeight',{250,'1x'},'Padding',[0 0 0 0],'RowSpacing',6);
axBar = uiaxes(left); axBar.Toolbar.Visible='off'; title(axBar,'tracks per method'); ylabel(axBar,'# tracks');
spt_axes_policy(axBar);
txt = uitextarea(left,'Editable','off','Value',{'Run the comparison to see track counts and where the methods differ.'}, ...
    'FontName','Menlo');

right = uigridlayout(body,[3 1],'RowHeight',{'1x',34,232},'Padding',[0 0 0 0],'RowSpacing',6);

% --- the three players (everything that must land in the exported video lives inside pnPlay,
%     and must be an AXES object: exportgraphics on a container drops uilabels/buttons/titles) ---
pnPlay = uipanel(right,'BorderType','none');
pg = uigridlayout(pnPlay,[2 3],'RowHeight',{'1x',52},'Padding',[4 4 4 4],'ColumnSpacing',6,'RowSpacing',2);
for i = 1:3
    a = uiaxes(pg); a.Toolbar.Visible='off'; a.XTick=[]; a.YTick=[]; a.YDir='reverse'; spt_axes_policy(a,'display');
    a.Box='on'; title(a, MLBL{i}, 'Color', COLM(i,:), 'FontWeight','bold');
    hold(a,'on');
    hImg(i)  = image(a,'CData',zeros(2,2,3),'XData',[1 2],'YData',[1 2]);
    hCtx(i)  = plot(a,nan,nan,'-','Color',GREY,'LineWidth',1.0);
    hEr(i)   = plot(a,nan,nan,'-','Color',ERCOL,'LineWidth',0.9);
    hFoc(i)  = plot(a,nan,nan,'-','Color',COLM(i,:),'LineWidth',2.2);
    hGap(i)  = plot(a,nan,nan,':','Color',COLM(i,:),'LineWidth',2.2);
    hPar(i)  = plot(a,nan,nan,'o','Color',COLM(i,:),'MarkerSize',13,'LineWidth',2.2);
    hHead(i) = plot(a,nan,nan,'o','MarkerFaceColor',COLM(i,:),'MarkerEdgeColor','k','MarkerSize',6);
    hSrc(i)  = plot(a,nan,nan,'o','MarkerFaceColor','w','MarkerEdgeColor','k','MarkerSize',7,'LineWidth',1.2);
    axis(a,'image'); axP(i) = a;
end
for i = 1:3      % divergence strips: WHEN in the window this method differs from the others
    a = uiaxes(pg); a.Toolbar.Visible='off'; a.XTick=[]; a.YTick=[]; a.YDir='normal'; a.Box='on';
    hold(a,'on');
    hStrip(i) = image(a,'CData',repmat(reshape(STRIPQ,1,1,3),1,2),'XData',[1 2],'YData',[0 1]);
    hTick(i)  = plot(a,nan,nan,'-','Color',[0.1 0.1 0.1],'LineWidth',1.4);   % frames where the methods disagree
    hCur(i)   = plot(a,[nan nan],[0 1],'-','Color','k','LineWidth',1.5);
    spt_axes_policy(a);
    a.ButtonDownFcn = @(s,e) stripClick(s);
    hStrip(i).ButtonDownFcn = @(s,e) stripClick(a);
    axS(i) = a;
end

% --- transport (outside pnPlay: deliberately not part of the exported video) ---
tr = uigridlayout(right,[1 10],'ColumnWidth',{80,'1x',104,64,74,60,150,116,110,'fit'}, ...
    'Padding',[0 0 0 0],'ColumnSpacing',6);
btnPlay = uibutton(tr,'Text','▶ Play','ButtonPushedFcn',@(s,e) toggle());
sld = uislider(tr,'Limits',[1 2],'Value',1,'MajorTicks',[],'MinorTicks',[], ...
    'ValueChangedFcn',@(s,e) seekIdx(round(s.Value)));
lblF = uilabel(tr,'Text','','HorizontalAlignment','center','FontName','Menlo');
ddSpeed = uidropdown(tr,'Items',{'0.5×','1×','2×'},'ItemsData',[0.16 0.08 0.05],'Value',0.08, ...
    'Tooltip','Playback speed.','ValueChangedFcn',@(s,e) respeed());
uilabel(tr,'Text','± frames','HorizontalAlignment','right', ...
    'Tooltip','How many frames each side of the disagreement to play.');
eWin = uispinner(tr,'Limits',[2 60],'Value',10,'Step',2,'RoundFractionalValues',true, ...
    'ValueChangedFcn',@(s,e) reloadExample());
sldC = uislider(tr,'Limits',[0.05 1],'Value',0.7,'MajorTicks',[],'MinorTicks',[], ...
    'Tooltip','Display contrast of the raw frame (lower = brighter).','ValueChangedFcn',@(s,e) draw());
ddBackdrop = uidropdown(tr,'Items',{'Raw + ER outline','Raw + ER tint','Raw frame','ER mask'}, ...
    'ItemsData',{'rawer','ertint','raw','mask'},'Value','rawer', ...
    'Tooltip','What the players draw on: the real frame (optionally with the ER outline or a light ER tint), or the ER mask itself.', ...
    'ValueChangedFcn',@(s,e) draw());
btnVid = uibutton(tr,'Text','Save video…','Enable','off','ButtonPushedFcn',@(s,e) saveVid());
uilabel(tr,'Text','');

% --- example list ---
tbl = uitable(right,'ColumnName',{'#','frame','what differs','first visible','diff','euOff','peOff','geOff'}, ...
    'ColumnWidth',{40,60,290,90,50,64,64,64}, 'SelectionType','row','Multiselect','off', ...
    'SelectionChangedFcn',@(s,e) onPick(e));

% handles for headless regression testing (spt_compare_smoke) — the UI itself never reads these
% NOTE: `state` must be a NESTED function, not an anonymous one — an anonymous function would
% capture kcur/ex/rank_ by VALUE at construction time and always report the empty initial state.
fig.UserData = struct('saveVideo',@saveVid, 'pick',@loadExample, 'play',@toggle, ...
    'seek',@seekIdx, 'state',@stateNow);

drawnow; if autorun, run_(); end

% ================= run / engine =================
    function run_()
        f0 = round(eF0.Value); f1 = round(eF1.Value);
        if ~(f1 > f0), status('Frame end must exceed frame start.', [0.75 0.1 0.1]); return; end
        if ~(isfield(cel,'erSeg') && ~isempty(cel.erSeg) && isfile(cel.erSeg))
            status('This cell has no ER segmentation — the three methods are identical without it.', [0.75 0.1 0.1]); return;
        end
        stopT(); btnRun.Enable='off'; btnSave.Enable='off'; btnVid.Enable='off';
        try
            cmp = spt_method_compare(cel, prm, 'Frames',[f0 f1], ...
                'ProgressFcn', @(frac,msg) status(sprintf('Running… %s', msg), [0.2 0.4 0.5]));
            status('Indexing tracks…'); buildOwners();
            status('Ranking disagreements…'); scoreRows();
            drawBar(); drawSummary(); fillTable();
            if ~isempty(rank_)
                tbl.Selection = 1; loadExample(1);
            else
                status('No disagreements in this window — the methods linked identically.', [0.4 0.4 0.2]);
            end
            status(sprintf('Done — %d–%d: euclid %d · penalty %d · geodesic %d tracks · %d disagreements.', ...
                cmp.summary.frames(1), cmp.summary.frames(2), cmp.counts.euclid.nTracks, ...
                cmp.counts.penalty.nTracks, cmp.counts.geodesic.nTracks, cmp.summary.nDiff), [0.2 0.5 0.2]);
            btnSave.Enable='on';
        catch ME
            status(['Compare failed: ' ME.message], [0.75 0.1 0.1]);
        end
        btnRun.Enable='on';
    end

    function buildOwners()
        % owner{m}{k}(i) = which track of method m owns detection i of window frame k.
        % Resolving by DETECTION INDEX (not track index) is what lets the three methods be compared:
        % the same physical spot is a different track number under each method.
        nF = numel(cmp.dets); owner = cell(1,3);
        for m = 1:3
            ow = cell(1,nF);
            for k = 1:nF, ow{k} = zeros(size(cmp.dets{k},1),1); end
            T = cmp.tracks.(MODES{m});
            for j = 1:numel(T)
                trk = T{j};
                for rr = 1:size(trk,1)
                    k = trk(rr,1); i = detIdx(cmp.dets{k}, trk(rr,2), trk(rr,3));
                    if i > 0, ow{k}(i) = j; end
                end
            end
            owner{m} = ow;
        end
    end

    function scoreRows()
        % Rank the disagreements by how much the three methods' FOCUS CHAINS actually differ over the
        % playback window — not by the engine's single-link off-ER heuristic, which says nothing about
        % what the video will show.
        T = cmp.instances; nR = min(height(T), round(eN.Value));
        rank_ = repmat(struct('row',0,'score',0,'what','','firstAbs',NaN), 1, 0);
        N = round(eWin.Value); nF = numel(cmp.dets);
        for rr = 1:nR
            r = T(rr,:);
            kc = r.frame - cmp.fr(1) + 1;
            if kc < 1 || kc > nF, continue; end
            kw = max(1,kc-N) : min(nF, kc+1+N);
            [V, ~] = focusChains(r, kc, kw);
            E = cellfun(@(v) edgesOf(v), V, 'uni', 0);
            allE = [E{1}; E{2}; E{3}];
            if isempty(allE), sc = 0;
            else
                uni = unique(allE,'rows');
                int = E{1};
                for m = 2:3, if isempty(int) || isempty(E{m}), int = zeros(0,6); else, int = intersect(int,E{m},'rows'); end, end
                sc = size(uni,1) - size(int,1);
            end
            rank_(end+1) = struct('row',rr, 'score',sc, ...
                'what', whatDiffers(V), 'firstAbs', firstDivergence(E, kw)); %#ok<AGROW>
        end
        if isempty(rank_), return; end
        [~, o] = sort([rank_.score], 'descend'); rank_ = rank_(o);
    end

    function [V, focusId] = focusChains(r, kc, kw)
        % V{m} = the vertices [k x y] of the track containing the source spot, under method m,
        % clipped to the playback window. Empty when that method never linked the spot.
        V = {zeros(0,3), zeros(0,3), zeros(0,3)}; focusId = [0 0 0];
        iSrc = detIdx(cmp.dets{kc}, r.srcX, r.srcY);
        if iSrc <= 0, return; end
        for m = 1:3
            j = owner{m}{kc}(iSrc); focusId(m) = j;
            if j <= 0, continue; end
            trk = cmp.tracks.(MODES{m}){j};
            s = trk(:,1) >= kw(1) & trk(:,1) <= kw(end);
            V{m} = trk(s,1:3);
        end
    end

% ================= example loading =================
    function onPick(e)
        s = [];
        if isstruct(e) && isfield(e,'Selection'), s = e.Selection; end
        if isempty(s), s = tbl.Selection; end
        if isempty(s), return; end
        loadExample(s(1));
    end

    function reloadExample()
        if isempty(ex), return; end
        loadExample(ex.rankIdx);
    end

    function loadExample(idx)
        if isempty(cmp) || isempty(rank_) || idx < 1 || idx > numel(rank_), return; end
        stopT(); btnPlay.Text = '▶ Play'; playing = false;
        rk = rank_(idx); r = cmp.instances(rk.row,:);
        nF = numel(cmp.dets); N = round(eWin.Value);
        kc = r.frame - cmp.fr(1) + 1;
        assert(kc >= 1 && kc <= nF, 'example frame outside the compared window');
        kw = max(1,kc-N) : min(nF, kc+1+N);
        [V, ~] = focusChains(r, kc, kw);

        % --- crop box: source + the three partners + every focus vertex, squared with a margin ---
        xs = r.srcX; ys = r.srcY;                        % keep these COLUMN vectors throughout —
        for c = {[r.euX r.euY],[r.peX r.peY],[r.geX r.geY]}   % the focus vertices below are columns
            q = c{1}; if all(~isnan(q)), xs(end+1,1)=q(1); ys(end+1,1)=q(2); end %#ok<AGROW>
        end
        for m = 1:3, if ~isempty(V{m}), xs = [xs; V{m}(:,2)]; ys = [ys; V{m}(:,3)]; end, end %#ok<AGROW>
        cx = (min(xs)+max(xs))/2; cy = (min(ys)+max(ys))/2;
        half = max(max(xs)-min(xs), max(ys)-min(ys))/2 * 1.25;
        half = min(max(half, 20), 45);                       % never microscopic, never the whole cell
        [Hh, Ww] = size(cmp.ERs{kw(1)});
        x0 = max(1,floor(cx-half)); x1 = min(Ww,ceil(cx+half));
        y0 = max(1,floor(cy-half)); y1 = min(Hh,ceil(cy+half));

        % --- preload the window (measured ~11 ms; keeps playback allocation-free) ---
        nW = numel(kw); raw = cell(1,nW); erc = cell(1,nW); erB = cell(1,nW);
        for q = 1:nW
            t = cmp.fr(1) + kw(q) - 1;
            try, im = double(imread(cel.spt, t)); catch, im = zeros(Hh,Ww); end
            raw{q} = im(y0:y1, x0:x1);
            erc{q} = cmp.ERs{kw(q)}(y0:y1, x0:x1);           % already the right frame — never re-read
            B = bwboundaries(erc{q}); bx = []; by = [];
            for bb = 1:numel(B), bn = B{bb}; bx = [bx; bn(:,2)+x0-1; nan]; by = [by; bn(:,1)+y0-1; nan]; end %#ok<AGROW>
            if isempty(bx), bx = nan; by = nan; end       % no ER in this crop — still needs a 2-column array
            erB{q} = [bx by];
        end
        allpx = cell2mat(cellfun(@(a) a(:), raw, 'uni', 0)');
        lo = prctile(allpx,1); hi = prctile(allpx,99.8); if ~(hi>lo), hi = lo+1; end

        % --- per-method context tracks in the box (everything that is not the focus chain) ---
        ctx = cell(1,3);
        for m = 1:3
            fid = 0;
            if ~isempty(V{m}), fid = owner{m}{kc}(detIdx(cmp.dets{kc}, r.srcX, r.srcY)); end
            ids = [];
            for q = 1:nW
                k = kw(q); D = cmp.dets{k}; if isempty(D), continue; end
                in = D(:,1)>=x0 & D(:,1)<=x1 & D(:,2)>=y0 & D(:,2)<=y1;
                o = owner{m}{k}(in); ids = [ids; o(o>0)]; %#ok<AGROW>
            end
            ids = setdiff(unique(ids), fid);
            C = cell(1,numel(ids));
            for z = 1:numel(ids)
                trk = cmp.tracks.(MODES{m}){ids(z)};
                s = trk(:,1) >= kw(1) & trk(:,1) <= kw(end);
                C{z} = trk(s,1:3);
            end
            ctx{m} = C;
        end

        E = cellfun(@(v) edgesOf(v), V, 'uni', 0);
        % Build field by field: struct('f',{c}) with a cell value would make a struct ARRAY, one
        % element per cell entry, instead of a scalar struct holding the cell.
        ex = struct();
        ex.rankIdx = idx; ex.r = r; ex.kc = kc; ex.kw = kw; ex.box = [x0 x1 y0 y1];
        ex.raw = raw; ex.erc = erc; ex.erB = erB; ex.lo = lo; ex.hi = hi;
        ex.V = V; ex.E = E; ex.ctx = ctx;
        [ex.stripRGB, ex.divQ] = stripColors(V, E, kw);

        % --- badges: the two outcomes that would otherwise read as a broken app ---
        title(axP(1), MLBL{1}, 'Color', COLM(1,:), 'FontWeight','bold');
        if isequal(V{2}, V{1})
            title(axP(2), sprintf('%s — identical to Euclidean here', MLBL{2}), 'Color',[0.45 0.45 0.5], 'FontWeight','normal');
        else
            title(axP(2), MLBL{2}, 'Color', COLM(2,:), 'FontWeight','bold');
        end
        if isempty(V{3})
            onEr = spt_on_er([r.srcX r.srcY], spt_er_support(cmp.ERs{kc}));
            if onEr, tail = 'spot kept, never linked'; else, tail = 'spot excluded (off ER)'; end
            title(axP(3), sprintf('%s — %s', MLBL{3}, tail), 'Color',[0.55 0.15 0.15], 'FontWeight','normal');
            set(hSrc(3), 'MarkerEdgeColor',[0.75 0.1 0.1], 'LineWidth',2);
        else
            title(axP(3), MLBL{3}, 'Color', COLM(3,:), 'FontWeight','bold');
            set(hSrc(3), 'MarkerEdgeColor','k', 'LineWidth',1.2);
        end

        for i = 1:3
            set(hImg(i), 'XData',[x0 x1], 'YData',[y0 y1]);
            xlim(axP(i), [x0-0.5 x1+0.5]); ylim(axP(i), [y0-0.5 y1+0.5]);
            set(hStrip(i), 'CData', ex.stripRGB{i}, 'XData',[1 max(nW,2)], 'YData',[0 1]);
            tx = []; ty = [];
            for z = ex.divQ, tx = [tx z z nan]; ty = [ty 0 0.3 nan]; end %#ok<AGROW>
            if isempty(tx), tx = nan; ty = nan; end
            set(hTick(i), 'XData',tx, 'YData',ty);
            xlim(axS(i), [0.5 nW+0.5]); ylim(axS(i), [0 1]);
        end
        sld.Limits = [1 max(nW,2)];

        % Open PAUSED on the first frame where the methods actually differ — opening on the
        % disagreement frame itself usually shows three identical panels.
        kStart = kw(1); fd = firstDivergence(E, kw);
        if ~isnan(fd), kStart = fd - cmp.fr(1) + 1; end
        kcur = min(max(kStart, kw(1)), kw(end));
        sld.Value = find(kw==kcur,1);
        btnVid.Enable = 'on';
        draw();
    end

% ================= drawing =================
    function draw()
        if isempty(ex), return; end
        q = find(ex.kw == kcur, 1); if isempty(q), q = 1; kcur = ex.kw(1); end
        bx = ex.box;
        md = ddBackdrop.Value;
        if strcmp(md,'mask')
            g = double(ex.erc{q}); rgb = cat(3, 1-0.20*g, 1-0.08*g, 1-0.20*g);   % white gap, light green ER
        else
            c = sldC.Value; hiAdj = ex.lo + max(c,0.05)*(ex.hi-ex.lo);
            g = mat2gray(ex.raw{q}, [ex.lo hiAdj]); rgb = repmat(g,[1 1 3]);
            if strcmp(md,'ertint'), rgb = tint_(rgb, ex.erc{q}, ERCOL, 0.12); end
        end
        for i = 1:3
            set(hImg(i), 'CData', rgb);
            if strcmp(md,'rawer'), set(hEr(i),'XData',ex.erB{q}(:,1),'YData',ex.erB{q}(:,2));
            else,                  set(hEr(i),'XData',nan,'YData',nan); end
            % context: every other track in the box, drawn up to now
            [cxs, cys] = polyUpTo(ex.ctx{i}, kcur);
            set(hCtx(i), 'XData',cxs, 'YData',cys);
            % focus chain: solid for consecutive frames, dotted where a gap-close skipped frames
            [fxs, fys, gxs, gys] = focusUpTo(ex.V{i}, kcur);
            set(hFoc(i), 'XData',fxs, 'YData',fys);
            set(hGap(i), 'XData',gxs, 'YData',gys);
            V = ex.V{i}; hx = nan; hy = nan;
            if ~isempty(V)
                z = find(V(:,1) <= kcur, 1, 'last');
                if ~isempty(z), hx = V(z,2); hy = V(z,3); end
            end
            set(hHead(i), 'XData',hx, 'YData',hy);
            set(hSrc(i),  'XData',ex.r.srcX, 'YData',ex.r.srcY);
            % that method's chosen partner, revealed once playback reaches the link
            pxy = partnerOf(ex.r, i);
            if any(isnan(pxy)) || kcur < ex.kc+1, set(hPar(i),'XData',nan,'YData',nan);
            else, set(hPar(i),'XData',pxy(1),'YData',pxy(2)); end
            set(hCur(i), 'XData',[q q], 'YData',[0 1]);
        end
        t = cmp.fr(1) + kcur - 1;
        title(axS(2), sprintf('frame %d   ·   disagreeing link %d\\rightarrow%d', t, ex.r.frame, ex.r.frame+1), 'FontSize',9);
        lblF.Text = sprintf('%d / %d', t, cmp.fr(2));
        drawnow limitrate;
    end

    function [xs, ys] = polyUpTo(C, kk)
        xs = nan; ys = nan;
        if isempty(C), return; end
        xs = []; ys = [];
        for z = 1:numel(C)
            V = C{z}; if isempty(V), continue; end
            s = V(:,1) <= kk; if nnz(s) < 2, continue; end
            xs = [xs; V(s,2); nan]; ys = [ys; V(s,3); nan]; %#ok<AGROW>
        end
        if isempty(xs), xs = nan; ys = nan; end
    end

    function [fx, fy, gx, gy] = focusUpTo(V, kk)
        fx = nan; fy = nan; gx = nan; gy = nan;
        if isempty(V), return; end
        s = V(:,1) <= kk; V = V(s,:);
        if size(V,1) < 2, return; end
        fx = []; fy = []; gx = []; gy = [];
        for z = 1:size(V,1)-1
            if V(z+1,1) - V(z,1) > 1, gx = [gx; V(z:z+1,2); nan]; gy = [gy; V(z:z+1,3); nan]; %#ok<AGROW>
            else,                     fx = [fx; V(z:z+1,2); nan]; fy = [fy; V(z:z+1,3); nan]; end %#ok<AGROW>
        end
        if isempty(fx), fx = nan; fy = nan; end
        if isempty(gx), gx = nan; gy = nan; end
    end

    function [rgbs, divQ] = stripColors(V, E, kw)
        % One strip per method, encoding PRESENCE: filled in the method colour on frames where that
        % method's focus chain exists, light grey where it does not. Presence is the right primary
        % signal because the commonest difference is an absence — geodesic having no chain at all
        % then reads instantly as an empty strip, which a "differs here" encoding cannot show
        % (everything differs, so every cell fills and the strip says nothing).
        % divQ marks, separately, the frames where the three chains disagree.
        nW = numel(kw); rgbs = cell(1,3);
        for m = 1:3
            C = repmat(reshape(STRIPQ,1,1,3), 1, max(nW,2));
            if ~isempty(V{m})
                for q = 1:nW
                    if any(V{m}(:,1) == kw(q)), C(1,q,:) = reshape(COLM(m,:),1,1,3); end
                end
            end
            rgbs{m} = C;
        end
        keys = cell(1,3);
        for m = 1:3, keys{m} = incomingKeys(E{m}, kw); end
        divQ = [];
        for q = 1:nW
            if ~isequaln(keys{1}(q,:), keys{2}(q,:)) || ~isequaln(keys{1}(q,:), keys{3}(q,:))
                divQ(end+1) = q; %#ok<AGROW>
            end
        end
    end

    function K = incomingKeys(E, kw)
        K = nan(numel(kw), 6);
        if isempty(E), return; end
        for q = 1:numel(kw)
            z = find(E(:,4) == kw(q), 1);
            if ~isempty(z), K(q,:) = E(z,:); end
        end
    end

    function f = firstDivergence(E, kw)
        keys = cell(1,3);
        for m = 1:3, keys{m} = incomingKeys(E{m}, kw); end
        f = NaN;
        for q = 1:numel(kw)
            if ~isequaln(keys{1}(q,:), keys{2}(q,:)) || ~isequaln(keys{1}(q,:), keys{3}(q,:))
                f = cmp.fr(1) + kw(q) - 1; return;
            end
        end
    end

    function s = whatDiffers(V)
        geoGone = isempty(V{3}); peSame = isequal(V{2}, V{1});
        if     geoGone && peSame, s = 'geodesic drops the track (penalty identical)';
        elseif geoGone,           s = 'geodesic drops the track; penalty also differs';
        elseif peSame,            s = 'geodesic reroutes the track (penalty identical)';
        else,                     s = 'all three differ';
        end
    end

    function fillTable()
        n = numel(rank_);
        if n == 0, tbl.Data = cell(0,8); return; end
        D = cell(n,8);
        for z = 1:n
            r = cmp.instances(rank_(z).row,:);
            fv = rank_(z).firstAbs; if isnan(fv), fvs = '—'; else, fvs = sprintf('%d', fv); end
            D(z,:) = {z, r.frame, rank_(z).what, fvs, rank_(z).score, ...
                num2str(r.euOff,'%.2f'), num2str(r.peOff,'%.2f'), num2str(r.geOff,'%.2f')};
        end
        tbl.Data = D;
    end

% ================= playback =================
    function toggle()
        if isempty(ex), return; end
        if playing, stopT(); btnPlay.Text = '▶ Play'; playing = false;
        else
            if kcur >= ex.kw(end), kcur = ex.kw(1); end
            startT(); btnPlay.Text = '⏸ Pause'; playing = true;
        end
    end

    function tick()
        if isempty(ex) || ~isvalid(axP(1)), stopT(); return; end
        z = find(ex.kw == kcur, 1); if isempty(z), z = 0; end
        z = z + 1; if z > numel(ex.kw), z = 1; end
        kcur = ex.kw(z); sld.Value = z; draw();
    end

    function seekIdx(z)
        if isempty(ex), return; end
        z = min(max(round(z),1), numel(ex.kw)); kcur = ex.kw(z); draw();
    end

    function stripClick(a)
        if isempty(ex), return; end
        p = a.CurrentPoint; seekIdx(round(p(1,1)));
    end

    function respeed()
        if isempty(tmr) || ~isvalid(tmr), return; end
        was = playing; stopT();
        delete(tmr); tmr = [];
        if was, startT(); end
    end

    function startT()
        if isempty(tmr) || ~isvalid(tmr)
            tmr = timer('ExecutionMode','fixedRate','Period',max(ddSpeed.Value,0.05), ...
                'BusyMode','drop','TimerFcn',@(~,~) tick());
        end
        if strcmp(tmr.Running,'off'), start(tmr); end
    end

    function stopT()
        try, if ~isempty(tmr) && isvalid(tmr) && strcmp(tmr.Running,'on'), stop(tmr); end, catch, end
        playing = false;
    end

    function s = stateNow()
        s = struct('kcur',kcur, 'ex',ex, 'rank',rank_, 'playing',playing);
    end

    function onClose()
        try, if ~isempty(tmr) && isvalid(tmr), stop(tmr); delete(tmr); end, catch, end
        tmr = []; delete(fig);
    end

% ================= left panel (unchanged behaviour) =================
    function drawBar()
        mm = round(eMin.Value); vals = countAt(mm);
        cla(axBar);
        b = bar(axBar, vals, 'FaceColor','flat'); b.CData = COLM;
        axBar.XTick = 1:3; axBar.XTickLabel = MLBL; ylabel(axBar,'# tracks');
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
            sprintf('ER-geodesic excluded %d detections outright (%.1f%% of all', gOff, 100*gOff/max(gTot,1))
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
            'Pick a row on the right to play that disagreement in all three methods.'
            };
        txt.Value = L;
    end

    function v = countAt(minLen)
        v = [countMode(cmp.tracks.euclid, minLen), countMode(cmp.tracks.penalty, minLen), countMode(cmp.tracks.geodesic, minLen)];
    end

    function recount()
        if isempty(cmp), return; end
        drawBar(); drawSummary();
    end

% ================= export =================
    function saveVid(outPath)
        if isempty(ex), return; end
        if nargin < 1 || isempty(outPath)
            [fn,pp] = uiputfile({'*.mp4','MPEG-4 video'}, 'Save comparison video', ...
                sprintf('%s_f%d_compare.mp4', getf(cel,'key','cell'), ex.r.frame));
            if isequal(fn,0), return; end
        else
            [pp, b, e2] = fileparts(outPath); if isempty(e2), e2 = '.mp4'; end; fn = [b e2];
        end
        was = playing; stopT();
        ws = warning('off','MATLAB:print:ExportappForUIFigureWithUIControl');
        cleanup = onCleanup(@() warning(ws)); %#ok<NASGU>
        out = fullfile(pp,fn);
        try,   vw = VideoWriter(out,'MPEG-4');
        catch, [pd,b] = fileparts(out); vw = VideoWriter(fullfile(pd,[b '.avi']),'Motion JPEG AVI'); end
        vw.FrameRate = 8; open(vw);
        tmpp = [tempname '.png']; saved = kcur; ok = true; errMsg = ''; sz = [];
        sTxt = btnVid.Text; btnVid.Enable = 'off';
        nW = numel(ex.kw);
        drawnow;   % load-bearing: the first exportgraphics on a freshly built panel returns a stub,
                   % and the frame size is locked from frame 1 — without this the whole video is garbage
        try
            for z = 1:nW
                kcur = ex.kw(z); draw();
                btnVid.Text = sprintf('Saving %d/%d…', z, nW);
                exportgraphics(pnPlay, tmpp, 'Resolution', 110);
                im = imread(tmpp);
                if isempty(sz)
                    hh = size(im,1); ww = size(im,2);
                    sz = [hh - mod(hh,2), ww - mod(ww,2)];   % H.264 wants even dims; a size CHANGE mid-write throws
                end
                if size(im,1) ~= sz(1) || size(im,2) ~= sz(2), im = imresize(im, sz); end
                writeVideo(vw, im);
            end
        catch ME
            ok = false; errMsg = ME.message;
        end
        close(vw); if isfile(tmpp), delete(tmpp); end
        btnVid.Text = sTxt; btnVid.Enable = 'on';
        kcur = saved; draw(); if was, startT(); playing = true; btnPlay.Text = '⏸ Pause'; end
        if ok, status(sprintf('Saved %s', fullfile(vw.Path, vw.Filename)), [0.2 0.5 0.2]);
        else,  status(['Video save failed: ' errMsg], [0.75 0.1 0.1]); end
    end

    function saveFig()
        [fn,pp] = uiputfile({'*.png','PNG image'}, 'Save comparison figure', sprintf('%s_method_compare.png', getf(cel,'key','cell')));
        if isequal(fn,0), return; end
        try, exportapp(fig, fullfile(pp,fn)); status(sprintf('Saved %s', fn), [0.2 0.5 0.2]);
        catch ME, status(['Save failed: ' ME.message], [0.75 0.1 0.1]); end
    end

    function status(msg, col), if nargin<2, col=[0.2 0.4 0.5]; end %#ok<INUSD>
        txt.Value = [{['» ' msg]}; txt.Value]; drawnow limitrate;
    end
end

% =========================================================================
function v = getf(s,f,d), if isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end

function n = countMode(trk, minLen)   % # tracks at least minLen frames long
if isempty(trk), n = 0; return; end
n = sum(cellfun(@(t) size(t,1), trk) >= minLen);
end

function i = detIdx(D, x, y)
% Row of detection (x,y) in this frame's detection list. The three methods share one detection set,
% so a detection index is the only identity that means the same thing under all three.
i = 0; if isempty(D), return; end
[v, i] = min((D(:,1)-x).^2 + (D(:,2)-y).^2);
if v > 1e-9, i = 0; end
end

function E = edgesOf(V)
% Track vertices -> edge rows [kA xA yA kB xB yB]. Coordinates come from the shared detection set,
% so edge rows are bit-comparable across methods with intersect/unique(...,'rows').
E = zeros(0,6);
if size(V,1) < 2, return; end
E = [V(1:end-1,:) V(2:end,:)];
end

function rgb = tint_(rgb, mask, col, a)
if ~any(mask(:)), return; end
for c = 1:3
    ch = rgb(:,:,c); ch(mask) = (1-a)*ch(mask) + a*col(c); rgb(:,:,c) = ch;
end
end

function p = partnerOf(r, m)
switch m
    case 1, p = [r.euX r.euY];
    case 2, p = [r.peX r.peY];
    otherwise, p = [r.geX r.geY];
end
end
