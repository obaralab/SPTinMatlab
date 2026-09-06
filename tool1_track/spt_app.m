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
ADVROW = 38; ADVH0 = 170; ADVH1 = 212;   % advanced row height, and the panel height with it shut / open

% Calibration is PER CELL — see cellCalib(). These two are the FALLBACK: what a cell that can supply
% nothing of its own is run with, recorded as such in the log and in that cell's _settings.txt. They
% used to be "the calibration", one pair of numbers applied to every cell in the batch, which
% mis-scaled every µm coordinate and every diffusion coefficient for cells acquired on another rig.
FB_PXUM_0 = 0.10785; FB_DTS_0 = 0.020064;   % the code literals, never reassigned
FBPXUM = FB_PXUM_0; FBDTS = FB_DTS_0;        % panel fallback: µm/px, s/frame (re-seeded per project)
dCal = struct('pixUm',FBPXUM,'dt_s',FBDTS,'srcPx','panel','srcDt','panel');   % the DETECT cell's own
cCal = dCal;                                 % the FILTER cell's own — selected independently of it
eCalPx=[]; eCalDt=[]; ddUnits=[];            % calibration edit fields + overview-units toggle (top bar)
ovUnits='um';                                % kept/removed track-map units ('um'|'px')
% Detect-tab handles + state (the Match tab's Scan refreshes the cell list)
ddCell=[]; spnDiam=[]; spnPct=[]; sldFrame=[]; eFrameNum=[]; lblDet=[]; axPrev=[]; axHist=[]; axRate=[];
spnRidge=[]; spnSize=[]; spnAlign=[]; ddBleed=[]; ddThrFrom=[]; btnAdv=[]; lblAdvWhy=[]; advG=[]; advRow=[]; advOpen=false; detSkelPg=-1; detSkelIm=[]; ddDeint=[]; ddSegEvery=[]; lblSegEvery=[];   % interleaved-acquisition controls (Detect tab)
ddThrMode=[]; spnQual=[]; lblQual=[];   % threshold mode: Top % (percentile) vs Quality ≥ (absolute DoG-quality gate)
dCell=0; dInfo=[]; dNfr=0; dPool=zeros(0,1); hRateMk=[]; dRateF=[]; dRateC=[]; imW=0; imH=0;
sldCMin=[]; sldCMax=[]; btnPlay=[]; playTimer=[];               % contrast sliders + play button/timer
dispLo=0; dispHi=1; gMin=0; gMax=1; dLastIm=[]; dLastXY=zeros(0,3); dLastShp=zeros(0,4); dLastRej=zeros(0,3);   % display range + cached frame/detections/shape
autoThr=[];   % ImageJ B&C auto-threshold; halves on repeated Auto, resets on frame/cell change
dLastOff=false(0,1);   % per-detection off-ER flag for the cached frame
erNfr=[];              % ER stack page count, cached per cell (imfinfo is O(pages))
gStack=[];    % per-cell intensity stats + pooled sample (stack_stats) — Auto works on this, not one frame
ELONG_BLUR = 1.5;   % elongation above this flags a likely motion-blurred (streaked) spot
% Track-tab handles + state
spnLink=[]; spnGap=[]; spnInt=[]; ddMode=[]; spnLam=[]; eProj=[]; lblTrk=[]; lblTrkDet=[]; txtLog=[]; trkBusy=false; spnSampN=[]; playerCtl=[];
btR=[]; btB=[]; btPct=[]; btExp=[]; btExpAll=[]; erModeTouched=false;   % the four action buttons — setBusy() drives their look
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
eCalPx = uieditfield(top,'numeric','Value',FBPXUM,'ValueDisplayFormat','%.5g','Limits',[1e-4 10], ...
    'Tooltip','µm per pixel for the CELL selected in the Detect tab — resolved from that cell; edit to override it.', ...
    'ValueChangedFcn',@(s,e) onCalChange('px'));
uilabel(top,'Text','Frame interval (s)','HorizontalAlignment','right');
eCalDt = uieditfield(top,'numeric','Value',FBDTS,'ValueDisplayFormat','%.5g','Limits',[1e-6 3600], ...
    'Tooltip',['Seconds per frame for the CELL selected in the Detect tab. Auto reads it from that ' ...
               'cell''s TIFF (ImageJ ''finterval''). The upper limit matches what the reader accepts, ' ...
               'so a slow timelapse cannot throw here.'], ...
    'ValueChangedFcn',@(s,e) onCalChange('dt'));
uibutton(top,'Text','Auto','Tooltip',['Re-read THIS CELL''s calibration from its own TIFF: pixel ' ...
    'size, frame interval, and the display range Fiji saved. Understands ImageJ/Fiji files, where ' ...
    'the scale is in XResolution and the unit is in the ImageDescription text block. It applies to ' ...
    'the selected cell only — every other cell keeps its own.'], ...
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
        eEr = uieditfield(g,'text','Placeholder','ilastik ER masks — enables the ER-penalty and ER-geodesic link modes');
        uibutton(g,'Text','Pick…','ButtonPushedFcn',@(s,e) pick(eEr));

        uilabel(g,'Text','Mito seg folder (optional)','HorizontalAlignment','right');
        eMi = uieditfield(g,'text','Placeholder','ilastik mito masks — enables per-spot mito distance');
        uibutton(g,'Text','Pick…','ButtonPushedFcn',@(s,e) pick(eMi));

        uilabel(g,'Text','Strip regex','HorizontalAlignment','right', ...
            'Tooltip',['Extra token stripped from names so SPT matches the seg files. LEAVE BLANK ' ...
                       'to read it from the file names — Scan reports which token it used. Type one ' ...
                       'only to override that.']);
        eStrip = uieditfield(g,'text','Placeholder','blank = derive it from the file names');
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

            % A BLANK field means derive the token. It used to default to '_VAPB', which silently
            % resolved no segmentations at all on any dataset named otherwise — the live data here
            % is '_C3'. Tool 2 was fixed for this; Tool 1 kept the literal and never called
            % spt_channel_token. A typed value still wins outright: the field is an override, not a
            % setting, so re-scanning a different project re-derives instead of carrying a stale one.
            if isempty(strip)
                [c, tokUsed, tokWhy, stripRe] = matchDerived(sptD, erD, miD);
            else
                c = spt_match(sptD, erD, miD, strip);
                tokUsed = strip; tokWhy = 'strip regex as typed'; stripRe = strip;
            end
            for k = 1:numel(c)
                c(k).use = true; c(k).diamUm = 0.5; c(k).keepPct = 6; c(k).thrAbs = [];
                % Carry HOW this cell was matched onto the cell record, so spt_write_settings can
                % record it beside the detection and tracking parameters. Without it the decision
                % died with the scan: Tools 2 and 3 had to re-derive the token from the file names,
                % which only works when the segmentation names are prefixes of the SPT names. A
                % regex typed here because the naming is unusual was unrecoverable downstream.
                c(k).chanTok = tokUsed;      % human-readable, e.g. '_C3'
                c(k).stripRe = stripRe;      % the regex actually passed to spt_match
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
            % NO ER SEGMENTATION -> Euclidean linking, chosen here rather than downgraded per cell.
            % The engine already falls back (spt_process_cell forces 'euclid' when the ER mask is
            % missing), so the tracks were never wrong — but the dropdown kept saying 'ER-penalty',
            % every cell recorded a DOWNGRADED mode in its settings file, and the run log implied a
            % mode that never ran. Across a large batch that is 93 lines of provenance describing
            % something that did not happen. Only touched when the user has not already moved it.
            if nEr == 0 && ~isempty(ddMode) && isgraphics(ddMode) && ~erModeTouched
                if ~strcmp(ddMode.Value,'Euclidean')
                    ddMode.Value = 'Euclidean';
                    logLine('No ER segmentations matched — link mode set to Euclidean (the ER modes need one).');
                end
            end
            lbl.Text = sprintf('%d cell(s): SPT %d, ER-seg %s, mito-seg %s · token %s (%s).', ...
                numel(c), numel(c), ...
                tern(hasEr, sprintf('%d/%d', nEr, numel(c)), 'off'), ...
                tern(hasMi, sprintf('%d/%d', nMi, numel(c)), 'off'), ...
                tern(isempty(tokUsed), '(none)', ['"' tokUsed '"']), tokWhy);
            % Amber, not green, when nothing resolved: with both seg folders set and zero matches the
            % naming convention is wrong, and that used to look identical to a successful scan.
            if (hasEr || hasMi) && nEr == 0 && nMi == 0
                lbl.FontColor = [0.6 0.4 0.1];
            else
                lbl.FontColor = [0.2 0.5 0.2];
            end
            seedPanelFallback();                 % seed the FALLBACK only — each cell resolves its own
            refreshDetectCells();                % populate the Detect tab's cell list (resolves cell 1's calibration)
            refreshCurateCells();                % populate the filter cell list
        end

        function [best, tok, why, re] = matchDerived(sptD, erD, miD)
            % The same ladder Tool 2 uses (spt_analyze_app onPickProject): the token READ from the
            % file names first, then the legacy '_VAPB', then nothing — each scored by how many
            % cells actually resolved a segmentation, so the winner is decided by the files rather
            % than by a default. The derived token is anchored and escaped; '_VAPB' is passed raw,
            % as it always was, because anchoring would defeat the infix case it exists for.
            % Seed with the strip-nothing case rather than []: it always succeeds when the SPT
            % folder is valid (the caller has already checked), so `best` is a STRUCT ARRAY from
            % here on. Returning a double [] would quietly change the class of `matched`.
            best = spt_match(sptD, erD, miD, '');
            tok  = ''; why = 'names match with nothing stripped';
            re   = '';                       % the REGEX that won, not just its human-readable token
            nBest = nResolved(best);
            cands = {};
            try
                [t0, ti] = spt_channel_token(sptD, erD, miD);
                if ~isempty(t0), cands{end+1} = {['(?:' regexptranslate('escape',t0) ')$'], t0, ti.why}; end
            catch
            end
            cands{end+1} = {'_VAPB', '_VAPB', 'legacy _VAPB token'};
            for q = 1:numel(cands)
                try mq = spt_match(sptD, erD, miD, cands{q}{1}); catch, continue; end
                nq = nResolved(mq);
                if nq > nBest, nBest = nq; best = mq; tok = cands{q}{2}; why = cands{q}{3}; re = cands{q}{1}; end
            end
            if nBest <= 0, why = 'no ER/mito matched any naming convention'; end
        end

        function n = nResolved(m)
            % How many cells this candidate actually paired with a segmentation — the only thing
            % worth scoring a naming convention on.
            n = 0;
            if isempty(m), return; end
            n = sum(arrayfun(@(x) ~isempty(x.erSeg) || ~isempty(x.mitoSeg), m));
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
        % Row 5 holds a NESTED grid, whose own minimum height is larger than a plain 26-px control
        % row — give it the extra explicitly, and the panel the room for it, or its widgets are
        % clipped by the panel edge.
        % The interleaved-acquisition controls live on their own row, COLLAPSED by default. They
        % exist for one uncommon layout — two channels alternating in one stack, an organelle
        % channel at a lower rate — and most projects have one frame of each per SPT frame and need
        % none of it. Six controls in front of everyone for that is the wrong default. The row
        % opens itself when the cell actually looks like it needs them (see advAutoShow).
        g = uigridlayout(parent,[3 1],'RowHeight',{ADVH0,22,'1x'},'Padding',[8 8 8 8],'RowSpacing',6);
        cp = uigridlayout(g,[6 6],'RowHeight',{26,26,26,26,22,0},'ColumnWidth',{56,'1x',96,66,52,66}, ...
            'Padding',[0 0 0 0],'RowSpacing',4,'ColumnSpacing',6);
        advG = g;   % the outer grid, whose first row height follows the disclosure
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
        % row 5 (built before the slider rows so the tab order reads left-to-right): the two
        % interleaved-acquisition controls. Both default to the shipped behaviour.
        % row 5: the disclosure itself, always visible and one line tall
        btnAdv = uibutton(cp,'Text','▸ interleaved acquisition & bleedthrough options', ...
            'HorizontalAlignment','left','BackgroundColor',[0.94 0.94 0.96], ...
            'Tooltip',['Options for a stack holding TWO channels alternating page by page, or an ' ...
            'organelle channel imaged at a lower rate than the particle channel. If your SPT, ER ' ...
            'and mito stacks all have the same number of frames you do not need any of this — the ' ...
            'defaults leave detection exactly as it was. The row opens on its own when a cell ' ...
            'looks like it needs it.'], 'ButtonPushedFcn',@(s,e) toggleAdv()); p(btnAdv,5,[1 3]);
        lblAdvWhy = uilabel(cp,'Text','','FontColor',[0.75 0.35 0.05]); p(lblAdvWhy,5,[4 6]);

        % Its own sub-grid: the outer columns are sized for the rows above, and these two labels do
        % not fit in them — 'Reject ridges' and 'SPT frames / organelle' both truncated to '...'.
        r5 = uigridlayout(cp,[1 15],'ColumnWidth',{58,46,50,46,46,46,52,92,64,92,84,70,60,92,'1x'}, ...
            'Padding',[0 0 0 0],'ColumnSpacing',6); p(r5,6,[1 6]);
        advRow = r5; r5.Visible = 'off';        % collapsed until the disclosure opens it
        uilabel(r5,'Text','ridge R ≤','HorizontalAlignment','right', ...
            'Tooltip',['Drop candidates shaped like a FILAMENT rather than a spot — a mitochondrion ' ...
            'bleeding through is a ridge, and a DoG breaks it into a chain of spot-sized detections. ' ...
            'The number is the largest DoG curvature RATIO to accept: lower is stricter, 2 is a ' ...
            'good starting point, 0 turns it OFF (the shipped behaviour). It is shape-only — a real ' ...
            'molecule sitting ON a mitochondrion is still a point source and is kept.']);
        % Lower limit 1, not 0.5: a curvature RATIO below 1 is not a stricter setting, it is the
        % same cut as its reciprocal — 0.1 behaves like 10. 0 (off) is reached with the down arrow
        % from 1, and onDetParam snaps anything typed into (0,1) up to 1.
        spnRidge = uispinner(r5,'Limits',[0 20],'Value',0,'Step',0.5, ...
            'ValueChangedFcn',@(s,e) onDetParam('ridge'));
        uilabel(r5,'Text','width ≤','HorizontalAlignment','right', ...
            'Tooltip',['Reject candidates WIDER than this multiple of the peak a real spot of the ' ...
            'Diameter above would make — the size half of the filter, and the half that depends on ' ...
            'the expected spot size. It catches what the shape test cannot: a filament END, a ' ...
            'CROSSING, a focal blob of bleedthrough — round enough to pass a curvature ratio, but ' ...
            'far too wide to be a single molecule. 1.6 is a good value; 0 turns it OFF.']);
        spnSize = uispinner(r5,'Limits',[0 10],'Value',0,'Step',0.1, ...
            'ValueChangedFcn',@(s,e) onDetParam('ridge'));
        uilabel(r5,'Text','align °','HorizontalAlignment','right', ...
            'Tooltip',['Reject detections that lie ALONG a mitochondrion: elongated, sitting on the ' ...
            'organelle skeleton, and pointing within this many degrees of it. This is the ' ...
            'bleedthrough the curvature test cannot see, because that test is blind to ' ...
            'orientation. Needs a mito or ER segmentation. 30 is a good value; 0 turns it OFF. ' ...
            'Measured on a contaminated channel it removed a further 19%% of detections while ' ...
            'costing NOTHING on the clean channel — a real molecule on a mitochondrion is round, ' ...
            'and a motion-blurred one points where it travelled, not along the organelle.']);
        spnAlign = uispinner(r5,'Limits',[0 90],'Value',0,'Step',5, ...
            'ValueChangedFcn',@(s,e) onDetParam('ridge'));
        uilabel(r5,'Text','thr from','HorizontalAlignment','right', ...
            'Tooltip',['WHICH FRAMES SET THE Top-%% THRESHOLD. Bleedthrough contributes a flood of ' ...
            'candidates, so pooling over contaminated frames lets the contamination set the ' ...
            'sensitivity for the CLEAN frames too — and by a different amount in every cell, in ' ...
            'proportion to how contaminated it is. Point this at the clean parity and the threshold ' ...
            'is set by real molecules alone. Measured over three cells it took the clean channel ' ...
            'from 16.8/35.4/47.6 detections per frame (a 2.8x spread between cells) to ' ...
            '82.7/63.7/65.1 (1.3x) — most of that apparent variation was the threshold moving.']);
        ddThrFrom = uidropdown(r5,'Items',{'all frames','odd 1,3,5…','even 2,4,6…'}, ...
            'ItemsData',{'all','odd','even'},'Value','all', ...
            'ValueChangedFcn',@(s,e) onDetParam('diam'));
        uilabel(r5,'Text','on frames','HorizontalAlignment','right', ...
            'Tooltip',['WHICH FRAMES the two rejection tests above apply to. When only one of two ' ...
            'interleaved particle channels carries bleedthrough, gate that parity alone: the clean ' ...
            'channel then keeps every detection it would have had, and pays nothing for a filter ' ...
            'it does not need. Step the Frame arrows by one to see which parity is contaminated. ' ...
            'Numbering is 1-based, matching the Frame box (the spots CSV counts from 0).']);
        ddBleed = uidropdown(r5,'Items',{'all frames','odd 1,3,5…','even 2,4,6…'}, ...
            'ItemsData',{'all','odd','even'},'Value','all', ...
            'ValueChangedFcn',@(s,e) onDetParam('ridge'));
        uilabel(r5,'Text','de-interleave','HorizontalAlignment','right', ...
            'Tooltip',['If this stack holds TWO channels alternating page by page, pick the pages ' ...
            'that are the particle channel: "odd" = pages 1,3,5…, "even" = 2,4,6…. Detection, the ' ...
            'threshold tuner and the preview all then see only those pages, renumbered as ' ...
            'consecutive frames — and the FRAME INTERVAL IS DOUBLED, because the real time between ' ...
            'the frames you kept is twice the time between pages. Leave "off" for a normal stack.']);
        ddDeint = uidropdown(r5,'Items',{'off','odd pages','even pages'},'Value','off', ...
            'ValueChangedFcn',@(s,e) onDetParam('deint'));
        uilabel(r5,'Text','organelle /','HorizontalAlignment','right', ...
            'Tooltip',['When the ER/mito channel is imaged at a LOWER RATE than the particle ' ...
            'channel, each organelle frame is held across that many SPT frames — "2 SPT frames" ' ...
            'means SPT frames 1 and 2 both read organelle page 1, frames 3 and 4 read page 2, and ' ...
            'so on. Nothing is duplicated on disk; it is an index map. "auto" reads the ratio from ' ...
            'the page counts, and the label to the right shows what it found. Getting this wrong ' ...
            'does not misalign a few frames — it leaves every frame past the end of the organelle ' ...
            'stack with NO mask at all, and no mito/ER distance for that part of the movie.']);
        ddSegEvery = uidropdown(r5,'Items',{'auto','1 SPT frame','2 SPT frames','3 SPT frames','4 SPT frames'}, ...
            'ItemsData',{'auto','1','2','3','4'},'Value','auto', ...
            'ValueChangedFcn',@(s,e) onDetParam('segevery'));
        lblSegEvery = uilabel(r5,'Text','','FontColor',[0.2 0.4 0.5]);
        uilabel(r5,'Text','');

        % row 3: frame slider + play
        % A slider alone cannot step: across ~12000 frames one pixel is several frames, so landing
        % on a chosen frame — or comparing frame t with t+1, which is exactly what you do to judge
        % an interleaved stack — was impossible. Nested grid so the stepper and a typed frame
        % number fit without disturbing the rows above.
        r3 = uigridlayout(cp,[1 6],'ColumnWidth',{56,'1x',32,32,64,66}, ...
            'Padding',[0 0 0 0],'ColumnSpacing',4); p(r3,3,[1 6]);
        uilabel(r3,'Text','Frame','HorizontalAlignment','right');
        sldFrame = uislider(r3,'Limits',[1 2],'Value',1,'MajorTicks',[],'ValueChangedFcn',@(s,e) onDetFrame());
        uibutton(r3,'Text','◀','Tooltip','Previous frame (one page back)','ButtonPushedFcn',@(s,e) onDetStep(-1));
        uibutton(r3,'Text','▶','Tooltip','Next frame (one page forward)','ButtonPushedFcn',@(s,e) onDetStep(+1));
        eFrameNum = uieditfield(r3,'numeric','Value',1,'Limits',[1 Inf],'RoundFractionalValues',true, ...
            'Tooltip','Jump straight to a frame number.','ValueChangedFcn',@(s,e) onDetFrameNum());
        btnPlay = uibutton(r3,'Text','▶ Play','ButtonPushedFcn',@(s,e) onPlay());
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
        spt_axes_policy(axPrev);   % redrawn on every frame — see the helper for why hover tips break
        rp = uigridlayout(ap,[2 1],'RowHeight',{'1x','1x'},'Padding',[0 0 0 0],'RowSpacing',8);
        axHist = uiaxes(rp); title(axHist,'pooled spot quality');
        axRate = uiaxes(rp); title(axRate,'spots / frame');
        spt_axes_policy([axHist axRate]);
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
        % Resolve and SHOW this cell's calibration before the unreadable-stack bail-out, or the top
        % bar keeps displaying the previous cell's numbers while dCell already points at this one.
        [~, dBase] = fileparts(c.spt);
        dCal = cellCalib(dBase, c.spt, projDir());
        showCal(dCal);
        showSegEvery();                      % this cell's SPT/organelle page ratio
        advAutoShow(c);                      % ...and open the interleaved row only if it applies
        showInterleaveWarning(c.spt, c.mitoSeg);   % ...and whether this stack is a raw two-channel one
        if dNfr < 1, lblDet.Text = 'Could not read the SPT stack.'; lblDet.FontColor = [0.75 0.1 0.1]; return; end
        imW = dInfo(1).Width; imH = dInfo(1).Height;   % pixel dimensions (for the status readout + track overview)
        % THIS cell's calibration, resolved once here rather than on every redraw: the preview
        % re-detects on every frame and re-reading the TIFF metadata each time would be felt. The two
        % top-bar fields follow the selection, so they always describe the cell you are looking at.
        spnDiam.Value = getf(c,'diamUm',0.5);
        spnPct.Value  = getf(c,'keepPct',6);
        ddThrMode.Value = getf(c,'thrMode','pct');
        spnQual.Value   = getf(c,'qualThr',0);
        syncThrModeUI();
        sldFrame.Limits = [1 max(detFrameCount(),1)];
        sldFrame.Value  = min(max(round(sldFrame.Value),1), dNfr);
        syncFrameNum();
        stopPlay();
        erNfr = []; dLastOff = false(0,1); dLastRej = zeros(0,3); detSkelPg = -1; detSkelIm = [];  % new cell -> drop the cached overlays
        gStack = spt_stack_range(c.spt, 12);                           % limits + a pooled stack sample
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
            [aLo, aHi] = spt_ij_auto(gStack.sample, 5000);
            dispLo = clampv(aLo, gMin, gMax); dispHi = clampv(max(aHi,dispLo+eps), dispLo+eps, gMax);
        end
        setSlider(sldCMin, dispLo); setSlider(sldCMax, dispHi);
        poolAndDraw();
    end

    function poolAndDraw()
        if dCell < 1 || dNfr < 1, return; end
        lblDet.Text = 'Pooling spot quality…'; lblDet.FontColor = [0.45 0.45 0.45]; drawnow;
        po = detOpts(); [po.stride, po.offset] = deintValue(); po.bleedFrames = bleedValue();
        if ~isempty(ddThrFrom) && isgraphics(ddThrFrom)
            switch ddThrFrom.Value      % pool the threshold from one parity only
                case 'odd',  po.stride = 2*po.stride;
                case 'even', po.offset = po.offset + po.stride; po.stride = 2*po.stride;
            end
        end
        dPool = spt_pool_quality(matched(dCell).spt, spnDiam.Value, dCal.pixUm, 40, po);
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
        syncPctButton();
        if strcmp(which,'segevery'), showSegEvery(); return; end   % display + run setting only
        if strcmp(which,'deint') && dCell >= 1
            % The selected PAGES changed, so the frame slider's range, the pooled quality
            % distribution and the preview are all describing a different movie now.
            sldFrame.Limits = [1 max(detFrameCount(),1)];
            if sldFrame.Value > sldFrame.Limits(2), sldFrame.Value = sldFrame.Limits(2); end
            syncFrameNum();
        end
        if dCell < 1, return; end
        matched(dCell).diamUm   = spnDiam.Value;
        matched(dCell).keepPct  = spnPct.Value;
        matched(dCell).thrMode  = ddThrMode.Value;
        matched(dCell).qualThr  = spnQual.Value;
        d = detOpts(); matched(dCell).ridgeMax = d.ridgeMax; matched(dCell).sizeMax = d.sizeMax;
        matched(dCell).alignDeg = d.alignDeg;
        % Snap a meaningless ratio up to 1 where the user can SEE it happen, rather than letting a
        % value that means its own reciprocal sit in the box looking deliberate.
        if ~isempty(spnRidge) && isgraphics(spnRidge) && spnRidge.Value > 0 && spnRidge.Value < 1
            spnRidge.Value = 1;
        end
        [stD, ofD] = deintValue();
        matched(dCell).frameStride = stD; matched(dCell).frameOffset = ofD;
        if any(strcmp(which,{'diam','ridge','deint'}))
            % The ridge gate changes WHICH candidates exist, so the pooled quality distribution and
            % the percentile threshold read off it both move. Re-pool, exactly as for diameter —
            % re-thresholding alone would leave the histogram describing candidates that are no
            % longer detected.
            poolAndDraw();
        else                          % percentile / mode / quality change only the threshold -> re-threshold
            drawDetHist(); drawDetRate(); drawDetPreview();
        end
    end

    function showInterleaveWarning(sptPath, segPath)
        % Surfaced on the Detect tab rather than only at run time: this is a "you are about to
        % analyse the wrong file" problem, and it is worth catching before a batch of runs, not in
        % the log afterwards.
        if isempty(lblDet) || ~isgraphics(lblDet), return; end
        % The mask turns "this is interleaved" into "keep the odd pages", which is the difference
        % between a warning the user can act on and one they have to investigate.
        try, IL = spt_interleave_check(sptPath, 12, segPath); catch, return; end
        if ~IL.isInterleaved, return; end
        [stW, ofW] = deintValue();
        if stW > 1
            % De-interleaved — but the WRONG parity is the dangerous case, not the un-set one. The
            % segmentation comes from the organelle pages, so detecting on them compares the
            % organelle with a mask drawn from itself: everything reads as colocalised.
            if ~isempty(IL.organelleParity)
                chosen = 'odd'; if mod(ofW,2) == 1, chosen = 'even'; end
                if strcmp(chosen, IL.organelleParity)
                    lblDet.Text = sprintf(['⚠ de-interleave is on the %s pages, which are the ' ...
                        'ORGANELLE channel (%.2fx in the mask vs %.2fx). Detecting these compares ' ...
                        'the organelle with a mask made from itself — switch to the %s pages.'], ...
                        chosen, max(IL.enrichOdd,IL.enrichEven), min(IL.enrichOdd,IL.enrichEven), ...
                        IL.particleParity);
                    lblDet.FontColor = [0.75 0.1 0.1];
                end
            end
            return;
        end
        lblDet.Text = ['⚠ ' IL.why];
        lblDet.FontColor = [0.75 0.35 0.05];
    end

    function showSegEvery()
        % Report the SPT/organelle page ratio for the selected cell, so 'auto' is never a guess the
        % user has to take on trust — and so a stack that is not a clean multiple is visible.
        if isempty(lblSegEvery) || ~isgraphics(lblSegEvery), return; end
        lblSegEvery.Text = '';
        if dCell < 1 || dCell > numel(matched), return; end
        cel = matched(dCell);
        seg = ''; if ~isempty(cel.mitoSeg) && isfile(cel.mitoSeg), seg = cel.mitoSeg;
        elseif ~isempty(cel.erSeg) && isfile(cel.erSeg), seg = cel.erSeg; end
        if isempty(seg), lblSegEvery.Text = '(no organelle stack)'; return; end
        try
            nS = numel(imfinfo(seg)); nF = numel(imfinfo(cel.spt));
        catch, return; end
        rat = nF / max(nS,1);
        if abs(rat - round(rat)) < 1e-9
            lblSegEvery.Text = sprintf('%d SPT / %d organelle = 1 per %g', nF, nS, round(rat));
        else
            lblSegEvery.Text = sprintf('%d SPT / %d organelle = %.2f (not a whole ratio -> 1)', nF, nS, rat);
        end
        % With de-interleaving on, spell out the interval the ANALYSIS will use. The top bar shows
        % the per-page number the file reports; the frames that survive are a stride apart.
        [stL, ~] = deintValue();
        if stL > 1 && ~isempty(dCal) && isfield(dCal,'dt_s') && isfinite(dCal.dt_s)
            lblSegEvery.Text = sprintf('%s · dt %.5g s/page -> %.5g s/frame', ...
                lblSegEvery.Text, dCal.dt_s, dCal.dt_s*stL);
        end
    end

    function onLinkModePicked()
        % Once the user picks a link mode themselves, a later scan must not silently move it —
        % choosing ER-geodesic and having a re-scan quietly drop you to Euclidean is worse than
        % the mismatch the auto-set exists to avoid.
        erModeTouched = true;
    end

    function syncPctButton()
        % The label carries the number it will use. A button that says "Top 6%" while the spinner
        % says 12 is worse than no button at all.
        if isempty(btPct) || ~isgraphics(btPct) || isempty(spnPct) || ~isgraphics(spnPct), return; end
        btPct.Text = sprintf('▶▶ Run all @ Top %.3g%%', spnPct.Value);
    end

    function syncThrModeUI()   % enable the control that matches the active threshold mode
        if isempty(ddThrMode) || ~isgraphics(ddThrMode), return; end
        isQual = strcmpi(ddThrMode.Value,'qual');
        spnQual.Enable = tern(isQual,'on','off');  lblQual.Enable = tern(isQual,'on','off');
        spnPct.Enable  = tern(~isQual,'on','off');
    end

    function onDetFrame()
        syncFrameNum(); drawDetPreview(); updateRateMarker();
    end

    function onDetStep(d)
        % One frame at a time. On an interleaved stack a single step alternates channels, which is
        % the whole point: step once to see the same field with and without the bleedthrough.
        if isempty(sldFrame) || ~isgraphics(sldFrame), return; end
        stopPlay();
        n = max(round(sldFrame.Limits(2)), 1);
        fr = min(max(round(sldFrame.Value) + d, 1), n);
        sldFrame.Value = fr; onDetFrame();
    end

    function onDetFrameNum()
        if isempty(sldFrame) || ~isgraphics(sldFrame), return; end
        stopPlay();
        n = max(round(sldFrame.Limits(2)), 1);
        fr = min(max(round(eFrameNum.Value), 1), n);
        sldFrame.Value = fr; onDetFrame();
    end

    function syncFrameNum()
        % The box mirrors the slider wherever the frame changes — dragging, stepping, playing or
        % clicking the rate plot — so it is never a stale number sitting beside a moved slider.
        if isempty(eFrameNum) || ~isgraphics(eFrameNum) || isempty(sldFrame) || ~isgraphics(sldFrame), return; end
        eFrameNum.Limits = [1 max(round(sldFrame.Limits(2)),1)];
        eFrameNum.Value  = min(max(round(sldFrame.Value),1), eFrameNum.Limits(2));
    end

    function onCalChange(which)
        % These fields EDIT THE SELECTED CELL. The edit is stamped into the experiment manifest as
        % hand-typed, which is what makes it stick: a later Rescan, and the resolver on the next run,
        % both step aside for a hand-edited value rather than replacing it with what the files say.
        % Only the field that actually changed is marked — marking both would lock a number nobody
        % typed and stop it refreshing when that cell finally gets a _settings.txt of its own.
        px = FBPXUM; dt = FBDTS;
        if ~isempty(eCalPx) && isgraphics(eCalPx), px = eCalPx.Value; end
        if ~isempty(eCalDt) && isgraphics(eCalDt), dt = eCalDt.Value; end
        if dCell < 1 || dCell > numel(matched)
            % No cell selected: there is nothing to edit, so the fields mean what they now are —
            % the fallback a cell gets when it can supply nothing.
            FBPXUM = px; FBDTS = dt; showCalTips(); return;
        end
        [~, b] = fileparts(matched(dCell).spt);
        if strcmp(which,'px')
            dCal.pixUm = px; dCal.srcPx = 'edited';
            stampCalib(b, projDir(), px, NaN, 'edited', true);
        else
            dCal.dt_s = dt;  dCal.srcDt = 'edited';
            stampCalib(b, projDir(), NaN, dt, 'edited', true);
        end
        showCalTips();
        poolAndDraw();                        % pixel size changes diameter->px, so re-detect
    end

    function d = projDir()
        % The project the run writes into — also the folder spt_project_calib resolves a cell against
        % (it reads <project>/tracks/<base>_settings.txt). '' before one is picked, which every
        % caller handles.
        d = ''; if ~isempty(eProj) && isgraphics(eProj), d = strtrim(eProj.Value); end
    end

    function cal = cellCalib(base, sptPath, pdir)
        % THIS cell's calibration, most-trustworthy source first, with the panel LAST.
        %
        %   1. a HAND-EDITED value in the experiment manifest — the user's correction, and the only
        %      thing that outranks the files. This is where "the edit sticks" becomes true at RUN
        %      time rather than only in the table.
        %   2. spt_project_calib(project, base) — the existing per-cell resolver, unchanged:
        %      _settings.txt, then the movie's metadata, then the tracks XML, and NaN rather than a
        %      guess. Its order is deliberate and nothing here re-derives any of it.
        %   3. the movie itself. Needed because Tool 1's SPT folder is user-chosen and need not be
        %      <project>/spt/, which is all the resolver's findMovie looks at — so a cell can have
        %      perfectly good metadata that step 2 cannot reach.
        %   4. the panel. The fallback is applied HERE, by the caller, never inside the resolver —
        %      that boundary is stated in spt_project_calib's header and is what keeps "NaN, never a
        %      guess" meaningful. A cell that reaches this step is reported as having reached it.
        cal = struct('pixUm',NaN,'dt_s',NaN,'srcPx','missing','srcDt','missing');
        m = manifestCal(base, pdir);
        if m.pixLock && inr_(m.pixUm,0.005,5),   cal.pixUm = m.pixUm; cal.srcPx = 'edited'; end
        if m.dtLock  && inr_(m.dtS,1e-6,3600),   cal.dt_s  = m.dtS;   cal.srcDt = 'edited'; end
        if ~isempty(pdir) && isfolder(pdir) && exist('spt_project_calib','file')==2
            try
                pc = spt_project_calib(pdir, base);
                if ~isfinite(cal.pixUm) && isfinite(pc.pixUm), cal.pixUm = pc.pixUm; cal.srcPx = pc.src.pixUm; end
                if ~isfinite(cal.dt_s)  && isfinite(pc.dt_s),  cal.dt_s  = pc.dt_s;  cal.srcDt = pc.src.dt_s;  end
            catch
            end
        end
        if (~isfinite(cal.pixUm) || ~isfinite(cal.dt_s)) && ~isempty(sptPath) && isfile(sptPath)
            try
                tc = spt_tiff_calib(sptPath);
                if ~isfinite(cal.pixUm) && inr_(tc.pixUm,0.005,5),  cal.pixUm = tc.pixUm; cal.srcPx = 'movie'; end
                if ~isfinite(cal.dt_s)  && inr_(tc.dt_s,1e-6,3600), cal.dt_s  = tc.dt_s;  cal.srcDt = 'movie'; end
            catch
            end
        end
        if ~isfinite(cal.pixUm), cal.pixUm = FBPXUM; cal.srcPx = 'panel'; end
        if ~isfinite(cal.dt_s),  cal.dt_s  = FBDTS;  cal.srcDt = 'panel'; end
    end

    function m = manifestCal(base, pdir)
        % What the experiment manifest holds for this cell, and whether it was hand-typed. Read
        % defensively throughout: the panel may be absent, and a manifest saved before calibration
        % was per cell has none of these fields.
        m = struct('pixUm',NaN,'pixLock',false,'dtS',NaN,'dtLock',false);
        try
            if isempty(exptCtl) || ~isstruct(exptCtl) || ~isfield(exptCtl,'getCells'), return; end
            C = exptCtl.getCells();
            if isempty(C) || ~isfield(C,'pixLock'), return; end
            hit = strcmp({C.file}, char(base)); if ~any(hit), return; end
            % (project, cell) is the manifest key, and when a project is named the match must be
            % SCOPED to it — no falling back to the base name alone. Day1/Cell1 and Day2/Cell1 is
            % this pipeline's own layout, so that fallback bound one project's hand-edited value to
            % another project's cell and, because it arrives as a LOCK, outranked the second cell's
            % own movie metadata while still being labelled 'hand-edited'.
            if ~isempty(pdir)
                hit = hit & strcmp({C.project}, canonPath(pdir));
            end
            if nnz(hit) ~= 1, return; end
            c = C(find(hit,1));
            if ~isempty(c.pixUm), m.pixUm = c.pixUm; end
            if ~isempty(c.dtS),   m.dtS   = c.dtS;   end
            m.pixLock = ~isempty(c.pixLock) && c.pixLock;
            m.dtLock  = ~isempty(c.dtLock)  && c.dtLock;
        catch
        end
    end

    function p = canonPath(d)
        % One spelling per project. Two spellings of the same folder — a trailing separator, or an
        % unresolved symlink — compare unequal, and (project, cell) is the manifest key.
        p = char(d);
        if numel(p) > 1 && endsWith(p, filesep), p = p(1:end-1); end
        try, r = char(java.io.File(p).getCanonicalPath()); if ~isempty(r), p = r; end, catch, end
    end

    function ensureRegistered(pdir)
        % Give the project a manifest row if it has none, so a hand-edited calibration has somewhere
        % to be stored. Cheap and idempotent: addFolder is what the Match tab's picker already calls.
        if isempty(pdir), return; end
        try
            if isempty(exptCtl) || ~isstruct(exptCtl) || ~isfield(exptCtl,'addFolder'), return; end
            C = exptCtl.getCells();
            if ~isempty(C) && isfield(C,'project') && any(strcmp({C.project}, canonPath(pdir)))
                return
            end
            exptCtl.addFolder(char(pdir));
        catch
        end
    end

    function stampCalib(base, pdir, pixUm, dtS, src, lock)
        % Record what this cell is actually calibrated with, in the manifest — the store the numbers
        % live in and the one place a person can see, side by side, which cells are on their own
        % scale and which fell back. Pass NaN for the number you are not setting. lock=false is a
        % REPORT and the panel refuses to let it overwrite anything hand-typed.
        try
            if isempty(exptCtl) || ~isstruct(exptCtl) || ~isfield(exptCtl,'setCalib'), return; end
            % A hand-typed value is STORED IN THE MANIFEST, so the project must have a row there for
            % the edit to land anywhere at all. Only the Match tab's project Pick... dialog used to
            % register one, so an edit made after opening a project any other way — the Track tab's
            % picker, or a typed path — was accepted by the field, displayed back, and then silently
            % dropped at run time while the log claimed nothing had supplied a value.
            if lock, ensureRegistered(pdir); end
            exptCtl.setCalib(pdir, base, pixUm, dtS, src, lock);
        catch
        end
    end

    function showCal(cal)
        % Point the two top-bar fields at the selected cell. Setting Value programmatically does not
        % fire ValueChangedFcn, so this cannot be mistaken for a user edit.
        if ~isempty(eCalPx) && isgraphics(eCalPx), eCalPx.Value = clampv(cal.pixUm, eCalPx.Limits(1), eCalPx.Limits(2)); end
        if ~isempty(eCalDt) && isgraphics(eCalDt), eCalDt.Value = clampv(cal.dt_s,  eCalDt.Limits(1), eCalDt.Limits(2)); end
        showCalTips();
    end

    function showCalTips()
        % The provenance has to be readable without opening the manifest, so it lives on the hover.
        if ~isempty(eCalPx) && isgraphics(eCalPx)
            eCalPx.Tooltip = sprintf(['µm per pixel for the CELL selected in the Detect tab — %s. ' ...
                'Type over it to correct THIS cell; every other cell keeps its own.'], srcWord(dCal.srcPx));
        end
        if ~isempty(eCalDt) && isgraphics(eCalDt)
            eCalDt.Tooltip = sprintf(['Seconds per frame for the CELL selected in the Detect tab — %s. ' ...
                'Type over it to correct THIS cell; every other cell keeps its own.'], srcWord(dCal.srcDt));
        end
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
        %
        % It applies to THE SELECTED CELL ONLY. It used to read one cell's TIFF and assign the result
        % app-wide, which is how every cell in a mixed-rig batch ended up on the first cell's scale.
        if dCell < 1 || dCell > numel(matched)
            if ~isempty(lblDet) && isgraphics(lblDet)
                lblDet.Text = 'Pick a cell first — Auto reads that cell''s own TIFF.'; lblDet.FontColor = [0.6 0.4 0.1];
            end
            return
        end
        p = matched(dCell).spt;
        [~, b] = fileparts(p);
        c = spt_tiff_calib(p);
        held = manifestCal(b, projDir());   % a hand edit is not overwritten by a re-read, only reported
        got = {}; miss = {}; kept = {};
        if ~inr_(c.pixUm,0.005,5),  miss{end+1} = 'pixel size';      %#ok<AGROW>
        elseif held.pixLock,        kept{end+1} = sprintf('pixel size (your %.5g kept over the file''s %.5g)', held.pixUm, c.pixUm); %#ok<AGROW>
        else
            dCal.pixUm = c.pixUm; dCal.srcPx = 'movie';
            % Not locked: this is a MEASUREMENT re-read from the file, not a correction the user
            % typed, so a later rescan reading the same file is free to refresh it.
            stampCalib(b, projDir(), c.pixUm, NaN, 'movie', false);
            got{end+1} = sprintf('%.5g µm/px', c.pixUm); %#ok<AGROW>
        end
        if ~inr_(c.dt_s,1e-6,3600), miss{end+1} = 'frame interval';  %#ok<AGROW>
        elseif held.dtLock,         kept{end+1} = sprintf('frame interval (your %.5g kept over the file''s %.5g)', held.dtS, c.dt_s); %#ok<AGROW>
        else
            dCal.dt_s = c.dt_s; dCal.srcDt = 'movie';
            stampCalib(b, projDir(), NaN, c.dt_s, 'movie', false);
            got{end+1} = sprintf('%.5g s/frame (%.4g Hz)', c.dt_s, 1/c.dt_s); %#ok<AGROW>
        end
        showCal(dCal);
        % Fiji's own display range travels in the same block. Offer it — the user asked for contrast
        % that matches Fiji, and this is literally the range Fiji was showing when the file was saved.
        if isfinite(c.dispLo) && isfinite(c.dispHi) && ~isempty(dLastIm)
            applyDisplayRange(c.dispLo, c.dispHi);
            got{end+1} = sprintf('display %g–%g (as saved in Fiji)', c.dispLo, c.dispHi); %#ok<AGROW>
        end
        if ~isempty(lblDet) && isgraphics(lblDet)
            if isempty(got) && isempty(kept)
                lblDet.Text = sprintf('Nothing readable in %s''s TIFF — set µm/px and frame interval manually above.', matched(dCell).key);
                lblDet.FontColor = [0.6 0.4 0.1];
            else
                tail = ''; if ~isempty(miss), tail = sprintf('  ·  no %s in the file — set it manually', strjoin(miss,' or ')); end
                % A hand edit held back a file value: never silent, and never presented as if the
                % file's number is what this cell will be tracked with.
                if ~isempty(kept), tail = [tail sprintf('  ·  your edit kept for %s', strjoin(kept,' and '))]; end
                lblDet.Text = sprintf('%s — read from its own TIFF: %s%s', matched(dCell).key, strjoin(got,'  ·  '), tail);
                lblDet.FontColor = [0.2 0.5 0.2]; if ~isempty(miss) || ~isempty(kept), lblDet.FontColor = [0.6 0.4 0.1]; end
            end
        end
        poolAndDraw();
    end

    function seedPanelFallback()
        % Seed the PANEL FALLBACK from the first cell's TIFF, so a cell that can supply nothing of
        % its own gets something from this dataset rather than a literal left over from another rig.
        %
        % This call is where the old bug lived: it read one cell and made that number every cell's
        % calibration. It no longer does — the value it sets is the fallback and nothing else, every
        % cell resolves its own (cellCalib), and any cell that actually falls back to this says so in
        % the run log and in its _settings.txt.
        % Reset FIRST. These were only ever WRITTEN when a new project's first cell supplied a
        % value, and nothing reset them — so scanning a calibrated project and then one where
        % nothing resolves ran the second project's cells on the FIRST project's rig. That is the
        % same shape as the ER/mito boxes not clearing between projects: a stale value that is
        % invisible because the top-bar fields follow the SELECTED CELL, not this fallback.
        FBPXUM = FB_PXUM_0; FBDTS = FB_DTS_0;
        if isempty(matched), return; end
        try, c = spt_tiff_calib(matched(1).spt); catch, return; end
        if inr_(c.pixUm,0.005,5),  FBPXUM = c.pixUm; end
        if inr_(c.dt_s,1e-6,3600), FBDTS  = c.dt_s;  end
    end

    function t = modeTag(R)
        % Name the mode that actually ran. This used to print ' · ER-aware', which was the old
        % two-way boolean and no longer names anything the app offers — you could not tell an
        % ER-penalty run from an ER-geodesic one in the log.
        t = '';
        m = ''; if isstruct(R) && isfield(R,'linkMode'), m = char(R.linkMode); end
        switch lower(m)
            case 'penalty',  t = ' · ER-penalty';
            case 'geodesic', t = ' · ER-geodesic (strict)';
            case 'euclid',   t = ' · Euclidean';
            otherwise, if isfield(R,'useEr') && R.useEr, t = ' · ER-aware'; end
        end
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
        dLastIm = double(imread(matched(dCell).spt, detPageOf(fr)));
        thr = curDetThr(); matched(dCell).thrAbs = thr;
        matched(dCell).thrMode = ddThrMode.Value; matched(dCell).qualThr = spnQual.Value;   % persist the policy with the cell
        [dLastXY, dLastShp, dLastRej] = spt_detect(dLastIm, spnDiam.Value, dCal.pixUm, thr, detOptsFrame(fr));
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
        % The µm size is this cell's own — so the readout names the SCALE and where it came from.
        % Without that, a cell running on the panel fallback prints a field of view that looks as
        % authoritative as its neighbour's and is measured with a different ruler.
        % The gate's effect belongs in the numbers as well as the picture: how many it took, and
        % what fraction of the candidates that is, is what tells you the threshold is sane.
        rejStr = '';
        if ~isempty(dLastRej)
            nR = size(dLastRej,1);
            rejStr = sprintf(' · %d rejected as ridge/too wide (%.0f%% of candidates)', ...
                nR, 100*nR/max(nR + size(dLastXY,1),1));
        end
        lblDet.Text = sprintf('%s · %d×%d px (%.1f×%.1f µm @ %.5g µm/px, %s) · diam %.2f µm · %s · thr %s · %d spots%s · %d likely motion-blur (elong≥%.1f, med %.2f)%s · pooled n=%d', ...
            matched(dCell).key, imW, imH, imW*dCal.pixUm, imH*dCal.pixUm, dCal.pixUm, srcWord(dCal.srcPx), ...
            spnDiam.Value, gateStr, thrStr(thr), size(dLastXY,1), rejStr, nBlur, ELONG_BLUR, medEl, offStr, numel(dPool));
        lblDet.FontColor = [0.2 0.4 0.5];
        if strcmp(dCal.srcPx,'panel'), lblDet.FontColor = [0.6 0.4 0.1]; end   % amber: not this cell's own scale
        updateTrkDet();   % keep the Track-tab detection readout in sync
    end

    function redrawDisplay()   % re-display the cached frame + detections (contrast/frame change, no re-detect)
        if isempty(dLastIm) || isempty(axPrev) || ~isgraphics(axPrev), return; end
        lo = dispLo; hi = dispHi; if ~(hi>lo), hi = lo + max(1,abs(lo)*0.01); end
        cla(axPrev);
        imshow(mat2gray(dLastIm,[lo hi]), 'Parent', axPrev); hold(axPrev,'on');
        if ~isempty(dLastXY)
            r = max((spnDiam.Value/dCal.pixUm)/2, 0.75);    % spot RADIUS in image pixels (true diameter)
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
        % What the ridge/size gate THREW AWAY. A third visual channel, because colour already means
        % shape and line style already means ER membership: a MAGENTA CROSS, not a ring — these are
        % not spots, they are the things that were stopped from becoming spots. Magenta is the
        % app's pinned mito colour, which is what they usually are.
        if ~isempty(dLastRej)
            plot(axPrev, dLastRej(:,1), dLastRej(:,2), 'x', ...
                'Color',[1 0.3 1], 'MarkerSize',9, 'LineWidth',1.1);
        end
        hold(axPrev,'off');
        nOff = sum(dLastOff(:)); offTxt = '';
        if haveErSeg(), offTxt = sprintf(', dotted = off-ER: %d', nOff); end
        rejTxt = '';
        if ~isempty(dLastRej)
            rejTxt = sprintf(', magenta × = rejected as ridge/too wide: %d', size(dLastRej,1));
        elseif ~isempty(detOpts().ridgeMax) || ~isempty(detOpts().sizeMax)
            if ~gateFrame(round(sldFrame.Value))
                rejTxt = sprintf(', gate OFF on this frame (on frames = %s)', bleedValue());
            end
        end
        title(axPrev, sprintf('frame %d/%d — %d spots (red = elong≥%.1f, likely motion-blur%s%s)', ...
            round(sldFrame.Value), dNfr, size(dLastXY,1), ELONG_BLUR, offTxt, rejTxt));
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
        [lo, hi] = spt_ij_auto(v, autoThr);
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
        sldFrame.Value = fr; syncFrameNum(); drawDetPreview(); updateRateMarker(); drawnow limitrate;
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
        [dRateF, dRateC] = spt_count_per_frame(matched(dCell).spt, spnDiam.Value, dCal.pixUm, curDetThr(), 120);
        plot(axRate, dRateF, dRateC, '-', 'Color',[0.2 0.5 0.7], 'LineWidth',1, 'HitTest','off');
        hold(axRate,'on');
        hRateMk = xline(axRate, round(sldFrame.Value), 'r-', 'HitTest','off');
        hold(axRate,'off');
        xlim(axRate,[1 max(dNfr,2)]); xlabel(axRate,'frame'); ylabel(axRate,'#spots');
        title(axRate, sprintf('spots / frame · median %.0f  (click to jump)', median(dRateC)));
        spt_axes_policy(axRate);   % click-to-seek coexists with zoom/pan — see spt_axes_policy
        axRate.ButtonDownFcn = @(s,e) onRateClick();   % click the trace -> go to that frame
    end

    function updateRateMarker()
        if ~isempty(hRateMk) && isgraphics(hRateMk), hRateMk.Value = round(sldFrame.Value); end
    end

    function onRateClick()
        if isempty(axRate) || ~isgraphics(axRate) || dNfr < 1, return; end
        cp = axRate.CurrentPoint; fr = round(cp(1,1));
        fr = min(max(fr,1), dNfr);
        sldFrame.Value = fr; syncFrameNum();
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
            'ValueChangedFcn',@(s,e) onLinkModePicked(), ...
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
        % SEVEN columns, not six: adding a child beyond a uigridlayout's declared size does not
        % error, it silently WRAPS onto a new row — which squashed this whole row to a sliver with
        % the project path unreadable. Every button added here must come with a column.
        r2 = uigridlayout(cp,[1 7],'ColumnWidth',{60,'1x',58,150,120,124,150},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uilabel(r2,'Text','Project','HorizontalAlignment','right');
        eProj = uieditfield(r2,'text','Placeholder','local output folder — tracks/ written here');
        uibutton(r2,'Text','Pick…','ButtonPushedFcn',@(s,e) onPickProject());
        lblTrkDet = uilabel(r2,'Text','det: —','HorizontalAlignment','right','FontColor',[0.30 0.45 0.55], ...
            'Tooltip','Detection setting the current Detect-tab cell will be tracked with (diameter + Top% / absolute threshold).');
        btR = uibutton(r2,'Text','▶ Run this cell','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70], ...
            'FontColor','w','ButtonPushedFcn',@(s,e) onTrackRun(),'Tooltip',detTip);
        btB = uibutton(r2,'Text','▶▶ Run all ticked','FontWeight','bold','ButtonPushedFcn',@(s,e) onTrackBatch(),'Tooltip',detTip);
        % An UNAMBIGUOUS batch button. "Run all ticked" honours each cell's own stored threshold,
        % which is right when you have tuned cells individually and wrong when you have not: a cell
        % previewed earlier at a different Top % keeps that number, so a 93-cell run can silently
        % mix policies. This one forces every ticked cell onto the Top % showing right now — it
        % clears the per-cell resolved thresholds so each re-pools its OWN frames at that
        % percentage. Same detection POLICY everywhere, a threshold per cell.
        btPct = uibutton(r2,'Text','▶▶ Run all @ Top 6%','FontWeight','bold', ...
            'BackgroundColor',[0.20 0.55 0.35],'FontColor','w', ...
            'ButtonPushedFcn',@(s,e) onTrackBatchPct(), ...
            'Tooltip',['Run every ticked cell at the Top %% shown on the Detect tab, whatever any ' ...
            'of them was previewed at. Each cell still pools its OWN frames, so each gets its own ' ...
            'absolute threshold — the percentage is shared, the number is not. Use this for a ' ...
            'batch you have not tuned cell by cell.']);

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
        spt_axes_policy([axCur axCurTrk]);
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
        % THIS cell's pixel size, not the Detect tab's. The filter cell is selected independently, so
        % using the other tab's scale put every overlay in the wrong place whenever the two cells
        % came off different rigs — the same mistake already fixed for dt in drawCurHist below.
        % Hand over how this cell's frames map onto pages, so the overlay reads the right organelle
        % page and the image the right SPT page. Without it the player re-derives from page counts,
        % which is right for a plain movie and wrong for a de-interleaved one.
        R.frameStride = getf(c,'frameStride',1); R.frameOffset = getf(c,'frameOffset',0);
        R.x = colv(S,'X_um')/cCal.pixUm + 1; R.y = colv(S,'Y_um')/cCal.pixUm + 1;   % µm -> 1-based px
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
        % The SHARED tracking params. pxUm/dtS carry the panel FALLBACK only — runCells replaces both
        % with each cell's own before that cell is processed, and onCompareModes replaces them with
        % the compared cell's. Nothing downstream should ever be handed this pair unexamined.
        prm = struct('linkUm',spnLink.Value,'gapUm',spnGap.Value,'maxGap',round(spnInt.Value), ...
            'useEr',~strcmp(mode,'euclid'),'linkMode',mode,'lambda',spnLam.Value, ...
            'pxUm',FBPXUM,'dtS',FBDTS,'pxUmSrc','panel','dtSSrc','panel');
        d = detOpts(); prm.ridgeMax = d.ridgeMax; prm.sizeMax = d.sizeMax; prm.alignDeg = d.alignDeg;
        prm.segEvery = segEveryValue();
        [prm.frameStride, prm.frameOffset] = deintValue();
        prm.bleedFrames = 'all';
        if ~isempty(ddBleed) && isgraphics(ddBleed), prm.bleedFrames = ddBleed.Value; end
        prm.thrFrames = 'all';
        if ~isempty(ddThrFrom) && isgraphics(ddThrFrom), prm.thrFrames = ddThrFrom.Value; end
    end

    function [stride, offset] = deintValue()
        % 'off' is stride 1 offset 0 — the untouched path.
        stride = 1; offset = 0;
        if isempty(ddDeint) || ~isgraphics(ddDeint), return; end
        switch ddDeint.Value
            case 'odd pages',  stride = 2; offset = 0;
            case 'even pages', stride = 2; offset = 1;
        end
    end

    function pg = detPageOf(fr)
        % Slider position (an SPT FRAME) -> the page of the stack it actually is.
        [st, of] = deintValue();
        pg = of + 1 + (max(1,round(fr)) - 1)*st;
    end

    function n = detFrameCount()
        [st, of] = deintValue();
        n = numel((of+1) : st : max(dNfr,0));
    end

    function o = detOpts()
        % Detector options for THIS panel state. 0 in the spinner means off, which spt_detect
        % expects as [] — the two are not the same thing to a spinner and must not be to the engine.
        rm = []; if ~isempty(spnRidge) && isgraphics(spnRidge) && spnRidge.Value > 0, rm = spnRidge.Value; end
        sz = []; if ~isempty(spnSize)  && isgraphics(spnSize)  && spnSize.Value  > 0, sz = spnSize.Value;  end
        ad = []; if ~isempty(spnAlign) && isgraphics(spnAlign) && spnAlign.Value > 0, ad = spnAlign.Value; end
        o = struct('ridgeMax', rm, 'sizeMax', sz, 'alignDeg', ad);
    end

    function toggleAdv(force)
        if nargin >= 1, advOpen = force; else, advOpen = ~advOpen; end
        if isempty(btnAdv) || ~isgraphics(btnAdv), return; end
        % Height AND visibility: a zero-height grid row squashes its children to a sliver but still
        % draws them, so the collapsed row showed a line of unreadable stubs.
        r5h = tern(advOpen, ADVROW, 0);
        cp2 = btnAdv.Parent; rh = cp2.RowHeight; rh{6} = r5h; cp2.RowHeight = rh;
        if ~isempty(advRow) && isgraphics(advRow), advRow.Visible = tern(advOpen,'on','off'); end
        if ~isempty(advG) && isgraphics(advG)
            gh = advG.RowHeight; gh{1} = tern(advOpen, ADVH1, ADVH0); advG.RowHeight = gh;
        end
        btnAdv.Text = tern(advOpen, '▾ interleaved acquisition & bleedthrough options', ...
                                    '▸ interleaved acquisition & bleedthrough options');
        if ~advOpen && ~isempty(lblAdvWhy) && isgraphics(lblAdvWhy), lblAdvWhy.Text = ''; end
    end

    function advAutoShow(c)
        % Open the row only when THIS cell looks like it needs it: an alternating stack, or an
        % organelle stack that is not one page per frame. Anything else and it stays shut, because
        % for most projects every one of these controls is a no-op.
        if isempty(btnAdv) || ~isgraphics(btnAdv), return; end
        why = '';
        try
            nSpt = numel(imfinfo(c.spt));
            seg = ''; if ~isempty(c.mitoSeg) && isfile(c.mitoSeg), seg = c.mitoSeg;
            elseif ~isempty(c.erSeg) && isfile(c.erSeg), seg = c.erSeg; end
            if ~isempty(seg)
                nS = numel(imfinfo(seg));
                if nS ~= nSpt
                    why = sprintf('%d SPT frames but %d organelle frames — check "organelle /"', nSpt, nS);
                end
            end
            if isempty(why)
                IL = spt_interleave_check(c.spt, 8);
                if IL.isInterleaved, why = 'this stack looks interleaved — see de-interleave / on frames'; end
            end
        catch, end
        if ~isempty(why)
            toggleAdv(true);
            if ~isempty(lblAdvWhy) && isgraphics(lblAdvWhy), lblAdvWhy.Text = ['⚠ ' why]; end
        elseif ~anyAdvSet()
            toggleAdv(false);         % nothing to flag and nothing set: keep it out of the way
        end
    end

    function tf = anyAdvSet()
        % Never collapse a row the user has actually configured — that would hide a setting that is
        % changing their results.
        d = detOpts();
        tf = ~isempty(d.ridgeMax) || ~isempty(d.sizeMax) || ~isempty(d.alignDeg) || ...
             ~strcmp(bleedValue(),'all') || ...
             (~isempty(ddThrFrom) && isgraphics(ddThrFrom) && ~strcmp(ddThrFrom.Value,'all')) || ...
             (~isempty(ddDeint)   && isgraphics(ddDeint)   && ~strcmp(ddDeint.Value,'off')) || ...
             (~isempty(ddSegEvery)&& isgraphics(ddSegEvery)&& ~strcmp(ddSegEvery.Value,'auto'));
    end

    function v = bleedValue()
        v = 'all';
        if ~isempty(ddBleed) && isgraphics(ddBleed), v = ddBleed.Value; end
    end

    function tf = gateFrame(fr)
        % Does the gate apply to THIS frame? The run has always honoured 'on frames'; the preview
        % did not, so it drew rejections on the clean parity that the run would never make — the
        % one place the setting most needs to be visible was the one place it was ignored.
        switch bleedValue()
            case 'odd',  tf = mod(round(fr),2) == 1;
            case 'even', tf = mod(round(fr),2) == 0;
            otherwise,   tf = true;
        end
    end

    function o = detOptsFrame(fr)
        o = detOpts();
        if ~gateFrame(fr), o.ridgeMax = []; o.sizeMax = []; o.alignDeg = []; return; end
        % The alignment test needs this frame's organelle skeleton. Without it the preview would
        % silently skip a criterion the run applies — the same mismatch the parity gate had.
        if ~isempty(o.alignDeg) && o.alignDeg > 0
            sk = detSkelFor(fr);
            if ~isempty(sk), o.skel = sk; end
        end
    end

    function sk = detSkelFor(fr)
        % Skeleton of the organelle page this frame reads, cached by page: with one page per N
        % frames the same skeleton serves N frames, and stepping the slider must not re-skeletonise.
        sk = [];
        if dCell < 1 || dCell > numel(matched), return; end
        seg = matched(dCell).mitoSeg;
        if isempty(seg) || ~isfile(seg), seg = matched(dCell).erSeg; end
        if isempty(seg) || ~isfile(seg), return; end
        try
            nS = numel(imfinfo(seg));
            n = segEveryValue();
            if ~isnumeric(n)                        % 'auto': the same whole-ratio rule the run uses
                nF = detFrameCount(); r = nF / max(nS,1);
                n = 1; if abs(r-round(r)) < 1e-9 && round(r) >= 1, n = round(r); end
            end
            pg = ceil(max(round(fr),1)/n);
            if pg < 1 || pg > nS, return; end
            if pg == detSkelPg && ~isempty(detSkelIm), sk = detSkelIm; return; end
            M = imread(seg, pg);
            nz = double(unique(M(M>0))); if isempty(nz), return; end
            sk = bwmorph(M == min(nz), 'skel', Inf);
            detSkelPg = pg; detSkelIm = sk;
        catch, sk = []; end
    end

    function v = segEveryValue()
        % 'auto' is passed through as the string; spt_process_cell derives the ratio per cell, which
        % is the only place that knows how many pages THAT cell's organelle stack has.
        v = 'auto';
        if ~isempty(ddSegEvery) && isgraphics(ddSegEvery) && ~strcmp(ddSegEvery.Value,'auto')
            v = str2double(ddSegEvery.Value);
        end
    end

    function onCompareModes()
        if dCell < 1 || dCell > numel(matched), setTrk('Pick a cell in the Detect tab first.',[0.75 0.1 0.1]); return; end
        cel = matched(dCell);
        if isempty(cel.erSeg) || ~isfile(cel.erSeg)
            setTrk('This cell has no ER segmentation — the ER modes need it.',[0.6 0.4 0.1]); return; end
        prm = gatherPrm();
        % spt_compare_app computes the link radius as linkUm/pxUm, so the comparison has to run on
        % THIS cell's pixel size or all three methods are compared at the wrong radius.
        [~, cb] = fileparts(cel.spt);
        ccal = cellCalib(cb, cel.spt, projDir());
        prm.pxUm = ccal.pixUm; prm.dtS = ccal.dt_s;
        prm.pxUmSrc = ccal.srcPx; prm.dtSSrc = ccal.srcDt;
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

    function onTrackBatchPct()
        % Force the CURRENT Top % onto every ticked cell, then run. Clearing thrAbs is the part that
        % matters: spt_process_cell prefers a stored absolute threshold over pooling, so without
        % this a previously-previewed cell would ignore the percentage entirely.
        if trkBusy, return; end
        idxs = find([matched.use]);
        if isempty(idxs), setTrk('No ticked cells to run.',[0.75 0.1 0.1]); return; end
        if isempty(strtrim(eProj.Value)), setTrk('Set a project folder first.',[0.75 0.1 0.1]); return; end
        pct = 6; if ~isempty(spnPct) && isgraphics(spnPct), pct = spnPct.Value; end
        nCleared = 0;
        for k = idxs(:)'
            if isfield(matched,'thrAbs') && ~isempty(matched(k).thrAbs), nCleared = nCleared + 1; end
            matched(k).keepPct = pct;
            matched(k).thrAbs  = [];        % re-pool from THIS cell at the new percentage
            matched(k).thrMode = 'pct';
        end
        if ~isempty(ddThrMode) && isgraphics(ddThrMode), ddThrMode.Value = 'pct'; syncThrModeUI(); end
        logLine(sprintf('▶▶ batch at Top %.3g%% — applied to %d cell(s)%s', pct, numel(idxs), ...
            tern(nCleared > 0, sprintf(', %d had a previewed threshold that was cleared', nCleared), '')));
        runCells(idxs, strtrim(eProj.Value), btPct);
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
        uiMode = 'pct'; uiQual = 0; uiPct = 6; nFb = 0;
        if ~isempty(ddThrMode) && isgraphics(ddThrMode), uiMode = ddThrMode.Value; end
        if ~isempty(spnQual)   && isgraphics(spnQual),   uiQual = spnQual.Value; end
        if ~isempty(spnPct)    && isgraphics(spnPct),    uiPct  = spnPct.Value;  end
        for kk = 1:numel(idxs)
            k = idxs(kk); cel = resolveDetThr(matched(k), uiMode, uiQual, uiPct);
            tCell = tic;
            % EACH CELL is run on its own calibration. `prm` above holds the tracking params, which
            % are genuinely shared; the calibration is not, and hoisting it out of the loop is what
            % put every cell on the first cell's scale. prm_k is a per-iteration copy — the same
            % thing progressFcn has always been.
            [~, kBase] = fileparts(cel.spt);
            cal = cellCalib(kBase, cel.spt, pdir);
            prm_k = prm;
            prm_k.pxUm = cal.pixUm; prm_k.pxUmSrc = cal.srcPx;
            prm_k.dtS  = cal.dt_s;  prm_k.dtSSrc  = cal.srcDt;
            prm_k.progressFcn = @(frac,msg) setTrk(sprintf('⏳ [%d/%d] %s — %s   (%s elapsed)', ...
                kk, numel(idxs), cel.key, msg, hms(toc(tCell))), [0.15 0.35 0.60]);
            try
                R = spt_process_cell(cel, prm_k);
                spt_write_outputs(R, tracksDir);
                spt_write_settings(tracksDir, R.base, cel, prm_k, R);            % per-cell provenance: detection + tracking method + params
                spt_append_detection_summary(tracksDir, R.base, cel, prm_k, R);  % one-row-per-cell project table
                % Show in the manifest what this cell actually ran on. Two calls because the two
                % numbers can legitimately come from different places (settings.txt for the pixel
                % size, the XML for dt) and one label must not be made to stand for both.
                stampCalib(kBase, pdir, cal.pixUm, NaN, cal.srcPx, false);
                stampCalib(kBase, pdir, NaN, cal.dt_s, cal.srcDt, false);
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
                    getf(cel,'diamUm',0.5), ds, modeTag(R)));
                % The scale this cell's numbers are on. Always logged, because two cells in one run
                % can now legitimately differ and the log is where you find out which is which.
                logLine(sprintf('     calibration: %.5g µm/px (%s) · %.6g s/frame (%s)', ...
                    cal.pixUm, srcWord(cal.srcPx), cal.dt_s, srcWord(cal.srcDt)));
                if strcmp(cal.srcPx,'panel') || strcmp(cal.srcDt,'panel')
                    nFb = nFb + 1;
                    logLine(sprintf('     calibration: FELL BACK to the panel — %s.', fbWhat(cal)));
                    logLine('       This cell has no _settings.txt, no readable TIFF metadata and no tracks XML to supply one.');
                    logLine('       Its µm coordinates and diffusion coefficients are on the PANEL scale, not this cell''s.');
                end
            catch ME
                logLine(sprintf('   %s: ERROR — %s', cel.key, ME.message));
                setTrk(sprintf('%s FAILED — %s', cel.key, ME.message), [0.75 0.1 0.1]);
            end
        end
        tot = toc(tAll);
        logLine(sprintf('✔ RUN done — %d cell(s) in %s -> %s', numel(idxs), hms(tot), tracksDir));
        if nFb > 0
            % Amber, and it survives the run: a per-cell status line is overwritten by the next
            % cell, and a batch that quietly put some cells on the panel's ruler must not finish
            % looking exactly like one where every cell supplied its own.
            setTrk(sprintf(['✔ Run done — %d cell(s) in %s.  ⚠ %d cell(s) FELL BACK to the panel ' ...
                'calibration (%.5g µm/px, %.5g s) — their µm coordinates and D are on the panel ' ...
                'scale, not their own. See the log.'], numel(idxs), hms(tot), nFb, FBPXUM, FBDTS), [0.6 0.4 0.1]);
        else
            setTrk(sprintf('✔ Run done — %d cell(s) in %s. Now set the filter and Export.', numel(idxs), hms(tot)), [0.15 0.50 0.20]);
        end
        % selectCurateCell -> onCurCell writes the SAME label, so it used to erase the amber warning
        % one statement after it was set — the very thing the message exists to prevent. Load the
        % cell first, then restate the run verdict over the top of it.
        keepMsg = lblTrk.Text; keepCol = lblTrk.FontColor;
        selectCurateCell(idxs(end));   % load the last run cell into the filter view (map + histogram)
        if nFb > 0, setTrk(keepMsg, keepCol); end
        trkBusy = false;
    end

    function cel = resolveDetThr(cel, uiMode, uiQual, uiPct)
        % Bake the detection-threshold policy for this run. A cell that was PREVIEWED carries its own
        % thrMode/thrAbs; one that wasn't inherits the current Detect-tab policy — so a threshold set
        % in the tab applies to every ticked cell, not only the one on screen.
        mode = getf(cel,'thrMode', uiMode);
        cel.thrMode = mode;
        if strcmpi(mode,'qual')
            qv = getf(cel,'qualThr', uiQual); if ~(qv > 0), qv = uiQual; end
            cel.qualThr = qv;
            if qv > 0, cel.thrAbs = qv; else, cel.thrAbs = []; end   % 0 -> unset -> engine MAD fallback
            return;
        end
        % TOP-% MODE. Scan seeds keepPct = 6 on every cell, and only PREVIEWING a cell writes the
        % tab's value onto it. So changing Top % and running the batch used to leave every
        % un-previewed cell detecting at 6 % — the tab said 10, the run used 6, and nothing said so.
        % Quality ≥ has always been inherited (above); this makes Top % behave the same way.
        %
        % A previewed cell is left alone, exactly as in the qual branch: it carries a resolved
        % thrAbs, which spt_process_cell prefers over pooling, so its own choice still wins. Having
        % no thrAbs IS the test for "never previewed" — nothing else distinguishes Scan's seeded 6
        % from a 6 the user chose.
        if ~isfield(cel,'thrAbs') || isempty(cel.thrAbs)
            if nargin >= 4 && ~isempty(uiPct) && uiPct > 0, cel.keepPct = uiPct; end
        end
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
        pdir = projDir();
        cCal = cellCalib(base, matched(dCurCell).spt, pdir);   % this cell's own scale, for the map + player
        csv = fullfile(pdir, 'tracks', [base '_spots.csv']);
        if isempty(pdir) || ~isfile(csv)
            cla(axCur); if ~isempty(axCurTrk) && isgraphics(axCurTrk), cla(axCurTrk); title(axCurTrk,'tracks: kept vs removed'); end
            lblCur.Text = sprintf('%s: no tracks yet — run Track (Tab 3) into the project folder first.', matched(dCurCell).key);
            lblCur.FontColor = [0.6 0.4 0.1]; return;
        end
        try, curC = spt_filter_read(csv); catch ME, lblCur.Text = ['read failed: ' ME.message]; lblCur.FontColor=[0.75 0.1 0.1]; return; end
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
        % spt_filter_write.m:23 does it. The app-wide DTS belongs to the Detect tab's cell, which is
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
        if ~um, X = X/cCal.pixUm + 1; Y = Y/cCal.pixUm + 1; end      % back to 1-based px, on THIS cell's scale
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
                Cc = spt_filter_read(csv);
                km = Cc.len >= ml & Cc.dispUm >= mdp;
                st = spt_filter_write(Cc, km, tracksDir, base);
                spt_append_filter_settings(tracksDir, base, ml, mdp, st);   % stamp the filter params into _settings.txt
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

