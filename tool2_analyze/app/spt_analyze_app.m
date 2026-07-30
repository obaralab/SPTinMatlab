function fig = spt_analyze_app(mode)
%SPT_ANALYZE_APP  The ContactSites pipeline as a clean, tab-by-tab app — split into two launchers.
%
% Single implementation, three-tool workflow. A MODE argument selects which tabs are shown so the
% same codebase backs two focused launchers (Tool 1 "Track" = spt_app.m is a separate app):
%
%   spt_analyze_app('curate')  -> Tool 2 "Curate & Build": Import & Curate -> Build & QC -> Experiment.
%                                 Curate the tracked cells and build the TrackStruct.mat the next tool reads.
%   spt_analyze_app('analyze') -> Tool 3 "Analyze" (DEFAULT): Contact sites -> Refine -> Sites -> Dwell
%                                 -> Experiment -> Compare. Starts from a built TrackStruct.mat.
%   spt_analyze_app('full')    -> every tab in one window (the old combined app; handy for a single cell).
%
% The Experiment tab (spt_experiment_panel) is SHARED across every mode — the multi-folder /
% condition manifest that ties the tools together. Curate & Build is usually launched via the thin
% wrapper spt_curate_app.m.
%
% Reuses the drivers + ContactSites_robust suite as the engine (build_trackstruct, cs_identify,
% mappers, refiners). The Import & Curate tab EMBEDS track_viewer.m (local-density + displacement-
% variance metrics, jump-gate mis-link filter, live percentile histograms, per-frame mito + ER
% overlay). Input is a Tool 1 project folder: <project>/tracks/ (curated _tracks_filtered.xml +
% _spots_filtered.csv) plus <project>/er_seg/ and <project>/mito_seg/. Calibration (pixel size, FOV,
% dt, localization precision) is per-dataset and written to cs_calib.mat so cs_config drives downstream.
%
%   run:  addpath('<repo>/tool2_analyze/app'); spt_analyze_app('analyze')   % or spt_curate_app

% ------- mode: which tabs this launcher shows (see help above) -------
if nargin<1 || isempty(mode), mode = 'analyze'; end
mode = validatestring(lower(char(mode)), {'curate','analyze','full'});
showCurate  = any(strcmp(mode,{'curate','full'}));    % Import & Curate + Build & QC
showAnalyze = any(strcmp(mode,{'analyze','full'}));   % Contact sites + Refine + Sites + Dwell + Compare
switch mode
    case 'curate',  toolName = 'SPT Curate & Build — Tool 2 of 3';
    case 'analyze', toolName = 'SPT Analyze — Tool 3 of 3';
    otherwise,      toolName = 'SPT Curate + Analyze (full)';
end

% ============================ shared state ============================
projectDir = '';                                  % Tool 1 project folder
tracksDir  = '';                                  % <project>/tracks
matched    = [];                                  % spt_match output: cell base -> er/mito seg (for the overlay)
PXUM = 0.10785; FOVUM = 27.61; DTS = 0.020064; PRECNM = 30;   % per-dataset calibration (localization precision, nm)

% path setup: drivers (build_trackstruct, TrackImporter_direct, cs_*), the ContactSites suite, and
% Tool 1's tool1_track (its file matcher handles the _VAPB / _TA_BC channel tokens for the overlay).
here_ = fileparts(mfilename('fullpath'));            % .../tool2_analyze/app
addpath(fullfile(fileparts(here_),'drivers'));
for c_ = {fullfile(fileparts(here_),'ContactSites_robust'), fullfile(fileparts(here_),'ContactSites_original')}
    if isfolder(c_{1}), addpath(genpath(c_{1})); break; end
end
t1_ = fullfile(fileparts(fileparts(here_)),'tool1_track');
if isfolder(t1_), addpath(t1_); end
eProj=[]; eCalPx=[]; eCalFov=[]; eCalDt=[]; eCalPrec=[]; lblProj=[];   % top-bar handles
tg=[]; tImport=[]; tBuild=[]; tCS=[];                                 % tabs
tRefine=[]; tSites=[]; tDwell=[]; tExpt=[]; tCompare=[];              % downstream tabs (Refine/Sites/Dwell/Experiment/Compare)
ddTimeUnit=[]; lblBuild=[]; tblBuild=[]; txtBuild=[];                 % Build handles
buildTracks=[]; ddQCcell=[]; axLen=[]; axMSD=[]; axCov=[]; axDist=[]; axDdist=[]; lblQCm=[]; eMsdFrac=[];   % QC handles
tsName=''; eTsName=[]; ddBuild=[];   % the ACTIVE TrackStruct basename in analysis/ (named builds)
axDloc=[]; axDtrace=[];   % stepwise-diffusion QC: pooled per-localization D, and D(t) for the clicked track
axCSD=[]; csdHi=[];       % cumulative-displacement panel + the highlight of the clicked track
ddHi=[]; dlHi=[];         % where the CLICKED track sits in the two pooled D histograms
eConfineD=[]; diffConfineD=0.15;   % per-localization diffusion: confinement threshold (µm²/s) computed at Build
ddConfMode=[]; diffConfMode='segment';    % 'segment' | 'drop' | 'relative' | 'absolute'
eMinSeg=[];    diffMinSeg=3;              % segment mode: shortest segment the splitter may produce
ePenalty=[];   diffPenalty=1.5;           % segment mode: LR must exceed penalty*log(n) to split
eBaseWin=[];   diffBaseWin=10;             % drop mode: preceding localizations forming the baseline
eConfFrac=[];  diffConfFrac=0.30;         % relative mode: confined when D <= this x the track's median
eMinRun=[];    diffMinRun=5;              % a confined run must last this many localizations to count
ddFitMode=[]; axSweep=[];   % MSD fit-window mode (fixed % / adaptive R²) + the per-track D-vs-fit-window sweep
qcTracks={}; qcSelIdx=0; qcHi=[]; playerCtl=[];   % click-to-inspect: flat track list, selection, highlight, embedded player
densCache=struct('base',{},'occ',{});   % per-cell whole-movie occupancy cache (used by ensureMips + saveDensityFiles)
pnCS=[]; btnPickCS=[]; chkCSsaveDens=[]; eCScontact=[]; lblCS=[];   % Tab 3 Contact-sites handles
% ---- downstream analysis results (in-session), read from / written to analysis/ ----
CSW=[]; DD=[];                                              % mapper (site x window) + dwell results
siteDensCache=struct('key',{},'dens',{},'raw',{});                  % per (cell,window,src) window-density cache for the inspector
% Refine tab handles (interactive footprint editing -> analysis/CS_footprints.mat)
axRef=[]; lstRefSites=[]; eRefFrac=[]; eRefMaxR=[]; ddRefWin=[]; lblRef=[]; lblRefSrc=[]; lblRefInfo=[];
axRad=[]; chkRefLocs=[]; ddRefScale=[]; sldRefContrast=[]; btnRefDelete=[]; refCbar=[]; refLockedSrc='all'; sldRefSmooth=[];
refNullCache=struct('key',{},'nullMax',{},'pmap',{}); refFoot=[]; refSelIdx=0; refRowMap=[];
refErCache=struct('key',{},'erGrid',{});   % per-(cell,grid) ER support mask resampled to the density grid (radial-null area)
% Sites tab handles
eMaxR=[]; eFrac=[]; ddWinFilt=[]; tblSites=[]; axSite=[]; lstMembers=[]; lblSites=[]; lblSitesSrc=[]; siteRowMap=[]; eMinPctIn=[];
sitePlayer=[]; siteSelIdx=0; btnPlaySite=[]; btnPlayOne=[]; btnDelTrack=[]; chkUseRefined=[]; siteMemberSel=0; stepRes=[];
pendExcl=struct('file',{},'csID',{},'window',{},'pickPx',{},'trackCol',{});   % track removals marked but not yet applied
% Dwell tab handles
axDwHist=[]; axKout=[]; tblDwell=[]; axDwTrace=[]; axDwDens=[]; lblDwell=[]; dwellRowMap=[];
btnDwPlay=[]; sldDwFrame=[]; chkDwEr=[]; chkDwMito=[]; eDwFps=[]; lblDwAnim=[]; dwellAnim=[]; ddDwBg=[]; eDwContrast=[];
% Compare tab handles
% Experiment tab — the shared experiment/condition panel (spt_experiment_panel)
exptCtl=[];
% Compare tab handles (+ data source: current project vs experiment)
ddCmpGroup=[]; ddCmpMetric=[]; ddCmpData=[]; tblCmp=[]; axCmpScatter=[]; axCmpCdf=[]; lblCmp=[]; cmpCSW=[]; cmpDD=[];

% Clean up any orphaned Dwell-animation timer from a previous session (a timer left running after an
% improper close fires its nested TimerFcn into a dead workspace -> "Unable to find function dwellTick").
try, tOrph = timerfindall('Tag','sptAnalyzeDwell'); if ~isempty(tOrph), stop(tOrph); delete(tOrph); end, catch, end

% ============================ window =================================
fig = uifigure('Name',toolName, 'Position',[60 60 1320 900]);
fig.CloseRequestFcn = @(s,e) onAppClose();   % deletes tabs -> track_viewer's parent.DeleteFcn stops its timer
% headless test hooks (spt_named_build_smoke); the UI itself never reads these. These must be
% NESTED functions — an anonymous @() tsName would capture the value at construction time and
% always report the empty initial state.
fig.UserData = struct('activeTs',@activeTsNow, 'tracks',@tracksNow, 'loadTracks',@onLoadTracks);
gl = uigridlayout(fig,[2 1],'RowHeight',{34,'1x'},'Padding',[8 8 8 8],'RowSpacing',6);

top = uigridlayout(gl,[1 16],'ColumnWidth', ...
    {150,'1x',60, 40,132, 74,60, 60,54, 54,54, 84,54, 52, 60}, ...
    'Padding',[0 0 0 0],'ColumnSpacing',6);
uilabel(top,'Text',tern(showCurate&&~showAnalyze,'Curate & Build — Tool 2',tern(showAnalyze&&~showCurate,'Analyze — Tool 3','Curate + Analyze')),'FontWeight','bold','FontColor',[0.25 0.25 0.3]);
eProj = uieditfield(top,'text','Placeholder','Tool 1 project folder (tracks/, er_seg/, mito_seg/)', ...
    'ValueChangedFcn',@(s,e) onProjEdit());
uibutton(top,'Text','Pick…','FontWeight','bold','ButtonPushedFcn',@(s,e) onPickProject());
% Which BUILD this project is working from. Tool 2 names builds; Tool 3 needs to say which one it
% is analysing rather than only inferring it, so the choice is explicit and visible in both modes.
uilabel(top,'Text','Build','HorizontalAlignment','right');
ddBuild = uidropdown(top,'Items',{'(none)'},'ItemsData',{''},'Value','', ...
    'Tooltip',['The TrackStruct build in force for this project (analysis/<name>.mat). Tool 2 writes ' ...
    'named builds; picking one here makes it active, so Tool 3 — and a separately launched Analyze ' ...
    'tool — analyse exactly this file.'], ...
    'ValueChangedFcn',@(s,e) onPickBuild());
uilabel(top,'Text','Pixel µm/px','HorizontalAlignment','right');
eCalPx = uieditfield(top,'numeric','Value',PXUM,'ValueDisplayFormat','%.5g','Limits',[1e-4 10], ...
    'Tooltip','Camera pixel size (µm/px) for THIS dataset.','ValueChangedFcn',@(s,e) onCal());
uilabel(top,'Text','FOV µm','HorizontalAlignment','right');
eCalFov = uieditfield(top,'numeric','Value',FOVUM,'ValueDisplayFormat','%.5g','Limits',[0.1 1e4], ...
    'Tooltip','Field of view (µm) — drives the density-map scale factor.','ValueChangedFcn',@(s,e) onCal());
uilabel(top,'Text','dt s','HorizontalAlignment','right');
eCalDt = uieditfield(top,'numeric','Value',DTS,'ValueDisplayFormat','%.5g','Limits',[1e-6 100], ...
    'ValueChangedFcn',@(s,e) onCal());
uilabel(top,'Text','Loc prec nm','HorizontalAlignment','right');
eCalPrec = uieditfield(top,'numeric','Value',PRECNM,'ValueDisplayFormat','%.4g','Limits',[1 500], ...
    'Tooltip','Localization precision / density-bin size (nm) for THIS dataset (per-camera — not the advisor''s 30 nm).', ...
    'ValueChangedFcn',@(s,e) onCal());
uibutton(top,'Text','Auto','Tooltip','Read dt (and pixel size where present) from a tracks XML in the project.', ...
    'ButtonPushedFcn',@(s,e) onCalAuto());
uibutton(top,'Text','❓ Help','Tooltip','Open the SPTinMatlab pipeline help guide in your browser.', ...
    'ButtonPushedFcn',@(s,e) onHelp());

% Tabs are created + built conditionally per mode (numbering is dynamic so each launcher reads 1..N).
% The Experiment tab is shared by every mode; handles for tabs this mode omits stay [] (guarded below).
tg = uitabgroup(gl); tg.Layout.Row = 2;
nTab = 0;
% Experiment FIRST, in every mode and in Tool 1 too: the cell inventory and the condition
% assignment are the setup step, and keeping it at tab 1 everywhere means the manifest is always
% in the same place whichever tool you opened.
nTab=nTab+1; tExpt = uitab(tg,'Title',sprintf('%d · Experiment',nTab));   % shared across all modes
if showCurate
    nTab=nTab+1; tImport = uitab(tg,'Title',sprintf('%d · Import & Curate',nTab));
    nTab=nTab+1; tBuild  = uitab(tg,'Title',sprintf('%d · Build & QC',nTab));
end
if showAnalyze
    nTab=nTab+1; tCS     = uitab(tg,'Title',sprintf('%d · Contact sites',nTab));
    nTab=nTab+1; tRefine = uitab(tg,'Title',sprintf('%d · Refine',nTab));
    nTab=nTab+1; tSites  = uitab(tg,'Title',sprintf('%d · Sites',nTab));
    nTab=nTab+1; tDwell  = uitab(tg,'Title',sprintf('%d · Dwell',nTab));
    nTab=nTab+1; tCompare = uitab(tg,'Title',sprintf('%d · Compare',nTab));
end

if showCurate
    placeholder(tImport, 'Pick a Tool 1 project folder above — the track curation tool loads here.');
    buildBuildTab(tBuild);
end
if showAnalyze
    buildContactTab(tCS);
    buildRefineTab(tRefine);
    buildSitesTab(tSites);
    buildDwellTab(tDwell);
end
buildExperimentTab(tExpt);   % shared
if showAnalyze
    buildCompareTab(tCompare);
end

