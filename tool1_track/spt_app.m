function fig = spt_app()
%SPT_APP  Single-particle "Track" tool (Tool 1 of 3): match -> detect -> track -> filter -> export.
%
% Upstream of the existing SPT_ContactSites_Pipeline analysis app. Takes three input folders
% (single-particle TIFF, ER segmentation, mito segmentation), matches cells, and (as tabs are
% added) detects + tracks + FILTERS (by track length / displacement), then exports
% <base>_tracks_filtered.xml + <base>_spots_filtered.csv (with per-spot MITO_DIST_UM) — the exact
% contract Tool 2's build_trackstruct reads. Note this tool only FILTERS; curation proper (density,
% step-variance, per-track inspection) is Tool 2's job, so nothing here calls itself curation.
%
%   spt_app        % opens the app

% ---- shared app state (nested functions below share this workspace) ----
matched = struct('key',{},'spt',{},'erSeg',{},'mitoSeg',{},'ok',{},'use',{});  % matched cells
hasEr = false; hasMi = false;                                                   % whether ER/mito folders were given
PXUM = 0.10785; DTS = 0.020064;             % calibration: µm/px, s/frame (auto-read from TIFF, user-editable)
eCalPx=[]; eCalDt=[]; ddUnits=[];            % calibration edit fields + overview-units toggle (top bar)
ovUnits='um';                                % kept/removed track-map units ('um'|'px')
% Detect-tab handles + state (the Match tab's Scan refreshes the cell list)
ddCell=[]; spnDiam=[]; spnPct=[]; sldFrame=[]; lblDet=[]; axPrev=[]; axHist=[]; axRate=[];
ddThrMode=[]; spnQual=[]; lblQual=[];   % threshold mode: Top % (percentile) vs Quality ≥ (absolute DoG-quality gate)
dCell=0; dInfo=[]; dNfr=0; dPool=zeros(0,1); hRateMk=[]; dRateF=[]; dRateC=[]; imW=0; imH=0;
sldCMin=[]; sldCMax=[]; btnPlay=[]; playTimer=[];               % contrast sliders + play button/timer
dispLo=0; dispHi=1; gMin=0; gMax=1; dLastIm=[]; dLastXY=zeros(0,3); dLastShp=zeros(0,4);   % display range + cached frame/detections/shape
autoThr=[];   % ImageJ B&C auto-threshold; halves on repeated Auto, resets on frame/cell change
dLastOff=false(0,1);   % per-detection off-ER flag for the cached frame
erNfr=[];              % ER stack page count, cached per cell (imfinfo is O(pages))
gStack=[];    % per-cell intensity stats + pooled sample (stack_stats) — Auto works on this, not one frame
ELONG_BLUR = 1.5;   % elongation above this flags a likely motion-blurred (streaked) spot
% Track-tab handles + state
spnLink=[]; spnGap=[]; spnInt=[]; ddMode=[]; spnLam=[]; eProj=[]; lblTrk=[]; lblTrkDet=[]; txtLog=[]; trkBusy=false; spnSampN=[]; playerCtl=[];
btR=[]; btB=[]; btExp=[]; btExpAll=[];   % the four action buttons — setBusy() drives their look
% Filter handles + state — live in the "Track & filter" tab. NOTE: Tool 1 only FILTERS (length /
% displacement); curation proper is Tool 2's job, so user-facing text here says "filter".
ddCur=[]; spnMinLen=[]; spnMinDisp=[]; axCur=[]; axCurTrk=[]; lblCur=[]; curC=[]; dCurCell=0;
exptCtl=[];   % shared multi-folder / condition experiment panel (spt_experiment_panel) — Experiment tab

% ---- path: the shared Experiment panel + its folder scanner live in Tool 2/3's tree ----
here_ = fileparts(mfilename('fullpath'));                       % .../tool1_track
t2_ = fullfile(fileparts(here_),'tool2_analyze');
if isfolder(t2_), addpath(fullfile(t2_,'app')); addpath(fullfile(t2_,'drivers')); end

% ---- window + tab group ----
fig = uifigure('Name','SPT Track — match · detect · track · filter · export', ...
    'Position',[80 80 1120 720]);
fig.CloseRequestFcn = @(s,e) onClose();
gl = uigridlayout(fig,[2 1],'RowHeight',{32,'1x'},'Padding',[8 8 8 8],'RowSpacing',6);
top = uigridlayout(gl,[1 10],'ColumnWidth',{'1x',86,66,110,66,58,10,90,64,60}, ...
    'Padding',[0 0 0 0],'ColumnSpacing',6);
uilabel(top,'Text','SPT Track — Tool 1 of 3','FontWeight','bold','FontColor',[0.25 0.25 0.3]);
uilabel(top,'Text','Pixel (µm/px)','HorizontalAlignment','right');
eCalPx = uieditfield(top,'numeric','Value',PXUM,'ValueDisplayFormat','%.5g','Limits',[1e-4 10], ...
    'Tooltip','µm per pixel — auto-read from the TIFF where possible; edit to override.', ...
    'ValueChangedFcn',@(s,e) onCalChange());
uilabel(top,'Text','Frame interval (s)','HorizontalAlignment','right');
eCalDt = uieditfield(top,'numeric','Value',DTS,'ValueDisplayFormat','%.5g','Limits',[1e-6 3600], ...
    'Tooltip',['Seconds per frame. Auto reads it from the TIFF (ImageJ ''finterval''). The upper ' ...
               'limit matches what the reader accepts, so a slow timelapse cannot throw here.'], ...
    'ValueChangedFcn',@(s,e) onCalChange());
uibutton(top,'Text','Auto','Tooltip',['Read the calibration from the current cell''s TIFF: pixel ' ...
    'size, frame interval, and the display range Fiji saved. Understands ImageJ/Fiji files, where ' ...
    'the scale is in XResolution and the unit is in the ImageDescription text block.'], ...
    'ButtonPushedFcn',@(s,e) onCalAuto());
uilabel(top,'Text','Map axes','HorizontalAlignment','right');
ddUnits = uidropdown(top,'Items',{'µm','px'},'ItemsData',{'um','px'},'Value',ovUnits, ...
    'Tooltip','Units for the kept/removed track map in the Track & filter tab.', ...
    'ValueChangedFcn',@(s,e) onUnits());
uibutton(top,'Text','❓ Help','Tooltip','Open the SPTinMatlab pipeline help guide in your browser.', ...
    'ButtonPushedFcn',@(s,e) onHelp());
tg = uitabgroup(gl); tg.Layout.Row = 2;

% Experiment FIRST: conditions and the cell inventory are what you set up before anything else,
% and the same panel is tab 1 in all three tools so the manifest is always in the same place.
tExpt = uitab(tg,'Title','1 · Experiment');
buildExperimentTab(tExpt);
tMatch = uitab(tg,'Title','2 · Match files');
buildMatchTab(tMatch);
tDetect = uitab(tg,'Title','3 · Detect');
buildDetectTab(tDetect);
tTrack = uitab(tg,'Title','4 · Track & filter');
buildTrackTab(tTrack);
tg.SelectedTab = tMatch;   % ...but open on Match files: that is where a fresh session starts

% ======================= nested functions =======================
    function buildExperimentTab(parent)
        % The SHARED experiment/condition panel (same component Tools 2 + 3 embed). Placing it here
        % lets conditions be defined UP FRONT — before tracking — and its scanner enumerates cells
        % straight from the raw movies. Pick a project in the Match tab (or Add folder here) to fill it.
        if exist('spt_experiment_panel','file') ~= 2
            uilabel(parent,'Text','spt_experiment_panel.m not found (expected in ../tool2_analyze/app).', ...
                'Position',[20 20 600 22]); return;
        end
        opts = struct('tool','track'); opts.seedFolders = {};   % assign after (struct('f',{}) makes an empty struct)
        exptCtl = spt_experiment_panel(parent, opts);
    end
    function buildMatchTab(parent)
        g = uigridlayout(parent,[7 3],'RowHeight',{30,30,30,30,30,24,'1x'}, ...
            'ColumnWidth',{170,'1x',96},'Padding',[10 10 10 10],'RowSpacing',6,'ColumnSpacing',8);

        uilabel(g,'Text','Project folder','HorizontalAlignment','right', ...
            'Tooltip','Pick a dataset folder; its spt / er_seg / mito_seg subfolders auto-fill (each still overridable), and output tracks/ are written here too.');
        eProjIn = uieditfield(g,'text','Placeholder','dataset folder containing spt/, er_seg/, mito_seg/');
        uibutton(g,'Text','Pick…','FontWeight','bold','ButtonPushedFcn',@(s,e) onPickProjectIn());

        uilabel(g,'Text','SPT folder (required)','HorizontalAlignment','right');
        eSpt = uieditfield(g,'text','Placeholder','folder of single-particle .tif stacks');
        uibutton(g,'Text','Pick…','ButtonPushedFcn',@(s,e) pick(eSpt));

        uilabel(g,'Text','ER seg folder (optional)','HorizontalAlignment','right');
        eEr = uieditfield(g,'text','Placeholder','ilastik ER masks — enables ER-aware tracking');
        uibutton(g,'Text','Pick…','ButtonPushedFcn',@(s,e) pick(eEr));

        uilabel(g,'Text','Mito seg folder (optional)','HorizontalAlignment','right');
        eMi = uieditfield(g,'text','Placeholder','ilastik mito masks — enables per-spot mito distance');
        uibutton(g,'Text','Pick…','ButtonPushedFcn',@(s,e) pick(eMi));

        uilabel(g,'Text','Strip regex','HorizontalAlignment','right', ...
            'Tooltip','Extra token stripped from names so SPT matches the seg files (e.g. _VAPB).');
        eStrip = uieditfield(g,'text','Value','_VAPB');
        uibutton(g,'Text','Scan','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70], ...
            'FontColor','w','ButtonPushedFcn',@(s,e) onScan());

        lbl = uilabel(g,'Text','Pick a project folder (auto-fills the 3 subfolders), or set them individually, then Scan.','FontColor',[0.45 0.45 0.45]);
        lbl.Layout.Row = 6; lbl.Layout.Column = [1 3];

        tbl = uitable(g,'ColumnName',{'use','cell','SPT','ER-seg','Mito-seg','status'}, ...
            'ColumnEditable',[true false false false false false], ...
            'ColumnWidth',{40,220,50,70,80,'auto'},'RowName',{});
        tbl.Layout.Row = 7; tbl.Layout.Column = [1 3];
        tbl.CellEditCallback = @(s,e) onUseEdit(e);

        % --- callbacks (nested: share matched/hasEr/hasMi + the handles above) ---
        function onScan()
            sptD = strtrim(eSpt.Value); erD = strtrim(eEr.Value);
            miD  = strtrim(eMi.Value);  strip = strtrim(eStrip.Value);
            if isempty(sptD) || ~isfolder(sptD)
                lbl.Text = 'Pick a valid SPT folder first.'; lbl.FontColor = [0.75 0.1 0.1];
                tbl.Data = {}; matched = matched([]); return;
            end
            hasEr = ~isempty(erD); hasMi = ~isempty(miD);
            if hasEr && ~isfolder(erD), lbl.Text='ER seg folder not found.'; lbl.FontColor=[0.75 0.1 0.1]; return; end
            if hasMi && ~isfolder(miD), lbl.Text='Mito seg folder not found.'; lbl.FontColor=[0.75 0.1 0.1]; return; end

            c = spt_match(sptD, erD, miD, strip);
            for k = 1:numel(c)
                c(k).use = true; c(k).diamUm = 0.5; c(k).keepPct = 6; c(k).thrAbs = [];
                % thrMode/qualThr left UNSET at init on purpose: un-previewed cells inherit the CURRENT
                % Detect-tab policy at run time (so "Quality ≥ X" applies to every ticked cell, not just one).
            end
            matched = c;
            if isempty(c)
                lbl.Text = 'No .tif stacks found in the SPT folder.'; lbl.FontColor = [0.75 0.1 0.1];
                tbl.Data = {}; return;
            end

            D = cell(numel(c), 6);
            for k = 1:numel(c)
                erCell = markCell(hasEr, ~isempty(c(k).erSeg));
                miCell = markCell(hasMi, ~isempty(c(k).mitoSeg));
                D(k,:) = {true, c(k).key, '✓', erCell, miCell, tern(c(k).ok,'usable','no SPT')};
            end
            tbl.Data = D;
            nEr = sum(arrayfun(@(x) ~isempty(x.erSeg), c));
            nMi = sum(arrayfun(@(x) ~isempty(x.mitoSeg), c));
            lbl.Text = sprintf('%d cell(s): SPT %d, ER-seg %s, mito-seg %s.', numel(c), numel(c), ...
                tern(hasEr, sprintf('%d/%d', nEr, numel(c)), 'off'), ...
                tern(hasMi, sprintf('%d/%d', nMi, numel(c)), 'off'));
            lbl.FontColor = [0.2 0.5 0.2];
            onCalAuto();                         % auto pixel size from the first cell's TIFF
            refreshDetectCells();                % populate the Detect tab's cell list
            refreshCurateCells();                % populate the filter cell list
        end

        function onUseEdit(e)
            if isempty(e.Indices) || e.Indices(2) ~= 1, return; end   % only the 'use' checkbox column
            r = e.Indices(1);
            if r >= 1 && r <= numel(matched), matched(r).use = logical(e.NewData); end
        end

        function onPickProjectIn()
            start = pwd; if ~isempty(eProjIn.Value) && isfolder(eProjIn.Value), start = eProjIn.Value; end
            d = uigetdir(start, 'Pick the project / dataset folder');
            if isequal(d, 0), return; end
            eProjIn.Value = d;
            % auto-fill the three input subfolders (each still overridable via its Pick button)
            sp = subfolder(d, {'spt'}); er = subfolder(d, {'er_seg','erseg'}); mi = subfolder(d, {'mito_seg','mitoseg'});
            if ~isempty(sp), eSpt.Value = sp; end
            if ~isempty(er), eEr.Value  = er; end
            if ~isempty(mi), eMi.Value  = mi; end
            if ~isempty(eProj) && isgraphics(eProj), eProj.Value = d; end   % output project = the same folder
            % The manifest lives WITH the project: load <project>/experiment_details.mat if it is
            % there and keep saving to it, so conditions set in any tool are already here next time.
            try, if ~isempty(exptCtl) && isstruct(exptCtl) && isfield(exptCtl,'setAutoPath')
                    exptCtl.setAutoPath(d);
                 end, catch, end
            try, if ~isempty(exptCtl) && isstruct(exptCtl), exptCtl.addFolder(d); end, catch, end   % add to the Experiment manifest
            if ~isempty(sp)
                onScan();                                                  % auto-scan when SPT was found
            else
                lbl.Text = 'No spt/ subfolder found — set the SPT folder manually.'; lbl.FontColor = [0.6 0.4 0.1];
            end
        end
    end

    function pick(field)
        start = pwd; if ~isempty(field.Value) && isfolder(field.Value), start = field.Value; end
        d = uigetdir(start, 'Pick a folder');
        if isequal(d, 0), return; end
        field.Value = d;
    end

    % ---------------- Tab 2: Detect (interactive per-file threshold) ----------------
    function buildDetectTab(parent)
        g = uigridlayout(parent,[3 1],'RowHeight',{132,22,'1x'},'Padding',[8 8 8 8],'RowSpacing',6);
        cp = uigridlayout(g,[4 6],'RowHeight',{26,26,26,26},'ColumnWidth',{56,'1x',96,66,52,66}, ...
            'Padding',[0 0 0 0],'RowSpacing',4,'ColumnSpacing',6);
        % row 1: cell / diameter / top-%
        p(uilabel(cp,'Text','Cell','HorizontalAlignment','right'),1,1);
        ddCell = uidropdown(cp,'Items',{'(scan first)'},'ValueChangedFcn',@(s,e) onDetCell()); p(ddCell,1,2);
        p(uilabel(cp,'Text','Diameter (µm)','HorizontalAlignment','right'),1,3);
        spnDiam = uispinner(cp,'Limits',[0.1 3],'Value',0.5,'Step',0.05,'ValueChangedFcn',@(s,e) onDetParam('diam')); p(spnDiam,1,4);
        p(uilabel(cp,'Text','Top %','HorizontalAlignment','right', ...
            'Tooltip','Keep the top X% of pooled candidates by DoG quality — the per-file threshold. Lower = stricter.'),1,5);
        spnPct = uispinner(cp,'Limits',[0.1 100],'Value',6,'Step',1,'ValueChangedFcn',@(s,e) onDetParam('pct')); p(spnPct,1,6);
        % row 2: threshold mode = percentile vs absolute DoG-quality gate (quality = the red line on the histogram)
        p(uilabel(cp,'Text','Threshold','HorizontalAlignment','right', ...
            'Tooltip','Top %: keep the top X% per cell (adapts to each cell). Quality ≥: a FIXED DoG-quality cut applied to every cell (directly comparable across cells).'),2,1);
        ddThrMode = uidropdown(cp,'Items',{'Top %','Quality ≥'},'ItemsData',{'pct','qual'},'Value','pct', ...
            'ValueChangedFcn',@(s,e) onDetParam('mode')); p(ddThrMode,2,2);
        lblQual = uilabel(cp,'Text','Quality ≥','HorizontalAlignment','right','Enable','off', ...
            'Tooltip','Absolute DoG-quality threshold (same units as the histogram x-axis). Keeps spots with quality ≥ this value.'); p(lblQual,2,[3 5]);
        spnQual = uispinner(cp,'Limits',[0 1e6],'Value',0,'Step',1,'Enable','off','ValueChangedFcn',@(s,e) onDetParam('qual')); p(spnQual,2,6);
        % row 3: frame slider + play
        p(uilabel(cp,'Text','Frame','HorizontalAlignment','right'),3,1);
        sldFrame = uislider(cp,'Limits',[1 2],'Value',1,'MajorTicks',[],'ValueChangedFcn',@(s,e) onDetFrame()); p(sldFrame,3,[2 5]);
        btnPlay = uibutton(cp,'Text','▶ Play','ButtonPushedFcn',@(s,e) onPlay()); p(btnPlay,3,6);
        % row 4: contrast = two display points (black + white, like Fiji B&C); Auto restretches them
        p(uilabel(cp,'Text','Black | White','HorizontalAlignment','right', ...
            'Tooltip','Display only (does NOT affect detection). Two points: the left slider is the black point, the right slider is the white point.'),4,1);
        sldCMin = uislider(cp,'Limits',[0 1],'Value',0,'MajorTicks',[],'ValueChangedFcn',@(s,e) onContrast(), ...
            'Tooltip','Black point — pixels at/below this display as black.'); p(sldCMin,4,[2 3]);
        sldCMax = uislider(cp,'Limits',[0 1],'Value',1,'MajorTicks',[],'ValueChangedFcn',@(s,e) onContrast(), ...
            'Tooltip','White point — pixels at/above this display as white.'); p(sldCMax,4,[4 5]);
        btnAuto = uibutton(cp,'Text','Auto','ButtonPushedFcn',@(s,e) onAutoContrast(), ...
            'Tooltip',['Fiji''s Brightness&Contrast Auto, over a sample of the WHOLE STACK so the ' ...
                       'brightness does not change as you scrub. Click again to stretch further ' ...
                       '(the threshold halves, exactly as ImageJ does). Right-click or use Reset ' ...
                       'for the full stack min–max, which is what Fiji shows when it opens the file.']); p(btnAuto,4,6);
        btnAuto.ContextMenu = uicontextmenu(fig);
        uimenu(btnAuto.ContextMenu,'Text','Reset to full stack min–max (Fiji Reset)', ...
            'MenuSelectedFcn',@(s,e) onResetContrast()); %#ok<NASGU>
        lblDet = uilabel(g,'Text','Scan on Tab 1, then pick a cell.','FontColor',[0.45 0.45 0.45]);
        ap = uigridlayout(g,[1 2],'ColumnWidth',{'1.4x','1x'},'Padding',[0 0 0 0],'ColumnSpacing',8);
        axPrev = uiaxes(ap); axPrev.Toolbar.Visible = 'off'; title(axPrev,'preview');
        rp = uigridlayout(ap,[2 1],'RowHeight',{'1x','1x'},'Padding',[0 0 0 0],'RowSpacing',8);
        axHist = uiaxes(rp); title(axHist,'pooled spot quality');
        axRate = uiaxes(rp); title(axRate,'spots / frame');
    end

    function refreshDetectCells()
        if isempty(ddCell) || ~isgraphics(ddCell), return; end
        idxs = find([matched.use]);
        if isempty(idxs)
            ddCell.Items = {'(no usable cells)'}; ddCell.ItemsData = {}; dCell = 0;
            if ~isempty(axPrev) && isgraphics(axPrev), cla(axPrev); end
            if ~isempty(axHist) && isgraphics(axHist), cla(axHist); end
            return;
        end
        ddCell.Items = {matched(idxs).key}; ddCell.ItemsData = num2cell(idxs);
        ddCell.Value = ddCell.ItemsData{1};
        onDetCell();
    end

    function onDetCell()
        if isempty(ddCell) || isempty(ddCell.ItemsData), dCell = 0; return; end
        dCell = ddCell.Value;
        if dCell < 1 || dCell > numel(matched), return; end
        c = matched(dCell);
        try, dInfo = imfinfo(c.spt); dNfr = numel(dInfo); catch, dInfo = []; dNfr = 0; end
        if dNfr < 1, lblDet.Text = 'Could not read the SPT stack.'; lblDet.FontColor = [0.75 0.1 0.1]; return; end
        imW = dInfo(1).Width; imH = dInfo(1).Height;   % pixel dimensions (for the status readout + track overview)
        spnDiam.Value = getf(c,'diamUm',0.5);
        spnPct.Value  = getf(c,'keepPct',6);
        ddThrMode.Value = getf(c,'thrMode','pct');
        spnQual.Value   = getf(c,'qualThr',0);
        syncThrModeUI();
        sldFrame.Limits = [1 max(dNfr,1)];
        sldFrame.Value  = min(max(round(sldFrame.Value),1), dNfr);
        stopPlay();
        erNfr = []; dLastOff = false(0,1);                         % new cell -> drop the ER caches
        gStack = stack_stats(c.spt, 12);                           % limits + a pooled stack sample
        % The slider limits must CONTAIN every range we might set, or applyDisplayRange silently
        % truncates it. The percentile pair alone does not: on the user's file it is 167–946, while
        % the stack really spans 138–1125 and the range Fiji saved is 131–1904. Clamping to the
        % percentiles turned "open on exactly what Fiji shows" into a 2x-too-bright preview, and made
        % Reset unable to reach the stack min–max even by dragging.
        gMin = gStack.lo; gMax = gStack.hi;
        fc0 = spt_tiff_calib(c.spt);
        gMin = min([gMin, gStack.rawLo, fc0.dispLo], [], 'omitnan');
        gMax = max([gMax, gStack.rawHi, fc0.dispHi], [], 'omitnan');
        if ~(gMax > gMin), gMax = gMin + 1; end
        setSliderLimits(sldCMin,[gMin gMax]); setSliderLimits(sldCMax,[gMin gMax]);
        % Open on the range Fiji would show. If the file carries one (a Fiji-saved stack does), use
        % exactly that; otherwise run ImageJ's Auto over the stack sample. Either way it is a
        % STACK-wide range, so scrubbing does not change the brightness — which is the part that did
        % not look like Fiji before.
        autoThr = [];
        fc = fc0;
        if isfinite(fc.dispLo) && isfinite(fc.dispHi)
            dispLo = clampv(fc.dispLo, gMin, gMax); dispHi = clampv(max(fc.dispHi,dispLo+eps), dispLo+eps, gMax);
        else
            [aLo, aHi] = ij_auto(gStack.sample, 5000);
            dispLo = clampv(aLo, gMin, gMax); dispHi = clampv(max(aHi,dispLo+eps), dispLo+eps, gMax);
        end
        setSlider(sldCMin, dispLo); setSlider(sldCMax, dispHi);
        poolAndDraw();
    end

    function poolAndDraw()
        if dCell < 1 || dNfr < 1, return; end
        lblDet.Text = 'Pooling spot quality…'; lblDet.FontColor = [0.45 0.45 0.45]; drawnow;
        dPool = spt_pool_quality(matched(dCell).spt, spnDiam.Value, PXUM, 40);
        drawDetHist(); drawDetRate(); drawDetPreview();
    end

    function onDetParam(which)
        if strcmp(which,'mode')
            % switching to Quality ≥ with no value yet -> seed it from the current percentile threshold
            if strcmpi(ddThrMode.Value,'qual') && spnQual.Value <= 0
                tp = []; if ~isempty(dPool), tp = prctile(dPool, 100 - min(max(spnPct.Value,0.1),100)); end
                if ~isempty(tp) && isfinite(tp), spnQual.Value = round(tp,3); end
            end
            syncThrModeUI();   % UI enable-state is independent of whether a cell is loaded
        end
        if dCell < 1, return; end
        matched(dCell).diamUm  = spnDiam.Value;
        matched(dCell).keepPct = spnPct.Value;
        matched(dCell).thrMode = ddThrMode.Value;
        matched(dCell).qualThr = spnQual.Value;
        if strcmp(which,'diam')      % diameter changes the DoG -> re-pool everything
            poolAndDraw();
        else                          % percentile / mode / quality change only the threshold -> re-threshold
            drawDetHist(); drawDetRate(); drawDetPreview();
        end
    end

    function syncThrModeUI()   % enable the control that matches the active threshold mode
        if isempty(ddThrMode) || ~isgraphics(ddThrMode), return; end
        isQual = strcmpi(ddThrMode.Value,'qual');
        spnQual.Enable = tern(isQual,'on','off');  lblQual.Enable = tern(isQual,'on','off');
        spnPct.Enable  = tern(~isQual,'on','off');
    end

    function onDetFrame()
        drawDetPreview(); updateRateMarker();
    end

    function onCalChange()
        if ~isempty(eCalPx) && isgraphics(eCalPx), PXUM = eCalPx.Value; end
        if ~isempty(eCalDt) && isgraphics(eCalDt), DTS  = eCalDt.Value; end
        if dCell >= 1, poolAndDraw(); end     % pixel size changes diameter->px, so re-detect
    end

    function onUnits()   % px<->µm for the kept/removed track map
        if ~isempty(ddUnits) && isgraphics(ddUnits), ovUnits = ddUnits.Value; end
        drawCurOverview();
    end

    function onHelp()
        d = fullfile(fileparts(here_),'docs','help.html');   % here_ = .../tool1_track
        if ~isfile(d), return; end
        try, web(d,'-browser'); catch, try, web(d); catch, end, end
    end

    function onCalAuto()
        % Read BOTH numbers off the movie. The pixel size used to come from the TIFF resolution tags
        % alone, which is the one thing a Fiji-saved file does not provide in a readable form: Fiji
        % puts the scale in XResolution and the UNIT in a text block, and sets ResolutionUnit to
        % None. spt_tiff_calib understands that block, so it also recovers the frame interval — which
        % this button never touched even though it sits right next to the field.
        p = '';
        if dCell >= 1 && dCell <= numel(matched), p = matched(dCell).spt;
        elseif ~isempty(matched),                 p = matched(1).spt; end
        if isempty(p), return; end
        c = spt_tiff_calib(p);
        got = {}; miss = {};
        if isfinite(c.pixUm)
            if ~isempty(eCalPx) && isgraphics(eCalPx), eCalPx.Value = c.pixUm; end
            PXUM = c.pixUm;
            got{end+1} = sprintf('%.5g µm/px', c.pixUm); %#ok<AGROW>
        else
            miss{end+1} = 'pixel size'; %#ok<AGROW>
        end
        if isfinite(c.dt_s)
            if ~isempty(eCalDt) && isgraphics(eCalDt), eCalDt.Value = c.dt_s; end
            DTS = c.dt_s;
            got{end+1} = sprintf('%.5g s/frame (%.4g Hz)', c.dt_s, 1/c.dt_s); %#ok<AGROW>
        else
            miss{end+1} = 'frame interval'; %#ok<AGROW>
        end
        % Fiji's own display range travels in the same block. Offer it — the user asked for contrast
        % that matches Fiji, and this is literally the range Fiji was showing when the file was saved.
        if isfinite(c.dispLo) && isfinite(c.dispHi) && ~isempty(dLastIm)
            applyDisplayRange(c.dispLo, c.dispHi);
            got{end+1} = sprintf('display %g–%g (as saved in Fiji)', c.dispLo, c.dispHi); %#ok<AGROW>
        end
        if ~isempty(lblDet) && isgraphics(lblDet)
            if isempty(got)
                lblDet.Text = 'Nothing readable in this TIFF — set µm/px and frame interval manually above.';
                lblDet.FontColor = [0.6 0.4 0.1];
            else
                tail = ''; if ~isempty(miss), tail = sprintf('  ·  no %s in the file — set it manually', strjoin(miss,' or ')); end
                lblDet.Text = ['Read from the TIFF: ' strjoin(got,'  ·  ') tail];
                lblDet.FontColor = [0.2 0.5 0.2]; if ~isempty(miss), lblDet.FontColor = [0.6 0.4 0.1]; end
            end
        end
        if dCell >= 1, poolAndDraw(); end
    end

    function thr = curDetThr()
        if ~isempty(ddThrMode) && isgraphics(ddThrMode) && strcmpi(ddThrMode.Value,'qual')
            thr = spnQual.Value;                                  % absolute DoG-quality gate (same units as the histogram)
            if ~(thr > 0), thr = []; end                         % 0 -> unset -> MAD fallback in spt_detect
            return;
        end
        if isempty(dPool), thr = []; return; end                 % [] -> MAD fallback in spt_detect
        thr = prctile(dPool, 100 - min(max(spnPct.Value,0.1),100));
    end

    function drawDetPreview()
        if dCell < 1 || dNfr < 1, return; end
        fr = round(sldFrame.Value);
        dLastIm = double(imread(matched(dCell).spt, fr));
        thr = curDetThr(); matched(dCell).thrAbs = thr;
        matched(dCell).thrMode = ddThrMode.Value; matched(dCell).qualThr = spnQual.Value;   % persist the policy with the cell
        [dLastXY, dLastShp] = spt_detect(dLastIm, spnDiam.Value, PXUM, thr);
        dLastOff = detOffEr(dLastXY, fr);   % once per detection; redrawDisplay reuses it
        redrawDisplay();
        if strcmpi(ddThrMode.Value,'qual'), gateStr = sprintf('quality ≥ %.4g', spnQual.Value);
        else,                               gateStr = sprintf('top %.3g%%', spnPct.Value); end
        nBlur = 0; medEl = NaN;
        if ~isempty(dLastShp), medEl = median(dLastShp(:,3)); nBlur = sum(dLastShp(:,3) >= ELONG_BLUR); end
        % Off-ER matters as much as motion blur when the target is an ER protein — under ER-geodesic
        % linking these detections are DISCARDED, so seeing how many there are is how you tell a
        % registration problem or a bad segmentation from genuine off-ER signal.
        offStr = '';
        if haveErSeg()
            nOff = sum(dLastOff(:));
            offStr = sprintf(' · %d off-ER (%.0f%%, dropped by ER-geodesic linking)', ...
                nOff, 100*nOff/max(size(dLastXY,1),1));
        end
        lblDet.Text = sprintf('%s · %d×%d px (%.1f×%.1f µm) · diam %.2f µm · %s · thr %s · %d spots · %d likely motion-blur (elong≥%.1f, med %.2f)%s · pooled n=%d', ...
            matched(dCell).key, imW, imH, imW*PXUM, imH*PXUM, spnDiam.Value, gateStr, thrStr(thr), size(dLastXY,1), nBlur, ELONG_BLUR, medEl, offStr, numel(dPool));
        lblDet.FontColor = [0.2 0.4 0.5];
        updateTrkDet();   % keep the Track-tab detection readout in sync
    end

    function redrawDisplay()   % re-display the cached frame + detections (contrast/frame change, no re-detect)
        if isempty(dLastIm) || isempty(axPrev) || ~isgraphics(axPrev), return; end
        lo = dispLo; hi = dispHi; if ~(hi>lo), hi = lo + max(1,abs(lo)*0.01); end
        cla(axPrev);
        imshow(mat2gray(dLastIm,[lo hi]), 'Parent', axPrev); hold(axPrev,'on');
        if ~isempty(dLastXY)
            r = max((spnDiam.Value/PXUM)/2, 0.75);          % spot RADIUS in image pixels (true diameter)
            th = linspace(0, 2*pi, 24);
            % Two INDEPENDENT properties, so they get two independent channels rather than fighting
            % over colour: COLOUR is shape (green round / red elongated, unchanged), LINE STYLE is
            % ER membership (solid on / dashed off). A spot can easily be both, and with one channel
            % that case is invisible.
            isBlur = false(size(dLastXY,1),1);
            if ~isempty(dLastShp) && size(dLastShp,1)==size(dLastXY,1), isBlur = dLastShp(:,3) >= ELONG_BLUR; end
            if numel(dLastOff) ~= size(dLastXY,1), dLastOff = false(size(dLastXY,1),1); end
            GRN = [0.15 1 0.3]; RED = [1 0.25 0.15];
            drawRings(dLastXY(~isBlur & ~dLastOff,:), r, th, GRN, '-');
            drawRings(dLastXY( isBlur & ~dLastOff,:), r, th, RED, '-');
            drawRings(dLastXY(~isBlur &  dLastOff,:), r, th, GRN, ':');
            drawRings(dLastXY( isBlur &  dLastOff,:), r, th, RED, ':');
        end
        hold(axPrev,'off');
        nOff = sum(dLastOff(:)); offTxt = '';
        if haveErSeg(), offTxt = sprintf(', dotted = off-ER: %d', nOff); end
        title(axPrev, sprintf('frame %d/%d — %d spots (red = elong≥%.1f, likely motion-blur%s)', ...
            round(sldFrame.Value), dNfr, size(dLastXY,1), ELONG_BLUR, offTxt));
    end

    function drawRings(xy, r, th, col, sty)   % one NaN-separated ring per spot, in one plot call
        if isempty(xy), return; end
        if nargin < 5 || isempty(sty), sty = '-'; end
        cx = xy(:,1) + r*cos(th); cy = xy(:,2) + r*sin(th);
        X = [cx, nan(size(cx,1),1)].'; Y = [cy, nan(size(cy,1),1)].';
        plot(axPrev, X(:), Y(:), sty, 'Color', col, 'LineWidth', 0.8);
    end

    function tf = haveErSeg()
        tf = dCell >= 1 && dCell <= numel(matched) && ~isempty(matched(dCell).erSeg) && isfile(matched(dCell).erSeg);
    end

    function off = detOffEr(xy, frame)
        % Which detections are NOT on this frame's ER — by the SAME definition strict geodesic
        % linking uses (spt_er_support's 1 px dilation, then spt_on_er), so what the preview marks is
        % exactly what tracking would discard. Deriving it any other way here would let the picture
        % and the tracker disagree.
        %
        % One page is read per frame rather than the whole stack: the ER stack is as long as the
        % movie, and the preview only ever shows one frame. spt_seg_fg_label caches the stack-wide
        % foreground label per file, so the page read is the only cost.
        off = false(size(xy,1),1);
        if isempty(xy) || ~haveErSeg(), return; end
        ep = matched(dCell).erSeg;
        try
            if isempty(erNfr) || erNfr < 1, erNfr = numel(imfinfo(ep)); end   % O(pages) — once per cell
            t = min(max(round(frame),1), erNfr);
            m = (imread(ep, t) == spt_seg_fg_label(ep));
            off = ~spt_on_er(xy(:,1:2), spt_er_support(m));
        catch
            off = false(size(xy,1),1);
        end
    end

    function onContrast()
        dispLo = sldCMin.Value; dispHi = sldCMax.Value;
        if dispHi <= dispLo, dispHi = dispLo + max(1,abs(dispLo)*0.01); end
        redrawDisplay();
    end

    function onAutoContrast()
        % Fiji's Brightness&Contrast "Auto" ALGORITHM, transcribed exactly — but deliberately fed a
        % sample of the whole stack rather than the current frame. Fiji applied to one slice gives a
        % different range for every slice; holding one range across the movie is what "looks like
        % Fiji" means when you are scrubbing a 5703-frame acquisition. On this data that is the
        % difference between 167–561 held throughout and 190–819 that changes under the cursor.
        %
        % The old rule was a 1–99.8 percentile stretch, and on a single-molecule movie that is the
        % wrong shape of rule: the frame is almost entirely dark background, so the 99.8th percentile
        % lands inside the noise and every actual spot saturates. ImageJ instead thresholds on the
        % HISTOGRAM COUNT — it walks in from each end until it finds a bin holding more than
        % pixelCount/autoThreshold pixels — which steps over the sparse bright tail instead of
        % clipping it. That is why the preview never looked like Fiji.
        %
        % Repeated clicks halve autoThreshold exactly as ImageJ does, so pressing Auto again
        % stretches further; it resets when the frame or cell changes.
        if isempty(dLastIm), return; end
        if isempty(autoThr) || autoThr < 10, autoThr = 5000; else, autoThr = autoThr/2; end
        v = dLastIm;                                    % fall back to this frame if the cell sample is gone
        if isstruct(gStack) && isfield(gStack,'sample') && ~isempty(gStack.sample), v = gStack.sample; end
        [lo, hi] = ij_auto(v, autoThr);
        if ~isfinite(lo) || ~isfinite(hi) || hi <= lo, lo = gMin; hi = gMax; end
        applyDisplayRange(lo, hi);
    end

    function onResetContrast()
        % Fiji's Reset: the stack's true min–max. A Fiji-saved file stores exactly this range, so
        % prefer the file's own numbers when it has them.
        if dCell < 1 || dCell > numel(matched), return; end
        lo = []; hi = [];
        fc = spt_tiff_calib(matched(dCell).spt);
        if isfinite(fc.dispLo) && isfinite(fc.dispHi), lo = fc.dispLo; hi = fc.dispHi; end
        if isempty(lo) && isstruct(gStack) && isfield(gStack,'rawLo'), lo = gStack.rawLo; hi = gStack.rawHi; end
        if isempty(lo), return; end
        autoThr = [];                                   % a Reset restarts Auto's halving, as in ImageJ
        applyDisplayRange(lo, hi);
    end

    function applyDisplayRange(lo, hi)
        dispLo = clampv(lo, gMin, gMax);
        dispHi = clampv(max(hi, dispLo+eps), dispLo+eps, gMax);
        setSlider(sldCMin, dispLo); setSlider(sldCMax, dispHi);
        redrawDisplay();
    end

    function onPlay()
        if ~isempty(playTimer) && isvalid(playTimer) && strcmp(playTimer.Running,'on'), stopPlay(); return; end
        if dCell < 1 || dNfr < 2, return; end
        if isempty(playTimer) || ~isvalid(playTimer)
            playTimer = timer('ExecutionMode','fixedRate','Period',0.08,'BusyMode','drop','TimerFcn',@(~,~) playTick());
        end
        if ~isempty(btnPlay) && isgraphics(btnPlay), btnPlay.Text = '⏸ Pause'; end
        start(playTimer);
    end

    function stopPlay()
        try, if ~isempty(playTimer) && isvalid(playTimer) && strcmp(playTimer.Running,'on'), stop(playTimer); end, catch, end
        if ~isempty(btnPlay) && isgraphics(btnPlay), btnPlay.Text = '▶ Play'; end
    end

    function playTick()
        if ~isvalid(fig) || dCell < 1 || dNfr < 1, stopPlay(); return; end
        fr = round(sldFrame.Value) + 1; if fr > dNfr, fr = 1; end
        sldFrame.Value = fr; drawDetPreview(); updateRateMarker(); drawnow limitrate;
    end

    function onClose()
        try, if ~isempty(playTimer) && isvalid(playTimer), stop(playTimer); delete(playTimer); end, catch, end
        try, if ~isempty(playerCtl) && isstruct(playerCtl), playerCtl.stop(); end, catch, end
        delete(fig);
    end

    function drawDetHist()
        if isempty(axHist) || ~isgraphics(axHist), return; end
        cla(axHist);
        if isempty(dPool), title(axHist,'(no candidates)'); return; end
        histogram(axHist, dPool, 60, 'FaceColor',[0.5 0.6 0.8], 'EdgeColor','none');
        try, set(axHist,'YScale','log'); catch, end
        thr = curDetThr();
        if ~isempty(thr), xline(axHist, thr, 'r-', 'LineWidth',1.5, 'Label','thr'); end
        xlabel(axHist,'DoG quality'); ylabel(axHist,'count');
        title(axHist, sprintf('pooled candidates n=%d', numel(dPool)));
    end

    function drawDetRate()
        if isempty(axRate) || ~isgraphics(axRate), return; end
        cla(axRate); hRateMk = [];
        if dCell < 1 || dNfr < 1, return; end
        [dRateF, dRateC] = spt_count_per_frame(matched(dCell).spt, spnDiam.Value, PXUM, curDetThr(), 120);
        plot(axRate, dRateF, dRateC, '-', 'Color',[0.2 0.5 0.7], 'LineWidth',1, 'HitTest','off');
        hold(axRate,'on');
        hRateMk = xline(axRate, round(sldFrame.Value), 'r-', 'HitTest','off');
        hold(axRate,'off');
        xlim(axRate,[1 max(dNfr,2)]); xlabel(axRate,'frame'); ylabel(axRate,'#spots');
        title(axRate, sprintf('spots / frame · median %.0f  (click to jump)', median(dRateC)));
        axRate.ButtonDownFcn = @(s,e) onRateClick();   % click the trace -> go to that frame
    end

    function updateRateMarker()
        if ~isempty(hRateMk) && isgraphics(hRateMk), hRateMk.Value = round(sldFrame.Value); end
    end

    function onRateClick()
        if isempty(axRate) || ~isgraphics(axRate) || dNfr < 1, return; end
        cp = axRate.CurrentPoint; fr = round(cp(1,1));
        fr = min(max(fr,1), dNfr);
        sldFrame.Value = fr;
        drawDetPreview(); updateRateMarker();
    end

    % ---------------- Tab 3: Track (TrackMate-style params + project + batch) ----------------
    function buildTrackTab(parent)
        g = uigridlayout(parent,[3 1],'RowHeight',{150,'1x',58},'Padding',[8 8 8 8],'RowSpacing',6);
        cp = uigridlayout(g,[4 1],'RowHeight',{26,26,26,38},'Padding',[0 0 0 0],'RowSpacing',6);

        % row 1 — tracking (linking) params
        r1 = uigridlayout(cp,[1 11],'ColumnWidth',{92,54,112,54,78,44,118,14,46,140,'1x'}, ...
            'Padding',[0 0 0 0],'ColumnSpacing',6);
        uilabel(r1,'Text','Link dist (µm)','HorizontalAlignment','right');
        spnLink = uispinner(r1,'Limits',[0.05 10],'Value',0.8,'Step',0.1);
        uilabel(r1,'Text','Max gap dist (µm)','HorizontalAlignment','right');
        spnGap = uispinner(r1,'Limits',[0.05 20],'Value',1.4,'Step',0.1);
        uilabel(r1,'Text','Max gap (fr)','HorizontalAlignment','right');
        spnInt = uispinner(r1,'Limits',[0 20],'Value',1,'Step',1);
        ddMode = uidropdown(r1,'Items',{'Euclidean','ER-penalty','ER-geodesic'},'Value','ER-penalty', ...
            'Tooltip',['Linking mode, softest→strictest. Euclidean = distance only. ER-penalty = SOFT: ' ...
            'distance·(1+λ·off-ER-fraction) — off-ER links cost more but are allowed. ER-geodesic = STRICT: ' ...
            'shortest path THROUGH the ER, and off-ER / unreachable links are FORBIDDEN (on-ER links only; ' ...
            '±1 px offset tolerated). In strict mode a detection off its OWN frame''s ER is excluded from ' ...
            'tracking entirely — it stays in the spots CSV with a blank TRACK_ID — so expect fewer, shorter ' ...
            'tracks; and a frame whose ER mask is missing contributes NOTHING (fails closed), counted in the ' ...
            'settings file as tracking.frames_no_er_mask. A cell with no ER segmentation at all is explicitly ' ...
            'downgraded to Euclidean, with the requested mode recorded as tracking.link_mode_req.']);
        uilabel(r1,'Text','λ','HorizontalAlignment','right');
        spnLam = uispinner(r1,'Limits',[0 20],'Value',3,'Step',0.5,'Tooltip','ER penalty weight (ER modes)');
        uibutton(r1,'Text','⚖ Compare methods','ButtonPushedFcn',@(s,e) onCompareModes(), ...
            'Tooltip',['Open a window comparing all 3 linking methods (Euclidean · ER-penalty · ER-geodesic) on the ' ...
            'current Detect cell: track counts per method, plus a list of the places they link a spot differently — ' ...
            'pick one and it plays as three side-by-side videos, one per method, over the real frames. Saves an MP4.']);
        uilabel(r1,'Text','');   % spacer

        % row 2 — project + run + detection readout
        detTip = ['Detection is NOT re-tuned here — each cell keeps its Detect-tab setting ' ...
            '(diameter + Top%, stored per cell). Cells never opened in Detect fall back to Top 10%.'];
        r2 = uigridlayout(cp,[1 6],'ColumnWidth',{60,'1x',58,150,130,132},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uilabel(r2,'Text','Project','HorizontalAlignment','right');
        eProj = uieditfield(r2,'text','Placeholder','local output folder — tracks/ written here');
        uibutton(r2,'Text','Pick…','ButtonPushedFcn',@(s,e) onPickProject());
        lblTrkDet = uilabel(r2,'Text','det: —','HorizontalAlignment','right','FontColor',[0.30 0.45 0.55], ...
            'Tooltip','Detection setting the current Detect-tab cell will be tracked with (diameter + Top% / absolute threshold).');
        btR = uibutton(r2,'Text','▶ Run this cell','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70], ...
            'FontColor','w','ButtonPushedFcn',@(s,e) onTrackRun(),'Tooltip',detTip);
        btB = uibutton(r2,'Text','▶▶ Run all ticked','FontWeight','bold','ButtonPushedFcn',@(s,e) onTrackBatch(),'Tooltip',detTip);

        % row 3 — filter tracks + export the _filtered pair
        r3 = uigridlayout(cp,[1 8],'ColumnWidth',{32,'1x',134,58,142,58,120,96},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uilabel(r3,'Text','Cell','HorizontalAlignment','right');
        ddCur = uidropdown(r3,'Items',{'(scan first)'},'ValueChangedFcn',@(s,e) onCurCell());
        uilabel(r3,'Text','Min track length (fr)','HorizontalAlignment','right');
        spnMinLen = uispinner(r3,'Limits',[1 1e5],'Value',50,'Step',1,'ValueChangedFcn',@(s,e) onCurParam());
        uilabel(r3,'Text','Min displacement (µm)','HorizontalAlignment','right');
        spnMinDisp = uispinner(r3,'Limits',[0 100],'Value',0,'Step',0.1,'ValueChangedFcn',@(s,e) onCurParam());
        btExp = uibutton(r3,'Text','Export cell','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70],'FontColor','w', ...
            'ButtonPushedFcn',@(s,e) onCurApply(false), ...
            'Tooltip','Write _tracks_filtered.xml + _spots_filtered.csv for this cell (only tracks are filtered; every detection is kept).');
        btExpAll = uibutton(r3,'Text','Export all','FontWeight','bold','ButtonPushedFcn',@(s,e) onCurApply(true), ...
            'Tooltip','Same, for every tracked cell.');

        % row 4 — one shared status line (bold + larger: this is the only live progress readout)
        lblTrk = uilabel(cp,'Text','Set a project folder, then Run. Filter by length / displacement, then Export the _filtered pair for the Analyze tool.', ...
            'FontColor',[0.45 0.45 0.45],'FontSize',13.5,'FontWeight','bold');
        try, lblTrk.WordWrap = 'on'; catch, end   % the filter summary is long; never clip its tail
        lblCur = lblTrk;   % the filter code writes to this same status line

        % ---- main: left = filter feedback plots, right = embedded player ----
        mn = uigridlayout(g,[1 2],'ColumnWidth',{'1.05x','1x'},'Padding',[0 0 0 0],'ColumnSpacing',8);
        lp = uigridlayout(mn,[2 1],'RowHeight',{'0.85x','1.15x'},'Padding',[0 0 0 0],'RowSpacing',6);
        axCur = uiaxes(lp); title(axCur,'track length distribution');
        axCurTrk = uiaxes(lp); axCurTrk.Toolbar.Visible = 'off'; title(axCurTrk,'tracks: kept vs removed');
        rp = uigridlayout(mn,[2 1],'RowHeight',{28,'1x'},'Padding',[0 0 0 0],'RowSpacing',4);
        ph = uigridlayout(rp,[1 3],'ColumnWidth',{196,58,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uibutton(ph,'Text','🎲 Play N random','ButtonPushedFcn',@(s,e) sampleVideo(), ...
            'Tooltip','Animate N random tracks that PASS the current filter, over the SPT frames in the player below.');
        spnSampN = uispinner(ph,'Limits',[1 40],'Value',8,'Step',1,'Tooltip','How many random (kept) tracks to play.');
        uilabel(ph,'Text','random KEPT tracks · play · scrub · ER/mito overlay · save video','FontColor',[0.5 0.5 0.5]);
        playerCtl = spt_track_movie(rp);     % embedded player fills rp''s second row

        txtLog = uitextarea(g,'Editable','off','Value',{'Track log:'});
    end

    function updateTrkDet()   % live readout of the detection setting the current cell will track with
        if isempty(lblTrkDet) || ~isgraphics(lblTrkDet), return; end
        if dCell < 1 || dCell > numel(matched), lblTrkDet.Text = 'det: —'; return; end
        c = matched(dCell);
        if isfield(c,'thrAbs') && ~isempty(c.thrAbs), ds = sprintf('thr %s', thrStr(c.thrAbs));
        else, ds = sprintf('Top %.3g%%', getf(c,'keepPct',10)); end
        lblTrkDet.Text = sprintf('det: %s · %.2g µm', ds, getf(c,'diamUm',0.5));
    end

    function sampleVideo()   % play N random KEPT tracks in the embedded player
        if isempty(curC) || isempty(curC.len), setTrk('Run or pick a tracked cell first.',[0.6 0.4 0.1]); return; end
        km = curKept(); keptIds = curC.trackId(km);
        if isempty(keptIds), setTrk('No tracks pass the current filter — loosen min length / displacement.',[0.6 0.4 0.1]); return; end
        K = min(round(spnSampN.Value), numel(keptIds));
        sel = keptIds(randperm(numel(keptIds), K));
        R = playRFromCur();
        if isempty(R), setTrk('Could not load the image for this cell.',[0.6 0.4 0.1]); return; end
        playerCtl.load(R, sel);
        setTrk(sprintf('Playing %d random kept tracks in the player.', K),[0.2 0.5 0.2]);
    end

    function R = playRFromCur()   % reconstruct a minimal R (for the player) from the loaded cell's CSV
        R = [];
        if isempty(curC) || dCurCell < 1 || dCurCell > numel(matched), return; end
        c = matched(dCurCell); if ~isfile(c.spt), return; end
        S = curC.spots;
        R = struct(); [~, R.base] = fileparts(c.spt); R.sptPath = c.spt;
        R.erPath   = ''; if ~isempty(c.erSeg)   && isfile(c.erSeg),   R.erPath   = c.erSeg;   end
        R.mitoPath = ''; if ~isempty(c.mitoSeg) && isfile(c.mitoSeg), R.mitoPath = c.mitoSeg; end
        R.x = colv(S,'X_um')/PXUM + 1; R.y = colv(S,'Y_um')/PXUM + 1;   % µm -> 1-based px
        R.frame = colv(S,'FRAME'); R.trackId = colv(S,'TRACK_ID');
    end

    function onPickProject()
        start = pwd; if ~isempty(eProj.Value) && isfolder(eProj.Value), start = eProj.Value; end
        d = uigetdir(start, 'Pick a LOCAL project / output folder');
        if isequal(d, 0), return; end
        eProj.Value = d;
    end

    function prm = gatherPrm()
        switch ddMode.Value
            case 'Euclidean',   mode = 'euclid';
            case 'ER-geodesic', mode = 'geodesic';
            otherwise,          mode = 'penalty';
        end
        prm = struct('linkUm',spnLink.Value,'gapUm',spnGap.Value,'maxGap',round(spnInt.Value), ...
            'erAware',~strcmp(mode,'euclid'),'linkMode',mode,'lambda',spnLam.Value,'pxUm',PXUM,'dtS',DTS);
    end

    function onCompareModes()
        if dCell < 1 || dCell > numel(matched), setTrk('Pick a cell in the Detect tab first.',[0.75 0.1 0.1]); return; end
        cel = matched(dCell);
        if isempty(cel.erSeg) || ~isfile(cel.erSeg)
            setTrk('This cell has no ER segmentation — the ER modes need it.',[0.6 0.4 0.1]); return; end
        prm = gatherPrm();
        try
            copts = struct();   % open the comparison at the SAME min-length as the export filter, so counts match the pipeline
            if ~isempty(spnMinLen) && isgraphics(spnMinLen), copts.minLen = spnMinLen.Value; end
            spt_compare_app(cel, prm, copts);   % standalone 3-way (Euclidean · ER-penalty · ER-geodesic) comparison window
            setTrk('Opened the linking-method comparison window (Euclidean · ER-penalty · ER-geodesic).',[0.2 0.5 0.2]);
        catch ME
            setTrk(['Compare failed: ' ME.message], [0.75 0.1 0.1]);
        end
    end

    function onTrackRun()
        if trkBusy, return; end
        if dCell < 1 || dCell > numel(matched), setTrk('Pick a cell in the Detect tab first.',[0.75 0.1 0.1]); return; end
        if isempty(strtrim(eProj.Value)), setTrk('Set a project folder first.',[0.75 0.1 0.1]); return; end
        runCells(dCell, strtrim(eProj.Value));
    end

    function onTrackBatch()
        if trkBusy, return; end
        idxs = find([matched.use]);
        if isempty(idxs), setTrk('No ticked cells to run.',[0.75 0.1 0.1]); return; end
        if isempty(strtrim(eProj.Value)), setTrk('Set a project folder first.',[0.75 0.1 0.1]); return; end
        runCells(idxs, strtrim(eProj.Value));
    end

    function runCells(idxs, pdir, actor)
        if nargin < 3, actor = btR; end
        trkBusy = true; setBusy(true, actor);
        cleanupBusy = onCleanup(@() setBusy(false, actor));   % restore even if a cell throws
        tracksDir = fullfile(pdir,'tracks'); prm = gatherPrm(); tAll = tic;
        logLine(sprintf('▶ RUN %d cell(s) · %s · link %.3g µm · gap %.3g µm / %d fr · λ %.3g -> %s', ...
            numel(idxs), ddMode.Value, prm.linkUm, prm.gapUm, prm.maxGap, prm.lambda, tracksDir));
        % the CURRENT Detect-tab threshold policy — inherited by any ticked cell that wasn't previewed
        uiMode = 'pct'; uiQual = 0;
        if ~isempty(ddThrMode) && isgraphics(ddThrMode), uiMode = ddThrMode.Value; end
        if ~isempty(spnQual)   && isgraphics(spnQual),   uiQual = spnQual.Value; end
        for kk = 1:numel(idxs)
            k = idxs(kk); cel = resolveDetThr(matched(k), uiMode, uiQual);
            tCell = tic;
            prm.progressFcn = @(frac,msg) setTrk(sprintf('⏳ [%d/%d] %s — %s   (%s elapsed)', ...
                kk, numel(idxs), cel.key, msg, hms(toc(tCell))), [0.15 0.35 0.60]);
            try
                R = spt_process_cell(cel, prm);
                spt_write_outputs(R, tracksDir);
                spt_write_settings(tracksDir, R.base, cel, prm, R);              % per-cell provenance: detection + tracking method + params
                spt_append_detection_summary(tracksDir, R.base, cel, prm, R);    % one-row-per-cell project table
                if strcmpi(getf(cel,'thrMode','pct'),'qual'), ds = sprintf('quality ≥ %.4g', getf(cel,'qualThr',getf(cel,'thrAbs',0)));
                elseif isfield(cel,'thrAbs') && ~isempty(cel.thrAbs), ds = sprintf('top %.3g%% (thr %s)', getf(cel,'keepPct',6), thrStr(cel.thrAbs));
                else, ds = sprintf('top %.3g%%', getf(cel,'keepPct',6)); end
                el = toc(tCell);
                nSp  = numel(R.spotId);
                nTrk = nnz(~isnan(R.trackId));                       % detections that ended up in a track
                pct  = 100*nTrk/max(nSp,1);
                logLine(sprintf('   %s · %s · %d frames · %d spots -> %d tracked (%.0f%%) in %d tracks', ...
                    cel.key, hms(el), R.nFrames, nSp, nTrk, pct, R.nTracks));
                % why detections were rejected — the strict ER rule is the big one, so name it
                if strcmp(getf(R,'linkMode','penalty'),'geodesic')
                    logLine(sprintf('     ER-geodesic (strict): %d spots rejected as off-ER (%.1f%%)%s', ...
                        getf(R,'nDetsOffEr',0), 100*getf(R,'nDetsOffEr',0)/max(nSp,1), ...
                        tern(getf(R,'nFramesNoErMask',0)>0, sprintf(' · %d frames had NO ER mask (nothing tracked there)', getf(R,'nFramesNoErMask',0)), '')));
                elseif ~strcmp(getf(R,'linkMode','penalty'), getf(R,'linkModeReq','penalty'))
                    logLine(sprintf('     %s requested but NOT applied (no ER segmentation) — linked %s', ...
                        getf(R,'linkModeReq','?'), getf(R,'linkMode','?')));
                end
                logLine(sprintf('     detection: diam %.2g µm · %s%s -> _tracks.xml + _spots.csv + _settings.txt', ...
                    getf(cel,'diamUm',0.5), ds, tern(R.erAware,' · ER-aware','')));
            catch ME
                logLine(sprintf('   %s: ERROR — %s', cel.key, ME.message));
                setTrk(sprintf('%s FAILED — %s', cel.key, ME.message), [0.75 0.1 0.1]);
            end
        end
        tot = toc(tAll);
        logLine(sprintf('✔ RUN done — %d cell(s) in %s -> %s', numel(idxs), hms(tot), tracksDir));
        setTrk(sprintf('✔ Run done — %d cell(s) in %s. Now set the filter and Export.', numel(idxs), hms(tot)), [0.15 0.50 0.20]);
        selectCurateCell(idxs(end));   % load the last run cell into the filter view (map + histogram)
        trkBusy = false;
    end

    function cel = resolveDetThr(cel, uiMode, uiQual)
        % Bake the detection-threshold policy for this run. A cell that was PREVIEWED carries its own
        % thrMode/thrAbs; one that wasn't inherits the current Detect-tab policy (uiMode/uiQual) — so
        % "Quality ≥ X" set in the tab applies to every ticked cell, not only the one on screen.
        mode = getf(cel,'thrMode', uiMode);
        cel.thrMode = mode;
        if strcmpi(mode,'qual')
            qv = getf(cel,'qualThr', uiQual); if ~(qv > 0), qv = uiQual; end
            cel.qualThr = qv;
            if qv > 0, cel.thrAbs = qv; else, cel.thrAbs = []; end   % 0 -> unset -> engine MAD fallback
        end
        % pct mode: keep cel.thrAbs if previewed, else [] -> spt_process_cell pools + keepPct
    end

    function selectCurateCell(idx)   % point the filter dropdown at a cell and load it
        if isempty(ddCur) || ~isgraphics(ddCur) || isempty(ddCur.ItemsData), return; end
        for i = 1:numel(ddCur.ItemsData)
            if isequal(ddCur.ItemsData{i}, idx), ddCur.Value = ddCur.ItemsData{i}; break; end
        end
        onCurCell();
    end

    function setTrk(msg, col)
        if ~isempty(lblTrk) && isgraphics(lblTrk), lblTrk.Text = msg; lblTrk.FontColor = col; drawnow limitrate; end
    end

    function setBusy(tf, actor)
        % Unmistakable feedback that a click landed and a long job is running: the button that
        % started it turns amber and says so, every other action button is disabled so a second run
        % cannot be launched underneath, and everything is restored when the job finishes.
        for b = [btR btB btExp btExpAll]
            if isempty(b) || ~isgraphics(b), continue; end
            b.Enable = tern(tf,'off','on');
        end
        if nargin >= 2 && ~isempty(actor) && isgraphics(actor)
            if tf
                actor.UserData = {actor.Text, actor.BackgroundColor, actor.FontColor};
                actor.Text = '⏳ working…'; actor.BackgroundColor = [0.90 0.58 0.10];
                actor.FontColor = 'w'; actor.Enable = 'on';     % kept live so the amber reads clearly
            elseif iscell(actor.UserData) && numel(actor.UserData) == 3
                actor.Text = actor.UserData{1}; actor.BackgroundColor = actor.UserData{2};
                actor.FontColor = actor.UserData{3}; actor.UserData = [];
            end
        end
        drawnow;
    end

    function s = hms(sec)   % compact elapsed time for the log
        if sec < 60, s = sprintf('%.1f s', sec);
        else, s = sprintf('%d m %02.0f s', floor(sec/60), mod(sec,60)); end
    end

    function logLine(s)
        if ~isempty(txtLog) && isgraphics(txtLog), txtLog.Value = [txtLog.Value; {s}]; drawnow limitrate; end
    end

    % ---------------- Filter logic — controls live in the Track & filter tab ----------------
    function refreshCurateCells()
        if isempty(ddCur) || ~isgraphics(ddCur), return; end
        idxs = find([matched.use]);
        if isempty(idxs), ddCur.Items = {'(no cells)'}; ddCur.ItemsData = {}; dCurCell = 0; return; end
        ddCur.Items = {matched(idxs).key}; ddCur.ItemsData = num2cell(idxs);
        ddCur.Value = ddCur.ItemsData{1}; onCurCell();
    end

    function onCurCell()
        if isempty(ddCur) || isempty(ddCur.ItemsData), dCurCell = 0; return; end
        dCurCell = ddCur.Value; curC = [];
        if dCurCell < 1 || dCurCell > numel(matched), return; end
        [~, base] = fileparts(matched(dCurCell).spt);
        pdir = ''; if ~isempty(eProj) && isgraphics(eProj), pdir = strtrim(eProj.Value); end
        csv = fullfile(pdir, 'tracks', [base '_spots.csv']);
        if isempty(pdir) || ~isfile(csv)
            cla(axCur); if ~isempty(axCurTrk) && isgraphics(axCurTrk), cla(axCurTrk); title(axCurTrk,'tracks: kept vs removed'); end
            lblCur.Text = sprintf('%s: no tracks yet — run Track (Tab 3) into the project folder first.', matched(dCurCell).key);
            lblCur.FontColor = [0.6 0.4 0.1]; return;
        end
        try, curC = spt_curate_read(csv); catch ME, lblCur.Text = ['read failed: ' ME.message]; lblCur.FontColor=[0.75 0.1 0.1]; return; end
        drawCurHist();
    end

    function onCurParam(), drawCurHist(); end

    function dt = curDt()
        % The loaded cell's own seconds-per-frame, from the spots CSV rather than the top bar.
        dt = NaN;
        if isempty(curC) || ~istable(curC.spots), return; end
        V = curC.spots.Properties.VariableNames;
        if ~all(ismember({'FRAME','T_s'}, V)), return; end
        FR = double(curC.spots.FRAME); Ts = double(curC.spots.T_s);
        ok = isfinite(FR) & isfinite(Ts) & FR > 0;
        if any(ok), dt = median(Ts(ok)./FR(ok)); end
        if ~(isfinite(dt) && dt > 0), dt = NaN; end
    end

    function m = curKept()
        m = false(0,1);
        if isempty(curC) || isempty(curC.len), return; end
        m = curC.len >= spnMinLen.Value & curC.dispUm >= spnMinDisp.Value;
    end

    function drawCurHist()
        if isempty(axCur) || ~isgraphics(axCur), return; end
        cla(axCur);
        if isempty(curC) || isempty(curC.len), title(axCur,'(no tracks)'); return; end
        km = curKept(); nk = sum(km); nAll = numel(curC.len);
        % Split the histogram at the threshold instead of drawing one colour across it. The removed
        % population has to stay visible — this histogram IS the control you set the threshold with —
        % but every NUMBER quoted from here on describes the tracks you keep. A median of 3 frames
        % under a 50-frame filter describes only what was discarded, which is not what you are
        % looking at anywhere else in the pipeline.
        nb = min(60, max(10, round(max(curC.len))));
        edges = linspace(0, max(curC.len)+1, nb+1);
        hold(axCur,'on');
        histogram(axCur, curC.len(~km), edges, 'FaceColor',[0.78 0.78 0.78], 'EdgeColor','none');
        histogram(axCur, curC.len(km),  edges, 'FaceColor',[0.13 0.6 0.25], 'EdgeColor','none');
        hold(axCur,'off');
        try, set(axCur,'YScale','log'); catch, end
        xline(axCur, spnMinLen.Value, 'r-', 'LineWidth',1.5, 'Label','min len');
        xlabel(axCur,'track length (frames)'); ylabel(axCur,'count');

        % everything below describes the KEPT set
        if nk > 0
            kl   = curC.len(km);
            medL = median(kl); maxL = max(kl);
            nDet = sum(cellfun(@numel, curC.rows(km)));
        else
            medL = NaN; maxL = NaN; nDet = 0;
        end
        % THIS cell's frame interval, recovered from its own CSV (T_s = FRAME*dt), the same way
        % spt_curate_write.m:23 does it. The app-wide DTS belongs to the Detect tab's cell, which is
        % selected independently — using it here reported 1.50 s for a 0.79 s median on the user's
        % file, a 1.9x error inside the very summary this was meant to fix.
        dtc = curDt();
        dtl = ''; if nk > 0 && isfinite(dtc) && dtc > 0, dtl = sprintf(' = %.2f s', medL*dtc); end
        if nk > 0
            title(axCur, sprintf('%d kept (green) of %d  ·  median %.0f fr%s, longest %.0f', ...
                nk, nAll, medL, dtl, maxL));
        else
            title(axCur, sprintf('0 kept of %d — the filter removes everything', nAll));
        end
        nDetAll = height(curC.spots);
        % Kept in one line and under ~150 characters: this label is shared with the track log, it is
        % not word-wrapped by default, and anything past the right edge is simply gone — which last
        % time silently ate the clause the change existed to add.
        lblCur.Text = sprintf('%s: %d/%d tracks kept (len≥%d, disp≥%.2f µm) · median %.0f fr%s, longest %.0f · %d/%d detections in kept tracks', ...
            matched(dCurCell).key, nk, nAll, round(spnMinLen.Value), spnMinDisp.Value, ...
            medL, dtl, maxL, nDet, nDetAll);
        lblCur.FontColor = [0.2 0.4 0.5];
        if nk == 0, lblCur.FontColor = [0.75 0.1 0.1]; end
        drawCurOverview();
    end

    function drawCurOverview()
        if isempty(axCurTrk) || ~isgraphics(axCurTrk), return; end
        cla(axCurTrk);
        if isempty(curC) || isempty(curC.len), title(axCurTrk,'tracks: kept vs removed'); return; end
        X = colv(curC.spots,'X_um'); Y = colv(curC.spots,'Y_um');   % CSV is in µm
        um = strcmp(ovUnits,'um');
        if ~um, X = X/PXUM + 1; Y = Y/PXUM + 1; end                  % back to 1-based px
        km = curKept();
        [xr,yr] = pathsXY(curC.rows(~km), X, Y);      % removed (grey, drawn first)
        [xk,yk] = pathsXY(curC.rows(km),  X, Y);      % kept (green, on top)
        hold(axCurTrk,'on');
        if ~isempty(xr), plot(axCurTrk, xr, yr, '-', 'Color',[0.78 0.78 0.78], 'LineWidth',0.5); end
        if ~isempty(xk), plot(axCurTrk, xk, yk, '-', 'Color',[0.13 0.6 0.25], 'LineWidth',0.7); end
        hold(axCurTrk,'off');
        axis(axCurTrk,'equal'); set(axCurTrk,'YDir','reverse');
        title(axCurTrk, sprintf('%d kept (green) · %d removed (grey)', sum(km), sum(~km)));
        if um, xlabel(axCurTrk,'x (µm)'); ylabel(axCurTrk,'y (µm)');
        else,  xlabel(axCurTrk,'x (px)'); ylabel(axCurTrk,'y (px)'); end
    end

    function onCurApply(allCells)
        pdir = ''; if ~isempty(eProj) && isgraphics(eProj), pdir = strtrim(eProj.Value); end
        if isempty(pdir)
            lblCur.Text = 'Set a project folder in the Track tab first.'; lblCur.FontColor=[0.75 0.1 0.1];
            logLine('EXPORT: no project folder set — nothing to do.'); return;
        end
        tracksDir = fullfile(pdir,'tracks');
        % Never return silently — a click that does nothing and says nothing is indistinguishable
        % from a click that did not register.
        if allCells
            idxs = find([matched.use]);
            if isempty(idxs)
                lblCur.Text = 'Nothing to export — no cells are ticked in the Match tab.';
                lblCur.FontColor = [0.75 0.35 0.05]; logLine('EXPORT: no ticked cells — nothing to do.'); return;
            end
        else
            if dCurCell < 1
                lblCur.Text = 'Pick a cell in the Cell dropdown first (or use Export all).';
                lblCur.FontColor = [0.75 0.35 0.05]; logLine('EXPORT: no cell selected — nothing to do.'); return;
            end
            idxs = dCurCell;
        end
        actor = btExp; if allCells, actor = btExpAll; end
        setBusy(true, actor);
        cleanupBusy = onCleanup(@() setBusy(false, actor)); %#ok<NASGU>
        ml = spnMinLen.Value; mdp = spnMinDisp.Value; done = 0; tAll = tic; nMiss = 0;
        logLine(sprintf('▶ EXPORT %d cell(s) · filter: min length %d fr · min displacement %.3g µm', numel(idxs), round(ml), mdp));
        for k = idxs
            [~, base] = fileparts(matched(k).spt);
            csv = fullfile(tracksDir, [base '_spots.csv']);
            if ~isfile(csv)
                logLine(sprintf('   %s: SKIPPED — no %s_spots.csv (run the cell first)', matched(k).key, base));
                nMiss = nMiss + 1; continue;
            end
            try
                tCell = tic;
                setTrk(sprintf('⏳ exporting %s…', matched(k).key), [0.15 0.35 0.60]);
                Cc = spt_curate_read(csv);
                km = Cc.len >= ml & Cc.dispUm >= mdp;
                st = spt_curate_write(Cc, km, tracksDir, base);
                spt_append_curation_settings(tracksDir, base, ml, mdp, st);   % stamp the filter params into _settings.txt
                nRej = st.before - st.after;
                logLine(sprintf('   %s · %s · %d -> %d tracks kept (%d rejected, %.0f%%) · %d detections written', ...
                    matched(k).key, hms(toc(tCell)), st.before, st.after, nRej, 100*nRej/max(st.before,1), st.nSpots));
                done = done + 1;
            catch ME
                logLine(sprintf('   %s: ERROR — %s', matched(k).key, ME.message));
            end
        end
        logLine(sprintf('✔ EXPORT done — %d cell(s) in %s -> _tracks_filtered.xml + _spots_filtered.csv%s', ...
            done, hms(toc(tAll)), tern(nMiss>0, sprintf(' (%d skipped)', nMiss), '')));
        lblCur.Text = sprintf('✔ Exported %d cell(s) in %s -> _tracks_filtered.xml + _spots_filtered.csv — ready for Tool 2', done, hms(toc(tAll)));
        lblCur.FontColor = [0.15 0.50 0.20];
    end
end

% ============================ local helpers ============================
function s = markCell(folderGiven, found)
% table cell for an optional channel: '–' when no folder given, else ✓/✗
if ~folderGiven, s = '–'; elseif found, s = '✓'; else, s = '✗'; end
end

function pth = subfolder(d, names)
% first existing subfolder of d matching one of `names` (case-insensitive), else ''
pth = '';
for i = 1:numel(names)
    p = fullfile(d, names{i});
    if isfolder(p), pth = p; return; end
end
L = dir(d); L = L([L.isdir]);
for i = 1:numel(names)
    for k = 1:numel(L)
        if strcmpi(L(k).name, names{i}), pth = fullfile(d, L(k).name); return; end
    end
end
end

function y = tern(c, a, b)
if c, y = a; else, y = b; end
end

function [X, Y] = pathsXY(rows, xs, ys)
% Concatenate per-track paths into NaN-separated vectors so all tracks draw in one plot() call.
X = []; Y = [];
for k = 1:numel(rows)
    r = rows{k};
    X = [X; xs(r); NaN]; %#ok<AGROW>
    Y = [Y; ys(r); NaN]; %#ok<AGROW>
end
end

function v = colv(T, name)
% Numeric column from a spots table (NaN vector if the column is absent).
if ~ismember(name, T.Properties.VariableNames), v = nan(height(T),1); return; end
c = T.(name);
if isnumeric(c), v = double(c); else, v = str2double(string(c)); end
end

function v = getf(s, f, d)
if isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end

function m = median0(x)
if isempty(x), m = NaN; else, m = median(x); end
end

function s = thrStr(t)
if isempty(t), s = 'MAD'; else, s = sprintf('%.1f', t); end
end

function p(obj, r, c)          % place a control in a uigridlayout cell / span
obj.Layout.Row = r; obj.Layout.Column = c;
end

function v = clampv(x, lo, hi)
v = min(max(x, lo), hi);
end

function setSlider(sld, val)  % set a slider Value, clamped to its Limits
if isempty(sld) || ~isgraphics(sld), return; end
sld.Value = min(max(val, sld.Limits(1)), sld.Limits(2));
end

function setSliderLimits(sld, lim)   % set slider Limits safely (span >0), keeping Value in range
if isempty(sld) || ~isgraphics(sld), return; end
if ~(lim(2) > lim(1)), lim(2) = lim(1) + 1; end
sld.Limits = lim;
sld.Value  = min(max(sld.Value, lim(1)), lim(2));
end

function [lo, hi] = ij_auto(im, autoThreshold)
%IJ_AUTO  ImageJ's ContrastAdjuster.autoAdjust, transcribed.
%
% ImageJ builds a 256-bin histogram over the image's own min..max, then walks in from each end until
% it finds a bin holding MORE than pixelCount/autoThreshold pixels. The bin edges of the first such
% bin at each end become the display range. autoThreshold starts at 5000 (so the threshold is 0.02%
% of the pixels) and halves on each repeated click.
%
% The count-based rule is the whole point. A percentile rule asks "where does the top 0.2% of the
% INTENSITY DISTRIBUTION start", which on a mostly-empty single-molecule frame is still background.
% The count rule asks "which is the first intensity level that is actually POPULATED", which walks
% past the sparse spot tail and leaves the spots unsaturated.
lo = NaN; hi = NaN;
v = double(im(:)); v = v(isfinite(v));
if isempty(v), return; end
mn = min(v); mx = max(v);
if ~(mx > mn), lo = mn; hi = mn + 1; return; end          % flat frame: any non-degenerate range

nb = 256;
edges = linspace(mn, mx, nb+1);
h = histcounts(v, edges);
thr = numel(v) / max(autoThreshold, 1);

i = find(h > thr, 1, 'first');
j = find(h > thr, 1, 'last');
if isempty(i) || isempty(j)                                % threshold too high for every bin
    lo = mn; hi = mx; return;
end
% ImageJ maps the found BIN INDICES back through the histogram's own scale.
lo = edges(i);
hi = edges(j+1);
if hi <= lo, lo = mn; hi = mx; end                         % degenerate -> full range, as ImageJ does
end

function st = stack_stats(sptPath, nSample)
%STACK_STATS  What the contrast controls need, read once per cell.
%
%   .lo/.hi     robust range for the SLIDER LIMITS (0.05/99.95 pct over sampled frames). Kept
%               percentile-based on purpose: one hot pixel must not make the sliders unusable.
%   .rawLo/.rawHi   the TRUE min/max over the sample — Fiji's Reset, and what a Fiji-saved file
%               stores in its ImageDescription.
%   .sample     a pooled subsample of pixel values across the sampled frames.
%
% The sample is why this exists. Auto used to run on the CURRENT FRAME, so the stretch changed
% every time you scrubbed; Fiji computes one range for the stack and holds it. Pooling a spread of
% frames here makes Auto stack-representative and stable, at the cost of one read per cell.
if nargin < 2, nSample = 12; end
st = struct('lo',0,'hi',1,'rawLo',0,'rawHi',1,'sample',[]);
info = imfinfo(sptPath); nfr = numel(info);
idx = unique(round(linspace(1, nfr, min(nfr, nSample))));
lo = inf; hi = -inf; rlo = inf; rhi = -inf; acc = cell(1,numel(idx));
for q = 1:numel(idx)
    im = double(imread(sptPath, idx(q))); v = im(:);
    lo = min(lo, prctile(v,0.05)); hi = max(hi, prctile(v,99.95));
    rlo = min(rlo, min(v));        rhi = max(rhi, max(v));
    acc{q} = v(1:3:end);                       % every 3rd pixel is plenty for a 256-bin histogram
end
if ~(hi > lo),   hi = lo + 1;   end
if ~(rhi > rlo), rhi = rlo + 1; end
st.lo = lo; st.hi = hi; st.rawLo = rlo; st.rawHi = rhi; st.sample = vertcat(acc{:});
end
