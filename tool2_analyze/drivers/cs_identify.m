function cs_identify(analysisDir, varargin)
%CS_IDENTIFY  In-MATLAB replacement for the Fiji CSidentifier step.
%
% Interactive contact-site picking on each cell's density map, writing
% csIDs/<base>_CSsites.txt in the EXACT format ContactSiteMapper[NoDeff] reads —
% so the whole post-tracking analysis runs in MATLAB with no ImageJ round-trip.
% The advisor's ContactSiteMapper is not modified.
%
%   cs_identify(analysisDir)
%   cs_identify(analysisDir,'MitoThresh',0.35,'MinArea',2,'AutoDetect',true)
%   cs_identify(analysisDir,'Parent',uiPanel)   % embed the UI in an app panel/tab
%
% A CELL NAVIGATOR (left table) lists every cell; click one to open its density
% map and pick / edit its contact sites. You can jump between cells in any order
% and revisit to add or remove sites — each cell's picks are held in memory (and
% reloaded from any existing <base>_CSsites.txt), harvested when you switch away,
% and written for all cells on "Finish". Per cell you can overlay the
% localizations, the tracks, and the mitochondria image, add / drag / delete
% contact-site points, and flag each as mito.
%
% NAME-VALUE
%   'MitoThresh' : fraction-of-max mito intensity to auto-flag a point mito (0.35)
%   'MinArea'    : min blob area (px) for an auto-detected candidate (2)
%   'AutoDetect' : seed with auto-detected candidates (true)
%   'Parent'     : a uipanel / uitab / uifigure to build the UI inside (for the
%                  integrated app). [] (default) opens a standalone uifigure.
%
% Output per cell: csIDs/<base>_CSsites.txt  (TAB-delimited; header + numeric
% body; col2=X col3=Y col7=mitoflag[1/2], or 6 columns when no mito info).

ip = inputParser;
ip.addParameter('MitoThresh',0.35,@isnumeric);   % legacy mito-MIP threshold (used only when a cell has no per-spot mito distance)
ip.addParameter('MinArea',2,@isnumeric);
ip.addParameter('AutoDetect',true,@islogical);
ip.addParameter('ContactUm',0.15,@isnumeric);    % contact-distance threshold (µm) for per-spot mito classification (~boundary band at 108 nm px)
ip.addParameter('MitoStat','median',@(s) any(strcmpi(s,{'median','fraction'})));  % per-site mito statistic
ip.addParameter('WinFrames',Inf,@isnumeric);     % detection density time-window length (frames); Inf = whole movie (default)
ip.addParameter('WinStep',[],@(x) isempty(x)||isnumeric(x));  % window step (frames); [] = non-overlapping (= WinFrames)
ip.addParameter('Parent',[]);
ip.addParameter('MitoDir','',@ischar);                    % app-supplied mito folder (Experiment tab)
ip.addParameter('MitoPat','{prefix}_mito_mip.tif',@ischar);% {prefix}-templated filename
ip.addParameter('MitoStrip','_spt\d+',@ischar);           % regex stripped off the cell base -> {prefix}
ip.addParameter('ErDir','',@ischar);                      % ER MIP folder (for the ER-weighted detection null)
ip.addParameter('ErPat','{prefix}_er_mip.tif',@ischar);
ip.addParameter('ErStrip','_spt\d+',@ischar);
ip.addParameter('IncludeFiles',{},@iscell);               % session cell selection: only these are pickable ({}=all)
ip.parse(varargin{:});
opt = ip.Results;
inParent = opt.Parent;
if ~isempty(inParent) && ~isgraphics(inParent), inParent = []; end   % stale handle -> standalone

assert(isfolder(analysisDir),'cs_identify: analysisDir not found: %s',analysisDir);
cfg = cs_config(analysisDir);   % this run's cs_calib.mat drives SF, regardless of pwd

if isfile(fullfile(analysisDir,'Tracks.mat'))
    L = load(fullfile(analysisDir,'Tracks.mat'));
elseif isfile(fullfile(analysisDir,'TrackStruct.mat'))
    L = load(fullfile(analysisDir,'TrackStruct.mat'));
else
    error('cs_identify:noTracks','No Tracks.mat / TrackStruct.mat in %s',analysisDir);
end
Tracks = L.Tracks;

csDir = fullfile(analysisDir,cfg.dir.csIDs);
if ~isfolder(csDir), mkdir(csDir); end

% ---- shared UI state (built once by ensureUI, reused for every cell) -------
container=[]; ax=[]; msg=[]; waitFig=[]; cellTbl=[];
btnAdd=[]; chkDens=[]; chkLoc=[]; chkTrk=[]; chkMito=[]; chkProb=[]; lstCS=[]; ddTrkColor=[];
sldDet=[]; btnRemCS=[]; lblCS=[]; ddDetMethod=[]; wSpin=[];   % sensitivity slider + null method + ER prior-weight spinner + CS-list controls
curDthr=Inf; curPStrong=NaN; curDetInfo='';   % last detection: CSR threshold, strongest-site null p, one-line info
MC_SIMS=100;   % Monte-Carlo random-labelling simulations per cell (null distribution size)
detCacheByCell={};   % per-cell cached detection (so a Monte-Carlo browse-back is instant; Re-detect forces refresh)
btnUndo=[]; ddMito=[]; sldDensA=[]; sldMitoA=[]; sldMitoC=[];   % undo / mito-at-pick / display sliders
pts = images.roi.Point.empty; idc = 0;                          % CURRENT cell's picked points
mitoN = []; mitoImgH = gobjects(0); densImgH = gobjects(0);     % current-cell image handles
locH = gobjects(0); trkH = gobjects(0); lastSelH = gobjects(0); selTrkH = gobjects(0);
W = 0; H = 0; SF = 1; addMode = false; csLog = {}; curBase = ''; manualMito = [];
curLx = []; curLy = []; Mx = []; My = [];   % current cell's localizations (density px) + raw um matrices
densCbar = [];            % colorbar giving an absolute localization-density scale (cross-cell comparable)
curPk = 0; curNloc = 0;   % current cell's peak loc/bin + total localizations (for the probability scale)
curDdisp = []; curPkDisp = 1; csDensClip = 1; sldDensCon = [];   % display density (Density_*.tif) + contrast clip
DENS_GAIN = 30;   % advisor's LocDensityFigIntUse: Density_*.tif = 30 * smoothed counts -> counts = value/30
DENS_CAP  = 255;  % advisor's uint8 display cap: pixel = min(value,255). Contrast clips BELOW this.
onPtClick = [];   % handle -> the current cell's addFromClick (so a click ON a marker routes there too)
% --- windowed density (moving sites) + per-spot mito classification + null-size knobs ---
chkWindow=[]; spnWinLen=[]; spnWinStep=[]; spnWinView=[]; spnSims=[]; spnContact=[]; ddMitoStat=[]; % control handles
winView = 0;                       % which detection window the DISPLAY shows (0 = whole-movie / merged)
curSmd = []; curFrame = []; curFrameInt = 1;   % per-loc signed mito dist (µm) + frame index; s/frame (window spinner is in seconds)
haveMitoDist = false;              % whether this cell carries per-spot mito distance (else fall back to the mito image)
curWinCounts = {}; curDdispFull = []; nFrames = 0;   % per-window display counts, whole-movie display density, frame count
inListRemove = false;              % reentrancy guard for click-to-remove in the CS list

% ---- multi-cell navigation state ------------------------------------------
nCells = numel(Tracks);
% one record per cell; picks are plain data (P,flags) so only the CURRENT cell holds live ROI points
% (the 6-col vs 8-col mito write format is derived from the flags at write time, not stored)
cellPicks = repmat(struct('loaded',false,'P',zeros(0,2),'flags',zeros(0,1),'manual',false(0,1), ...
    'reviewed',false,'seeded',false,'hasRho',false,'W',0,'H',0), 1, nCells);
curCell = 0; inSwitch = false; autoAcceptUnreviewed = true;

% Discover each cell's density map + preload any already-saved picks (so re-running
% csid shows prior work and you can go back and add/remove). Use a unique index name
% (not `i`) so it never becomes a variable shared with the nested functions' loops.
for c0 = 1:nCells
    base = cellBase(Tracks(c0).file, cfg);
    rho  = fullfile(analysisDir,cfg.dir.Densities,[Tracks(c0).file '_rho.tif']);
    cellPicks(c0).hasRho = (exist(rho,'file')==2);
    sf = fullfile(csDir,[base cfg.suffix.CSsites]);
    if exist(sf,'file')==2
        [Pp,Ff] = read_cssites(sf);
        if ~isempty(Pp)
            cellPicks(c0).P=Pp; cellPicks(c0).flags=Ff; cellPicks(c0).manual=true(size(Ff));   % saved picks = kept (survive a reset)
            cellPicks(c0).loaded=true; cellPicks(c0).seeded=true; cellPicks(c0).reviewed=true;
        end
    end
end

% Session file selection: if IncludeFiles is given, only those cells are pickable this run
% (mark the rest hasRho=false so navigation skips them). Match on cell base OR tracks file,
% by exact name or containment, so it is robust to prefix-stripping differences.
inc = opt.IncludeFiles;
if ~isempty(inc)
    if ischar(inc), inc = {inc}; end
    for c0 = 1:nCells
        b = cellBase(Tracks(c0).file, cfg); f = Tracks(c0).file;
        keep = any(cellfun(@(x) ~isempty(x) && (strcmpi(x,b) || strcmpi(x,f) || ...
            contains(f,x) || contains(b,x) || contains(x,b)), inc));
        if ~keep, cellPicks(c0).hasRho = false; end
    end
end

ensureUI();
guard = onCleanup(@close_id_windows); %#ok<NASGU>
fillCellTable();
first = find([cellPicks.hasRho], 1);
if isempty(first)
    warning('cs_identify:noRho','No density maps found in %s — nothing to pick.', fullfile(analysisDir,cfg.dir.Densities));
    finishUI(); return;
end
drawCell(first);

uiwait(waitFig);
if ~isvalid(waitFig)   % window closed (X) instead of Finish -> abort the run, don't skip silently
    error('cs_identify:aborted','Contact-site picking aborted (picker window closed).');
end
harvestCurrentCell();
finalizeAndWrite();
finishUI();