% ======================= nested functions =======================
    function onAppClose()
        try, if ~isempty(playerCtl)  && isstruct(playerCtl),  playerCtl.stop();  end, catch, end   % stop the embedded QC player timer
        try, if ~isempty(sitePlayer) && isstruct(sitePlayer), sitePlayer.stop(); end, catch, end   % stop the Sites-tab player timer
        try, dwellStopTimer(); catch, end                                                          % stop the Dwell animation timer
        delete(fig);
    end

    function onPickProject()
        start = pwd; if ~isempty(projectDir) && isfolder(projectDir), start = projectDir; end
        d = uigetdir(start, 'Pick the Tool 1 project folder (contains tracks/, er_seg/, mito_seg/)');
        if isequal(d,0), return; end
        eProj.Value = d; setProject(d);
    end

    function onProjEdit()
        d = strtrim(eProj.Value);
        if ~isempty(d) && isfolder(d), setProject(d); end
    end

    function onHelp()
        % open the pipeline help guide (SPTinMatlab/docs/help.html) in the system browser
        d = fullfile(fileparts(fileparts(here_)),'docs','help.html');   % here_ = .../tool2_analyze/app
        if ~isfile(d), return; end
        try, web(d,'-browser'); catch, try, web(d); catch, end, end
    end

    function setProject(d)
        projectDir = d;
        tracksDir = firstExisting({fullfile(d,'tracks'), d});   % tracks/ subfolder, else the folder itself
        matched = [];                                            % pair spt <-> er_seg <-> mito_seg for the overlay
        buildTracks = [];                                        % drop the previous project's tracks so the new one is reloaded
        tsName = activeTsName(fullfile(d,'analysis'));            % ...and its ACTIVE BUILD NAME: carrying
        if ~isempty(eTsName) && isgraphics(eTsName)               % Day1_KO.mat into the next project would
            [~,stem] = fileparts(tsName); eTsName.Value = stem;   % open the wrong build, or none at all
        end
        densCache = struct('base',{},'occ',{});                  % occupancy cache is per-project
        resetDownstream();                                       % clear Refine/Sites/Dwell/Compare state + caches (prevents cross-project leakage)
        if ~isempty(ddQCcell)   && isgraphics(ddQCcell),   ddQCcell.Items   = {'(build first)'}; ddQCcell.Value   = '(build first)'; end
        if ~isempty(tblBuild)   && isgraphics(tblBuild),   tblBuild.Data = {}; end
        if exist('spt_match','file')==2
            try, matched = spt_match(fullfile(d,'spt'), fullfile(d,'er_seg'), fullfile(d,'mito_seg'), '_VAPB'); catch, matched = []; end
        end
        onCalAuto();          % try to read dt from a tracks XML
        embedImportCurate();
        % The manifest lives WITH the project (<project>/experiment_manifest.mat), so whichever tool
        % opens this folder sees the same cells and conditions without an explicit Load/Save.
        try, if ~isempty(exptCtl) && isstruct(exptCtl) && isfield(exptCtl,'setAutoPath')
                exptCtl.setAutoPath(fullfile(d,'experiment_manifest.mat'));
             end, catch, end
        try, if ~isempty(exptCtl) && isstruct(exptCtl) && isfolder(fullfile(d,'analysis')), exptCtl.addFolder(fullfile(d,'analysis')); end, catch, end   % keep the experiment in sync
        refreshBuildList();
    end

    % ---------------- Tab 2: Build & QC (build + interactive per-track inspection) ----------------
    function buildBuildTab(parent)
        g = uigridlayout(parent,[4 1],'RowHeight',{30,28,'1x',44},'Padding',[10 10 10 10],'RowSpacing',6);
        % row 1 — build controls
        r1 = uigridlayout(g,[1 6],'ColumnWidth',{200,188,206,190,'1x',0},'Padding',[0 0 0 0],'ColumnSpacing',8);
        r1a = uigridlayout(r1,[1 2],'ColumnWidth',{72,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uilabel(r1a,'Text','Time unit','HorizontalAlignment','right');
        ddTimeUnit = uidropdown(r1a,'Items',{'frame','seconds'},'Value','frame', ...
            'Tooltip','matrix(:,:,1) = integer FRAME (default; reproduces the legacy MSD lag-binning) or T = FRAME·dt.');
        r1b = uigridlayout(r1,[1 2],'ColumnWidth',{44,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uilabel(r1b,'Text','Name','HorizontalAlignment','right');
        eTsName = uieditfield(r1b,'text','Value','TrackStruct', ...
            'Tooltip',['Name this build, e.g. Day1_WT. It is written to analysis/<name>.mat and becomes the ' ...
                       'ACTIVE TrackStruct — the Contact-sites/Refine/Sites/Dwell tabs and a separately launched ' ...
                       'Analyze tool all follow it. Several named builds can sit side by side in analysis/.'], ...
            'ValueChangedFcn',@(s,e) onTsName());
        uibutton(r1,'Text','▶ Build + QC','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70], ...
            'FontColor','w','ButtonPushedFcn',@(s,e) onBuild(), ...
            'Tooltip','Import the curated tracks, compute MSD for every track (the slow step, once), write analysis/<name>.mat, and show the QC.');
        uibutton(r1,'Text','📂 Load TrackStruct…','ButtonPushedFcn',@(s,e) onLoadTracks(), ...
            'Tooltip','Load a built TrackStruct (the active one, or browse to any named build) and show the QC WITHOUT recomputing MSD.');
        lblBuild = uilabel(r1,'Text','Curate first (Import & Curate tab), then build + QC here — or Load an existing build.','FontColor',[0.45 0.45 0.45]);
        uilabel(r1,'Text','');
        % row 2 — QC controls
        r2 = uigridlayout(g,[1 9],'ColumnWidth',{56,180,58,130,66,56,84,60,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uilabel(r2,'Text','QC cell','HorizontalAlignment','right');
        ddQCcell = uidropdown(r2,'Items',{'(build first)'},'ValueChangedFcn',@(s,e) onQCcell());
        uilabel(r2,'Text','D fit','HorizontalAlignment','right');
        ddFitMode = uidropdown(r2,'Items',{'Fixed %','Adaptive R²'},'ItemsData',{'fixed','adaptive'},'Value','fixed', ...
            'Tooltip',['How each track''s D = slope/4 fit window is chosen. Fixed %: the same % of lags for every track. ' ...
                       'Adaptive R²: per track, the LARGEST window (up to the % below) that still fits with R² ≥ 0.95 — ' ...
                       'so a linear track uses more lags, a confined/curved one uses fewer (some 10%, some 25%…).'], ...
            'ValueChangedFcn',@(s,e) onMsdFrac());
        uilabel(r2,'Text','fit %','HorizontalAlignment','right');
        eMsdFrac = uispinner(r2,'Limits',[5 100],'Value',25,'Step',5, ...
            'Tooltip','Fixed mode: % of lags fit. Adaptive mode: the MAXIMUM % of lags the adaptive fit may use.', ...
            'ValueChangedFcn',@(s,e) onMsdFrac());
        uilabel(r2,'Text','state change','HorizontalAlignment','right');
        ddConfMode = uidropdown(r2,'Items',{'segment (changepoint)','drop (× preceding)','relative (× own median)','absolute (µm²/s)'}, ...
            'ItemsData',{'segment','drop','relative','absolute'},'Value',diffConfMode, ...
            'Tooltip',['How a localization is called "confined". RELATIVE compares D to THIS track''s own ' ...
            'median, so the test is "did this molecule slow down" rather than "is it below a fixed number" — ' ...
            'an absolute cut conflates a slow track with one that changed state.'], ...
            'ValueChangedFcn',@(s,e) onConfineD());
        eConfFrac = uispinner(r2,'Limits',[0.05 0.95],'Value',diffConfFrac,'Step',0.05,'ValueDisplayFormat','%.2f', ...
            'Tooltip',['Relative mode: confined when D falls to this fraction of the track''s own median. ' ...
            'Measured against a matched Brownian null on the reference cell, 0.30 with a minimum run of 5 ' ...
            'gives 3.6x enrichment over chance; 0.40 gives 2.7x.'], ...
            'ValueChangedFcn',@(s,e) onConfineD());
        uilabel(r2,'Text','min seg','HorizontalAlignment','right');
        eMinSeg = uispinner(r2,'Limits',[2 30],'Value',diffMinSeg,'Step',1,'RoundFractionalValues','on', ...
            'Tooltip','Segment mode: the shortest segment the splitter may produce, in steps.', ...
            'ValueChangedFcn',@(s,e) onConfineD());
        uilabel(r2,'Text','penalty','HorizontalAlignment','right');
        ePenalty = uispinner(r2,'Limits',[0.5 10],'Value',diffPenalty,'Step',0.25,'ValueDisplayFormat','%.2f', ...
            'Tooltip',['Segment mode: a split is accepted when its likelihood ratio exceeds ' ...
            'penalty x log(n). Higher = fewer, more confident segments. Measured on the reference ' ...
            'cell: 1.5 gives 86% precision, 2.5 gives 94%, 3.0 gives 97% at progressively lower yield.'], ...
            'ValueChangedFcn',@(s,e) onConfineD());
        uilabel(r2,'Text','baseline','HorizontalAlignment','right');
        eBaseWin = uispinner(r2,'Limits',[3 100],'Value',diffBaseWin,'Step',1,'RoundFractionalValues','on', ...
            'Tooltip','Drop mode: how many preceding localizations form the baseline D that the current one is compared against.', ...
            'ValueChangedFcn',@(s,e) onConfineD());
        uilabel(r2,'Text','min run','HorizontalAlignment','right');
        eMinRun = uispinner(r2,'Limits',[1 50],'Value',diffMinRun,'Step',1,'RoundFractionalValues','on', ...
            'Tooltip',['A confined stretch must last this many localizations to count as a state change. ' ...
            'This is the single biggest lever on specificity: a noise dip in the 7-point rolling estimator ' ...
            'is short, a real confinement episode is not. At 1 (no persistence) roughly half of pure ' ...
            'constant-D tracks register a false state change.'], ...
            'ValueChangedFcn',@(s,e) onConfineD());
        uilabel(r2,'Text','confined ≤ D','HorizontalAlignment','right');
        eConfineD = uispinner(r2,'Limits',[0.001 100],'Value',diffConfineD,'Step',0.05,'ValueDisplayFormat','%.3g', ...
            'Tooltip','Per-localization confinement threshold (µm²/s): D ≤ this = "confined". Sets which localizations feed Tool 3''s confinement/state-change site detection. Re-derives from the stored D(t) (no rebuild).', ...
            'ValueChangedFcn',@(s,e) onConfineD());
        lblQCm = uilabel(r2,'Text','Build, then click a track in the tracks panel to inspect it (it plays here).','FontColor',[0.2 0.4 0.5]);
        % row 3 — main: [ left pooled | middle clickable tracks | right: embedded player + small MSD ]
        mn = uigridlayout(g,[1 3],'ColumnWidth',{'0.78x','1.15x','1.05x'},'Padding',[0 0 0 0],'ColumnSpacing',8);
        lp = uigridlayout(mn,[6 1],'RowHeight',{92,'1x','1x','1x','1x','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
        tblBuild = uitable(lp,'ColumnName',{'cell','tracks','med len','mito','ER'},'ColumnWidth',{'auto',52,64,44,44});
        axLen   = uiaxes(lp); title(axLen,'track length');
        axDist  = uiaxes(lp); title(axDist,'ER / mito distance');
        axDdist = uiaxes(lp); title(axDdist,'D distribution');
        axDloc  = uiaxes(lp); title(axDloc,'stepwise D (per localization)');   % pooled Dt — one value per loc
        axCSD   = uiaxes(lp); title(axCSD,'CSD — cumulative displacement');    % every track faint, clicked one bold
        axCov  = uiaxes(mn); axCov.Toolbar.Visible='off'; title(axCov,'tracks (click one)'); axCov.ButtonDownFcn=@(s,e) onCovClick(e);
        rp = uigridlayout(mn,[4 1],'RowHeight',{'1.35x','1x','1x','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
        pc = uigridlayout(rp,[1 1],'Padding',[0 0 0 0]);   % embedded selected-track player
        if exist('spt_track_movie','file')==2, playerCtl = spt_track_movie(pc); end
        axMSD = uiaxes(rp); title(axMSD,'MSD + D fit');
        axDtrace = uiaxes(rp); title(axDtrace,'stepwise D(t) (click a track)');   % the per-loc D over time
        axSweep = uiaxes(rp); title(axSweep,'D & R² vs fit window (click a track)');   % the fit-fraction sweep
        txtBuild = uitextarea(g,'Editable','off','Value',{'Build log:'});
    end

    % ---- the ACTIVE TrackStruct -------------------------------------------------------------
    % A project may hold several named builds side by side in analysis/ (Day1_WT.mat, Day1_KO.mat…).
    % analysis/active_trackstruct.txt names the one in force, so a separately launched Analyze tool
    % (run_analyze) opens the same build the Curate tool last wrote or loaded. Absent pointer =
    % TrackStruct.mat, which is what every previous project already has.
    function n = activeTsName(anaDir)
        n = 'TrackStruct.mat';                       % default for a project with nothing built yet
        if nargin < 1 || isempty(anaDir), return; end
        try
            [~, nm] = cs_active_trackstruct(anaDir); % SINGLE definition, shared with the picker + lamp
            if ~isempty(nm), n = nm; end
        catch
        end
    end

    function setActiveTs(anaDir, name)
        tsName = name;
        if ~isempty(eTsName) && isgraphics(eTsName), [~,stem] = fileparts(name); eTsName.Value = stem; end
        if isempty(anaDir) || ~isfolder(anaDir), refreshBuildList(); return; end
        try
            fid = fopen(fullfile(anaDir,'active_trackstruct.txt'),'w');
            if fid > 0, fprintf(fid,'%s\n',name); fclose(fid); end
        catch
        end
        refreshBuildList();   % keep the top-bar selector showing which build is in force
    end

    function names = listBuilds(anaDir)
        % Every .mat in analysis/ that actually holds a 'Tracks' variable — i.e. every build this
        % project has, named or not. whos('-file') is ~1 ms, so this is cheap enough to refresh.
        names = {};
        if isempty(anaDir) || ~isfolder(anaDir), return; end
        skip = {'cs_calib.mat','CSW_final.mat','cs_window_dwell.mat','cs_footprints.mat','experiment_manifest.mat'};
        d = dir(fullfile(anaDir,'*.mat'));
        for k = 1:numel(d)
            if any(strcmpi(d(k).name, skip)), continue; end
            try
                w = whos('-file', fullfile(anaDir,d(k).name));
                if any(strcmp({w.name},'Tracks')), names{end+1} = d(k).name; end %#ok<AGROW>
            catch
            end
        end
    end

    function refreshBuildList()
        if isempty(ddBuild) || ~isgraphics(ddBuild), return; end
        anaDir = ''; if ~isempty(projectDir), anaDir = fullfile(projectDir,'analysis'); end
        names = listBuilds(anaDir);
        if isempty(names)
            ddBuild.Items = {'(no build yet)'}; ddBuild.ItemsData = {''}; ddBuild.Value = ''; return;
        end
        act = activeTsName(anaDir);
        lbl = names;
        for k = 1:numel(names)
            if strcmp(names{k}, act), lbl{k} = [names{k} '  ●']; end   % ● marks the one in force
        end
        ddBuild.Items = lbl; ddBuild.ItemsData = names;
        if any(strcmp(names, act)), ddBuild.Value = act; else, ddBuild.Value = names{1}; end
    end

    function onPickBuild()
        % Make the chosen build the active one and load it, so every downstream tab analyses it.
        if isempty(ddBuild) || ~isgraphics(ddBuild) || isempty(ddBuild.Value), return; end
        if isempty(projectDir), return; end
        anaDir = fullfile(projectDir,'analysis');
        want = ddBuild.Value;
        if strcmp(want, tsName) && ~isempty(buildTracks), return; end   % already on it
        setActiveTs(anaDir, want);
        buildTracks = [];                  % force a reload from the newly active file
        resetDownstream();                 % sites/dwell/compare belong to the old build
        if ensureTracksLoaded() && ~isempty(buildTracks)
            if ~isempty(ddQCcell) && isgraphics(ddQCcell)
                ddQCcell.Items = [{'All (pooled)'}, cellfun(@char, {buildTracks.file}, 'uni', 0)];
                ddQCcell.Value = 'All (pooled)';
                try, drawQC('All (pooled)'); catch, end
            end
            logBuild(sprintf('Active build -> %s  (%d cell(s))', want, numel(buildTracks)));
        else
            logBuild(sprintf('Could not load %s', want));
        end
        refreshBuildList();
    end

    function v = activeTsNow(), v = tsName; end    % test hooks — see fig.UserData
    function v = tracksNow(),   v = buildTracks; end

    function p = activeTsPath()                    % '' when no project is set
        p = ''; if isempty(projectDir), return; end
        a = fullfile(projectDir,'analysis');
        if isempty(tsName), tsName = activeTsName(a); end
        p = fullfile(a, tsName);
    end

    function onTsName()
        v = strtrim(eTsName.Value);
        if isempty(v), v = 'TrackStruct'; eTsName.Value = v; end
        [~,stem,ext] = fileparts(v); if ~strcmpi(ext,'.mat'), ext = '.mat'; end
        tsName = [stem ext];
    end

    function ok = ensureTracksLoaded()             % use the in-session build, else load the ACTIVE build
        ok = ~isempty(buildTracks); if ok, return; end
        if isempty(projectDir), return; end
        if isempty(tsName), tsName = activeTsName(fullfile(projectDir,'analysis')); end
        f = activeTsPath();
        if isfile(f)
            try, L = load(f); if isfield(L,'Tracks') && ~isempty(L.Tracks), buildTracks = L.Tracks; ok = true; end, catch, end
        end
    end

    function [X,Y,MD,ED] = densCoords(sel, src)
        % Localization coordinates (µm) for the selected cell(s) + source, with MITODIST/ERDIST kept
        % aligned 1:1 with X/Y (NaN where a distance column is absent).
        X=[]; Y=[]; MD=[]; ED=[];
        if isempty(buildTracks), return; end
        if strcmp(sel,'All (pooled)'), ks = 1:numel(buildTracks);
        else, ks = find(strcmp({buildTracks.file}, sel)); end
        useTracked = strcmp(src,'Tracked spots only');
        for k = ks(:)'
            T = buildTracks(k);
            haveCloud = isstruct(T.allSpots) && ~isempty(fieldnames(T.allSpots)) && ...
                isfield(T.allSpots,'X') && ~isempty(T.allSpots.X);
            if ~useTracked && haveCloud
                x = T.allSpots.X(:); y = T.allSpots.Y(:);
                md = nan(size(x)); ed = nan(size(x));
                if isfield(T.allSpots,'MITODIST') && numel(T.allSpots.MITODIST)==numel(x), md = double(T.allSpots.MITODIST(:)); end
                if isfield(T.allSpots,'ERDIST')   && numel(T.allSpots.ERDIST)==numel(x),   ed = double(T.allSpots.ERDIST(:));   end
            else
                M = T.matrix; if size(M,3) < 3, continue; end
                x = reshape(M(:,:,2),[],1); y = reshape(M(:,:,3),[],1);
                md = nan(size(x)); ed = nan(size(x));
                if isfield(T,'mitoDist') && isequal(size(T.mitoDist), size(M(:,:,1))), md = reshape(T.mitoDist,[],1); end
                if isfield(T,'erDist')   && isequal(size(T.erDist),   size(M(:,:,1))), ed = reshape(T.erDist,[],1);   end
            end
            keep = isfinite(x) & isfinite(y);
            X=[X; x(keep)]; Y=[Y; y(keep)]; MD=[MD; md(keep)]; ED=[ED; ed(keep)]; %#ok<AGROW>
        end
    end

    function s = occupancyFor(base)
        % whole-movie ER/mito occupancy (fraction of frames inside the organelle) for a cell, cached.
        % Used by ensureMips to write the ER support MIP for the ER-Monte-Carlo null. Only the occupancy
        % arrays are cached (seg_occupancy is the expensive part).
        b = char(base);
        for i = 1:numel(densCache), if strcmp(densCache(i).base, b), s = densCache(i).occ; return; end, end
        s = struct('mito',[],'er',[]);
        ov = resolveOverlay(b);
        if ~isempty(ov.mito) && isfile(ov.mito), s.mito = seg_occupancy(ov.mito); end
        if ~isempty(ov.er)   && isfile(ov.er),   s.er   = seg_occupancy(ov.er);   end
        densCache(end+1) = struct('base', b, 'occ', s);
    end

    function saveDensityFiles(k, src, anaDir)
        % Reproduce the advisor's density save EXACTLY (DensityVisualization + LocDensityFigIntUse) so the
        % files are a drop-in for the ContactSites pipeline. Same nm grid, σ=2 smooth, transpose:
        %   Densities/<base>_rho.tif  = full-range turbo RGB (DensityVisualization) — read by ContactSiteMapper
        %                               and cs_identify; its row count sets SF = SnapFOV_um/size(imG,1).
        %   Density_<base>.tif        = uint16(30·smoothed counts) in analysis/ root — read by cs_identify
        %                               (peaks recovered with DENS_GAIN = 30).
        %   Density_<base>.mat        = imG (same array) in analysis/ root — paper-faithful QC artifact.
        % Source: 'Tracked spots only' reproduces the paper's tracked-matrix input; 'All detections (cloud)'
        % uses the full localization cloud instead.
        base = char(buildTracks(k).file);
        [X,Y] = densCoords(base, src);
        PixSize = PRECNM;                                       % nm bin
        Bins = PixSize*(1:ceil(FOVUM/(PixSize/1000))+1);        % nm edges, identical to the advisor's grid
        okp = isfinite(X) & isfinite(Y);
        NumLoc = histcounts2(1000*X(okp), 1000*Y(okp), Bins, Bins);
        sm = imgaussfilt(NumLoc,[2 2])';                        % row = y, col = x (image convention)
        % Densities/<base>_rho.tif — full-range turbo RGB (DensityVisualization.m)
        densDir = fullfile(anaDir,'Densities'); if ~isfolder(densDir), mkdir(densDir); end
        lo = min(sm,[],'all'); hi = max(sm,[],'all'); if ~(hi>lo), hi = lo + 1; end
        rgb = ind2rgb(uint8(round(255*(sm-lo)/(hi-lo))), turbo(256));
        imwrite(rgb, fullfile(densDir, [base '_rho.tif']));
        % Density_<base>.mat/.tif in analysis/ root — imG = 30·smoothed counts (LocDensityFigIntUse.m)
        imG = 30*sm; %#ok<NASGU>
        save(fullfile(anaDir, ['Density_' base '.mat']), 'imG');
        try,   ChrisPrograms.saveastiff(uint16(30*sm), fullfile(anaDir, ['Density_' base '.tif']));
        catch, imwrite(uint16(30*sm), fullfile(anaDir, ['Density_' base '.tif'])); end
    end

    % ---------------- Tab 3: Contact sites (embeds the ContactSites picker cs_identify) ----------------
    % cs_identify is the paper pipeline's interactive picker. Given 'Parent', it builds its whole UI inside
    % our panel: auto-detects density peaks against a Monte-Carlo (CSR/ER) null, windows the density in time
    % to keep moving contact sites sharp, classifies each site mito vs non-mito from the per-spot MITODIST,
    % and writes analysis/csIDs/<cell>_CSsites.txt. It reads analysis/TrackStruct.mat + the saved density
    % (Densities/<cell>_rho.tif sets the pixel↔µm scale; Density_<cell>.tif is the display density).
    function buildContactTab(parent)
        g = uigridlayout(parent,[2 1],'RowHeight',{34,'1x'},'Padding',[10 10 10 10],'RowSpacing',6);
        r = uigridlayout(g,[1 5],'ColumnWidth',{200, 74,60, 168, '1x'},'Padding',[0 0 0 0],'ColumnSpacing',8);
        btnPickCS = uibutton(r,'Text','▶ Open windowed picker','FontWeight','bold', ...
            'BackgroundColor',[0.18 0.45 0.70],'FontColor','w', ...
            'Tooltip', ['Open the time-windowed contact-site picker: one density panel per frame window, ' ...
                        'click a window to zoom, manual Detect (ER Monte-Carlo / local / relative) + ＋Add, ' ...
                        'multi-select site list. Save writes per-window sites to csIDs/<cell>_CSsites.txt.'], ...
            'ButtonPushedFcn',@(s,e) onLaunchCS());
        uilabel(r,'Text','contact µm','HorizontalAlignment','right');
        eCScontact = uispinner(r,'Limits',[-1 2],'Value',0.15,'Step',0.05, ...
            'Tooltip','A site is mito-contact when nearby localizations'' median signed MITODIST ≤ this (µm). Adjustable in the picker too.');
        chkCSsaveDens = uicheckbox(r,'Text','(re)save density first','Value',true, ...
            'Tooltip','Also write Densities/<cell>_rho.tif + Density_<cell>.tif for the downstream mapper (the picker itself computes density live).');
        lblCS = uilabel(r,'Text','Build (Build & QC tab), then open the windowed contact-site picker here.','FontColor',[0.2 0.4 0.5]);
        pnCS = uipanel(g,'BorderType','none');
        placeholder(pnCS, 'The windowed contact-site picker opens here when you click ▶ Open windowed picker.');
    end

    function onLaunchCS()
        if exist('cs_window_picker','file') ~= 2, lblCS.Text = 'cs_window_picker.m is not on the path (expected in drivers/).'; return; end
        if ~ensureTracksLoaded() || isempty(buildTracks)
            lblCS.Text = 'Build (Build & QC tab) or open a project with analysis/TrackStruct.mat first.'; return; end
        anaDir = fullfile(projectDir,'analysis'); if ~isfolder(anaDir), try, mkdir(anaDir); catch, end, end
        if isempty(tsName), tsName = activeTsName(anaDir); end
        tsFile = fullfile(anaDir,tsName);
        if ~isfile(tsFile), Tracks = buildTracks; try, save(tsFile,'Tracks','-v7.3'); catch, end, end %#ok<NASGU>
        try, calib = struct('pixSizeUm',PXUM,'fovUm',FOVUM,'dt_s',DTS,'binNm',PRECNM,'snapFovUm',FOVUM); %#ok<NASGU>
             save(fullfile(anaDir,'cs_calib.mat'),'calib'); catch, end
        % density files for the downstream mapper (+ grid size); the picker computes its own density live.
        needDens = isempty(dir(fullfile(anaDir,'Densities','*_rho.tif')));
        if (~isempty(chkCSsaveDens) && chkCSsaveDens.Value) || needDens
            lblCS.Text = 'Saving density maps…'; drawnow;
            for k = 1:numel(buildTracks), try, saveDensityFiles(k, 'All detections (cloud)', anaDir); catch, end, end
        end
        % ER max-occupancy MIP = the ER support the ER-Monte-Carlo null scatters within.
        lblCS.Text = 'Preparing ER support…'; drawnow;
        mdir = ensureMips(anaDir);
        try
            % Hand over the struct we already hold rather than making the picker re-load the same
            % file: it never writes st.Tracks, so copy-on-write shares it instead of duplicating a
            % second full copy. It also guarantees the picker analyses the ACTIVE named build.
            cs_window_picker(pnCS, anaDir, struct('FOV_um',FOVUM,'binNm',PRECNM, ...
                'contactUm',eCScontact.Value,'mipDir',mdir,'segResolver',@resolveOverlay, ...
                'Tracks',buildTracks,'tsFile',tsFile));
            lblCS.Text = 'Windowed picker ready — set frames/window, click a window to zoom, Detect win / ＋Add, then 💾 Save.';
        catch ME
            lblCS.Text = ['Picker error: ' ME.message];
            placeholder(pnCS, 'The windowed contact-site picker opens here when you click ▶ Open windowed picker.');
        end
    end

    function mdir = ensureMips(anaDir)
        % Write small max-occupancy MIPs (one per cell) that cs_identify loads for its mito/ER overlay,
        % so it never reads the full seg stack on open. Names follow the picker's {prefix} pattern
        % (base with the _spt<n> channel token stripped). Reuses the cached whole-movie occupancy.
        mdir = fullfile(anaDir,'mips'); if ~isfolder(mdir), try, mkdir(mdir); catch, end, end
        for k = 1:numel(buildTracks)
            base = char(buildTracks(k).file);
            prefix = regexprep(base, '_spt\d+$', '', 'ignorecase');
            mp = fullfile(mdir, [prefix '_mito_mip.tif']); ep = fullfile(mdir, [prefix '_er_mip.tif']);
            if isfile(mp) && isfile(ep), continue; end
            s = occupancyFor(base);                              % [0,1] whole-movie occupancy, cached
            if ~isempty(s.mito) && ~isfile(mp), try, imwrite(uint8(255*mat2gray(s.mito)), mp); catch, end, end
            if ~isempty(s.er)   && ~isfile(ep), try, imwrite(uint8(255*mat2gray(s.er)),   ep); catch, end, end
        end
    end

    % ================= Tab 4 · Refine (interactive footprint editing before the mapper) =================
    % The paper's freehand refiner, folded into the modern pipeline: for each picked site it shows the
    % window density + the AUTO half-max footprint, and you adjust it (frac / maxR sliders, or Freehand
    % redraw), watching the tracked member trails update live. Save writes analysis/CS_footprints.mat,
    % which the mapper (Sites tab) reads to OVERRIDE the auto footprint per site. Optional — skip it and the
    % mapper just uses the auto footprints.
    function buildRefineTab(parent)
        g = uigridlayout(parent,[2 1],'RowHeight',{34,'1x'},'Padding',[10 10 10 10],'RowSpacing',6);
        r = uigridlayout(g,[1 7],'ColumnWidth',{216, 214, 64,150, 96, '1x', 0},'Padding',[0 0 0 0],'ColumnSpacing',8);
        uibutton(r,'Text','▶ Load / build contact sites','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70],'FontColor','w', ...
            'Tooltip','Build the auto (half-max) contact-site outline for every picked site (or resume an existing CS_footprints.mat), then adjust them here.', ...
            'ButtonPushedFcn',@(s,e) onRefLoad());
        lblRefSrc = uilabel(r,'Text','density source: (from picker)','FontColor',[0.3 0.3 0.45], ...
            'Tooltip','The density source is LOCKED to whatever you used in the Contact-sites picker (Contact-sites tab) — All localizations or Tracked only.');
        uilabel(r,'Text','window','HorizontalAlignment','right');
        ddRefWin = uidropdown(r,'Items',{'All windows'},'Value','All windows','ValueChangedFcn',@(s,e) fillRefList());
        uibutton(r,'Text','💾 Save','ButtonPushedFcn',@(s,e) onRefSave(), ...
            'Tooltip','Write analysis/CS_footprints.mat — the mapper (Sites tab) then uses THESE contact sites (and skips any you deleted).');
        lblRef = uilabel(r,'Text','Pick sites (Contact-sites tab), then Load / build contact sites to refine.','FontColor',[0.2 0.4 0.5]);
        uilabel(r,'Text','');
        % main: [ site list | (density editor over radial plot) | controls ]
        mn = uigridlayout(g,[1 3],'ColumnWidth',{'0.55x','1.5x',238},'Padding',[0 0 0 0],'ColumnSpacing',8);
        lstRefSites = uilistbox(mn,'Items',{'(load first)'},'ValueChangedFcn',@(s,e) onRefSelect());
        % centre: contact-site editor (top) with the radial concentration plot beneath it (full width, no cut-off)
        cnR = uigridlayout(mn,[2 1],'RowHeight',{'1.55x','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
        axRef = uiaxes(cnR); title(axRef,'contact-site editor (load, then pick a site)'); axRef.Toolbar.Visible='off';
        axRad = uiaxes(cnR); box(axRad,'on'); axRad.FontSize = 9; try, disableDefaultInteractivity(axRad); catch, end
        title(axRad,'radial concentration (load, then pick a site)');
        % right: display + auto-outline + manual-draw + delete controls
        cc = uigridlayout(mn,[14 1],'RowHeight',{24, 16,26, 44, 16,32, 16,26,30,28, 40,28, 30, '1x'}, ...
            'Padding',[0 0 0 0],'RowSpacing',4);
        chkRefLocs = uicheckbox(cc,'Text','show localizations','Value',false, ...
            'Tooltip','Overlay this window''s localizations (white dots) on the density.','ValueChangedFcn',@(s,e) redrawRef());
        uilabel(cc,'Text','colour scale','FontWeight','bold','FontColor',[0.35 0.35 0.4]);
        ddRefScale = uidropdown(cc,'Items',{'density (a.u.)','locs / bin','significance (p)'},'Value','density (a.u.)', ...
            'Tooltip',['density = smoothed detection density; locs/bin = raw localization count per 30 nm bin; ' ...
                       'significance = per-pixel Monte-Carlo CSR p-map (hot = density unlikely under a random scatter).'], ...
            'ValueChangedFcn',@(s,e) redrawRef());
        scg = uigridlayout(cc,[2 1],'RowHeight',{16,'1x'},'Padding',[0 0 0 0],'RowSpacing',0);
        uilabel(scg,'Text','contrast','FontSize',10,'FontColor',[0.35 0.35 0.4]);
        sldRefContrast = uislider(scg,'Limits',[0.1 1],'Value',1,'MajorTicks',[],'MinorTicks',[], ...
            'Tooltip','Clip the colour cap at contrast·peak. Left = brighter (reveal faint density).','ValueChangedFcn',@(s,e) onRefContrast());
        uilabel(cc,'Text','auto contact site (half-max)','FontWeight','bold','FontColor',[0.35 0.35 0.4]);
        fm = uigridlayout(cc,[1 4],'ColumnWidth',{30,'1x',40,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',4);
        uilabel(fm,'Text','frac');
        eRefFrac = uispinner(fm,'Limits',[0.1 0.95],'Value',0.5,'Step',0.05,'ValueChangedFcn',@(s,e) onRefParam(), ...
            'Tooltip',['HALF-MAX: the contact site is the connected patch of density ≥ frac·(local peak) that ' ...
                       'contains the pick, grown outward and capped at maxR. frac=0.5 = half the peak; LOWER frac = bigger site, HIGHER = tighter core.']);
        uilabel(fm,'Text','maxR');
        eRefMaxR = uispinner(fm,'Limits',[0.1 3],'Value',0.6,'Step',0.1,'ValueChangedFcn',@(s,e) onRefParam(), ...
            'Tooltip','Clip the auto contact site to this radius (µm) about the pick.');
        uilabel(cc,'Text','manual refine','FontWeight','bold','FontColor',[0.35 0.35 0.4]);
        uibutton(cc,'Text','✎ Draw centre + boundary','FontWeight','bold','BackgroundColor',[0.20 0.45 0.70],'FontColor','w', ...
            'Tooltip','Click the CENTRE, then press-and-drag to trace the contact-site BOUNDARY yourself (Esc cancels). This is the paper''s manual refine.', ...
            'ButtonPushedFcn',@(s,e) onRefDrawCB());
        uibutton(cc,'Text','↺ Reset to auto','ButtonPushedFcn',@(s,e) onRefReset());
        btnRefDelete = uibutton(cc,'Text','🗑 Delete site','FontColor',[0.75 0.1 0.1], ...
            'Tooltip','Mark this contact site for deletion (recorded in CS_footprints.mat; the mapper skips it). Click again to restore.', ...
            'ButtonPushedFcn',@(s,e) onRefDelete());
        smg = uigridlayout(cc,[2 1],'RowHeight',{16,'1x'},'Padding',[0 0 0 0],'RowSpacing',0);
        uilabel(smg,'Text','smooth boundary','FontSize',10,'FontColor',[0.35 0.35 0.4]);
        sldRefSmooth = uislider(smg,'Limits',[0 1],'Value',0.35,'MajorTicks',[],'MinorTicks',[], ...
            'Tooltip','Smoothing strength for ✨ Smooth (and auto-applied to a hand-traced boundary): 0 = keep detail, 1 = near-circular.');
        uibutton(cc,'Text','✨ Smooth boundary','FontWeight','bold', ...
            'Tooltip','Smooth this contact site''s outline into a clean closed curve (removes the jagged half-max / freehand steps). Click again to smooth more.', ...
            'ButtonPushedFcn',@(s,e) onRefSmooth());
        lblRefInfo = uilabel(cc,'Text','','WordWrap','on','FontColor',[0.35 0.35 0.42]);
    end

    function onRefContrast()
        if refSelIdx>=1 && refSelIdx<=numel(refFoot), drawRefSite(refSelIdx); end
    end

    function amt = refSmoothAmt()
        amt = 0.35; if ~isempty(sldRefSmooth) && isgraphics(sldRefSmooth), amt = sldRefSmooth.Value; end
    end

    function onRefSmooth()
        % Smooth the selected contact site's outline into a clean closed curve (auto half-max ring or a
        % freehand trace). Repeated clicks smooth further. Marks the site edited so Save keeps it.
        if refSelIdx<1 || refSelIdx>numel(refFoot), return; end
        rb = refFoot(refSelIdx).refboundary;
        if isempty(rb) || size(rb,1) < 4, lblRef.Text = 'No boundary to smooth (pick a site with a footprint).'; return; end
        if exist('cs_smooth_boundary','file') ~= 2, lblRef.Text = 'cs_smooth_boundary.m not on the path.'; return; end
        rb = cs_smooth_boundary(rb, refSmoothAmt());
        refFoot(refSelIdx).refboundary = rb;
        refFoot(refSelIdx).areaUm2 = polyarea(rb(:,1),rb(:,2));
        om = 'halfmax'; if isfield(refFoot,'mode') && ~isempty(refFoot(refSelIdx).mode), om = char(refFoot(refSelIdx).mode); end
        refFoot(refSelIdx).mode = [regexprep(om,'\+smooth$','') '+smooth'];
        refFoot(refSelIdx).edited = true;
        drawRefSite(refSelIdx); updateRefRow(refSelIdx);
        lblRef.Text = sprintf('Smoothed the contact-site boundary (strength %.2f). 💾 Save when done.', refSmoothAmt());
    end

    function redrawRef()
        if refSelIdx>=1 && refSelIdx<=numel(refFoot), drawRefSite(refSelIdx); end
    end

    function [X,Y] = refWindowLocs(e)
        % this window's density-source localizations (µm) — for the scatter overlay + radial plot
        X = []; Y = [];
        if isempty(buildTracks) || e.cellIndex<1 || e.cellIndex>numel(buildTracks), return; end
        T = buildTracks(e.cellIndex);
        if strcmp(e.densSrc,'tracked')
            sX = reshape(T.matrix(:,:,2),[],1); sY = reshape(T.matrix(:,:,3),[],1); sF = reshape(T.matrix(:,:,1),[],1);
        else
            a = T.allSpots; sX = a.X(:); sY = a.Y(:); sF = a.FRAME(:);
        end
        fin = isfinite(sX) & isfinite(sY);
        if isinf(e.winFrames(1)) && isinf(e.winFrames(2)), inw = fin;
        else, inw = sF>=e.winFrames(1) & sF<=e.winFrames(2) & fin; end
        X = sX(inw); Y = sY(inw);
    end

    function onRefLoad()
        anaDir = ensureAnaDir(); if isempty(anaDir), lblRef.Text='Pick a project + build/load TrackStruct first.'; return; end
        if isempty(dir(fullfile(anaDir,'csIDs','*_CSsites.txt')))
            lblRef.Text='No csIDs/*_CSsites.txt — pick sites in the Contact-sites tab (Save) first.'; return; end
        % ALWAYS build the full contact-site list (every picked site), then MERGE any saved edits +
        % deletions from CS_footprints.mat onto the matching sites — so resume shows ALL sites, not just
        % the few that were edited. The density SOURCE is LOCKED to whatever the picker (Contact-sites tab) used
        % (cs_footprints_build reads windows.source); no toggle here.
        lblRef.Text='Building contact sites…'; drawnow;
        try, refFoot = cs_footprints_build(anaDir, struct('save',false,'verbose',false));
        catch ME, lblRef.Text=['Build error: ' ME.message]; return; end
        if isempty(refFoot), lblRef.Text='No sites found for the cells in TrackStruct.'; return; end
        refLockedSrc = refFoot(1).densSrc;
        if ~isempty(lblRefSrc) && isgraphics(lblRefSrc)
            lblRefSrc.Text = ['density source: ' srcLabel(refLockedSrc) '  (locked from picker)'];
        end
        nMerged = 0; nDel = 0;
        f = fullfile(anaDir,'CS_footprints.mat');
        if isfile(f)
            try
                Lf = load(f);
                if isfield(Lf,'CSfoot') && ~isempty(Lf.CSfoot)
                    for q = 1:numel(Lf.CSfoot)
                        m = matchFoot(refFoot, Lf.CSfoot(q));
                        if m>0, refFoot(m) = mergeFoot(refFoot(m), Lf.CSfoot(q)); nMerged = nMerged+1; end
                    end
                end
                if isfield(Lf,'CSdeleted') && ~isempty(Lf.CSdeleted)
                    for q = 1:numel(Lf.CSdeleted)
                        m = matchFoot(refFoot, Lf.CSdeleted(q));
                        if m>0, refFoot(m).deleted = true; nDel = nDel+1; end
                    end
                end
            catch, end
        end
        siteDensCache = struct('key',{},'dens',{},'raw',{}); refNullCache = struct('key',{},'nullMax',{},'pmap',{}); refErCache = struct('key',{},'erGrid',{}); refCbar = [];
        wl = unique([refFoot.window]); ddRefWin.Items = [{'All windows'}, arrayfun(@(w) sprintf('window %d',w), wl,'uni',0)];
        ddRefWin.Value = 'All windows'; refSelIdx = 0;
        fillRefList();
        extra = ''; if nMerged>0 || nDel>0, extra = sprintf(' (resumed %d edit(s), %d deletion(s))', nMerged, nDel); end
        lblRef.Text = sprintf('%d footprint(s)%s — pick a site; adjust / draw / delete; then 💾 Save.', numel(refFoot), extra);
    end

    function m = matchFoot(FF, ff)
        % index in FF of the site matching ff (file+csID+window, pickPx-validated); 0 if none
        m = 0;
        for i = 1:numel(FF)
            if strcmp(FF(i).file,ff.file) && FF(i).csID==ff.csID && FF(i).window==ff.window
                ok = true;
                if isfield(ff,'pickPx') && numel(ff.pickPx)==2 && isfield(FF(i),'pickPx') && numel(FF(i).pickPx)==2
                    ok = hypot(FF(i).pickPx(1)-ff.pickPx(1), FF(i).pickPx(2)-ff.pickPx(2)) < 1.5;
                end
                if ok, m = i; return; end
            end
        end
    end

    function b = mergeFoot(b, s)
        for fld = {'center','refboundary','mode','frac','maxRadiusUm','areaUm2'}
            if isfield(s,fld{1}) && ~isempty(s.(fld{1})), b.(fld{1}) = s.(fld{1}); end
        end
        b.edited = true;
    end

    function fillRefList()
        if isempty(refFoot), lstRefSites.Items = {'(load first)'}; lstRefSites.ItemsData = []; refRowMap = []; refSelIdx = 0; return; end
        keep = 1:numel(refFoot);
        if ~isempty(ddRefWin) && isgraphics(ddRefWin) && ~strcmp(ddRefWin.Value,'All windows')
            w = sscanf(ddRefWin.Value,'window %d'); keep = find([refFoot.window]==w);
        end
        refRowMap = keep;
        items = cell(1,numel(keep));
        for r = 1:numel(keep), items{r} = refRowLabel(refFoot(keep(r))); end
        lstRefSites.Items = items; lstRefSites.ItemsData = keep;
        % A programmatic Items reassignment does NOT fire ValueChangedFcn, so sync the selection
        % ourselves — otherwise refSelIdx keeps pointing at a now-filtered-out site and edits go astray.
        if ~isempty(keep), lstRefSites.Value = keep(1); onRefSelect(); else, refSelIdx = 0; end
    end

    function s = refRowLabel(e)
        tag = '';
        if isfield(e,'edited')  && ~isempty(e.edited)  && e.edited,  tag = [tag ' ✎']; end
        if isfield(e,'deleted') && ~isempty(e.deleted) && e.deleted, tag = [tag ' ✗del']; end
        s = sprintf('c%d · s%d · w%d · %s%s', e.cellIndex, e.csID, e.window, tern(e.mito,'mito','—'), tag);
    end

    function s = srcLabel(sc)
        if strcmp(char(sc),'tracked'), s = 'Tracked only'; else, s = 'All localizations'; end
    end

    function onRefSelect()
        k = lstRefSites.Value; if isempty(k) || ~isnumeric(k) || k<1 || k>numel(refFoot), return; end
        refSelIdx = k; e = refFoot(k);
        if isgraphics(eRefFrac) && isfield(e,'frac')        && ~isempty(e.frac),        eRefFrac.Value = min(max(e.frac,0.1),0.95); end
        if isgraphics(eRefMaxR) && isfield(e,'maxRadiusUm') && ~isempty(e.maxRadiusUm), eRefMaxR.Value = min(max(e.maxRadiusUm,0.1),3); end
        drawRefSite(k);
    end

    function drawRefSite(k)
        if k<1 || k>numel(refFoot), return; end
        if ~ensureTracksLoaded(), lblRef.Text='TrackStruct not loaded.'; return; end
        e = refFoot(k); SF = e.SF; g = e.grid; cUm = e.center;
        [Dens,Raw] = windowDens(e.cellIndex, e.winFrames, SF, g, e.densSrc);
        scaleMode = 'density (a.u.)'; if ~isempty(ddRefScale) && isgraphics(ddRefScale), scaleMode = ddRefScale.Value; end
        contrast = 1; if ~isempty(sldRefContrast) && isgraphics(sldRefContrast), contrast = sldRefContrast.Value; end
        cla(axRef);
        img = Dens; cbLab = 'density (a.u.)'; isSig = false; nullMax = [];
        if strcmp(scaleMode,'locs / bin') && ~isempty(Raw)
            img = Raw; cbLab = 'localizations / bin';
        elseif strcmp(scaleMode,'significance (p)') && ~isempty(Raw) && ~isempty(Dens)
            [pmap, nullMax] = refWindowNull(e, Raw, Dens);      % per-pixel FWER p-map (cached per window)
            if ~isempty(pmap), img = 1 - pmap; cbLab = 'significance (1 − p)'; isSig = true; end
        end
        if ~isempty(img)
            imagesc(axRef, [SF g*SF], [SF g*SF], img); colormap(axRef, turbo);
            if isSig, clim(axRef,[0 1]); else, pk = max(img(:)); if pk>0, clim(axRef,[0 contrast*pk]); end, end
            try
                if isempty(refCbar) || ~isgraphics(refCbar), refCbar = colorbar(axRef); end
                refCbar.Label.String = cbLab;
            catch, end
        end
        axis(axRef,'image'); hold(axRef,'on');
        [Lx,Ly] = refWindowLocs(e);                                          % this window's localizations (µm)
        if ~isempty(chkRefLocs) && isgraphics(chkRefLocs) && chkRefLocs.Value && ~isempty(Lx)
            scatter(axRef, Lx, Ly, 5, [1 1 1], 'filled', 'MarkerFaceAlpha',0.30, 'HitTest','off');
        end
        bx = e.refboundary(:,1)+cUm(1); by = e.refboundary(:,2)+cUm(2);
        del = isfield(e,'deleted') && ~isempty(e.deleted) && e.deleted;
        bclr = [1 1 1]; if del, bclr = [1 0.35 0.35]; end                    % deleted -> red, dashed
        plot(axRef, bx, by, tern(del,'--','-'),'Color',bclr,'LineWidth',1.6);
        [trk,CSm] = footTrackMembers(e.cellIndex, e.winFrames, cUm, e.refboundary);
        for jj = 1:numel(trk)
            x = CSm(:,jj,2)+cUm(1); y = CSm(:,jj,3)+cUm(2); ok = isfinite(x)&isfinite(y);
            if nnz(ok)>=2, plot(axRef, x(ok), y(ok), '-','Color',[1 0.95 0.3 0.55],'LineWidth',0.5); end
        end
        plot(axRef, cUm(1), cUm(2), '+','Color',[1 0 1],'MarkerSize',13,'LineWidth',1.6);
        hold(axRef,'off');
        pad = max(0.6, 1.4*sqrt(max(e.areaUm2,eps)/pi));
        xlim(axRef,[min(bx)-pad max(bx)+pad]); ylim(axRef,[min(by)-pad max(by)+pad]);
        xlabel(axRef,'x (µm)'); ylabel(axRef,'y (µm)');
        delTag = ''; if del, delTag = '  [DELETED]'; end
        title(axRef, sprintf('cell %d · site %d · win %d · %s · %.4f µm² · %d trk%s', e.cellIndex, e.csID, e.window, char(e.mode), e.areaUm2, numel(trk), delTag));
        % peak localization density (raw loc/bin) inside the site + significance (site peak vs null)
        pkLoc = NaN; if ~isempty(Raw), pkLoc = localPeak(Raw, cUm, SF, g); end
        pval = NaN;
        if isSig && ~isempty(nullMax) && ~isempty(Dens)
            pval = mean(nullMax >= localPeak(Dens, cUm, SF, g));
        end
        % radial concentration: how the localizations concentrate toward the centre vs a CELL-WIDE
        % ER-uniform null (density from the localizations over ER across the whole cell, not the local FOV)
        pctIn = NaN; idx = NaN;
        if ~isempty(Lx)
            inb = inpolygon(Lx, Ly, bx, by); pctIn = 100*nnz(inb)/max(numel(Lx),1);
            if ~isempty(axRad) && isgraphics(axRad)
                en = []; try, en = erNullForSite(e.cellIndex, SF, g, cUm, Lx, Ly, 1.2); catch, end
                try, idx = cs_radial_plot(axRad, Lx-cUm(1), Ly-cUm(2), 1.2, pctIn, true, en); catch, end
            end
        end
        if ~isempty(btnRefDelete) && isgraphics(btnRefDelete)
            if del, btnRefDelete.Text = '♻ Restore site'; btnRefDelete.FontColor = [0.15 0.5 0.2];
            else,   btnRefDelete.Text = '🗑 Delete site'; btnRefDelete.FontColor = [0.75 0.1 0.1]; end
        end
        if ~isempty(lblRefInfo) && isgraphics(lblRefInfo)
            pTxt = ''; if isfinite(pval), pTxt = sprintf('\nCSR peak p = %.3g', pval); end
            lblRefInfo.Text = sprintf('area %.4f µm²\n%d tracked track(s)\npeak %.2g loc/bin\n%.1f%% of window locs inside\nconcentration %.2f%s%s', ...
                e.areaUm2, numel(trk), pkLoc, pctIn, idx, pTxt, tern(del,'  · DELETED',''));
        end
    end

    function pk = localPeak(im, cUm, SF, g)
        % peak of a density image within a small disk (0.4 µm) about the centre
        pk = NaN; if isempty(im), return; end
        rpx = max(2, round(0.4/SF)); cc = round(cUm/SF);
        x0 = max(1,cc(1)-rpx); x1 = min(g,cc(1)+rpx); y0 = max(1,cc(2)-rpx); y1 = min(g,cc(2)+rpx);
        if x1<=x0 || y1<=y0, return; end
        sub = im(y0:y1, x0:x1); pk = max(sub(:));   % im is [row=y, col=x]
    end

    function [pmap, nullMax] = refWindowNull(e, Raw, Dens)
        % Per-window CSR Monte-Carlo null recoloured as a per-pixel FWER p-map. Scatter this window's
        % localizations uniformly within the cell-occupied region M times, record each run's PEAK
        % smoothed density (family-wise null); then p(pixel) = fraction of null peaks ≥ that pixel's
        % density, so hot (1−p→1) marks density unlikely under a random scatter. Cached per (cell,window,
        % src) since the null is a window property (independent of the drawn boundary).
        pmap = []; nullMax = [];
        if isempty(Raw) || isempty(Dens), return; end
        key = sprintf('%d|%g|%g|%s', e.cellIndex, e.winFrames(1), e.winFrames(2), e.densSrc);
        for i = 1:numel(refNullCache)
            if strcmp(refNullCache(i).key,key), nullMax = refNullCache(i).nullMax; pmap = refNullCache(i).pmap; return; end
        end
        if ~isempty(lblRef) && isgraphics(lblRef), lblRef.Text = 'Computing significance (CSR Monte-Carlo)…'; drawnow; end
        mask = imfill(imdilate(Raw>=1, strel('disk',4)), 'holes');           % cell-occupied region (CSR support)
        try, [~, nullMax] = cs_mc_threshold(Raw, mask, 8, 0.05, 100); catch, nullMax = []; end
        if ~isempty(nullMax)
            sn = sort(nullMax(:)); M = numel(sn);
            b = discretize(Dens(:), [sn; inf]); b(isnan(b)) = 0;             % # null peaks ≤ each pixel
            pmap = reshape(min(max((M - b)/M, 0), 1), size(Dens));          % FWER p = fraction of null peaks ≥ pixel
            refNullCache(end+1) = struct('key',key,'nullMax',nullMax,'pmap',pmap);
        end
        if ~isempty(lblRef) && isgraphics(lblRef), lblRef.Text = 'Significance ready — hot = density unlikely under a random scatter.'; end
    end

    function onRefDelete()
        if refSelIdx<1 || refSelIdx>numel(refFoot), return; end
        cur = isfield(refFoot(refSelIdx),'deleted') && ~isempty(refFoot(refSelIdx).deleted) && refFoot(refSelIdx).deleted;
        refFoot(refSelIdx).deleted = ~cur;
        drawRefSite(refSelIdx); updateRefRow(refSelIdx);
        if ~cur, lblRef.Text = sprintf('Site %d marked for deletion — 💾 Save, then re-run the mapper (Sites tab) to drop it.', refFoot(refSelIdx).csID);
        else,    lblRef.Text = sprintf('Site %d restored.', refFoot(refSelIdx).csID); end
    end

    function onRefParam()
        if refSelIdx<1 || refSelIdx>numel(refFoot), return; end
        e = refFoot(refSelIdx);
        Dens = windowDens(e.cellIndex, e.winFrames, e.SF, e.grid, e.densSrc);
        if isempty(Dens), return; end
        fpOpts = struct('mode','halfmax','frac',eRefFrac.Value,'maxRadiusUm',eRefMaxR.Value,'boxHalfWidthUm',0.5);
        fp = cs_window_footprint(Dens, e.pickPx, e.SF, fpOpts);
        refFoot(refSelIdx).refboundary = fp.refboundary; refFoot(refSelIdx).center = fp.centerUm;
        refFoot(refSelIdx).mode = fp.mode; refFoot(refSelIdx).frac = eRefFrac.Value;
        refFoot(refSelIdx).maxRadiusUm = eRefMaxR.Value; refFoot(refSelIdx).areaUm2 = fp.areaUm2;
        refFoot(refSelIdx).edited = true;                 % only edited footprints are saved as overrides
        drawRefSite(refSelIdx); updateRefRow(refSelIdx);
    end

    function onRefDrawCB()
        % Paper-style manual refine: click the CENTRE (drawpoint), then trace the BOUNDARY
        % (drawfreehand). The clicked point becomes the site centre; the traced polygon (µm,
        % relative to that centre) becomes the footprint. Both are stored and flagged edited.
        if refSelIdx<1 || refSelIdx>numel(refFoot), return; end
        lblRef.Text='Click the CENTRE, then press-and-drag to trace the BOUNDARY (Esc cancels)…'; drawnow;
        r1 = [];
        try, r1 = drawpoint(axRef,'Color',[1 0 1]);
        catch ME, lblRef.Text=['Drawing unavailable here: ' ME.message]; return; end
        if isempty(r1) || ~isvalid(r1) || isempty(r1.Position)
            lblRef.Text='Cancelled (no centre placed).'; try, delete(r1); catch, end; return;
        end
        ctr = r1.Position(:)';                                        % µm centre
        r2 = [];
        try, r2 = drawfreehand(axRef,'Color',[1 0 1],'LineWidth',1.2); catch, end
        if isempty(r2) || ~isvalid(r2) || size(r2.Position,1)<3
            lblRef.Text='Cancelled (no boundary drawn).'; try, delete(r1); catch, end; try, delete(r2); catch, end; return;
        end
        pos = r2.Position; try, delete(r1); catch, end; try, delete(r2); catch, end
        refb = [pos(:,1)-ctr(1), pos(:,2)-ctr(2)];                    % µm, relative to the clicked centre
        if ~isequal(refb(1,:),refb(end,:)), refb(end+1,:) = refb(1,:); end
        if exist('cs_close_boundary','file')==2, refb = cs_close_boundary(refb); end   % round ONLY the closing seam; keep the traced shape
        refFoot(refSelIdx).center = ctr; refFoot(refSelIdx).refboundary = refb;
        refFoot(refSelIdx).mode = 'freehand'; refFoot(refSelIdx).areaUm2 = polyarea(refb(:,1),refb(:,2));
        refFoot(refSelIdx).edited = true;
        drawRefSite(refSelIdx); updateRefRow(refSelIdx);
        lblRef.Text='Centre + boundary set by hand. 💾 Save footprints when done.';
    end

    function onRefReset()
        if refSelIdx<1 || refSelIdx>numel(refFoot), return; end
        if isgraphics(eRefFrac),  eRefFrac.Value=0.5; end
        if isgraphics(eRefMaxR),  eRefMaxR.Value=0.6; end
        onRefParam();                                   % recompute the auto (half-max) contact site
        refFoot(refSelIdx).edited = false;              % back to auto -> no longer an override
        drawRefSite(refSelIdx); updateRefRow(refSelIdx);
    end

    function updateRefRow(k)
        if isempty(refRowMap), return; end
        r = find(refRowMap==k,1); if isempty(r), return; end
        it = lstRefSites.Items; if r>numel(it), return; end
        it{r} = refRowLabel(refFoot(k));
        sel = lstRefSites.Value;                 % ItemsData holds refFoot indices; preserve selection
        lstRefSites.Items = it; lstRefSites.ItemsData = refRowMap; lstRefSites.Value = sel;
    end

    function onRefSave()
        if isempty(refFoot), lblRef.Text='Nothing to save — Load / build footprints first.'; return; end
        anaDir = ensureAnaDir(); if isempty(anaDir), lblRef.Text='Pick a project first.'; return; end
        % Persist the sites you EDITED (footprint overrides) + the sites you DELETED (skip list). Unedited,
        % non-deleted sites are left out, so the mapper's auto footprint + Sites-tab maxR/frac still govern them.
        edFlag  = arrayfun(@(x) isfield(x,'edited')  && ~isempty(x.edited)  && x.edited,  refFoot);
        delFlag = arrayfun(@(x) isfield(x,'deleted') && ~isempty(x.deleted) && x.deleted, refFoot);
        CSfoot = refFoot(edFlag & ~delFlag);      % a deleted site needs no footprint override
        dd = refFoot(delFlag);
        CSdeleted = struct('file',{},'csID',{},'window',{},'pickPx',{});
        for q = 1:numel(dd)
            CSdeleted(q) = struct('file',dd(q).file,'csID',dd(q).csID,'window',dd(q).window,'pickPx',dd(q).pickPx); %#ok<AGROW>
        end
        try, save(fullfile(anaDir,'CS_footprints.mat'),'CSfoot','CSdeleted','-v7.3'); %#ok<NASGU>
        catch ME, lblRef.Text=['Save failed: ' ME.message]; return; end
        CSW = []; DD = [];                        % refinement changes the mapping -> invalidate old results
        nE = nnz(edFlag & ~delFlag); nD = nnz(delFlag);
        if nE==0 && nD==0
            lblRef.Text = 'No edits/deletions — saved an empty override set; the mapper (Sites tab) uses AUTO footprints for every site.';
        else
            lblRef.Text = sprintf('Saved %d edited + %d deleted site(s) to CS_footprints.mat — re-run the mapper (Sites tab) to apply.', nE, nD);
        end
    end

    % ================= Tab 5 · Sites (mapper + auto-footprint + per-site-per-window results) =================
    % Runs cs_window_mapper (headless) to assign every picked site its member tracks/localizations and
    % density metrics for its OWN time window, then lets you inspect any site: the window density backdrop,
    % the auto half-max footprint polygon, the member-track trails, and the pick. Reads csIDs/*_CSsites.txt
    % (from Tab 3) + analysis/TrackStruct.mat; writes analysis/CSW_final.mat (the file Tabs 5–6 read).
    function buildSitesTab(parent)
        g = uigridlayout(parent,[2 1],'RowHeight',{34,'1x'},'Padding',[10 10 10 10],'RowSpacing',6);
        r = uigridlayout(g,[1 12],'ColumnWidth', ...
            {180, 56,46, 40,46, 150, 54,120, 90, 52,48, '1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uibutton(r,'Text','▶ Run mapper','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70],'FontColor','w', ...
            'Tooltip','Assign every picked site its member tracks + metrics for its time window -> analysis/CSW_final.mat. Auto contact site = half-max (maxR/frac); refined sites (Refine tab) override.', ...
            'ButtonPushedFcn',@(s,e) onRunMapper());
        uilabel(r,'Text','maxR µm','HorizontalAlignment','right');
        eMaxR = uispinner(r,'Limits',[0.1 3],'Value',0.6,'Step',0.1,'Tooltip','Auto (half-max) contact-site size cap (µm). A MERC is sub-micron.');
        uilabel(r,'Text','frac','HorizontalAlignment','right');
        eFrac = uispinner(r,'Limits',[0.1 0.95],'Value',0.5,'Step',0.05,'Tooltip','Half-max fraction of the local peak for the auto contact site.');
        lblSitesSrc = uilabel(r,'Text','density: (from picker)','FontColor',[0.3 0.3 0.45], ...
            'Tooltip','Density/enrichment source is LOCKED to what the Contact-sites picker (Contact-sites tab) used. Membership + dwell always use the tracked matrix.');
        uilabel(r,'Text','window','HorizontalAlignment','right');
        ddWinFilt = uidropdown(r,'Items',{'All windows'},'Value','All windows','ValueChangedFcn',@(s,e) fillSitesTable());
        chkUseRefined = uicheckbox(r,'Text','use refined','Value',true, ...
            'Tooltip','Apply the Refine tab''s analysis/CS_footprints.mat (per-site refined outlines + deletions). Uncheck to force the auto (maxR/frac) contact site for every site.');
        uilabel(r,'Text','≥% in','HorizontalAlignment','right','Tooltip','Show/play only member tracks with at least this % of their localizations INSIDE the contact site (dwelling vs passing-through). 0 = all members.');
        eMinPctIn = uispinner(r,'Limits',[0 100],'Value',0,'Step',5,'RoundFractionalValues',true,'ValueChangedFcn',@(s,e) onMinPctIn());
        lblSites = uilabel(r,'Text','Pick sites (Contact-sites tab), then Run mapper.','FontColor',[0.2 0.4 0.5]);
        % main: [ results table | (density inspector / track player) | member list + play ]
        mn = uigridlayout(g,[1 3],'ColumnWidth',{'1.0x','1.35x','0.62x'},'Padding',[0 0 0 0],'ColumnSpacing',8);
        tblSites = uitable(mn,'ColumnName',{'cell','site','win','mito','area µm²','tracks','enrich'}, ...
            'ColumnWidth',{'auto',48,44,44,72,58,58}, ...
            'SelectionType','row','CellSelectionCallback',@(s,e) onSiteSelect(e));
        cn = uigridlayout(mn,[2 1],'RowHeight',{'1x','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
        axSite = uiaxes(cn); title(axSite,'site inspector — density + footprint (Run mapper, click a row)'); axSite.Toolbar.Visible='off';
        pcS = uigridlayout(cn,[1 1],'Padding',[0 0 0 0]);          % embedded member-track player
        if exist('spt_track_movie','file')==2, sitePlayer = spt_track_movie(pcS); end
        rp = uigridlayout(mn,[8 1],'RowHeight',{22,'1x',28,28,28,28,28,28},'Padding',[0 0 0 0],'RowSpacing',4);
        uilabel(rp,'Text','member tracks (click to select)','FontWeight','bold','FontColor',[0.35 0.35 0.4]);
        lstMembers = uilistbox(rp,'Items',{'—'},'ValueChangedFcn',@(s,e) onMemberSelect(), ...
            'Tooltip','Member tracks of the selected site. Click one to highlight it on the density and enable single-track play / delete.');
        btnPlaySite = uibutton(rp,'Text','▶ Play all member tracks','ButtonPushedFcn',@(s,e) onPlaySite(), ...
            'Tooltip','Play ALL of this site''s member tracks over the raw SPT movie (each a distinct colour) with per-frame ER/mito overlay.');
        btnPlayOne = uibutton(rp,'Text','▶ Play selected track','ButtonPushedFcn',@(s,e) onPlaySiteOne(), ...
            'Tooltip','Play ONLY the track selected in the list, over the raw SPT movie.');
        btnDelTrack = uibutton(rp,'Text','🗑 Mark/unmark track for removal','FontColor',[0.75 0.1 0.1],'ButtonPushedFcn',@(s,e) onDeleteTrack(), ...
            'Tooltip','Toggle removal of the selected member track from THIS site. Marked tracks turn RED and stay pending across sites (nothing is applied yet). Click 💾 Save removals to apply them all at once.');
        uibutton(rp,'Text','💾 Save removals (re-run)','ButtonPushedFcn',@(s,e) onSaveRemovals(), ...
            'Tooltip','Write ALL pending track removals to analysis/CS_trackedits.mat and re-run the mapper once — applies every marked removal across all sites in one go.');
        uibutton(rp,'Text','⇢ Export tracks for STEP','ButtonPushedFcn',@(s,e) onStepExport(), ...
            'Tooltip','Write analysis/step/step_tracks.csv (all member-track trajectories + inside-CS flags), then run drivers/run_step.py to get pointwise D(t)/α(t) (STEP or a rolling-window fallback).');
        uibutton(rp,'Text','⇠ Import STEP D(t)','ButtonPushedFcn',@(s,e) onStepImport(), ...
            'Tooltip','Read analysis/step/step_predictions.csv (from run_step.py) and report each member track''s diffusion INSIDE vs OUTSIDE the contact site — the motion change due to interaction.');
    end

    function onRunMapper()
        anaDir = ensureAnaDir(); if isempty(anaDir), lblSites.Text='Pick a project + build first.'; return; end
        if isempty(dir(fullfile(anaDir,'csIDs','*_CSsites.txt')))
            lblSites.Text='No csIDs/*_CSsites.txt — pick sites in the Contact-sites tab (Save) first.'; return; end
        % density source is LOCKED to the picker's (cs_window_mapper reads windows.source); the auto
        % contact site is half-max with the maxR/frac below. Refined sites (Refine tab) override per site.
        useRef = isempty(chkUseRefined) || ~isgraphics(chkUseRefined) || chkUseRefined.Value;
        opts = struct('footprintMode','halfmax','maxRadiusUm',eMaxR.Value, ...
            'fracHalfMax',eFrac.Value,'save',true,'verbose',false,'useRefined',useRef);
        lblSites.Text='Running mapper…'; drawnow;
        try, CSW = cs_window_mapper(anaDir, opts);
        catch ME, lblSites.Text=['Mapper error: ' ME.message]; return; end
        if isempty(CSW), lblSites.Text='Mapper found no sites (no cells matched TrackStruct?).'; return; end
        siteDensCache = struct('key',{},'dens',{},'raw',{}); DD = [];              % results changed -> invalidate caches
        if ~isempty(lblSitesSrc) && isgraphics(lblSitesSrc)
            lblSitesSrc.Text = ['density: ' srcLabel(CSW(1).densSrc) '  (from picker)'];
        end
        wl = unique([CSW.window]); ddWinFilt.Items = [{'All windows'}, arrayfun(@(w) sprintf('window %d',w), wl,'uni',0)];
        ddWinFilt.Value = 'All windows';
        fillSitesTable();
        nMito = nnz([CSW.MitoFlag]);
        nRef = nnz(cellfun(@(m) startsWith(char(m),'refined'), {CSW.footprintMode}));
        refTxt = ''; if nRef>0, refTxt = sprintf(' · %d refined', nRef); end
        lblSites.Text = sprintf('%d site-windows over %d window(s) · %d mito%s · median enrich %.2f — click a row to inspect / play.', ...
            numel(CSW), numel(wl), nMito, refTxt, median0_([CSW.enrichment]));
    end

    function fillSitesTable()
        if isempty(CSW), tblSites.Data = {}; siteRowMap = []; return; end
        keep = 1:numel(CSW);
        if ~isempty(ddWinFilt) && isgraphics(ddWinFilt) && ~strcmp(ddWinFilt.Value,'All windows')
            w = sscanf(ddWinFilt.Value,'window %d'); keep = find([CSW.window]==w);
        end
        siteRowMap = keep;
        % strings so counts/IDs show as integers (not 9.0000) and area/enrich keep sensible precision
        D = cell(numel(keep),7);
        for r = 1:numel(keep)
            e = CSW(keep(r));
            D(r,:) = {e.file, sprintf('%d',e.csID), sprintf('%d',e.window), tern(e.MitoFlag,'✓','–'), ...
                      sprintf('%.3f',e.areaUm2), sprintf('%d',e.nTracks), sprintf('%.2f',e.enrichment)};
        end
        tblSites.Data = D;
    end

    function onSiteSelect(e)
        if isempty(siteRowMap), return; end
        try, row = e.Indices(1); catch, return; end
        if row < 1 || row > numel(siteRowMap), return; end
        siteMemberSel = 0;                          % new site row -> clear the member-track selection
        drawSiteInspector(siteRowMap(row));
    end

    function drawSiteInspector(k)
        if k < 1 || k > numel(CSW), return; end
        if ~ensureTracksLoaded(), lblSites.Text='TrackStruct not loaded.'; return; end
        siteSelIdx = k;
        e = CSW(k); SF = e.SF; g = e.grid; cUm = e.center;
        Dens = siteDensity(e);
        cla(axSite);
        if ~isempty(Dens)
            imagesc(axSite, [SF g*SF], [SF g*SF], Dens);   % µm extent; imagesc keeps YDir reverse (image convention)
            colormap(axSite, turbo);
            pk = max(Dens(:)); if pk>0, clim(axSite,[0 pk]); end
        end
        axis(axSite,'image'); hold(axSite,'on');
        bx = e.refboundary(:,1)+cUm(1); by = e.refboundary(:,2)+cUm(2);       % contact-site outline, abs µm
        plot(axSite, bx, by, '-','Color',[1 1 1],'LineWidth',1.6);
        % per-track %-localization-inside + the ≥% filter (dwelling vs passing-through)
        [pctv, ninv, ntotv] = siteTrackStats(e);
        minPct = 0; if ~isempty(eMinPctIn) && isgraphics(eMinPctIn), minPct = eMinPctIn.Value; end
        keepT = true(1,numel(e.tracks)); if ~isempty(pctv), keepT = pctv >= minPct; end
        for jj = 1:numel(e.tracks)                                            % member-track trails (filtered)
            if ~keepT(jj), continue; end
            x = e.CSmatrix(:,jj,2)+cUm(1); y = e.CSmatrix(:,jj,3)+cUm(2); ok = isfinite(x)&isfinite(y);
            if nnz(ok)<2, continue; end
            if isPendRemoved(e, e.tracks(jj))                                 % marked for removal -> red
                plot(axSite, x(ok), y(ok), '-','Color',[1 0.12 0.12],'LineWidth',1.6);
            elseif e.tracks(jj)==siteMemberSel                               % highlight the selected member track
                plot(axSite, x(ok), y(ok), '-','Color',[0.1 1 1],'LineWidth',2.0);
                plot(axSite, x(ok), y(ok), 'o','Color',[0.1 1 1],'MarkerSize',3,'MarkerFaceColor',[0.1 1 1]);
            else
                plot(axSite, x(ok), y(ok), '-','Color',[1 0.95 0.3 0.55],'LineWidth',0.5);
            end
        end
        plot(axSite, cUm(1), cUm(2), '+','Color',[1 0 1],'MarkerSize',13,'LineWidth',1.6);
        hold(axSite,'off');
        pad = max(0.6, 1.4*sqrt(max(e.areaUm2,eps)/pi));
        xlim(axSite,[min(bx)-pad max(bx)+pad]); ylim(axSite,[min(by)-pad max(by)+pad]);
        xlabel(axSite,'x (µm)'); ylabel(axSite,'y (µm)');
        if minPct>0, ftag = sprintf(' · %d/%d trk ≥%g%% in', nnz(keepT), e.nTracks, minPct); else, ftag = ''; end
        title(axSite, sprintf('cell %d · site %d · win %d [%g–%g] · cloud %d locs · %d tracked (%d trk)%s · enrich %.2f', ...
            e.cellIndex, e.csID, e.window, e.winFrames(1), e.winFrames(2), e.nLocInside, e.nMemberLocs, e.nTracks, ftag, e.enrichment));
        % member list: track · locs inside / the track's window locs (% inside), filtered by ≥% threshold
        kidx = find(keepT);
        items = cell(1,numel(kidx)); tdata = zeros(1,numel(kidx));
        for m = 1:numel(kidx)
            jj = kidx(m);
            extra = '';
            sr = stepForTrack(e.file, e.csID, e.window, e.tracks(jj));   % STEP D outside->inside, if imported
            if ~isempty(sr) && isfinite(sr.Din) && isfinite(sr.Dout), extra = sprintf(' · D %.2g→%.2g', sr.Dout, sr.Din); end
            pre = ''; if isPendRemoved(e, e.tracks(jj)), pre = '🗑 '; end   % pending removal marker
            items{m} = sprintf('%strack %d · %d/%d in (%.0f%%)%s', pre, e.tracks(jj), ninv(jj), ntotv(jj), pctv(jj), extra);
            tdata(m) = e.tracks(jj);
        end
        if isempty(items)
            if e.nTracks>0 && minPct>0
                items = {sprintf('(no member tracks ≥ %g%% inside — lower the ≥%% in filter)', minPct)};
            elseif e.nLocInside > 0
                items = {sprintf('(no tracked tracks — %d untracked locs)', e.nLocInside), 'immobile/blinking spot that', 'never linked into a curated track'};
            else
                items = {'(no localizations in footprint)'};
            end
            lstMembers.Items = items; lstMembers.ItemsData = [];
        else
            lstMembers.Items = items; lstMembers.ItemsData = tdata;   % select -> track column
            if siteMemberSel>0 && any(tdata==siteMemberSel), lstMembers.Value = siteMemberSel; end
        end
    end

    function [pct, nin, ntot] = siteTrackStats(e)
        % Per member track: locs inside the contact site / the track's localizations present in the window,
        % and the % inside. Uses the mapper-stored fields if present (older CSW re-computes from CSmatrix).
        n = numel(e.tracks); pct = zeros(1,n); nin = zeros(1,n); ntot = zeros(1,n);
        if n==0, return; end
        if isfield(e,'trackPctInside') && numel(e.trackPctInside)==n && ...
           isfield(e,'trackLocsInside') && numel(e.trackLocsInside)==n && isfield(e,'trackLocsWin') && numel(e.trackLocsWin)==n
            pct = e.trackPctInside(:)'; nin = e.trackLocsInside(:)'; ntot = e.trackLocsWin(:)'; return;
        end
        for jj = 1:n
            fr = e.CSmatrix(:,jj,1); x = e.CSmatrix(:,jj,2); y = e.CSmatrix(:,jj,3);
            inw = fr>=e.winFrames(1) & fr<=e.winFrames(2); if all(isinf(e.winFrames)), inw = isfinite(fr); end
            ntot(jj) = nnz(inw & isfinite(x) & isfinite(y));
            nin(jj)  = nnz(inpolygon(x,y,e.refboundary(:,1),e.refboundary(:,2)) & inw & isfinite(x));
        end
        pct = 100 * nin ./ max(ntot,1);
    end

    function onMinPctIn()
        if siteSelIdx>=1 && siteSelIdx<=numel(CSW), drawSiteInspector(siteSelIdx); end
    end

    function onStepExport()
        % Write member-track trajectories (+ inside-CS flags) for the STEP pointwise-diffusion bridge.
        if isempty(CSW), lblSites.Text='Run the mapper first — no sites to export.'; return; end
        anaDir = fullfile(projectDir,'analysis'); if ~isfolder(anaDir), lblSites.Text='No analysis/ folder in the project.'; return; end
        if exist('cs_step_export','file')~=2, lblSites.Text='cs_step_export.m not on the path (drivers/).'; return; end
        try
            f = cs_step_export(CSW, anaDir);
            lblSites.Text = sprintf('Exported → %s . Now run:  python3 %s/tool2_analyze/drivers/run_step.py --in "%s" --out "%s"', ...
                f, spRoot(), f, fullfile(anaDir,'step','step_predictions.csv'));
        catch ME, lblSites.Text = ['STEP export failed: ' ME.message]; end
    end

    function onStepImport()
        % Read run_step.py's predictions -> per-track D INSIDE vs OUTSIDE the contact site (motion change).
        anaDir = fullfile(projectDir,'analysis');
        if ~isfile(fullfile(anaDir,'step','step_predictions.csv'))
            lblSites.Text = 'No step_predictions.csv yet — Export tracks, then run run_step.py.'; return; end
        if exist('cs_step_import','file')~=2, lblSites.Text='cs_step_import.m not on the path (drivers/).'; return; end
        try
            stepRes = cs_step_import(anaDir);
            rat = [stepRes.ratio]; rat = rat(isfinite(rat) & rat>0);
            din = median([stepRes.Din],'omitnan'); dout = median([stepRes.Dout],'omitnan');
            meth = ''; if ~isempty(stepRes) && isfield(stepRes,'method'), meth = stepRes(1).method; end
            lblSites.Text = sprintf('STEP (%s): %d tracks · median D inside %.3g vs outside %.3g µm²/s (ratio %.2f · %d/%d slower inside). Click a site for per-track.', ...
                meth, numel(stepRes), din, dout, median(rat), nnz(rat<1), numel(rat));
            if siteSelIdx>=1 && siteSelIdx<=numel(CSW), drawSiteInspector(siteSelIdx); end
        catch ME, lblSites.Text = ['STEP import failed: ' ME.message]; end
    end

    function e = stepForTrack(base, csID, win, col)   % find the imported STEP result for a member track, or []
        e = [];
        if isempty(stepRes), return; end
        for q = 1:numel(stepRes)
            if stepRes(q).csID==csID && stepRes(q).window==win && stepRes(q).trackCol==col && strcmp(char(stepRes(q).file),char(base))
                e = stepRes(q); return;
            end
        end
    end

    function r = spRoot()   % repo root for the run_step.py hint
        r = fileparts(fileparts(fileparts(mfilename('fullpath'))));   % .../SPTinMatlab
    end

    function onMemberSelect()
        v = lstMembers.Value;
        if isempty(v) || ~isnumeric(v), return; end
        siteMemberSel = v;                          % track column
        drawSiteInspector(siteSelIdx);              % redraw with the highlight (keeps siteMemberSel)
    end

    function onPlaySite()
        % Play the selected site's member tracks over the raw SPT movie (one colour per track).
        if isempty(sitePlayer) || ~isstruct(sitePlayer), return; end
        if siteSelIdx < 1 || siteSelIdx > numel(CSW), lblSites.Text='Click a site row first.'; return; end
        e = CSW(siteSelIdx);
        if isempty(e.tracks)
            lblSites.Text = sprintf('Site %d has no tracked trajectories (it sits on %d untracked detections) — nothing to play.', e.csID, e.nLocInside);
            try, sitePlayer.load([],[]); catch, end; return;
        end
        % apply the ≥% inside filter: play only the dwelling member tracks
        pctv = siteTrackStats(e); minPct = 0; if ~isempty(eMinPctIn) && isgraphics(eMinPctIn), minPct = eMinPctIn.Value; end
        keptCols = e.tracks; if ~isempty(pctv), keptCols = e.tracks(pctv >= minPct); end
        if isempty(keptCols)
            lblSites.Text = sprintf('No member track has ≥ %g%% of its localizations inside — lower the ≥%% in filter.', minPct); return;
        end
        R = buildSiteR(e);
        if isempty(R)
            lblSites.Text = sprintf('Raw SPT movie not found for cell %s — cannot play (set the project''s spt/ folder).', e.file); return;
        end
        try, sitePlayer.load(R, unique(keptCols(:)')); catch ME, lblSites.Text = ['Player error: ' ME.message]; return; end
        lblSites.Text = sprintf('Playing site %d: %d of %d member track(s) (≥%g%% inside) over %s.', e.csID, numel(keptCols), numel(e.tracks), minPct, e.file);
    end

    function onPlaySiteOne()
        % Play ONLY the member track selected in the list, over the raw SPT movie.
        if isempty(sitePlayer) || ~isstruct(sitePlayer), return; end
        if siteSelIdx < 1 || siteSelIdx > numel(CSW), lblSites.Text='Click a site row first.'; return; end
        if siteMemberSel < 1, lblSites.Text='Click a member track in the list first.'; return; end
        e = CSW(siteSelIdx);
        R = buildSiteR(e, siteMemberSel);
        if isempty(R), lblSites.Text = sprintf('Cannot play track %d (raw SPT movie for %s not found).', siteMemberSel, e.file); return; end
        try, sitePlayer.load(R, unique(R.trackId(:)')); catch ME, lblSites.Text = ['Player error: ' ME.message]; return; end
        lblSites.Text = sprintf('Playing track %d only, at site %d over %s.', siteMemberSel, e.csID, e.file);
    end

    function onDeleteTrack()
        % TOGGLE the selected member track's removal — kept in a pending set (across sites), marked RED
        % in the list + on the density, and NOT applied until 💾 Save removals writes them all + re-runs.
        if siteSelIdx < 1 || siteSelIdx > numel(CSW), lblSites.Text='Click a site row first.'; return; end
        if siteMemberSel < 1, lblSites.Text='Click a member track in the list to mark it.'; return; end
        e = CSW(siteSelIdx);
        ppx = e.center/e.SF; if isfield(e,'pickPx') && numel(e.pickPx)==2, ppx = e.pickPx; end   % original detection pick
        dup = arrayfun(@(x) strcmp(x.file,e.file)&&x.csID==e.csID&&x.window==e.window&&x.trackCol==siteMemberSel, pendExcl);
        if any(dup), pendExcl(dup) = []; act = 'unmarked';
        else, pendExcl(end+1) = struct('file',e.file,'csID',e.csID,'window',e.window,'pickPx',ppx,'trackCol',siteMemberSel); act = 'marked for removal'; end
        drawSiteInspector(siteSelIdx);
        lblSites.Text = sprintf('Track %d %s at site %d · %d track(s) pending. Click 💾 Save removals to apply all.', siteMemberSel, act, e.csID, numel(pendExcl));
    end

    function tf = isPendRemoved(e, col)   % is this member track marked (pending) for removal?
        tf = ~isempty(pendExcl) && any(arrayfun(@(x) strcmp(x.file,e.file)&&x.csID==e.csID&&x.window==e.window&&x.trackCol==col, pendExcl));
    end

    function onSaveRemovals()
        % Write ALL pending removals into CS_trackedits.mat (merged) and re-run the mapper once to apply.
        if isempty(pendExcl), lblSites.Text='No tracks marked for removal — mark some first (🗑).'; return; end
        anaDir = ensureAnaDir(); if isempty(anaDir), return; end
        f = fullfile(anaDir,'CS_trackedits.mat');
        CSexclude = struct('file',{},'csID',{},'window',{},'pickPx',{},'trackCol',{});
        if isfile(f), try, L=load(f); if isfield(L,'CSexclude'), CSexclude=L.CSexclude; end, catch, end, end
        for q = 1:numel(pendExcl)
            r = pendExcl(q);
            dup = arrayfun(@(x) strcmp(x.file,r.file)&&x.csID==r.csID&&x.window==r.window&&x.trackCol==r.trackCol, CSexclude);
            if ~any(dup), CSexclude(end+1) = r; end %#ok<AGROW>
        end
        try, save(f,'CSexclude','-v7.3'); catch ME, lblSites.Text=['Save failed: ' ME.message]; return; end
        np = numel(pendExcl); pendExcl(:) = [];
        lblSites.Text = sprintf('Saved %d removal(s) → re-running the mapper to apply…', np); drawnow;
        onRunMapper();   % rebuild CSW_final.mat once, without every removed track
    end

    function R = buildSiteR(e, onlyCols)
        % Build a spt_track_movie R struct from a site's member tracks (all, or only onlyCols). CSmatrix
        % is µm RELATIVE to the site centre → absolute µm (+centre) → raw-movie pixels (x = X/PXUM + 1).
        if nargin<2, onlyCols = []; end
        R = [];
        [sp,er,mi] = matchedPaths(e.file);
        if isempty(sp) || ~isfile(sp), return; end
        dtc = trackDt(e.cellIndex); secs = secsMode();
        cx = e.center(1); cy = e.center(2);
        xAll=[]; yAll=[]; fAll=[]; idAll=[];
        for jj = 1:numel(e.tracks)
            if ~isempty(onlyCols) && ~ismember(e.tracks(jj), onlyCols), continue; end
            fr = e.CSmatrix(:,jj,1); x = e.CSmatrix(:,jj,2)+cx; y = e.CSmatrix(:,jj,3)+cy;
            keep = isfinite(x) & isfinite(y) & isfinite(fr);
            if ~any(keep), continue; end
            if secs, f0 = round(fr(keep)/max(dtc,eps)); else, f0 = round(fr(keep)); end
            xAll = [xAll; x(keep)/PXUM + 1]; yAll = [yAll; y(keep)/PXUM + 1]; %#ok<AGROW>
            fAll = [fAll; f0(:)]; idAll = [idAll; e.tracks(jj)*ones(nnz(keep),1)]; %#ok<AGROW>
        end
        if isempty(xAll), return; end
        csPx = [];   % contact-site outline in raw-movie pixels (same µm->px map) — overlaid via the player's CS toggle
        if isfield(e,'refboundary') && size(e.refboundary,1)>=3
            csPx = [(e.refboundary(:,1)+cx)/PXUM + 1, (e.refboundary(:,2)+cy)/PXUM + 1];
        end
        R = struct('base',e.file,'sptPath',sp,'erPath',er,'mitoPath',mi, ...
                   'x',xAll,'y',yAll,'frame',fAll,'trackId',idAll,'csPolyPx',csPx);
    end

    function Dens = siteDensity(e)
        Dens = windowDens(e.cellIndex, e.winFrames, e.SF, e.grid, e.densSrc);
    end

    function [Dens, Raw] = windowDens(ci, winFrames, SF, grid, src)
        % Smoothed density + raw counts for a window (cached per cell/window/src/grid). Raw feeds the
        % locs/bin colour scale and the significance (Monte-Carlo) null.
        Dens = []; Raw = [];
        key = sprintf('%d|%g|%g|%s|%d', ci, winFrames(1), winFrames(2), src, grid);
        for i = 1:numel(siteDensCache)
            if strcmp(siteDensCache(i).key,key), Dens = siteDensCache(i).dens; Raw = siteDensCache(i).raw; return; end
        end
        if isempty(buildTracks) || ci < 1 || ci > numel(buildTracks), return; end
        T = buildTracks(ci);
        if strcmp(src,'tracked')
            sX = reshape(T.matrix(:,:,2),[],1); sY = reshape(T.matrix(:,:,3),[],1); sF = reshape(T.matrix(:,:,1),[],1);
        else
            a = T.allSpots; sX = a.X(:); sY = a.Y(:); sF = a.FRAME(:);
        end
        try, [Raw,Dens] = cs_window_density(sX,sY,sF, winFrames(1), winFrames(2), SF, grid, grid, 8); catch, Dens = []; Raw = []; end
        if ~isempty(Dens), siteDensCache(end+1) = struct('key',key,'dens',Dens,'raw',Raw); end   % never cache a transient failure
    end

    function erGrid = erGridForCell(ci, g)
        % Cell ER support (occupancy>0 = ER present in ≥1 sampled frame) resampled to the g×g density
        % grid as a logical mask. Cached per (cell,g). Registration is internally consistent with the
        % density: the seg and the density grid both span the full FOV, so imresize aligns them, and
        % downstream we index it with the SAME round(µm/SF) transform the density uses.
        erGrid = [];
        if isempty(buildTracks) || ci<1 || ci>numel(buildTracks), return; end
        key = sprintf('%d|%d', ci, g);
        for i = 1:numel(refErCache), if strcmp(refErCache(i).key,key), erGrid = refErCache(i).erGrid; return; end, end
        occ = [];
        try, s = occupancyFor(char(buildTracks(ci).file)); occ = s.er; catch, end
        if isempty(occ), return; end
        try, erGrid = imresize(occ > 0, [g g], 'nearest'); catch, erGrid = []; end
        if ~isempty(erGrid), refErCache(end+1) = struct('key',key,'erGrid',erGrid); end
    end

    function en = erNullForSite(ci, SF, g, cUm, Lx, Ly, Rwin)
        % Cell-wide ER-uniform null for the radial plot (replaces the disk-uniform baseline): the
        % expected radial count IF this loc set were spread uniformly over ALL the cell's ER at the
        % cell-average density. rho = (locs over ER, cell-wide) / (total cell ER area); Acum(r) = ER
        % area within r of the site centre. Both from the cell ER mask on the density grid.
        en = [];
        erGrid = erGridForCell(ci, g);
        if isempty(erGrid) || ~any(erGrid(:)), return; end
        px2 = SF^2;
        A_ER_cell = nnz(erGrid) * px2;                       % total cell ER area (µm²)
        nOnER = 0;                                           % this loc set's localizations that land on ER
        if ~isempty(Lx)
            col = round(Lx(:)/SF); row = round(Ly(:)/SF);
            ok = isfinite(col) & isfinite(row) & col>=1 & col<=g & row>=1 & row<=g;
            if any(ok), nOnER = nnz(erGrid(sub2ind([g g], row(ok), col(ok)))); end
        end
        rho = nOnER / max(A_ER_cell, eps);                   % localizations per µm² of ER, cell-wide
        [er, ec] = find(erGrid);                             % row=Y px, col=X px of every ER pixel
        dpx = hypot(ec*SF - cUm(1), er*SF - cUm(2));         % µm distance of each ER px to the site centre
        ds  = sort(dpx(dpx <= Rwin));                        % only ER px within the window matter for A_ER(r)
        rVec = linspace(0, Rwin, 60)';
        Acum = arrayfun(@(rr) sum(ds <= rr), rVec) * px2;    % ER area (µm²) within each radius of the centre
        if rho <= 0 || Acum(end) <= 0, return; end           % no ER density / no ER near this site -> disk-null fallback
        en = struct('r', rVec, 'Acum', Acum, 'rho', rho);
    end

    function [tracks, CSmatrix] = footTrackMembers(ci, winFrames, center, refb)
        % Live tracked-membership preview for the Refine editor (same test the mapper uses).
        tracks = []; CSmatrix = [];
        if isempty(buildTracks) || ci < 1 || ci > numel(buildTracks), return; end
        M = buildTracks(ci).matrix; Frame = M(:,:,1); A = M(:,:,2); B = M(:,:,3);
        Ar = A-center(1); Br = B-center(2); okxy = isfinite(A)&isfinite(B);
        inP = false(size(A)); inP(okxy) = inpolygon(Ar(okxy), Br(okxy), refb(:,1), refb(:,2));
        if isinf(winFrames(1))&&isinf(winFrames(2)), inW = true(size(Frame)); else, inW = Frame>=winFrames(1)&Frame<=winFrames(2); end
        mn = inP & inW & okxy; tracks = find(sum(mn,1));
        CSmatrix = cat(3, Frame(:,tracks), A(:,tracks)-center(1), B(:,tracks)-center(2));
    end

    % ================= Tab 6 · Dwell (residence times + per-window escape rate k_out(w)) =================
    function buildDwellTab(parent)
        g = uigridlayout(parent,[2 1],'RowHeight',{34,'1x'},'Padding',[10 10 10 10],'RowSpacing',6);
        r = uigridlayout(g,[1 3],'ColumnWidth',{170,'1x',0},'Padding',[0 0 0 0],'ColumnSpacing',8);
        uibutton(r,'Text','▶ Compute dwell','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70],'FontColor','w', ...
            'Tooltip','Residence of each member track in its site''s own window (span+1 accounting) -> analysis/cs_window_dwell.csv.', ...
            'ButtonPushedFcn',@(s,e) onComputeDwell());
        lblDwell = uilabel(r,'Text','Run the mapper (Sites tab) first, then Compute dwell.','FontColor',[0.2 0.4 0.5]);
        uilabel(r,'Text','');
        mn = uigridlayout(g,[1 2],'ColumnWidth',{'1x','1x'},'Padding',[0 0 0 0],'ColumnSpacing',8);
        lc = uigridlayout(mn,[2 1],'RowHeight',{'1.4x','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
        axDwHist = uiaxes(lc); title(axDwHist,'dwell-time distribution');
        axKout   = uiaxes(lc); title(axKout,'escape rate k_{out}(window)');
        rc = uigridlayout(mn,[3 1],'RowHeight',{'0.9x','1x',30},'Padding',[0 0 0 0],'RowSpacing',6);
        tblDwell = uitable(rc,'ColumnName',{'cell','site','win','track','class','#','longest s','total s'}, ...
            'ColumnWidth',{'auto',40,36,44,88,32,62,56},'SelectionType','row', ...
            'CellSelectionCallback',@(s,e) onDwellSelect(e));
        bc = uigridlayout(rc,[1 2],'ColumnWidth',{'1x','1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
        axDwDens = uiaxes(bc); title(axDwDens,'track on contact-site density (click a row)'); axDwDens.Toolbar.Visible='off'; axDwDens.Tag='dwDens';
        axDwTrace = uiaxes(bc); title(axDwTrace,'distance-to-centre vs frame');
        % animation controls for the density panel: play the track over the density + ER/mito overlay + save video
        ac = uigridlayout(rc,[1 11],'ColumnWidth',{58,'1x',124,30,42, 52,52, 26,46, 84,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
        btnDwPlay = uibutton(ac,'Text','▶ Play','Tag','dwPlay','ButtonPushedFcn',@(s,e) onDwellPlay(), ...
            'Tooltip','Animate the selected track over the chosen backdrop (with the ER/mito overlay).');
        sldDwFrame = uislider(ac,'Limits',[0 1],'Value',0,'Tag','dwFrame','MajorTicks',[],'MinorTicks',[], ...
            'ValueChangedFcn',@(s,e) onDwellScrub(), 'Tooltip','Scrub through the track''s frames.');
        ddDwBg = uidropdown(ac,'Items',{'density (accumulated)','raw movie'},'Value','density (accumulated)','Tag','dwBg', ...
            'Tooltip','Backdrop: the accumulated localization density (shows the site + dwell context) or the raw SPT movie frame-by-frame (the actual data). The contact-site outline + dwell colouring + ER/mito overlay draw on either.', ...
            'ValueChangedFcn',@(s,e) onDwellBg());
        chkDwEr   = uicheckbox(ac,'Text','ER','Value',false,'Tag','dwEr','ValueChangedFcn',@(s,e) dwellRedraw(), 'Tooltip','Overlay the ER segmentation (green) at the current frame.');
        chkDwMito = uicheckbox(ac,'Text','mito','Value',true,'Tag','dwMito','ValueChangedFcn',@(s,e) dwellRedraw(), 'Tooltip','Overlay the mitochondria segmentation (magenta) at the current frame.');
        uilabel(ac,'Text','contrast','HorizontalAlignment','right','FontSize',10);
        eDwContrast = uispinner(ac,'Limits',[0.05 1],'Value',0.7,'Step',0.05,'Tag','dwContrast', ...
            'Tooltip','Display contrast for the backdrop — clips the bright end (LOWER = brighter). Handy for dark raw movies.', ...
            'ValueChangedFcn',@(s,e) onDwellContrast());
        uilabel(ac,'Text','fps','HorizontalAlignment','right','FontSize',10);
        eDwFps = uispinner(ac,'Limits',[1 60],'Value',10,'Step',1,'Tag','dwFps','Tooltip','Playback frames per second.');
        uibutton(ac,'Text','🎥 Save video…','Tag','dwSave','ButtonPushedFcn',@(s,e) onDwellSaveVideo(), ...
            'Tooltip','Render this track''s animation (over the chosen backdrop + ER/mito overlay) to an MP4/AVI.');
        lblDwAnim = uilabel(ac,'Text','','FontColor',[0.35 0.35 0.42]);
    end

    function onComputeDwell()
        anaDir = ensureAnaDir(); if isempty(anaDir), lblDwell.Text='Pick a project first.'; return; end
        if ~ensureCSWloaded(), lblDwell.Text='Run the mapper (Sites tab) first — no CSW_final.mat.'; return; end
        lblDwell.Text='Computing dwell…'; drawnow;
        try, DD = cs_window_dwell(anaDir, struct('save',true,'verbose',false));
        catch ME, lblDwell.Text=['Dwell error: ' ME.message]; return; end
        drawDwell();
    end

    function drawDwell()
        if isempty(DD) || ~isfield(DD,'allDwell'), return; end
        d = DD.allDwell; d = d(isfinite(d)&d>0);
        cla(axDwHist);
        if ~isempty(d)
            histogram(axDwHist, d, min(50,max(6,round(numel(d)/8))), 'FaceColor',[0.4 0.55 0.8],'EdgeColor','none');
            try, set(axDwHist,'YScale','log'); catch, end
        end
        xlabel(axDwHist,'dwell (s)'); ylabel(axDwHist,'events'); title(axDwHist, sprintf('dwell-time distribution (median %.3g s, n=%d)', median0_(d), numel(d)));
        % k_out per window
        pw = DD.perWindow; cla(axKout);
        if ~isempty(pw)
            w = [pw.window]; k = [pw.kout_w];
            bar(axKout, w, k, 0.6, 'FaceColor',[0.7 0.4 0.3],'EdgeColor','none');
            xlabel(axKout,'window'); ylabel(axKout,'k_{out} (1/s)');
            title(axKout, sprintf('escape rate per window (pooled %.2f /s)', numel(d)/max(sum(d),eps)));
            xticks(axKout, w);
        end
        % per-track table (with the contact-site id, so each row is traceable to cell·site·win·track)
        pt = DD.perTrack; dwellRowMap = 1:numel(pt);
        uid2cs = containers.Map('KeyType','double','ValueType','double');   % siteUID -> csID (robust to old DD w/o csID)
        if isfield(DD,'perSite') && ~isempty(DD.perSite)
            for q = 1:numel(DD.perSite), uid2cs(DD.perSite(q).siteUID) = DD.perSite(q).csID; end
        end
        T = cell(numel(pt),8);
        for i = 1:numel(pt)
            if isfield(pt,'csID') && ~isempty(pt(i).csID), cs = pt(i).csID;
            elseif isKey(uid2cs, pt(i).siteUID),            cs = uid2cs(pt(i).siteUID);
            else,                                           cs = NaN; end
            csStr = '—'; if isfinite(cs), csStr = sprintf('%d', cs); end
            T(i,:) = {sprintf('%d',pt(i).cellIndex), csStr, sprintf('%d',pt(i).window), sprintf('%d',pt(i).trackCol), ...
                      pt(i).label, sprintf('%d',pt(i).numDwell), sprintf('%.3g',pt(i).longest_s), sprintf('%.3g',pt(i).total_s)};
        end
        tblDwell.Data = T;
        lblDwell.Text = sprintf('%d events · %d member-tracks · median dwell %.3g s · pooled k_out %.2f /s — click a row for its trace.', ...
            numel(DD.events), numel(pt), median0_(d), numel(d)/max(sum(d),eps));
    end

    function onDwellSelect(e)
        if isempty(DD) || isempty(dwellRowMap), return; end
        try, row = e.Indices(1); catch, return; end
        if row < 1 || row > numel(dwellRowMap), return; end
        pt = DD.perTrack(dwellRowMap(row));
        if ~ensureCSWloaded(), return; end
        idx = find([CSW.siteUID]==pt.siteUID,1); if isempty(idx), return; end
        ee = CSW(idx); jj = find(ee.tracks==pt.trackCol,1); if isempty(jj), return; end
        cUm = ee.center;
        fr = ee.CSmatrix(:,jj,1); xr = ee.CSmatrix(:,jj,2); yr = ee.CSmatrix(:,jj,3);   % µm rel centre
        ok = isfinite(fr)&isfinite(xr)&isfinite(yr); fr=fr(ok); xr=xr(ok); yr=yr(ok);
        rdist = hypot(xr,yr);                                % distance to contact-site centre (µm)
        inside = inpolygon(xr,yr,ee.refboundary(:,1),ee.refboundary(:,2));
        inw = fr>=ee.winFrames(1) & fr<=ee.winFrames(2); if all(isinf(ee.winFrames)), inw=true(size(fr)); end
        ii = inside & inw;

        % (1) prepare + draw the ANIMATED "track on contact-site density" panel (Play/scrub/overlay/video)
        dwellStopTimer();
        dwellPrepare(ee, pt, fr, xr+cUm(1), yr+cUm(2), ii, cUm);

        % (2) distance-to-centre vs frame with the dwell frames marked
        cla(axDwTrace); hold(axDwTrace,'on');
        plot(axDwTrace, fr, rdist, '-','Color',[0.6 0.6 0.7],'LineWidth',0.6);
        plot(axDwTrace, fr(ii), rdist(ii), 'o','MarkerFaceColor',[0.85 0.2 0.3],'MarkerEdgeColor','none','MarkerSize',4);
        plot(axDwTrace, fr(~ii), rdist(~ii), 'o','MarkerFaceColor',[0.6 0.6 0.7],'MarkerEdgeColor','none','MarkerSize',3);
        hold(axDwTrace,'off');
        xlabel(axDwTrace,'frame'); ylabel(axDwTrace,'dist to centre (µm)');
        title(axDwTrace, sprintf('cell %d track %d @ site %d (win %d) · %s · %d in / %d total', ...
            pt.cellIndex, pt.trackCol, ee.csID, pt.window, pt.label, nnz(ii), numel(fr)));
    end

    % ---- Dwell density animator: play the selected track over the contact-site density + ER/mito overlay ----
    function dwellPrepare(ee, pt, fr, xa, ya, ii, cUm)
        dwellAnim = [];
        if isempty(axDwDens) || ~isgraphics(axDwDens) || numel(fr) < 1, return; end
        if ~ensureTracksLoaded(), return; end
        SF = ee.SF; g = ee.grid;
        Dens = windowDens(ee.cellIndex, ee.winFrames, SF, g, ee.densSrc);
        bx = ee.refboundary(:,1)+cUm(1); by = ee.refboundary(:,2)+cUm(2);
        pad = max(0.6, 1.4*sqrt(max(ee.areaUm2,eps)/pi));
        ov = struct('er','','mito',''); try, ov = resolveOverlay(ee.file); catch, end
        bg = 'density (accumulated)'; if ~isempty(ddDwBg) && isgraphics(ddDwBg), bg = ddDwBg.Value; end
        da = struct('cUm',cUm,'bx',bx,'by',by,'dens',Dens,'SF',SF,'grid',g, ...
            'xa',xa(:),'ya',ya(:),'fr',fr(:),'ii',logical(ii(:)),'n',numel(fr), ...
            'xlim',[min(bx)-pad max(bx)+pad],'ylim',[min(by)-pad max(by)+pad], ...
            'erPath',ov.er,'mitoPath',ov.mito,'sptPath',ov.spt,'cellIndex',ee.cellIndex, ...
            'backdrop',bg,'rawH',[],'rawW',[],'rawN',0,'rawLo',[],'rawHi',[], ...
            'orgCache',containers.Map('KeyType','double','ValueType','any'), ...
            'name',sprintf('cell%d_track%d_site%d_win%d', ee.cellIndex, pt.trackCol, ee.csID, pt.window), ...
            'title',sprintf('track %d on site %d', pt.trackCol, ee.csID), ...
            'i',numel(fr),'timer',[],'playing',false, ...
            'h',struct('bg',gobjects(0),'trail',[],'dwell',[],'head',[],'org',gobjects(0)));
        dwellAnim = da;
        dwellDrawStatic();
        n = da.n;
        if ~isempty(sldDwFrame) && isgraphics(sldDwFrame)
            if n>1, sldDwFrame.Limits=[1 n]; else, sldDwFrame.Limits=[1 2]; end
            sldDwFrame.Value = min(max(n,1), sldDwFrame.Limits(2));
        end
        haveMito = ~isempty(da.mitoPath) && isfile(da.mitoPath);
        haveEr   = ~isempty(da.erPath)   && isfile(da.erPath);
        if ~isempty(chkDwMito) && isgraphics(chkDwMito), chkDwMito.Enable=tern(haveMito,'on','off'); if ~haveMito, chkDwMito.Value=false; end, end
        if ~isempty(chkDwEr)   && isgraphics(chkDwEr),   chkDwEr.Enable=tern(haveEr,'on','off');     if ~haveEr,   chkDwEr.Value=false;   end, end
        dwellRedraw(n);
        if ~isempty(lblDwAnim) && isgraphics(lblDwAnim)
            lblDwAnim.Text = sprintf('%d frames%s', n, tern(haveMito||haveEr,'',' · no ER/mito seg'));
        end
    end

    function dwellDrawStatic()
        da = dwellAnim; if isempty(da) || ~isgraphics(axDwDens), return; end
        ax = axDwDens; cla(ax); da.h.bg = gobjects(0);
        rawOn = strcmp(da.backdrop,'raw movie') && ~isempty(da.sptPath) && isfile(da.sptPath);
        if rawOn
            % per-frame raw SPT backdrop (image filled in dwellRedraw); µm extent so track/outline register
            try, info = imfinfo(da.sptPath); da.rawH = info(1).Height; da.rawW = info(1).Width; da.rawN = numel(info); catch, da.rawH = []; end
            if ~isempty(da.rawH)
                da.h.bg = imagesc(ax, [0 (da.rawW-1)*PXUM], [0 (da.rawH-1)*PXUM], zeros(da.rawH,da.rawW)); colormap(ax,gray); da.rawLo = []; da.rawHi = [];
            end
        elseif ~isempty(da.dens)
            da.h.bg = imagesc(ax,[da.SF da.grid*da.SF],[da.SF da.grid*da.SF],da.dens); colormap(ax,turbo);
            c = dwContrastVal(); pk = max(da.dens(:)); if pk>0, clim(ax,[0 c*pk]); end
        end
        axis(ax,'image'); hold(ax,'on');
        plot(ax, da.bx, da.by, '-','Color',[1 1 1],'LineWidth',1.4);                                  % contact-site outline
        plot(ax, da.cUm(1), da.cUm(2), '+','Color',[1 0 1],'MarkerSize',11,'LineWidth',1.4);          % centre
        plot(ax, da.xa(1), da.ya(1), '>','Color',[0.2 1 0.2],'MarkerSize',7,'LineWidth',1.4);         % start
        plot(ax, da.xa(end), da.ya(end), 's','Color',[1 1 1],'MarkerSize',7,'LineWidth',1.4);         % end
        da.h.trail = plot(ax, nan, nan, '-','Color',[0.2 1 1],'LineWidth',1.3);
        da.h.dwell = plot(ax, nan, nan, 'o','MarkerFaceColor',[0.95 0.2 0.25],'MarkerEdgeColor','none','MarkerSize',4);
        da.h.head  = plot(ax, nan, nan, 'o','MarkerFaceColor',[1 1 0.2],'MarkerEdgeColor','k','MarkerSize',9,'LineWidth',1);
        da.h.org   = gobjects(0);
        xlim(ax,da.xlim); ylim(ax,da.ylim); xlabel(ax,'x (µm)'); ylabel(ax,'y (µm)');   % keep hold ON for per-frame org lines
        dwellAnim = da;
    end

    function onDwellBg()
        if isempty(dwellAnim) || ~isgraphics(axDwDens), return; end
        dwellStopTimer();
        dwellAnim.backdrop = ddDwBg.Value; dwellAnim.rawLo = []; dwellAnim.rawHi = [];
        dwellDrawStatic(); dwellRedraw(dwellAnim.i);
    end

    function c = dwContrastVal()
        c = 0.7; if ~isempty(eDwContrast) && isgraphics(eDwContrast), c = eDwContrast.Value; end
    end

    function dwellApplyContrast()
        % set the backdrop colour limits from the contrast control (raw: clip within the frame range;
        % density: clip at contrast·peak). Lower contrast = brighter.
        if isempty(dwellAnim) || ~isgraphics(axDwDens), return; end
        da = dwellAnim; c = dwContrastVal();
        if strcmp(da.backdrop,'raw movie')
            if ~isempty(da.rawLo) && ~isempty(da.rawHi) && da.rawHi>da.rawLo
                clim(axDwDens, [da.rawLo, da.rawLo + c*(da.rawHi-da.rawLo)]);
            end
        elseif ~isempty(da.dens)
            pk = max(da.dens(:)); if pk>0, clim(axDwDens,[0 c*pk]); end
        end
    end

    function onDwellContrast()
        dwellApplyContrast();
    end

    function dwellRedraw(i)
        if isempty(dwellAnim) || ~isgraphics(axDwDens), return; end
        da = dwellAnim; n = da.n; if n<1, return; end
        if nargin<1 || isempty(i), i = da.i; end                 % no-arg (checkbox toggle) -> redraw current frame
        i = max(1,min(round(i),n)); dwellAnim.i = i;
        % raw-movie backdrop: swap in the actual SPT frame at this track point
        if strcmp(da.backdrop,'raw movie') && ~isempty(da.h.bg) && isgraphics(da.h.bg) && ~isempty(da.sptPath)
            if secsMode(), pg = round(da.fr(i)/max(trackDt(da.cellIndex),eps)); else, pg = round(da.fr(i)); end
            pg = min(max(pg+1,1), max(da.rawN,1));
            try
                im = imread(da.sptPath, pg); if size(im,3)==3, im = rgb2gray(im); end
                set(da.h.bg, 'CData', double(im));
                if isempty(da.rawLo)
                    s = sort(double(im(:))); lo = s(1); hi = s(max(1,round(0.999*numel(s))));   % robust hi (99.9%) so hot pixels don't darken it
                    if hi<=lo, hi = lo+1; end
                    da.rawLo = lo; da.rawHi = hi; dwellAnim.rawLo = lo; dwellAnim.rawHi = hi;
                    dwellApplyContrast();
                end
            catch, end
        end
        set(da.h.trail,'XData',da.xa(1:i),'YData',da.ya(1:i));
        idIn = find(da.ii(1:i)); set(da.h.dwell,'XData',da.xa(idIn),'YData',da.ya(idIn));
        inHead = da.ii(i);
        set(da.h.head,'XData',da.xa(i),'YData',da.ya(i),'MarkerFaceColor',tern(inHead,[0.95 0.2 0.25],[1 1 0.2]));
        try, if ~isempty(da.h.org), delete(da.h.org(isgraphics(da.h.org))); end, catch, end
        oh = gobjects(0);
        showM = ~isempty(chkDwMito) && isgraphics(chkDwMito) && strcmp(chkDwMito.Enable,'on') && chkDwMito.Value;
        showE = ~isempty(chkDwEr)   && isgraphics(chkDwEr)   && strcmp(chkDwEr.Enable,'on')   && chkDwEr.Value;
        hold(axDwDens,'on');
        if showM, oh = addOrgFill(oh, dwellOrgMask(da,'mito',da.fr(i)), [1 0.25 1]);  end
        if showE, oh = addOrgFill(oh, dwellOrgMask(da,'er',  da.fr(i)), [0.2 1 0.35]); end
        % filled masks sit just ABOVE the backdrop but BELOW the outline/track (drop them to the
        % bottom, then push the backdrop below them) so the trajectory stays visible through the tint
        if ~isempty(oh)
            try, uistack(oh,'bottom'); if ~isempty(da.h.bg)&&isgraphics(da.h.bg), uistack(da.h.bg,'bottom'); end, catch, end
        end
        dwellAnim.h.org = oh;
        title(axDwDens, sprintf('%s · frame %d/%d%s', da.title, i, n, tern(inHead,' · INSIDE','')));
    end

    function m = dwellOrgMask(da, which, frameVal)
        % Cropped ER/mito mask + its µm extent at this track point's movie frame — for a FILLED overlay
        % (like the players' tint) rather than an outline. Cached in da.orgCache (a handle Map, shared
        % with dwellAnim). Registration: seg µm/px = FOVUM/seg width; frame→seg page = frame+1 (0-based;
        % seconds mode divides by dt first). No imfinfo here — walking all IFDs of the multi-thousand-
        % frame seg stack was the toggle/scrub hang; an out-of-range page just returns [] via the catch.
        m = [];
        if strcmp(which,'mito'), p = da.mitoPath; else, p = da.erPath; end
        if isempty(p) || ~isfile(p), return; end
        if secsMode(), fIdx = round(frameVal/max(trackDt(da.cellIndex),eps)); else, fIdx = round(frameVal); end
        segIdx = max(fIdx + 1, 1);
        keyv = segIdx*10 + tern(strcmp(which,'mito'),1,2);
        if isKey(da.orgCache,keyv), m = da.orgCache(keyv); return; end
        try
            im = imread(p, segIdx); if size(im,3)==3, im = rgb2gray(im); end
            v = unique(im(:)); nz = v(v>0); fg = 1; if ~isempty(nz), fg = double(min(nz)); end
            mask = (im == fg);
            segH = size(mask,1); segW = size(mask,2); ux = FOVUM/segW; uy = FOVUM/segH;
            c0 = max(1,floor(da.xlim(1)/ux)); c1 = min(segW,ceil(da.xlim(2)/ux));
            r0 = max(1,floor(da.ylim(1)/uy)); r1 = min(segH,ceil(da.ylim(2)/uy));
            if c1>c0 && r1>r0
                m = struct('mask', mask(r0:r1, c0:c1), 'xd',[c0*ux c1*ux], 'yd',[r0*uy r1*uy]);
            end
        catch, m = []; end
        da.orgCache(keyv) = m;    % orgCache is a handle Map → persists to dwellAnim
    end

    function oh = addOrgFill(oh, M, col)   % translucent filled mask overlay (ER/mito), like the players' tint
        if isempty(M) || ~any(M.mask(:)), return; end
        [hh,ww] = size(M.mask);
        rgb = cat(3, col(1)*ones(hh,ww), col(2)*ones(hh,ww), col(3)*ones(hh,ww));
        oh(end+1) = image(axDwDens, 'XData',M.xd, 'YData',M.yd, 'CData',rgb, 'AlphaData', double(M.mask)*0.42, 'HitTest','off'); %#ok<AGROW>
    end

    function onDwellPlay()
        if isempty(dwellAnim) || dwellAnim.n < 2, if ~isempty(lblDwAnim)&&isgraphics(lblDwAnim), lblDwAnim.Text='Click a track row first.'; end, return; end
        if isstruct(dwellAnim) && dwellAnim.playing, dwellStopTimer(); return; end
        fps = 10; if ~isempty(eDwFps) && isgraphics(eDwFps), fps = eDwFps.Value; end
        dwellRedraw(1);
        t = timer('ExecutionMode','fixedRate','Period',max(0.03,round(1000/fps)/1000),'BusyMode','drop', ...
                  'Tag','sptAnalyzeDwell','TimerFcn',@(s,e) dwellTick(), 'ErrorFcn',@(s,e) delete(s));
        dwellAnim.timer = t; dwellAnim.playing = true;
        if ~isempty(btnDwPlay) && isgraphics(btnDwPlay), btnDwPlay.Text = '⏸ Stop'; end
        start(t);
    end

    function dwellTick()
        if isempty(dwellAnim) || ~isgraphics(axDwDens), dwellStopTimer(); return; end
        i = dwellAnim.i + 1; if i > dwellAnim.n, i = 1; end
        dwellRedraw(i);
        if ~isempty(sldDwFrame) && isgraphics(sldDwFrame), try, sldDwFrame.Value = i; catch, end, end
    end

    function dwellStopTimer()
        if isempty(dwellAnim) || ~isstruct(dwellAnim), return; end
        try, if ~isempty(dwellAnim.timer) && isa(dwellAnim.timer,'timer') && isvalid(dwellAnim.timer), stop(dwellAnim.timer); delete(dwellAnim.timer); end, catch, end
        dwellAnim.timer = []; dwellAnim.playing = false;
        if ~isempty(btnDwPlay) && isgraphics(btnDwPlay), btnDwPlay.Text = '▶ Play'; end
    end

    function onDwellScrub()
        if isempty(dwellAnim) || isempty(sldDwFrame) || ~isgraphics(sldDwFrame), return; end
        dwellStopTimer(); dwellRedraw(sldDwFrame.Value);
    end

    function onDwellSaveVideo()
        if isempty(dwellAnim) || dwellAnim.n < 2, if ~isempty(lblDwAnim)&&isgraphics(lblDwAnim), lblDwAnim.Text='Click a track row first.'; end, return; end
        dwellStopTimer();
        deflt = fullfile(tern(isempty(projectDir),pwd,projectDir), [dwellAnim.name '.mp4']);
        [fn,fp] = uiputfile({'*.mp4','MPEG-4';'*.avi','Motion JPEG AVI'},'Save track animation', deflt);
        if isequal(fn,0), return; end
        out = fullfile(fp,fn); [~,~,ext] = fileparts(out);
        fps = 10; if ~isempty(eDwFps) && isgraphics(eDwFps), fps = eDwFps.Value; end
        if ~isempty(lblDwAnim)&&isgraphics(lblDwAnim), lblDwAnim.Text='Rendering video…'; drawnow; end
        vw = []; tmp = [tempname '.png']; sz = [];
        try
            if strcmpi(ext,'.avi'), vw = VideoWriter(out,'Motion JPEG AVI'); else, vw = VideoWriter(out,'MPEG-4'); end
            vw.FrameRate = max(1,round(fps)); open(vw);
            for i = 1:dwellAnim.n
                dwellRedraw(i); drawnow;
                exportgraphics(axDwDens, tmp, 'Resolution',120); im = imread(tmp);
                if isempty(sz)
                    h = size(im,1); w = size(im,2); sz = [h-mod(h,2), w-mod(w,2)];   % EVEN dims (H.264 needs even; odd -> padded -> diagonal shear)
                end
                if ~isequal([size(im,1) size(im,2)], sz), im = imresize(im, sz); else, im = im(1:sz(1),1:sz(2),:); end
                writeVideo(vw, im);
            end
            close(vw); if isfile(tmp), delete(tmp); end
            if ~isempty(lblDwAnim)&&isgraphics(lblDwAnim), lblDwAnim.Text = ['Saved ' out]; end
        catch ME
            try, if ~isempty(vw), close(vw); end, catch, end
            if ~isempty(lblDwAnim)&&isgraphics(lblDwAnim), lblDwAnim.Text = ['Video failed: ' ME.message]; end
        end
    end

    % ================= Tab 7 · Experiment (multi-folder ingest + condition manifest) =================
    % Gather cells from several analysis folders (each day/batch), assign each a CONDITION, and save a
    % manifest that REFERENCES the folders (never merges the TrackStructs). The Compare tab can then
    % group across the whole dataset by condition. This is the scaling layer for many cells/conditions.
    function buildExperimentTab(parent)
        % The SHARED experiment panel (same component every tool embeds). Seed with the current
        % project's analysis folder if one is open; the user adds more day/batch folders here.
        seed = {}; if ~isempty(projectDir) && isfolder(fullfile(projectDir,'analysis')), seed = {fullfile(projectDir,'analysis')}; end
        opts = struct('tool',mode); opts.seedFolders = seed;   % assign after (struct('f',{}) would make an empty struct)
        exptCtl = spt_experiment_panel(parent, opts);
    end

    % ================= Tab 8 · Compare (grouped stats: mito / window / condition) =================
    function buildCompareTab(parent)
        g = uigridlayout(parent,[2 1],'RowHeight',{34,'1x'},'Padding',[10 10 10 10],'RowSpacing',6);
        r = uigridlayout(g,[1 10],'ColumnWidth',{40,160, 54,150, 50,150, 88, 84, '1x', 0},'Padding',[0 0 0 0],'ColumnSpacing',8);
        uilabel(r,'Text','data','HorizontalAlignment','right');
        ddCmpData = uidropdown(r,'Items',{'current project','experiment (all folders)'},'Value','current project', ...
            'Tooltip','Compare THIS project''s sites, or the whole EXPERIMENT (every folder in the Experiment tab, grouped by the conditions you assigned).');
        uilabel(r,'Text','group by','HorizontalAlignment','right');
        ddCmpGroup = uidropdown(r,'Items',{'mito vs non-mito','window (time-resolved)','condition'},'Value','condition');
        uilabel(r,'Text','metric','HorizontalAlignment','right');
        ddCmpMetric = uidropdown(r,'Items',{'dwell s','k_out /s','enrichment','area µm²','n_loc','mito fraction','# sites'},'Value','enrichment');
        uibutton(r,'Text','▶ Compute','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70],'FontColor','w','ButtonPushedFcn',@(s,e) onCompareCompute());
        uibutton(r,'Text','Export CSV','ButtonPushedFcn',@(s,e) onCompareExport());
        lblCmp = uilabel(r,'Text','Run the mapper (Sites tab); dwell metrics also need the Dwell tab. Then Compute.','FontColor',[0.2 0.4 0.5]);
        uilabel(r,'Text','');
        mn = uigridlayout(g,[1 2],'ColumnWidth',{'0.9x','1.1x'},'Padding',[0 0 0 0],'ColumnSpacing',8);
        tblCmp = uitable(mn,'ColumnName',{'group','n','mean','sem'},'ColumnWidth',{'1x',44,80,80});
        rc = uigridlayout(mn,[2 1],'RowHeight',{'1x','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
        axCmpScatter = uiaxes(rc); title(axCmpScatter,'per-site values by group');
        axCmpCdf     = uiaxes(rc); title(axCmpCdf,'pooled dwell-time CDF');
    end

    function onCompareCompute()
        metric = ddCmpMetric.Value; mode = ddCmpGroup.Value;
        useExpt = ~isempty(ddCmpData) && isgraphics(ddCmpData) && startsWith(ddCmpData.Value,'experiment');
        if useExpt
            cellsE = []; if ~isempty(exptCtl) && isstruct(exptCtl), cellsE = exptCtl.getCells(); end
            if isempty(cellsE), lblCmp.Text='No experiment loaded — add folders + conditions in the Experiment tab first.'; return; end
            [cmpCSW, cmpDD] = cs_experiment_aggregate(exptCtl.getManifest());
            if isempty(cmpCSW), lblCmp.Text='No mapped sites in the experiment folders (run the mapper per folder).'; return; end
        else
            if ~ensureCSWloaded(), lblCmp.Text='Run the mapper (Sites tab) first.'; return; end
            cmpCSW = CSW; cmpDD = DD;
            if any(strcmp(metric,{'dwell s','k_out /s'})) && ~ensureDDloaded(), lblCmp.Text='Compute dwell (Dwell tab) first for this metric.'; return; end
            cmpDD = DD;
        end
        if any(strcmp(metric,{'dwell s','k_out /s'})) && (isempty(cmpDD) || ~isfield(cmpDD,'perSite') || isempty(cmpDD.perSite))
            lblCmp.Text = ['This metric needs dwell — compute dwell (Dwell tab)' tern(useExpt,' in each experiment folder.','.')]; return;
        end
        [vals, grp] = compareValues(metric, mode);                 % per-site value + group label
        if isempty(vals), lblCmp.Text='No values for this metric/grouping.'; return; end
        [gnames,~,gi] = unique(grp,'stable');
        D = cell(numel(gnames),4); mus = nan(1,numel(gnames));
        for j = 1:numel(gnames)
            v = vals(gi==j); v = v(isfinite(v));
            mus(j) = mean0(v);
            D(j,:) = {gnames{j}, sprintf('%d',numel(v)), sprintf('%.4g',mean0(v)), sprintf('%.4g',semv(v))};
        end
        tblCmp.Data = D;
        % scatter of per-site values by group (+ mean marker)
        cla(axCmpScatter); hold(axCmpScatter,'on');
        for j = 1:numel(gnames)
            v = vals(gi==j); v = v(isfinite(v));
            xj = j + 0.12*(rand(numel(v),1)-0.5)*2;
            plot(axCmpScatter, xj, v, 'o','MarkerFaceColor',[0.45 0.55 0.75],'MarkerEdgeColor','none','MarkerSize',4);
            plot(axCmpScatter, j, mean0(v), '_','Color',[0.85 0.25 0.2],'MarkerSize',26,'LineWidth',2);
        end
        hold(axCmpScatter,'off'); xlim(axCmpScatter,[0.5 numel(gnames)+0.5]);
        xticks(axCmpScatter,1:numel(gnames)); xticklabels(axCmpScatter,gnames);
        ylabel(axCmpScatter, metric); title(axCmpScatter, sprintf('%s by %s', metric, mode));
        % pooled dwell CDF per group (from the selected dataset's dwell events)
        cla(axCmpCdf);
        if ~isempty(cmpDD) && isfield(cmpDD,'events') && ~isempty(cmpDD.events)
            hold(axCmpCdf,'on'); leg = {};
            for j = 1:numel(gnames)
                dv = groupDwell(gnames{j}, mode); dv = dv(isfinite(dv)&dv>0);
                if isempty(dv), continue; end
                sv = sort(dv(:)); yy = (1:numel(sv))'/numel(sv);
                stairs(axCmpCdf, sv, yy, 'LineWidth',1.3); leg{end+1}=gnames{j}; %#ok<AGROW>
            end
            hold(axCmpCdf,'off'); xlabel(axCmpCdf,'dwell (s)'); ylabel(axCmpCdf,'CDF');
            if ~isempty(leg), legend(axCmpCdf, leg, 'Location','southeast'); end
            title(axCmpCdf,'pooled dwell-time CDF');
        else
            title(axCmpCdf,'pooled dwell-time CDF (compute dwell in the Dwell tab)');
        end
        % two-group rank-sum p (Stats toolbox)
        pmsg = '';
        if numel(gnames)==2 && exist('ranksum','file')==2
            v1 = vals(gi==1); v2 = vals(gi==2); v1=v1(isfinite(v1)); v2=v2(isfinite(v2));
            if ~isempty(v1)&&~isempty(v2), try, pmsg = sprintf(' · rank-sum p=%.3g', ranksum(v1,v2)); catch, end, end
        end
        lblCmp.Text = sprintf('%s by %s · %d groups%s', metric, mode, numel(gnames), pmsg);
    end

    function [vals, grp] = compareValues(metric, mode)
        % One value per site (cmpCSW element) + its group label. Dwell/k_out from cmpDD.perSite, matched
        % by siteUID and then by source folder. That NARROWS cross-folder mixing, it does not prevent it —
        % see findPerSite for the two cases that fall through to cand(1).
        n = numel(cmpCSW); vals = nan(1,n); grp = cell(1,n);
        havePS = ~isempty(cmpDD) && isfield(cmpDD,'perSite') && ~isempty(cmpDD.perSite);
        for i = 1:n
            e = cmpCSW(i);
            switch metric
                case 'enrichment', vals(i) = e.enrichment;
                case 'area µm²',   vals(i) = e.areaUm2;
                case 'n_loc',      vals(i) = e.nMemberLocs;
                case 'mito fraction', vals(i) = double(e.MitoFlag);
                case '# sites',    vals(i) = 1;
                case {'dwell s','k_out /s'}
                    if havePS
                        j = findPerSite(cmpDD.perSite, e);
                        if j>0
                            if strcmp(metric,'dwell s'), vals(i) = cmpDD.perSite(j).meanDwell;
                            else,                        vals(i) = cmpDD.perSite(j).kout; end
                        end
                    end
            end
            grp{i} = groupLabel(e, mode);
        end
        keep = ~cellfun(@isempty,grp);
        vals = vals(keep); grp = grp(keep);
    end

    function j = findPerSite(ps, e)
        % Match a site to its per-site dwell record by siteUID, then by source folder. siteUID restarts
        % at 1 in every folder's mapper run, so collisions across folders are normal. TWO fall-throughs
        % return a record from a DIFFERENT folder: a single candidate is taken without checking the
        % folder at all, and if no candidate's folder matches, the first is used anyway.
        j = 0; ids = [ps.siteUID]; cand = find(ids==e.siteUID);
        if isempty(cand), return; end
        if numel(cand)==1 || ~isfield(e,'srcFolder') || ~isfield(ps,'srcFolder'), j = cand(1); return; end
        for c = cand(:)', if strcmp(ps(c).srcFolder, e.srcFolder), j = c; return; end, end
        j = cand(1);
    end

    function lab = groupLabel(e, mode)
        switch mode
            case 'window (time-resolved)', lab = sprintf('win %d', e.window);
            case 'condition'
                if isfield(e,'condition') && ~isempty(e.condition), lab = char(e.condition); else, lab = e.file; end
            otherwise,                     lab = tern(e.MitoFlag,'mito','non-mito');
        end
    end

    function dv = groupDwell(gname, mode)
        % pooled event dwell durations for the events whose group label == gname (works on either the
        % project or the experiment dataset — events carry window/mito/condition directly).
        dv = [];
        if isempty(cmpDD) || ~isfield(cmpDD,'events') || isempty(cmpDD.events), return; end
        ev = cmpDD.events;
        labs = arrayfun(@(x) groupLabelEv(x,mode), ev, 'uni',0);
        dv = [ev(strcmp(labs,gname)).dwell];
    end

    function lab = groupLabelEv(ev, mode)
        switch mode
            case 'window (time-resolved)', lab = sprintf('win %d', ev.window);
            case 'condition'
                if isfield(ev,'condition') && ~isempty(ev.condition), lab = char(ev.condition); else, lab = ev.file; end
            otherwise, lab = tern(ev.mito,'mito','non-mito');
        end
    end

    function onCompareExport()
        if isempty(tblCmp) || isempty(tblCmp.Data), lblCmp.Text='Nothing to export — Compute first.'; return; end
        anaDir = ensureAnaDir(); if isempty(anaDir), return; end
        fn = fullfile(anaDir, sprintf('cs_compare_%s_by_%s.csv', regexprep(ddCmpMetric.Value,'\W','_'), regexprep(ddCmpGroup.Value,'\W','_')));
        try
            fid = fopen(fn,'w'); fprintf(fid,'group,n,mean,sem\n');
            D = tblCmp.Data;
            for r = 1:size(D,1), fprintf(fid,'%s,%s,%s,%s\n', D{r,1}, D{r,2}, D{r,3}, D{r,4}); end
            fclose(fid); lblCmp.Text = ['Exported ' fn];
        catch ME, lblCmp.Text = ['Export failed: ' ME.message]; end
    end

    % ---- shared downstream helpers ----
    function resetDownstream()
        % Clear ALL downstream (Refine/Sites/Dwell/Compare) in-memory state + caches so a project
        % switch or a Load never leaks a prior dataset's footprints/densities/results into the new one.
        try, dwellStopTimer(); catch, end   % stop any running Dwell animation before wiping results
        CSW = []; DD = []; siteDensCache = struct('key',{},'dens',{},'raw',{}); refNullCache = struct('key',{},'nullMax',{},'pmap',{});
        dwellAnim = [];
        refFoot = []; refSelIdx = 0; refRowMap = []; siteSelIdx = 0; siteRowMap = []; siteMemberSel = 0;
        if ~isempty(refCbar) && isgraphics(refCbar), delete(refCbar); end; refCbar = [];
        if ~isempty(lstRefSites) && isgraphics(lstRefSites), lstRefSites.Items = {'(load first)'}; lstRefSites.ItemsData = []; end
        if ~isempty(axRef)      && isgraphics(axRef),      cla(axRef);  title(axRef,'footprint editor (load, then pick a site)'); end
        if ~isempty(axRad)      && isgraphics(axRad),      cla(axRad);  title(axRad,'radial concentration'); end
        if ~isempty(lblRefInfo) && isgraphics(lblRefInfo), lblRefInfo.Text = ''; end
        if ~isempty(ddRefWin)   && isgraphics(ddRefWin),   ddRefWin.Items = {'All windows'}; ddRefWin.Value = 'All windows'; end
        if ~isempty(tblSites)   && isgraphics(tblSites),   tblSites.Data = {}; end
        if ~isempty(axSite)     && isgraphics(axSite),     cla(axSite); title(axSite,'site inspector — density + footprint (Run mapper, click a row)'); end
        if ~isempty(lstMembers) && isgraphics(lstMembers), lstMembers.Items = {'—'}; end
        if ~isempty(ddWinFilt)  && isgraphics(ddWinFilt),  ddWinFilt.Items = {'All windows'}; ddWinFilt.Value = 'All windows'; end
        if ~isempty(sitePlayer) && isstruct(sitePlayer), try, sitePlayer.load([],[]); catch, end, end
    end

    function anaDir = ensureAnaDir()
        anaDir = '';
        if isempty(projectDir), return; end
        anaDir = fullfile(projectDir,'analysis'); if ~isfolder(anaDir), try, mkdir(anaDir); catch, anaDir=''; return; end, end
        % the mapper reads the build from disk — make sure the in-session one is persisted, under
        % the ACTIVE name so a named build is what the downstream stages pick up
        if isempty(tsName), tsName = activeTsName(anaDir); end
        if ensureTracksLoaded() && ~isfile(fullfile(anaDir,tsName))
            Tracks = buildTracks; try, save(fullfile(anaDir,tsName),'Tracks','-v7.3'); catch, end %#ok<NASGU>
        end
    end
    function ok = ensureCSWloaded()
        ok = ~isempty(CSW); if ok, return; end
        if isempty(projectDir), return; end
        f = fullfile(projectDir,'analysis','CSW_final.mat');
        if isfile(f), try, L = load(f); if isfield(L,'CSW')&&~isempty(L.CSW), CSW = L.CSW; ok = true; end, catch, end, end
    end
    function ok = ensureDDloaded()
        ok = ~isempty(DD) && isfield(DD,'events'); if ok, return; end
        if isempty(projectDir), return; end
        f = fullfile(projectDir,'analysis','cs_window_dwell.mat');
        if isfile(f), try, L = load(f); if isfield(L,'DD')&&~isempty(L.DD), DD = L.DD; ok = true; end, catch, end, end
    end
    function ok = ensureDDloadedSoft(), ok = ensureDDloaded(); end

    function pat = curatePattern()
        % prefer Tool 2's curated tracks, then Tool 1's filtered, then raw
        if     ~isempty(dir(fullfile(tracksDir,'*_tracks_curated.xml'))),  pat = '*_tracks_curated.xml';
        elseif ~isempty(dir(fullfile(tracksDir,'*_tracks_filtered.xml'))), pat = '*_tracks_filtered.xml';
        else,                                                              pat = '*_tracks.xml'; end
    end

    function Tracks = addDiffusion(Tracks)
        % Per-localization instantaneous D(t) + confinement/state-change for every cell — the native
        % rolling estimator, run at BUILD (after curation), stored in TrackStruct so Tool 3 can use
        % diffusion state to identify sites. No-op if the driver is missing.
        if exist('spt_track_diffusion','file')~=2, return; end
        for k = 1:numel(Tracks)
            dtk = DTS; if isfield(Tracks,'frameInterval') && ~isempty(Tracks(k).frameInterval) && Tracks(k).frameInterval>0, dtk = Tracks(k).frameInterval; end
            try
                Tk = spt_track_diffusion(Tracks(k), struct('dt',dtk,'sigmaUm',PRECNM/1000, ...
                    'confineD',diffConfineD,'confMode',diffConfMode,'confFrac',diffConfFrac, ...
                    'baseWin',diffBaseWin,'minRun',diffMinRun, ...
                    'minSeg',diffMinSeg,'penalty',diffPenalty));
                % assign FIELD-BY-FIELD (a whole-struct assign fails — the result has extra fields)
                Tracks(k).Dt = Tk.Dt; Tracks(k).confined = Tk.confined; Tracks(k).stateChange = Tk.stateChange; Tracks(k).diffOpts = Tk.diffOpts;
            catch, end
        end
    end

    function reDeriveConfinement()
        % Recompute confined/stateChange from the STORED Dt (cheap — no re-rolling) for a new threshold,
        % re-save TrackStruct, and refresh the QC. Called when the confinement spinner changes.
        if isempty(buildTracks) || ~isfield(buildTracks,'Dt'), return; end
        for k = 1:numel(buildTracks)
            Dt = buildTracks(k).Dt; if isempty(Dt), continue; end
            % Same rules the builder uses — relative-to-own-median by default, with a minimum run
            % length. This used to hardcode `Dt <= diffConfineD` with no persistence, so re-deriving
            % silently reverted a build to the old absolute criterion.
            % ONE implementation, shared with the builder. These were separate copies and had
            % already drifted — the app kept a sliding baseline after the driver moved to a frozen
            % one, so re-deriving a build produced different flags from building it.
            dtk = trackDt(k);
            [conf, sc] = spt_confine_flags(Dt, struct('confMode',diffConfMode, ...
                'confFrac',diffConfFrac,'baseWin',diffBaseWin,'confineD',diffConfineD, ...
                'minRun',diffMinRun,'minSeg',diffMinSeg,'penalty',diffPenalty, ...
                'dt',dtk,'sigmaUm',PRECNM/1000), buildTracks(k).matrix);
            buildTracks(k).confined = conf; buildTracks(k).stateChange = sc;
            if isfield(buildTracks,'diffOpts') && isstruct(buildTracks(k).diffOpts)
                buildTracks(k).diffOpts.confineD = diffConfineD;
                buildTracks(k).diffOpts.confMode = diffConfMode;
                buildTracks(k).diffOpts.confFrac = diffConfFrac;
                buildTracks(k).diffOpts.baseWin  = diffBaseWin;
                buildTracks(k).diffOpts.minSeg   = diffMinSeg;
                buildTracks(k).diffOpts.penalty  = diffPenalty;
                buildTracks(k).diffOpts.minRun   = diffMinRun;
            end
        end
        % Re-save to the ACTIVE build. Writing TrackStruct.mat unconditionally discarded the edit
        % for a named build and left a divergent shadow file behind.
        p = activeTsPath();
        try, if ~isempty(p), Tracks = buildTracks; save(p,'Tracks','-v7.3'); end, catch, end %#ok<NASGU>
        if ~isempty(ddQCcell) && isgraphics(ddQCcell), drawQC(ddQCcell.Value); end
    end

    function onConfineD()
        if ~isempty(eConfineD) && isgraphics(eConfineD), diffConfineD = eConfineD.Value; end
        if ~isempty(ddConfMode) && isgraphics(ddConfMode), diffConfMode = ddConfMode.Value; end
        if ~isempty(eConfFrac)  && isgraphics(eConfFrac),  diffConfFrac = eConfFrac.Value;  end
        if ~isempty(eBaseWin)   && isgraphics(eBaseWin),   diffBaseWin  = round(eBaseWin.Value); end
        if ~isempty(eMinSeg)    && isgraphics(eMinSeg),    diffMinSeg   = round(eMinSeg.Value); end
        if ~isempty(ePenalty)   && isgraphics(ePenalty),   diffPenalty  = ePenalty.Value; end
        if ~isempty(eMinRun)    && isgraphics(eMinRun),    diffMinRun   = round(eMinRun.Value); end
        isAbs = strcmpi(diffConfMode,'absolute');
        if ~isempty(eConfineD) && isgraphics(eConfineD)
            if isAbs, eConfineD.Enable = 'on'; else, eConfineD.Enable = 'off'; end
        end
        if ~isempty(eConfFrac) && isgraphics(eConfFrac)
            if isAbs, eConfFrac.Enable = 'off'; else, eConfFrac.Enable = 'on'; end
        end
        isSeg = strcmpi(diffConfMode,'segment');
        if ~isempty(eBaseWin) && isgraphics(eBaseWin)
            if strcmpi(diffConfMode,'drop'), eBaseWin.Enable = 'on'; else, eBaseWin.Enable = 'off'; end
        end
        for h = [eMinSeg ePenalty]
            if ~isempty(h) && isgraphics(h)
                if isSeg, h.Enable = 'on'; else, h.Enable = 'off'; end
            end
        end
        if ~isempty(eMinRun) && isgraphics(eMinRun)
            % segment mode enforces its own minimum through minSeg; minRun would double-filter
            if isSeg, eMinRun.Enable = 'off'; else, eMinRun.Enable = 'on'; end
        end
        reDeriveConfinement();
    end


    function onBuild()
        if isempty(tracksDir) || ~isfolder(tracksDir)
            setBuild('Pick a project folder first.',[0.75 0.1 0.1]); return; end
        if exist('build_trackstruct','file') ~= 2
            setBuild('build_trackstruct.m not on the path (expected in drivers/).',[0.75 0.1 0.1]); return; end
        pat = curatePattern(); tu = 'frame'; if ~isempty(ddTimeUnit) && isgraphics(ddTimeUnit), tu = ddTimeUnit.Value; end
        if strcmp(pat,'*_tracks_curated.xml'), src = 'curated';
        elseif strcmp(pat,'*_tracks_filtered.xml'), src = 'filtered (not yet curated in Tool 2)';
        else, src = 'raw (unfiltered)'; end
        setBuild(sprintf('Building from %s tracks (%s time) — computing MSD, please wait…', src, tu),[0.2 0.4 0.5]);
        try
            % Prefer='raw' is a benign placeholder so the auto-detect doesn't error; Pattern overrides it.
            Tracks = build_trackstruct(tracksDir, 'Prefer', 'raw', 'Pattern', pat, 'TimeUnit', tu, 'Save', false, ...
                'Verbose', false, 'ProgressFcn', @(i,n,name) setBuild(sprintf('Building %d/%d: %s (MSD)…', i, n, name),[0.2 0.4 0.5]));
        catch ME
            setBuild(['Build failed: ' ME.message],[0.75 0.1 0.1]); return;
        end
        if isempty(Tracks), setBuild('No tracks imported — check the tracks folder.',[0.6 0.4 0.1]); return; end
        setBuild('Computing per-localization diffusion D(t) + confinement…',[0.2 0.4 0.5]); drawnow;
        Tracks = addDiffusion(Tracks);                         % per-loc D(t)/confined/stateChange stored in TrackStruct
        aDir = fullfile(projectDir,'analysis'); if ~isfolder(aDir), mkdir(aDir); end
        onTsName(); setActiveTs(aDir, tsName);          % write analysis/<name>.mat and make it active
        save(fullfile(aDir,tsName),'Tracks','-v7.3');
        cc = fullfile(tracksDir,'cs_calib.mat'); if isfile(cc), try, copyfile(cc, fullfile(aDir,'cs_calib.mat')); catch, end, end
        populateBuildSummary(Tracks, src, aDir);
    end

    function onLoadTracks()
        % Load a built TrackStruct and populate the QC WITHOUT recomputing MSD. When the project
        % holds MORE THAN ONE build, always ask which — otherwise the shortcut to the active one
        % made every other named build unreachable, contradicting the button's own tooltip.
        f = '';
        if ~isempty(projectDir)
            a = fullfile(projectDir,'analysis');
            nBuilds = 0;
            d = dir(fullfile(a,'*.mat'));
            skip = {'cs_calib.mat','CSW_final.mat','cs_window_dwell.mat','cs_footprints.mat','experiment_manifest.mat'};
            for q = 1:numel(d)
                if any(strcmpi(d(q).name,skip)), continue; end
                try, w = whos('-file', fullfile(a,d(q).name)); if any(strcmp({w.name},'Tracks')), nBuilds = nBuilds + 1; end, catch, end
            end
            if nBuilds <= 1
                c = fullfile(a, activeTsName(a)); if isfile(c), f = c; end
            end
        end
        if isempty(f)
            start = pwd; if ~isempty(projectDir) && isfolder(projectDir), start = projectDir; end
            [fn,fp] = uigetfile({'*.mat','TrackStruct (*.mat)'}, 'Pick a built TrackStruct', start);
            if isequal(fn,0), return; end
            f = fullfile(fp,fn);
        end
        setBuild(['Loading ' f ' …'],[0.2 0.4 0.5]); drawnow;
        try, L = load(f); catch ME, setBuild(['Load failed: ' ME.message],[0.75 0.1 0.1]); return; end
        if ~isfield(L,'Tracks') || isempty(L.Tracks)
            setBuild('That .mat has no non-empty ''Tracks'' variable.',[0.75 0.1 0.1]); return; end
        Tracks = L.Tracks;
        if ~isfield(Tracks,'Dt') || isempty(Tracks(1).Dt)     % older build: add per-loc diffusion now
            setBuild('Computing per-localization diffusion D(t) + confinement…',[0.2 0.4 0.5]); drawnow;
            Tracks = addDiffusion(Tracks);
        end
        % infer / set the project so the downstream tabs have an analysis/ folder to read+write
        [fdir,~] = fileparts(f);
        if isempty(projectDir) && endsWith(fdir, [filesep 'analysis'])
            d = fileparts(fdir);
            if isfolder(d), eProj.Value = d; setProject(d); end   % also embeds Import & Curate
        end
        aDir = '';
        if ~isempty(projectDir)
            aDir = fullfile(projectDir,'analysis'); if ~isfolder(aDir), mkdir(aDir); end
            % Keep the file's OWN name — loading Day1_KO.mat must not overwrite TrackStruct.mat.
            % A build picked from outside the project is copied in under that same name and becomes
            % active, so several named builds coexist and the one you loaded is the one in force.
            [~,stem,ext] = fileparts(f); if isempty(ext), ext = '.mat'; end
            setActiveTs(aDir, [stem ext]);
            dst = fullfile(aDir, tsName);
            try, save(dst,'Tracks','-v7.3'); catch, end   % persist (may have just added diffusion fields)
            cc = fullfile(aDir,'cs_calib.mat'); if isfile(cc), try, calib=load(cc); if isfield(calib,'calib'), applyCalib(calib.calib); end, catch, end, end
        end
        resetDownstream();                                               % new tracks -> invalidate downstream state + caches
        populateBuildSummary(Tracks, 'loaded (no rebuild)', aDir);
        logBuild(sprintf('Loaded TrackStruct.mat (%d cell(s)) from %s — MSD rebuild skipped.', numel(Tracks), f));
    end

    function applyCalib(c)
        % adopt calibration fields from a loaded cs_calib.mat into the top bar (best-effort)
        if isfield(c,'pixSizeUm')&&c.pixSizeUm>0, PXUM=c.pixSizeUm; if isgraphics(eCalPx), eCalPx.Value=PXUM; end, end
        if isfield(c,'fovUm')&&c.fovUm>0, FOVUM=c.fovUm; if isgraphics(eCalFov), eCalFov.Value=FOVUM; end, end
        if isfield(c,'dt_s')&&c.dt_s>0, DTS=c.dt_s; if isgraphics(eCalDt), eCalDt.Value=DTS; end, end
        if isfield(c,'binNm')&&c.binNm>0, PRECNM=c.binNm; if isgraphics(eCalPrec), eCalPrec.Value=PRECNM; end, end
    end

    function populateBuildSummary(Tracks, src, aDir)
        n = numel(Tracks); D = cell(n,5); tot = 0; anyM=false; anyE=false;
        for k = 1:n
            L = double(Tracks(k).lengths(:)); nt = numel(L); tot = tot + nt;
            hm = isfield(Tracks,'mitoDist') && ~isempty(Tracks(k).mitoDist);
            he = isfield(Tracks,'erDist')   && ~isempty(Tracks(k).erDist);
            anyM = anyM||hm; anyE = anyE||he;
            D(k,:) = {char(Tracks(k).file), nt, round(median(L)), tern(hm,'✓','–'), tern(he,'✓','–')};
        end
        tblBuild.Data = D;
        buildTracks = Tracks;
        ddQCcell.Items = [{'All (pooled)'}, cellfun(@char, {Tracks.file}, 'uni', 0)];
        ddQCcell.Value = 'All (pooled)';
        drawQC('All (pooled)');
        logBuild(sprintf('Built %d cell(s), %d tracks -> %s  [%s tracks, mito=%s ER=%s]', ...
            n, tot, fullfile(aDir,tsName), src, tern(anyM,'yes','no'), tern(anyE,'yes','no')));
        setBuild(sprintf('Done — %d cell(s), %d tracks. %s in analysis/ (active). QC below.', n, tot, tsName),[0.2 0.5 0.2]);
    end

    function onQCcell()
        if ~isempty(ddQCcell) && isgraphics(ddQCcell), drawQC(ddQCcell.Value); end
    end

    function drawQC(sel)
        if isempty(buildTracks), return; end
        if strcmp(sel,'All (pooled)'), ks = 1:numel(buildTracks);
        else, ks = find(strcmp({buildTracks.file}, sel)); if isempty(ks), ks = 1:numel(buildTracks); end
        end

        % ---- flat, clickable track list across the displayed cells ----
        qcTracks = {}; ER = []; MI = []; L = [];
        for k = ks
            T = buildTracks(k); M = T.matrix; if size(M,3) < 3, continue; end
            dtk = trackDt(k);
            for c = 1:size(M,2)
                X = M(:,c,2); Y = M(:,c,3); F = M(:,c,1); ok = isfinite(X) & isfinite(Y);
                if nnz(ok) < 2, continue; end
                msdT = fieldOr(T,'MSD');   erT = fieldOr(T,'erDist');   miT = fieldOr(T,'mitoDist');   % may be absent (no-ER build / old struct)
                rr = spt_fit_msd(colOr(msdT,c), dtk, fitSpec());        % per-track D at the current fit mode/window
                s = struct('cellIdx',k,'col',c,'base',char(T.file),'X',X(ok),'Y',Y(ok),'F',F(ok),'len',nnz(ok), ...
                    'MSD', colOr(msdT,c), 'ER', finiteCol(erT,c), 'MI', finiteCol(miT,c), 'D', rr.D, 'sigLoc', rr.sigLocUm, 'fracUsed', rr.fracUsed, ...
                    'dt', dtk, ...                                       % stepwise (per-localization) diffusion, aligned to X/Y/F:
                    'Dt',   maskCol(fieldOr(T,'Dt'),          c, ok), ...
                    'conf', maskCol(fieldOr(T,'confined'),    c, ok), ...
                    'sc',   maskCol(fieldOr(T,'stateChange'), c, ok), ...
                    'CSD',  trimCol(fieldOr(T,'CSD'), c, nnz(ok)-1));    % path length through each step (µm)
                qcTracks{end+1} = s; L(end+1)=s.len; ER=[ER; s.ER]; MI=[MI; s.MI]; %#ok<AGROW>
            end
        end
        qcSelIdx = 0; qcHi = [];

        % ---- tracks panel (click one) ----
        cla(axCov); Xa=[]; Ya=[];
        for i=1:numel(qcTracks), Xa=[Xa; qcTracks{i}.X; NaN]; Ya=[Ya; qcTracks{i}.Y; NaN]; end %#ok<AGROW>
        if ~isempty(Xa), plot(axCov, Xa, Ya, '-','Color',[0.55 0.6 0.75],'LineWidth',0.4,'HitTest','off'); end
        axis(axCov,'equal'); set(axCov,'YDir','reverse'); disableDefaultInteractivity(axCov);
        xlabel(axCov,'x (µm)'); ylabel(axCov,'y (µm)'); title(axCov, sprintf('tracks (click one) — %d', numel(qcTracks)));

        % ---- pooled length + ER/mito distance ----
        L = L(:);
        cla(axLen);
        if ~isempty(L)
            histogram(axLen, L, min(40,max(5,round(max(L)/2))), 'FaceColor',[0.5 0.6 0.8],'EdgeColor','none');
            try, set(axLen,'YScale','log'); catch, end
        end
        xlabel(axLen,'length (frames)'); ylabel(axLen,'count'); title(axLen, sprintf('track length (median %.0f)', median0_(L)));

        cla(axDist); hold(axDist,'on'); leg = {};
        if ~isempty(ER), histogram(axDist, ER, 40, 'FaceColor',[0.15 0.6 0.25],'EdgeColor','none','FaceAlpha',0.6); leg{end+1}='ER'; end %#ok<AGROW>
        if ~isempty(MI), histogram(axDist, MI, 40, 'FaceColor',[0.85 0.2 0.6],'EdgeColor','none','FaceAlpha',0.6); leg{end+1}='mito'; end %#ok<AGROW>
        xline(axDist, 0, 'k-'); hold(axDist,'off');
        xlabel(axDist,'signed distance (µm)  [− inside]'); ylabel(axDist,'spots'); title(axDist,'ER / mito distance');
        if ~isempty(leg), legend(axDist, leg, 'Location','best'); end

        % D distribution across the displayed tracks (at the current fit %) + MSD-intercept precision
        Dv = cellfun(@(x) x.D, qcTracks); Dv = Dv(isfinite(Dv) & Dv>0);
        frv = cellfun(@(x) x.fracUsed, qcTracks); frv = frv(isfinite(frv));
        if strcmp(fitModeNow(),'adaptive') && ~isempty(frv)
            fitTag = sprintf('adaptive fit %.0f–%.0f%% (median %.0f%%)', min(frv), max(frv), median(frv));
        else
            fitTag = sprintf('fixed fit %.0f%%', eMsdFrac.Value);
        end
        cla(axDdist);
        if ~isempty(Dv), histogram(axDdist, Dv, min(40,max(5,round(numel(Dv)/3))), 'FaceColor',[0.4 0.55 0.75],'EdgeColor','none'); end
        xlabel(axDdist,'D (µm²/s)'); ylabel(axDdist,'tracks');
        title(axDdist, sprintf('D distribution — median %.3g µm²/s  ·  %s', median0_(Dv), fitTag));
        % per-localization confinement (from the stored diffusion) — the low-D cutoff Tool 3 uses
        % confined/stateChange may be absent even when Dt is present (a struct written before those
        % fields existed, or one merged by combine_trackstructs where a source lacked them) — reading
        % them unguarded threw 'Unrecognized field name "confined"' and blanked the whole QC tab.
        if isfield(buildTracks,'Dt') && isfield(buildTracks,'confined') && isfield(buildTracks,'stateChange')
            nConf=0; nLoc=0; nSC=0;
            for k=ks
                if ~isempty(buildTracks(k).Dt) && ~isempty(buildTracks(k).confined) && ~isempty(buildTracks(k).stateChange)
                    fin=isfinite(buildTracks(k).Dt); nLoc=nLoc+nnz(fin);
                    nConf=nConf+nnz(buildTracks(k).confined & fin); nSC=nSC+nnz(buildTracks(k).stateChange);
                end
            end
            if nLoc>0
                hold(axDdist,'on'); xline(axDdist, diffConfineD, '-','Color',[0.85 0.3 0.2],'LineWidth',1.2,'Alpha',0.8); hold(axDdist,'off');
                title(axDdist, sprintf('D dist — median %.3g · %s | confined ≤%.3g: %.1f%% locs · %d state-changes', ...
                    median0_(Dv), fitTag, diffConfineD, 100*nConf/max(nLoc,1), nSC),'FontSize',8.5);
            end
        end
        % ---- pooled STEPWISE diffusion: one D per localization (spt_track_diffusion), not per track ----
        % This is a different quantity from the D-distribution above: that one fits an MSD per TRACK,
        % this one is the rolling noise-corrected D at every localization, and it is what the confined /
        % state-change flags — and Tool 3's density channels — are derived from.
        cla(axDloc);
        Dl = []; Cl = [];
        for k = ks
            Tk = buildTracks(k);
            if ~isfield(Tk,'Dt') || isempty(Tk.Dt), continue; end
            d = Tk.Dt(:); fin = isfinite(d); Dl = [Dl; d(fin)]; %#ok<AGROW>
            if isfield(Tk,'confined') && ~isempty(Tk.confined)
                cc = Tk.confined(:); Cl = [Cl; cc(fin)]; %#ok<AGROW>
            end
        end
        if isempty(Dl)
            title(axDloc,'stepwise D (per localization) — not in this TrackStruct');
            xlabel(axDloc,''); ylabel(axDloc,'');
        else
            % Drop the top 0.5% rather than clamping it into the last bin — clamping builds a false
            % spike at the right edge that reads as a real population.
            hi = prctile(Dl, 99.5); if ~(hi > 0), hi = max(Dl); end
            shown = Dl(Dl <= hi); nHid = numel(Dl) - numel(shown);
            histogram(axDloc, shown, linspace(0, max(hi,eps), 60), 'FaceColor',[0.45 0.35 0.65],'EdgeColor','none');
            hold(axDloc,'on');
            xline(axDloc, diffConfineD, '-','Color',[0.85 0.3 0.2],'LineWidth',1.4);
            hold(axDloc,'off');
            try, set(axDloc,'YScale','log'); catch, end                   % the confined peak is orders below the bulk
            xlim(axDloc, [0 max(hi, eps)]);
            tail = ''; if nHid > 0, tail = sprintf('  ·  %d >%.2g hidden', nHid, hi); end
            xlabel(axDloc, sprintf('stepwise D (µm²/s)/loc%s', tail));
            ylabel(axDloc,'localizations');
            pctC = 100*mean(Dl <= diffConfineD); if ~isempty(Cl), pctC = 100*mean(Cl); end
            title(axDloc, sprintf('stepwise D · med %.3g · %.0f%% confined · n=%s', ...
                median(Dl), pctC, kfmt_(numel(Dl))), 'FontSize',8.5);
        end

        % ---- CSD: cumulative path length per track (µm). Every track faint, median bold; the
        % clicked track is highlighted on top, the same way the tracks panel behaves.
        cla(axCSD); csdHi = [];
        ddHi = []; dlHi = [];    % the pooled D panels are redrawn below; their markers go with them
        Cx = []; Cy = []; nC = 0; Call = {};
        for i = 1:numel(qcTracks)
            cv = fieldOr(qcTracks{i},'CSD'); cv = cv(isfinite(cv));
            if numel(cv) < 2, continue; end
            Cx = [Cx; (1:numel(cv))'; NaN]; Cy = [Cy; cv(:); NaN]; nC = nC + 1; %#ok<AGROW>
            Call{end+1} = cv(:); %#ok<AGROW>
        end
        if nC == 0
            if isfield(buildTracks,'CSD'), msg = 'CSD — no track long enough to plot';
            else,                          msg = 'CSD — not in this TrackStruct'; end
            title(axCSD, msg); xlabel(axCSD,''); ylabel(axCSD,'');
        else
            plot(axCSD, Cx, Cy, '-','Color',[0.85 0.55 0.15 0.13],'LineWidth',0.5,'HitTest','off');
            hold(axCSD,'on');
            nmax = max(cellfun(@numel, Call));
            P = nan(nmax, nC);
            for i = 1:nC, P(1:numel(Call{i}), i) = Call{i}; end
            % The median at step k is over only the tracks still alive at step k, so past the bulk of
            % the length distribution it is a handful of long tracks and drifts upward. Draw it only
            % while enough tracks contribute, and say how far that is.
            nAlive = sum(isfinite(P), 2);
            kMax = find(nAlive >= max(5, 0.10*nC), 1, 'last'); if isempty(kMax), kMax = 1; end
            med = median(P(1:kMax,:), 2, 'omitnan');
            plot(axCSD, (1:kMax)', med, '-','Color',[0.55 0.30 0.05],'LineWidth',1.6,'HitTest','off');
            hold(axCSD,'off');
            tot = cellfun(@(v) v(end), Call);
            xlabel(axCSD,'step #'); ylabel(axCSD,'path length (µm)');
            title(axCSD, sprintf('CSD — %d tracks · median total %.2f µm · median to step %d', ...
                nC, median(tot), kMax), 'FontSize',8.5);
        end

        if ~isempty(playerCtl) && isstruct(playerCtl), playerCtl.load([], 0); end   % clear the player until a track is clicked
        cla(axMSD); title(axMSD,'MSD + D fit (click a track)');
        cla(axDtrace); title(axDtrace,'stepwise D(t) (click a track)');
        cla(axSweep); title(axSweep,'D & R² vs fit window (click a track)');
        if ~isempty(ER)
            lblQCm.Text = sprintf('%d tracks · on-ER %.1f%% (median %.3f µm) · median len %.0f fr — click a track to inspect', ...
                numel(qcTracks), 100*mean(ER<=0), median(ER), median0_(L));
        else
            lblQCm.Text = sprintf('%d tracks · median len %.0f fr · (no ER) — click a track to inspect', numel(qcTracks), median0_(L));
        end
    end

    function onCovClick(e)
        if isempty(qcTracks), return; end
        try, p = e.IntersectionPoint(1:2); catch, return; end
        best = 0; bd = inf;
        for i = 1:numel(qcTracks)
            d = min(hypot(qcTracks{i}.X - p(1), qcTracks{i}.Y - p(2)));
            if d < bd, bd = d; best = i; end
        end
        if best > 0, drawSelected(best); end
    end

    function drawSelected(i)
        if i < 1 || i > numel(qcTracks), return; end
        qcSelIdx = i; s = qcTracks{i};
        % highlight in the tracks panel
        if ~isempty(qcHi) && isgraphics(qcHi), delete(qcHi); end
        hold(axCov,'on'); qcHi = plot(axCov, s.X, s.Y, '-','Color',[1 0.55 0],'LineWidth',2,'HitTest','off'); hold(axCov,'off');
        % play the selected track in the embedded player (over the SPT frames + per-frame ER/mito overlay)
        R = trackR(s);
        if ~isempty(playerCtl) && isstruct(playerCtl)
            if ~isempty(R), playerCtl.load(R, 0); else, playerCtl.load([], 0); end
        end
        % MSD + D = slope/4 fit over the resolved window
        dtk = trackDt(s.cellIdx);
        cla(axMSD); r = spt_fit_msd(s.MSD, dtk, fitSpec());
        if ~isempty(r.lag)
            plot(axMSD, r.lag, r.y, 'o','Color',[0.2 0.5 0.7],'MarkerSize',3); hold(axMSD,'on');
            if ~isempty(r.fitX), plot(axMSD, r.fitX, r.fitY, 'r-','LineWidth',1.5); end
            hold(axMSD,'off');
        end
        xlabel(axMSD,'lag (s)'); ylabel(axMSD,'MSD (µm²)');
        title(axMSD, sprintf('D = %.4g µm²/s · R² = %.3f · fit %d lags (%.0f%%)', r.D, r.R2, r.nPts, r.fracUsed));

        % highlight this track's cumulative displacement against the population
        if ~isempty(axCSD) && isgraphics(axCSD)
            if ~isempty(csdHi) && isgraphics(csdHi), delete(csdHi); end
            cv = fieldOr(s,'CSD'); cv = cv(isfinite(cv));
            if numel(cv) >= 2
                hold(axCSD,'on');
                csdHi = plot(axCSD, (1:numel(cv))', cv(:), '-','Color',[1 0.55 0],'LineWidth',2,'HitTest','off');
                hold(axCSD,'off');
            end
        end

        % Where THIS track sits in the two pooled D histograms. The only vertical line on those
        % panels used to be the confinement threshold, which never moves — so clicking a track told
        % you nothing about where it fell in the population, which is what you want when hunting for
        % the fast ones.
        if ~isempty(axDdist) && isgraphics(axDdist)
            if ~isempty(ddHi) && isgraphics(ddHi), delete(ddHi); end
            if isfinite(r.D)
                hold(axDdist,'on');
                ddHi = xline(axDdist, r.D, '-', sprintf('this track %.3g', r.D), ...
                    'Color',[1 0.55 0],'LineWidth',2,'FontSize',7, ...
                    'LabelVerticalAlignment','top','LabelHorizontalAlignment','center');
                hold(axDdist,'off');
            end
        end
        if ~isempty(axDloc) && isgraphics(axDloc)
            if ~isempty(dlHi) && isgraphics(dlHi), delete(dlHi); end
            dvv = fieldOr(s,'Dt'); dvv = dvv(isfinite(dvv));
            if ~isempty(dvv)
                hold(axDloc,'on');
                dlHi = xline(axDloc, median(dvv), '-', sprintf('this track %.3g', median(dvv)), ...
                    'Color',[1 0.55 0],'LineWidth',2,'FontSize',7, ...
                    'LabelVerticalAlignment','top','LabelHorizontalAlignment','center');
                hold(axDloc,'off');
            end
        end

        % stepwise D(t) for THIS track — the per-localization rolling D that the confined /
        % state-change flags come from. The MSD panel above gives one D for the whole track; this
        % shows how it varies along the track, which is the point of computing it per localization.
        cla(axDtrace);
        Dt = fieldOr(s,'Dt');
        if isempty(Dt) || ~any(isfinite(Dt))
            title(axDtrace,'stepwise D(t) — not in this TrackStruct'); xlabel(axDtrace,''); ylabel(axDtrace,'');
        else
            % Elapsed time along the track, honouring real frame gaps. matrix(:,:,1) is a FRAME
            % index under TimeUnit='frame' but already SECONDS under 'seconds' — scaling the latter
            % by dt again would compress the axis by a factor of dt. Integer-valued means frames.
            tt = (0:numel(Dt)-1)' * dtk;
            if ~isempty(s.F) && numel(s.F)==numel(Dt)
                F0 = s.F - s.F(1);
                if all(abs(F0 - round(F0)) < 1e-6), tt = F0 * dtk; else, tt = F0; end
            end
            cf = fieldOr(s,'conf'); if isempty(cf), cf = Dt <= diffConfineD; end
            cf = logical(cf(:)) & isfinite(Dt(:));
            hold(axDtrace,'on');
            plot(axDtrace, tt, Dt, '-','Color',[0.45 0.5 0.62],'LineWidth',0.9);
            plot(axDtrace, tt(~cf), Dt(~cf), '.','Color',[0.20 0.45 0.75],'MarkerSize',7);   % mobile
            plot(axDtrace, tt(cf),  Dt(cf),  '.','Color',[0.85 0.30 0.20],'MarkerSize',9);   % confined
            yline(axDtrace, diffConfineD, '--','Color',[0.85 0.3 0.2],'LineWidth',1.1);
            scv = fieldOr(s,'sc');
            if ~isempty(scv)
                z = find(logical(scv(:)));                                                   % fast -> slow entries
                for q = z(:)', xline(axDtrace, tt(q), '-','Color',[0.95 0.6 0.1],'LineWidth',1.1,'Alpha',0.85); end
            end
            hold(axDtrace,'off');
            xlabel(axDtrace,'time along track (s)'); ylabel(axDtrace,'D (µm²/s)');
            if ~isempty(tt) && tt(end) > tt(1), xlim(axDtrace, [tt(1) tt(end)]); end
            nsc = 0; if ~isempty(scv), nsc = nnz(scv); end
            title(axDtrace, sprintf('stepwise D(t) · med %.3g · %.0f%% confined · %d state-change%s', ...
                median(Dt(isfinite(Dt))), 100*mean(cf), nsc, plural_(nsc)), 'FontSize',9);
        end

        % D & R² vs fit window — the sensitivity of this track's D to how many MSD lags are fit
        sw = spt_msd_sweep(s.MSD, dtk, 1.0);
        cla(axSweep);
        if ~isempty(sw.npts)
            yyaxis(axSweep,'left');  plot(axSweep, sw.frac, sw.D, '-o','Color',[0.20 0.45 0.75],'MarkerSize',3,'LineWidth',1); ylabel(axSweep,'D (µm²/s)');
            yyaxis(axSweep,'right'); plot(axSweep, sw.frac, sw.R2,'-','Color',[0.85 0.30 0.20],'LineWidth',1.2); ylabel(axSweep,'R²'); ylim(axSweep,[0 1.03]);
            xline(axSweep, r.fracUsed, 'k--', 'used', 'LabelVerticalAlignment','bottom','FontSize',7);
            xlabel(axSweep,'fit window (% of MSD lags)');
            title(axSweep, sprintf('D & R² vs fit window · used %.0f%% (%d lags)', r.fracUsed, r.nPts));
        else
            title(axSweep,'D & R² vs fit window (track too short)');
        end
        % readout (σ_loc kept as a small trailing note — it is fit-window dependent, treat as a caveat)
        onER = NaN; if ~isempty(s.ER), onER = 100*mean(s.ER<=0); end
        if isfinite(r.sigLocUm) && r.sigLocUm>0, sTr = sprintf(' · σ_loc≈%.0f nm', 1000*r.sigLocUm); else, sTr = ''; end
        lblQCm.Text = sprintf('track col %d (%s): %d spots · D = %.4g µm²/s (R²=%.3f, %d lags) · on-ER %.0f%%%s', ...
            s.col, s.base, s.len, r.D, r.R2, r.nPts, onER, sTr);
    end

    function m = fitModeNow()
        m = 'fixed'; if ~isempty(ddFitMode) && isgraphics(ddFitMode), m = ddFitMode.Value; end
    end

    function spec = fitSpec()   % the MSD-fit window spec passed to spt_fit_msd, from the mode dropdown + fit-% spinner
        if strcmp(fitModeNow(),'adaptive')
            spec = struct('mode','adaptive', 'maxFrac', min(max(eMsdFrac.Value,10),100)/100, 'r2thr',0.95, 'minPts',3);
        else
            spec = eMsdFrac.Value;   % fixed %
        end
    end

    function onMsdFrac()
        key = [];   % remember the selected track across the recompute
        if qcSelIdx > 0 && qcSelIdx <= numel(qcTracks), key = [qcTracks{qcSelIdx}.cellIdx, qcTracks{qcSelIdx}.col]; end
        drawQC(ddQCcell.Value);
        if ~isempty(key)
            for i = 1:numel(qcTracks)
                if qcTracks{i}.cellIdx==key(1) && qcTracks{i}.col==key(2), drawSelected(i); break; end
            end
        end
    end

    function R = trackR(s)
        % minimal R for spt_track_movie: this one track over its cell's SPT frames + ER/mito seg
        R = [];
        [sp,er,mi] = matchedPaths(s.base);
        if isempty(sp) || ~isfile(sp), return; end
        dt = trackDt(s.cellIdx);
        if secsMode(), fr = round(s.F/dt); else, fr = round(s.F); end
        R = struct('base',s.base,'sptPath',sp,'erPath',er,'mitoPath',mi, ...
            'x', s.X/PXUM + 1, 'y', s.Y/PXUM + 1, 'frame', fr(:), 'trackId', zeros(numel(s.X),1));
    end

    function dt = trackDt(cellIdx)
        dt = DTS;
        if cellIdx>=1 && cellIdx<=numel(buildTracks) && isfield(buildTracks,'frameInterval') ...
                && ~isempty(buildTracks(cellIdx).frameInterval) && buildTracks(cellIdx).frameInterval>0
            dt = buildTracks(cellIdx).frameInterval;
        end
    end

    function tf = secsMode()
        % Is the track matrix time column in SECONDS? The 'Time unit' dropdown lives in the Build & QC
        % tab, which is absent in 'analyze' mode — there the loaded TrackStruct was built frame-based
        % (the default), so default to frames (false) when the dropdown doesn't exist.
        tf = false;
        if ~isempty(ddTimeUnit) && isgraphics(ddTimeUnit), tf = strcmp(ddTimeUnit.Value,'seconds'); end
    end

    function [sp,er,mi] = matchedPaths(base)
        sp=''; er=''; mi='';
        if isempty(matched), return; end
        for i = 1:numel(matched)
            [~,sn] = fileparts(matched(i).spt);
            if strcmpi(sn, char(base)), sp=matched(i).spt; er=matched(i).erSeg; mi=matched(i).mitoSeg; return; end
        end
    end

    function setBuild(msg,col)
        if ~isempty(lblBuild) && isgraphics(lblBuild), lblBuild.Text = msg; lblBuild.FontColor = col; drawnow limitrate; end
    end
    function logBuild(s)
        if ~isempty(txtBuild) && isgraphics(txtBuild), txtBuild.Value = [txtBuild.Value; {s}]; drawnow limitrate; end
    end

    function embedImportCurate()
        if isempty(tImport) || ~isgraphics(tImport), return; end   % Import & Curate tab absent in 'analyze' mode
        delete(tImport.Children);
        if isempty(tracksDir) || ~isfolder(tracksDir)
            placeholder(tImport, 'No tracks/ folder found in the project. Set it and re-pick.'); return;
        end
        if exist('track_viewer','file') ~= 2
            placeholder(tImport, 'track_viewer.m is not on the path (expected next to this app).'); return;
        end
        try
            writeCalib();                                          % cs_calib.mat before curation reads it
            % read Tool 1's curated _filtered pair; write a NEW _curated set; keep the full localization cloud
            tvOpts = struct('readPrefer','filtered','exportSuffix','curated','preserveCloud',true);
            track_viewer(tImport, tracksDir, @resolveOverlay, {}, tvOpts);
        catch ME
            placeholder(tImport, ['Could not embed track curation: ' ME.message]);
        end
    end

    % overlay resolver: cell base -> its raw SPT movie + per-frame ER + mito segmentation stacks.
    % Primary: spt_match (handles _VAPB / _TA_BC tokens). Fallback: loose containment on a stripped key.
    function ov = resolveOverlay(base)
        ov = struct('er','','mito','','spt','');
        b = char(base);
        if ~isempty(matched)
            for i = 1:numel(matched)
                [~,sn] = fileparts(matched(i).spt);
                if strcmpi(sn, b), ov.er = matched(i).erSeg; ov.mito = matched(i).mitoSeg; ov.spt = matched(i).spt; return; end
            end
        end
        if isempty(projectDir), return; end
        key = regexprep(b, '(_spt\d*|_VAPB)$', '', 'ignorecase');
        ov.er   = findSeg(fullfile(projectDir,'er_seg'),   key);
        ov.mito = findSeg(fullfile(projectDir,'mito_seg'), key);
        ov.spt  = findSeg(fullfile(projectDir,'spt'),      b);   % raw SPT movie (match the full base)
    end

    function onCal()
        if isgraphics(eCalPx),   PXUM   = eCalPx.Value;   end
        if isgraphics(eCalFov),  FOVUM  = eCalFov.Value;  end
        if isgraphics(eCalDt),   DTS    = eCalDt.Value;   end
        if isgraphics(eCalPrec), PRECNM = eCalPrec.Value; end
        writeCalib();
    end

    function onCalAuto()
        if isempty(tracksDir) || ~isfolder(tracksDir), return; end
        L = dir(fullfile(tracksDir,'*_tracks*.xml'));
        if isempty(L), return; end
        try
            txt = fileread(fullfile(L(1).folder, L(1).name));
            fi = regexp(txt, 'frameInterval="([\d.eE+-]+)"', 'tokens', 'once');
            if ~isempty(fi)
                v = str2double(fi{1});
                if isfinite(v) && v > 0, DTS = v; if isgraphics(eCalDt), eCalDt.Value = v; end, end
            end
        catch
        end
        writeCalib();
    end

    function writeCalib()
        dst = tracksDir; if isempty(dst) || ~isfolder(dst), dst = projectDir; end
        if isempty(dst) || ~isfolder(dst), return; end
        calib = struct('pixSizeUm',PXUM,'fovUm',FOVUM,'dt_s',DTS,'binNm',PRECNM,'snapFovUm',FOVUM); %#ok<NASGU>
        try, save(fullfile(dst,'cs_calib.mat'),'calib'); catch, end
    end

    function placeholder(parent, msg)
        delete(parent.Children);
        g = uigridlayout(parent,[1 1],'Padding',[18 18 18 18]);
        uilabel(g,'Text',msg,'WordWrap','on','FontColor',[0.45 0.45 0.5]);
    end
end

% ============================ local helpers ============================
function p = firstExisting(cands)
p = '';
for i = 1:numel(cands)
    if isfolder(cands{i}), p = cands{i}; return; end
end
end

function p = findSeg(segDir, key)
% first TIFF in segDir whose name contains `key` (case-insensitive); '' if none
p = '';
if isempty(key) || ~isfolder(segDir), return; end
L = [dir(fullfile(segDir,'*.tif')); dir(fullfile(segDir,'*.tiff'))];
for i = 1:numel(L)
    [~,nm] = fileparts(L(i).name);
    if contains(lower(nm), lower(key)), p = fullfile(L(i).folder, L(i).name); return; end
end
end

function y = tern(c, a, b)
if c, y = a; else, y = b; end
end

function v = fieldOr(s, f)
% struct field s.(f) if present and a struct, else [] — so QC survives structs without erDist/MSD.
if isstruct(s) && isfield(s,f), v = s.(f); else, v = []; end
end

function m = median0_(v)
v = v(:); v = v(isfinite(v));
if isempty(v), m = 0; else, m = median(v); end
end

function m = mean0(v)
v = v(:); v = v(isfinite(v));
if isempty(v), m = NaN; else, m = mean(v); end
end

function s = semv(v)
v = v(:); v = v(isfinite(v));
if numel(v) < 2, s = 0; else, s = std(v)/sqrt(numel(v)); end
end

function y = round4(x), if isfinite(x), y = round(x,4); else, y = x; end, end
function y = round2(x), if isfinite(x), y = round(x,2); else, y = x; end, end
function s = sci(x)
if ~isfinite(x), s = ''; elseif x==0, s = '0'; else, s = sprintf('%.2e', x); end
end

function v = colOr(M, c)
% column c of M (a matrix) as a column vector, or [] if absent
if ~isempty(M) && c <= size(M,2), v = M(:,c); else, v = []; end
end

function v = finiteCol(M, c)
v = colOr(M, c); v = v(isfinite(v));
end

function s = plural_(n), if n == 1, s = ''; else, s = 's'; end, end

function s = kfmt_(n)   % compact count for a narrow panel title: 73994 -> 74.0k
if n >= 1000, s = sprintf('%.1fk', n/1000); else, s = sprintf('%d', n); end
end

function v = trimCol(M, c, nStep)
% First nStep rows of column c — a per-STEP field ([nF-1 x nT]) has L-1 real rows for a track of
% length L; everything past that is padding.
v = colOr(M, c);
if isempty(v) || nStep < 1, v = []; return; end
v = v(1:min(nStep, numel(v)));
end

function v = maskCol(M, c, ok)
% Column c of a per-localization [nF x nT] field, restricted to this track's real localizations, so
% it lines up 1:1 with X/Y/F. [] when the field is absent (a build that predates the diffusion pass).
v = colOr(M, c);
if isempty(v), return; end
v = v(ok);
end

% fitTrackD was extracted to drivers/spt_fit_msd.m (unit-testable) — the QC calls that now.

function occ = seg_occupancy(segPath)
% Whole-movie occupancy: fraction of frames each pixel is inside the organelle (fg = min nonzero
% label, the ilastik/seg convention). Returns [] on any read failure.
occ = [];
try
    info = imfinfo(segPath); nfr = numel(info);
    a1 = imread(segPath, 1); v = unique(a1(:)); nz = v(v > 0);
    fg = 1; if ~isempty(nz), fg = double(min(nz)); end
    step = max(1, ceil(nfr/1000));          % sample ~1000 frames — occupancy is a smooth per-pixel mean, so
    frames = 1:step:nfr;                     % striding a multi-thousand-frame stack barely changes it
    acc = zeros(size(a1));
    for t = frames, acc = acc + double(imread(segPath, t) == fg); end
    occ = acc / numel(frames);
catch
    occ = [];
end
end