function s = srcWord(src)
% Where a calibration number came from, in words. The labels are spt_project_calib's, plus the two
% this app adds. 'panel' is spelled out rather than named, because it is the only one that is NOT
% this cell's own data and a reader skimming a log has to notice it.
switch lower(char(src))
    case 'settings', s = 'this cell''s _settings.txt';
    case 'movie',    s = 'its movie metadata';
    case 'xml',      s = 'its tracks XML';
    case 'derived',  s = 'derived';
    case 'edited',   s = 'hand-edited';
    case 'panel',    s = 'THE PANEL FALLBACK — not this cell';
    otherwise,       s = 'unknown';
end
end

function s = fbWhat(cal)
% Name which of the two numbers fell back, so the log line is specific. A cell that resolved its own
% pixel size but not its dt is a different problem from one that resolved neither.
w = {};
if strcmp(cal.srcPx,'panel'), w{end+1} = sprintf('%.5g µm/px', cal.pixUm); end
if strcmp(cal.srcDt,'panel'), w{end+1} = sprintf('%.6g s/frame', cal.dt_s); end
s = strjoin(w, ' and ');
end

function tf = inr_(v, lo, hi)
% The same gate spt_project_calib applies (its inr), so a value this app adopts is one the resolver
% would also have accepted. Keeping the two in step is what stops the manifest holding a number no
% other part of the pipeline trusts.
tf = isscalar(v) && isnumeric(v) && isfinite(v) && v >= lo && v <= hi;
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