% ======================= nested (share workspace) =======================
    function ensureUI()
        if ~isempty(ax) && isgraphics(ax), return; end
        if isempty(inParent) || ~isgraphics(inParent)
            container = uifigure('Name','CS identify (pick contact sites)', ...
                'Position',[100 70 1240 860],'Tag','cs_identify_window','Color',[0.12 0.12 0.14]);
        else
            container = inParent; delete(allchild(container));
        end
        waitFig = ancestor(container,'matlab.ui.Figure');
        gl = uigridlayout(container,[1 3],'ColumnWidth',{196,'1x',236}, ...
            'Padding',[8 8 8 8],'ColumnSpacing',8);

        % --- cell navigator (left) ------------------------------------------
        cp = uigridlayout(gl,[2 1],'RowHeight',{20,'1x'},'Padding',[0 0 0 0],'RowSpacing',4);
        cp.Layout.Row=1; cp.Layout.Column=1;
        uilabel(cp,'Text','Cells — click to open','FontWeight','bold','FontSize',11);
        cellTbl = uitable(cp,'ColumnName',{'cell','#CS','✓'},'ColumnWidth',{116,42,24},'RowName',{}, ...
            'CellSelectionCallback',@(s,e) onCellSelect(e));

        % --- density / picker (centre) --------------------------------------
        ax = uiaxes(gl); ax.Layout.Row=1; ax.Layout.Column=2;
        axtoolbar(ax,{'zoomin','zoomout','pan','restoreview'});  % explicit zoom; keeps clicks for adding
        disableDefaultInteractivity(ax);                        % drop drag-pan (it would swallow the add click)
        % ...but keep SCROLL-WHEEL zoom on: scroll to zoom into a cluster, then left-click to
        % place a CS exactly — no more toggling the toolbar zoom on and off between adds.
        try, ax.Interactions = zoomInteraction; catch, end

        % --- controls (right) -----------------------------------------------
        % 18 rows for 18 children (btnAdd, Undo-grid, density, prob, loc, tracks, trkColor,
        % mito, LoadMito, sliders-grid, detect-grid, KNOBS-grid, CS label, CS list='1x', remove,
        % msg, review, finish). Sliders row 96 px; the knobs grid (windowing + mito-contact +
        % MC-sims) is 84 px.
        sp = uigridlayout(gl,[18 1],'RowHeight',{30,26,20,20,20,20,22,20,24,96,80,74,16,'1x',26,40,28,30}, ...
            'Padding',[2 2 2 2],'RowSpacing',4); sp.Layout.Row=1; sp.Layout.Column=3;
        btnAdd = uibutton(sp,'Text','+ Add CS: OFF','FontWeight','bold', ...
            'BackgroundColor',[0.30 0.30 0.34],'FontColor','w','ButtonPushedFcn',@(s,e) toggleAdd());
        % Undo + how new points are flagged (mito / not / auto)
        r2 = uigridlayout(sp,[1 2],'ColumnWidth',{72,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',4);
        btnUndo = uibutton(r2,'Text','Undo','ButtonPushedFcn',@(s,e) undoLastPoint());
        ddMito  = uidropdown(r2,'Items',{'mito=auto','mito=YES','mito=no'},'Value','mito=auto');
        chkDens = uicheckbox(sp,'Text','density','Value',true, 'ValueChangedFcn',@(s,e) onVis('dens',s.Value));
        chkProb = uicheckbox(sp,'Text','prob scale','Value',true, ...
            'Tooltip',['Colorbar in per-cell PROBABILITY (localizations/bin ÷ total localizations, the ' ...
            'paper''s PMF) instead of raw counts — expression-invariant. Off = ≈ localizations/bin.'], ...
            'ValueChangedFcn',@(s,e) updateDensScale());
        chkLoc  = uicheckbox(sp,'Text','localizations','Value',false,'ValueChangedFcn',@(s,e) onVis('loc', s.Value));
        chkTrk  = uicheckbox(sp,'Text','tracks','Value',true, 'ValueChangedFcn',@(s,e) onVis('trk', s.Value));
        ddTrkColor = uidropdown(sp,'Items',{'yellow','cyan','white','green','orange','red','magenta'}, ...
            'Value','yellow','ValueChangedFcn',@(s,e) onTrkColor());
        chkMito = uicheckbox(sp,'Text','mito overlay','Value',true,'ValueChangedFcn',@(s,e) onVis('mito',s.Value));
        uibutton(sp,'Text','Load mito…','ButtonPushedFcn',@(s,e) onPickMito());
        % Display sliders: density opacity, density contrast, mito opacity, mito contrast
        dg = uigridlayout(sp,[4 2],'ColumnWidth',{88,'1x'},'RowHeight',{'1x','1x','1x','1x'}, ...
            'Padding',[0 0 0 0],'RowSpacing',2,'ColumnSpacing',4);
        uilabel(dg,'Text','density α','FontSize',10);
        sldDensA = uislider(dg,'Limits',[0 1],'Value',1,  'MajorTicks',[],'ValueChangedFcn',@(s,e) onDisplayTune());
        uilabel(dg,'Text','density contrast','FontSize',10,'Tooltip','Clip the density colour scale — drag left to reveal fainter contact sites next to a very dense one');
        sldDensCon = uislider(dg,'Limits',[0.05 1],'Value',1,'MajorTicks',[],'MinorTicks',[], ...
            'ValueChangedFcn',@(s,e) onDensContrast(s.Value));
        uilabel(dg,'Text','mito α','FontSize',10);
        sldMitoA = uislider(dg,'Limits',[0 1],'Value',0.45,'MajorTicks',[],'ValueChangedFcn',@(s,e) onDisplayTune());
        uilabel(dg,'Text','mito contrast','FontSize',10);
        sldMitoC = uislider(dg,'Limits',[0 0.9],'Value',0,'MajorTicks',[],'ValueChangedFcn',@(s,e) onDisplayTune());
        % Auto-detect sensitivity: slide toward "more" to surface modest peaks the default
        % misses; "Re-detect" RESETS the auto-detected sites to the current sensitivity (clears
        % the previous auto sites, keeps your hand-placed/kept ones), so changing it doesn't pile up.
        detG = uigridlayout(sp,[3 4],'ColumnWidth',{16,44,'1x',72},'RowHeight',{14,30,'1x'}, ...
            'Padding',[0 0 0 0],'RowSpacing',2,'ColumnSpacing',4);
        lblDet = uilabel(detG,'Text','auto-detect sensitivity — stricter ◀ α ▶ more sites','FontSize',10, ...
            'Tooltip',['Auto-detect flags density peaks a CSR (complete-spatial-randomness) null model ' ...
            'rules out as chance. Uniform nulls (Monte-Carlo / Poisson) assume the same density everywhere. ' ...
            'Structure-aware nulls follow the cell: ER-weighted uses the ER MIP as the baseline where VAPB ' ...
            'should be (prior weight w: 0 = uniform on the ER, 1 = full ER-intensity conditioning), and ' ...
            'Local-background uses a large-scale smooth of VAPB itself (no external image). Slide α toward ' ...
            '"more" to accept weaker sites; remove any false ones below.']);
        lblDet.Layout.Row=1; lblDet.Layout.Column=[1 4];
        sldDet = uislider(detG,'Limits',[0 1],'Value',0.45,'MajorTicks',[],'MinorTicks',[], ...
            'ValueChangedFcn',@(s,e) reDetectCurrent());   % new alpha -> drop cache + re-detect the current cell live
        sldDet.Layout.Row=2; sldDet.Layout.Column=[1 4];   % full-width slider row (was cramped beside the controls)
        wLbl = uilabel(detG,'Text','w','FontSize',10,'HorizontalAlignment','right', ...
            'Tooltip','ER prior weight (used by the ER-weighted and ER Monte-Carlo nulls)');
        wLbl.Layout.Row=3; wLbl.Layout.Column=1;
        wSpin = uispinner(detG,'Limits',[0 1],'Value',0,'Step',0.1,'FontSize',10, ...
            'ValueChangedFcn',@(s,e) reDetectCurrent(), ...
            'Tooltip','ER prior weight w (ER-weighted / ER Monte-Carlo null): 0 = uniform on the ER (support mask), 1 = full ER-intensity conditioning.');
        wSpin.Layout.Row=3; wSpin.Layout.Column=2;
        ddDetMethod = uidropdown(detG,'Items',{'Monte-Carlo','Poisson','ER-weighted','ER Monte-Carlo','Local bg','Relative'}, ...
            'ItemsData',{'montecarlo','poisson','erweight','ermc','localbg','relative'},'Value','montecarlo','FontSize',10, ...
            'ValueChangedFcn',@(s,e) reDetectCurrent(), ...
            'Tooltip',['Null model for the significance threshold. Monte-Carlo / Poisson = uniform CSR ' ...
            '(structure-blind). ER-weighted = analytic baseline follows the ER MIP (uses the w spinner). ' ...
            'ER Monte-Carlo = the Monte-Carlo null REDISTRIBUTED onto the ER-supported pixels (w-weighted), ' ...
            'so only peaks above the ER-expected density survive. Local background = baseline is a large-scale ' ...
            'smooth of VAPB itself (no ER image). Relative = old per-cell prominence (slider = fraction of the cell peak).']);
        ddDetMethod.Layout.Row=3; ddDetMethod.Layout.Column=3;
        btnReDet = uibutton(detG,'Text','Re-detect','ButtonPushedFcn',@(s,e) onReDetect(), ...
            'Tooltip','Reset the auto-detected sites at the current method / α (your hand-placed sites are kept)');
        btnReDet.Layout.Row=3; btnReDet.Layout.Column=4;
        % --- windowed density (moving contact sites) + per-spot mito classification + MC-null size ---
        wg = uigridlayout(sp,[3 4],'ColumnWidth',{'1x',56,'1x',56},'RowHeight',{'1x','1x','1x'}, ...
            'Padding',[0 0 0 0],'RowSpacing',2,'ColumnSpacing',4);
        chkWindow = uicheckbox(wg,'Text','window (s)','Value',true,'FontSize',10, ...
            'Tooltip',['Detect the density in a TIME WINDOW (seconds) so a MOVING contact site stays sharp instead of ' ...
            'smearing over the whole movie. OFF = whole movie. Per-window candidates are merged + deduped (0.4 µm). ' ...
            'Organelle-neutral: a short window near the VAPB counting floor makes the fewest assumptions about which ' ...
            'organelle a site contacts; a longer window favours long-lived contacts.'], ...
            'ValueChangedFcn',@(s,e) onWindowChange());
        chkWindow.Layout.Row=1; chkWindow.Layout.Column=[1 2];
        spnWinLen = uispinner(wg,'Limits',[0.5 1e5],'Value',30,'Step',5,'FontSize',10, ...
            'Tooltip','Window length in SECONDS (converted to frames via the track frame interval).', ...
            'ValueChangedFcn',@(s,e) onWindowChange());
        spnWinLen.Layout.Row=1; spnWinLen.Layout.Column=3;
        spnWinView = uispinner(wg,'Limits',[0 0],'Value',0,'Step',1,'FontSize',10, ...
            'Tooltip','Scrub the DISPLAY through each detection window to watch a site move (0 = whole-movie). Detection is unaffected.', ...
            'ValueChangedFcn',@(s,e) onScrubWindow());
        spnWinView.Layout.Row=1; spnWinView.Layout.Column=4;
        lblSims = uilabel(wg,'Text','MC sims','FontSize',10, ...
            'Tooltip','Monte-Carlo CSR null size (simulations) for auto-detect. More = smoother threshold, slower.');
        lblSims.Layout.Row=2; lblSims.Layout.Column=1;
        spnSims = uispinner(wg,'Limits',[20 5000],'Value',MC_SIMS,'Step',50,'FontSize',10, ...
            'ValueChangedFcn',@(s,e) reDetectCurrent());
        spnSims.Layout.Row=2; spnSims.Layout.Column=2;
        lblCon = uilabel(wg,'Text','contact µm','FontSize',10, ...
            'Tooltip',['A site is mito if its localizations'' signed mito distance passes this threshold (µm). ' ...
            '~0.15 µm = the boundary band at 108 nm px. Active only when the cell carries per-spot mito distance.']);
        lblCon.Layout.Row=2; lblCon.Layout.Column=3;
        spnContact = uispinner(wg,'Limits',[-1 2],'Value',min(max(opt.ContactUm,-1),2),'Step',0.05,'FontSize',10, ...
            'ValueChangedFcn',@(s,e) onContactChange());
        spnContact.Layout.Row=2; spnContact.Layout.Column=4;
        lblStat = uilabel(wg,'Text','mito stat','FontSize',10, ...
            'Tooltip','median = typical distance ≤ contact (robust); fraction = ≥50% of nearby locs within contact (catches partial contacts).');
        lblStat.Layout.Row=3; lblStat.Layout.Column=1;
        ddMitoStat = uidropdown(wg,'Items',{'median','fraction'},'Value',lower(opt.MitoStat),'FontSize',10, ...
            'ValueChangedFcn',@(s,e) onContactChange());
        ddMitoStat.Layout.Row=3; ddMitoStat.Layout.Column=[2 4];
        lblCS = uilabel(sp,'Text','Contact sites — click a row to remove','FontWeight','bold','FontSize',11);
        lstCS = uilistbox(sp,'Items',{},'FontSize',11,'Multiselect','off', ...
            'Tooltip','Click a site in this list to DELETE it (re-add by clicking the density in Add mode). Right-click a point on the image for Delete / Toggle mito.', ...
            'ClickedFcn',@(s,e) onCSlistPick(e));   % ClickedFcn (not ValueChanged): fires on EVERY click, so any row — even the already-selected one — removes on click
        btnRemCS = uibutton(sp,'Text','－ Remove selected CS','FontColor',[0.75 0.1 0.1], ...
            'ButtonPushedFcn',@(s,e) onRemoveSelCS());
        msg = uilabel(sp,'Text','','WordWrap','on','FontSize',11);
        uibutton(sp,'Text','✓ Review & next','ButtonPushedFcn',@(s,e) reviewNext());
        uibutton(sp,'Text','Finish — save all','FontWeight','bold', ...
            'BackgroundColor',[0.18 0.45 0.70],'FontColor','w','ButtonPushedFcn',@(s,e) finishAll());
    end

    % -------- per-cell heavy prep (pure: reads state, returns everything) ----
    function [imG,Hh,Ww,SFq,mN,cand,bs,MxL,MyL,lxL,lyL,pkL] = prepCell(i, forceDet)
        if nargin<2 || isempty(forceDet), forceDet = false; end   % Re-detect passes true to refresh the cache
        bs  = cellBase(Tracks(i).file, cfg);
        rho = fullfile(analysisDir,cfg.dir.Densities,[Tracks(i).file '_rho.tif']);
        imG = ChrisPrograms.loadtiff(rho); [Hh,Ww,~] = size(imG);
        SFq = cfg.SnapFOV_um / size(imG,1);          % um per density pixel (col=X/SF, row=Y/SF)
        MxL = Tracks(i).matrix(:,:,2); MyL = Tracks(i).matrix(:,:,3);   % tracked-spot matrices (track overlay)
        % Localization set for density + mito classification. Prefer allSpots (EVERY detection,
        % tracked + untracked, each with its per-frame signed mito distance) so the density is denser
        % and moving-site/mito aware; fall back to the tracked matrix (+ mitoDist if present) for older
        % structs. aX/aY microns; aF integer frame; aMD signed µm to mito (+ outside, - inside; NaN=none).
        as = []; if isfield(Tracks,'allSpots'), as = Tracks(i).allSpots; end
        if ~isempty(as) && isfield(as,'X') && ~isempty(as.X)
            aX = double(as.X(:)); aY = double(as.Y(:));
            if isfield(as,'FRAME'), aF = double(as.FRAME(:)); else, aF = nan(size(aX)); end
            aMD = cs_channel_dist(Tracks(i), 'mito', 'cloud');       % NaN-filled when not imaged
        else
            ok0 = isfinite(MxL) & isfinite(MyL);
            aX = MxL(ok0); aY = MyL(ok0);
            F0 = Tracks(i).matrix(:,:,1); aF = F0(ok0);
            MD0 = cs_channel_dist(Tracks(i), 'mito', 'tracked');     % column, matrix order
            aMD = MD0(ok0(:));
        end
        keep = isfinite(aX) & isfinite(aY);
        aX = aX(keep); aY = aY(keep); aF = aF(keep); aMD = aMD(keep);
        lxL = aX/SFq; lyL = aY/SFq;                      % localizations in density px (all detections)
        curLx = lxL; curLy = lyL; curSmd = aMD; curFrame = aF;   % share with the mito classifier / csLocCount
        curFrameInt = 1;                                 % seconds per frame (for the window-seconds -> frames conversion)
        if isfield(Tracks,'frameInterval') && ~isempty(Tracks(i).frameInterval) && Tracks(i).frameInterval>0
            curFrameInt = Tracks(i).frameInterval;
        end
        haveMitoDist = any(isfinite(aMD));
        nFrames = 0; if ~isempty(aF) && any(isfinite(aF)), nFrames = max(aF(isfinite(aF))); end
        % Whole-movie localization density (monotonic) for auto-detection. Do NOT use rgb2gray(rho):
        % the density is turbo-mapped and rgb2gray(turbo) is NON-monotonic (a peak maps LOW), so it
        % would find the ring not the peak. Binning localizations directly (cs_window_density,
        % unbounded window) gives a true density — identical transform, whole movie.
        [rawCounts, Dens] = cs_window_density(aX, aY, aF, -Inf, Inf, SFq, Hh, Ww, 8);
        % DISPLAY density: the advisor's 16-bit Density_*.tif (= 30 * sigma-2 smoothed counts),
        % NOT the lossy min-max-scaled RGB rho.tif — so the colour scale is absolute (a single
        % very-dense site no longer washes fainter ones out) and matches the advisor's density.
        dfp = fullfile(analysisDir, ['Density_' Tracks(i).file '.tif']);
        curDdisp = [];
        if exist(dfp,'file')==2
            try
                D16 = double(imread(dfp));
                if size(D16,1)~=Hh || size(D16,2)~=Ww, D16 = imresize(D16,[Hh Ww]); end
                curDdisp = D16;
            catch, curDdisp = []; end
        end
        if isempty(curDdisp), curDdisp = DENS_GAIN*imgaussfilt(rawCounts, 2); end   % fallback, same 30*counts units
        curDdispFull = curDdisp;                         % whole-movie display (restored when the scrub returns to 0)
        curPkDisp = max(curDdisp(:)); if ~(curPkDisp>0), curPkDisp=1; end
        % optional mitochondria overlay (resized to the density frame) for context / fallback flagging
        mN = local_mito(analysisDir, bs, cfg, Hh, Ww, opt.MitoDir, opt.MitoPat, opt.MitoStrip);
        if isempty(mN) && ~isempty(manualMito)
            mN = imresize(manualMito,[Hh Ww]); mmx=max(mN(:)); if mmx>0, mN=mN/mmx; end
        end
        % auto-detected candidate centres = density peaks a CSR null model rules out as chance. When
        % windowing is ON, detection runs PER WINDOW (so a MOVING site stays sharp) and the per-window
        % candidates are merged + deduped (0.4 µm). Cache per cell (keyed on the window settings) so a
        % browse-back is instant; Re-detect (forceDet) refreshes.
        wk = winKey();
        useCache = ~forceDet && numel(detCacheByCell)>=i && ~isempty(detCacheByCell{i}) && ...
                   isfield(detCacheByCell{i},'winKey') && isequal(detCacheByCell{i}.winKey, wk);
        if useCache
            dc = detCacheByCell{i};
            cand = dc.cand; curDthr = dc.Dthr; curPStrong = dc.pStrong; curDetInfo = dc.info;
            if isfield(dc,'winCounts'), curWinCounts = dc.winCounts; else, curWinCounts = {}; end   % keep the scrub alive on browse-back
        else
            win = build_windows();                       % Kx2 [t0 t1] over the cell's frame range, or [] whole-movie
            if isempty(win)
                [cand, curDthr, curPStrong, curDetInfo] = run_detect(rawCounts, Dens, Hh, Ww, bs);
                curWinCounts = {};
            else
                cand = zeros(0,2); pAll = NaN; DthrAll = Inf; curWinCounts = cell(size(win,1),1);
                Rpx = 0.4/max(SFq,eps);
                for wi = 1:size(win,1)
                    [rcw, Dnw] = cs_window_density(aX, aY, aF, win(wi,1), win(wi,2), SFq, Hh, Ww, 8);
                    curWinCounts{wi} = rcw;
                    [cw, Dthrw, pw] = run_detect(rcw, Dnw, Hh, Ww, bs);
                    for r = 1:size(cw,1)                  % merge, dedup against sites already kept (0.4 µm)
                        c = cw(r,:);
                        if isempty(cand) || min(hypot(cand(:,1)-c(1), cand(:,2)-c(2))) > Rpx
                            cand(end+1,:) = c; %#ok<AGROW>
                        end
                    end
                    if isfinite(pw) && (~isfinite(pAll) || pw < pAll), pAll = pw; end
                    DthrAll = min(DthrAll, Dthrw);
                end
                curDthr = DthrAll; curPStrong = pAll;
                curDetInfo = sprintf('windowed %dw x %dfr -> %d sites', size(win,1), win(1,2)-win(1,1)+1, size(cand,1));
            end
            dcs = struct('cand',cand,'Dthr',curDthr,'pStrong',curPStrong,'info',curDetInfo,'winKey',wk);
            dcs.winCounts = curWinCounts;                % cache the per-window display counts too (scrub survives revisit)
            detCacheByCell{i} = dcs;
        end
        pkL = 0;
        if ~isempty(lxL)
            try, hc = histcounts2(lxL, lyL, 0.5:1:(Ww+0.5), 0.5:1:(Hh+0.5)); pkL = max(hc(:)); catch, end
        end
    end

    % -------- one detection pass on a given density (whole-movie or a single window) --------
    function [cand, Dthr, pStrong, info] = run_detect(rc, Dn, Hh, Ww, bs)
        detMask = imfill(imclose(rc>0, strel('disk',8)),'holes');   % footprint the null scatters into
        method = detMethod(); wER = detWeight(); lamMap = []; detMaskEff = detMask; wmap = [];
        if any(strcmp(method,{'erweight','localbg','ermc'}))     % structure-aware nulls
            if any(strcmp(method,{'erweight','ermc'}))
                erN = local_er(analysisDir, bs, cfg, Hh, Ww, opt.ErDir, opt.ErPat, opt.ErStrip);
            else
                erN = [];
            end
            if strcmp(method,'ermc')                     % ER Monte-Carlo: null redistributed onto ER pixels
                if ~isempty(erN)
                    sup = detMask & (erN > 0.05); if ~any(sup(:)), sup = detMask; end
                    wmap = (erN.^wER) .* sup; if ~any(wmap(:)>0), wmap = double(sup); end
                    detMaskEff = sup;
                end                                      % no ER MIP -> wmap stays [] -> uniform MC over the footprint
            elseif strcmp(method,'erweight') && ~isempty(erN)
                sup = detMask & (erN > 0.05);            % on-ER support (contact sites live on the ER)
                if ~any(sup(:)), sup = detMask; end
                pin = (erN.^wER) .* sup;                 % w=0 -> uniform on ER; w=1 -> full ER conditioning
                sden = sum(pin(:)); if sden<=0, pin = double(sup); sden = sum(pin(:)); end
                Non = sum(rc(sup));                       % locs that live ON the ER -> keeps mu on the data's scale
                lamMap = (Non/sden) * pin; detMaskEff = sup;
            end
            if isempty(lamMap) && ~strcmp(method,'ermc') % local-background, or ER-weighted fallback (no ER MIP)
                bg = imgaussfilt(rc, 48) .* detMask;      % large-scale (6*sigma) VAPB self-background
                sden = sum(bg(:)); if sden<=0, bg = double(detMask); sden = sum(bg(:)); end
                lamMap = (sum(rc(detMask))/sden) * bg;
                if strcmp(method,'erweight'), method = 'localbg'; end   % note the fallback in the title
            end
        end
        [cand, Dthr, pStrong, info] = detect_candidates(Dn, rc, detMaskEff, ...
            opt.MinArea, opt.AutoDetect, Ww, Hh, method, detAlphaOrFrac(), detSims(), 8, lamMap, wER, wmap);
    end

    % -------- draw a cell into the (persistent) picker UI --------------------
    function drawCell(i)
        ensureUI();
        [imG,H,W,SF,mitoN,cand,curBase,Mx,My,curLx,curLy,pk] = prepCell(i);
        curCell = i; cellPicks(i).loaded = true; cellPicks(i).reviewed = true;
        cellPicks(i).W = W; cellPicks(i).H = H;
        syncWinView();                                     % reset the window-scrub range for this cell
        cla(ax); lastSelH = gobjects(0); selTrkH = gobjects(0);
        curPk = curPkDisp; curNloc = numel(curLx);
        rgbD = pickerDensRGB(); if isempty(rgbD), rgbD = imG; end   % re-rendered density (contrast) or rho.tif fallback
        densImgH = imshow(rgbD,'Parent',ax); hold(ax,'on');
        drawMitoOverlay();                                 % faint magenta mito context + flagging
        pkCounts = curPkDisp/DENS_GAIN;   % Density_*.tif value / 30 = smoothed localizations per bin
        ttl = sprintf('%s   (%d/%d)   —   %d loc · %d tracks · peak ~%.3g loc/bin · %d sites  [%s]', ...
            curBase, i, nCells, numel(curLx), size(Tracks(i).matrix,2), pkCounts, size(cand,1), curDetInfo);
        if isfinite(curPStrong), ttl=[ttl sprintf('  strongest site p=%.1e', curPStrong)]; end
        title(ax, ttl);
        updateDensScale();   % colorbar as an absolute scale (loc/bin or per-cell probability)
        locH = scatter(ax, curLx, curLy, 3, [0.15 0.9 0.9], 'filled', 'MarkerFaceAlpha',0.35,'HitTest','off');
        trkH = plot(ax, Mx/SF, My/SF, '-','Color',trkRGBA(),'HitTest','off');   % one line per track
        setVis(densImgH, chkDens.Value); setVis(locH, chkLoc.Value); setVis(trkH, chkTrk.Value);
        if ~isempty(sldDensA) && isgraphics(sldDensA) && isgraphics(densImgH)
            try densImgH.AlphaData = sldDensA.Value; catch, end   % carry density-opacity across cells
        end
        addMode = false; applyAddMode();
        % clicks add (add mode) / select a track (view mode). Overlays are HitTest off so
        % clicks reach the axes/image; a click ON a marker is forwarded via ROIClicked.
        imh = findobj(ax,'Type','image');
        for h = imh(:)', h.ButtonDownFcn = @(s,e) addFromClick(); end
        ax.ButtonDownFcn = @(s,e) addFromClick();
        onPtClick = @(xy,st) addFromClick(xy,st);
        % seed the live points: restore this cell's stored/saved picks if it has them,
        % else drop the auto-detected candidates (and stash them so revisits are stable).
        pts = images.roi.Point.empty; idc = 0;
        if cellPicks(i).seeded
            Ps = cellPicks(i).P; Fs = cellPicks(i).flags; Ms = cellPicks(i).manual;
            for k = 1:size(Ps,1)
                isMan = isempty(Ms) || k>numel(Ms) || Ms(k);   % default (older entries) -> manual (kept)
                mkPointFlag(Ps(k,:), Fs(k), isMan);
            end
        else
            for k = 1:size(cand,1), mkPoint(cand(k,:), opt.MitoThresh); end
            harvestCurrentCell();                 % stash the auto-seeded picks
            cellPicks(i).seeded = true;
        end
        if ~isempty(lastSelH) && isgraphics(lastSelH), delete(lastSelH); lastSelH=gobjects(0); end  % no ring at load
        refreshList(); fillCellTable();
        msg.Text = 'View mode: click a cell at left to switch; click a track to highlight; "+ Add CS" to place sites.';
    end

    % -------- harvest the current cell's live ROI points into plain data -----
    function harvestCurrentCell()
        if curCell<1 || curCell>nCells, return; end
        v = pts(isvalid(pts));
        P = zeros(numel(v),2); fl = zeros(numel(v),1); man = false(numel(v),1);
        for k = 1:numel(v), P(k,:) = v(k).Position; fl(k) = flagOf(v(k)); man(k) = strcmp(v(k).Tag,'manual'); end
        if ~isempty(P) && W>0                     % keep to valid pixel indices (no inward snap)
            P(:,1) = min(max(P(:,1),1), W);
            P(:,2) = min(max(P(:,2),1), H);
        end
        cellPicks(curCell).P = P; cellPicks(curCell).flags = fl; cellPicks(curCell).manual = man;  % keep auto/manual so Re-detect resets correctly on revisit
        cellPicks(curCell).reviewed = true; cellPicks(curCell).seeded = true;
        cellPicks(curCell).W = W; cellPicks(curCell).H = H;
    end

    function onCellSelect(e)
        if inSwitch || isempty(e) || isempty(e.Indices), return; end
        row = e.Indices(1,1);
        if row<1 || row>nCells || row==curCell, return; end
        if ~cellPicks(row).hasRho
            if isgraphics(msg), msg.Text = sprintf('%s has no density map — nothing to pick.', cellBase(Tracks(row).file,cfg)); end
            return;
        end
        inSwitch = true;
        try
            harvestCurrentCell();
            drawCell(row);
        catch ME
            if isgraphics(msg), msg.Text = ['Could not open cell: ' ME.message]; end
        end
        inSwitch = false;
    end

    function fillCellTable()
        if isempty(cellTbl) || ~isgraphics(cellTbl), return; end
        D = cell(nCells,3);
        for i = 1:nCells
            nm = cellBase(Tracks(i).file, cfg);
            if i==curCell, nm = ['▶ ' nm]; end
            if ~cellPicks(i).hasRho, cnt = 'no map';
            elseif cellPicks(i).seeded, cnt = size(cellPicks(i).P,1);
            else, cnt = ''; end
            D(i,:) = {nm, cnt, tern(cellPicks(i).reviewed,'✓','')};
        end
        cellTbl.Data = D;
    end

    function reviewNext()
        harvestCurrentCell();
        nxt = find([cellPicks.hasRho] & ((1:nCells) > curCell), 1);
        if isempty(nxt), nxt = find([cellPicks.hasRho], 1); end   % wrap to the first
        if isempty(nxt), return; end
        inSwitch = true; try, drawCell(nxt); catch, end; inSwitch = false;
    end

    function finishAll()
        harvestCurrentCell();
        un = find([cellPicks.hasRho] & ~[cellPicks.seeded]);   % have a map but never seeded/reviewed
        autoAcceptUnreviewed = true;
        if ~isempty(un)
            d = 'Auto-accept detected';
            try
                d = uiconfirm(waitFig, sprintf(['%d cell(s) have not been reviewed. Auto-accept their ' ...
                    'auto-detected contact sites, or skip them (leave those cells with no CS)?'], numel(un)), ...
                    'Finish contact-site picking', 'Options',{'Auto-accept detected','Skip unreviewed','Cancel'}, ...
                    'DefaultOption',1,'CancelOption',3);
            catch, end
            if strcmp(d,'Cancel'), return; end
            autoAcceptUnreviewed = strcmp(d,'Auto-accept detected');
        end
        if isgraphics(waitFig), uiresume(waitFig); end
    end

    % -------- write every cell's picks to csIDs/<base>_CSsites.txt -----------
    function finalizeAndWrite()
        csLog = {};
        for i = 1:nCells
            if ~cellPicks(i).hasRho, continue; end
            base = cellBase(Tracks(i).file, cfg);
            csFile = fullfile(csDir,[base cfg.suffix.CSsites]);
            if ~cellPicks(i).seeded
                if autoAcceptUnreviewed
                    [~,Hx,Wx,SFx,mNx,candx] = prepCell(i);   % sets curLx/curLy/curSmd/haveMitoDist for cell i
                    P = candx; fl = zeros(size(P,1),1);
                    Rx = 0.6/max(SFx,eps);                   % this cell's 0.6 µm neighbourhood (not the last-drawn cell's SF)
                    for k = 1:size(P,1)
                        if haveMitoDist
                            fl(k) = cs_mito_from_dist(P(k,:), curLx, curLy, curSmd, Rx, contactUm(), useFractionStat());
                        else
                            fl(k) = mitoAtXY(P(k,:), opt.MitoThresh, mNx, Wx, Hx);
                        end
                    end
                    cellPicks(i).P=P; cellPicks(i).flags=fl;
                    cellPicks(i).W=Wx; cellPicks(i).H=Hx; cellPicks(i).seeded=true;
                else
                    csLog{end+1} = sprintf('[skip] %s: not reviewed', base); %#ok<AGROW>
                    continue;
                end
            end
            P = cellPicks(i).P; fl = cellPicks(i).flags;
            if cellPicks(i).W>0 && ~isempty(P)
                P(:,1) = min(max(P(:,1),1), cellPicks(i).W);
                P(:,2) = min(max(P(:,2),1), cellPicks(i).H);
            end
            if isempty(P)
                % A header-only file cannot be parsed by importdata into a struct, so write
                % nothing: ContactSiteMapper needs >=1 CS row per cell. If a saved file for
                % this cell already exists (e.g. the user just DELETED every site from a
                % preloaded cell), remove it so the mapper does not keep consuming stale sites.
                if exist(csFile,'file')==2
                    try delete(csFile); tag='cleared'; catch, tag='0 CS (stale file remains)'; end
                else
                    tag='0 CS';
                end
                warning('cs_identify:emptyCS','%s: no contact sites — no CSsites file.', base);
                csLog{end+1} = sprintf('[%s] %s: 0 CS', tag, base); %#ok<AGROW>
                continue;
            end
            % Write 8-column (mito) format iff ANY point is mito-flagged, so col7 carries the
            % 1/2 flags. Driving this off the actual flags — not a transient mito image that
            % may be unavailable this session — keeps a re-opened mito cell from silently
            % downgrading to 6-column and losing its mito classifications.
            local_write(csFile, P, fl, any(fl==1));
            csLog{end+1} = sprintf('[done] %s: %d CS (%d mito)', base, size(P,1), sum(fl==1)); %#ok<AGROW>
            fprintf('cs_identify: %s -> %d CS (%d mito-flagged) -> csIDs/%s\n', ...
                base, size(P,1), sum(fl==1), [base cfg.suffix.CSsites]);
        end
    end

    function mkPoint(xy, mThr)                    % place an AUTO-detected candidate (mito auto-classified)
        registerPoint(drawpoint(ax,'Position',xy), mThr, false);
    end
    function mkPointFlag(xy, fl, isMan)           % restore a stored point with its known flag + auto/manual provenance
        if ~ismember(fl,[1 2]), fl = 2; end
        if nargin<3, isMan = true; end
        p = drawpoint(ax,'Position',xy);
        try, p.Tag = tern(isMan,'manual','auto'); catch, end   % preserve provenance so "Re-detect (reset)" clears only auto
        registerPointCore(p, fl);
    end

    function addFromClick(xyIn, stIn)             % add mode: drop a CS; view mode: highlight a track
        % LEFT single-click only. Two call paths: (a) axes/image ButtonDownFcn -> no args, so
        % read the figure SelectionType + ax.CurrentPoint; (b) a marker's ROIClicked -> the
        % caller passes the marker Position + the EVENT SelectionType (authoritative on that
        % path). figure vocab = normal/alt/open/extend; ROI event = left/right/double/shift.
        if nargin>=2 && ~isempty(stIn), st = stIn;
        else, st=''; if isgraphics(waitFig), st = waitFig.SelectionType; end
        end
        if ~any(strcmpi(st,{'normal','left'})), return; end   % ignore right/double/shift/middle
        if nargin>=1 && ~isempty(xyIn), xy = xyIn(1,1:2);
        else, cp2 = ax.CurrentPoint; xy = cp2(1,1:2);
        end
        % Ignore clicks outside the density image (the axes letterboxes a square rho).
        if ~all(isfinite(xy)) || xy(1)<1 || xy(1)>W || xy(2)<1 || xy(2)>H, return; end
        if addMode
            registerPoint(drawpoint(ax,'Position',xy), opt.MitoThresh, true);  % user-placed -> honor mito dropdown
        else
            selTrackInPicker(xy);
        end
    end

    function selTrackInPicker(xy)                 % view-mode: highlight the track under the cursor
        dAll = hypot(Mx/SF - xy(1), My/SF - xy(2));   % [frames x tracks] click-to-spot distance (px)
        dTrk = min(dAll, [], 1, 'omitnan');           % nearest spot per track -> [1 x n]
        dTrk(~isfinite(dTrk)) = Inf;
        [dm,t] = min(dTrk);
        if isempty(dm) || ~isfinite(dm), return; end  % no tracks / all-NaN -> nothing to select
        if ~isempty(selTrkH) && isgraphics(selTrkH), delete(selTrkH(isgraphics(selTrkH))); end
        xt = Mx(:,t)/SF; yt = My(:,t)/SF; ok = isfinite(xt)&isfinite(yt);
        selTrkH = plot(ax, xt(ok), yt(ok), '-o','Color',[1 0.12 0.12],'LineWidth',3, ...
            'MarkerSize',4,'MarkerFaceColor',[1 0.12 0.12],'HitTest','off');
        try uistack(selTrkH,'top'); catch, end
        msg.Text = sprintf('Track %d selected — %d spots (%.0f px from click). Turn "+ Add CS" ON to place sites.', ...
            t, nnz(ok), dm);
    end

    function toggleAdd()
        % Real ON<->OFF toggle. Adding is NON-BLOCKING (a click on the axes places a point
        % via addFromClick), so the button turns add mode off again and rapid clicks are
        % never lost in a draw()-loop gap.
        addMode = ~addMode;
        applyAddMode();
    end

    function applyAddMode()
        % single source of truth for the button / cursor / message that must match addMode
        if isgraphics(btnAdd)
            if addMode, btnAdd.Text='+ Add CS: ON (click to place)'; btnAdd.BackgroundColor=[0.18 0.55 0.30];
            else,       btnAdd.Text='+ Add CS: OFF';                 btnAdd.BackgroundColor=[0.30 0.30 0.34]; end
        end
        if isgraphics(waitFig), waitFig.Pointer = tern(addMode,'crosshair','arrow'); end
        if isgraphics(msg)
            if addMode, msg.Text='ADD MODE: scroll to zoom in, then click to drop a contact site exactly there. Click "+ Add CS" again to stop.';
            else,       msg.Text='View mode: scroll to zoom; click a track to highlight; right-click a point to Delete / Toggle mito; Undo removes the last.'; end
        end
    end

    function setVis(h, on)
        h = h(isgraphics(h));
        if ~isempty(h), set(h,'Visible',tern(on,'on','off')); end
    end

    function onVis(layer, on)
        % read the LIVE per-cell handle (an anonymous closure would freeze the
        % gobjects(0) placeholder captured at ensureUI time -> dead checkboxes).
        switch layer
            case 'dens', setVis(densImgH, on);
            case 'loc',  setVis(locH,     on);
            case 'trk',  setVis(trkH,     on);
            case 'mito', setVis(mitoImgH, on);
        end
    end

    function rgba = trkRGBA()          % track line color+alpha from the dropdown
        if isempty(ddTrkColor) || ~isgraphics(ddTrkColor), name='yellow'; else, name=ddTrkColor.Value; end
        switch name
            case 'cyan',    c=[0.15 0.9 0.9];
            case 'white',   c=[1 1 1];
            case 'green',   c=[0.2 0.9 0.3];
            case 'orange',  c=[1 0.6 0.1];
            case 'red',     c=[1 0.25 0.25];
            case 'magenta', c=[1 0.3 1];
            otherwise,      c=[1 1 0];      % yellow
        end
        rgba=[c 0.45];
    end

    function onTrkColor()              % recolor the live track lines (trkH is one handle PER track)
        h = trkH(isgraphics(trkH));    % isgraphics is element-wise -> filter, don't && a non-scalar
        if ~isempty(h), set(h,'Color',trkRGBA()); end
    end

    function drawMitoOverlay()     % (re)draw the magenta mito overlay from mitoN
        if ~isempty(mitoImgH) && isgraphics(mitoImgH), delete(mitoImgH); end
        mitoImgH = gobjects(0);
        if ~isempty(mitoN)
            md = mitoN;
            cc = 0; if ~isempty(sldMitoC) && isgraphics(sldMitoC), cc = min(max(sldMitoC.Value,0),0.9); end
            if cc>0, md = imadjust(md,[cc 1],[0 1]); end        % raise low-in -> faint mito brightens
            a = 0.45; if ~isempty(sldMitoA) && isgraphics(sldMitoA), a = sldMitoA.Value; end
            mrgb = cat(3, md, zeros(H,W), md);
            mitoImgH = image(ax,'CData',mrgb,'AlphaData',min(1,a*md),'HitTest','off');
            uistack(mitoImgH,'bottom');
            if ~isempty(densImgH) && isgraphics(densImgH), uistack(densImgH,'bottom'); end
        end
        if ~isempty(chkMito) && isgraphics(chkMito)
            chkMito.Enable = tern(~isempty(mitoN),'on','off');
            setVis(mitoImgH, chkMito.Value);
        end
    end

    function rgb = pickerDensRGB()
        % Map the 16-bit Density_*.tif (curDdisp = 30*counts) to turbo. DEFAULT (csDensClip=1)
        % clips at the advisor's fixed cap 255 -> pixel = min(value,255), the advisor's exact,
        % cross-cell-comparable scaling. Contrast is the DEVIATION: dragging it below 1 lowers
        % the cap (255*clip) so faint sites next to a very dense one brighten instead of washing out.
        rgb = [];
        if isempty(curDdisp), return; end
        cmax = max(csDensClip,0.02) * DENS_CAP; if ~(cmax>0), cmax=1; end
        idx = uint8(round(255*min(max(curDdisp,0)/cmax,1)));
        rgb = ind2rgb(idx, turbo(256));
    end

    function updateDensScale()
        % Colorbar for the density map, in the advisor's units: the Density_*.tif value is
        % 30*smoothed_counts, so counts = value/30 and probability = counts/NormTotal
        % (LocDensityFigIntUse; e.g. its "axis max" = (255/30)/NormTotal at value 255). The
        % top is the CONTRAST clip point so the legend matches the display saturation.
        if isempty(ax) || ~isgraphics(ax), return; end
        try
            colormap(ax, turbo);
            topD      = max(csDensClip,0.02) * DENS_CAP; % advisor's cap 255 at clip=1 (fixed, absolute)
            topCounts = topD / DENS_GAIN;                % -> smoothed localizations / bin (255/30 = 8.5 at clip=1)
            useProb = ~isempty(chkProb) && isgraphics(chkProb) && chkProb.Value;
            if useProb && curNloc>0 && topCounts>0
                ax.CLim=[0 topCounts/curNloc]; lab='localization probability / bin';
            elseif topCounts>0
                ax.CLim=[0 topCounts];         lab='≈ localizations / 30 nm bin';
            else
                lab='';
            end
            if ~isempty(densCbar) && isgraphics(densCbar), delete(densCbar); end
            densCbar = colorbar(ax); if ~isempty(lab), densCbar.Label.String = lab; end
        catch, end
    end

    function onDensContrast(v)
        % contrast clip for the density display (re-maps curDdisp live; colorbar follows).
        csDensClip = max(0.05, min(1, v));
        if ~isempty(densImgH) && isgraphics(densImgH)
            rgbD = pickerDensRGB();
            if ~isempty(rgbD)
                a = densImgH.AlphaData; densImgH.CData = rgbD;   % keep the density-opacity + z-order
                try densImgH.AlphaData = a; catch, end
            end
        end
        updateDensScale();
    end

    function onPickMito()          % load a mito image when Mito/ has none (e.g. it's at the project root)
        [fn,pth] = uigetfile({'*.tif;*.tiff','TIFF images'},'Pick the mitochondria image (MIP or stack)');
        if isequal(fn,0), return; end
        try
            fp=fullfile(pth,fn); info=imfinfo(fp); im=imread(fp,1);
            for kk=2:numel(info), im=max(im,imread(fp,kk)); end   % running MIP
            if size(im,3)==3, g=im2double(rgb2gray(im)); else, g=im2double(im); end
            mx=max(g(:)); if mx>0, g=g/mx; end
            manualMito = g;                            % persists for later cells too
            mitoN = imresize(g,[H W]); mmx=max(mitoN(:)); if mmx>0, mitoN=mitoN/mmx; end
            if ~isempty(chkMito), chkMito.Value=true; end
            drawMitoOverlay();
            if ~isempty(msg), msg.Text=sprintf('Mito loaded: %s [%dx%d]. Toggle "mito overlay"; right-click a point to flag it mito.', fn, size(g,1), size(g,2)); end
        catch ME
            if ~isempty(msg), msg.Text=['mito load failed: ' ME.message]; end
        end
    end

    function refreshList()
        if isempty(lstCS) || ~isgraphics(lstCS), return; end
        v = pts(isvalid(pts));
        items = cell(1,numel(v));
        for k = 1:numel(v)
            items{k} = sprintf('CS %d  ·  %s', k, tern(flagOf(v(k))==1,'mito','non-mito'));
        end
        lstCS.Items = items;      % programmatic -> does not fire ValueChangedFcn
        if ~isempty(lblCS) && isgraphics(lblCS)
            nDone = nnz([cellPicks.reviewed] & [cellPicks.hasRho]); nMap = nnz([cellPicks.hasRho]);
            lblCS.Text = sprintf('Contact sites — click to remove (%d)   ·   cells %d/%d', numel(v), nDone, nMap);
        end
    end

    function frac = detFrac()          % slider -> prominence fraction (right = more sites) — RELATIVE mode
        frac = 0.35;
        if ~isempty(sldDet) && isgraphics(sldDet), frac = 0.60 - 0.55*sldDet.Value; end
        frac = min(max(frac,0.05),0.60);
    end
    function a = detAlpha()            % slider -> family-wise significance alpha (right = larger alpha = more sites)
        v = 0.45; if ~isempty(sldDet) && isgraphics(sldDet), v = sldDet.Value; end
        a = 0.01 * 10.^(1.4*v);        % v=0 -> 0.01 (strict), v=1 -> ~0.25 (lenient); log sweep
        a = min(max(a,1/max(MC_SIMS,1)),0.4);   % floor at 1/M: finer alpha than the null resolves is meaningless
    end
    function clearDetCache()           % detection settings changed -> drop cache so browsing reflects current method/alpha
        detCacheByCell = {};
        if ~isempty(msg) && isgraphics(msg)
            msg.Text = 'Detection settings changed — press "Re-detect" to apply to the current cell.';
        end
    end
    function mth = detMethod()         % current null-model method
        mth = 'montecarlo';
        if ~isempty(ddDetMethod) && isgraphics(ddDetMethod), mth = ddDetMethod.Value; end
    end
    function w = detWeight()           % ER prior weight (ER-weighted null): 0 = on-ER uniform, 1 = full conditioning
        w = 0; if ~isempty(wSpin) && isgraphics(wSpin), w = wSpin.Value; end
        w = min(max(w,0),1);
    end
    function a = detAlphaOrFrac()      % the slider's meaning depends on the method
        if strcmpi(detMethod(),'relative'), a = detFrac(); else, a = detAlpha(); end
    end
    function n = detSims()             % Monte-Carlo null size (simulations) — the M knob
        n = MC_SIMS;
        if ~isempty(spnSims) && isgraphics(spnSims), n = round(spnSims.Value); end
        n = max(round(n),20);
    end
    function u = contactUm()           % contact-distance threshold (µm) for per-spot mito classification
        u = opt.ContactUm;
        if ~isempty(spnContact) && isgraphics(spnContact), u = spnContact.Value; end
    end
    function tf = useFractionStat()    % mito statistic: false = median distance, true = fraction within contact
        tf = strcmpi(opt.MitoStat,'fraction');
        if ~isempty(ddMitoStat) && isgraphics(ddMitoStat), tf = strcmpi(ddMitoStat.Value,'fraction'); end
    end
    function r = contactRadPx()        % neighbourhood radius (density px) whose locs classify a site (~0.6 µm)
        r = 0.6 / max(SF,eps);
    end
    function L = winLenFrames()        % detection window length in FRAMES (the spinner is in SECONDS)
        if ~isempty(chkWindow) && isgraphics(chkWindow) && chkWindow.Value ...
                && ~isempty(spnWinLen) && isgraphics(spnWinLen)
            L = max(round(spnWinLen.Value / max(curFrameInt,eps)), 1);   % seconds -> frames
        elseif ~isempty(chkWindow) && isgraphics(chkWindow)   % checkbox exists and is OFF
            L = Inf;
        else                                                  % pre-UI (headless): honor the opt default (frames)
            L = opt.WinFrames;
        end
    end
    function s = winStepFrames()       % detection window step in frames (default = non-overlapping)
        s = winLenFrames();
        if ~isempty(spnWinStep) && isgraphics(spnWinStep) && spnWinStep.Value>0
            s = max(round(spnWinStep.Value),1);
        elseif ~isempty(opt.WinStep) && opt.WinStep>0
            s = max(round(opt.WinStep),1);
        end
        s = min(s, winLenFrames());    % step > length would leave uncovered frame gaps -> clamp (overlap OK, gaps not)
    end
    function k = winKey()              % cache key: window settings that change the candidate set
        k = [winLenFrames(), winStepFrames()];
    end
    function win = build_windows()     % tile [f0 f1] windows over the cell's ACTUAL frame range; [] = whole-movie
        win = [];
        if isempty(curFrame), return; end
        ff = curFrame(isfinite(curFrame));
        if isempty(ff), return; end
        f0 = min(ff); f1 = max(ff); span = f1 - f0 + 1;     % frames can be 0-indexed (ERAware) — start at f0, not 1
        L = winLenFrames();
        if ~isfinite(L) || span<1 || L>=span, return; end   % window >= movie -> no tiling (whole-movie)
        s = max(winStepFrames(),1);
        t0 = f0; rows = zeros(0,2);
        while t0 <= f1
            rows(end+1,:) = [t0, min(t0+L-1, f1)]; %#ok<AGROW>
            if rows(end,2) >= f1, break; end
            t0 = t0 + s;
        end
        if size(rows,1) >= 2 && (rows(end,2)-rows(end,1)+1) < 0.25*L   % absorb a tiny trailing remainder
            rows(end-1,2) = rows(end,2); rows(end,:) = [];
        end
        win = rows;
    end
    function reDetectCurrent()         % a null knob changed -> drop cache + re-detect the current cell live
        clearDetCache();
        if curCell>=1 && curCell<=nCells, onReDetect(); end
    end
    function onWindowChange()          % window length/step changed -> re-detect with the new windows
        clearDetCache();
        if curCell>=1 && curCell<=nCells, onReDetect(); end
        syncWinView();                 % refresh the scrub range from the windows just built
    end
    function syncWinView()             % scrub spinner range = number of detection windows this cell has
        if isempty(spnWinView) || ~isgraphics(spnWinView), return; end
        nw = numel(curWinCounts);
        spnWinView.Limits = [0 max(nw,0)];
        spnWinView.Value = 0; winView = 0;
    end
    function onScrubWindow()           % DISPLAY-ONLY: show one detection window's density to watch a site move
        v = 0; if ~isempty(spnWinView) && isgraphics(spnWinView), v = round(spnWinView.Value); end
        winView = v;
        if v>=1 && v<=numel(curWinCounts) && ~isempty(curWinCounts{v})
            curDdisp = DENS_GAIN*imgaussfilt(curWinCounts{v}, 2);   % same 30*counts display units as the fallback
        else
            curDdisp = curDdispFull;                               % 0 (or out of range) -> whole-movie
        end
        curPkDisp = max(curDdisp(:)); if ~(curPkDisp>0), curPkDisp=1; end
        if ~isempty(densImgH) && isgraphics(densImgH)
            rgbD = pickerDensRGB();
            if ~isempty(rgbD), a = densImgH.AlphaData; densImgH.CData = rgbD; try densImgH.AlphaData = a; catch, end, end
        end
        updateDensScale();
        if ~isempty(msg) && isgraphics(msg)
            if v>=1, msg.Text = sprintf('Viewing window %d/%d (display only — detection uses all windows merged).', v, numel(curWinCounts));
            else,    msg.Text = 'Viewing whole-movie density.'; end
        end
    end
    function onContactChange()         % contact-µm / statistic changed -> re-classify AUTO sites live (positions kept)
        if ~haveMitoDist
            if ~isempty(msg) && isgraphics(msg)
                msg.Text = 'This cell has no per-spot mito distance — contact/stat knob inactive (using the mito image).';
            end
            return;
        end
        v = pts(isvalid(pts)); nre = 0;
        for k = 1:numel(v)
            if strcmp(v(k).Tag,'manual'), continue; end       % keep user-owned flags; only auto sites track the knob
            fl = cs_mito_from_dist(v(k).Position, curLx, curLy, curSmd, contactRadPx(), contactUm(), useFractionStat());
            v(k).UserData = fl; v(k).Color = flagColor(fl); nre = nre + 1;
        end
        refreshList();
        if ~isempty(msg) && isgraphics(msg)
            st = 'median'; if useFractionStat(), st = 'fraction'; end
            msg.Text = sprintf('Re-classified %d auto site(s) at contact %.3g µm (%s).', nre, contactUm(), st);
        end
    end

    function onCSlistPick(e)           % the list says "click a row to remove" -> clicking a site DELETES it
        if isempty(lstCS) || ~isgraphics(lstCS) || inListRemove, return; end
        idx = [];
        if nargin>=1 && ~isempty(e)    % ClickedFcn event: identify the clicked row (works even on a re-click)
            try
                it = e.InteractionInformation.Item;          % clicked item text ('' if the click missed a row)
                if ~isempty(it), idx = find(strcmp(lstCS.Items, char(it)), 1); end
            catch, end
        end
        if isempty(idx), idx = lstCS.ValueIndex; end         % fallback: the current selection
        v = pts(isvalid(pts)); idx = idx(idx>=1 & idx<=numel(v));
        if isempty(idx), return; end
        removeSites(idx);
    end

    function onRemoveSelCS()           % button: remove the currently-highlighted site(s) (same as clicking a row)
        if isempty(lstCS) || ~isgraphics(lstCS), return; end
        idx = lstCS.ValueIndex; v = pts(isvalid(pts));
        idx = idx(idx>=1 & idx<=numel(v));
        if isempty(idx)
            if ~isempty(msg) && isgraphics(msg), msg.Text='Click a site in the list (or right-click a point on the image) to remove it.'; end
            return;
        end
        removeSites(idx);
    end

    function removeSites(idx)          % shared delete path (reentrancy-guarded so refreshList can't re-fire it)
        if inListRemove, return; end
        inListRemove = true;
        v = pts(isvalid(pts));
        idx = idx(idx>=1 & idx<=numel(v));
        try
            if ~isempty(idx), delete(v(idx)); end       % -> ObjectBeingDestroyed -> afterPointGone
            if ~isempty(lastSelH) && isgraphics(lastSelH), delete(lastSelH); lastSelH=gobjects(0); end
            renumberPoints(); refreshList(); fillCellTable();   % explicit, in case the destroy listener is delayed
            harvestCurrentCell();                       % keep cellPicks in sync so the removal persists on switch
            if ~isempty(msg) && isgraphics(msg)
                msg.Text = sprintf('Removed %d contact site(s) — %d left. Click the density in Add mode to place a new one.', ...
                    numel(idx), numel(pts(isvalid(pts))));
            end
        catch ME
            if ~isempty(msg) && isgraphics(msg), msg.Text = ['Remove failed: ' ME.message]; end
        end
        inListRemove = false;
    end

    function onReDetect()             % RESET the auto-detected sites at the current sensitivity (keep manual picks)
        if curCell<1 || curCell>nCells, return; end
        try
            [~,~,~,SFq,~,cand2] = prepCell(curCell, true);   % force fresh detection at the current method/alpha
        catch ME
            if ~isempty(msg) && isgraphics(msg), msg.Text=['Re-detect failed: ' ME.message]; end, return;
        end
        % Clear the previous AUTO-detected sites so changing the sensitivity RESETS rather than
        % accumulates; points you placed/kept by hand (Tag 'manual') survive.
        v = pts(isvalid(pts)); nKept = 0;
        for k = 1:numel(v)
            if strcmp(v(k).Tag,'auto'), delete(v(k)); else, nKept = nKept + 1; end
        end
        % re-seed from the fresh detection, skipping any candidate near a surviving manual pick
        v2 = pts(isvalid(pts)); ex = zeros(numel(v2),2);
        for k = 1:numel(v2), ex(k,:) = v2(k).Position; end
        Rpx = 0.4/max(SFq,eps); nAuto = 0;
        for r = 1:size(cand2,1)
            c = cand2(r,:);
            if isempty(ex) || min(hypot(ex(:,1)-c(1), ex(:,2)-c(2))) > Rpx
                registerPoint(drawpoint(ax,'Position',c), opt.MitoThresh, false);   % auto-classified
                ex = [ex; c]; nAuto = nAuto + 1; %#ok<AGROW>
            end
        end
        if ~isempty(lastSelH) && isgraphics(lastSelH), delete(lastSelH); lastSelH=gobjects(0); end
        harvestCurrentCell();          % sync cellPicks so the cell table's #CS reflects the reset
        refreshList(); fillCellTable();
        if ~isempty(msg) && isgraphics(msg)
            msg.Text = sprintf('Re-detect [%s]: reset to %d auto site(s)%s.', curDetInfo, nAuto, ...
                tern(nKept>0, sprintf(' (kept %d manual)', nKept), ''));
        end
    end

    function registerPoint(p, mThr, fromUser)
        if nargin<3, fromUser=true; end
        if ~isvalid(p), return; end
        % Auto-detected candidates are ALWAYS classified from the mito image; only points the
        % user places honor the mito=auto/YES/no dropdown (so the override doesn't leak onto
        % the next cell's seeded candidates).
        if fromUser, fl = pickFlag(p.Position, mThr); else, fl = mitoAt(p.Position, mThr); end
        try, p.Tag = tern(fromUser,'manual','auto'); catch, end   % so "Re-detect (reset)" clears only auto sites
        registerPointCore(p, fl);
    end

    function registerPointCore(p, fl)
        if ~isvalid(p), return; end
        p.Color = flagColor(fl); p.UserData = fl; p.Deletable = true;
        try p.LabelVisible = 'on'; catch, end   % CS id label (text assigned by renumberPoints)
        try p.MarkerSize = 13; catch, end        % bigger so the auto-detected peak centre is easy to see on the density
        % Markers are non-interactive so they can never be accidentally DRAGGED. But
        % InteractionsAllowed='none' does NOT make them click-through — the marker still
        % hit-tests and would swallow a left-click. So forward the marker's OWN click
        % (ROIClicked, which fires even when non-interactive) to addFromClick.
        try p.InteractionsAllowed = 'none'; catch, end
        cm = uicontextmenu(waitFig);
        uimenu(cm,'Text','Toggle mito','MenuSelectedFcn',@(s,e) toggleMito(p));
        uimenu(cm,'Text','Delete',     'MenuSelectedFcn',@(s,e) delete(p));
        p.ContextMenu = cm;
        try addlistener(p,'ROIClicked',@(s,e) fwdPtClick(s,e)); catch, end
        addlistener(p,'ObjectBeingDestroyed',@(~,~) afterPointGone(cm));
        pts(end+1) = p; %#ok<AGROW>
        renumberPoints();                                % contiguous 1..N labels; idc = live count
        highlightPoint(p, idc, fl);                      % ring it so close points stay distinguishable
        refreshList();
    end

    function fwdPtClick(p, e)
        % a click landed ON a CS marker -> route it to the current cell's click handler with
        % the marker's OWN position + the EVENT's click type (both authoritative on this path).
        if isempty(onPtClick), return; end
        st=''; try st = e.SelectionType; catch, end
        xy=[]; try xy = p.Position; catch, end
        try onPtClick(xy, st); catch, end
    end

    function renumberPoints()
        % Keep the CS labels/count contiguous 1..N in placement order. Called after every add
        % AND every removal (Undo / right-click Delete), so undo actually rolls the count back.
        pts = pts(isvalid(pts));            % drop dead handles
        idc = numel(pts);
        for q = 1:numel(pts)
            try pts(q).Label = num2str(q); catch, end
        end
    end

    function fl = pickFlag(xy, mThr)
        m = ''; if ~isempty(ddMito) && isgraphics(ddMito), m = ddMito.Value; end
        switch m
            case 'mito=YES', fl = 1;
            case 'mito=no',  fl = 2;
            otherwise,       fl = mitoAt(xy, mThr);      % auto: sample the mito overlay
        end
    end

    function highlightPoint(p, id, fl)
        if ~isempty(lastSelH) && isgraphics(lastSelH), delete(lastSelH); end
        lastSelH = gobjects(0);
        if ~isvalid(p) || ~isgraphics(ax), return; end
        xy = p.Position;
        lastSelH = plot(ax, xy(1), xy(2), 'o','MarkerSize',22,'LineWidth',2.5, ...
            'MarkerEdgeColor',[1 1 1],'HitTest','off');      % white ring = active CS
        if ~isempty(msg) && isgraphics(msg)
            [n, warn] = csLocCount(xy);   % localizations within ~0.6 um — a sparse-cell reality check
            msg.Text = sprintf('CS %d (%s) — %d localizations within 0.6 µm%s.  (right-click a point to change/delete; Undo removes the last.)', ...
                id, tern(fl==1,'MITO','non-mito'), n, warn);
        end
    end

    function [n, warn] = csLocCount(xy)
        % how many localizations sit within ~0.6 um of this CS — the density is normalized
        % per-cell, so a bright peak in a sparse cell can be just a few points.
        n = 0; warn = '';
        if isempty(curLx) || numel(xy)<2, return; end
        R = 0.6 / max(SF,eps);                                  % 0.6 um in density px
        n = nnz(hypot(curLx - xy(1), curLy - xy(2)) <= R);
        if n < 10, warn = '  ⚠ LOW — may be a sparse-cell artifact'; end
    end

    function undoLastPoint()
        v = pts(isvalid(pts));
        if isempty(v)
            if ~isempty(msg) && isgraphics(msg), msg.Text='Nothing to undo.'; end
            return;
        end
        delete(v(end));                                  % ObjectBeingDestroyed -> afterPointGone -> refreshList
        if ~isempty(lastSelH) && isgraphics(lastSelH), delete(lastSelH); lastSelH=gobjects(0); end
        if ~isempty(msg) && isgraphics(msg), msg.Text='Removed the last contact site.'; end
    end

    function onDisplayTune()
        % density opacity (uniform alpha on the density image) + mito opacity/contrast
        if ~isempty(densImgH) && isgraphics(densImgH) && ~isempty(sldDensA) && isgraphics(sldDensA)
            try densImgH.AlphaData = sldDensA.Value; catch, end
        end
        drawMitoOverlay();
    end

    function afterPointGone(cm)
        if isgraphics(cm), delete(cm); end   % clean up the point's context menu
        if ~isempty(lastSelH) && isgraphics(lastSelH), delete(lastSelH); lastSelH=gobjects(0); end
        renumberPoints();                    % roll the count back + re-label 1..N after a deletion
        refreshList();                       % keep the running list in sync
    end

    function fl = mitoAt(xy, mThr)
        if haveMitoDist                                  % per-spot signed mito distance (per frame) — moving-mito aware
            fl = cs_mito_from_dist(xy, curLx, curLy, curSmd, contactRadPx(), contactUm(), useFractionStat());
        else                                             % fall back to the mito image when a cell has no per-spot distance
            fl = mitoAtXY(xy, mThr, mitoN, W, H);
        end
    end

    function toggleMito(p)
        if ~isvalid(p), return; end
        fl = p.UserData; if fl==1, fl=2; else, fl=1; end
        p.UserData = fl; p.Color = flagColor(fl);
        try, p.Tag = 'manual'; catch, end   % a hand-toggled flag is user-owned -> survives the contact-µm/stat knob
        highlightPoint(p, str2double(p.Label), fl);   % ring the one you just changed
    end

    function fl = flagOf(p)
        fl = p.UserData; if isempty(fl) || ~ismember(fl,[1 2]), fl = 2; end
    end

    function finishUI()
        if ~isempty(inParent) && isgraphics(inParent)
            delete(allchild(inParent));
            g = uigridlayout(inParent,[1 1],'Padding',[16 16 16 16]);
            done = sprintf('Contact-site picking complete.\n\n%s\n\nRunning mapper…', strjoin(csLog, newline));
            uilabel(g,'Text',done,'WordWrap','on','FontSize',12);
        end
    end
end

% ============================ local functions ============================
function [cand, Dthr, pStrong, info] = detect_candidates(Dens, rawCounts, mask, MinArea, doAuto, W, H, method, alpha, M, sig, lambdaMap, wER, wmap)
% Statistically significant localization-density peaks (candidate contact sites).
% Dens = localizations binned to the grid and Gaussian-smoothed (sigma ~8 px ~0.24 um).
% A peak is a "site" only if its density exceeds what the NULL model produces by chance;
% the SAME sigma smoothing is applied to the null as to Dens, so the units match.
%   UNIFORM (structure-blind) nulls -- complete spatial randomness at one density everywhere:
%     'montecarlo': random labelling. Scatter the SAME N locs uniformly over the mask M times,
%                   smooth, take each run's MAX; Dthr = (1-alpha) quantile of the maxima ->
%                   family-wise P[>=1 false site] ~ alpha. (SR-Tesseler / ClusterViSu approach.)
%     'poisson'   : analytic twin. Smoothed density ~ Normal(lambda, lambda/(4 pi sig^2)),
%                   lambda = N/area; Bonferroni over ~area/(4 pi sig^2) resolution elements.
%   STRUCTURE-AWARE (inhomogeneous) nulls -- a per-pixel baseline lambdaMap(x) (built by the
%   caller) drives a SPATIALLY-VARYING analytic threshold Dthr(x) = mu(x)+z*sd(x):
%     'erweight'  : lambdaMap follows the ER MIP (w=0 uniform-on-ER .. w=1 full ER conditioning).
%     'localbg'   : lambdaMap = a large-scale smooth of VAPB itself (top-hat; no external image).
%   'relative'    : legacy imextendedmax prominence at alpha*max(Dens) (alpha carries the frac).
% Returns centroids, a reference threshold, the strongest site's null p-value, and a title string.
cand = zeros(0,2); Dthr = Inf; pStrong = NaN; info = ''; emar = 3;
if ~doAuto || ~any(Dens(:)>0), return; end
if nargin<11 || isempty(sig), sig = 8; end
if nargin<12, lambdaMap = []; end
if nargin<13, wER = 0; end
if nargin<14, wmap = []; end
if isempty(mask), mask = true(size(Dens)); end
pfun = @(pk) NaN; scoreImg = Dens;   % statistic whose per-region max drives the p-value
switch lower(method)
    case 'relative'
        frac = min(max(alpha,0.02),0.6); Dthr = frac*max(Dens(:));
        bw = imextendedmax(Dens, Dthr) & mask;
        info = sprintf('relative prominence %.2f', frac);
    case 'poisson'
        N = sum(rawCounts(:)); A = max(nnz(mask),1); lam = N/A;
        sumw2 = 1/(4*pi*sig^2); sdS = sqrt(max(lam,eps)*sumw2); neff = max(A*sumw2,1);
        aFW = min(max(alpha/neff, realmin), 0.5);
        z = -sqrt(2)*erfcinv(2*(1-aFW));                 % norminv(1-aFW) without Stats Toolbox
        Dthr = lam + z*sdS; bw = (Dens > Dthr) & mask;
        pfun = @(pk) min(1, neff*0.5*erfc((pk-lam)/max(sdS,eps)/sqrt(2)));   % Bonferroni family-wise tail
        info = sprintf('Poisson CSR \\alpha=%.3g (%d res.elem.)', alpha, round(neff));
    case {'erweight','localbg'}
        % Compare like-for-like: smooth ONLY the on-support counts, so the data image and the
        % baseline mu are built from the same mass -> no off-support smoothing leak biasing the
        % ER-support rim (for localbg mask=footprint, so densOn == Dens).
        densOn = imgaussfilt(rawCounts .* mask, sig);
        [bw, DthrMap, zmap, neff] = analytic_inhom(densOn, lambdaMap, mask, sig, alpha);
        scoreImg = zmap;                                 % score = standardized excess (densOn-mu)/sd
        pfun = @(zz) min(1, neff*0.5*erfc(zz/sqrt(2)));
        Dthr = median(DthrMap(mask));                    % a representative value (threshold is spatially varying)
        if strcmpi(method,'erweight')
            info = sprintf('ER-weighted CSR w=%.2g \\alpha=%.3g', wER, alpha);
        else
            info = sprintf('local-bg CSR \\alpha=%.3g', alpha);
        end
    case 'ermc'  % ER Monte-Carlo: random labelling with the null redistributed onto ER-supported pixels
        [Dthr, nullMax] = cs_mc_threshold(rawCounts, mask, sig, alpha, M, wmap);
        bw = (Dens > Dthr) & mask;
        pfun = @(pk) (1 + sum(nullMax>=pk))/(numel(nullMax)+1);   % family-wise empirical p
        info = sprintf('ER Monte-Carlo CSR \\alpha=%.3g (%d sims)', alpha, M);
    otherwise    % monte-carlo random labelling (uniform)
        [Dthr, nullMax] = cs_mc_threshold(rawCounts, mask, sig, alpha, M);
        bw = (Dens > Dthr) & mask;
        pfun = @(pk) (1 + sum(nullMax>=pk))/(numel(nullMax)+1);   % family-wise empirical p
        info = sprintf('Monte-Carlo CSR \\alpha=%.3g (%d sims)', alpha, M);
end
rp = regionprops(bw, scoreImg, 'Centroid','Area','MaxIntensity');
best = -inf;
for r = 1:numel(rp)
    c = rp(r).Centroid;      % [x y]
    if rp(r).Area>=MinArea && c(1)>emar && c(1)<W-emar && c(2)>emar && c(2)<H-emar
        cand(end+1,:) = c; %#ok<AGROW>
        if rp(r).MaxIntensity > best, best = rp(r).MaxIntensity; pStrong = pfun(best); end
    end
end
end

% -------------------------------------------------------------------------
function [bw, DthrMap, zmap, neff] = analytic_inhom(Dens, lambdaMap, mask, sig, alpha)
% Inhomogeneous CSR: given a per-pixel expected-count baseline lambdaMap (already scaled so it
% sums to N over the support), the smoothed density at x is ~ Normal(mu(x), var(x)) with
%   mu(x)  = (G_sig * lambda)(x)              expected smoothed density
%   var(x) = (G_sig^2 * lambda)(x) = imgaussfilt(lambda, sig/sqrt2)/(4 pi sig^2)   (G_sig^2 is a
%            narrower Gaussian of area 1/(4 pi sig^2)). Threshold Dthr(x) = mu + z*sd, Bonferroni
%   z = norminv(1 - alpha/neff),  neff = support area / (4 pi sig^2) resolution elements.
if isempty(lambdaMap) || ~any(lambdaMap(:)>0)
    bw = false(size(Dens)); DthrMap = inf(size(Dens)); zmap = zeros(size(Dens)); neff = 1; return;
end
mu   = imgaussfilt(lambdaMap, sig);
vv   = max(imgaussfilt(lambdaMap, sig/sqrt(2)) / (4*pi*sig^2), 0);
neff = max(nnz(mask)/(4*pi*sig^2), 1);
aFW  = min(max(alpha/neff, realmin), 0.5);
z    = -sqrt(2)*erfcinv(2*(1-aFW));
sd   = sqrt(max(vv, eps));
DthrMap = mu + z*sd;
zmap = (Dens - mu) ./ sd;
bw   = (Dens > DthrMap) & mask;
end

% -------------------------------------------------------------------------
function fl = mitoAtXY(xy, mThr, mN, W, H)
% mito flag (1) if the (resized) mito image at this pixel >= threshold, else 2.
fl = 2;
if ~isempty(mN)
    c = round(xy); c(1)=min(max(c(1),1),W); c(2)=min(max(c(2),1),H);
    if mN(c(2),c(1)) >= mThr, fl = 1; end
end
end

% -------------------------------------------------------------------------
function [P, flags, haveMito] = read_cssites(fname)
% Parse a previously-written <base>_CSsites.txt back into P (Nx2 [X Y]) + flags
% (Nx1 1/2). col2=X col3=Y; col7=flag when the 8-column (mito) format was written.
P = zeros(0,2); flags = zeros(0,1); haveMito = false;
try
    M = readmatrix(fname,'NumHeaderLines',1,'Delimiter','\t');
    if isempty(M) || size(M,2)<3, return; end
    P = [M(:,2) M(:,3)];
    if size(M,2)>=7
        haveMito = true; flags = M(:,7); flags(~ismember(flags,[1 2])) = 2;
    else
        flags = 2*ones(size(M,1),1);
    end
    ok = all(isfinite(P),2);          % drop any NaN rows a stray trailing line could add
    P = P(ok,:); flags = flags(ok);
catch
    P = zeros(0,2); flags = zeros(0,1); haveMito = false;
end
end

% -------------------------------------------------------------------------
function mitoN = local_mito(analysisDir, base, cfg, H, W, mitoDir, mitoPat, mitoStrip)
% Best-effort mito image (max-projected, normalized, resized to the density frame).
% Resolution order (this cell only — a wrong cell's mito would mis-flag):
%   1) the app-supplied mito folder + {prefix} pattern (Experiment tab) — e.g. Project/mito
%      with '{prefix}_mito_mip.tif'. This is what makes auto-load work without a Mito/ folder.
%   2) fallback: <analysisDir>/Mito with a '<base>*.tif' match.
mitoN = [];
if nargin<6, mitoDir=''; end
if nargin<7 || isempty(mitoPat), mitoPat='{prefix}_mito_mip.tif'; end
if nargin<8, mitoStrip='_spt\d+'; end
fp = '';
% 1) app-provided folder + {prefix}-templated name (same logic as the app's qcCellMitoPath)
if ~isempty(mitoDir) && isfolder(mitoDir)
    if isempty(mitoStrip), prefix=base; else, prefix=regexprep(base,[mitoStrip '$'],'','ignorecase'); end
    try
        f = dir(fullfile(mitoDir, strrep(mitoPat,'{prefix}',prefix))); f = f(~[f.isdir]);
        if ~isempty(f), fp = fullfile(mitoDir,f(1).name); end
    catch, end
end
% 2) fallback: the pipeline's own Mito/ subfolder under the analysis dir
if isempty(fp)
    md = fullfile(analysisDir,cfg.dir.Mito);
    if isfolder(md)
        Lm = dir(fullfile(md,[base '*.tif']));
        if ~isempty(Lm), fp = fullfile(md,Lm(1).name); end
    end
end
if isempty(fp), return; end
try
    info = imfinfo(fp); n = numel(info);
    im = imread(fp,1);
    for k = 2:n, im = max(im, imread(fp,k)); end        % running MIP
    if size(im,3)==3, g = im2double(rgb2gray(im)); else, g = im2double(im); end
    if size(g,1)~=H || size(g,2)~=W, g = imresize(g,[H W]); end
    mx = max(g(:)); if mx>0, mitoN = g/mx; else, mitoN = g; end
catch
    mitoN = [];
end
end

% -------------------------------------------------------------------------
function erN = local_er(analysisDir, base, cfg, H, W, erDir, erPat, erStrip)
% Best-effort ER image (max-projected, normalized 0..1, resized to the density frame) for the
% ER-weighted detection null. Same resolution order as local_mito: app ER folder + {prefix},
% then <analysisDir>/ER. Returns [] when no ER MIP is available (caller falls back to local-bg).
erN = [];
if nargin<6, erDir=''; end
if nargin<7 || isempty(erPat), erPat='{prefix}_er_mip.tif'; end
if nargin<8, erStrip='_spt\d+'; end
fp = '';
if ~isempty(erDir) && isfolder(erDir)
    if isempty(erStrip), prefix=base; else, prefix=regexprep(base,[erStrip '$'],'','ignorecase'); end
    try
        f = dir(fullfile(erDir, strrep(erPat,'{prefix}',prefix))); f = f(~[f.isdir]);
        if ~isempty(f), fp = fullfile(erDir,f(1).name); end
    catch, end
end
if isempty(fp) && isfield(cfg,'dir') && isfield(cfg.dir,'ER')
    ed = fullfile(analysisDir,cfg.dir.ER);
    if isfolder(ed)
        Le = dir(fullfile(ed,[base '*.tif']));
        if ~isempty(Le), fp = fullfile(ed,Le(1).name); end
    end
end
if isempty(fp), return; end
try
    info = imfinfo(fp); n = numel(info);
    im = imread(fp,1);
    for k = 2:n, im = max(im, imread(fp,k)); end        % running MIP
    if size(im,3)==3, g = im2double(rgb2gray(im)); else, g = im2double(im); end
    if size(g,1)~=H || size(g,2)~=W, g = imresize(g,[H W]); end
    mx = max(g(:)); if mx>0, erN = g/mx; else, erN = g; end
catch
    erN = [];
end
end

% -------------------------------------------------------------------------
function c = flagColor(fl)
if fl==1, c = [1 0 1]; else, c = [0 1 1]; end   % magenta = mito, cyan = other
end

% -------------------------------------------------------------------------
function y = tern(c,a,b), if c, y=a; else, y=b; end, end

% -------------------------------------------------------------------------
function close_id_windows()
% Self-contained teardown for onCleanup: close standalone cs_identify windows by
% tag (an embedded app panel is untagged and left untouched).
h = findall(groot,'Type','figure','Tag','cs_identify_window');
if ~isempty(h), close(h); end
end

% -------------------------------------------------------------------------
function local_write(fname, P, flags, haveMito)
fid = fopen(fname,'w');
if fid < 0, error('cs_identify:write','Cannot open %s for writing.',fname); end
c = onCleanup(@() fclose(fid));
if haveMito
    % 8 columns; col4=X col5=Y col7=flag. Bypasses the mapper's size==6 fallback,
    % so col7 MUST be a valid 1/2 on every row.
    fprintf(fid,' \tX\tY\tXM\tYM\tSlice\tCounter\tCount\n');
    for j = 1:size(P,1)
        fl = flags(j); if ~ismember(fl,[1 2]), fl = 2; end
        fprintf(fid,'%d\t%.3f\t%.3f\t%.3f\t%.3f\t%d\t%d\t%d\n', j, P(j,1),P(j,2),P(j,1),P(j,2),1,fl,0);
    end
else
    % 6 columns -> ContactSiteMapper fills cols 7:8 with 2 (all MitoFlag=false).
    fprintf(fid,' \tX\tY\tXM\tYM\tSlice\n');
    for j = 1:size(P,1)
        fprintf(fid,'%d\t%.3f\t%.3f\t%.3f\t%.3f\t%d\n', j, P(j,1),P(j,2),P(j,1),P(j,2),1);
    end
end
end
