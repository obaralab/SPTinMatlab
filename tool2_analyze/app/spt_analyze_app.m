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
% Uses the drivers/ layer as the engine (build_trackstruct, the windowed picker, mappers, dwell).
% The Import & Curate tab EMBEDS track_viewer.m (local-density + displacement-
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
t1_ = fullfile(fileparts(fileparts(here_)),'tool1_track');
if isfolder(t1_), addpath(t1_); end
eProj=[]; eCalPx=[]; eCalFov=[]; eCalDt=[]; eCalPrec=[]; lblProj=[]; lblDims=[];  % top-bar handles
IMW = NaN; IMH = NaN;   % image dimensions in px, from the movie — what the FOV is computed from
CALEDIT = {};           % which top-bar numbers are HAND EDITS ('pixSizeUm','fovUm','dt_s'), so the
                        % build can rank them above the file — see TrackImporter_direct/cell_calib
tg=[]; tImport=[]; tBuild=[]; tCS=[];                                 % tabs
tRefine=[]; tSites=[]; tDwell=[]; tExpt=[]; tEngage=[]; tCompare=[];   % downstream tabs
% Engagement tab handles
engExN=0; engDropC=0; bEngEx=[]; engOccT=[]; engEngF=[]; engDd=[]; engKey=[]; engD0=[]; engD1=[]; engN=[]; engSig=[]; engMin=[]; engTbl=[]; engLbl=[]; engAxEx=[]; engNEx=[];
engAxCell=[]; engAxScan=[]; engLast=[];
ddTimeUnit=[]; lblBuild=[]; tblBuild=[]; txtBuild=[];                 % Build handles
buildChanKeys = {};   % the channel columns tblBuild was BUILT with — onCalEdit derives its column
                      % index map from this, so adding a channel cannot silently shift calibration
chanTok=''; chanWhy='';   % SPT channel token derived per project (see spt_channel_token)
calibKnown=false;   % is the panel calibration supported by THIS project (adopted or typed)?
buildTracks=[]; ddQCcell=[]; axMSD=[]; axCov=[]; axDist=[]; axDdist=[]; lblQCm=[]; eMsdFrac=[];   % QC handles
tsName=''; eTsName=[]; ddBuild=[];   % the ACTIVE TrackStruct basename in analysis/ (named builds)
axDtrace=[];   % stepwise D(t) for the clicked track (the POOLED per-localization panel was retired:
              % it measured the same thing, and the left column is for per-TRACK quantities now)
axCSD=[]; csdHi=[];       % cumulative-displacement panel + the highlight of the clicked track
spnLenMin=[]; ddDistCh=[]; spnDistMax=[]; lblQcSel=[]; qcKeep=[];   % QC track selection (length / near a channel)
trkEx=[]; bQcRej=[];      % hand-rejected tracks (cs_track_exclusions) + the reject/restore button
ddHi=[];                  % where the CLICKED track sits in the pooled D histogram
% Confinement / state-change is not part of the pipeline right now: the build stores only the
% rolling D, and Tool 3's picker has no diffusion-state density channels. The criterion and all four
% of its modes live on in spt_confine_flags / spt_track_diffusion, measured against a matched
% Brownian null (see that header), for when the contact-site work needs them.
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
pendExcl=struct('file',{},'csID',{},'window',{},'pickPx',{},'trackCol',{});
pendDelSite=struct('file',{},'csID',{},'window',{},'pickPx',{});   % whole-site deletions marked but not yet saved   % track removals marked but not yet applied
% Dwell tab handles
axDwHist=[]; axKout=[]; tblDwell=[]; axDwTrace=[]; axDwDens=[]; lblDwell=[]; dwellRowMap=[];
btnDwPlay=[]; sldDwFrame=[]; chkDwChan=gobjects(1,0); eDwFps=[]; lblDwAnim=[]; dwellAnim=[]; ddDwBg=[]; eDwContrast=[];
% Compare tab handles
% Experiment tab — the shared experiment/condition panel (spt_experiment_panel)
exptCtl=[];
% Compare tab handles (+ data source: current project vs experiment)
ddCmpGroup=[]; ddCmpMetric=[]; ddCmpData=[]; ddCmpSites=[]; eCmpMinDw=[]; eMinDwPct=[]; tblCmp=[];
axCmpScatter=[]; axCmpCdf=[]; lblCmp=[]; cmpCSW=[]; cmpDD=[];
% Identity keys of the sites that survived Compare's filters. The dwell CDF pools EVENTS, and an
% event has to leave with the site it belongs to.
cmpKeptSites=[]; cmpLast=[];   % ...and the last computed comparison, for the per-point export
cmpCells=[];   % (folder|file) keys of the cells to include; [] means every cell in the dataset

% Clean up any orphaned Dwell-animation timer from a previous session (a timer left running after an
% improper close fires its nested TimerFcn into a dead workspace -> "Unable to find function dwellTick").
try, tOrph = timerfindall('Tag','sptAnalyzeDwell'); if ~isempty(tOrph), stop(tOrph); delete(tOrph); end, catch, end

% ============================ window =================================
fig = uifigure('Name',toolName, 'Position',[60 60 1320 900]);
fig.CloseRequestFcn = @(s,e) onAppClose();   % deletes tabs -> track_viewer's parent.DeleteFcn stops its timer
% headless test hooks (spt_named_build_smoke); the UI itself never reads these. These must be
% NESTED functions — an anonymous @() tsName would capture the value at construction time and
% always report the empty initial state.
fig.UserData = struct('activeTs',@activeTsNow, 'tracks',@tracksNow, 'loadTracks',@onLoadTracks, ...
    'cmpSetCells',@setCompareCells, 'cmpCellList',@compareCellList, 'cmpLoad',@ensureCompareData, ...
    'exptCtl',@exptCtlNow, 'calibForBuild',@calibForBuild, 'loadTracksFile',@loadTracksFile, ...
    'engExamples',@onEngageExamples);
gl = uigridlayout(fig,[2 1],'RowHeight',{34,'1x'},'Padding',[8 8 8 8],'RowSpacing',6);

% 16 columns, 16 widths, 16 children — keep the three in step. uigridlayout WRAPS a child it has no
% column for onto a new row and then crushes the row height, which reads as a broken toolbar rather
% than as a layout error.
top = uigridlayout(gl,[1 16],'ColumnWidth', ...
    {150,'1x',60, 40,132, 74,60, 60,54,66, 54,54, 84,54, 52, 60}, ...
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
% The dimensions the FOV is computed FROM. A bare FOV is unfalsifiable — 27.61 looks as reasonable as
% 55.2 — but "256x256 px" next to it makes the arithmetic checkable at a glance: width-1 times the
% pixel size. It is a label, not a field: the movie decides its size, not the user.
lblDims = uilabel(top,'Text','— px','Tag','calibDims','HorizontalAlignment','center','FontColor',[0.45 0.45 0.5], ...
    'Tooltip','Image dimensions in pixels, from the movie. FOV = (width − 1) × pixel size.');
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
    nTab=nTab+1; tEngage = uitab(tg,'Title',sprintf('%d · Engagement',nTab));
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
    buildEngageTab(tEngage);
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
        % The SPT channel token used to be HARDCODED to '_VAPB' here, with no way to change it —
        % Tool 1 at least asks for it. So the moment a dataset used another channel name ('_C3'),
        % every ER and mito overlay silently failed to resolve and this tab just showed nothing.
        % Nothing errored; the names simply never matched.
        %
        % It is not a setting worth asking for, because the answer is in the folder: a segmentation
        % is named for the cell, the SPT stack for the cell plus the token, so the token is the
        % difference. spt_channel_token derives it and reports what it found.
        % Pick the token that RESOLVES THE MOST CELLS, rather than trusting any single rule.
        %
        % Deriving it from the file names handles the common case ('_C3', '_spt1') without asking,
        % but spt_match's strip is documented as an unanchored regex precisely so it can remove an
        % INFIX — the historical 'cell_VAPB_spt1' layout, where the token sits in the middle and no
        % prefix comparison can find it. Replacing the old literal outright would have turned those
        % projects into the same silent-empty-overlay failure this is fixing. So both are candidates,
        % and the data decides.
        %
        % The derived token is anchored and escaped; '_VAPB' is passed raw, as it always was, because
        % anchoring it would defeat the infix case it exists for.
        calibKnown = false;   % a new project has not justified these numbers yet
        chanTok = ''; chanWhy = ''; matched = [];
        if exist('spt_match','file')==2
            cands = {};
            % FIRST: what Tool 1 actually used, if it recorded it. Deriving works only when a
            % segmentation name is a prefix of the SPT name; a regex typed in Tool 1 for unusual
            % naming can never be re-derived, so the recorded value has to lead. Still scored
            % against the others below, so a stale record cannot beat a convention that resolves
            % more cells.
            try
                [reRec, tokRec, srcRec] = spt_settings_match(fullfile(d,'tracks'));
                if ~isempty(srcRec)
                    cands{end+1} = {reRec, tokRec, 'recorded by Tool 1 in _settings.txt'};
                end
            catch, end
            try, [t0, ti] = spt_channel_token(fullfile(d,'spt'), fullfile(d,'er_seg'), fullfile(d,'mito_seg'));
                 if ~isempty(t0), cands{end+1} = {['(?:' regexptranslate('escape',t0) ')$'], t0, ti.why}; end
            catch, end
            cands{end+1} = {'_VAPB', '_VAPB', 'legacy _VAPB token'};
            cands{end+1} = {'',      '',      'names match with nothing stripped'};
            best = -1;
            for q = 1:numel(cands)
                try, mq = spt_match(fullfile(d,'spt'), fullfile(d,'er_seg'), fullfile(d,'mito_seg'), cands{q}{1});
                catch, continue; end
                nq = sum(arrayfun(@(x) ~isempty(x.erSeg) || ~isempty(x.mitoSeg), mq));
                if nq > best
                    best = nq; matched = mq; chanTok = cands{q}{2}; chanWhy = cands{q}{3};
                end
            end
            if best <= 0 && ~isempty(matched), chanWhy = 'no ER/mito matched any naming convention'; end
        end
        onCalAuto();          % try to read dt from a tracks XML
        embedImportCurate();
        % The manifest lives WITH the project (<project>/experiment_details.mat), so whichever tool
        % opens this folder sees the same cells and conditions without an explicit Load/Save.
        try, if ~isempty(exptCtl) && isstruct(exptCtl) && isfield(exptCtl,'setAutoPath')
                exptCtl.setAutoPath(d);
             end, catch, end
        % Add the PROJECT ROOT, the same thing Tool 1 adds. This used to add <project>/analysis,
        % which resolves to the same project — so a manifest touched by both tools named one project
        % twice and listed every cell twice.
        try, if ~isempty(exptCtl) && isstruct(exptCtl), exptCtl.addFolder(d); end, catch, end   % keep the experiment in sync
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
        % QC controls for the ROLLING DIFFUSION readout. The confinement / state-change criterion is
        % applied at build with the measured defaults (see spt_track_diffusion) and is deliberately NOT
        % exposed here: its six tuning controls overflowed this row — a uigridlayout squeezes every
        % child when there are more of them than declared columns, which is what squashed this strip.
        % To change the criterion, pass confMode/confFrac/minSeg/penalty to spt_track_diffusion.
        r2 = uigridlayout(g,[1 7],'ColumnWidth',{56,180,58,130,66,56,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
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
        lblQCm = uilabel(r2,'Text','Build, then click a track in the tracks panel to inspect it (it plays here).','FontColor',[0.2 0.4 0.5]);
        % row 3 — main: [ left pooled | middle clickable tracks | right: embedded player + small MSD ]
        mn = uigridlayout(g,[1 3],'ColumnWidth',{'0.78x','1.15x','1.05x'},'Padding',[0 0 0 0],'ColumnSpacing',8);
        % Five rows, not six. The track-LENGTH histogram is gone (its space is the selection row
        % below), and so is the pooled stepwise-D histogram: that is the same measurement as the
        % stepwise D(t) already on the right, and one of the two had to go. What remains gets more
        % height each, which the column badly needed.
        lp = uigridlayout(mn,[5 1],'RowHeight',{92,50,'1x','1x','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
        % Calibration is PER CELL, and it lives here because this is the per-cell inventory of the
        % build. Each cell is stamped at import from its own file metadata where the acquisition chain
        % kept it, and from the Calibration panel otherwise; a * marks a value inherited from the panel
        % rather than measured from that cell. The last four columns are editable, so a cell recorded
        % on a different camera or at a different frame rate can be corrected without touching the
        % others — which is what makes a comparison spanning two acquisitions come out in real units.
        % Header: three fixed columns, then ONE PRESENCE COLUMN PER DECLARED CHANNEL, then the five
        % editable calibration columns. The channel block is generated in declaration order (so it
        % agrees with the picker's checkboxes), which is why onCalEdit must not use literal column
        % numbers — see buildChanKeys.
        buildChanKeys = cs_channel_keys(cs_channel_config(projectDir));
        chanHdr = cell(1,numel(buildChanKeys));
        for kH = 1:numel(buildChanKeys), chanHdr{kH} = cs_channel_fields(buildChanKeys{kH}).label; end
        tblBuild = uitable(lp, ...
            'ColumnName',[{'cell','tracks','med len'}, chanHdr, {'µm/px','FOV µm','dt s','prec nm','bin nm'}], ...
            'ColumnFormat',[repmat({'char'},1,3+numel(chanHdr)), repmat({'char'},1,5)], ...
            'ColumnWidth',[{'auto',52,64}, repmat({44},1,numel(chanHdr)), {60,58,60,58,54}], ...
            'ColumnEditable',[false false false, false(1,numel(chanHdr)), true true true true true], ...
            'CellEditCallback',@(s2,e2) onCalEdit(e2), ...
            'SelectionType','row', 'CellSelectionCallback',@(s2,e2) onQcRowPick(e2), ...
            'Tooltip',['Per-cell calibration — edit any of the last four for one cell without disturbing ' ...
                       'the rest. * = inherited from the Calibration panel above rather than read from ' ...
                       'that cell''s own file. dt comes from each cell''s tracks XML. ' ...
                       'prec nm is this cell''s localization precision (it sets D''s noise floor); ' ...
                       'bin nm is the DENSITY BIN, which sets the grid and so the physical size of ' ...
                       'object the detector looks for. Match bin nm across cells you want to compare, ' ...
                       'even when their precisions differ.']);
        % SELECT which tracks the pooled panels describe. Length and proximity to mito are the two
        % cuts that actually decide whether a track is worth keeping, and reading them off a
        % histogram then going elsewhere to act on them is the slow way round.
        % EXPLICIT Layout.Row on every child of lp. Auto-placement put this row fourth — under the
        % D distribution, overlapping its axis — even though it is created second, and a crushed
        % control row is the kind of thing only a render catches.
        % TWO rows. One row wanted 516 px of fixed-width controls in a column that is ~331 px wide,
        % so the last buttons were simply cut off the right edge — invisible rather than cramped.
        % Every child gets an explicit Layout, because auto-placement in a nested grid has already
        % surprised this file once.
        % TWO rows with INDEPENDENT columns. One row wanted 516 px of fixed-width controls in a
        % column that is ~331 px wide, so the last buttons were cut off the right edge — invisible
        % rather than merely cramped. A single 2x4 grid does not work either: one column cannot be
        % both a 50 px spinner and an 86 px button, so each row gets its own grid.
        qs  = uigridlayout(lp,[2 1],'RowHeight',{22,22},'Padding',[0 0 0 0],'RowSpacing',3);
        qsA = uigridlayout(qs,[1 4],'ColumnWidth',{36,50,'1x',58},'Padding',[0 0 0 0],'ColumnSpacing',4);
        qsB = uigridlayout(qs,[1 4],'ColumnWidth',{'1x',86,72,74},'Padding',[0 0 0 0],'ColumnSpacing',4);
        qsA.Layout.Row = 1; qsB.Layout.Row = 2;
        lblLen = uilabel(qsA,'Text','len ≥','HorizontalAlignment','right');
        spnLenMin = uispinner(qsA,'Limits',[0 1e5],'Value',0,'Step',5,'FontSize',9, ...
            'Tooltip','Keep tracks with at least this many localizations. 0 keeps everything.', ...
            'ValueChangedFcn',@(~,~) redrawQcPooled());
        % Which channel the distance cut is against. A dropdown rather than a mito-only checkbox:
        % the rest of the pipeline is channel-generic, and a project with ER segmentation has the
        % same question to ask of it. Items are rebuilt per build from the channels that actually
        % carry data, so a project with no ER is never offered a filter that would select nothing.
        ddDistCh = uidropdown(qsA,'Items',{'any distance'},'ItemsData',{''},'Value','','FontSize',9, ...
            'Tooltip',['Keep only tracks whose MEDIAN signed distance to this channel is under the ' ...
                       'value on the right. Median over the track, so one excursion neither includes ' ...
                       'nor excludes it. Negative is inside the mask, so 0 means "more than half the ' ...
                       'track sits on the organelle".'], ...
            'ValueChangedFcn',@(~,~) redrawQcPooled());
        spnDistMax = uispinner(qsA,'Limits',[-5 5],'Value',0.2,'Step',0.05,'FontSize',9, ...
            'ValueDisplayFormat','%.2f µm','ValueChangedFcn',@(~,~) redrawQcPooled());
        lblQcSel = uilabel(qsB,'Text','','FontSize',9,'FontColor',[0.2 0.4 0.5]);
        bExpShown = uibutton(qsB,'Text','Export shown','FontSize',9, ...
            'Tooltip',['Write the per-track D of the tracks currently selected — the QC cell above, ' ...
                       'narrowed by the two filters on the left. Wide for a Prism Column table, and ' ...
                       'long with the identifiers plus the fit window each track used.'], ...
            'ButtonPushedFcn',@(~,~) onExportQcD(false));
        bQcRej = uibutton(qsB,'Text','✖ Reject','FontSize',9, ...
            'Tooltip',['Reject the track selected in the map — it is dropped from the pooled panels, ' ...
                       'the exports AND the Engagement ratio, and the decision is written to ' ...
                       'analysis/track_exclusions.csv so every tool honours it. Click again to ' ...
                       'restore. Rejecting does NOT rebuild: nothing else about the build changes.'], ...
            'ButtonPushedFcn',@(~,~) onQcReject());
        bExpAll = uibutton(qsB,'Text','Export ALL','FontSize',9,'FontWeight','bold', ...
            'Tooltip',['The same export over EVERY cell in the build, whichever one the QC dropdown ' ...
                       'is showing. The length and mito filters still apply — they are the point of ' ...
                       'the export — and the long file names the cell on every row, so 93 cells come ' ...
                       'out as one file you can pivot rather than 93 you have to concatenate.'], ...
            'ButtonPushedFcn',@(~,~) onExportQcD(true));

        % Explicit columns within each row — auto-placement in a nested grid has surprised this
        % file before, and a control silently placed in the wrong cell reads as a layout bug.
        lblLen.Layout.Column = 1; spnLenMin.Layout.Column = 2;
        ddDistCh.Layout.Column = 3; spnDistMax.Layout.Column = 4;
        lblQcSel.Layout.Column = 1; bExpShown.Layout.Column = 2;
        bQcRej.Layout.Column = 3;   bExpAll.Layout.Column = 4;

        axDist  = uiaxes(lp); title(axDist,'ER / mito distance');
        axDdist = uiaxes(lp); title(axDdist,'D distribution');
        axCSD   = uiaxes(lp); title(axCSD,'CSD — cumulative displacement');    % every track faint, clicked one bold
        tblBuild.Layout.Row = 1; qs.Layout.Row = 2;
        axDist.Layout.Row   = 3; axDdist.Layout.Row = 4; axCSD.Layout.Row = 5;
        axCov  = uiaxes(mn); axCov.Toolbar.Visible='off'; title(axCov,'tracks (click one)'); axCov.ButtonDownFcn=@(s,e) onCovClick(e);
        rp = uigridlayout(mn,[4 1],'RowHeight',{'1.35x','1x','1x','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
        pc = uigridlayout(rp,[1 1],'Padding',[0 0 0 0]);   % embedded selected-track player
        if exist('spt_track_movie','file')==2, playerCtl = spt_track_movie(pc); end
        % Order matters: the MSD fit and the fit-window sweep are two views of the SAME fit — the sweep
        % is where you see whether the 25% window sits on a plateau or on a slope — so they belong
        % adjacent. The stepwise D(t) is a different measurement entirely (a rolling estimate along
        % the track, not a fit), so it goes above rather than between them.
        axDtrace = uiaxes(rp); title(axDtrace,'stepwise D(t) (click a track)');   % the per-loc D over time
        axDtrace.Layout.Row = 2;
        axMSD = uiaxes(rp); title(axMSD,'MSD + D fit');
        axMSD.Layout.Row = 3;
        axSweep = uiaxes(rp); title(axSweep,'D & R² vs fit window (click a track)');   % the fit-fraction sweep
        axSweep.Layout.Row = 4;
        % One policy for every plot in this tab: zoom and pan stay, the hover data tip goes. It is
        % the tip that arms a linger timer against a specific object, and every one of these axes is
        % cleared and rebuilt under the pointer.
        spt_axes_policy([axDist axDdist axCSD axMSD axDtrace axSweep]);
        spt_axes_policy(axCov);   % click-to-select a track coexists with zoom/pan
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
        skip = {'cs_calib.mat','CSW_final.mat','cs_window_dwell.mat','cs_footprints.mat','experiment_details.mat','experiment_manifest.mat'};
        d = dir(fullfile(anaDir,'*.mat'));
        for k = 1:numel(d)
            if any(strcmpi(d(k).name, skip)), continue; end
            % examples_*.mat IS a valid TrackStruct — the Engagement tab's subset of tracks that
            % touch the organelle — but it is not a BUILD. Offering it here would let it be made the
            % active build, and every downstream stage would then quietly analyse a subset. It stays
            % out of this list and remains reachable from Load TrackStruct…, whose own count does
            % include it, so the picker still opens.
            if strncmpi(d(k).name, 'examples_', 9), continue; end
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
                md = cs_channel_dist(T,'mito','cloud');
                ed = cs_channel_dist(T,'er','cloud');
            else
                M = T.matrix; if size(M,3) < 3, continue; end
                x = reshape(M(:,:,2),[],1); y = reshape(M(:,:,3),[],1);
                md = cs_channel_dist(T,'mito','tracked');
                ed = cs_channel_dist(T,'er','tracked');
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

    function saveDensityFiles(k, src, anaDir, wantExtraDens)
        if nargin < 4, wantExtraDens = true; end
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
        PixSize = trackBin(k);                                  % nm DENSITY BIN (not the precision)
        Bins = PixSize*(1:ceil(trackFov(k)/(PixSize/1000))+1);  % nm edges, identical to the advisor's grid
        okp = isfinite(X) & isfinite(Y);
        NumLoc = histcounts2(1000*X(okp), 1000*Y(okp), Bins, Bins);
        sm = imgaussfilt(NumLoc,[2 2])';                        % row = y, col = x (image convention)
        % Densities/<base>_rho.tif — full-range turbo RGB (DensityVisualization.m)
        densDir = fullfile(anaDir,'Densities'); if ~isfolder(densDir), mkdir(densDir); end
        lo = min(sm,[],'all'); hi = max(sm,[],'all'); if ~(hi>lo), hi = lo + 1; end
        rgb = ind2rgb(uint8(round(255*(sm-lo)/(hi-lo))), turbo(256));
        imwrite(rgb, fullfile(densDir, [base '_rho.tif']));
        % Density_<base>.mat/.tif — imG = 30·smoothed counts (LocDensityFigIntUse.m). NOTHING IN THIS
        % PIPELINE READS THESE: they are a drop-in for the advisor's external ContactSites code, and
        % grep finds no reader (there is no cs_identify here). They were nonetheless written for
        % every cell on first open, which is 186 unread files on a 93-cell plate. They are now
        % written only when the checkbox actually asks for them, and into analysis/density/.
        if ~wantExtraDens, return; end
        imG = 30*sm; %#ok<NASGU>
        dOut = cs_ana_path(anaDir, 'density');
        save(fullfile(dOut, ['Density_' base '.mat']), 'imG');
        try,   ChrisPrograms.saveastiff(uint16(30*sm), fullfile(dOut, ['Density_' base '.tif']));
        catch, imwrite(uint16(30*sm), fullfile(dOut, ['Density_' base '.tif'])); end
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
            'Tooltip',['Also write the EXPORT copies analysis/density/Density_<cell>.mat and .tif — ' ...
                       'for the advisor''s external ContactSites code. Nothing in THIS pipeline ' ...
                       'reads them, so leaving it off costs nothing here. Densities/<cell>_rho.tif ' ...
                       'is written regardless when it is missing: the mapper needs it, and its row ' ...
                       'count sets the µm scale factor.']);
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
        % Densities/<base>_rho.tif IS needed — its row count sets SF for the mapper — so it is
        % bootstrapped when the folder is empty, which is why density files appear on a project
        % nobody ran density on. The EXTRA Density_<base>.mat/.tif are export-only and follow the
        % checkbox, so a bootstrap writes 93 files rather than 279.
        wantExtra = ~isempty(chkCSsaveDens) && chkCSsaveDens.Value;
        needDens = isempty(dir(fullfile(anaDir,'Densities','*_rho.tif')));
        if wantExtra || needDens
            if needDens && ~wantExtra
                lblCS.Text = sprintf('First open: building the density map the mapper needs, for %d cell(s)…', numel(buildTracks));
            else
                lblCS.Text = 'Saving density maps…';
            end
            drawnow;
            for k = 1:numel(buildTracks)
                try, saveDensityFiles(k, 'All detections (cloud)', anaDir, wantExtra); catch, end
            end
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
        spt_axes_policy(axRef);
        axRad = uiaxes(cnR); box(axRad,'on'); axRad.FontSize = 9; spt_axes_policy(axRad);
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
        s = sprintf('c%d · s%d · w%d · %s%s', e.cellIndex, e.csID, e.window, tern(cs_site_near(e,'mito'),'mito','—'), tag);
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
        % 'enrich' is gone. It read like the Monte-Carlo enrichment the detector uses and is not:
        % that one is peak-inside ÷ median-over-the-ER-mask (cs_detect.m:67,77). THIS one was
        % mean-inside ÷ mean-over-bins-that-any-localization-touched (csDensMetricOne.m:37-42,
        % occBg at cs_window_mapper.m:269) — no ER anywhere in it, and the denominator pools every
        % track in the window, so it is an ensemble footprint of many different molecules over the
        % whole window rather than anything about this site's occupancy. The number is still in
        % CSW_final.mat and cs_window_metrics.csv; it is only off the screen.
        tblSites = uitable(mn,'ColumnName',{'cell','site','win','mito','area µm²','tracks','med D in','med D out'}, ...
            'ColumnWidth',{'auto',48,44,44,72,58,68,68}, ...
            'Tooltip',['med D in / med D out — the median ROLLING diffusion coefficient of this ' ...
                       'site''s member tracks, split by whether each localization sat inside the ' ...
                       'footprint. A track slower inside than outside is one that changed how it ' ...
                       'moves while it was there. "–" means no localization fell on that side.'], ...
            'SelectionType','row','CellSelectionCallback',@(s,e) onSiteSelect(e));
        cn = uigridlayout(mn,[2 1],'RowHeight',{'1x','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
        axSite = uiaxes(cn); title(axSite,'site inspector — density + footprint (Run mapper, click a row)'); axSite.Toolbar.Visible='off';
        spt_axes_policy(axSite);
        pcS = uigridlayout(cn,[1 1],'Padding',[0 0 0 0]);          % embedded member-track player
        if exist('spt_track_movie','file')==2, sitePlayer = spt_track_movie(pcS); end
        % 8 rows for 8 children. The rolling-D axes was row 3 ('1.1x'); when it went, BOTH the count
        % and RowHeight had to shrink with it — a grid with more declared rows than children leaves a
        % dead band, and one with fewer silently invents '1x' rows that are zero pixels tall here.
        rp = uigridlayout(mn,[8 1],'RowHeight',{22,'1x',28,28,28,28,28,28},'Padding',[0 0 0 0],'RowSpacing',4);
        uilabel(rp,'Text','member tracks (click to select)','FontWeight','bold','FontColor',[0.35 0.35 0.4]);
        lstMembers = uilistbox(rp,'Items',{'—'},'ValueChangedFcn',@(s,e) onMemberSelect(), ...
            'Tooltip','Member tracks of the selected site. Click one to highlight it on the density and enable single-track play / delete.');
        % The rolling-D panel was here. Removed: it was hard to read and its per-localization estimate
        % is noisy enough that the plot invited conclusions the data does not support. The QUESTION it
        % asked — does a molecule move differently while it is at a site — is still answered, by the
        % 'med D in' / 'med D out' columns of the table above, which come from the same siteTrackD
        % split and are a number rather than a shape. siteTrackD is untouched.
        btnPlaySite = uibutton(rp,'Text','▶ Play all member tracks','ButtonPushedFcn',@(s,e) onPlaySite(), ...
            'Tooltip','Play ALL of this site''s member tracks over the raw SPT movie (each a distinct colour) with per-frame ER/mito overlay.');
        btnPlayOne = uibutton(rp,'Text','▶ Play selected track','ButtonPushedFcn',@(s,e) onPlaySiteOne(), ...
            'Tooltip','Play ONLY the track selected in the list, over the raw SPT movie.');
        btnDelTrack = uibutton(rp,'Text','🗑 Mark/unmark track for removal','FontColor',[0.75 0.1 0.1],'ButtonPushedFcn',@(s,e) onDeleteTrack(), ...
            'Tooltip','Toggle removal of the selected member track from THIS site. Marked tracks turn RED and stay pending across sites (nothing is applied yet). Click 💾 Save removals to apply them all at once.');
        btnDelSite = uibutton(rp,'Text','🗑 Mark/unmark SITE for deletion','FontColor',[0.75 0.1 0.1], ...
            'ButtonPushedFcn',@(s,e) onDeleteSite(), ...
            'Tooltip',['Toggle deletion of the SELECTED site. This writes the SAME CSdeleted list the Refine ' ...
                       'tab writes, so the two tabs cannot disagree about which sites exist — it is offered here ' ...
                       'too because this is where you inspect a site''s member tracks and decide it is not real. ' ...
                       'Applied by Save below.']);
        uibutton(rp,'Text','💾 Save removals (re-run)','ButtonPushedFcn',@(s,e) onSaveRemovals(), ...
            'Tooltip','Write ALL pending edits — track removals to analysis/CS_trackedits.mat, deleted sites to analysis/CS_footprints.mat — and re-run the mapper once.');
        % The STEP export/import buttons were here. Removed: the bridge is unused and the bundled
        % models are D-only, so they were two controls leading nowhere. drivers/run_step.py,
        % cs_step_export.m and cs_step_import.m are untouched — call them directly if wanted.
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
        nMito = nnz(cs_sites_near(CSW,'mito'));
        nRef = nnz(cellfun(@(m) startsWith(char(m),'refined'), {CSW.footprintMode}));
        refTxt = ''; if nRef>0, refTxt = sprintf(' · %d refined', nRef); end
        lblSites.Text = sprintf('%d site-windows over %d window(s) · %d mito%s — click a row to inspect / play.', ...
            numel(CSW), numel(wl), nMito, refTxt);
    end

    function fillSitesTable()
        if isempty(CSW), tblSites.Data = {}; siteRowMap = []; return; end
        keep = 1:numel(CSW);
        if ~isempty(ddWinFilt) && isgraphics(ddWinFilt) && ~strcmp(ddWinFilt.Value,'All windows')
            w = sscanf(ddWinFilt.Value,'window %d'); keep = find([CSW.window]==w);
        end
        siteRowMap = keep;
        % strings so counts/IDs show as integers (not 9.0000) and area/D keep sensible precision
        D = cell(numel(keep),8);
        for r = 1:numel(keep)
            e = CSW(keep(r));
            [dIn, dOut] = siteTrackD(e);
            D(r,:) = {e.file, sprintf('%d',e.csID), sprintf('%d',e.window), tern(cs_site_near(e,'mito'),'✓','–'), ...
                      sprintf('%.3f',e.areaUm2), sprintf('%d',e.nTracks), ...
                      fmtD_(dIn), fmtD_(dOut)};
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
        % A site marked for deletion must LOOK marked, or the only feedback is a status line that the
        % next click overwrites.
        delTag = ''; if isPendDeletedSite(e), delTag = '   ✗ MARKED FOR DELETION'; end
        title(axSite, sprintf(['cell %d · site %d · win %d [%g–%g] · cloud %d locs · %d tracked (%d trk)%s' delTag], ...
            e.cellIndex, e.csID, e.window, e.winFrames(1), e.winFrames(2), e.nLocInside, e.nMemberLocs, e.nTracks, ftag));
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

    function onDeleteSite()
        % Mark/unmark the SELECTED site for deletion. Deliberately writes the SAME CSdeleted list the
        % Refine tab writes, rather than a second mechanism — the mapper already skips those sites,
        % so one list means one truth about which sites exist.
        if isempty(CSW) || siteSelIdx < 1 || siteSelIdx > numel(CSW)
            lblSites.Text = 'Select a site first.'; return;
        end
        e = CSW(siteSelIdx);
        ppx = []; if isfield(e,'pickPx'), ppx = e.pickPx; end
        dup = arrayfun(@(x) strcmp(x.file,e.file)&&x.csID==e.csID&&x.window==e.window, pendDelSite);
        if any(dup), pendDelSite(dup) = []; act = 'unmarked';
        else, pendDelSite(end+1) = struct('file',e.file,'csID',e.csID,'window',e.window,'pickPx',ppx); act = 'marked for DELETION'; end
        drawSiteInspector(siteSelIdx);
        lblSites.Text = sprintf('Site %d %s · %d site(s) and %d track(s) pending. 💾 Save removals to apply.', ...
            e.csID, act, numel(pendDelSite), numel(pendExcl));
    end

    function [dIn, dOut, perTrk] = siteTrackD(e)
        % Each member track's ROLLING D, split by whether the localization sat inside this site.
        %
        % This is the question the tab exists for — does a molecule move differently while it is at a
        % contact site — and it is answerable from what is already stored: Tracks(k).Dt is one
        % diffusion estimate per localization, CSmatrix is those same localizations relative to the
        % site centre, and refboundary is the footprint. Same rows, same columns, so the mask lines up
        % without re-deriving anything.
        %
        % Returns the POOLED medians (for the table) and a per-track struct (for the plot). NaN where
        % a track has no localization on one side — a track fully inside has no 'out' value, and
        % inventing one would read as a measured zero.
        dIn = NaN; dOut = NaN;
        perTrk = struct('col',{},'dIn',{},'dOut',{},'nIn',{},'nOut',{},'t',{},'d',{},'in',{});
        if isempty(e) || ~isfield(e,'tracks') || isempty(e.tracks), return; end
        if isempty(buildTracks) || e.cellIndex < 1 || e.cellIndex > numel(buildTracks), return; end
        T = buildTracks(e.cellIndex);
        if ~isfield(T,'Dt') || isempty(T.Dt), return; end
        cols = e.tracks(:)';
        if max(cols) > size(T.Dt,2), return; end

        bx = e.refboundary(:,1); by = e.refboundary(:,2);      % µm, relative to the site centre
        allIn = []; allOut = [];
        for q = 1:numel(cols)
            n  = min(size(T.Dt,1), size(e.CSmatrix,1));
            d  = T.Dt(1:n, cols(q));
            x  = e.CSmatrix(1:n, q, 2); y = e.CSmatrix(1:n, q, 3);
            fr = e.CSmatrix(1:n, q, 1);
            ok = isfinite(d) & isfinite(x) & isfinite(y);
            if ~any(ok), continue; end
            in = false(size(ok));
            in(ok) = inpolygon(x(ok), y(ok), bx, by);
            di = d(ok &  in); do_ = d(ok & ~in);
            perTrk(end+1) = struct('col',cols(q), ...
                'dIn', med0(di), 'dOut', med0(do_), 'nIn', numel(di), 'nOut', numel(do_), ...
                't', fr(ok), 'd', d(ok), 'in', in(ok)); %#ok<AGROW>
            allIn = [allIn; di]; allOut = [allOut; do_]; %#ok<AGROW>
        end
        dIn = med0(allIn); dOut = med0(allOut);
    end

    function v = med0(x)
        x = x(isfinite(x)); if isempty(x), v = NaN; else, v = median(x); end
    end

    function s = fmtD_(v)
        if ~isfinite(v), s = '–'; else, s = sprintf('%.3f', v); end
    end

    function tf = isPendDeletedSite(e)
        tf = ~isempty(pendDelSite) && ...
             any(arrayfun(@(x) strcmp(x.file,e.file)&&x.csID==e.csID&&x.window==e.window, pendDelSite));
    end

    function tf = isPendRemoved(e, col)   % is this member track marked (pending) for removal?
        tf = ~isempty(pendExcl) && any(arrayfun(@(x) strcmp(x.file,e.file)&&x.csID==e.csID&&x.window==e.window&&x.trackCol==col, pendExcl));
    end

    function onSaveRemovals()
        % Write ALL pending removals into CS_trackedits.mat (merged) and re-run the mapper once to apply.
        if isempty(pendExcl) && isempty(pendDelSite)
            lblSites.Text='Nothing marked — mark a track or a site for removal first (🗑).'; return; end
        anaDir = ensureAnaDir(); if isempty(anaDir), return; end
        % whole-site deletions first, MERGED into whatever Refine already wrote
        nSite = numel(pendDelSite);
        if nSite > 0
            ff = fullfile(anaDir,'CS_footprints.mat');
            CSfoot = struct([]); CSdeleted = struct('file',{},'csID',{},'window',{},'pickPx',{});
            if isfile(ff)
                try, Lf=load(ff);
                    if isfield(Lf,'CSfoot'), CSfoot = Lf.CSfoot; end
                    if isfield(Lf,'CSdeleted') && ~isempty(Lf.CSdeleted), CSdeleted = Lf.CSdeleted; end
                catch, end
            end
            for q = 1:nSite
                r = pendDelSite(q);
                dup = arrayfun(@(x) strcmp(x.file,r.file)&&x.csID==r.csID&&x.window==r.window, CSdeleted);
                if ~any(dup), CSdeleted(end+1) = r; end %#ok<AGROW>
            end
            try, save(ff,'CSfoot','CSdeleted','-v7.3'); %#ok<NASGU>
            catch ME, lblSites.Text=['Save failed: ' ME.message]; return; end
            pendDelSite(:) = [];
        end
        if isempty(pendExcl)
            lblSites.Text = sprintf('Deleted %d site(s) → re-running the mapper…', nSite); drawnow;
            onRunMapper(); return;
        end
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
        lblSites.Text = sprintf('Saved %d track removal(s) + %d site deletion(s) → re-running the mapper…', np, nSite); drawnow;
        onRunMapper();   % rebuild CSW_final.mat once, without every removed track
    end

    function R = buildSiteR(e, onlyCols)
        % Build a spt_track_movie R struct from a site's member tracks (all, or only onlyCols). CSmatrix
        % is µm RELATIVE to the site centre → absolute µm (+centre) → raw-movie pixels (x = X/px + 1,
        % px being THIS cell's pixel size, which need not match the rest of the project).
        if nargin<2, onlyCols = []; end
        R = [];
        [sp,er,mi] = matchedPaths(e.file);
        if isempty(sp) || ~isfile(sp), return; end
        pxc = trackPx(e.cellIndex);
        dtc = trackDt(e.cellIndex); secs = secsMode();
        cx = e.center(1); cy = e.center(2);
        xAll=[]; yAll=[]; fAll=[]; idAll=[];
        for jj = 1:numel(e.tracks)
            if ~isempty(onlyCols) && ~ismember(e.tracks(jj), onlyCols), continue; end
            fr = e.CSmatrix(:,jj,1); x = e.CSmatrix(:,jj,2)+cx; y = e.CSmatrix(:,jj,3)+cy;
            keep = isfinite(x) & isfinite(y) & isfinite(fr);
            if ~any(keep), continue; end
            if secs, f0 = round(fr(keep)/max(dtc,eps)); else, f0 = round(fr(keep)); end
            xAll = [xAll; x(keep)/pxc + 1]; yAll = [yAll; y(keep)/pxc + 1]; %#ok<AGROW>
            fAll = [fAll; f0(:)]; idAll = [idAll; e.tracks(jj)*ones(nnz(keep),1)]; %#ok<AGROW>
        end
        if isempty(xAll), return; end
        csPx = [];   % contact-site outline in raw-movie pixels (same µm->px map) — overlaid via the player's CS toggle
        if isfield(e,'refboundary') && size(e.refboundary,1)>=3
            csPx = [(e.refboundary(:,1)+cx)/pxc + 1, (e.refboundary(:,2)+cy)/pxc + 1];
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
        r = uigridlayout(g,[1 5],'ColumnWidth',{170, 44, 72, '1x', 0},'Padding',[0 0 0 0],'ColumnSpacing',8);
        uibutton(r,'Text','▶ Compute dwell','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70],'FontColor','w', ...
            'Tooltip','Residence of each member track in its site''s own window (span+1 accounting) -> analysis/cs_window_dwell.csv.', ...
            'ButtonPushedFcn',@(s,e) onComputeDwell());
        % The same criterion the Sites tab filters its member list on, applied at the point where it
        % changes a NUMBER rather than a display: dwell is computed over the kept tracks only.
        uilabel(r,'Text','≥% in','HorizontalAlignment','right');
        eMinDwPct = uispinner(r,'Limits',[0 100],'Value',0,'Step',5,'RoundFractionalValues',true, ...
            'Tooltip',['Compute dwell over member tracks with at least this % of their window ' ...
            'localizations INSIDE the site — dwelling molecules rather than ones passing through. ' ...
            '0 = every member. Raising it can only raise mean dwell and lower k_out (it removes the ' ...
            'short visits), so report the threshold alongside the number. Recompute after changing it.']);
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
        spt_axes_policy([axDwHist axKout axDwDens axDwTrace]);
        % animation controls for the density panel: play the track over the density + ER/mito overlay + save video
        ac = uigridlayout(rc,[1 11],'ColumnWidth',{58,'1x',124,30,42, 52,52, 26,46, 84,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
        btnDwPlay = uibutton(ac,'Text','▶ Play','Tag','dwPlay','ButtonPushedFcn',@(s,e) onDwellPlay(), ...
            'Tooltip','Animate the selected track over the chosen backdrop (with the ER/mito overlay).');
        sldDwFrame = uislider(ac,'Limits',[0 1],'Value',0,'Tag','dwFrame','MajorTicks',[],'MinorTicks',[], ...
            'ValueChangedFcn',@(s,e) onDwellScrub(), 'Tooltip','Scrub through the track''s frames.');
        ddDwBg = uidropdown(ac,'Items',{'density (accumulated)','raw movie'},'Value','density (accumulated)','Tag','dwBg', ...
            'Tooltip','Backdrop: the accumulated localization density (shows the site + dwell context) or the raw SPT movie frame-by-frame (the actual data). The contact-site outline + dwell colouring + ER/mito overlay draw on either.', ...
            'ValueChangedFcn',@(s,e) onDwellBg());
        % One overlay checkbox per declared channel, generated. mito stays ticked by default and ER
        % unticked, as they always were; a newly declared channel starts unticked.
        dwKeys = cs_channel_keys(cs_channel_config(projectDir));
        chkDwChan = gobjects(1, numel(dwKeys));
        for kDw = 1:numel(dwKeys)
            Fd = cs_channel_fields(dwKeys{kDw});
            lab = Fd.label; if ~strcmp(lab, upper(lab)), lab = lower(lab); end
            chkDwChan(kDw) = uicheckbox(ac,'Text',lab,'Value',strcmp(Fd.key,'mito'), ...
                'Tag',['dw_' Fd.key],'ValueChangedFcn',@(s,e) dwellRedraw(), ...
                'Tooltip',sprintf('Overlay the %s segmentation at the current frame.', Fd.label));
        end
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
        mp = 0; if ~isempty(eMinDwPct) && isgraphics(eMinDwPct), mp = eMinDwPct.Value; end
        try, DD = cs_window_dwell(anaDir, struct('save',true,'verbose',false,'minPctInside',mp));
        catch ME, lblDwell.Text=['Dwell error: ' ME.message]; return; end
        drawDwell();
        % Say what was computed — the label used to be left reading "Computing dwell…" forever, and
        % with a threshold in play the reader has to be told which tracks are behind the numbers.
        nEv = numel(DD.events); nSite = numel(DD.perSite); nTr = numel(DD.perTrack);
        lblDwell.Text = sprintf('%d events · %d site-windows · %d member tracks%s', nEv, nSite, nTr, ...
            tern(mp>0, sprintf(' with ≥%g%% of their localizations inside', mp), ''));
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
        ov = struct('er','','mito','','seg',struct()); try, ov = resolveOverlay(ee.file); catch, end
        segAll = struct(); if isfield(ov,'seg') && isstruct(ov.seg), segAll = ov.seg; end
        bg = 'density (accumulated)'; if ~isempty(ddDwBg) && isgraphics(ddDwBg), bg = ddDwBg.Value; end
        da = struct('cUm',cUm,'bx',bx,'by',by,'dens',Dens,'SF',SF,'grid',g, ...
            'xa',xa(:),'ya',ya(:),'fr',fr(:),'ii',logical(ii(:)),'n',numel(fr), ...
            'xlim',[min(bx)-pad max(bx)+pad],'ylim',[min(by)-pad max(by)+pad], ...
            'erPath',ov.er,'mitoPath',ov.mito,'seg',segAll,'sptPath',ov.spt,'cellIndex',ee.cellIndex, ...
            'backdrop',bg,'rawH',[],'rawW',[],'rawN',0,'rawLo',[],'rawHi',[], ...
            'orgCache',containers.Map('KeyType','char','ValueType','any'), ...
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
        % Enable each channel's box only if that channel actually resolved a stack for this cell.
        anySeg = false;
        for kEn = 1:numel(chkDwChan)
            h = chkDwChan(kEn); if ~isgraphics(h), continue; end
            kk_ = regexprep(char(h.Tag), '^dw_', '');
            hasIt = isfield(da.seg,kk_) && ~isempty(da.seg.(kk_)) && isfile(da.seg.(kk_));
            h.Enable = tern(hasIt,'on','off'); if ~hasIt, h.Value = false; end
            anySeg = anySeg || hasIt;
        end
        dwellRedraw(n);
        if ~isempty(lblDwAnim) && isgraphics(lblDwAnim)
            lblDwAnim.Text = sprintf('%d frames%s', n, tern(anySeg,'',' · no reference-channel seg'));
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
                pxc = trackPx(da.cellIndex);
                da.h.bg = imagesc(ax, [0 (da.rawW-1)*pxc], [0 (da.rawH-1)*pxc], zeros(da.rawH,da.rawW)); colormap(ax,gray); da.rawLo = []; da.rawHi = [];
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
        hold(axDwDens,'on');
        % One filled overlay per ticked channel. The pinned pair keeps this panel's published fill
        % colours; anything newly declared takes the shared rota (cs_channel_colour).
        DWPIN = struct('er',[0.2 1 0.35], 'mito',[1 0.25 1]);
        for kSh = 1:numel(chkDwChan)
            h = chkDwChan(kSh);
            if ~isgraphics(h) || ~strcmp(h.Enable,'on') || ~h.Value, continue; end
            kk_ = regexprep(char(h.Tag), '^dw_', '');
            oh = addOrgFill(oh, dwellOrgMask(da, kk_, da.fr(i)), cs_channel_colour(kk_, kSh, DWPIN));
        end
        % filled masks sit just ABOVE the backdrop but BELOW the outline/track (drop them to the
        % bottom, then push the backdrop below them) so the trajectory stays visible through the tint
        if ~isempty(oh)
            try, uistack(oh,'bottom'); if ~isempty(da.h.bg)&&isgraphics(da.h.bg), uistack(da.h.bg,'bottom'); end, catch, end
        end
        dwellAnim.h.org = oh;
        title(axDwDens, sprintf('%s · frame %d/%d%s', da.title, i, n, tern(inHead,' · INSIDE','')));
    end

    function m = dwellOrgMask(da, which, frameVal)
        % Cropped mask + its µm extent for ONE channel at this track point's movie frame — for a
        % FILLED overlay (like the players' tint) rather than an outline. Cached in da.orgCache (a
        % handle Map, shared with dwellAnim). Registration: seg µm/px = FOVUM/seg width; frame→seg
        % page = frame+1 (0-based; seconds mode divides by dt first). No imfinfo here — walking all
        % IFDs of the multi-thousand-frame seg stack was the toggle/scrub hang; an out-of-range page
        % just returns [] via the catch.
        %
        % `which` is a CHANNEL KEY. It used to be a two-way test — mito took da.mitoPath and
        % EVERYTHING ELSE took da.erPath — so a third channel silently read the ER stack and cached
        % under the ER slot: the wrong mask drawn under the right label, with no error. The path now
        % comes from the keyed da.seg, and the cache key is a string, so channels cannot collide.
        m = [];
        which = char(which);
        p = '';
        if isfield(da,'seg') && isstruct(da.seg) && isfield(da.seg, which), p = da.seg.(which); end
        if isempty(p) || ~isfile(p), return; end
        if secsMode(), fIdx = round(frameVal/max(trackDt(da.cellIndex),eps)); else, fIdx = round(frameVal); end
        segIdx = max(fIdx + 1, 1);
        keyv = sprintf('%s@%d', which, segIdx);
        if isKey(da.orgCache,keyv), m = da.orgCache(keyv); return; end
        try
            im = imread(p, segIdx); if size(im,3)==3, im = rgb2gray(im); end
            v = unique(im(:)); nz = v(v>0); fg = 1; if ~isempty(nz), fg = double(min(nz)); end
            mask = (im == fg);
            % The mask spans the same field as the tracks, in the SAME coordinate convention:
            % X_um = (0-based column) * pixUm, so the step is fov/(W-1) and column c (1-based) sits
            % at (c-1)*ux. It used to divide by W and place column c at c*ux, which shifts the whole
            % overlay by one camera pixel — 0.1 µm here, against contact sites 0.1-0.5 µm across.
            % Display only: the ER/mito DISTANCES come from Tool 1's CSV and are untouched by this,
            % which is exactly why the drawn mask could disagree with the numbers beside it.
            fovc = trackFov(da.cellIndex);
            segH = size(mask,1); segW = size(mask,2);
            ux = fovc/max(segW-1,1); uy = fovc/max(segH-1,1);
            c0 = max(1,floor(da.xlim(1)/ux)+1); c1 = min(segW,ceil(da.xlim(2)/ux)+1);
            r0 = max(1,floor(da.ylim(1)/uy)+1); r1 = min(segH,ceil(da.ylim(2)/uy)+1);
            if c1>c0 && r1>r0
                m = struct('mask', mask(r0:r1, c0:c1), ...
                           'xd',[(c0-1)*ux (c1-1)*ux], 'yd',[(r0-1)*uy (r1-1)*uy]);
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
        % Editing a calibration here must reach the TOP BAR and the files, not just this table.
        % Without this the manifest held the corrected value, spt_project_calib now honoured it, and
        % nothing asked it again until the project was reopened — so the tool went on analysing at
        % the fallback while the Experiment tab displayed the correction. onCalAuto re-resolves and,
        % because an edited pixel size counts as supported, persists it to cs_calib.mat, which is
        % what every downstream stage reads.
        opts.onChange = @(m) onManifestChanged();
        exptCtl = spt_experiment_panel(parent, opts);
    end

    % ================= Tab 8 · Engagement (diffusion contrast at the organelle) =================
    % Per CELL, not per site: this asks whether molecules are slowed where they meet the organelle,
    % which needs no contact-site mapping at all — only the per-localization distance the build
    % already carries. That makes it usable on a plate of cells that were never picked or mapped.
    function buildEngageTab(parent)
        g = uigridlayout(parent,[3 1],'RowHeight',{34,26,'1x'},'Padding',[10 10 10 10],'RowSpacing',6);
        r = uigridlayout(g,[1 18],'ColumnWidth',{36,120, 36,64, 56,48,48,36, 62,50, 52,48, 62,50, 78, 78, 42, 112}, ...
            'Padding',[0 0 0 0],'ColumnSpacing',5);
        uilabel(r,'Text','data','HorizontalAlignment','right');
        engDd = uidropdown(r,'Items',{'current project','experiment (all folders)'},'Value','current project', ...
            'Tooltip','This project''s active build, or every folder in the Experiment tab (each folder''s own build).');
        uilabel(r,'Text','near','HorizontalAlignment','right');
        engKey = uidropdown(r,'Items',{'mito','er'},'Value','mito', ...
            'Tooltip','Which reference channel counts as the interface.');
        uilabel(r,'Text','distance µm','HorizontalAlignment','right', ...
            'Tooltip',['The engagement zone: a step counts as BOUND when it STARTS at a signed ' ...
            'distance <= this. The distance is SIGNED — negative is INSIDE the organelle mask — so ' ...
            'd = 0.1 means "inside, or within 100 nm outside", and everything inside is already ' ...
            'included. Set a NEGATIVE d to require being at least that far inside. ' ...
            'The two boxes are the ENDS of a scan and the third is how many values between them ' ...
            '(6 over 0.01-0.3 gives 0.01, 0.068, 0.126, 0.184, 0.242, 0.3). Scan rather than fixing ' ...
            'one value: the distance at which the contrast disappears is itself a result — roughly ' ...
            'the depth of the engaged layer — and one number chosen up front hides it.']);
        % NEGATIVE thresholds are allowed. The distance is SIGNED — negative is inside the mask —
        % and the zone test is `dist <= d`, so a positive d already includes everything inside plus
        % a shell of that width outside. A NEGATIVE d asks the stricter question: count only what is
        % at least |d| INSIDE the organelle. The limits used to start at 0.01, which made that
        % question unaskable and left the impression that inside-the-mask localizations were being
        % missed. They never were.
        engD0 = uispinner(r,'Limits',[-2 5],'Value',0.05,'Step',0.05,'ValueDisplayFormat','%.3g');
        engD1 = uispinner(r,'Limits',[-2 5],'Value',0.30,'Step',0.05,'ValueDisplayFormat','%.3g');
        engN  = uispinner(r,'Limits',[1 20],'Value',6,'Step',1,'Tooltip','How many distances to scan between those two.');
        uilabel(r,'Text','precision nm','HorizontalAlignment','right', ...
            'Tooltip','Localization precision, for the noise floor subtracted from every step.');
        engSig = uispinner(r,'Limits',[0 500],'Value',30,'Step',5);
        uilabel(r,'Text','min steps','HorizontalAlignment','right', ...
            'Tooltip',['A cell needs this many steps in EACH class — bound AND free — before a D ' ...
            'ratio is reported; below it the row shows a dash and says "too few steps (bound N, ' ...
            'free M)". It guards the RATIO only: a D from 12 steps is not a measurement. The ' ...
            'occupancy columns ignore it, because counting localizations needs no step statistics, ' ...
            'so a sparse cell still gets an occupancy.']);
        engMin = uispinner(r,'Limits',[5 5000],'Value',100,'Step',25);
        uilabel(r,'Text','engaged ≥','HorizontalAlignment','right', ...
            'Tooltip',['A TRACK counts as engaged when at least this fraction of its own ' ...
                       'localizations lie inside the zone. 0.5 = "spends more than half its time ' ...
                       'at the organelle". This sets the "eng %" column, which is the share of ' ...
                       'MOLECULES engaged — not the share of time, and not weighted by track length.']);
        engEngF = uispinner(r,'Limits',[0.05 1],'Value',0.5,'Step',0.05,'ValueDisplayFormat','%.2f');
        uibutton(r,'Text','▶ Compute','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70],'FontColor','w', ...
            'ButtonPushedFcn',@(s,e) onEngageCompute());
        uibutton(r,'Text','Export CSV','ButtonPushedFcn',@(s,e) onEngageExport(), ...
            'Tooltip','One row per cell per distance, with the step counts — the file you would score compounds from.');
        engNEx = uispinner(r,'Limits',[1 12],'Value',5,'Step',1, ...
            'Tooltip','How many example tracks to DRAW per condition. The export writes all of them.');
        bEngEx = uibutton(r,'Text','Examples → Tool 2','ButtonPushedFcn',@(s,e) onEngageExamples(), ...
            'Tooltip',['Write a TrackStruct holding every track that touches the zone — the same ' ...
                       'population D_bound is built from — and open it in Tool 2 with Load ' ...
                       'TrackStruct… for the player, MSD, stepwise D(t), CSD and the per-track D ' ...
                       'export, on exactly these tracks.']);
        engLbl = uilabel(g,'Text','Needs a built TrackStruct with a mito/ER distance. Set the project, then Compute.', ...
            'FontColor',[0.2 0.4 0.5],'WordWrap','on');
        mn = uigridlayout(g,[1 2],'ColumnWidth',{'1.15x','0.85x'},'Padding',[0 0 0 0],'ColumnSpacing',8);
        engTbl = uitable(mn,'ColumnName',{'cell','condition','d µm','D bound','D free','ratio', ...
                                          'occ med','eng %','k_off /s','k_on /s','n bound','n free','note'}, ...
            'ColumnWidth',{'1x',80,42,54,54,48,50,44,54,50,50,50,120});
        rc = uigridlayout(mn,[3 1],'RowHeight',{'1x','1x','1.1x'},'Padding',[0 0 0 0],'RowSpacing',6);
        engAxCell = uiaxes(rc); title(engAxCell,'D ratio per cell (at the chosen distance)');
        engAxScan = uiaxes(rc); title(engAxScan,'D ratio vs engagement distance');
        % The examples. A number on a plot is a claim about trajectories; this is the trajectories.
        engAxEx = uiaxes(rc); title(engAxEx,'example tracks at the interface (Compute to fill)');
        engAxCell.Layout.Row = 1; engAxScan.Layout.Row = 2; engAxEx.Layout.Row = 3;
        spt_axes_policy([engAxCell engAxScan engAxEx]);
    end

    function onEngageCompute()
        if ~ensureTracksLoaded()
            engLbl.Text = 'No built TrackStruct for this project — build it in Tool 2 first.'; return;
        end
        % HAND-REJECTED TRACKS ARE DROPPED BEFORE THE RATIO IS COMPUTED. That is the whole point of
        % curating: look at a track, decide it is not real, and have the number change. Re-read from
        % disk each time so a rejection made in Tool 2 (a separate app on the same project) is
        % honoured here without reopening.
        try, trkEx = cs_track_exclusions('load', projectDir); catch, trkEx = []; end
        T = cs_track_exclusions('apply', trkEx, buildTracks);
        nEx = cs_track_exclusions('count', trkEx);
        % ...then whole cells the Experiment tab excluded. Order matters only for the counts: track
        % rejections inside an excluded cell are still counted as rejections, which is honest.
        [keepC, nDropC] = engageKeepCells(T);
        T = T(keepC);
        if isempty(T)
            engLbl.Text = sprintf(['Every cell is marked EXCLUDE on the Experiment tab (%d of %d), ' ...
                'so there is nothing left to measure.'], nDropC, numel(buildTracks));
            return
        end
        % The data dropdown offers 'experiment (all folders)' and this function has only ever
        % measured the CURRENT project's build. A control that silently does nothing is worse than
        % one that is absent, so it says which it used rather than letting the label imply the other.
        engScopeNote = '';
        if ~isempty(engDd) && isgraphics(engDd) && contains(string(engDd.Value),'experiment')
            engScopeNote = '  ·  NOTE: measured THIS project''s build only — cross-folder pooling is not implemented here yet.';
        end
        dl = linspace(engD0.Value, engD1.Value, round(engN.Value));
        o = struct('dUm',dl, 'key',engKey.Value, 'sigmaUm',engSig.Value/1000, 'minSteps',engMin.Value);
        try
            E = cs_mito_engage(T, o);
        catch ME
            engLbl.Text = ['Engagement failed: ' ME.message]; return;
        end
        engLast = E;
        engExN = nEx; engDropC = nDropC;
        if ~isempty(bEngEx) && isgraphics(bEngEx)
            bEngEx.Text = 'Examples → Tool 2';
            bEngEx.BackgroundColor = [0.96 0.96 0.96];
            bEngEx.FontWeight = 'normal';
        end

        % PER-TRACK OCCUPANCY, at every distance in the scan. Cheap (it is a count), and per
        % distance because the table is per cell x distance and occupancy varies with d exactly as
        % the ratio does. Computed on the SAME curated T, so the two columns of a row describe the
        % same set of molecules.
        engOccT = struct('med',nan(size(E)), 'eng',nan(size(E)), 'n',zeros(size(E)), ...
                         'kOff',nan(size(E)), 'kOn',nan(size(E)), ...
                         'nEnd',zeros(size(E)), 'nCens',zeros(size(E)), ...
                         'tB',zeros(size(E)), 'tF',zeros(size(E)), 'perTrack',{{}});
        for q = 1:numel(dl)
            [ptq, pcq] = cs_track_occupancy(T, struct('dUm',dl(q), 'key',engKey.Value, ...
                'minLoc',5, 'engFrac',engEngF.Value));
            % Kinetics at the same distance and on the same curated set, so every column of a table
            % row describes one partition of one set of molecules.
            kq = cs_zone_kinetics(T, struct('dUm',dl(q), 'key',engKey.Value, 'minLoc',5));
            for k = 1:numel(pcq)
                engOccT.med(k,q) = pcq(k).occMedian;
                engOccT.eng(k,q) = pcq(k).engagedFrac;
                engOccT.n(k,q)   = pcq(k).nScored;
                engOccT.kOff(k,q)= kq(k).kOff;   engOccT.kOn(k,q)  = kq(k).kOn;
                engOccT.nEnd(k,q)= kq(k).nEnd;   engOccT.nCens(k,q)= kq(k).nCensored;
                engOccT.tB(k,q)  = kq(k).tBound; engOccT.tF(k,q)   = kq(k).tFree;
            end
            engOccT.perTrack{q} = ptq;
        end
        cond = engageConditions({E(:,1).file});
        try
            [selEx, ~, dEx] = engageExampleSel();
            drawEngageExamples(selEx, dEx);
        catch MEx
            if isgraphics(engAxEx), cla(engAxEx); title(engAxEx, ['examples unavailable: ' MEx.message]); end
        end

        % Table: every cell at every distance, so a cell that only engages at one radius is visible
        % rather than hidden behind a single chosen number.
        D = cell(numel(E), 13); rr = 0;
        for k = 1:size(E,1)
            for q = 1:size(E,2)
                rr = rr + 1; e = E(k,q);
                D(rr,:) = {e.file, cond{k}, sprintf('%.3g',e.dUm), ...
                    numOrDash(e.Dbound), numOrDash(e.Dfree), numOrDash(e.Dratio), ...
                    numOrDash(engOccT.med(k,q)), pctOrDash(engOccT.eng(k,q)), ...
                    kOrDash(engOccT.kOff(k,q), engOccT.nEnd(k,q)), numOrDash(engOccT.kOn(k,q)), ...
                    sprintf('%d',e.nBound), sprintf('%d',e.nFree), tern(e.ok,'',e.why)};
            end
        end
        engTbl.Data = D;

        % per-cell ratio at the LAST distance in the scan that the cell could answer at
        cla(engAxCell); hold(engAxCell,'on');
        qMid = max(1, round(size(E,2)/2));
        vals = arrayfun(@(e) e.Dratio, E(:,qMid));
        okc  = arrayfun(@(e) e.ok, E(:,qMid));
        [ug,~,gi] = unique(cond(:),'stable');
        for j = 1:numel(ug)
            v = vals(gi==j & okc); if isempty(v), continue; end
            xj = j + 0.12*(rand(numel(v),1)-0.5)*2;
            plot(engAxCell, xj, v, 'o','MarkerFaceColor',[0.45 0.55 0.75],'MarkerEdgeColor','none','MarkerSize',5);
            plot(engAxCell, j, median(v), '_','Color',[0.85 0.25 0.2],'MarkerSize',26,'LineWidth',2);
        end
        yline(engAxCell, 1, ':', 'no contrast');   % the null: bound and free diffuse alike
        hold(engAxCell,'off');
        xlim(engAxCell,[0.5 numel(ug)+0.5]); xticks(engAxCell,1:numel(ug)); xticklabels(engAxCell,ug);
        xtickangle(engAxCell, tern(numel(ug)>4,30,0));
        ylabel(engAxCell,'D bound / D free');
        title(engAxCell, sprintf('D ratio per cell at d = %.3g µm', E(1,qMid).dUm));

        % the scan: one line per condition, median over its cells
        cla(engAxScan); hold(engAxScan,'on'); leg = {};
        for j = 1:numel(ug)
            m = nan(1,size(E,2));
            for q = 1:size(E,2)
                v = arrayfun(@(e) e.Dratio, E(gi==j,q));
                v = v(isfinite(v)); if ~isempty(v), m(q) = median(v); end
            end
            if all(isnan(m)), continue; end
            plot(engAxScan, dl, m, '-o','LineWidth',1.4,'MarkerSize',4); leg{end+1} = ug{j}; %#ok<AGROW>
        end
        yline(engAxScan, 1, ':');
        hold(engAxScan,'off'); xlabel(engAxScan,'engagement distance (µm)'); ylabel(engAxScan,'median D ratio');
        if ~isempty(leg), legend(engAxScan, leg, 'Location','best'); end
        title(engAxScan,'D ratio vs engagement distance');

        nOK = sum(arrayfun(@(e) e.ok, E(:)));
        % Name the curation on the status line. A ratio computed after rejecting tracks is a
        % different measurement from one computed before, and the difference must not be invisible.
        exTxt = '';
        if engExN > 0
            exTxt = sprintf('  ·  %d hand-rejected track(s) EXCLUDED (analysis/track_exclusions.csv)', engExN);
        end
        if engDropC > 0
            exTxt = sprintf('%s  ·  %d cell(s) EXCLUDED on the Experiment tab', exTxt, engDropC);
        end
        engLbl.Text = sprintf(['%d cell(s) x %d distance(s) · %d answered · %s within %.3g–%.3g µm · ' ...
            'precision %g nm · min %d steps per class. A ratio below 1 means slowed at the interface; ' ...
            '1 means no contrast.%s%s'], size(E,1), size(E,2), nOK, engKey.Value, dl(1), dl(end), ...
            engSig.Value, round(engMin.Value), exTxt, engScopeNote);
    end

    function closeIfOpen(fid)
        try, if ~isempty(fid) && fid > 2 && ~isempty(fopen(fid)), fclose(fid); end, catch, end
    end

    function t = kOrDash(v, nEnd)
        % A k_off of 0 is not a rate — it is "no episode was seen to end here", which happens when
        % every episode is still running when its track stops. Showing 0 would read as "never
        % unbinds", the opposite of "unmeasured", so it shows a dash and the export carries n_ended.
        if ~(isscalar(v) && isfinite(v)) || nEnd < 1, t = '—'; else, t = sprintf('%.3g', v); end
    end

    function t = pctOrDash(v)
        if isscalar(v) && isfinite(v), t = sprintf('%.0f%%', 100*v); else, t = '—'; end
    end

    function c = engageConditions(files)
        % Condition per cell from the experiment manifest, matched on the cell FILE name. Falls back
        % to the file itself, exactly as the Compare tab does in project mode — a label that is
        % honest about being one cell rather than a group.
        c = files(:)';
        for i = 1:numel(c), if isempty(c{i}), c{i} = sprintf('cell %d', i); end, end
        if isempty(exptCtl) || ~isstruct(exptCtl), return; end
        try, cells = exptCtl.getCells(); catch, return; end
        if isempty(cells), return; end
        for i = 1:numel(c)
            for k = 1:numel(cells)
                if strcmp(char(cells(k).file), files{i}) && ~isempty(cells(k).condition)
                    c{i} = char(cells(k).condition); break;
                end
            end
        end
    end

    function [keep, nDrop] = engageKeepCells(Tracks)
        % Cells the Experiment tab has marked EXCLUDE are dropped before anything is measured. That
        % flag is the durable, per-cell judgement — a dying cell, bad segmentation, a density far off
        % the rest — and cs_experiment_aggregate has always honoured it. Engagement did not, so the
        % same plate gave one answer in Compare and another here, with nothing on screen to say why.
        %
        % Matched on the cell FILE name, the same key engageConditions uses, so a cell cannot be
        % excluded under one identity and grouped under another.
        keep = true(1, numel(Tracks)); nDrop = 0;
        if isempty(exptCtl) || ~isstruct(exptCtl), return; end
        try, cells = exptCtl.getCells(); catch, return; end
        if isempty(cells) || ~isfield(cells,'exclude'), return; end
        for i = 1:numel(Tracks)
            f = ''; if isfield(Tracks(i),'file'), f = char(Tracks(i).file); end
            if isempty(f), continue; end
            h = find(strcmp({cells.file}, f), 1);
            if ~isempty(h) && ~isempty(cells(h).exclude) && logical(cells(h).exclude)
                keep(i) = false; nDrop = nDrop + 1;
            end
        end
    end

    function [selE, TsubE, dEx] = engageExampleSel()
        % The shared selection: every track with at least one step STARTING in the zone, at the
        % scan's middle distance — the same distance the per-cell plot reports, so the pictures and
        % the number describe the same thing.
        selE = []; TsubE = []; dEx = NaN;
        if ~ensureTracksLoaded() || isempty(buildTracks), return; end
        dl = linspace(engD0.Value, engD1.Value, round(engN.Value));
        dEx = dl(max(1, round(numel(dl)/2)));
        % The SAME curated set the ratio was computed on — otherwise the gallery would show, and the
        % export would hand to Tool 2, tracks the number no longer counts.
        try, trkEx = cs_track_exclusions('load', projectDir); catch, trkEx = []; end
        Tcur = cs_track_exclusions('apply', trkEx, buildTracks);
        Tcur = Tcur(engageKeepCells(Tcur));      % the same cells the ratio was computed on
        [selE, TsubE] = cs_engage_examples(Tcur, struct('dUm',dEx,'key',engKey.Value));
    end

    function drawEngageExamples(selE, dEx)
        % One ROW per condition, N tracks across. Each track is drawn on its own crop of the
        % organelle mask, so "around the mitochondria" is literal rather than implied, and each
        % localization is coloured by whether it is INSIDE the zone — the same test that decides
        % which pool its step joins.
        if isempty(engAxEx) || ~isgraphics(engAxEx), return; end
        cla(engAxEx); engAxEx.Visible = 'on';
        if isempty(selE)
            title(engAxEx,'example tracks — nothing selected'); return;
        end
        nPer = 5; if ~isempty(engNEx) && isgraphics(engNEx), nPer = round(engNEx.Value); end
        cond = engageConditions({selE.file});
        [ug,~,gi] = unique(cond(:),'stable');

        PAD = 0.55;                 % µm of margin around each track, so the mask context is visible
        CELLW = 1.0;                % one grid cell of the gallery, in normalized units
        hold(engAxEx,'on');
        rng(7);                     % a fixed seed: the same examples every time you press Compute
        nDrawn = 0;
        for j = 1:numel(ug)
            rows = find(gi == j);
            % Flatten (cell, track) pairs for this condition, then take an unbiased sample of them.
            pairs = [];
            for r = rows(:)'
                for c = selE(r).cols, pairs(end+1,:) = [r c]; end %#ok<AGROW>
            end
            if isempty(pairs), continue; end
            take = pairs(randperm(size(pairs,1), min(nPer, size(pairs,1))), :);
            for m = 1:size(take,1)
                k = take(m,1); c = take(m,2);
                T = buildTracks(selE(k).cellIndex);
                X = T.matrix(:,c,2); Y = T.matrix(:,c,3);
                ok = isfinite(X) & isfinite(Y); X = X(ok); Y = Y(ok);
                if numel(X) < 2, continue; end
                [dv, have] = cs_channel_dist(T, engKey.Value, 'tracked');
                inz = false(size(X));
                if have && numel(dv) == numel(T.matrix(:,:,1))
                    Dm = reshape(dv, size(T.matrix,1), size(T.matrix,2));
                    dcol = Dm(:,c); inz = dcol(ok) <= dEx;
                end
                % place this track in the gallery grid, scaled so every panel is the same size
                x0 = min(X)-PAD; x1 = max(X)+PAD; y0 = min(Y)-PAD; y1 = max(Y)+PAD;
                sc = max(max(x1-x0, y1-y0), eps);
                gx = (m-1)*CELLW*1.06; gy = -(j-1)*CELLW*1.06;
                px = @(v) gx + (v - x0)/sc*CELLW;
                py = @(v) gy + (v - y0)/sc*CELLW;
                drawMaskCrop(selE(k).file, [x0 x1 y0 y1], sc, gx, gy, CELLW);
                plot(engAxEx, px(X), py(Y), '-','Color',[0.45 0.5 0.62],'LineWidth',0.7);
                plot(engAxEx, px(X(~inz)), py(Y(~inz)), '.','Color',[0.55 0.6 0.7],'MarkerSize',6);
                plot(engAxEx, px(X(inz)),  py(Y(inz)),  '.','Color',[0.85 0.2 0.55],'MarkerSize',8);
                nDrawn = nDrawn + 1;
            end
            % Truncate from the LEFT: an unassigned cell falls back to its file name, and those
            % differ in their last few characters, not their first.
            lb = ug{j}; if numel(lb) > 20, lb = ['…' lb(end-18:end)]; end
            text(engAxEx, -0.06, -(j-1)*CELLW*1.06 + CELLW/2, lb, ...
                'HorizontalAlignment','right','FontSize',8.5,'FontWeight','bold','Interpreter','none');
        end
        hold(engAxEx,'off');
        axis(engAxEx,'equal'); engAxEx.XTick = []; engAxEx.YTick = [];
        engAxEx.XLim = [-1.6 max(nPer,1)*CELLW*1.06 + 0.1];
        title(engAxEx, sprintf(['example tracks at d = %.3g µm — %d shown, magenta = inside the zone ' ...
            '(grey mask = %s)'], dEx, nDrawn, engKey.Value), 'FontSize',8.5);
    end

    function drawMaskCrop(base, box, sc, gx, gy, CELLW)
        % The organelle mask under one example, cropped to that track's box. Best-effort: a project
        % whose segmentation cannot be resolved still gets the track and the colouring, which is
        % where the classification actually lives.
        try
            ov = resolveOverlay(base);
            p2 = ''; if isfield(ov,'seg') && isfield(ov.seg, engKey.Value), p2 = ov.seg.(engKey.Value); end
            if isempty(p2) || ~isfile(p2), return; end
            k = find(strcmp({buildTracks.file}, char(base)), 1);
            if isempty(k), return; end
            pxu = trackPx(k);
            im = imread(p2, 1); if size(im,3)==3, im = rgb2gray(im); end
            v = unique(im(:)); nz = v(v>0); fg = 1; if ~isempty(nz), fg = double(min(nz)); end
            mask = (im == fg);
            % Same convention as everywhere else: X_um = (0-based col) * pixUm.
            c0 = max(1, floor(box(1)/pxu)+1); c1 = min(size(mask,2), ceil(box(2)/pxu)+1);
            r0 = max(1, floor(box(3)/pxu)+1); r1 = min(size(mask,1), ceil(box(4)/pxu)+1);
            if c1 <= c0 || r1 <= r0, return; end
            sub = mask(r0:r1, c0:c1);
            xa = gx + ([(c0-1) (c1-1)]*pxu - box(1))/sc*CELLW;
            ya = gy + ([(r0-1) (r1-1)]*pxu - box(3))/sc*CELLW;
            rgbm = cat(3, 0.72*ones(size(sub)), 0.74*ones(size(sub)), 0.80*ones(size(sub)));
            image(engAxEx,'XData',xa,'YData',ya,'CData',rgbm,'AlphaData',double(sub)*0.75,'HitTest','off');
        catch
        end
    end

    function onEngageExamples(preset)
        % preset: write straight to this path and skip the Save dialog. The button passes nothing —
        % it asks. Callers that already know the file (the smokes) pass one, because a modal dialog
        % cannot be answered headlessly and the export would otherwise be untestable.
        if nargin < 1, preset = ''; end
        [selE, TsubE, dEx] = engageExampleSel();
        if isempty(selE), engLbl.Text = 'Build or load a TrackStruct first.'; return; end
        nTr = sum(arrayfun(@(x) numel(x.cols), selE));
        if nTr == 0
            engLbl.Text = sprintf('No track has a step starting within %.3g µm of %s — nothing to export.', ...
                dEx, engKey.Value);
            return
        end
        dst = fullfile(projectDir,'analysis'); if ~isfolder(dst), mkdir(dst); end
        % ASK where it goes. The name encodes the channel and the distance, which is what
        % distinguishes one export from the next, but a run is often better named for what it IS
        % ("baseline_only", "after_density_cut") and the tool cannot guess that.
        f = char(preset);
        if isempty(f)
            deflt = cs_ana_path(dst,'examples', sprintf('examples_%s_%.0fnm.mat', engKey.Value, dEx*1000));
            [fn, fp] = uiputfile({'*.mat','TrackStruct (*.mat)'}, 'Save the example tracks as', deflt);
            if isequal(fn,0)
                engLbl.Text = 'Export cancelled — nothing was written.'; return
            end
            f = fullfile(fp, fn);
            % The subset guard is name-based, so a file saved under a name that does not start with
            % examples_ could later be picked up as a BUILD and quietly analysed as one. Say so
            % rather than silently renaming what the user typed.
            [~, stemChk] = fileparts(f);
            if ~startsWith(stemChk,'examples_')
                uialert(ancestor(engLbl,'figure'), ...
                    sprintf(['"%s" does not start with "examples_". Subsets are recognised by that ' ...
                             'prefix and kept out of the Build selector; under this name the file ' ...
                             'can be made the active build, and every downstream stage would then ' ...
                             'measure a pre-selected subset.'], stemChk), ...
                    'Saved, but not recognised as a subset', 'Icon','warning');
            end
        end
        Tracks = TsubE; %#ok<NASGU>
        % The folder may not exist: uiputfile guarantees one, a preset path does not, and cs_ana_path
        % only creates the folder when IT builds the name.
        pdir = fileparts(f); if ~isempty(pdir) && ~isfolder(pdir), try, mkdir(pdir); catch, end, end
        try, save(f, 'Tracks', '-v7.3');
        catch ME, engLbl.Text = ['Could not write the examples: ' ME.message]; return; end
        nC = sum(arrayfun(@(x) ~isempty(x.cols), selE));
        [~, fb, fe] = fileparts(f);
        engLbl.Text = sprintf(['Wrote %d track(s) from %d cell(s) touching %s within %.3g µm -> %s   ' ...
            '·  In TOOL 2, hit "Load TrackStruct…" and pick %s%s for the interactive player over the ' ...
            'raw movie with the ER/mito overlay, plus MSD, stepwise D(t), CSD and the per-track D ' ...
            'export — on exactly these tracks. It is deliberately NOT offered in the Build selector: ' ...
            'it is a subset, not a build.'], nTr, nC, engKey.Value, dEx, f, fb, fe);
        logBuild(sprintf('Engagement examples: %d track(s), %d cell(s) -> %s', nTr, nC, f));
        % The button itself says it worked. The status line is a paragraph of text above the table
        % and a person who just clicked a button is looking at the button. Reset on the next
        % Compute, which is the natural boundary — no timer to outlive the figure.
        if ~isempty(bEngEx) && isgraphics(bEngEx)
            bEngEx.Text = '✓ Examples written';
            bEngEx.BackgroundColor = [0.83 0.93 0.83];
            bEngEx.FontWeight = 'bold';
        end
    end

    function onEngageExport()
        if isempty(engLast), engLbl.Text = 'Nothing to export — Compute first.'; return; end
        anaDir = ensureAnaDir(); if isempty(anaDir), return; end
        fn = cs_ana_path(anaDir,'export', sprintf('cs_engagement_%s.csv', regexprep(engKey.Value,'\W','_')));
        try
            fid = fopen(fn,'w');
            % Guarded: the per-cell file is closed explicitly below (before the per-track file is
            % written), so an unconditional fclose in the cleanup would close it twice.
            c = onCleanup(@() closeIfOpen(fid)); %#ok<NASGU>
            fprintf(fid,['cell,condition,d_um,D_bound,D_free,D_ratio,n_bound,n_free,n_crossing,' ...
                         'occupancy_pooled,occ_median_per_track,engaged_frac,n_tracks_scored,' ...
                         'k_off_per_s,k_on_per_s,n_ended,n_censored,t_bound_s,t_free_s,ok,note\n']);
            cond = engageConditions({engLast(:,1).file});
            for k = 1:size(engLast,1)
                for q = 1:size(engLast,2)
                    e = engLast(k,q);
                    om = NaN; ef = NaN; ns = 0; kf = NaN; kn = NaN; ne = 0; nc = 0; tb = 0; tf = 0;
                    if ~isempty(engOccT) && k <= size(engOccT.med,1) && q <= size(engOccT.med,2)
                        om = engOccT.med(k,q);  ef = engOccT.eng(k,q);  ns = engOccT.n(k,q);
                        kf = engOccT.kOff(k,q); kn = engOccT.kOn(k,q);
                        ne = engOccT.nEnd(k,q); nc = engOccT.nCens(k,q);
                        tb = engOccT.tB(k,q);   tf = engOccT.tF(k,q);
                    end
                    % n_ended and n_censored travel with the rates on purpose: a k_off from three
                    % completed episodes is not a rate, and a cell where most episodes are censored
                    % is saying its tracks are too short for the binding it contains.
                    fprintf(fid,'%s,%s,%.4g,%.6g,%.6g,%.6g,%d,%d,%d,%.4g,%.4g,%.4g,%d,%.6g,%.6g,%d,%d,%.6g,%.6g,%d,%s\n', ...
                        csvq(e.file), csvq(cond{k}), e.dUm, e.Dbound, e.Dfree, e.Dratio, ...
                        e.nBound, e.nFree, e.nStraddle, e.occupancy, om, ef, ns, ...
                        kf, kn, ne, nc, tb, tf, e.ok, csvq(e.why));
                end
            end
            fclose(fid); fid = -1;

            % PER-TRACK file as well. The per-cell rows are summaries; this is the distribution they
            % summarise — one row per molecule — which is what a Prism column plot needs and what
            % shows whether a cell is bimodal rather than merely intermediate.
            fn2 = strrep(fn,'.csv','_pertrack.csv');
            fid2 = fopen(fn2,'w');
            fprintf(fid2,'cell,condition,d_um,track_col,n_loc,n_inside,occupancy,engaged\n');
            for q = 1:numel(engOccT.perTrack)
                ptq = engOccT.perTrack{q};
                dq = engLast(1,q).dUm;
                for i = 1:numel(ptq)
                    ci = ptq(i).cellIndex;
                    cn = ''; if ci >= 1 && ci <= numel(cond), cn = cond{ci}; end
                    fprintf(fid2,'%s,%s,%.4g,%d,%d,%d,%.6g,%d\n', csvq(ptq(i).file), csvq(cn), ...
                        dq, ptq(i).srcCol, ptq(i).nLoc, ptq(i).nIn, ptq(i).occ, ptq(i).engaged);
                end
            end
            fclose(fid2);
            engLbl.Text = sprintf('Exported %s  +  %s (one row per molecule)', fn, fn2);
        catch ME
            engLbl.Text = ['Export failed: ' ME.message];
        end
    end

    % ================= Tab 8 · Compare (grouped stats: mito / window / condition) =================
    function buildCompareTab(parent)
        % The status line gets its OWN full-width row. It was sharing the control row, and every
        % filter added since has taken width off it — it was down to ~150 px for a string that runs
        % past 700 when a crossed grouping lists a test per condition. Wrapping in its own row it
        % has the whole tab, and the controls stop competing with it for space.
        g = uigridlayout(parent,[3 1],'RowHeight',{34,30,'1x'},'Padding',[10 10 10 10],'RowSpacing',6);
        r = uigridlayout(g,[1 15],'ColumnWidth',{40,150, 62, 54,146, 40,100, 44,60, 46,140, 84, 80, 92, '1x'},'Padding',[0 0 0 0],'ColumnSpacing',7);
        uilabel(r,'Text','data','HorizontalAlignment','right');
        ddCmpData = uidropdown(r,'Items',{'current project','experiment (all folders)'},'Value','current project', ...
            'Tooltip','Compare THIS project''s sites, or the whole EXPERIMENT (every folder in the Experiment tab, grouped by the conditions you assigned).');
        uibutton(r,'Text','cells…','ButtonPushedFcn',@(s,e) onCompareCellPick(), ...
            'Tooltip',['Choose which CELLS enter the comparison. Every cell is in by default; ' ...
            'unticking one leaves it out of every group, of both plots and of the exports. Use it ' ...
            'to drop a cell you do not trust without editing the experiment manifest — the ' ...
            'Experiment tab''s exclude flag is the durable QC judgement, this is a per-comparison one.']);
        uilabel(r,'Text','group by','HorizontalAlignment','right');
        ddCmpGroup = uidropdown(r,'Items',{'mito vs non-mito','window (time-resolved)','condition', ...
            'condition x mito','window x mito'},'Value','condition', ...
            'Tooltip','The "x mito" groupings split each condition (or window) into its mito and non-mito sites, so you compare the two INSIDE a condition instead of pooling them.');
        % WHICH sites enter the comparison, applied BEFORE grouping. Grouping by condition with this
        % on 'mito only' is the cross-condition mito comparison — WT vs FFAT vs … over mito sites —
        % which the crossed grouping cannot give you: that one pairs mito against non-mito INSIDE a
        % condition and interleaves the conditions.
        uilabel(r,'Text','sites','HorizontalAlignment','right');
        ddCmpSites = uidropdown(r,'Items',{'all sites','mito only','non-mito only'},'Value','all sites', ...
            'Tooltip','Restrict the comparison to mito or non-mito sites before grouping. The table, the scatter, the dwell-time distribution and the tests all honour it.');
        % Spurious-hit gate, on EVERY metric. dw% is the picker's own site statistic — the median,
        % over the site's member tracks, of each track's % of window localizations inside the
        % footprint. A site whose tracks merely cross it scores low; a real one scores high. This
        % drops the site outright, so enrichment, area and n_loc are filtered by it as much as dwell.
        uilabel(r,'Text','dw% ≥','HorizontalAlignment','right');
        eCmpMinDw = uispinner(r,'Limits',[0 100],'Value',0,'Step',5,'RoundFractionalValues',true, ...
            'Tooltip',['Drop sites whose dw% is below this — dw% is the MEDIAN over the site''s member ' ...
            'tracks of the % of each track''s window localizations inside the footprint, the same ' ...
            'number the picker''s site table shows. Low dw% = traffic passing through, which is what a ' ...
            'spurious hit looks like. 0 = keep every site. Applies to every metric, and a dropped ' ...
            'site takes its dwell events out of the distribution with it.']);
        uilabel(r,'Text','metric','HorizontalAlignment','right');
        ddCmpMetric = uidropdown(r,'Items',{'dwell s','k_out /s','enrichment','area µm²','n_loc','mito fraction','# sites'},'Value','enrichment');
        uibutton(r,'Text','▶ Compute','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70],'FontColor','w','ButtonPushedFcn',@(s,e) onCompareCompute());
        uibutton(r,'Text','Export CSV','ButtonPushedFcn',@(s,e) onCompareExport(), ...
            'Tooltip','The SUMMARY table as shown: one row per group with n, mean, sem, median and mode.');
        uibutton(r,'Text','Export points','ButtonPushedFcn',@(s,e) onComparePointsExport(), ...
            'Tooltip',['Every per-site value behind the table, for Prism: one COLUMN per group, ' ...
            'rows padded — paste straight into a Prism Column data table. Also writes a long-format ' ...
            'file with each point''s cell/site/window/condition for traceability, and the pooled ' ...
            'dwell EVENT durations per group when dwell is loaded (that is what the CDF is drawn from).']);
        uilabel(r,'Text','');
        % WordWrap stays: even at full width a crossed grouping over many conditions can run past
        % one line, and the end of a status line is where the p-values are.
        lblCmp = uilabel(g,'Text','Run the mapper (Sites tab); dwell metrics also need the Dwell tab. Then Compute.', ...
            'FontColor',[0.2 0.4 0.5],'WordWrap','on');
        mn = uigridlayout(g,[1 2],'ColumnWidth',{'0.9x','1.1x'},'Padding',[0 0 0 0],'ColumnSpacing',8);
        tblCmp = uitable(mn,'ColumnName',{'group','n','mean','sem','median','mode'}, ...
            'ColumnWidth',{'1x',40,64,58,64,64});
        rc = uigridlayout(mn,[2 1],'RowHeight',{'1x','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
        axCmpScatter = uiaxes(rc); title(axCmpScatter,'per-site values by group');
        axCmpCdf     = uiaxes(rc); title(axCmpCdf,'pooled dwell-time CDF');
        spt_axes_policy([axCmpScatter axCmpCdf]);
    end

    function ok = ensureCompareData(metric)
        % Load what Compute would compare — this project, or the whole experiment — into
        % cmpCSW/cmpDD, reporting any reason it cannot into the status line. Shared with the cell
        % picker, so the picker can only ever offer cells the comparison would actually read.
        ok = false;
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
        ok = true;
    end

    function onCompareCompute()
        metric = ddCmpMetric.Value; mode = ddCmpGroup.Value;
        if ~ensureCompareData(metric), return; end
        [vals, grp, base, ismito, keptIdx] = compareValues(metric, mode);   % per-site value + label (+ its two parts)
        if isempty(vals)
            % Distinguish "this metric has no values" from "your filters removed every site" — the
            % second is a knob to turn, and the generic message sent you looking for a broken stage.
            fp = filterParts();
            if isempty(fp)
                lblCmp.Text = 'No values for this metric/grouping.';
            else
                lblCmp.Text = sprintf(['No sites left after filtering (%s) — %d before. Loosen it. ' ...
                    '(A site with no tracked member track has no dw%% at all, so any dw%% ≥ above 0 drops it.)'], ...
                    strjoin(fp,', '), numel(cmpCSW));
            end
            return;
        end
        [gnames,~,gi] = unique(grp,'stable'); gi = reshape(gi,size(vals));
        % A group counts as mito when EVERY site in it is — true of a crossed group's mito half, of
        % the 'mito' group of a plain mito/non-mito split, and of every group once the sites filter
        % is on 'mito only'. All three then get the mito colour, from one rule.
        gmito = false(1,numel(gnames));
        for j = 1:numel(gnames), gmito(j) = all(ismito(gi==j)); end
        if crossedMito(mode)
            % Base groups keep their first-seen order, but each one's mito row is placed next to its
            % own non-mito row: the pair you are actually comparing has to be adjacent in the table
            % and on the axes, otherwise a 4-condition split reads as 8 unrelated bars.
            [~,~,bi] = unique(base,'stable');
            key = zeros(numel(gnames),2);
            for j = 1:numel(gnames), k1 = find(gi==j,1); key(j,:) = [bi(k1), double(~gmito(j))]; end
            [~,ord] = sortrows(key);
            gnames = gnames(ord); gmito = gmito(ord);
            remap = zeros(1,numel(ord)); remap(ord) = 1:numel(ord); gi = reshape(remap(gi),size(gi));
        end
        D = cell(numel(gnames),6);
        for j = 1:numel(gnames)
            v = vals(gi==j); v = v(isfinite(v));
            D(j,:) = {gnames{j}, sprintf('%d',numel(v)), sprintf('%.4g',mean0(v)), sprintf('%.4g',semv(v)), ...
                      sprintf('%.4g',med0(v)), sprintf('%.4g',modev(v))};
        end
        tblCmp.Data = D;
        % scatter of per-site values by group (+ mean marker). An all-mito group's dots take the
        % app's pinned mito magenta (darkened to read on a white axes) so the two halves of a
        % condition are told apart by colour, not just by the tick label.
        cMito = [0.85 0.25 0.80]; cNon = [0.45 0.55 0.75];
        cla(axCmpScatter); hold(axCmpScatter,'on');
        for j = 1:numel(gnames)
            v = vals(gi==j); v = v(isfinite(v));
            xj = j + 0.12*(rand(numel(v),1)-0.5)*2;
            cj = cNon; if gmito(j), cj = cMito; end
            plot(axCmpScatter, xj, v, 'o','MarkerFaceColor',cj,'MarkerEdgeColor','none','MarkerSize',4);
            plot(axCmpScatter, j, mean0(v), '_','Color',[0.85 0.25 0.2],'MarkerSize',26,'LineWidth',2);
        end
        hold(axCmpScatter,'off'); xlim(axCmpScatter,[0.5 numel(gnames)+0.5]);
        xticks(axCmpScatter,1:numel(gnames)); xticklabels(axCmpScatter,gnames);
        xtickangle(axCmpScatter, tern(numel(gnames)>4, 30, 0));
        ylabel(axCmpScatter, metric); title(axCmpScatter, sprintf('%s by %s%s', metric, mode, filterTag()));
        % pooled dwell CDF per group (from the selected dataset's dwell events)
        cla(axCmpCdf);
        if ~isempty(cmpDD) && isfield(cmpDD,'events') && ~isempty(cmpDD.events)
            hold(axCmpCdf,'on'); leg = {};
            for j = 1:numel(gnames)
                dv = groupDwell(gnames{j}, mode); dv = dv(isfinite(dv)&dv>0);
                if isempty(dv), continue; end
                sv = sort(dv(:)); yy = (1:numel(sv))'/numel(sv);
                stairs(axCmpCdf, sv, yy, 'LineWidth',1.3);
                % n and median in the legend: the curves are the comparison, and a distribution
                % read off a figure is worth little without the count behind it.
                leg{end+1} = sprintf('%s (n=%d, med %.3g s)', gnames{j}, numel(sv), median(sv)); %#ok<AGROW>
            end
            hold(axCmpCdf,'off'); xlabel(axCmpCdf,'dwell (s)'); ylabel(axCmpCdf,'CDF');
            if ~isempty(leg), legend(axCmpCdf, leg, 'Location','southeast'); end
            title(axCmpCdf, ['pooled dwell-time CDF' filterTag()]);
        else
            title(axCmpCdf,'pooled dwell-time CDF (compute dwell in the Dwell tab)');
        end
        % rank-sum p (Stats toolbox): two groups get the one test; a crossed grouping gets mito vs
        % non-mito WITHIN each condition/window, which is the comparison that grouping is asking for.
        pmsg = '';
        if crossedMito(mode) && exist('ranksum','file')==2
            ub = unique(base,'stable'); parts = {};
            for b = 1:numel(ub)
                sel = strcmp(base, ub{b});
                v1 = vals(sel &  ismito); v1 = v1(isfinite(v1));
                v2 = vals(sel & ~ismito); v2 = v2(isfinite(v2));
                if isempty(v1) || isempty(v2), continue; end
                try, parts{end+1} = sprintf('%s p=%.3g', ub{b}, ranksum(v1,v2)); catch, end %#ok<AGROW>
            end
            if ~isempty(parts), pmsg = [' · mito vs non-mito ' strjoin(parts,', ')]; end
        end
        % Falls through to here for a plain grouping — and for a crossed one the sites filter has
        % collapsed to a single side, where there is no pair left to test.
        if isempty(pmsg) && numel(gnames)==2 && exist('ranksum','file')==2
            v1 = vals(gi==1); v2 = vals(gi==2); v1=v1(isfinite(v1)); v2=v2(isfinite(v2));
            if ~isempty(v1)&&~isempty(v2), try, pmsg = sprintf(' · rank-sum p=%.3g', ranksum(v1,v2)); catch, end, end
        elseif isempty(pmsg) && numel(gnames)>2 && exist('kruskalwallis','file')==2
            % More than two groups is the cross-condition case. A rank-sum needs a pair, so the
            % omnibus goes first: does ANY group differ? Chase it with pairwise tests yourself —
            % this deliberately does not print six uncorrected p-values as if they were one result.
            ok = isfinite(vals);
            if numel(unique(gi(ok)))>2
                try, pmsg = sprintf(' · Kruskal-Wallis p=%.3g (omnibus)', kruskalwallis(vals(ok), gi(ok), 'off')); catch, end
            end
        end
        % The per-point export writes THIS result, not a recomputation: an export that re-derives its
        % own values can silently disagree with the table the user is looking at.
        cmpLast = struct('metric',metric, 'mode',mode, 'vals',vals, 'gi',gi, 'idx',keptIdx, ...
                         'gnames',{gnames}, 'ismito',ismito);
        lblCmp.Text = sprintf('%s by %s%s · %d groups%s%s', metric, mode, filterTag(), numel(gnames), pmsg, dwellTag(metric));
    end

    function [vals, grp, base, ismito, keptIdx] = compareValues(metric, mode)
        % One value per site (cmpCSW element) + its group label. Dwell/k_out from cmpDD.perSite,
        % matched on site IDENTITY (see findPerSite), so colliding siteUIDs across an experiment's
        % folders cannot pull another condition's dwell number onto this site.
        % base/ismito are the label's two parts, kept so a crossed grouping can pair and test them.
        n = numel(cmpCSW); vals = nan(1,n); grp = cell(1,n); base = cell(1,n); ismito = false(1,n);
        keptIdx = 1:n;                                    % trimmed with the rest by keep, below
        havePS = ~isempty(cmpDD) && isfield(cmpDD,'perSite') && ~isempty(cmpDD.perSite);
        cmpKeptSites = containers.Map('KeyType','char','ValueType','logical');
        for i = 1:n
            e = cmpCSW(i);
            [lab, bs, im] = groupLabel(e, mode);
            if ~cellKeep(e) || ~siteKeep(im) || ~dwKeep(e), continue; end   % grp{i} stays '' -> dropped below
            cmpKeptSites(siteKey(e)) = true;
            grp{i} = lab; base{i} = bs; ismito(i) = im;
            switch metric
                case 'enrichment', vals(i) = e.enrichment;
                case 'area µm²',   vals(i) = e.areaUm2;
                case 'n_loc',      vals(i) = e.nMemberLocs;
                case 'mito fraction', vals(i) = double(cs_site_near(e,'mito'));
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
        end
        keep = ~cellfun(@isempty,grp);
        vals = vals(keep); grp = grp(keep); base = base(keep); ismito = ismito(keep);
        keptIdx = keptIdx(keep);
    end

    function j = findPerSite(ps, e)
        % Match a site to its per-site dwell record on IDENTITY — source folder, file, cell, site and
        % window — not on siteUID alone. siteUID restarts at 1 in every folder's mapper run, so across
        % an experiment the ids collide; the old fall-throughs handed back a record from a DIFFERENT
        % folder, which under a by-condition grouping silently scores one condition with another's
        % dwell. No identity match now means NO value (NaN, dropped from the group) — the honest
        % answer when a folder was never dwelled.
        j = 0;
        for c = find([ps.siteUID] == e.siteUID)
            if sameSiteRec(ps(c), e), j = c; return; end
        end
    end

    function tf = sameSiteRec(a, b)
        % Same physical site-window in both records. srcFolder exists only on the experiment
        % aggregate; within one project file/cell/site/window is already unique.
        tf = strcmp(char(fieldOr(a,'file')), char(fieldOr(b,'file'))) ...
            && isequal(fieldOr(a,'cellIndex'), fieldOr(b,'cellIndex')) ...
            && isequal(fieldOr(a,'csID'),      fieldOr(b,'csID')) ...
            && isequal(fieldOr(a,'window'),    fieldOr(b,'window'));
        if tf && isfield(a,'srcFolder') && isfield(b,'srcFolder')
            tf = strcmp(char(a.srcFolder), char(b.srcFolder));
        end
    end

    function [lab, base, ismito] = groupLabel(e, mode)
        % Label for ONE record — a CSW site OR a dwell event. Both spell the mito flag in a form
        % cs_site_near reads (MitoFlag on sites, mito on events), so one function serves both and the
        % table, the CDF and the tests cannot drift apart in how they name a group.
        ismito = cs_site_near(e,'mito');
        switch mode
            case {'window (time-resolved)','window x mito'}, base = sprintf('win %d', e.window);
            case {'condition','condition x mito'}
                if isfield(e,'condition') && ~isempty(e.condition), base = char(e.condition); else, base = e.file; end
            otherwise,                     base = tern(ismito,'mito','non-mito');
        end
        lab = base;
        if crossedMito(mode), lab = [base ' · ' tern(ismito,'mito','non-mito')]; end
    end

    function tf = crossedMito(mode)
        tf = any(strcmp(mode, {'condition x mito','window x mito'}));
    end

    function pct = siteDwPct(e)
        % dw%: the MEDIAN over the site's member tracks of each track's % of window localizations
        % inside the footprint — the picker's own site statistic. NaN when the site has no tracked
        % member at all, which no positive threshold should pass: a site with nothing tracked in it
        % has produced no evidence of dwelling, and that is what the gate is asking for.
        pct = NaN;
        if ~isstruct(e) || ~isfield(e,'tracks') || isempty(e.tracks), return; end
        v = siteTrackStats(e); v = v(isfinite(v));
        if ~isempty(v), pct = median(v); end
    end

    function tf = dwKeep(e)
        m = 0; if ~isempty(eCmpMinDw) && isgraphics(eCmpMinDw), m = eCmpMinDw.Value; end
        if m <= 0, tf = true; return; end                 % 0 keeps every site, NaN dw% included
        p = siteDwPct(e); tf = isfinite(p) && p >= m;
    end

    function k = siteKey(rec)
        % One identity for a site-window, spelled the same on a CSW record and on a dwell event, so
        % a filter decided over sites can be applied to events. srcFolder is '' outside an
        % experiment aggregate, where file/cell/site/window is already unique.
        fo = ''; if isfield(rec,'srcFolder') && ~isempty(rec.srcFolder), fo = char(rec.srcFolder); end
        k = sprintf('%s|%s|%d|%d|%d', fo, char(fieldOr(rec,'file')), ...
            num0(fieldOr(rec,'cellIndex')), num0(fieldOr(rec,'csID')), num0(fieldOr(rec,'window')));
    end

    function k = cellKey(rec)
        % A CELL is (source folder, cell file). The folder matters: two days can hold a cell of the
        % same name, and they are different cells.
        fo = ''; if isfield(rec,'srcFolder') && ~isempty(rec.srcFolder), fo = char(rec.srcFolder); end
        k = sprintf('%s|%s', fo, char(fieldOr(rec,'file')));
    end

    function tf = cellKeep(e)
        tf = isempty(cmpCells) || any(strcmp(cmpCells, cellKey(e)));
    end

    function [keys, labs] = compareCellList()
        % Every cell present in the loaded dataset, with the condition it was assigned, in a stable
        % order. Built from the SITES, so a cell in the manifest that the mapper never reached does
        % not appear — there is nothing of it to include or leave out.
        keys = {}; labs = {};
        for i = 1:numel(cmpCSW)
            k = cellKey(cmpCSW(i));
            if any(strcmp(keys,k)), continue; end
            e = cmpCSW(i);
            cond = ''; if isfield(e,'condition') && ~isempty(e.condition), cond = [' · ' char(e.condition)]; end
            nS = sum(arrayfun(@(x) strcmp(cellKey(x),k), cmpCSW));
            keys{end+1} = k; %#ok<AGROW>
            labs{end+1} = sprintf('%s%s  (%d sites)', char(fieldOr(e,'file')), cond, nS); %#ok<AGROW>
        end
        [keys, ord] = sort(keys); labs = labs(ord);
    end

    function setCompareCells(sel)
        % Headless hook (spt_compare_group_smoke) and the picker's commit path. [] or every key
        % means "all cells", which is the state that leaves file names and titles unfiltered.
        if isempty(sel), cmpCells = []; return; end
        cmpCells = cellstr(sel(:)');
    end

    function onCompareCellPick()
        if ~ensureCompareData('enrichment'), return; end     % a metric that never demands dwell
        [keys, labs] = compareCellList();
        if isempty(keys), lblCmp.Text = 'No cells in the loaded data yet — run the mapper first.'; return; end
        sel = true(numel(keys),1);
        if ~isempty(cmpCells), sel = ismember(keys(:), cmpCells(:)); end

        d = uifigure('Name','Cells in the comparison','Position',[120 120 470 470],'WindowStyle','modal');
        d.UserData = false;                                   % set by OK; closing the window cancels
        d.CloseRequestFcn = @(s,e) uiresume(d);
        gg = uigridlayout(d,[3 1],'RowHeight',{34,'1x',32},'Padding',[10 10 10 10],'RowSpacing',6);
        uilabel(gg,'Text','Untick a cell to leave it out of every group, both plots and the exports.', ...
            'WordWrap','on','FontColor',[0.2 0.4 0.5]);
        tb = uitable(gg,'Data',table(sel, labs(:), 'VariableNames',{'use','cell'}), ...
            'ColumnEditable',[true false],'ColumnWidth',{44,'1x'});
        br = uigridlayout(gg,[1 5],'ColumnWidth',{64,64,'1x',80,80},'Padding',[0 0 0 0],'ColumnSpacing',6);
        uibutton(br,'Text','All','ButtonPushedFcn',@(s,e) setAll(tb,true));
        uibutton(br,'Text','None','ButtonPushedFcn',@(s,e) setAll(tb,false));
        uilabel(br,'Text','');
        uibutton(br,'Text','Cancel','ButtonPushedFcn',@(s,e) uiresume(d));
        uibutton(br,'Text','OK','FontWeight','bold','ButtonPushedFcn',@(s,e) pickOk(d));
        uiwait(d);
        if ~isgraphics(d), return; end
        if d.UserData
            v = logical(tb.Data.use);
            if all(v), setCompareCells([]); else, setCompareCells(keys(v)); end
            lblCmp.Text = sprintf('%d of %d cells selected — press Compute.', nnz(v), numel(keys));
        end
        delete(d);
    end

    function tf = siteKeep(ismito)
        % The 'sites' filter, applied to a site OR to a dwell event — both know their mito flag, so
        % the table and the dwell-time distribution below it cannot end up filtered differently.
        switch siteFilter()
            case 'mito only',     tf = ismito;
            case 'non-mito only', tf = ~ismito;
            otherwise,            tf = true;
        end
    end

    function v = siteFilter()
        v = 'all sites';
        if ~isempty(ddCmpSites) && isgraphics(ddCmpSites), v = ddCmpSites.Value; end
    end

    function p = filterParts()
        % The active site filters, in words. One list, so the axes title, the status line and the
        % "nothing survived" message cannot describe the same filtering differently.
        p = {};
        if ~strcmp(siteFilter(),'all sites'), p{end+1} = siteFilter(); end
        m = 0; if ~isempty(eCmpMinDw) && isgraphics(eCmpMinDw), m = eCmpMinDw.Value; end
        if m > 0, p{end+1} = sprintf('dw%% ≥ %g%%', m); end
        if ~isempty(cmpCells), p{end+1} = sprintf('%d cells', numel(cmpCells)); end
    end

    function t = filterTag()
        % '' when nothing is filtered, so titles and file names of an unfiltered run are unchanged.
        t = ''; p = filterParts(); if ~isempty(p), t = [' — ' strjoin(p,', ')]; end
    end

    function t = filterTok()
        % The same two filters as a file-name token, so no two different comparisons can land on
        % one file. Empty when nothing is filtered, leaving old names untouched.
        t = '';
        if ~strcmp(siteFilter(),'all sites'), t = ['_' regexprep(siteFilter(),'\W','_')]; end
        m = 0; if ~isempty(eCmpMinDw) && isgraphics(eCmpMinDw), m = eCmpMinDw.Value; end
        if m > 0, t = sprintf('%s_dw%g', t, m); end
        % The cell selection needs a token that DISTINGUISHES selections, not just marks that one
        % exists: two different sets of the same size would otherwise overwrite each other's export.
        if ~isempty(cmpCells)
            h = 0; for c = double(strjoin(sort(cmpCells),'|')), h = mod(h*31 + c, 1679616); end
            t = sprintf('%s_cells%d_%s', t, numel(cmpCells), lower(dec2base(h,36,4)));
        end
    end

    function t = dwellTag(metric)
        % A dwell number computed over only the dwelling tracks is a different measurement from one
        % over every member, and nothing on this tab would otherwise say which you are looking at.
        t = '';
        if ~any(strcmp(metric,{'dwell s','k_out /s'})), return; end
        if isempty(cmpDD) || ~isfield(cmpDD,'minPctInside'), return; end
        mp = cmpDD.minPctInside;
        if isscalar(mp)
            if mp > 0, t = sprintf(' · dwell from tracks ≥%g%% inside', mp); end
        elseif numel(mp) > 1
            t = sprintf(' · ⚠ folders used different ≥%% inside thresholds (%s) — recompute dwell consistently', ...
                strjoin(arrayfun(@(v) sprintf('%g',v), mp(:)', 'uni',0), ', '));
        end
    end

    function dv = groupDwell(gname, mode)
        % Pooled event dwell durations for the events whose group label == gname (works on either the
        % project or the experiment dataset — events carry window/mito/condition directly). The
        % sites filter is applied HERE too: a 'mito only' table above a distribution pooling every
        % event would be two different comparisons drawn as one figure.
        dv = [];
        if isempty(cmpDD) || ~isfield(cmpDD,'events') || isempty(cmpDD.events), return; end
        ev = cmpDD.events;
        % Keep an event only if ITS SITE survived the filters. Re-testing the event against each
        % filter would work for mito but not for dw%, which is a property of the site, not of the
        % event — and two gates evaluated separately are two gates that can disagree.
        if ~isempty(cmpKeptSites)
            ev = ev(arrayfun(@(x) isKey(cmpKeptSites, siteKey(x)), ev));
        end
        if isempty(ev), return; end
        labs = arrayfun(@(x) groupLabel(x,mode), ev, 'uni',0);
        dv = [ev(strcmp(labs,gname)).dwell];
    end

    function onCompareExport()
        if isempty(tblCmp) || isempty(tblCmp.Data), lblCmp.Text='Nothing to export — Compute first.'; return; end
        anaDir = ensureAnaDir(); if isempty(anaDir), return; end
        % The filter is part of the file name: a mito-only comparison and an all-sites one of the
        % same metric and grouping are different results, and must not overwrite each other.
        grpTok = [regexprep(ddCmpGroup.Value,'\W','_') filterTok()];
        fn = fullfile(anaDir, sprintf('cs_compare_%s_by_%s.csv', regexprep(ddCmpMetric.Value,'\W','_'), grpTok));
        try
            fid = fopen(fn,'w'); fprintf(fid,'group,n,mean,sem,median,mode\n');
            D = tblCmp.Data;
            for r = 1:size(D,1)
                fprintf(fid,'%s,%s,%s,%s,%s,%s\n', csvq(D{r,1}), D{r,2}, D{r,3}, D{r,4}, D{r,5}, D{r,6});
            end
            fclose(fid); lblCmp.Text = ['Exported ' fn];
        catch ME, lblCmp.Text = ['Export failed: ' ME.message]; end
    end

    function onComparePointsExport()
        % Every per-site value behind the table, in the shape Prism wants: one COLUMN per group,
        % rows padded to the longest. Plus a long-format companion carrying each point's identity
        % (cell, site, window, condition, mito, dw%), because a bare column of numbers cannot be
        % traced back to the site it came from — and, when dwell events are loaded, the pooled event
        % durations per group, which is what the CDF is drawn from and what a distribution figure in
        % Prism needs (the per-site column holds one mean per site, not the events).
        if isempty(cmpLast) || isempty(cmpLast.vals), lblCmp.Text='Nothing to export — Compute first.'; return; end
        anaDir = ensureAnaDir(); if isempty(anaDir), return; end
        L = cmpLast;
        stem = sprintf('%s_by_%s%s', regexprep(L.metric,'\W','_'), regexprep(L.mode,'\W','_'), filterTok());
        written = {};
        try
            % (1) wide — one column per group, for a Prism Column data table
            cols = cell(1,numel(L.gnames));
            for j = 1:numel(L.gnames)
                v = L.vals(L.gi==j); cols{j} = v(isfinite(v));
            end
            fw = fullfile(anaDir, ['cs_points_' stem '.csv']);
            writeWideCSV(fw, L.gnames, cols); written{end+1} = fw;

            % (2) long — one row per point, with where it came from
            fl = fullfile(anaDir, ['cs_points_' stem '_long.csv']);
            fid = fopen(fl,'w');
            fprintf(fid,'group,condition,file,cellIndex,csID,window,siteUID,mito,dw_pct,%s\n', ...
                regexprep(L.metric,'\W','_'));
            for k = 1:numel(L.vals)
                if ~isfinite(L.vals(k)), continue; end
                e = cmpCSW(L.idx(k));
                cond = ''; if isfield(e,'condition') && ~isempty(e.condition), cond = char(e.condition); end
                fprintf(fid,'%s,%s,%s,%d,%d,%d,%d,%d,%.4g,%.6g\n', ...
                    csvq(L.gnames{L.gi(k)}), csvq(cond), csvq(char(fieldOr(e,'file'))), ...
                    num0(fieldOr(e,'cellIndex')), num0(fieldOr(e,'csID')), num0(fieldOr(e,'window')), ...
                    num0(fieldOr(e,'siteUID')), double(L.ismito(k)), siteDwPct(e), L.vals(k));
            end
            fclose(fid); written{end+1} = fl;

            % (3) the events behind the CDF, same wide shape — only when there are any
            if ~isempty(cmpDD) && isfield(cmpDD,'events') && ~isempty(cmpDD.events)
                ecols = cell(1,numel(L.gnames)); any_ = false;
                for j = 1:numel(L.gnames)
                    dv = groupDwell(L.gnames{j}, L.mode); dv = dv(isfinite(dv) & dv>0);
                    ecols{j} = dv(:); any_ = any_ || ~isempty(dv);
                end
                if any_
                    fe = fullfile(anaDir, sprintf('cs_dwellevents_by_%s%s.csv', ...
                        regexprep(L.mode,'\W','_'), filterTok()));
                    writeWideCSV(fe, L.gnames, ecols); written{end+1} = fe;
                end
            end
            [~,n1] = fileparts(written{1});
            lblCmp.Text = sprintf('Exported %d file(s) to %s — %s.csv + %d more', ...
                numel(written), anaDir, n1, numel(written)-1);
        catch ME
            lblCmp.Text = ['Point export failed: ' ME.message];
        end
    end

    function pickOk(d), d.UserData = true; uiresume(d); end
    function setAll(tb, v), D = tb.Data; D.use(:) = v; tb.Data = D; end

    % ---- shared downstream helpers ----
    function resetDownstream()
        % Clear ALL downstream (Refine/Sites/Dwell/Compare) in-memory state + caches so a project
        % switch or a Load never leaks a prior dataset's footprints/densities/results into the new one.
        try, dwellStopTimer(); catch, end   % stop any running Dwell animation before wiping results
        CSW = []; DD = []; cmpKeptSites = []; cmpLast = []; cmpCells = []; siteDensCache = struct('key',{},'dens',{},'raw',{}); refNullCache = struct('key',{},'nullMax',{},'pmap',{});
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
                % this cell's own localization precision where the build stamped one
                prk = PRECNM;
                if isfield(Tracks,'calib') && isstruct(Tracks(k).calib) && isfield(Tracks(k).calib,'precNm') ...
                        && isscalar(Tracks(k).calib.precNm) && Tracks(k).calib.precNm > 0
                    prk = Tracks(k).calib.precNm;
                end
                Tk = spt_track_diffusion(Tracks(k), struct('dt',dtk,'sigmaUm',prk/1000));
                % Only the rolling D is stored. confined / stateChange are NOT written: nothing reads
                % them any more (Tool 3's diffusion-state density channels are gone), and carrying
                % flags derived from a confinement criterion nobody is setting invites them being
                % trusted. spt_confine_flags still implements all four criteria — pass confMode &c to
                % spt_track_diffusion and assign Tk.confined / Tk.stateChange here to bring it back.
                % assign FIELD-BY-FIELD (a whole-struct assign fails — the result has extra fields)
                Tracks(k).Dt = Tk.Dt; Tracks(k).diffOpts = Tk.diffOpts;
            catch, end
        end
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
                'Calib', calibForBuild(), ...
                'Verbose', false, 'ProgressFcn', @(i,n,name) setBuild(sprintf('Building %d/%d: %s (MSD)…', i, n, name),[0.2 0.4 0.5]));
        catch ME
            setBuild(['Build failed: ' ME.message],[0.75 0.1 0.1]); return;
        end
        if isempty(Tracks), setBuild('No tracks imported — check the tracks folder.',[0.6 0.4 0.1]); return; end
        setBuild('Computing per-localization diffusion D(t) + confinement…',[0.2 0.4 0.5]); drawnow;
        Tracks = addDiffusion(Tracks);                         % per-localization rolling D(t) stored in TrackStruct
        aDir = fullfile(projectDir,'analysis'); if ~isfolder(aDir), mkdir(aDir); end
        onTsName(); setActiveTs(aDir, tsName);          % write analysis/<name>.mat and make it active
        save(fullfile(aDir,tsName),'Tracks','-v7.3');
        cc = fullfile(tracksDir,'cs_calib.mat'); if isfile(cc), try, copyfile(cc, fullfile(aDir,'cs_calib.mat')); catch, end, end
        populateBuildSummary(Tracks, src, aDir);
    end

    function loadTracksFile(p2)
        % Load a NAMED file, skipping the picker. Exposed for tests, which cannot answer a dialog;
        % onLoadTracks is the interactive wrapper and both share everything after the file is known.
        onLoadTracks(p2);
    end

    function onLoadTracks(preset)
        % Load a built TrackStruct and populate the QC WITHOUT recomputing MSD. When the project
        % holds MORE THAN ONE build, always ask which — otherwise the shortcut to the active one
        % made every other named build unreachable, contradicting the button's own tooltip.
        f = '';
        if nargin >= 1 && ~isempty(preset) && isfile(preset), f = char(preset); end
        if isempty(f) && ~isempty(projectDir)
            a = fullfile(projectDir,'analysis');
            nBuilds = 0;
            % Count the examples/ subfolder too. The examples subsets moved out of the root, and
            % this count is what decides whether a PICKER opens: with one real build and the subsets
            % uncounted, the button would silently load the active build and the subsets would be
            % unreachable from the UI entirely.
            d = [dir(fullfile(a,'*.mat')); dir(fullfile(a,'examples','*.mat'))];
            skip = {'cs_calib.mat','CSW_final.mat','cs_window_dwell.mat','cs_footprints.mat','experiment_details.mat','experiment_manifest.mat'};
            for q = 1:numel(d)
                if any(strcmpi(d(q).name,skip)), continue; end
                try, w = whos('-file', fullfile(d(q).folder,d(q).name)); if any(strcmp({w.name},'Tracks')), nBuilds = nBuilds + 1; end, catch, end
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
            % An examples_* file is a SUBSET — the tracks that touch the organelle — and must never
            % become the active build. It was: loading one for inspection stamped it active, and
            % every downstream stage then measured 3044 pre-selected tracks instead of 7615. That
            % is not merely fewer data, it is BIASED data: D_free is then computed only from steps
            % of tracks that also touch the organelle, so the free pool is depleted of exactly the
            % molecules that never go near it and the ratio is dragged toward 1. It still loads
            % here — inspecting it in the player is the whole point — but the project's active
            % build is left alone.
            isSubset = startsWith(stem, 'examples_');
            if ~isSubset
                setActiveTs(aDir, [stem ext]);
            else
                % setActiveTs is what normally updates the Name box, and it is deliberately skipped
                % here — so the box kept whatever it last held and pointed at a file that is not the
                % one on screen. It must still CHANGE, and it must not change to the subset's name:
                % the box answers "what will Build write?", and writing a build over the examples
                % file is exactly the confusion the subset guard exists to prevent. Snap it back to
                % the ACTIVE build, which is what Build would actually produce.
                if ~isempty(eTsName) && isgraphics(eTsName) && ~isempty(tsName)
                    [~, actStem] = fileparts(tsName); eTsName.Value = actStem;
                end
            end
            dst = fullfile(aDir, tsName);
            if ~isSubset
                try, save(dst,'Tracks','-v7.3'); catch, end   % persist (may have just added diffusion fields)
            end
            cc = fullfile(aDir,'cs_calib.mat'); if isfile(cc), try, calib=load(cc); if isfield(calib,'calib'), applyCalib(calib.calib); end, catch, end, end
        end
        resetDownstream();                                               % new tracks -> invalidate downstream state + caches
        populateBuildSummary(Tracks, 'loaded (no rebuild)', aDir);
        logBuild(sprintf('Loaded TrackStruct.mat (%d cell(s)) from %s — MSD rebuild skipped.', numel(Tracks), f));
        [~,ldStem] = fileparts(f);
        if startsWith(ldStem,'examples_')
            m = sprintf(['Loaded the SUBSET %s for inspection — the active build is unchanged (%s). ' ...
                'Do not read engagement or dwell numbers off a subset: its tracks were pre-selected ' ...
                'for touching the organelle, so D_free is computed only from molecules that also go ' ...
                'near it and the ratio is pulled toward 1.'], ldStem, tsName);
            setBuild(m, [0.6 0.4 0.1]); logBuild(m);
        end
    end

    function applyCalib(c)
        % adopt calibration fields from a loaded cs_calib.mat into the top bar (best-effort)
        if isfield(c,'pixSizeUm')&&c.pixSizeUm>0, PXUM=c.pixSizeUm; if isgraphics(eCalPx), eCalPx.Value=PXUM; end, end
        if isfield(c,'fovUm')&&c.fovUm>0, FOVUM=c.fovUm; if isgraphics(eCalFov), eCalFov.Value=FOVUM; end, end
        if isfield(c,'dt_s')&&c.dt_s>0, DTS=c.dt_s; if isgraphics(eCalDt), eCalDt.Value=DTS; end, end
        if isfield(c,'binNm')&&c.binNm>0, PRECNM=c.binNm; if isgraphics(eCalPrec), eCalPrec.Value=PRECNM; end, end
    end

    function populateBuildSummary(Tracks, src, aDir)
        nCh = numel(buildChanKeys);
        n = numel(Tracks); D = cell(n, 3 + nCh + 5); tot = 0;
        anyCh = false(1, nCh);
        buildTracks = Tracks;                                    % set FIRST: the calibration accessors read it
        for k = 1:n
            L = double(Tracks(k).lengths(:)); nt = numel(L); tot = tot + nt;
            marks = cell(1, nCh);
            for kC = 1:nCh
                % THREE states, not two. cs_channel_has answers "is the array there?", and the
                % importer decides that from the CSV COLUMN NAME alone — so a cell with an
                % ER_DIST_UM column and no ER segmentation gets a full-NaN matrix, which is present
                % but carries nothing. A plain ✓ then claimed ER on a cell whose own status line
                % said "(no ER)", because that line tests for finite values. 'NaN' is the honest
                % third answer: the column exists and holds no data.
                [hc, rawc] = cs_channel_has(Tracks(k), buildChanKeys{kC});
                anyCh(kC) = anyCh(kC) || hc;
                if ~hc,                            marks{kC} = '–';
                elseif ~any(isfinite(rawc(:))),    marks{kC} = 'NaN';
                else,                              marks{kC} = '✓';
                end
            end
            % '*' marks a value INHERITED from the Calibration panel. It used to be '°', which in a
            % column headed "FOV µm" reads as degrees — the marker looked like a unit.
            sc = calSrc(k); inh = @(f) tern(strcmp(gs(sc,f),'image')||strcmp(gs(sc,f),'xml'),'','*');
            D(k,:) = [{char(Tracks(k).file), nt, round(median(L))}, marks, ...
                     {sprintf('%.5g%s', trackPx(k),   inh('pixSizeUm')), ...
                      sprintf('%.5g%s', trackFov(k),  inh('fovUm')), ...
                      sprintf('%.5g%s', trackDt(k),   inh('dt_s')), ...
                      sprintf('%.4g%s', trackPrec(k), inh('precNm')), ...
                      sprintf('%.4g%s', trackBin(k),  inh('binNm'))}];
        end
        tblBuild.Data = D;
        ddQCcell.Items = [{'All (pooled)'}, cellfun(@char, {Tracks.file}, 'uni', 0)];
        ddQCcell.Value = 'All (pooled)';
        drawQC('All (pooled)');
        chanTxt = '';   % '· mito=yes er=no', one term per declared channel
        for kC = 1:nCh, chanTxt = sprintf('%s %s=%s', chanTxt, buildChanKeys{kC}, tern(anyCh(kC),'yes','no')); end
        logBuild(sprintf('Built %d cell(s), %d tracks -> %s  [%s tracks,%s]', ...
            n, tot, fullfile(aDir,tsName), src, chanTxt));
        setBuild(sprintf('Done — %d cell(s), %d tracks. %s in analysis/ (active). QC below.', n, tot, tsName),[0.2 0.5 0.2]);
    end

    function onCalEdit(ev)
        % Write one cell's calibration back into the build. Saving matters: D is re-derived from the
        % stored precision, so a correction that lived only in the table would silently not apply.
        try, r = ev.Indices(1); c = ev.Indices(2); catch, return; end
        if r < 1 || r > numel(buildTracks), return; end
        % The five calibration columns sit AFTER the three fixed ones and the generated per-channel
        % block, so their positions depend on how many channels the project declares. Deriving the
        % index instead of hard-coding x6..x10 is what stops a third channel from silently writing
        % the pixel size into the FOV field.
        calFields = {'pixSizeUm','fovUm','dt_s','precNm','binNm'};
        idx = c - (3 + numel(buildChanKeys));
        if idx < 1 || idx > numel(calFields), return; end
        f = calFields{idx};
        % Strip any non-numeric decoration, so a value pasted back with its inherited marker (now '*',
        % previously '°') parses rather than being rejected.
        v = str2double(regexprep(char(string(ev.NewData)), '[^0-9eE.+-]', ''));
        if ~(isscalar(v) && isfinite(v) && v > 0)
            setBuild('Calibration must be a positive number — reverting that cell.',[0.7 0.2 0.2]);
            tblBuild.Data{r,c} = ev.PreviousData; return;
        end
        if ~isfield(buildTracks,'calib'), [buildTracks.calib] = deal(struct()); end
        cal = buildTracks(r).calib; if ~isstruct(cal), cal = struct(); end
        cal.(f) = v;
        if ~isfield(cal,'src') || ~isstruct(cal.src), cal.src = struct(); end
        cal.src.(f) = 'edited';
        buildTracks(r).calib = cal;
        if strcmp(f,'dt_s'), buildTracks(r).frameInterval = v; end   % the one field read from two places
        tblBuild.Data{r,c} = sprintf('%.5g', v);
        saveActiveBuild(sprintf('%s of %s → %.5g', f, char(buildTracks(r).file), v));
    end

    function saveActiveBuild(what)
        aDir = fullfile(projectDir,'analysis');
        f = fullfile(aDir, activeTsName(aDir));
        if ~isfolder(aDir) || isempty(buildTracks)
            setBuild('Nothing to save — build or load a TrackStruct first.',[0.7 0.2 0.2]); return;
        end
        Tracks = buildTracks; %#ok<NASGU>
        try
            save(f,'Tracks','-v7.3');
            setBuild(sprintf('Saved %s → %s. Rebuild to re-derive D with it.', what, activeTsName(aDir)),[0.2 0.5 0.2]);
        catch ME
            setBuild(['Could not save: ' ME.message],[0.7 0.2 0.2]);
        end
    end

    function v = gs(s2,f), v = ''; if isstruct(s2)&&isfield(s2,f)&&(ischar(s2.(f))||isstring(s2.(f))), v = char(s2.(f)); end, end

    function onQcReject()
        % Reject (or restore) the track selected in the map. The decision is keyed on the ORIGINAL
        % build column, resolved through srcCols, so the same click means the same track whether you
        % are looking at the full build or at an examples subset.
        if qcSelIdx < 1 || qcSelIdx > numel(qcTracks)
            setBuild('Click a track in the map first, then reject it.',[0.6 0.4 0.1]); return;
        end
        s = qcTracks{qcSelIdx};
        src = s.col;
        T = buildTracks(s.cellIdx);
        if isfield(T,'srcCols') && numel(T.srcCols) >= s.col, src = T.srcCols(s.col); end
        was = cs_track_exclusions('has', trkEx, s.base, src);
        trkEx = cs_track_exclusions('toggle', trkEx, s.base, src, '');
        cs_track_exclusions('save', projectDir, trkEx);
        n = cs_track_exclusions('count', trkEx);
        if was, verb = 'restored'; else, verb = 'rejected'; end
        msg = sprintf('%s %s track %d — %d rejected in this project (analysis/track_exclusions.csv)', ...
            verb, s.base, src, n);
        setBuild(msg, [0.1 0.5 0.2]); logBuild(msg);
        drawQC(ddQCcell.Value);                       % the pooled panels must stop counting it now
        % Re-select the SAME track. drawQC rebuilds the list and clears the selection, and without
        % this the button springs back to "Reject" on a track that is already rejected — leaving no
        % way to undo it from the UI.
        for i = 1:numel(qcTracks)
            if qcTracks{i}.cellIdx == s.cellIdx && qcTracks{i}.col == s.col, drawSelected(i); break; end
        end
    end

    function refreshRejectBtn()
        % The button says what the click will DO, which is the only way a toggle is legible.
        if isempty(bQcRej) || ~isgraphics(bQcRej), return; end
        if qcSelIdx < 1 || qcSelIdx > numel(qcTracks), bQcRej.Text = '✖ Reject'; return; end
        s = qcTracks{qcSelIdx};
        src = s.col; T = buildTracks(s.cellIdx);
        if isfield(T,'srcCols') && numel(T.srcCols) >= s.col, src = T.srcCols(s.col); end
        if cs_track_exclusions('has', trkEx, s.base, src), bQcRej.Text = '↺ Restore';
        else,                                              bQcRej.Text = '✖ Reject'; end
    end

    function [recs, ER, MI, L] = qcRecords(ks)
        % One record per track over the given cells. Factored out of drawQC so the ALL-CELLS export
        % measures every track exactly the way the on-screen panels measure the shown ones — same
        % fit spec, same fields. Two loops would drift the moment the fit mode gained an option.
        recs = {}; ER = []; MI = []; L = [];
        for k = ks
            T = buildTracks(k); M = T.matrix; if size(M,3) < 3, continue; end
            dtk = trackDt(k);
            msdT = fieldOr(T,'MSD');                                                    % may be absent (old struct)
            [~, erT] = cs_channel_has(T,'er');   [~, miT] = cs_channel_has(T,'mito');   % [] when not imaged
            % Rejected tracks stay IN the list, flagged. Dropping them here removed them from the
            % map too, and a track you cannot click is a track you cannot un-reject — the toggle
            % became one-way. They are excluded from the statistics by qcSelectionOf instead, and
            % drawn in red so a rejection is visible in context rather than only as a count.
            keepK = true(1, size(M,2));
            if ~isempty(trkEx)
                km = cs_track_exclusions('mask', trkEx, T); keepK = km{1};
            end
            for c = 1:size(M,2)
                X = M(:,c,2); Y = M(:,c,3); F = M(:,c,1); ok = isfinite(X) & isfinite(Y);
                if nnz(ok) < 2, continue; end
                rr = spt_fit_msd(colOr(msdT,c), dtk, fitSpec());        % per-track D at the current fit mode/window
                s = struct('cellIdx',k,'col',c,'base',char(T.file),'rejected',~keepK(c), ...
                    'X',X(ok),'Y',Y(ok),'F',F(ok),'len',nnz(ok), ...
                    'MSD', colOr(msdT,c), 'ER', finiteCol(erT,c), 'MI', finiteCol(miT,c), 'D', rr.D, 'sigLoc', rr.sigLocUm, 'fracUsed', rr.fracUsed, ...
                    'dt', dtk, ...                                       % stepwise (per-localization) diffusion, aligned to X/Y/F:
                    'Dt',   maskCol(fieldOr(T,'Dt'),          c, ok), ...
                    'CSD',  trimCol(fieldOr(T,'CSD'), c, nnz(ok)-1));    % path length through each step (µm)
                recs{end+1} = s; L(end+1)=s.len; ER=[ER; s.ER]; MI=[MI; s.MI]; %#ok<AGROW>
            end
        end
    end

    function onQcRowPick(e)
        % Clicking a row of the cell table selects that cell for QC. The dropdown above stays and
        % stays authoritative — this only sets it — so both routes lead to one code path and the
        % control still SHOWS which cell you are looking at after you click.
        try, r = e.Indices(1); catch, return; end
        if isempty(buildTracks) || r < 1 || r > numel(buildTracks), return; end
        nm = char(buildTracks(r).file);
        if isempty(ddQCcell) || ~isgraphics(ddQCcell) || ~any(strcmp(ddQCcell.Items, nm)), return; end
        if strcmp(ddQCcell.Value, nm), return; end          % already showing it: do not rebuild
        ddQCcell.Value = nm; drawQC(nm);
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
        [qcTracks, ER, MI, L] = qcRecords(ks);
        qcSelIdx = 0; qcHi = [];
        refreshDistChannels(ER, MI);

        % ---- tracks panel (click one) ----
        cla(axCov); Xa=[]; Ya=[];
        for i=1:numel(qcTracks), Xa=[Xa; qcTracks{i}.X; NaN]; Ya=[Ya; qcTracks{i}.Y; NaN]; end %#ok<AGROW>
        if ~isempty(Xa), plot(axCov, Xa, Ya, '-','Color',[0.55 0.6 0.75],'LineWidth',0.4,'HitTest','off'); end
        axis(axCov,'equal'); set(axCov,'YDir','reverse');   % interactions are set once at construction
        xlabel(axCov,'x (µm)'); ylabel(axCov,'y (µm)'); title(axCov, sprintf('tracks (click one) — %d', numel(qcTracks)));

        % ---- pooled ER/mito distance. Deliberately over ALL tracks, not the selected ones: this is
        % the histogram you read the "near mito ≤" threshold OFF, so filtering it by that threshold
        % would be circular. The threshold is drawn on it instead.
        L = L(:);
        cla(axDist); hold(axDist,'on'); leg = {};
        if ~isempty(ER), histogram(axDist, ER, 40, 'FaceColor',[0.15 0.6 0.25],'EdgeColor','none','FaceAlpha',0.6); leg{end+1}='ER'; end %#ok<AGROW>
        if ~isempty(MI), histogram(axDist, MI, 40, 'FaceColor',[0.85 0.2 0.6],'EdgeColor','none','FaceAlpha',0.6); leg{end+1}='mito'; end %#ok<AGROW>
        xline(axDist, 0, 'k-');
        kD = distKey();
        if ~isempty(kD)
            % Draw the cut in the colour of the channel it applies to, so on a project with both
            % ER and mito it is unambiguous which histogram the line belongs to.
            cD = [0.85 0.2 0.6]; if strcmp(kD,'er'), cD = [0.15 0.6 0.25]; end
            xline(axDist, spnDistMax.Value, '--', 'Color',cD,'LineWidth',1.2);
        end
        hold(axDist,'off');
        xlabel(axDist,'signed distance (µm)  [− inside]'); ylabel(axDist,'spots'); title(axDist,'ER / mito distance');
        % A KEY DRAWN IN THE AXES, not legend(). In a uigridlayout, legend() parents itself to the
        % LAYOUT rather than to the axes, and a legend has no Layout property — so it is auto-placed
        % into a grid cell of its own and shoves every panel below it out of position. That is what
        % put the selection row under the D distribution instead of under the table. Text objects
        % belong to the axes and cannot take a cell.
        if ~isempty(leg)
            cols = struct('ER',[0.15 0.6 0.25],'mito',[0.85 0.2 0.6]);
            for kL = 1:numel(leg)
                text(axDist, 0.97, 1.02 - 0.11*kL, leg{kL}, 'Units','normalized', ...
                    'Color',cols.(leg{kL}), 'FontSize',8.5, 'FontWeight','bold', ...
                    'HorizontalAlignment','right', 'VerticalAlignment','top', 'HitTest','off');
            end
        end

        redrawQcPooled();

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
        refreshRejectBtn();
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
        % stepwise D(t) for THIS track. The MSD panel above gives one D for the whole track; this
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
            hold(axDtrace,'on');
            plot(axDtrace, tt, Dt, '-','Color',[0.45 0.5 0.62],'LineWidth',0.9);
            plot(axDtrace, tt, Dt, '.','Color',[0.20 0.45 0.75],'MarkerSize',7);
            md = median(Dt(isfinite(Dt)));
            yline(axDtrace, md, '--','Color',[0.85 0.3 0.2],'LineWidth',1.0);   % this track's own median
            hold(axDtrace,'off');
            xlabel(axDtrace,'time along track (s)'); ylabel(axDtrace,'D (µm²/s)');
            if ~isempty(tt) && tt(end) > tt(1), xlim(axDtrace, [tt(1) tt(end)]); end
            title(axDtrace, sprintf('stepwise D(t) · med %.3g µm²/s (dashed)', md), 'FontSize',9);
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
        dt = trackDt(s.cellIdx); pxc = trackPx(s.cellIdx);
        if secsMode(), fr = round(s.F/dt); else, fr = round(s.F); end
        R = struct('base',s.base,'sptPath',sp,'erPath',er,'mitoPath',mi, ...
            'x', s.X/pxc + 1, 'y', s.Y/pxc + 1, 'frame', fr(:), 'trackId', zeros(numel(s.X),1));
    end

    function dt = trackDt(cellIdx)
        dt = DTS;
        if cellIdx>=1 && cellIdx<=numel(buildTracks) && isfield(buildTracks,'frameInterval') ...
                && ~isempty(buildTracks(cellIdx).frameInterval) && buildTracks(cellIdx).frameInterval>0
            dt = buildTracks(cellIdx).frameInterval;
        end
    end

    % ---- per-CELL calibration -------------------------------------------------------------------
    % dt has always been per cell (above), read from each cell's own XML. These three are the rest of
    % it. A cell carries its own values when the build stamped them (Tracks(k).calib, from the cell's
    % image metadata or from the panel at build time); the panel fields below are the fallback for
    % cells built before this existed. That is what lets ONE comparison span acquisitions from
    % different cameras and frame rates — e.g. a collaborator's data as a null — without retyping the
    % calibration between cells.
    function v = trackCal(cellIdx, field, dflt)
        v = dflt;
        if cellIdx>=1 && cellIdx<=numel(buildTracks) && isfield(buildTracks,'calib')
            c = buildTracks(cellIdx).calib;
            if isstruct(c) && isfield(c,field) && isscalar(c.(field)) && isfinite(c.(field)) && c.(field)>0
                v = c.(field);
            end
        end
    end
    function v = trackPx(cellIdx),   v = trackCal(cellIdx,'pixSizeUm',PXUM);   end
    function v = trackFov(cellIdx),  v = trackCal(cellIdx,'fovUm',   FOVUM);   end
    function v = trackPrec(cellIdx), v = trackCal(cellIdx,'precNm',  PRECNM);  end
    % The density BIN, which sets the grid and hence the physical detection scale. Separate from the
    % precision above: two cameras with different precisions must still be binned the same way for
    % their density maps to be comparable. Falls back to this cell's precision, then the panel.
    function v = trackBin(cellIdx),  v = trackCal(cellIdx,'binNm', trackPrec(cellIdx)); end


    function keep = qcSelection()
        keep = qcSelectionOf(qcTracks);
    end

    function keep = qcSelectionOf(recs)
        % Which tracks the pooled panels describe. Two cuts, both per TRACK:
        %   length  — localizations, not frames spanned; a gap-closed track is not credited for the
        %             frames it was absent.
        %   mito    — the MEDIAN signed distance over the track, so one excursion neither includes
        %             nor excludes it, and negative is inside the mask. Median matches how the Dwell
        %             tab summarises a track against a footprint; a min() would select any track that
        %             ever brushed a mitochondrion, which is a different and much weaker claim.
        keep = true(1, numel(recs));
        if isempty(recs), return; end
        keep = keep & ~cellfun(@(x) isfield(x,'rejected') && x.rejected, recs);   % hand-rejected
        if ~isempty(spnLenMin) && isgraphics(spnLenMin) && spnLenMin.Value > 0
            keep = keep & cellfun(@(x) x.len >= spnLenMin.Value, recs);
        end
        key = distKey();
        if ~isempty(key)
            thr = spnDistMax.Value;
            keep = keep & cellfun(@(x) hasMedDist(x, key, thr), recs);
        end
    end

    function refreshDistChannels(ER, MI)
        % Offer only the channels that have data in what is on screen. A project with no ER
        % segmentation should not be offered an ER filter that would silently select nothing —
        % that reads as a broken filter rather than as absent data.
        if isempty(ddDistCh) || ~isgraphics(ddDistCh), return; end
        items = {'any distance'}; data = {''};
        if ~isempty(MI) && any(isfinite(MI)), items{end+1} = 'near mito ≤'; data{end+1} = 'mito'; end
        if ~isempty(ER) && any(isfinite(ER)), items{end+1} = 'near ER ≤';   data{end+1} = 'er';   end
        was = ddDistCh.Value;
        ddDistCh.Items = items; ddDistCh.ItemsData = data;
        % Keep the current choice across a cell change when that channel is still available;
        % otherwise fall back to off rather than silently filtering on a different channel.
        if any(strcmp(data, was)), ddDistCh.Value = was; else, ddDistCh.Value = ''; end
    end

    function k = distKey()
        % '' = no distance filter. Otherwise 'mito' or 'er' — the record field is chosen from this,
        % never from a hardcoded channel, so adding a third channel is a change in ONE place.
        k = '';
        if ~isempty(ddDistCh) && isgraphics(ddDistCh) && ~isempty(ddDistCh.Value), k = char(ddDistCh.Value); end
    end

    function v = distOf(x, key)
        switch key
            case 'mito', v = fieldOr(x,'MI');
            case 'er',   v = fieldOr(x,'ER');
            otherwise,   v = [];
        end
        v = v(isfinite(v));
    end

    function tf = hasMedDist(x, key, thr)
        v = distOf(x, key);
        tf = ~isempty(v) && median(v) <= thr;    % no distance on this track => not selectable
    end

    function redrawQcPooled()
        % The pooled per-TRACK panels, over the SELECTED tracks. Called on build and whenever a
        % selection control moves, so the histogram and the CSD always describe the same set the
        % label counts and the export writes.
        if isempty(axDdist) || ~isgraphics(axDdist), return; end
        qcKeep = qcSelection();
        sel = qcTracks(qcKeep);
        nAll = numel(qcTracks);

        if ~isempty(lblQcSel) && isgraphics(lblQcSel)
            lblQcSel.FontColor = [0.2 0.4 0.5]; lblQcSel.FontWeight = 'normal';
        end
        nRej = sum(cellfun(@(x) isfield(x,'rejected') && x.rejected, qcTracks));
        rejTxt = ''; if nRej > 0, rejTxt = sprintf('  ·  %d rejected', nRej); end
        if ~isempty(lblQcSel) && isgraphics(lblQcSel)
            if numel(sel) == nAll
                lblQcSel.Text = sprintf('all %d tracks%s', nAll, rejTxt);
            else
                lblQcSel.Text = sprintf('%d of %d tracks selected%s', numel(sel), nAll, rejTxt);
            end
        end

        % the track map: unselected faint, selected solid, so the cut is visible where the tracks are
        if ~isempty(axCov) && isgraphics(axCov)
            cla(axCov); hold(axCov,'on');
            isRej = cellfun(@(x) isfield(x,'rejected') && x.rejected, qcTracks);
            [Xo,Yo] = catXY(qcTracks(~qcKeep & ~isRej)); [Xs,Ys] = catXY(sel);
            [Xr,Yr] = catXY(qcTracks(isRej));
            if ~isempty(Xo), plot(axCov, Xo, Yo, '-','Color',[0.80 0.82 0.88],'LineWidth',0.4,'HitTest','off'); end
            if ~isempty(Xs), plot(axCov, Xs, Ys, '-','Color',[0.35 0.42 0.62],'LineWidth',0.5,'HitTest','off'); end
            if ~isempty(Xr), plot(axCov, Xr, Yr, '-','Color',[0.85 0.25 0.20],'LineWidth',0.9,'HitTest','off'); end
            hold(axCov,'off');
            axis(axCov,'equal'); set(axCov,'YDir','reverse');
            xlabel(axCov,'x (µm)'); ylabel(axCov,'y (µm)');
            if numel(sel) == nAll, title(axCov, sprintf('tracks (click one) — %d', nAll));
            else, title(axCov, sprintf('tracks (click one) — %d of %d selected', numel(sel), nAll)); end
            qcHi = [];   % the old highlight was just cleared with the axes
        end

        % ---- D distribution: one D per TRACK, at whichever fit the user chose ----
        Dv  = cellfun(@(x) x.D, sel); Dv = Dv(isfinite(Dv) & Dv > 0);
        frv = cellfun(@(x) x.fracUsed, sel); frv = frv(isfinite(frv));
        if strcmp(fitModeNow(),'adaptive') && ~isempty(frv)
            fitTag = sprintf('adaptive R² fit %.0f–%.0f%% (median %.0f%%)', min(frv), max(frv), median(frv));
        else
            fitTag = sprintf('fixed fit %.0f%%', eMsdFrac.Value);
        end
        cla(axDdist); ddHi = [];
        if ~isempty(Dv)
            histogram(axDdist, Dv, min(40,max(5,round(numel(Dv)/3))), 'FaceColor',[0.4 0.55 0.75],'EdgeColor','none');
        end
        xlabel(axDdist,'D (µm²/s)'); ylabel(axDdist,'tracks');
        title(axDdist, sprintf('D distribution — n=%d · median %.3g µm²/s  ·  %s', ...
            numel(Dv), median0_(Dv), fitTag), 'FontSize',8.5);

        % ---- CSD over the same set ----
        cla(axCSD); csdHi = [];
        Cx = []; Cy = []; nC = 0; Call = {};
        for i = 1:numel(sel)
            cv = fieldOr(sel{i},'CSD'); cv = cv(isfinite(cv));
            if numel(cv) < 2, continue; end
            Cx = [Cx; (1:numel(cv))'; NaN]; Cy = [Cy; cv(:); NaN]; nC = nC + 1; %#ok<AGROW>
            Call{end+1} = cv(:); %#ok<AGROW>
        end
        if nC == 0
            if isfield(buildTracks,'CSD'), msg = 'CSD — no selected track long enough to plot';
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
    end

    function [X,Y] = catXY(cs)
        X = []; Y = [];
        for i = 1:numel(cs), X = [X; cs{i}.X; NaN]; Y = [Y; cs{i}.Y; NaN]; end %#ok<AGROW>
    end

    function onExportQcD(allCells)
        % Per-track D as two files: WIDE (one column, straight into a Prism Column table) and LONG
        % (every value with the cell, track and fit window behind it, so a number can be traced
        % back). The fit window travels with the value because an adaptive fit chose it per track —
        % a D exported without it cannot be compared against a D fitted over a different span.
        %
        % allCells=false exports what is on screen; true exports every cell in the build under the
        % SAME filters. Both go through qcSelection/qcRecords, so the all-cells file cannot drift
        % from what the panels would show if you selected each cell in turn.
        if nargin < 1, allCells = false; end
        if isempty(buildTracks), setBuild('Build first — there are no tracks to export.',[0.6 0.4 0.1]); return; end

        if allCells
            setBuild(sprintf('Measuring %d cells at the current fit…', numel(buildTracks)),[0.2 0.4 0.5]); drawnow;
            recs = qcRecords(1:numel(buildTracks));
            scopeTag = sprintf('allcells%d', numel(buildTracks));
        else
            if isempty(qcTracks), setBuild('Nothing shown — pick a QC cell first.',[0.6 0.4 0.1]); return; end
            recs = qcTracks;
            scopeTag = 'shown';
        end
        sel = recs(qcSelectionOf(recs));
        if isempty(sel), setBuild('No tracks pass the filters — widen them.',[0.6 0.4 0.1]); return; end

        dst = fullfile(projectDir,'analysis'); if ~isfolder(dst), mkdir(dst); end
        tag = 'all'; if ~isempty(spnLenMin) && spnLenMin.Value > 0, tag = sprintf('len%d', round(spnLenMin.Value)); end
        kD = distKey();
        if ~isempty(kD), tag = sprintf('%s_%s%.2f', tag, kD, spnDistMax.Value); end
        mode = fitModeNow();
        if strcmp(mode,'adaptive'), fitName = sprintf('adaptiveR2max%.0f', eMsdFrac.Value);
        else,                       fitName = sprintf('fixed%.0f', eMsdFrac.Value); end
        stem = fullfile(cs_ana_path(dst,'export'), sprintf('qc_trackD_%s_%s_%s', fitName, tag, scopeTag));

        D = cellfun(@(x) x.D, sel); ok = isfinite(D) & D > 0;
        nCells = numel(unique(cellfun(@(x) x.cellIdx, sel)));
        try
            fid = fopen([stem '_wide.csv'],'w');
            fprintf(fid,'D_um2_per_s\n'); fprintf(fid,'%.6g\n', D(ok)); fclose(fid);

            fid = fopen([stem '_long.csv'],'w');
            fprintf(fid,'cell,condition,track_col,n_loc,D_um2_per_s,fit_window_pct,sigma_loc_um,median_mito_um,median_er_um,fit_mode\n');
            for i = 1:numel(sel)
                x = sel{i}; if ~(isfinite(x.D) && x.D > 0), continue; end
                fprintf(fid,'%s,%s,%d,%d,%.6g,%.4g,%.4g,%s,%s,%s\n', x.base, csvSafe(condFor(x.base)), ...
                    x.col, x.len, x.D, x.fracUsed, x.sigLoc, ...
                    numOrDash(medOr(x,'MI')), numOrDash(medOr(x,'ER')), mode);
            end
            fclose(fid);
        catch ME
            setBuild(['Export failed: ' ME.message],[0.75 0.1 0.1]); return;
        end
        % SAY SO IN THREE PLACES. The status line alone was not enough feedback: it lives at the top
        % of the tab, the Export buttons are at the bottom left, and a message that appears 600 px
        % from the thing you clicked reads as nothing happening at all.
        msg = sprintf('Exported %d track D values from %d cell(s) -> %s_wide.csv + _long.csv', ...
            nnz(ok), nCells, stem);
        setBuild(msg, [0.1 0.5 0.2]);       % 1. the status line
        logBuild(msg);                       % 2. the Build log, which keeps a record you can scroll
        flashQcSel(sprintf('✓ exported %d tracks · %d cell(s)', nnz(ok), nCells));   % 3. next to the button
    end

    function flashQcSel(txt)
        % Confirm where the user is looking — the selection label sits between the filters and the
        % Export buttons. It STAYS until the next redraw (any filter change, any reject, any
        % rebuild), rather than fading on a timer: a confirmation that vanishes after two seconds
        % can be missed, which was the original complaint, and a timer outliving the app fired
        % into a deleted figure.
        if isempty(lblQcSel) || ~isgraphics(lblQcSel), return; end
        lblQcSel.Text = txt; lblQcSel.FontColor = [0.10 0.50 0.20]; lblQcSel.FontWeight = 'bold';
    end

    function v = medOr(x, f)
        v = fieldOr(x,f); v = v(isfinite(v));
        if isempty(v), v = NaN; else, v = median(v); end
    end

    function c = condFor(base)
        % This cell's condition from the experiment manifest, so an all-cells export can be grouped
        % in Prism without joining anything by hand. '' when the manifest has no row for it.
        c = '';
        if isempty(exptCtl) || ~isstruct(exptCtl), return; end
        try, cl = exptCtl.getCells(); catch, return; end
        if isempty(cl), return; end
        hit = find(strcmp({cl.file}, char(base)), 1);
        if ~isempty(hit) && isfield(cl,'condition'), c = char(cl(hit).condition); end
    end

    function t = csvSafe(v)
        t = strrep(char(v), ',', ';');    % a condition with a comma would shift every later column
    end

    function s = calSrc(cellIdx)
        % 'measured' / 'inherited' per field, so the UI can say where a cell's numbers came from
        % rather than showing an inherited value as though it had been read off the file.
        s = struct('pixSizeUm','panel','fovUm','panel','dt_s','xml','precNm','panel');
        if cellIdx>=1 && cellIdx<=numel(buildTracks) && isfield(buildTracks,'calib')
            c = buildTracks(cellIdx).calib;
            if isstruct(c) && isfield(c,'src') && isstruct(c.src), s = c.src; end
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
            % The project's pixel size, as a LIVE handle. The viewer draws the raw frame and the
            % ER/mito overlay across (width-1)*pixUm, and could previously only read that off the
            % movie's own TIFF tags — so a movie with no metadata got a hardcoded 27.61 µm and every
            % overlay sat at the wrong scale. A handle rather than a number so a calibration
            % corrected on the Experiment tab reaches the overlay without re-embedding the tab.
            tvOpts = struct('readPrefer','filtered','exportSuffix','curated','preserveCloud',true);
            tvOpts.pixUmFcn = @() PXUM;
            track_viewer(tImport, tracksDir, @resolveOverlay, {}, tvOpts);
        catch ME
            placeholder(tImport, ['Could not embed track curation: ' ME.message]);
        end
    end

    % overlay resolver: cell base -> its raw SPT movie + per-frame ER + mito segmentation stacks.
    % Primary: spt_match (handles _VAPB / _TA_BC tokens). Fallback: loose containment on a stripped key.
    function ov = resolveOverlay(base)
        % ov.seg.<key> is the keyed answer every consumer should read; ov.er / ov.mito stay as the
        % flat mirror, because track_viewer and the older overlay paths still test those by name.
        % A project's third channel appears in ov.seg and nowhere else, which is why the picker
        % reads the container first and the flat names only as a fallback.
        ov = struct('er','','mito','','spt','','seg',struct());
        chanKeys = cs_channel_keys(cs_channel_config(projectDir));
        for q = 1:numel(chanKeys), ov.seg.(chanKeys{q}) = ''; end
        b = char(base);
        if ~isempty(matched)
            for i = 1:numel(matched)
                [~,sn] = fileparts(matched(i).spt);
                if strcmpi(sn, b)
                    if isfield(matched,'seg') && isstruct(matched(i).seg), ov.seg = matched(i).seg; end
                    ov.er = matched(i).erSeg; ov.mito = matched(i).mitoSeg; ov.spt = matched(i).spt; return
                end
            end
        end
        if isempty(projectDir), return; end
        % Strip the token this project actually uses, not a hardcoded guess. The _spt\d* form stays
        % as a last resort for folders whose segmentations are missing entirely, where there is
        % nothing to derive a token from.
        key = b;
        if ~isempty(chanTok), key = regexprep(key, [regexptranslate('escape',chanTok) '$'], '', 'ignorecase'); end
        if strcmp(key, b),    key = regexprep(b, '_spt\d*$', '', 'ignorecase'); end
        % Every declared channel, from its own folder — not two literals. The flat er/mito mirror is
        % filled from the container afterwards so nothing downstream has to change at once.
        chans = cs_channel_config(projectDir);
        for q = 1:numel(chans)
            Fq = cs_channel_fields(chans(q));
            ov.seg.(Fq.key) = findSeg(fullfile(projectDir, Fq.folder), key);
        end
        if isfield(ov.seg,'er'),   ov.er   = ov.seg.er;   end
        if isfield(ov.seg,'mito'), ov.mito = ov.seg.mito; end
        ov.spt  = findSeg(fullfile(projectDir,'spt'),      b);   % raw SPT movie (match the full base)
    end

    function onCal()
        calibKnown = true;   % the user typed it, so it is supported by definition
        if isgraphics(eCalPx),   PXUM   = eCalPx.Value;   end
        if isgraphics(eCalFov),  FOVUM  = eCalFov.Value;  end
        if isgraphics(eCalDt),   DTS    = eCalDt.Value;   end
        if isgraphics(eCalPrec), PRECNM = eCalPrec.Value; end
        % The FOV is a CONSEQUENCE of the pixel size and the image width, so when the width is known
        % a typed pixel size recomputes it. Leaving the two independent is how a corrected pixel size
        % ends up sitting beside a field of view computed from the number it replaced — arithmetic
        % that no longer holds, on screen, with nothing to flag it. The FOV field stays editable for
        % a project with no movie to measure, where there is no width and nothing to derive from.
        if isfinite(IMW) && IMW > 1 && isfinite(PXUM) && PXUM > 0
            want = (IMW-1)*PXUM;
            if abs(want-FOVUM) > 1e-9
                FOVUM = want;
                if isgraphics(eCalFov), eCalFov.Value = FOVUM; end
            end
        end
        writeCalib();
        refreshDimsLabel();
    end

    function onManifestChanged()
        % Cheap and idempotent: onCalAuto no-ops unless a number actually differs, so firing this on
        % every manifest change (a condition assignment, a note, a rescan) costs one settings-file
        % read and does nothing visible unless the calibration really moved.
        try, onCalAuto(); catch, end
    end

    function onCalAuto(quiet)
        % Adopt what TOOL 1 actually used. This read only frameInterval out of a tracks XML, so the
        % pixel size and field of view kept whatever the panel held — for a new dataset, the previous
        % dataset's numbers — even though tracks/<base>_settings.txt records the real ones.
        %
        % Localization precision and the density bin are NOT touched: nothing Tool 1 writes can
        % supply them, so they stay yours.
        if nargin < 1, quiet = false; end
        if isempty(projectDir) || ~isfolder(projectDir), return; end
        if exist('spt_project_calib','file')~=2, return; end
        try, trkEx = cs_track_exclusions('load', projectDir); catch, trkEx = []; end
        try, pc = spt_project_calib(projectDir); catch, return; end
        IMW = pc.width; IMH = pc.height;
        % 'edited' is the resolver's own label for a value read back out of the manifest, so the
        % build's ranking and the toolbar's tint are driven by one source of truth rather than two.
        % The FOV rides with the pixel size: it is derived from it, so if the pixel size is a
        % correction the FOV is one too.
        CALEDIT = {};
        if strcmp(pc.src.pixUm,'edited'), CALEDIT{end+1} = 'pixSizeUm'; CALEDIT{end+1} = 'fovUm'; end
        if strcmp(pc.src.dt_s,'edited'),  CALEDIT{end+1} = 'dt_s'; end
        changed = false;
        if isfinite(pc.pixUm) && abs(pc.pixUm-PXUM) > 1e-9
            PXUM = pc.pixUm;  if isgraphics(eCalPx),  eCalPx.Value  = PXUM;  end, changed = true;
        end
        if isfinite(pc.dt_s) && abs(pc.dt_s-DTS) > 1e-12
            DTS = pc.dt_s;    if isgraphics(eCalDt),  eCalDt.Value  = DTS;   end, changed = true;
        end
        if isfinite(pc.fovUm) && abs(pc.fovUm-FOVUM) > 1e-9
            FOVUM = pc.fovUm; if isgraphics(eCalFov), eCalFov.Value = FOVUM; end, changed = true;
        end
        % Only a supported PIXEL SIZE justifies persisting a calibration file. cs_calib.mat asserts a
        % spatial scale to everything downstream, and adopting dt from a tracks XML — which almost
        % every project can supply — must not license writing a pixel size the project never stated.
        % That is precisely how the previous project's 0.16 ended up in a folder that had no movie
        % and no settings file.
        if isfinite(pc.pixUm), calibKnown = true; end
        if changed
            % Only persist once something real was adopted. writeCalib used to run unconditionally
            % here, on project OPEN, which wrote the panel's untouched defaults into the project as
            % cs_calib.mat before the user had done anything — and the next read believed them.
            writeCalib();
        end
        if ~quiet, setCalStatus(pc); end
    end

    function setCalStatus(pc)
        % Say where each number came from, on the field itself. Not being able to see that is what
        % made this invisible: the panel showed a confident 0.10785 that nothing in the project
        % supported, and looked exactly like a value someone had chosen.
        %
        % The top bar has no room for a status line, so the provenance rides on the tooltips — the
        % one place already attached to the number in question.
        srcTxt = @(f) tern(strcmp(f,'edited'),   'YOUR value, typed on the Experiment tab — it overrides the files', ...
                    tern(strcmp(f,'settings'), 'read from Tool 1''s _settings.txt', ...
                    tern(strcmp(f,'movie'),      'read from the movie''s own metadata', ...
                    tern(strcmp(f,'xml'),        'read from the tracks XML', ...
                    tern(strcmp(f,'derived'),    'computed as (width−1) × pixel size', ...
                                                 'NOT found in this project — this is your value')))));
        % A value nothing in the project supports is TINTED, not just tooltipped. When you open a
        % second project the panel still holds the first one's numbers — it has to hold something —
        % and a confident white box is what made that invisible in the first place. Amber means "this
        % came from your previous session, not from this data".
        % An EDITED value gets its own tint. White would make a correction indistinguishable from a
        % number read out of the files, and amber would call it unsupported when it is the most
        % authoritative value there is. Green says "this is yours, and it is in force".
        UNSUP = [1 0.96 0.86]; OK = [1 1 1]; EDIT = [0.90 0.97 0.90];
        tint = @(h,f) set(h,'BackgroundColor', tern(strcmp(f,'missing'), UNSUP, ...
                                               tern(strcmp(f,'edited'), EDIT, OK)));
        if isgraphics(eCalPx)
            eCalPx.Tooltip = sprintf('Camera pixel size (µm/px). %s.', srcTxt(pc.src.pixUm));
            tint(eCalPx, pc.src.pixUm);
        end
        if isgraphics(eCalDt)
            eCalDt.Tooltip = sprintf('Seconds per frame. %s.', srcTxt(pc.src.dt_s));
            tint(eCalDt, pc.src.dt_s);
        end
        if isgraphics(eCalFov)
            eCalFov.Tooltip = sprintf(['Field of view (µm) — drives the density-map scale factor. %s. ' ...
                'Tool 1 does not record a FOV, so it can only be computed from the movie.'], srcTxt(pc.src.fovUm));
            tint(eCalFov, pc.src.fovUm);
        end
        refreshDimsLabel();
        if ~isempty(lblProj) && isgraphics(lblProj)
            if isempty(pc.why), lblProj.Text = 'No tracked cells here yet — calibration is yours to set.';
            else,               lblProj.Text = ['Calibration: ' pc.why]; end
        end
    end

    function h = exptCtlNow(), h = exptCtl; end   % live handle (an anonymous @() would capture [])

    function cb = calibForBuild()
        % The calibration the importer gets, WITH the provenance it needs. Passing only the numbers
        % is what let a build quietly prefer a stale frameInterval in the XML over the dt the user
        % had just corrected: the importer could not tell a typed value from a defaulted one.
        cb = struct('pixSizeUm',PXUM,'fovUm',FOVUM,'dt_s',DTS,'binNm',PRECNM,'densBinNm',PRECNM);
        cb.edited = CALEDIT;
    end

    function refreshDimsLabel()
        % IMW/IMH are whatever the last resolve found; the tooltip spells the arithmetic out so the
        % FOV can be checked rather than believed.
        if ~isgraphics(lblDims), return; end
        if isfinite(IMW) && isfinite(IMH)
            lblDims.Text = sprintf('%g×%g px', IMW, IMH);
            lblDims.Tooltip = sprintf(['Image is %g×%g pixels, from the movie. ' ...
                'FOV = (%g − 1) × %.5g µm/px = %.5g µm. Change the pixel size and the FOV follows; ' ...
                'if the FOV looks wrong, the pixel size is what to check.'], ...
                IMW, IMH, IMW, PXUM, (IMW-1)*PXUM);
        else
            lblDims.Text = '— px';
            lblDims.Tooltip = ['No movie found for this cell, so the image dimensions are unknown ' ...
                'and the FOV cannot be checked against them. The FOV shown is yours to set.'];
        end
    end

    function writeCalib()
        % Guard first: this is called on project OPEN, from embedImportCurate, before the user has
        % touched anything. Writing then means stamping whatever the panel happens to hold — which,
        % one project into a session, is the PREVIOUS project's calibration — into a folder that may
        % have had the right answer or no answer at all.
        %
        % So it writes only when the numbers are SUPPORTED: adopted from the project by onCalAuto, or
        % typed by the user in onCal. Otherwise it will correct a file that already exists but will
        % never create one. calibKnown is what separates those.
        if ~calibKnown && ~isfile(fullfile(tern(isempty(tracksDir)||~isfolder(tracksDir),projectDir,tracksDir),'cs_calib.mat'))
            return;
        end
        dst = tracksDir; if isempty(dst) || ~isfolder(dst), dst = projectDir; end
        if isempty(dst) || ~isfolder(dst), return; end
        calib = struct('pixSizeUm',PXUM,'fovUm',FOVUM,'dt_s',DTS,'binNm',PRECNM,'snapFovUm',FOVUM); %#ok<NASGU>
        try, save(fullfile(dst,'cs_calib.mat'),'calib'); catch, end
        % analysis/ as well, when it exists. NOTHING reads tracks/cs_calib.mat — it is staging, copied
        % into analysis/ at build time, and analysis/ is the only copy cs_config ever loads. Writing
        % just the staging file meant a calibration correction did not reach Tool 3 until the next
        % rebuild, so the tool went on using the previous numbers with nothing on screen to say so.
        ana = fullfile(projectDir,'analysis');
        if isfolder(ana)
            try, save(fullfile(ana,'cs_calib.mat'),'calib'); catch, end
        end
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

function n = num0(v)
% a scalar numeric for a key, whatever a missing or odd field turns up as
if isempty(v) || ~isnumeric(v), n = 0; else, n = double(v(1)); end
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

function m = med0(v)
v = v(:); v = v(isfinite(v));
if isempty(v), m = NaN; else, m = median(v); end
end

function m = modev(v)
% Modal value as the CENTRE OF THE BUSIEST HISTOGRAM BIN, not MATLAB's mode().
%
% mode() answers "which value occurs most often", which is the wrong question for a continuous
% sample: per-site enrichment, area and mean-dwell are all distinct to many decimal places, no
% value repeats, and mode() then returns the SMALLEST one — a number that looks like a statistic
% and is really just the minimum. Binning first is what makes a mode mean anything here.
%
% Bin width by Freedman-Diaconis (2*IQR/n^(1/3)) — IQR-based, so the long right tail that dwell
% times always have cannot inflate it the way a std-based rule would; Scott's rule as the fallback
% when the IQR is zero, and the median when there is nothing to bin at all.
%
% A binned mode DEPENDS ON THE BIN WIDTH. Read it as "where the bulk of the distribution sits",
% cross-checked against the CDF, and do not quote it as a precise value.
v = v(:); v = v(isfinite(v));
if isempty(v), m = NaN; return; end
if numel(v) < 3 || (max(v)-min(v)) <= 0, m = median(v); return; end
w = 2*(pct0(v,75)-pct0(v,25)) / numel(v)^(1/3);            % Freedman-Diaconis
if ~(w > 0), w = 3.49*std(v)/numel(v)^(1/3); end           % Scott
if ~(w > 0), m = median(v); return; end
edges = min(v):w:(max(v)+w);
if numel(edges) < 2, m = median(v); return; end
[cnt, e] = histcounts(v, edges);
[~, i] = max(cnt);
m = (e(i) + e(i+1))/2;
end

function q = pct0(v, p)
% p-th percentile without the Statistics toolbox — prctile's midpoint convention (order statistics
% at (i-0.5)/n, linearly interpolated), so modev's bin width matches what prctile would give.
v = sort(v(:)); n = numel(v);
if n == 0, q = NaN; return; end
if n == 1, q = v(1); return; end
x = p/100*n - 0.5;
if x <= 0,   q = v(1); return; end
if x >= n-1, q = v(n); return; end
i = floor(x); f = x - i;
q = v(i+1)*(1-f) + v(i+2)*f;
end

function writeWideCSV(path, names, cols)
% One column per group, rows padded to the longest with empty fields — a Prism Column data table.
% Prism reads ragged columns this way; a long format would need pivoting before it could be plotted
% as "scatter with mean", which is the figure these numbers are for.
fid = fopen(path,'w');
if fid < 0, error('cannot write %s', path); end
c = onCleanup(@() fclose(fid)); %#ok<NASGU>
fprintf(fid, '%s\n', strjoin(cellfun(@csvq, names(:)', 'uni',0), ','));
nMax = max(cellfun(@numel, cols));
for r = 1:nMax
    f = cell(1,numel(cols));
    for j = 1:numel(cols)
        if r <= numel(cols{j}), f{j} = sprintf('%.6g', cols{j}(r)); else, f{j} = ''; end
    end
    fprintf(fid, '%s\n', strjoin(f, ','));
end
end

function s = numOrDash(v)
% A number, or an em dash when it could not be computed. Printing 'NaN' in a results table invites
% it being read as a value; a dash says the cell did not answer.
if isempty(v) || ~isscalar(v) || ~isfinite(v), s = '—'; else, s = sprintf('%.4g', v); end
end

function s = csvq(t)
% One CSV field, quoted — a condition named "WT, day 2" must not become two columns.
t = char(t);
if any(t == ',') || any(t == '"') || any(t == newline)
    s = ['"' strrep(t,'"','""') '"'];
else
    s = t;
end
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
