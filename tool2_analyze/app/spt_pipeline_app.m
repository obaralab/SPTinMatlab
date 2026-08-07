function spt_pipeline_app()
% SPT_PIPELINE_APP  One-window uifigure front end for the whole SPT +
% ContactSites workflow: curate tracks -> set per-dataset calibration ->
% build the Tracks struct -> scaffold the run folder -> drive the CS suite.
%
%   >> spt_pipeline_app
%
% This is the unified GUI the integration plan describes. It reuses the SAME
% drivers as pipeline_gui (build_trackstruct, setup_run_folder,
% run_contactsite_analysis) and the SAME track curation app (track_viewer),
% adding one shared project context and a Calibration tab so multi-camera
% datasets (different pixel size / FOV / dt) are handled per run.
%
% Requires R2020b+: uifigure / uigridlayout / uitab are R2019b-era, but the
% embedded contact-site picker/refiner use interactive ROI objects (drawpoint /
% drawpolygon) in a uiaxes, which need R2020a (R2020b for full reliability). The
% classic pipeline_gui remains for older MATLAB / Octave.

% ---- resolve sibling code folders onto the path ---------------------------
here = fileparts(mfilename('fullpath'));         % gui/
root = fileparts(here);                          % repo root
addpath(here);                                   % gui/  (track_viewer.m lives here too)
addpath(fullfile(root,'drivers'));               % build_trackstruct, setup_run_folder, run_contactsite_analysis, read_calibration, calibration_panel
S = struct('projectDir','','suitePath','','mito','','maxint','','er','');
csRunning = false;   % re-entrancy guard: a ContactSites run is interactive & blocking
QCstate = [];        % aggregated Import-QC data, for the click-to-select-track interaction
qcTimer = [];        % playback timer for the selected track (kept out of QCstate so refresh can't orphan it)
qcList = []; qcAllT = [];   % Import-QC: per-cell list + the loaded Tracks (view one cell at a time)
qcOverlayImg = [];   % normalized mito/ER structure image for the QC overlay
chkQCov = [];        % QC 'overlay' checkbox handle
eMsdFrac = [];       % QC "MSD fit %" spinner -> fraction of lags for fitDeff
% ---- Contact-Site Results (tab 6) state ----
csData=[]; csSelK=[]; csPlayFrame=0; csFrameMin=0; csFrameMax=0; playMode='qc';
csRefining=false;                 % re-entrancy guard for the in-place boundary editor (Tab 7)
csOverlayImg=[]; chkCSov=[]; csTable=[]; csAx=[]; csAxRad=[]; lRes=[]; csOvCi=[];   % csAxRad = radial curve; csOvCi = cell whose mito overlay is loaded
csMitoBg=[]; csMitoBgCi=[];        % cached cell-wide mito background level (Otsu) for the absolute overlay scale
chkCSradHist=[];                   % CS Results: toggle the bottom panel between the radial curve and a per-track loc histogram
csTrkUndo=[]; bTrkUndo=[];         % CS Results (Tab 7): one-level undo for Add/Remove track membership edits
csMemDens=[]; chkCSwhole=[];   % cached member-track density (boundary-aligned)
csTouchCols=[]; csTouchColsSig=[];   % per-selection cache of csTouchingCols (avoids per-playback-frame inpolygon)
csWholeDens=[]; csWholeDensK=[];   % whole-cell density on the SAME grid as csMemDens (built lazily per CS) so toggling never shifts the image
csTrkList=[]; csTrkHi=[];      % CS Results: per-CS track list + isolated-track highlight handle
csIsoTrk=[]; chkCSspots=[];    % CS Results: isolated track column (click-to-play) + "all spots" toggle
densAlpha=1; sldDensCS=[]; sldDensDw=[];   % shared density-background opacity (CS Results + Dwell panels)
csDensClip=1; sldDensContrast=[];   % CS density contrast (clip fraction of the site peak)
csDensProbMode=false; chkCSprobDisp=[];   % show CS density as the per-cell PMF on a shared cross-cell scale
axCSall=[]; chkCSall=[];       % whole-cell tracks panel; "all tracks" toggle for the site view
lProg=[]; csRunT0=[]; csPrevKey=''; csLastTic=[]; csAutoElapsed=0; csAutoDone=0;   % live run-progress
tabLamps=[];   % per-tab progress lamps in the Status & Log panel
tDwell=[]; dwTable=[]; axDwDist=[]; axDwTrace=[]; lDwell=[]; chkDwAll=[]; dwellData=[];   % dwell & labels tab
dwellOverrides=containers.Map('KeyType','char','ValueType','any');   % manual class/entry/exit edits (Tab 8), persisted to CSV
axDwSpace=[]; dwSel=[]; dwTimer=[]; dwIdx=1;   % dwell tab: track playback in the CS reference frame
axDwCell=[]; chkDwCenter=[];                    % dwell tab: whole-cell panel; recenter distance on boundary centroid
chkDwMito=[]; dwMitoImg=[]; dwMitoCi=[];         % dwell tab: mito overlay (auto-matched per cell, cached by cell index)
% multi-condition experiment (Setup): type-folders + scanned cells + manifest
eExTracks=[]; eExMito=[]; eExEr=[]; eExCond=[]; exptTable=[]; exptStatus=[]; exptCells=[]; exptSelRows=[]; bWorkSel=[];
eExMitoPat=[]; eExErPat=[]; eExPrefix=[];   % mito/ER filename patterns + prefix-strip regex
spDwin=[]; spSig=[]; dwDwin=5; dwSigNm=30;      % per-timestep D: window (steps) + loc precision (nm)
% multi-condition comparison (tab 9): accumulated per-cell metrics + UI handles
cmpData=[]; cmpTable=[]; cmpMetric=[]; axCmpMain=[]; axCmpDist=[]; lCmp=[]; cmpGroupBy=[];
for c = {fullfile(root,'ContactSites_robust'), ...
         fullfile(root,'ContactSites_original'), ...
         fullfile(root,'ContactSites')}
    if isfolder(c{1}), addpath(genpath(c{1})); S.suitePath = c{1}; break; end
end

GREY  = [0.60 0.60 0.60];
GREEN = [0.30 0.75 0.30];

% ===========================================================================
% WINDOW  (HandleVisibility off so the suite's `close all` cannot close it)
% ===========================================================================
fig = uifigure('Name','SPT + ContactSites Pipeline','Position',[50 40 1400 980], ...
    'HandleVisibility','off','AutoResizeChildren','off','CloseRequestFcn',@(s,e) onAppClose());
gl = uigridlayout(fig,[3 1],'RowHeight',{96,'1x',150}, ...
    'Padding',[8 8 8 8],'RowSpacing',8);

% ---------------- Project bar ----------------------------------------------
pProj = uipanel(gl,'Title','Project'); pProj.Layout.Row = 1;
pg = uigridlayout(pProj,[2 5],'RowHeight',{24,24}, ...
    'ColumnWidth',{110,'1x',90,110,120},'Padding',[8 6 8 6],'RowSpacing',4);
lp1 = uilabel(pg,'Text','Project folder:'); lp1.Layout.Row=1; lp1.Layout.Column=1;
eProj = uieditfield(pg,'text','Editable','off'); eProj.Layout.Row=1; eProj.Layout.Column=2;
bBrowse = uibutton(pg,'Text','Browse…','ButtonPushedFcn',@onBrowseProject);
bBrowse.Layout.Row=1; bBrowse.Layout.Column=3;
bLoadAna = uibutton(pg,'Text','Load analysis…','ButtonPushedFcn',@onLoadAnalysis, ...
    'Tooltip','Point at a project/analysis folder and refresh EVERY tab (Curate, QC, CS Results, Dwell, Compare) from its saved files — resume where you left off.');
bLoadAna.Layout.Row=1; bLoadAna.Layout.Column=4;
bRefresh = uibutton(pg,'Text','↻ Refresh tabs','ButtonPushedFcn',@(s,e) refreshAllAnalysis(), ...
    'Tooltip','Re-read the current project''s analysis files into CS Results / Dwell / Compare (after a new run or an external change).');
bRefresh.Layout.Row=1; bRefresh.Layout.Column=5;
lTracks = uilabel(pg,'Text','tracks subdir:'); lTracks.Layout.Row=2; lTracks.Layout.Column=1;
eTracks = uieditfield(pg,'text','Value','tracks'); eTracks.Layout.Row=2; eTracks.Layout.Column=2;
lAna = uilabel(pg,'Text','analysis subdir:'); lAna.Layout.Row=2; lAna.Layout.Column=[3 4];
eAnalysis = uieditfield(pg,'text','Value','analysis'); eAnalysis.Layout.Row=2; eAnalysis.Layout.Column=5;

% ---------------- Tab group ------------------------------------------------
tg = uitabgroup(gl); tg.Layout.Row = 2;
tg.SelectionChangedFcn = @(s,e) onTabChanged(e);   % refresh Experiment status column on entry

% ===== Tab 1: Calibration =====
tCal = uitab(tg,'Title','1 · Calibration');
cgl = uigridlayout(tCal,[8 3],'RowHeight',repmat({28},1,8), ...
    'ColumnWidth',{170,140,'1x'},'Padding',[14 12 14 12],'RowSpacing',6);
lblRow(cgl,1,'Per-dataset calibration — auto-fill from metadata, or TYPE the values you see (ImageJ ▸ Image ▸ Properties) if it was stripped.',[1 3]);
uilabel(cgl,'Text','Pixel size (µm/px):');       ePix = uieditfield(cgl,'text'); uilabel(cgl,'Text','from TIFF XResolution');
uilabel(cgl,'Text','Image size (px, width):');   eNpx = uieditfield(cgl,'text'); uilabel(cgl,'Text','sensor pixels across the FOV');
uilabel(cgl,'Text','Field of view (µm):');       eFov = uieditfield(cgl,'text'); uilabel(cgl,'Text','= pixel size × image size');
uilabel(cgl,'Text','Frame interval dt (s):');    eDt  = uieditfield(cgl,'text'); uilabel(cgl,'Text','from TrackMate frameInterval; sets Deff & dwell times');
uilabel(cgl,'Text','Density bin (nm):');         eBin = uieditfield(cgl,'text','Value','30'); uilabel(cgl,'Text','usually 30; camera-independent');
bCalAuto = uibutton(cgl,'Text','Auto-detect from files','ButtonPushedFcn',@onCalibAuto);
bCalSave = uibutton(cgl,'Text','Save calibration','ButtonPushedFcn',@onCalibSave,'FontWeight','bold');
lCalStatus = uilabel(cgl,'Text','No calibration saved yet.','FontColor',[0.3 0.4 0.6]);
lCalStatus.Layout.Row = 8; lCalStatus.Layout.Column = [1 3];
ePix.ValueChangedFcn=@onCalScale; eNpx.ValueChangedFcn=@onCalScale;

% ===== Tab 2: Experiment (multi-condition ingest — folders + conditions) =====
tExp = uitab(tg,'Title','2 · Experiment');
xgl = uigridlayout(tExp,[7 1],'RowHeight',{30,30,30,30,34,'1x',24},'Padding',[12 12 12 12],'RowSpacing',8);
% three type-folder pickers
xr1 = uigridlayout(xgl,[1 3],'ColumnWidth',{150,'1x',120},'Padding',[0 0 0 0],'ColumnSpacing',6); xr1.Layout.Row=1;
uilabel(xr1,'Text','Tracks folder (.xml):');
eExTracks = uieditfield(xr1,'text','Editable','off','Placeholder','folder with *_tracks.xml + *_spots.csv');
uibutton(xr1,'Text','Pick…','ButtonPushedFcn',@(s,e) onExpPick('tracks'));
xr2 = uigridlayout(xgl,[1 3],'ColumnWidth',{150,'1x',120},'Padding',[0 0 0 0],'ColumnSpacing',6); xr2.Layout.Row=2;
uilabel(xr2,'Text','Mito max-int folder:');
eExMito = uieditfield(xr2,'text','Editable','off','Placeholder','folder with mito MIP .tif');
uibutton(xr2,'Text','Pick…','ButtonPushedFcn',@(s,e) onExpPick('mito'));
xr3 = uigridlayout(xgl,[1 3],'ColumnWidth',{150,'1x',120},'Padding',[0 0 0 0],'ColumnSpacing',6); xr3.Layout.Row=3;
uilabel(xr3,'Text','ER max-int folder:');
eExEr = uieditfield(xr3,'text','Editable','off','Placeholder','folder with ER MIP .tif');
uibutton(xr3,'Text','Pick…','ButtonPushedFcn',@(s,e) onExpPick('er'));
% name patterns: {prefix} is the tracks base with the "strip" regex removed from its END
xrp = uigridlayout(xgl,[1 7],'ColumnWidth',{86,'1x',72,'1x',96,110,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6); xrp.Layout.Row=4;
uilabel(xrp,'Text','Mito pattern:');
eExMitoPat = uieditfield(xrp,'text','Value','{prefix}_mito_mip.tif','Tooltip','{prefix} = the cell prefix; * allowed. e.g. {prefix}_mito_mip.tif');
uilabel(xrp,'Text','ER pattern:');
eExErPat = uieditfield(xrp,'text','Value','{prefix}_er_mip.tif');
uilabel(xrp,'Text','prefix = strip:');
eExPrefix = uieditfield(xrp,'text','Value','_spt\d+', ...
    'Tooltip','regex removed from the END of the tracks name to form {prefix} (e.g. _spt\d+ turns 250408_FFAT_001_spt1 into 250408_FFAT_001). Blank = use the full tracks name.');
% actions
xr4 = uigridlayout(xgl,[1 7],'ColumnWidth',{88,150,178,138,128,182,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6); xr4.Layout.Row=5;
uibutton(xr4,'Text','🔍 Scan','FontWeight','bold','ButtonPushedFcn',@(s,e) onExpScan());
eExCond = uieditfield(xr4,'text','Placeholder','condition name');
uibutton(xr4,'Text','Assign to selected rows','ButtonPushedFcn',@(s,e) onExpAssign());
uibutton(xr4,'Text','Import mapping…','ButtonPushedFcn',@(s,e) onExpImportMap());
uibutton(xr4,'Text','💾 Save manifest','ButtonPushedFcn',@(s,e) onExpSave());
bWorkSel = uibutton(xr4,'Text','✓ Work on ticked','FontWeight','bold','BackgroundColor',[0.18 0.45 0.70],'FontColor','w', ...
    'Tooltip','Apply the ''work'' ticks for this session: Curate and the picker will only show the ticked cells (density is generated only for them too).', ...
    'ButtonPushedFcn',@(s,e) onApplyWorkSel());
% the cells table (condition editable + flagged rows for missing/ambiguous files)
exptTable = uitable(xgl,'ColumnName',{'work','condition','name','tracks','mito','ER','status','TrackStruct'}, ...
    'ColumnWidth',{50,116,178,48,110,110,84,120}, ...
    'ColumnEditable',[true true false false false false false false], ...
    'ColumnFormat',{'logical',[],[],[],[],[],[],[]}, ...
    'RowName',{},'CellSelectionCallback',@(s,e) onExpSelect(e),'CellEditCallback',@(s,e) onExpEdit(e), ...
    'Tooltip',['work = include this cell in the session (the picker only opens the ticked cells). ' ...
    'status = progress on disk: density → picked → refined. Re-Scan (or re-enter this tab) to refresh status.']);
exptTable.Layout.Row=6;
exptStatus = uilabel(xgl,'Text','Pick the three folders, set the mito/ER patterns, then Scan. Assign conditions, then Save manifest.','FontColor',[0.35 0.45 0.65]);
exptStatus.Layout.Row=7;

% ===== Tab 3: Curate (track_viewer embedded once a project is picked) =====
tCur = uitab(tg,'Title','3 · Curate tracks');
curPlaceholder('Pick a project folder — track curation (track_viewer) loads here once it is found.');

% ===== Tab 4: Build tracks =====
tBld = uitab(tg,'Title','4 · Build tracks');
bgl = uigridlayout(tBld,[6 4],'RowHeight',repmat({30},1,6), ...
    'ColumnWidth',{140,180,'1x',150},'Padding',[14 12 14 12],'RowSpacing',8);
uilabel(bgl,'Text','Build TrackStruct — import every cell in the Experiment tracks folder','FontWeight','bold');
bCombine = uibutton(bgl,'Text','⧉ Combine TrackStructs…','ButtonPushedFcn',@(o,e) onCombineTrackstructs(), ...
    'Tooltip',['Merge several days'' TrackStruct.mat into ONE combined TrackStruct in this project''s ' ...
    'analysis folder, then run the contact-site pipeline / comparison over all days together.']);
bCombine.Layout.Row=1; bCombine.Layout.Column=4;
bLoadTs = uibutton(bgl,'Text','Load TrackStruct…','ButtonPushedFcn',@(o,e) onLoadTrackStruct(), ...
    'Tooltip',['Load an existing TrackStruct.mat (e.g. after restarting MATLAB) as this project''s ' ...
    'analysis/TrackStruct.mat and show it in Import QC — resume without rebuilding.']);
bLoadTs.Layout.Row=1; bLoadTs.Layout.Column=3;
b1 = uilabel(bgl,'Text','Time unit:'); b1.Layout.Row=2; b1.Layout.Column=1;
ddTime = uidropdown(bgl,'Items',{'frame','seconds'}); ddTime.Layout.Row=2; ddTime.Layout.Column=2;
bBuild = uibutton(bgl,'Text','Build Tracks','ButtonPushedFcn',@onBuild,'FontWeight','bold');
bBuild.Layout.Row=2; bBuild.Layout.Column=4;
nameG = uigridlayout(bgl,[1 2],'ColumnWidth',{56,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',4);
nameG.Layout.Row=2; nameG.Layout.Column=3;
uilabel(nameG,'Text','save as:','FontSize',11);
eTsName = uieditfield(nameG,'text','Value','TrackStruct', ...
    'Tooltip',['Output name in the analysis folder (.mat added automatically). Default "TrackStruct" = the ' ...
    'pipeline input. Give each curation a distinct name (e.g. day1, day2) to keep several, then ' ...
    '"Combine TrackStructs…" merges them into the final analysis/TrackStruct.mat.']);
h1 = uilabel(bgl,'Text','Setup run folder  (optional — mito & ER now come from the Experiment tab)', ...
    'FontColor',[0.5 0.5 0.55]); h1.Layout.Row=3; h1.Layout.Column=[1 4];
m1 = uilabel(bgl,'Text','Mito image:'); m1.Layout.Row=4; m1.Layout.Column=1;
eMito = uieditfield(bgl,'text','Editable','off'); eMito.Layout.Row=4; eMito.Layout.Column=[2 3];
bMito = uibutton(bgl,'Text','Pick mito…','ButtonPushedFcn',@(o,e)onPick('mito',eMito)); bMito.Layout.Row=4; bMito.Layout.Column=4;
x1 = uilabel(bgl,'Text','MaxInt RGB image:'); x1.Layout.Row=5; x1.Layout.Column=1;
eMax = uieditfield(bgl,'text','Editable','off'); eMax.Layout.Row=5; eMax.Layout.Column=[2 3];
bMax = uibutton(bgl,'Text','Pick MaxInt…','ButtonPushedFcn',@(o,e)onPick('maxint',eMax)); bMax.Layout.Row=5; bMax.Layout.Column=4;
s1 = uilabel(bgl,'Text','Mito name suffix:'); s1.Layout.Row=6; s1.Layout.Column=1;
ddSuffix = uidropdown(bgl,'Items',{'_3_TA_BC.tif  (reorienter v2)','_3_maxS2N_8bit.tif  (reorienter v3)'});
ddSuffix.Layout.Row=6; ddSuffix.Layout.Column=[2 3];
bSetup = uibutton(bgl,'Text','Setup Folders','ButtonPushedFcn',@onSetup,'FontWeight','bold');
bSetup.Layout.Row=6; bSetup.Layout.Column=4;

% ===== Tab 4b: Import QC (diagnostics from the imported Tracks) =====
tQC = uitab(tg,'Title','4b · Import QC');
qgl = uigridlayout(tQC,[2 3],'RowHeight',{'1x',34}, ...
    'ColumnWidth',{175,'2.15x','1x'},'Padding',[10 10 10 10], ...
    'RowSpacing',6,'ColumnSpacing',6);
% Left: a per-cell list (click a cell to view just its tracks). Middle: the BIG
% Tracks panel for the selected cell. Right: the diagnostics (MSD/centered/D/CSD).
qcLeft = uigridlayout(qgl,[2 1],'RowHeight',{20,'1x'},'Padding',[0 0 0 0],'RowSpacing',4);
qcLeft.Layout.Row=1; qcLeft.Layout.Column=1;
uilabel(qcLeft,'Text','Cells (click one)','FontWeight','bold','FontSize',10);
qcList = uilistbox(qcLeft,'Items',{},'ValueChangedFcn',@(s,e) drawQCcell());
axTracks = uiaxes(qgl); axTracks.Layout.Row=1; axTracks.Layout.Column=2; axTracks.FontSize=10; box(axTracks,'on');
qright = uigridlayout(qgl,[3 2],'RowHeight',{'1.3x','1x','1x'},'Padding',[0 0 0 0],'RowSpacing',6,'ColumnSpacing',6);
qright.Layout.Row=1; qright.Layout.Column=3;
axSel = uiaxes(qright); axSel.Layout.Row=1; axSel.Layout.Column=[1 2]; axSel.FontSize=8; box(axSel,'on');
axMSD = uiaxes(qright); axMSD.Layout.Row=2; axMSD.Layout.Column=1; axMSD.FontSize=8; box(axMSD,'on');
axCentered = uiaxes(qright); axCentered.Layout.Row=2; axCentered.Layout.Column=2; axCentered.FontSize=8; box(axCentered,'on');
axDeff = uiaxes(qright); axDeff.Layout.Row=3; axDeff.Layout.Column=1; axDeff.FontSize=8; box(axDeff,'on');
axCSD  = uiaxes(qright); axCSD.Layout.Row=3;  axCSD.Layout.Column=2;  axCSD.FontSize=8;  box(axCSD,'on');
title(axMSD,'MSD + fit'); title(axSel,'Selected track + spots');
title(axTracks,'Tracks (click one)'); title(axCentered,'Centered');
title(axDeff,'D dist'); title(axCSD,'CSD (\mum)');
% match the curation view's ImageJ orientation (Y increases downward)
axTracks.YDir='reverse'; axCentered.YDir='reverse'; axSel.YDir='reverse';
% clicks select a track instead of pan/zoom (MSD + Tracks); axSel is redrawn by
% the playback timer, so disable its interactions too (they fight timer redraws).
disableDefaultInteractivity(axMSD); disableDefaultInteractivity(axTracks); disableDefaultInteractivity(axSel);
qcCtl = uigridlayout(qgl,[1 8],'ColumnWidth',{'1x',64,70,84,96,170,112,84},'Padding',[0 0 0 0],'ColumnSpacing',6);
qcCtl.Layout.Row=2; qcCtl.Layout.Column=[1 3];
lQC = uilabel(qcCtl,'Text','Build the track struct (tab 3) to see import diagnostics.');
uibutton(qcCtl,'Text','▶ Play','ButtonPushedFcn',@(s,e) onQCPlay());
uibutton(qcCtl,'Text','⏸ Pause','ButtonPushedFcn',@(s,e) onQCPause());
chkQCov = uicheckbox(qcCtl,'Text','mito overlay','Value',true,'ValueChangedFcn',@(s,e) onQCoverlayChanged());
uibutton(qcCtl,'Text','Structure…','ButtonPushedFcn',@(s,e) onQCpickOverlay());
uibutton(qcCtl,'Text','Send Tracks → workspace','ButtonPushedFcn',@(s,e) onSendWorkspace());
msdG = uigridlayout(qcCtl,[1 2],'ColumnWidth',{58,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',3);
uilabel(msdG,'Text','MSD fit %','FontSize',10);
eMsdFrac = uispinner(msdG,'Limits',[5 100],'Value',50,'Step',5, ...
    'Tooltip','% of each track''s finite MSD lags used for the D = slope/4 linear fit (default 50)', ...
    'ValueChangedFcn',@(s,e) drawQCcell());
uibutton(qcCtl,'Text','Refresh','ButtonPushedFcn',@(s,e) showImportQC());

% ===== Tab 4: Run ContactSites =====
tRun = uitab(tg,'Title','5 · Run ContactSites');
rgl = uigridlayout(tRun,[5 4],'RowHeight',{30,30,30,30,'1x'}, ...
    'ColumnWidth',{140,180,180,'1x'},'Padding',[14 12 14 12],'RowSpacing',8);
stages = {'density','locdens','quickplot','csid','mapper','part2','snaprename','refiner','ensemble','builder','accum'};
r0 = uilabel(rgl,'Text','Runs the whole pipeline from the start. Just press Run.','FontWeight','bold','FontSize',13);
r0.Layout.Row=1; r0.Layout.Column=[1 3];
bRun = uibutton(rgl,'Text','▶  Run / Resume','ButtonPushedFcn',@onRunCS,'FontWeight','bold', ...
    'BackgroundColor',[0.16 0.45 0.70],'FontColor','w','FontSize',13);
bRun.Layout.Row=1; bRun.Layout.Column=4;
% Advanced (de-emphasised): resume mid-pipeline / stop early. Default Start = 'density' = full run.
r1 = uilabel(rgl,'Text','Advanced — start stage:','FontColor',[0.5 0.56 0.62],'FontSize',11); r1.Layout.Row=2; r1.Layout.Column=1;
ddStart = uidropdown(rgl,'Items',stages,'Value','density'); ddStart.Layout.Row=2; ddStart.Layout.Column=2;
r2 = uilabel(rgl,'Text','stop after (optional):','FontColor',[0.5 0.56 0.62],'FontSize',11); r2.Layout.Row=3; r2.Layout.Column=1;
ddStop = uidropdown(rgl,'Items',[{'(next gate)'} stages]); ddStop.Layout.Row=3; ddStop.Layout.Column=2;
cbJBM = uicheckbox(rgl,'Text','JBM / Deff branch','Value',true); cbJBM.Layout.Row=2; cbJBM.Layout.Column=3;
cbMito = uicheckbox(rgl,'Text','Mito-flagged CSs only','Value',false); cbMito.Layout.Row=3; cbMito.Layout.Column=3;
tsG = uigridlayout(rgl,[2 1],'RowHeight',{15,'1x'},'Padding',[0 0 0 0],'RowSpacing',2);
tsG.Layout.Row=[2 3]; tsG.Layout.Column=4;
uilabel(tsG,'Text','TrackStruct .mat to run:','FontSize',11,'FontColor',[0.5 0.56 0.62]);
ddTsFile = uidropdown(tsG,'Items',{'TrackStruct.mat'},'Value','TrackStruct.mat', ...
    'Tooltip',['Which TrackStruct .mat in the analysis folder this run uses. Pick a named build ' ...
    '(e.g. Day1.mat, a subselection) or a combined TrackStruct.mat. Refreshes when you open this tab.']);
cbAccum = uicheckbox(rgl,'Text','Excel + reference images (slow)','Value',true, ...
    'Tooltip',['The final "accum" stage writes the Excel table + a QC image per contact site. It is ' ...
    'slow (freezes the UI while it runs) and CS_final.mat — everything Tab 7 needs — is already built ' ...
    'before it. Untick to stop after the builder so CS Results opens immediately; run the export later.']);
cbAccum.Layout.Row=4; cbAccum.Layout.Column=[3 4];
r3 = uilabel(rgl,'Text','Leave "start stage" at density for a full run. Picking & refining open in the "Contact Sites" tab; CS Results opens automatically when the run finishes.', ...
    'FontColor',[0.5 0.56 0.62],'FontSize',11,'WordWrap','on'); r3.Layout.Row=4; r3.Layout.Column=[1 2];
% Row 5: dynamic per-stage hint (top) + full scrollable pipeline documentation (fills the tab).
docBox = uigridlayout(rgl,[2 1],'RowHeight',{'fit','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
docBox.Layout.Row=5; docBox.Layout.Column=[1 4];
% what each stage does + where you can resume from (updates with the "start stage" dropdown)
lStageDesc = uilabel(docBox,'Text','','FontSize',11,'WordWrap','on','FontColor',[0.30 0.35 0.42], ...
    'VerticalAlignment','top');
ddStart.ValueChangedFcn = @(s,e) updateStageDesc();
updateStageDesc();   % initial text for the default 'density'
% Always-visible, detailed documentation of the whole pipeline. Loaded from the sibling HTML
% file (gui/cs_pipeline_doc.html) so it is easy to edit; degrades to a short text pointer if
% uihtml or the file is unavailable.
try
    docFile = fullfile(fileparts(mfilename('fullpath')),'cs_pipeline_doc.html');
    uihtml(docBox,'HTMLSource',fileread(docFile));
catch
    uilabel(docBox,'Text',['Pipeline: density/locdens build the density maps; you PICK sites (csid) and ' ...
        'REFINE boundaries (refiner) in the Contact Sites tab; mapper/part2 attach tracks; builder writes ' ...
        'CS_final.mat (the result Tabs 7 & 8 read); accum writes the optional Excel + per-site QC images ' ...
        '(slow). Full details in gui/cs_pipeline_doc.html.'],'FontSize',11,'WordWrap','on', ...
        'FontColor',[0.30 0.35 0.42],'VerticalAlignment','top');
end

% ===== Tab 5: Contact Sites (cs_identify picker + cs_refine embed here) =====
tCS = uitab(tg,'Title','6 · Contact Sites');
csPlaceholder('The contact-site picker and refiner open here when you Run (tab 4).');

% ===== Tab 6: Contact Site Results (browse · play · classify · dwell) =====
tRes = uitab(tg,'Title','7 · CS Results');
rgl6 = uigridlayout(tRes,[2 3],'RowHeight',{'1x',34},'ColumnWidth',{440,'1x','1x'}, ...
    'Padding',[8 8 8 8],'RowSpacing',6,'ColumnSpacing',8);
csLeft6 = uigridlayout(rgl6,[5 1],'RowHeight',{'1.4x',28,18,'1x',30},'Padding',[0 0 0 0],'RowSpacing',4);
csLeft6.Layout.Row=1; csLeft6.Layout.Column=1;
csTable = uitable(csLeft6,'ColumnName',{'CS','cell','file','mito','#trk','dwell s','p','enrich'}, ...
    'ColumnWidth',{34,34,124,40,38,50,52,48},'RowName',{}, 'CellSelectionCallback',@(s,e) onCSselect(e), ...
    'Tooltip',['Each row is a contact site. "cell" is the numeric cellIndex; "file" is its source ' ...
    'cell filename. "p" = per-cell localization probability (advisor-style: localizations inside the ' ...
    'site / total localizations in the cell). "enrich" = fold local density over the cell baseline. ' ...
    'Both are exported to analysis/cs_density_metrics.csv and saved on CS_final. Click a row (or use ◀ Prev / Next ▶) to open that site. The full index -> file -> ' ...
    'condition mapping is also saved to analysis/cell_index_map.csv.']);
% step through contact sites without hunting in the list (click back and forth)
csNav = uigridlayout(csLeft6,[1 2],'ColumnWidth',{'1x','1x'},'Padding',[0 0 0 0],'ColumnSpacing',4);
uibutton(csNav,'Text','◀ Prev CS','ButtonPushedFcn',@(s,e) onCSStep(-1));
uibutton(csNav,'Text','Next CS ▶','ButtonPushedFcn',@(s,e) onCSStep(+1));
uilabel(csLeft6,'Text','Tracks in this CS · loc inside / total (multi-select to remove)','FontWeight','bold','FontSize',10);
csTrkList = uilistbox(csLeft6,'Items',{},'FontSize',10,'Multiselect','on','ValueChangedFcn',@(s,e) onCStrkPick(), ...
    'Tooltip',['Each track shows its localizations INSIDE the boundary / its total, and %% inside — ' ...
    'low %% = a track that barely sits in the site. Click one to isolate & play it; Ctrl/Shift-click ' ...
    'several, then "－ Remove" to drop them all at once.']);
csTrkBtns = uigridlayout(csLeft6,[1 4],'ColumnWidth',{'1x','0.85x','0.7x','0.75x'},'Padding',[0 0 0 0],'ColumnSpacing',4);
uibutton(csTrkBtns,'Text','＋ Add track…','FontSize',10,'ButtonPushedFcn',@(s,e) onCStrkAdd());
uibutton(csTrkBtns,'Text','－ Remove','FontSize',10,'FontColor',[0.7 0.1 0.1],'ButtonPushedFcn',@(s,e) onCStrkRemove());
bTrkUndo = uibutton(csTrkBtns,'Text','↶ Undo','FontSize',10,'Enable','off','ButtonPushedFcn',@(s,e) onCStrkUndo(), ...
    'Tooltip','Undo the last Add/Remove track edit on the current contact site (one level)');
uibutton(csTrkBtns,'Text','✂ Trim','FontSize',10,'ButtonPushedFcn',@(s,e) onCStrkTrimAll(), ...
    'Tooltip',['Remove over-associated tracks from ALL contact sites — keep only tracks with >=1 localization ' ...
    'inside the refined boundary. The mapper''s large box captures many DISTINCT tracks that aren''t really at ' ...
    'the site; this drops them. Rewrites CS_final.mat (metrics are unchanged — they use localizations inside).']);
% middle column: per-CS density (top) + radial-concentration curve / loc histogram (bottom, keep/discard aid)
csMid6 = uigridlayout(rgl6,[2 1],'RowHeight',{'1x',172},'Padding',[0 0 0 0],'RowSpacing',6);
csMid6.Layout.Row=1; csMid6.Layout.Column=2;
csAx = uiaxes(csMid6); csAx.FontSize=9; box(csAx,'on');   % row 1 (auto-flow)
csAx.YDir='reverse';
try, csAx.Interactions=[zoomInteraction panInteraction]; axtoolbar(csAx,{'zoomin','zoomout','pan','restoreview'}); catch, end   % scroll-zoom / pan / reset so you can zoom out to the tracks
% bottom sub-panel: a toggle (row 1) over the radial/histogram axes (row 2)
csRadBox = uigridlayout(csMid6,[2 1],'RowHeight',{18,'1x'},'Padding',[0 0 0 0],'RowSpacing',2);   % row 2 (auto-flow)
chkCSradHist = uicheckbox(csRadBox,'Text','histogram: loc per 30 nm bin (whole cell)','FontSize',9,'Value',false, ...
    'Tooltip',['Bottom panel: OFF = radial concentration curve for THIS site (cumulative %% of localizations vs ' ...
    'radius). ON = histogram of localizations per 30 nm bin across the WHOLE cell (occupied bins only) — the ' ...
    'cell''s density distribution, independent of the contact site.'], ...
    'ValueChangedFcn',@(s,e) drawCSradial(csSelK));
csAxRad = uiaxes(csRadBox); csAxRad.FontSize=8; box(csAxRad,'on');   % row 2 — radial curve OR loc-per-track histogram
title(csAxRad,'local density');
axCSall = uiaxes(rgl6); axCSall.Layout.Row=1; axCSall.Layout.Column=3; axCSall.FontSize=9; box(axCSall,'on');
axCSall.YDir='reverse'; title(axCSall,'Whole cell — all tracks + sites');
% interactive (like QC/curate): scroll/drag to zoom + pan, toolbar to reset
axCSall.Interactions=[zoomInteraction panInteraction];
axtoolbar(axCSall,{'zoomin','zoomout','pan','restoreview'});
resCtl = uigridlayout(rgl6,[1 15],'ColumnWidth',{72,60,64,70,80,96,100,96,88,104,86,78,72,232,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
resCtl.Layout.Row=2; resCtl.Layout.Column=[1 3];
uibutton(resCtl,'Text','Reload','ButtonPushedFcn',@(s,e) loadCSresults());
uibutton(resCtl,'Text','Load…','ButtonPushedFcn',@(s,e) loadIntoTab('cs'), ...
    'Tooltip','Load a CS_final.mat from another project into CS Results (points the analysis folder at its location)');
uibutton(resCtl,'Text','▶ Play','ButtonPushedFcn',@(s,e) onCSPlay());
uibutton(resCtl,'Text','⏸ Pause','ButtonPushedFcn',@(s,e) onQCPause());
chkCSov = uicheckbox(resCtl,'Text','overlay','Value',true,'ValueChangedFcn',@(s,e) refreshCSov(), ...
    'Tooltip','Mito/ER structure overlay (magenta) on both the site view and the whole-cell panel — on by default so you can judge mito vs non-mito.');
uibutton(resCtl,'Text','Structure…','ButtonPushedFcn',@(s,e) onCSpickOverlay());
uibutton(resCtl,'Text','Toggle mito','ButtonPushedFcn',@(s,e) onCSToggleMito());
uibutton(resCtl,'Text','✏ Refine…','ButtonPushedFcn',@(s,e) onCSReRefine(), ...
    'Tooltip',['Adjust the selected site''s boundary right here on the density panel (fast, in-place — ' ...
    'recomputes dwell, size, p and which tracks fall inside), or re-run the full freehand refiner.']);
uibutton(resCtl,'Text','🗑 Delete CS','FontColor',[0.7 0.1 0.1], ...
    'Tooltip','Remove the selected contact site from CS_final.mat (if it is not a real site)', ...
    'ButtonPushedFcn',@(s,e) onCSDelete());
chkCSwhole = uicheckbox(resCtl,'Text','whole-cell dens','Value',false, ...
    'Tooltip',['Swap the member-track density for the whole-cell rendered density (rho.tif, all localizations). ' ...
    'The boundary was traced on the member density, so it may sit a few pixels off the whole-cell peak — expected.'], ...
    'ValueChangedFcn',@(s,e) redrawCSsite());
chkCSall = uicheckbox(resCtl,'Text','all tracks','Value',false,'ValueChangedFcn',@(s,e) redrawCSsite());
chkCSspots = uicheckbox(resCtl,'Text','all spots','Value',false, ...
    'Tooltip',['Show EVERY detection in the current frame (tracked + untracked), like the QC / ' ...
    'Curate panels — small grey dots, orange if within a link radius of a member track. Use it to ' ...
    'check whether the site sits in a crowded region or a nearby spot was missed.'], ...
    'ValueChangedFcn',@(s,e) redrawCSsite());
chkCSprobDisp = uicheckbox(resCtl,'Text','prob scale','Value',false, ...
    'Tooltip',['Render the site density as the per-cell PROBABILITY (localizations/bin ÷ cell total, ' ...
    'the paper''s PMF) on a scale SHARED across all cells — so the colours become expression-invariant ' ...
    'and directly comparable cell-to-cell (densest site in the dataset = full scale). Off = per-site ' ...
    'auto-stretch. The contrast slider still applies.'], ...
    'ValueChangedFcn',@(s,e) toggleProbDisp());
densCSg = uigridlayout(resCtl,[1 4],'ColumnWidth',{16,'1x',54,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',3);
uilabel(densCSg,'Text','α','FontSize',10,'Tooltip','Density-background opacity');
sldDensCS = uislider(densCSg,'Limits',[0 1],'Value',1,'MajorTicks',[],'MinorTicks',[], ...
    'Tooltip','Density-background opacity','ValueChangedFcn',@(s,e) setDensAlpha(s.Value));
uilabel(densCSg,'Text','contrast','FontSize',10);
sldDensContrast = uislider(densCSg,'Limits',[0.05 1],'Value',1,'MajorTicks',[],'MinorTicks',[], ...
    'Tooltip',['Contact-site density contrast: clip the turbo colour scale at this fraction of the ' ...
    'SITE peak. 1 = full local range (matches the whole-cell look); drag left to saturate the top so ' ...
    'a faint site stands out. Appearance only — the peak loc/bin + probability in the title are unchanged.'], ...
    'ValueChangedFcn',@(s,e) setDensContrast(s.Value));
lRes = uilabel(resCtl,'Text','Run ContactSites (tab 4); results load here (or press Reload).');

% ===== Tab 7: Dwell & labels (per-track dwell, Fig1c/d, CS labels) =====
tDwell = uitab(tg,'Title','8 · Dwell & labels');
dgl = uigridlayout(tDwell,[2 2],'RowHeight',{'1x',34},'ColumnWidth',{604,'1x'}, ...
    'Padding',[8 8 8 8],'RowSpacing',6,'ColumnSpacing',8);
dwTable = uitable(dgl,'ColumnName',{'track','cell','label','CS id','class','in','out','entry(s)','exit(s)','long s','tot s'}, ...
    'ColumnWidth',{46,34,68,46,100,28,32,68,68,50,44}, ...
    'ColumnEditable',[false false false false true false false true true false false], ...
    'ColumnFormat',{[],[],[],[], {'RESIDENT','ENTERS','EXITS','ENTERS+EXITS','—'}, [],[],'char','char',[],[]}, ...
    'RowName',{},'CellSelectionCallback',@(s,e) onDwellSelect(e),'CellEditCallback',@(s,e) onDwellEdit(e), ...
    'Tooltip',['Dwell events = runs of consecutive localizations of a track inside a refined contact-site ' ...
    'boundary. CS id = the contact-site id(s) the track visits; longest/total s = residence time. ' ...
    'class (for the track''s longest-residence site): RESIDENT = inside its whole observed lifetime; ' ...
    'ENTERS = crosses in; EXITS = crosses out; ENTERS+EXITS = both. #in/#out = number of arrivals/departures; ' ...
    'entry(s)/exit(s) = ALL crossing frames (semicolon list, — if none). ' ...
    'EDITABLE: pick the class from the dropdown, or type entry/exit frames (e.g. 12;78) to override the auto ' ...
    'value — edits are saved to analysis/dwell_overrides.csv and reload with the project. ' ...
    'Tracks that never enter a contact site have no dwell and are shown only with "show all tracks".']);
dwTable.Layout.Row=1; dwTable.Layout.Column=1;
dwCM = uicontextmenu(fig);   % right-click a track row -> drop it from its contact site(s)
uimenu(dwCM,'Text','✂ Remove this track from its contact site(s)','MenuSelectedFcn',@(s,e) onDwellRemoveTrack());
dwTable.ContextMenu = dwCM;
dwRight = uigridlayout(dgl,[2 3],'RowHeight',{'1x','1.1x'},'ColumnWidth',{'1x','1x','1x'}, ...
    'Padding',[0 0 0 0],'RowSpacing',6,'ColumnSpacing',6);
dwRight.Layout.Row=1; dwRight.Layout.Column=2;
axDwDist = uiaxes(dwRight); axDwDist.Layout.Row=1; axDwDist.Layout.Column=[1 2]; box(axDwDist,'on'); axDwDist.FontSize=9;
% whole-cell overview (tall, right column) — the selected track's site in context
axDwCell = uiaxes(dwRight); axDwCell.Layout.Row=[1 2]; axDwCell.Layout.Column=3; box(axDwCell,'on'); axDwCell.FontSize=8;
axDwCell.YDir='reverse'; axDwCell.Interactions=[zoomInteraction panInteraction]; axtoolbar(axDwCell,{'zoomin','zoomout','pan','restoreview'});
axDwSpace = uiaxes(dwRight); axDwSpace.Layout.Row=2; axDwSpace.Layout.Column=1; box(axDwSpace,'on'); axDwSpace.FontSize=8;
axDwSpace.YDir='reverse';   % match the CS Results site view so density/boundary/track register identically
axDwTrace = uiaxes(dwRight); axDwTrace.Layout.Row=2; axDwTrace.Layout.Column=2; box(axDwTrace,'on'); axDwTrace.FontSize=8;
disableDefaultInteractivity(axDwDist); disableDefaultInteractivity(axDwSpace); disableDefaultInteractivity(axDwTrace);
dwCtl = uigridlayout(dgl,[1 12],'ColumnWidth',{84,58,58,64,110,120,74,140,88,104,208,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
dwCtl.Layout.Row=2; dwCtl.Layout.Column=[1 2];
uibutton(dwCtl,'Text','Compute','FontWeight','bold','ButtonPushedFcn',@(s,e) loadDwell());
uibutton(dwCtl,'Text','Load…','ButtonPushedFcn',@(s,e) loadIntoTab('dwell'), ...
    'Tooltip','Load a CS_final.mat from another project into the Dwell tab (points the analysis folder at its location)');
uibutton(dwCtl,'Text','▶ Play','ButtonPushedFcn',@(s,e) onDwellPlay());
uibutton(dwCtl,'Text','⏸ Pause','ButtonPushedFcn',@(s,e) stopDwellPlay());
chkDwAll = uicheckbox(dwCtl,'Text','show all tracks','Value',false,'ValueChangedFcn',@(s,e) fillDwellTable());
chkDwCenter = uicheckbox(dwCtl,'Text','center on boundary','Value',false, ...
    'Tooltip','Measure distance from the refined-boundary centroid instead of the CS reference centre', ...
    'ValueChangedFcn',@(s,e) redrawDwellStatic());
chkDwMito = uicheckbox(dwCtl,'Text','mito','Value',true, ...
    'Tooltip','Overlay the cell''s mito max-int on the whole-cell panel', ...
    'ValueChangedFcn',@(s,e) redrawDwellStatic());
densDwg = uigridlayout(dwCtl,[1 2],'ColumnWidth',{40,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',3);
uilabel(densDwg,'Text','dens α','FontSize',10);
sldDensDw = uislider(densDwg,'Limits',[0 1],'Value',1,'MajorTicks',[],'MinorTicks',[], ...
    'Tooltip','Density-background opacity','ValueChangedFcn',@(s,e) setDensAlpha(s.Value));
uibutton(dwCtl,'Text','Trace grid…','ButtonPushedFcn',@(s,e) dwellTraceGrid());
uibutton(dwCtl,'Text','Export CSV…','ButtonPushedFcn',@(s,e) exportDwellCSV());
% per-timestep diffusion coefficient controls: window (steps) + localization precision (nm)
dwDc = uigridlayout(dwCtl,[1 4],'ColumnWidth',{40,'1x',40,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',3);
uilabel(dwDc,'Text','D win','FontSize',10);
spDwin = uispinner(dwDc,'Limits',[1 50],'Value',dwDwin,'Step',1,'RoundFractionalValues','on','FontSize',10,'ValueChangedFcn',@(s,e) onDwellDparam());
uilabel(dwDc,'Text','σ nm','FontSize',10);
spSig  = uispinner(dwDc,'Limits',[0 200],'Value',dwSigNm,'Step',5,'FontSize',10,'ValueChangedFcn',@(s,e) onDwellDparam());
lDwell = uilabel(dwCtl,'Text',['Dwell = time a track stays continuously INSIDE a refined CS boundary ' ...
    '(consecutive localizations × frame time); only contact-site residences count. Click a track to inspect.']);

% ===== Tab 9: Compare conditions (cross-condition roll-up of dwell / k_out / mito) =====
tCmp = uitab(tg,'Title','9 · Compare');
cgl = uigridlayout(tCmp,[2 2],'RowHeight',{'1x',34},'ColumnWidth',{440,'1x'}, ...
    'Padding',[8 8 8 8],'RowSpacing',6,'ColumnSpacing',8);
cmpTable = uitable(cgl,'ColumnName',{'group','n','#CS/rep','mito frac','CC frac','dwell s','k_out /s'}, ...
    'ColumnWidth',{120,34,64,60,56,60,64},'RowName',{}, ...
    'Tooltip',['Per-group summary — each metric is mean ± s.e.m. across the replicate unit. ' ...
    'Group by CONDITION: replicate = cell (n = cells; #CS/rep = contact sites per cell). ' ...
    'Group by MITO vs non-mito: replicate = contact site (n = CS; #CS/rep = 1). ' ...
    'mito frac = fraction mitochondrial; CC frac = fraction of in-CS tracks ChrisC-associated; ' ...
    'dwell = median residence time (s); k_out = escape rate = events / total residence.']);
cmpTable.Layout.Row=1; cmpTable.Layout.Column=1;
cmpRight = uigridlayout(cgl,[2 1],'RowHeight',{'1x','1x'},'Padding',[0 0 0 0],'RowSpacing',6);
cmpRight.Layout.Row=1; cmpRight.Layout.Column=2;
axCmpMain = uiaxes(cmpRight); axCmpMain.Layout.Row=1; box(axCmpMain,'on'); axCmpMain.FontSize=9;
axCmpDist = uiaxes(cmpRight); axCmpDist.Layout.Row=2; box(axCmpDist,'on'); axCmpDist.FontSize=9;
disableDefaultInteractivity(axCmpMain); disableDefaultInteractivity(axCmpDist);
cmpCtl = uigridlayout(cgl,[1 6],'ColumnWidth',{84,66,168,186,92,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',6);
cmpCtl.Layout.Row=2; cmpCtl.Layout.Column=[1 2];
uibutton(cmpCtl,'Text','Compute','FontWeight','bold','ButtonPushedFcn',@(s,e) computeComparison());
uibutton(cmpCtl,'Text','Load…','ButtonPushedFcn',@(s,e) loadIntoTab('compare'), ...
    'Tooltip','Load a CS_final.mat from another project and compute the comparison on it');
cmpGroupBy = uidropdown(cmpCtl,'Items',{'Group: condition','Group: mito vs non-mito'}, ...
    'ItemsData',{'condition','mito'},'Value','condition', ...
    'Tooltip',['Compare across experimental conditions (replicate = cell, from the Experiment manifest) ' ...
    'OR mito vs non-mito contact sites (replicate = contact site). Use "mito vs non-mito" when you have ' ...
    'no conditions assigned — it always has two groups, so Compute always shows a comparison.'], ...
    'ValueChangedFcn',@(s,e) computeComparison());
cmpMetric = uidropdown(cmpCtl,'Items',{'Dwell time (median s)','k_out (/s)','mito fraction of CS', ...
    'CC-associated fraction','# CS per cell','# tracks per CS','CS area (um^2)', ...
    'CS perimeter (um)','CS length (um)','CS width (um)','CS aspect (L/W)'}, ...
    'Value','Dwell time (median s)','ValueChangedFcn',@(s,e) drawComparison());
uibutton(cmpCtl,'Text','Export CSV…','ButtonPushedFcn',@(s,e) exportComparisonCSV());
lCmp = uilabel(cmpCtl,'Text','Pick a group-by, then Compute. Mito vs non-mito needs no manifest.');

% ---------------- Status + Log ---------------------------------------------
pLog = uipanel(gl,'Title','Status & Log'); pLog.Layout.Row = 3;
lgl = uigridlayout(pLog,[3 1],'RowHeight',{22,18,'1x'},'Padding',[8 6 8 6],'RowSpacing',4);
% per-tab progress lamps: green = stage output on disk, amber = partial, grey = pending
lampNums  = {'1','2','3','4','4b','5','6','7','8','9'};
lampNames = {'Calibration','Experiment','Curate','Build','Import QC','Run','Picker','CS Results','Dwell','Compare'};
nLamp = numel(lampNums); cw = cell(1,2*nLamp+1);
for i=1:nLamp, cw{2*i-1}=13; cw{2*i}=20; end, cw{end}='1x';
lampRow = uigridlayout(lgl,[1 2*nLamp+1],'ColumnWidth',cw,'Padding',[0 0 0 0],'ColumnSpacing',2);
tabLamps = gobjects(1,nLamp);
for i=1:nLamp
    tabLamps(i) = uilamp(lampRow,'Color',GREY,'Tooltip',lampNames{i});
    uilabel(lampRow,'Text',lampNums{i},'FontSize',9,'Tooltip',lampNames{i});
end
lProg = uilabel(lampRow,'Text','','FontWeight','bold','FontColor',[0.2 0.5 0.3]);
% persistent scale/calibration readout — visible on EVERY tab (this panel sits below
% the tab group), so the pixel size etc. is always in view wherever you're working.
lblScale = uilabel(lgl,'Text','scale: —','FontColor',[0.45 0.55 0.75],'FontSize',11);
logEntries = {};                   % {HH:mm:ss, level, text} rows for the rich activity log
htmlLog = uihtml(lgl);             % styled, timestamped, severity-coloured log (replaces the plain textarea)

refreshLamps(); refreshScale();
say('Ready — pick a project folder to begin.');

% ===========================================================================
% CALLBACKS  (nested — share handles + S)
% ===========================================================================
    function say(varargin)
        m = sprintf(varargin{:});
        logLine(autoLevel(m), m);
    end
    function logLine(level, msg)
        if ~isvalid(fig), fprintf('%s\n', msg); return; end
        try, ts = char(datetime('now','Format','HH:mm:ss')); catch, ts = ''; end
        logEntries(end+1,:) = {ts, level, msg}; %#ok<AGROW>
        if size(logEntries,1) > 300, logEntries = logEntries(end-299:end,:); end
        renderLog(); drawnow;
    end
    function lv = autoLevel(m)          % colour the log by message content (all say() calls benefit)
        ml = lower(m); lv = 'info';
        if     contains(ml,{'fail','error','could not','cannot','invalid',' no such'}), lv='err';
        elseif contains(ml,{'warning','skipp','omit'}),                                  lv='warn';
        elseif contains(ml,{'done','complete','saved','finished','success','ready','✓'}),lv='ok';
        elseif contains(ml,{'…','running','computing','scanning','loading','processing'}),lv='run';
        end
    end
    function renderLog()
        if isempty(htmlLog) || ~isvalid(htmlLog), return; end
        rows = '';
        for k = 1:size(logEntries,1)
            lv = logEntries{k,2};
            switch lv
                case 'ok',   ic='✓'; case 'warn', ic='⚠';
                case 'err',  ic='✕'; case 'run',  ic='▸'; otherwise, ic='•';
            end
            rows = [rows sprintf('<div class="ln %s"><span class="t">%s</span><span class="i">%s</span><span class="m">%s</span></div>', ...
                lv, logEntries{k,1}, ic, escHtml(logEntries{k,3}))]; %#ok<AGROW>
        end
        htmlLog.HTMLSource = ['<style>html,body{margin:0;height:100%}' ...
            'body{font-family:-apple-system,"Segoe UI",Roboto,Helvetica,Arial,sans-serif;font-size:12px;background:#fbfcfe;color:#2a3543;overflow-y:auto}' ...
            '#log{padding:5px 8px}.ln{display:flex;gap:8px;align-items:baseline;padding:2px 5px;border-radius:4px;line-height:1.45}' ...
            '.ln+.ln{margin-top:1px}.t{color:#93a1b0;font-family:ui-monospace,Menlo,Consolas,monospace;font-size:11px;flex:none}' ...
            '.i{flex:none;width:1.15em;text-align:center}.m{flex:1;white-space:pre-wrap;word-break:break-word}' ...
            '.info .i{color:#9aa7b5}.ok{background:#f0faf4}.ok .i{color:#1f9d55}.ok .m{color:#166b3c}' ...
            '.warn{background:#fdf6e8}.warn .i{color:#bf831a}.warn .m{color:#875812}' ...
            '.err{background:#fdedef}.err .i{color:#c0392b}.err .m{color:#8a2620;font-weight:600}' ...
            '.run .i{color:#2b6cb0}.run .m{color:#22507e}</style>' ...
            '<div id="log">' rows '</div><script>window.scrollTo(0,1e9);</script>'];
    end
    function s = escHtml(s)
        s = strrep(s,'&','&amp;'); s = strrep(s,'<','&lt;'); s = strrep(s,'>','&gt;');
    end

    function onBrowseProject(~,~)
        d = uigetdir(pwd,'Choose project folder');
        if isequal(d,0), return; end
        S.projectDir = d; eProj.Value = d;
        say('project = %s',d); refreshLamps(); refreshScale();
        loadExistingCalib();
        onExpLoad();          % restore the Experiment tracks folder from the manifest FIRST...
        embedCurate();        % ...so Curate auto-loads from it
    end

    function onLoadAnalysis(~,~)     % pick a project OR analysis folder and refresh EVERY tab (resume work)
        start = S.projectDir; if isempty(start)||~isfolder(start), start=pwd; end
        d = uigetdir(start,'Load a project or analysis folder to continue');
        if isequal(d,0), return; end
        [proj, sub] = resolveProjectFromPick(d);   % handles picking the analysis folder itself (no analysis/analysis)
        S.projectDir = proj; eProj.Value = proj;
        if isgraphics(eAnalysis), eAnalysis.Value = sub; end
        say('Loading: project = %s   (analysis subdir = "%s") …', proj, sub);
        refreshLamps(); refreshScale();
        try, loadExistingCalib(); catch, end
        try, onExpLoad(); catch, end       % restore Experiment tracks folder + conditions
        try, embedCurate(); catch, end     % Curate auto-loads from the tracks folder
        refreshAllAnalysis();
    end

    function [proj, sub] = resolveProjectFromPick(d)
        % Map a picked folder to (projectDir, analysisSubdir) so getAnalysisDir() lands on the
        % REAL analysis folder — whether the user picked the project root OR the analysis folder
        % itself. Prevents the analysis/analysis double-nest.
        proj = d; sub = valOr(eAnalysis,'analysis');
        isAna = exist(fullfile(d,'CS_final.mat'),'file')==2 || isfolder(fullfile(d,'Densities')) || ...
                exist(fullfile(d,'TrackStruct.mat'),'file')==2 || exist(fullfile(d,'Tracks_final.mat'),'file')==2 || ...
                ~isempty(dir(fullfile(d,'Density_*.tif'))) || isfolder(fullfile(d,'CSdata'));
        if isAna
            [proj, sub] = fileparts(d);            % picked the analysis folder -> its parent is the project
            if isempty(sub), sub='analysis'; end
        elseif isfolder(fullfile(d,'analysis'))
            proj = d; sub = 'analysis';            % picked the project root that contains analysis/
        end
    end

    function refreshAllAnalysis()   % re-populate CS Results / Dwell / Compare from the current project
        if isempty(S.projectDir) || ~isfolder(S.projectDir)
            say('Load a project folder first (Browse… or Load analysis…).'); return;
        end
        ana=getAnalysisDir(); csf=fullfile(ana,'CS_final.mat');
        if exist(csf,'file')~=2
            say('No CS_final.mat in %s — run ContactSites (tab 5) or load a project that has it.', ana); return;
        end
        try, loadCSresults();     catch ME, say('CS Results reload failed: %s', ME.message); end
        try, loadDwell();         catch ME, say('Dwell reload failed: %s', ME.message); end
        try, computeComparison(); catch ME, say('Compare reload failed: %s', ME.message); end
        say('Analysis refreshed from %s — CS Results, Dwell and Compare are up to date.', ana);
    end

    function loadIntoTab(kind)      % per-tab "Load…": pick a CS_final.mat and refresh just that tab
        start = S.projectDir; if isempty(start)||~isfolder(start), start=pwd; end
        [fn,pth]=uigetfile({'CS_final.mat','CS_final.mat';'*.mat','MAT-files'}, 'Load a CS_final.mat to continue', start);
        if isequal(fn,0), return; end
        ana = fileparts(fullfile(pth,'x'));   % analysis folder (trailing sep stripped)
        [proj, sub] = fileparts(ana);         % project dir + analysis-subdir name
        S.projectDir = proj; eProj.Value = proj;
        if isgraphics(eAnalysis) && ~isempty(sub), eAnalysis.Value = sub; end
        refreshLamps(); refreshScale();
        say('Loaded %s from %s', fn, ana);
        switch kind
            case 'cs',      loadCSresults();
            case 'dwell',   loadDwell();
            case 'compare', computeComparison();
        end
    end

    % ---------------- Experiment tab (multi-condition ingest) ----------------
    function onExpPick(kind)
        d = uigetdir(pwd, ['Pick the ' kind ' folder']);
        if isequal(d,0), return; end
        switch kind
            case 'tracks'
                if isgraphics(eExTracks), eExTracks.Value=d; end
                try, embedCurate(); catch, end      % Curate auto-loads from the new tracks folder
            case 'mito', if isgraphics(eExMito), eExMito.Value=d; end
            case 'er',   if isgraphics(eExEr),   eExEr.Value=d; end
        end
    end

    function onExpScan()
        td=''; md=''; ed='';
        if isgraphics(eExTracks), td=eExTracks.Value; end
        if isgraphics(eExMito),   md=eExMito.Value; end
        if isgraphics(eExEr),     ed=eExEr.Value; end
        if isempty(td) || ~isfolder(td), exptStatus.Text='Pick a valid tracks folder first.'; return; end
        mpat=''; epat=''; pstrip='';
        if isgraphics(eExMitoPat), mpat=strtrim(eExMitoPat.Value); end
        if isgraphics(eExErPat),   epat=strtrim(eExErPat.Value); end
        if isgraphics(eExPrefix),  pstrip=eExPrefix.Value; end
        try, exptCells = scan_experiment(td, md, ed, mpat, epat, pstrip);
        catch ME, exptStatus.Text=['Scan failed: ' ME.message]; return; end
        if ~isempty(exptCells), [exptCells.work] = deal(true); [exptCells.trackstruct] = deal('—'); end   % defaults: all ticked, untagged
        exptSelRows = []; fillExpTable(); setWorkSelPending();   % new cell set -> nothing applied yet
        nMiss=0; nAmb=0;
        for k=1:numel(exptCells)
            if exptCells(k).mitoN==0 || exptCells(k).erN==0, nMiss=nMiss+1; end
            if exptCells(k).mitoN>1  || exptCells(k).erN>1,  nAmb=nAmb+1;  end
        end
        exptStatus.Text = sprintf(['%d cells · %d missing a file · %d ambiguous (red cells). ' ...
            'Type a condition, select rows, "Assign"; or Import mapping; then Save manifest.'], numel(exptCells), nMiss, nAmb);
    end

    function fillExpTable()
        if isempty(exptTable) || ~isgraphics(exptTable), return; end
        n = numel(exptCells); D = cell(n,8);
        for k=1:n
            c = exptCells(k);
            wk = true; if isfield(c,'work') && ~isempty(c.work), wk = logical(c.work); end
            ts = '—'; if isfield(c,'trackstruct') && ~isempty(c.trackstruct), ts = c.trackstruct; end
            D(k,:) = {wk, c.condition, c.name, tern(~isempty(c.tracks),'✓','MISSING'), ...
                      expStat(c.mito,c.mitoN), expStat(c.er,c.erN), cellStatus(c.name), ts};
        end
        exptTable.Data = D;
        try removeStyle(exptTable); catch, end            % clear old red flags
        red = uistyle('BackgroundColor',[1 0.85 0.85]);
        grn = uistyle('BackgroundColor',[0.85 0.96 0.87]);
        for k=1:n
            c = exptCells(k);
            if isempty(c.tracks), try addStyle(exptTable,red,'cell',[k 4]); catch, end, end
            if c.mitoN~=1,        try addStyle(exptTable,red,'cell',[k 5]); catch, end, end
            if c.erN~=1,          try addStyle(exptTable,red,'cell',[k 6]); catch, end, end
            if startsWith(D{k,7},'✓'), try addStyle(exptTable,grn,'cell',[k 7]); catch, end, end   % refined = green
        end
    end

    function st = cellStatus(name)   % per-cell pipeline progress read from the analysis folder
        st='—'; ana=getAnalysisDir();
        if isempty(name) || ~isfolder(ana), return; end
        has = @(sub,pat) isfolder(fullfile(ana,sub)) && ~isempty(dir(fullfile(ana,sub,pat)));
        if has('CSdata',['*' name '*_CSdata.mat']),                    st='✓ refined'; return; end
        if has('csIDs',['*' name '*']) || ~isempty(dir(fullfile(ana,['*' name '*CSsites*']))), st='picked'; return; end
        if has('Densities',['*' name '*rho.tif']) || ~isempty(dir(fullfile(ana,['Density_*' name '*.tif']))), st='density'; return; end
    end

    function s = expStat(p, nMatch)
        if nMatch==0, s='MISSING';
        elseif nMatch>1, [~,nm,ex]=fileparts(p); s=sprintf('AMBIG ×%d: %s', nMatch, [nm ex]);
        else, [~,nm,ex]=fileparts(p); s=[nm ex]; end
    end

    function onExpSelect(e)
        if isempty(e.Indices), exptSelRows=[]; return; end
        exptSelRows = unique(e.Indices(:,1));
    end

    function tagTrackStruct(name, builtFiles)   % record which TrackStruct each built cell went into
        if isempty(exptCells) || isempty(builtFiles), return; end
        for k=1:numel(exptCells)
            nm = exptCells(k).name;
            if any(cellfun(@(f) ~isempty(f) && ~isempty(nm) && (strcmpi(f,nm)||contains(f,nm)||contains(nm,f)), builtFiles))
                exptCells(k).trackstruct = name;
            end
        end
        try, fillExpTable(); catch, end
    end

    function inc = workSelectedFiles()   % Experiment "work" ticks -> selected cell names ({}=all, no filter)
        inc = {};
        if isempty(exptCells) || ~isfield(exptCells,'work'), return; end
        wmask = arrayfun(@(c) ~isfield(c,'work') || isempty(c.work) || logical(c.work), exptCells);
        if ~all(wmask), inc = {exptCells(wmask).name}; end
    end

    function onApplyWorkSel()   % confirm the session selection: filter Curate (and downstream) to the ticked cells
        if isempty(exptCells), exptStatus.Text='Scan first, then tick the cells to work on.'; return; end
        inc = workSelectedFiles(); nAll = numel(exptCells); nSel = tern(isempty(inc), nAll, numel(inc));
        embedCurate();     % re-embed Curate filtered to the selection (density/picker already honor it at run time)
        try, fillExpTable(); catch, end
        if isempty(inc)
            exptStatus.Text = sprintf('Working on ALL %d cells this session. Untick rows to focus, then click again.', nAll);
        else
            shown = strjoin(inc(1:min(numel(inc),6)), ', ');
            exptStatus.Text = sprintf('Session set to %d of %d cells — Curate & the picker now show only these: %s%s', ...
                nSel, nAll, shown, tern(numel(inc)>6,' …',''));
        end
        setWorkSelApplied(nSel, nAll);   % turn the button GREEN so it is clear the selection was applied
        say('Session selection applied: %d of %d cell(s).', nSel, nAll);
    end

    function setWorkSelApplied(nSel, nAll)   % GREEN "applied & current" state
        if isempty(bWorkSel) || ~isgraphics(bWorkSel), return; end
        bWorkSel.BackgroundColor = [0.18 0.55 0.30];
        bWorkSel.Text = sprintf('✓ Working on %d/%d', nSel, nAll);
    end

    function setWorkSelPending()   % BLUE "changes not yet applied" state (reset after a tick is edited)
        if isempty(bWorkSel) || ~isgraphics(bWorkSel), return; end
        bWorkSel.BackgroundColor = [0.18 0.45 0.70];
        bWorkSel.Text = '✓ Work on ticked';
    end

    function onTabChanged(e)   % keep the per-tab lamps + Experiment status current on every tab switch
        try, refreshLamps(); catch, end
        try
            if ~isempty(tExp) && isgraphics(tExp) && isequal(e.NewValue,tExp) && ~isempty(exptCells)
                fillExpTable();
            end
        catch, end
        try, if ~isempty(tRun) && isgraphics(tRun) && isequal(e.NewValue,tRun), refreshTsFiles(); end, catch, end
        % rehydrate an invalidated cache on entry so no tab shows stale membership after an edit
        try
            ana=getAnalysisDir(); haveFinal = ~isempty(S.projectDir) && isfolder(S.projectDir) && exist(fullfile(ana,'CS_final.mat'),'file')==2;
            if haveFinal
                if ~isempty(tRes)   && isgraphics(tRes)   && isequal(e.NewValue,tRes)   && isempty(csData),    loadCSresults();     end
                if ~isempty(tDwell) && isgraphics(tDwell) && isequal(e.NewValue,tDwell) && isempty(dwellData), loadDwell();         end
                if ~isempty(tCmp)   && isgraphics(tCmp)   && isequal(e.NewValue,tCmp)   && isempty(cmpData),   computeComparison(); end
            end
        catch, end
        try, updateLoadedInfo(); catch, end
    end

    function items = trackStructCandidates()   % TrackStruct-like *.mat in the analysis folder (named builds + TrackStruct/Tracks)
        items = {}; ana = getAnalysisDir(); if ~isfolder(ana), return; end
        d = dir(fullfile(ana,'*.mat'));
        excl = {'cs_calib','CS_final','Tracks_final','cell_index','project','_CSdata','_Part'};
        for k=1:numel(d)
            nm = d(k).name;
            if startsWith(nm,'Density_'), continue; end
            if any(cellfun(@(x) contains(nm,x), excl)), continue; end
            items{end+1} = nm; %#ok<AGROW>
        end
    end

    function refreshTsFiles()   % populate the Run tab's TrackStruct picker from disk (keep the current choice if still there)
        if isempty(ddTsFile) || ~isgraphics(ddTsFile), return; end
        items = trackStructCandidates(); if isempty(items), items = {'TrackStruct.mat'}; end
        prev = ddTsFile.Value; ddTsFile.Items = items;
        if any(strcmp(items,prev)),                    ddTsFile.Value = prev;
        elseif any(strcmp(items,'TrackStruct.mat')),   ddTsFile.Value = 'TrackStruct.mat';
        else,                                          ddTsFile.Value = items{1}; end
    end

    function s = stageDescText(name)   % one-line role of each pipeline stage (Run tab help)
        switch name
            case 'density',    s='build each cell''s 30 nm localization-density map from its tracks — the base image every later stage measures on.';
            case 'locdens',    s='render the per-cell density figures (rho.tif) used as the picker / refiner background.';
            case 'quickplot',  s='quick per-cell track + density overview images (visual QC).';
            case 'csid',       s='PICK contact sites — the density picker opens in the Contact Sites tab (auto-detect peaks + manual add). NEEDS YOUR INPUT.';
            case 'mapper',     s='assign each picked point its member tracks (the ±5.4 µm box) → per-cell CSdata.';
            case 'part2',      s='assemble the per-cell contact-site records from the mapped tracks.';
            case 'snaprename', s='snapshot + rename the intermediate files into the canonical layout.';
            case 'refiner',    s='REFINE each site''s boundary — the freehand refiner opens in the Contact Sites tab. NEEDS YOUR INPUT.';
            case 'ensemble',   s='combine every cell''s refined sites into one set.';
            case 'builder',    s='build CS_final.mat (dwell, size, p for every site) — this is what Tabs 7 & 8 read. The main result.';
            case 'accum',      s='write the Excel table + a QC image per contact site (slow; optional — untick the checkbox to skip).';
            otherwise,         s='';
        end
    end

    function updateStageDesc()   % refresh the Run-tab stage help for the current "start stage"
        if isempty(lStageDesc) || ~isgraphics(lStageDesc) || isempty(ddStart) || ~isgraphics(ddStart), return; end
        nm = ddStart.Value;
        lStageDesc.Text = { sprintf('Start stage "%s" — %s', nm, stageDescText(nm)); ...
            'Running from here assumes every EARLIER stage already finished for this dataset (use it to RESUME, not for a fresh run).'; ...
            'Order:  density → locdens → quickplot → csid (pick) → mapper → part2 → snaprename → refiner (refine) → ensemble → builder (CS_final.mat) → accum (Excel).' };
    end

    function onExpEdit(e)   % edit the work checkbox (col 1) or type a condition (col 2)
        if isempty(e.Indices), return; end
        r = e.Indices(1); if r<1 || r>numel(exptCells), return; end
        switch e.Indices(2)
            case 1, exptCells(r).work = logical(e.NewData); setWorkSelPending();   % ticks changed -> selection no longer applied
            case 2, exptCells(r).condition = strtrim(char(string(e.NewData)));     % condition label
        end
    end

    function onExpAssign()
        if isempty(exptCells), return; end
        cond=''; if isgraphics(eExCond), cond=strtrim(eExCond.Value); end
        if isempty(cond), exptStatus.Text='Type a condition name in the box first, then select rows and Assign.'; return; end
        if isempty(exptSelRows), exptStatus.Text='Select one or more rows in the table first (click / shift-click).'; return; end
        rr = exptSelRows(exptSelRows>=1 & exptSelRows<=numel(exptCells));
        for r=rr(:)', exptCells(r).condition = cond; end
        fillExpTable();
        exptStatus.Text = sprintf('Assigned "%s" to %d cell(s).', cond, numel(rr));
    end

    function onExpImportMap()
        if isempty(exptCells), exptStatus.Text='Scan first, then Import mapping.'; return; end
        [fn,pth]=uigetfile({'*.csv;*.txt','name,condition mapping'},'Pick a name,condition mapping file');
        if isequal(fn,0), return; end
        try, T = readcell(fullfile(pth,fn));
        catch ME, exptStatus.Text=['Import failed: ' ME.message]; return; end
        m = containers.Map('KeyType','char','ValueType','char');
        for i=1:size(T,1)
            nm = strtrim(char(string(T{i,1}))); cd='';
            if size(T,2)>=2, cd = strtrim(char(string(T{i,2}))); end
            if isempty(nm) || strcmpi(nm,'name'), continue; end      % skip blanks / a header row
            m(nm) = cd;
        end
        nSet=0; ky=m.keys;
        for k=1:numel(exptCells)
            nm = exptCells(k).name;
            if isKey(m,nm), exptCells(k).condition=m(nm); nSet=nSet+1;
            else                                                     % fall back to prefix/contains match
                for j=1:numel(ky)
                    if startsWith(nm,ky{j}) || contains(nm,ky{j}), exptCells(k).condition=m(ky{j}); nSet=nSet+1; break; end
                end
            end
        end
        fillExpTable();
        exptStatus.Text = sprintf('Imported mapping: set condition on %d/%d cells.', nSet, numel(exptCells));
    end

    function onExpSave()
        if isempty(S.projectDir) || ~isfolder(S.projectDir), exptStatus.Text='Pick a project folder (top bar) first.'; return; end
        if isempty(exptCells), exptStatus.Text='Nothing to save — Scan first.'; return; end
        expt = struct('tracksDir','','mitoDir','','erDir','','cells',{exptCells},'conditions',{{}}); %#ok<NASGU>
        if isgraphics(eExTracks), expt.tracksDir=eExTracks.Value; end
        if isgraphics(eExMito),   expt.mitoDir=eExMito.Value; end
        if isgraphics(eExEr),     expt.erDir=eExEr.Value; end
        if isgraphics(eExMitoPat),expt.mitoPat=eExMitoPat.Value; end
        if isgraphics(eExErPat),  expt.erPat=eExErPat.Value; end
        if isgraphics(eExPrefix), expt.prefixStrip=eExPrefix.Value; end
        conds = unique({exptCells.condition}); conds = conds(~cellfun(@isempty,conds));
        expt.conditions = conds;
        f = fullfile(S.projectDir,'project.mat');
        try, save(f,'expt'); catch ME, exptStatus.Text=['Save failed: ' ME.message]; return; end
        nNo = sum(cellfun(@isempty,{exptCells.condition}));
        say('Saved experiment manifest -> %s (%d cells, %d conditions)', f, numel(exptCells), numel(conds));
        exptStatus.Text = sprintf('Saved project.mat: %d cells, %d conditions [%s]%s.', numel(exptCells), numel(conds), ...
            strjoin(conds,', '), tern(nNo>0, sprintf('  —  %d cells have NO condition yet',nNo), ''));
    end

    function onExpLoad()
        if isempty(S.projectDir), return; end
        f = fullfile(S.projectDir,'project.mat');
        if exist(f,'file')~=2, return; end
        try
            L = load(f); if ~isfield(L,'expt'), return; end; ex = L.expt;
            if isfield(ex,'tracksDir') && isgraphics(eExTracks), eExTracks.Value=ex.tracksDir; end
            if isfield(ex,'mitoDir')   && isgraphics(eExMito),   eExMito.Value=ex.mitoDir; end
            if isfield(ex,'erDir')     && isgraphics(eExEr),     eExEr.Value=ex.erDir; end
            if isfield(ex,'mitoPat')    && isgraphics(eExMitoPat), eExMitoPat.Value=ex.mitoPat; end
            if isfield(ex,'erPat')      && isgraphics(eExErPat),   eExErPat.Value=ex.erPat; end
            if isfield(ex,'prefixStrip')&& isgraphics(eExPrefix),  eExPrefix.Value=ex.prefixStrip; end
            if isfield(ex,'cells'), exptCells=ex.cells; fillExpTable(); setWorkSelPending();   % loaded set -> nothing applied yet this session
                if isgraphics(exptStatus), exptStatus.Text=sprintf('Loaded saved manifest: %d cells.', numel(exptCells)); end
            end
        catch, end
    end

    function onPick(kind,ef)
        [fn,pth] = uigetfile({'*.tif;*.tiff','TIFF images'},['Pick ' kind ' image']);
        if isequal(fn,0), return; end
        S.(kind) = fullfile(pth,fn); ef.Value = S.(kind);
        say('%s image = %s',kind,fn);
    end

    % ---- Calibration ----
    function onCalScale(~,~)
        px = str2double(ePix.Value); np = str2double(eNpx.Value);
        if isfinite(px)&&px>0 && isfinite(np)&&np>0, eFov.Value = num2str(px*np); end
    end

    function onCalibAuto(~,~)
        if exist('read_calibration','file')~=2
            lCalStatus.Text = 'read_calibration.m not on path (expected in drivers/).'; return;
        end
        img = S.mito; if isempty(img)||exist(img,'file')~=2, img = firstTif(fullfile(getAnalysisDir(),'Mito'), fullfile(getAnalysisDir(),'MaxInt'), getAnalysisDir()); end
        xml = firstXml(fullfile(S.projectDir, valOr(eTracks,'tracks')));
        a = [];
        try, a = read_calibration('Image',img,'XML',xml); catch, end
        if isempty(a), lCalStatus.Text = 'Auto-detect: nothing readable. Enter values manually.'; return; end
        if isfinite(a.pixSizeUm), ePix.Value = num2str(a.pixSizeUm); end
        if isfinite(a.nPix),      eNpx.Value = num2str(a.nPix);      end
        if isfinite(a.dt_s),      eDt.Value  = num2str(a.dt_s);      end
        onCalScale();
        miss = {}; if ~isfinite(a.pixSizeUm), miss{end+1}='pixel size'; end
        if ~isfinite(a.dt_s), miss{end+1}='dt'; end
        if isempty(miss), lCalStatus.Text='Auto-detect: filled from metadata — confirm & Save.';
        else, lCalStatus.Text=sprintf('Auto-detect: %s missing — type by hand.',strjoin(miss,' & ')); end
    end

    function onCalibSave(~,~)
        if ~needProject(), return; end
        analysisDir = getAnalysisDir(); if ~isfolder(analysisDir), mkdir(analysisDir); end
        px=str2double(ePix.Value); np=str2double(eNpx.Value);
        fov=str2double(eFov.Value); dt=str2double(eDt.Value); bin=str2double(eBin.Value);
        if ~(isfinite(fov)&&fov>0) && isfinite(px)&&px>0 && isfinite(np)&&np>0, fov=px*np; end
        if ~(isfinite(fov)&&fov>0), lCalStatus.Text='Enter FOV (µm), or pixel size AND image size.'; return; end
        if ~(isfinite(dt)&&dt>0),  lCalStatus.Text='Enter frame interval dt (s).'; return; end
        if ~(isfinite(bin)&&bin>0), bin=30; end
        calib = struct('pixSizeUm',px,'nPix',np,'fovUm',fov,'snapFovUm',fov, ...
                       'dt_s',dt,'binNm',bin,'source','unified-app','savedFrom',analysisDir); %#ok<NASGU>
        try
            save(fullfile(analysisDir,'cs_calib.mat'),'calib');
        catch ME
            lCalStatus.Text = ['Could not save: ' ME.message]; return;
        end
        lCalStatus.Text = sprintf('Saved cs_calib.mat: FOV %.4g µm | dt %.5g s | bin %g nm', fov, dt, bin);
        say('calibration saved -> %s', fullfile(analysisDir,'cs_calib.mat'));
        say('  FOV=%.4g um | pixel=%s um/px | dt=%.5g s | bin=%g nm', fov, num2str(px), dt, bin);
        refreshScale();   % reflect the new calibration in the persistent scale readout
    end

    function loadExistingCalib()
        cf = fullfile(getAnalysisDir(),'cs_calib.mat');
        if exist(cf,'file')~=2, return; end
        try
            L = load(cf);
            if isfield(L,'calib')
                c = L.calib;
                if isfield(c,'pixSizeUm')&&isfinite(c.pixSizeUm), ePix.Value=num2str(c.pixSizeUm); end
                if isfield(c,'nPix')&&isfinite(c.nPix),           eNpx.Value=num2str(c.nPix);      end
                if isfield(c,'fovUm')&&isfinite(c.fovUm),         eFov.Value=num2str(c.fovUm);     end
                if isfield(c,'dt_s')&&isfinite(c.dt_s),           eDt.Value =num2str(c.dt_s);      end
                if isfield(c,'binNm')&&isfinite(c.binNm),         eBin.Value=num2str(c.binNm);     end
                lCalStatus.Text = 'Loaded existing cs_calib.mat for this project.';
            end
        catch
        end
        refreshScale();
    end

    % ---- Curate (embedded track_viewer) ----
    function curPlaceholder(msg)
        delete(tCur.Children);
        g = uigridlayout(tCur,[1 1],'Padding',[16 16 16 16]);
        uilabel(g,'Text',msg,'WordWrap','on');
    end

    % ---- Contact Sites host (cs_identify / cs_refine build their UI here) ----
    function csPlaceholder(msg)
        delete(tCS.Children);
        g = uigridlayout(tCS,[1 1],'Padding',[16 16 16 16]);
        uilabel(g,'Text',msg,'WordWrap','on');
    end

    function csBuildingPanel()   % shown while the frozen post-refine stages build CS_final.mat
        delete(tCS.Children);
        g = uigridlayout(tCS,[2 1],'RowHeight',{44,'1x'},'Padding',[24 24 24 24],'RowSpacing',12);
        uilabel(g,'Text','⏳  Refinement complete — building final results…', ...
            'FontSize',16,'FontWeight','bold','FontColor',[0.16 0.45 0.70]);
        uilabel(g,'Text',['Writing CS_final.mat (dwell metrics + per-site geometry) from your refined ' ...
            'boundaries. MATLAB is single-threaded, so the app may look frozen for up to a minute — ' ...
            'this is normal. The CS Results tab (7) opens by itself when it finishes; you don''t need ' ...
            'to click anything. Watch the Status & Log bar below for the current stage.'], ...
            'WordWrap','on','FontColor',[0.4 0.44 0.5]);
        drawnow;
    end

    function embedCurate()
        if isempty(S.projectDir), return; end
        delete(tCur.Children);
        if exist('track_viewer','file')~=2      % canonical copy is gui/track_viewer.m (on path)
            curPlaceholder('track_viewer.m not found on the path (expected in gui/).'); return;
        end
        tracksDir = tracksSourceDir();   % Experiment tab's folder if set, else project tracks/
        try
            inc = workSelectedFiles();   % Experiment "work" selection ({}=all) -> Curate shows only these cells
            track_viewer(tCur, tracksDir, @cellOverlayPaths, inc);   % embed + auto-load overlay per cell
            say('embedded track curation from %s%s', tracksDir, tern(isempty(inc),'',sprintf(' (%d selected cell(s))',numel(inc))));
        catch ME
            curPlaceholder(['Could not embed track curation: ' ME.message]);
            say('ERROR embedding track_viewer: %s', ME.message);
        end
    end

    % ---- Build / Setup / Run ----
    function onBuild(~,~)
        if ~needProject(), return; end
        tracksDir = tracksSourceDir();   % same source Curate uses (Experiment folder if set)
        if ~isfolder(tracksDir), uialert(fig,['tracks folder not found: ' tracksDir],'Missing'); return; end
        analysisDir = getAnalysisDir(); if ~isfolder(analysisDir), mkdir(analysisDir); end
        haveFilt = ~isempty(dir(fullfile(tracksDir,'*_tracks_filtered.xml')));
        srcTxt = tern(haveFilt,'curated (filtered)','raw run');
        nX = numel(dir(fullfile(tracksDir, tern(haveFilt,'*_tracks_filtered.xml','*_tracks.xml'))));
        say('Build TrackStruct from %s  [%s · %d cell(s)]', tracksDir, srcTxt, nX);
        % progress dialog with per-cell ETA (build_trackstruct calls back per cell)
        dlg = uiprogressdlg(fig,'Title','Build TrackStruct','Message','Starting…','Value',0);
        buildT0 = tic; busy(true);
        try
            Tbuilt = build_trackstruct(tracksDir,'TimeUnit',ddTime.Value,'AttachCSV',true,'Save',true,'Verbose',false, ...
                'IncludeFiles',workSelectedFiles(), ...   % build ONLY the ticked cells (empty = all)
                'ProgressFcn',@(i,n,nm) onBuildProg(dlg,buildT0,i,n,nm));
            outName = tsOutName(); outFull = fullfile(analysisDir,outName);
            src = fullfile(tracksDir,'TrackStruct.mat');
            if isfile(src), movefile(src, outFull); say('-> %s -> %s', outName, analysisDir); end
            try, tagTrackStruct(outName, {Tbuilt.file}); catch, end   % record which TrackStruct each cell went into (Experiment tab)
            % de-blinding key only for the canonical TrackStruct.mat (custom names are combine intermediates)
            if strcmpi(outName,'TrackStruct.mat')
                try, mp = write_cell_index_map(analysisDir, S.projectDir);
                    if ~isempty(mp), say('-> cell_index_map.csv (cellIndex -> file mapping) -> %s', analysisDir); end
                catch MEm, say('cell_index_map skipped: %s', MEm.message); end
            else
                say('Saved as %s — pipeline input is analysis/TrackStruct.mat, so Combine these (or Load one) before running.', outName);
            end
            if isvalid(dlg), close(dlg); end
            say('IMPORT complete  (%s · %d cells · %.0fs).', srcTxt, nX, toc(buildT0));
            try, showImportQC(outFull); tg.SelectedTab = tQC; catch MEqc, say('QC plot skipped: %s',MEqc.message); end
        catch ME
            if isvalid(dlg), close(dlg); end
            say('ERROR: %s',ME.message); uialert(fig,ME.message,'build_trackstruct failed');
        end
        busy(false); refreshLamps(); refreshScale();
    end

    function onCombineTrackstructs()
        % Combine several days' TrackStruct.mat into ONE for a combined final analysis, written
        % to THIS project's analysis dir (so the CS pipeline + comparison run over all days).
        if ~needProject(), return; end
        [fn,pth] = uigetfile({'*.mat','TrackStruct / Tracks .mat'}, ...
            'Select 2+ TrackStruct.mat files to combine (Ctrl/Cmd-click)', 'MultiSelect','on');
        if isequal(fn,0), return; end
        if ischar(fn), fn = {fn}; end
        if numel(fn) < 2, uialert(fig,'Select at least two TrackStruct.mat files to combine.','Combine'); return; end
        files = cellfun(@(f) fullfile(pth,f), fn, 'UniformOutput', false);
        analysisDir = getAnalysisDir(); if ~isfolder(analysisDir), mkdir(analysisDir); end
        out = fullfile(analysisDir,'TrackStruct.mat');
        if isfile(out)
            d = uiconfirm(fig, sprintf(['This overwrites analysis/TrackStruct.mat with the combined set ' ...
                '(%d files). Downstream per-cell outputs (Densities, CSdata, CS_final) are re-generated by ' ...
                'the run, so combine BEFORE running ContactSites. Continue?'], numel(files)), ...
                'Combine TrackStructs', 'Options',{'Combine & overwrite','Cancel'}, ...
                'DefaultOption',2,'CancelOption',2,'Icon','warning');
            if ~strcmp(d,'Combine & overwrite'), return; end
        end
        busy(true);
        try
            [~, prov] = combine_trackstructs(files, out);
            try, writetable(prov, fullfile(analysisDir,'trackstruct_sources.csv')); catch, end
            try, write_cell_index_map(analysisDir, S.projectDir); catch, end
            say('Combined %d TrackStruct file(s) -> %d cells -> %s  (provenance: trackstruct_sources.csv)', ...
                numel(files), height(prov), out);
            try, showImportQC(); tg.SelectedTab = tQC; catch MEqc, say('QC skipped: %s', MEqc.message); end
        catch ME
            say('Combine failed: %s', ME.message); uialert(fig, ME.message, 'Combine failed');
        end
        busy(false); refreshLamps();
    end

    function nm = tsOutName()       % Build "save as" field -> filesystem-safe <name>.mat
        nm = 'TrackStruct';
        if ~isempty(eTsName) && isgraphics(eTsName) && ~isempty(strtrim(eTsName.Value)), nm = strtrim(eTsName.Value); end
        nm = regexprep(nm,'\.mat$','','ignorecase');   % strip a typed extension before sanitising
        nm = regexprep(nm,'[^\w\-]','_'); if isempty(nm), nm='TrackStruct'; end
        nm = [nm '.mat'];
    end

    function onLoadTrackStruct()    % pick an existing TrackStruct.mat and make it this project's analysis input
        if ~needProject(), return; end
        start = getAnalysisDir(); if ~isfolder(start), start = S.projectDir; end
        [fn,pth] = uigetfile({'*.mat','TrackStruct / Tracks .mat'}, 'Load an existing TrackStruct.mat', start);
        if isequal(fn,0), return; end
        ana = getAnalysisDir(); if ~isfolder(ana), mkdir(ana); end
        src = fullfile(pth,fn); dst = fullfile(ana,'TrackStruct.mat');
        try
            L = load(src); if ~isfield(L,'Tracks'), uialert(fig,[fn ' has no ''Tracks'' variable — not a TrackStruct.'],'Load TrackStruct'); return; end
            if ~strcmp(src,dst), copyfile(src, dst); end
            say('Loaded %s -> analysis/TrackStruct.mat  (%d cells).', fn, numel(L.Tracks));
            try, write_cell_index_map(ana, S.projectDir); catch, end
            showImportQC(dst); tg.SelectedTab = tQC; refreshLamps();
        catch ME, say('Load TrackStruct failed: %s', ME.message); uialert(fig, ME.message, 'Load failed');
        end
    end

    function onBuildProg(dlg, t0, i, n, nm)
        if isempty(dlg) || ~isvalid(dlg), return; end
        dlg.Value = max(0,min(1,(i-1)/max(n,1)));       % cells COMPLETED before this one
        [~,b] = fileparts(nm);
        if i>1, eta = toc(t0)/(i-1)*(n-i+1); etaTxt = sprintf('   ·  ~%.0fs left', eta); else, etaTxt=''; end
        dlg.Message = sprintf('[%d/%d]  %s%s', i, n, b, etaTxt);
        drawnow limitrate;
    end

    % ---- Import QC (tracks / centered / MSD+fit / D-dist / CSD, interactive) ----
    function showImportQC(varargin)
        ana = getAnalysisDir();
        if     nargin>=1 && ~isempty(varargin{1}) && isfile(varargin{1}), Lq=load(varargin{1});
        elseif isfile(fullfile(ana,'TrackStruct.mat')), Lq=load(fullfile(ana,'TrackStruct.mat'));
        elseif isfile(fullfile(ana,'Tracks.mat')),      Lq=load(fullfile(ana,'Tracks.mat'));
        else,  lQC.Text='No TrackStruct.mat — Build or Load one first.'; return; end
        if ~isfield(Lq,'Tracks'), lQC.Text='TrackStruct.mat has no ''Tracks''.'; return; end
        qcAllT = Lq.Tracks; T = qcAllT;
        % per-cell list: "All cells" + each cell (with its track count) — click to view one
        names = cell(1,numel(T));
        for i=1:numel(T)
            nT=0; if isfield(T,'lengths'), nT=numel(T(i).lengths); end
            names{i} = sprintf('%d · %s  (%d)', i, T(i).file, nT);
        end
        if ~isempty(qcList) && isgraphics(qcList)
            qcList.Items = [{'▣ All cells'}, names];
            qcList.ItemsData = [{0}, num2cell(1:numel(T))];
            if isempty(qcList.Value) || ~any(cellfun(@(v) isequal(v,qcList.Value), qcList.ItemsData))
                if numel(T)>=1, qcList.Value = 1; else, qcList.Value = 0; end   % default: first cell
            end
        end
        drawQCcell();
    end

    % draw the Import-QC panels for the SELECTED cell (or all cells)
    function f = msdFrac()
        % fraction of finite MSD lags used by fitDeff, from the QC "MSD fit %" spinner (default 0.5)
        f = 0.5;
        if ~isempty(eMsdFrac) && isgraphics(eMsdFrac), f = eMsdFrac.Value/100; end
        f = max(0.05, min(1, f));
    end

    function drawQCcell()
        T = qcAllT; if isempty(T), return; end
        dt = local_dt(); stopQCplay();   % any running playback belongs to the previous selection
        sel = 0; if ~isempty(qcList) && isgraphics(qcList) && ~isempty(qcList.Value), sel = qcList.Value; end
        if sel==0, cellIdxs = 1:numel(T); else, cellIdxs = max(1,min(sel,numel(T))); end
        % auto-match THIS cell's mito max-int (from the Experiment folder + pattern) and
        % keep it as the overlay, so it's shown by default without picking a file each time.
        if numel(cellIdxs)==1
            mp = qcCellMitoPath(T(cellIdxs).file);
            if ~isempty(mp), loadQCmito(mp); else, qcOverlayImg=[]; end
        else
            qcOverlayImg=[];   % 'All cells' has no single mito
        end

        % ---- aggregate across the selected cell(s); build a per-track list (for the
        %      click-to-select interaction) plus per-track Deff from MSD fits.
        msdCols={}; csdCols={}; mapCell=[]; mapCol=[]; Deff=[]; nTrk=0;
        for i=cellIdxs
            if isfield(T,'MSD') && ~isempty(T(i).MSD)
                Mi = T(i).MSD;                                  % [nLag x n]
                for n=1:size(Mi,2)
                    msdCols{end+1}=Mi(:,n);                     %#ok<AGROW>
                    mapCell(end+1)=i; mapCol(end+1)=n;          %#ok<AGROW>
                    Deff(end+1)=fitDeff(Mi(:,n),dt,msdFrac());   %#ok<AGROW>
                end
            end
            if isfield(T,'CSD') && ~isempty(T(i).CSD), csdCols{end+1}=T(i).CSD; end %#ok<AGROW>
            if isfield(T,'lengths'), nTrk=nTrk+numel(T(i).lengths); end
        end

        % ---- MSD panel: per-track curves + ensemble mean + fit; click to select
        cla(axMSD); QCstate = [];
        if ~isempty(msdCols)
            M = padcat_cols(msdCols); lag=(1:size(M,1))'*dt;
            % per-track centroid, aligned with mapCell/mapCol (for click-to-select on Tracks)
            cx = nan(1,numel(mapCell)); cy = cx;
            for k=1:numel(mapCell)
                xk = T(mapCell(k)).matrix(:,mapCol(k),2); yk = T(mapCell(k)).matrix(:,mapCol(k),3);
                cx(k)=mean(xk,'omitnan'); cy(k)=mean(yk,'omitnan');
            end
            QCstate.T=T; QCstate.M=M; QCstate.lag=lag; QCstate.mapCell=mapCell; QCstate.mapCol=mapCol;
            QCstate.Deff=Deff; QCstate.cx=cx; QCstate.cy=cy; QCstate.cellIdxs=cellIdxs;
            QCstate.selK=[]; QCstate.hlTrack=[]; QCstate.hlDeff=[]; QCstate.playIdx=0;
            QCstate.selXY=[]; QCstate.selInt=[]; QCstate.selCi=[]; QCstate.selNi=[];
            plot(axMSD,lag,M,'-','Color',[0.55 0.65 0.85 0.10]); hold(axMSD,'on');
            mMSD = mean(M,2,'omitnan');
            plot(axMSD,lag,mMSD,'-','Color',[0.10 0.30 0.70],'LineWidth',2);
            [De,be,nfFit] = fitDeff(mMSD,dt,msdFrac()); nf = max(2, min(numel(lag), nfFit));   % draw over the fitted lags
            if isfinite(De) && De>0     % re-add the fitted intercept so the line sits on the mean curve
                plot(axMSD,lag(1:nf),4*De*lag(1:nf)+be,'--','Color',[0.85 0.15 0.15],'LineWidth',1.6);
                titStr = sprintf('Per-track MSD + fit (D_{ens}=%.3g µm²/s, first %.0f%% of lags) — click a curve',De,100*msdFrac());
            else
                titStr = 'Per-track MSD + fit (ensemble D unreliable) — click a curve';
            end
            hold(axMSD,'off'); xlabel(axMSD,'lag (s)'); ylabel(axMSD,'MSD (\mum^2)');
            if numel(lag)>1, axMSD.XLim=[0 lag(min(end,20))]; end   % first ~20 lags
            title(axMSD,titStr);
            set(findobj(axMSD,'Type','line'),'HitTest','off');     % clicks reach the axes
            axMSD.ButtonDownFcn = @(s,e) onMSDClick();
        else
            title(axMSD,'Per-track MSD (no MSD data)');
        end

        % ---- Diffusion-coefficient distribution (per-track fits)
        cla(axDeff); Dpos = Deff(isfinite(Deff) & Deff>0); medD = NaN;
        if ~isempty(Dpos)
            medD = median(Dpos);
            histogram(axDeff,Dpos,40,'FaceColor',[0.55 0.30 0.70],'EdgeColor','none');
            xlabel(axDeff,'D (\mum^2/s)'); ylabel(axDeff,'count');
            title(axDeff,sprintf('D distribution (median %.3g)',medD));
        else, title(axDeff,'D distribution (no fits)'); end

        % ---- Tracks (raw) + Centered tracks (time-coloured lines) + structure overlay
        drawTrackPanels();

        % ---- CSD (raw, actual µm — NOT normalized)
        cla(axCSD);
        if ~isempty(csdCols)
            Cr = padcat_cols(csdCols);
            plot(axCSD,(1:size(Cr,1))',Cr,'-','Color',[0.85 0.55 0.15 0.12]);
            xlabel(axCSD,'step #'); ylabel(axCSD,'cumulative displacement (\mum)');
            title(axCSD,sprintf('CSD (µm) — %d tracks',size(Cr,2)));
        else, title(axCSD,'CSD (no data)'); end

        if numel(cellIdxs)==1, scopeTxt=sprintf('cell %d/%d: %s', cellIdxs, numel(T), T(cellIdxs).file);
        else,                  scopeTxt=sprintf('all %d cells', numel(T)); end
        lQC.Text=sprintf('%s  |  %d tracks  |  %d MSD fits  |  median D %.3g µm²/s  |  dt=%.5g s', ...
            scopeTxt,nTrk,numel(Dpos),medD,dt);
    end

    % clicking the MSD plot selects the nearest track curve
    function onMSDClick()
        if isempty(QCstate) || ~isfield(QCstate,'M') || isempty(QCstate.M), return; end
        cp = axMSD.CurrentPoint; xc=cp(1,1); yc=cp(1,2);
        [~,li] = min(abs(QCstate.lag - xc)); li=max(1,min(li,size(QCstate.M,1)));
        d = abs(QCstate.M(li,:) - yc); d(~isfinite(d))=Inf;
        [dmin,k] = min(d);
        if ~isfinite(dmin), return; end
        selectTrack(k);
    end

    % clicking the Tracks panel selects the nearest track (by centroid)
    function onTracksClick()
        if isempty(QCstate) || ~isfield(QCstate,'cx') || isempty(QCstate.cx), return; end
        cp = axTracks.CurrentPoint; xc=cp(1,1); yc=cp(1,2);
        d = hypot(QCstate.cx-xc, QCstate.cy-yc); d(~isfinite(d))=Inf;
        [dmin,k] = min(d);
        if ~isfinite(dmin), return; end
        selectTrack(k);
    end

    % central selection: highlight on Tracks, mark D on the distribution, show it in axSel
    function selectTrack(k)
        if isempty(QCstate) || ~isfield(QCstate,'mapCell') || k<1 || k>numel(QCstate.mapCell), return; end
        stopQCplay();
        ci = QCstate.mapCell(k); ni = QCstate.mapCol(k); Tt = QCstate.T;
        if ci<1 || ci>numel(Tt) || ~isfield(Tt,'matrix') || isempty(Tt(ci).matrix) ...
                || size(Tt(ci).matrix,3)<3 || ni>size(Tt(ci).matrix,2), return; end
        x = Tt(ci).matrix(:,ni,2); y = Tt(ci).matrix(:,ni,3); fr = Tt(ci).matrix(:,ni,1);
        inten = [];
        if isfield(Tt,'intens') && ~isempty(Tt(ci).intens) && size(Tt(ci).intens,3)>=3 ...
                && ni<=size(Tt(ci).intens,2)
            tint = Tt(ci).intens(:,ni,3); if any(isfinite(tint)), inten = tint; end
        end
        ok = isfinite(x) & isfinite(y); x=x(ok); y=y(ok); fr=fr(ok);
        if ~isempty(inten), inten = inten(ok); end
        QCstate.selK=k; QCstate.selCi=ci; QCstate.selNi=ni;
        QCstate.selXY=[x y]; QCstate.selInt=inten; QCstate.selFrame=fr; QCstate.playIdx=numel(x);

        % highlight the selected track on the Tracks panel (keep the base plot)
        if ~isempty(QCstate.hlTrack) && isgraphics(QCstate.hlTrack), delete(QCstate.hlTrack); end
        if ~isempty(x)
            hold(axTracks,'on');
            QCstate.hlTrack = plot(axTracks,x,y,'-','Color',[1 0.72 0],'LineWidth',2,'HitTest','off');
        end
        % mark this track's D on the distribution
        D = QCstate.Deff(k);
        if ~isempty(QCstate.hlDeff) && isgraphics(QCstate.hlDeff), delete(QCstate.hlDeff); end
        if isfinite(D) && D>0
            QCstate.hlDeff = xline(axDeff, D, '-', 'Color',[1 0.55 0],'LineWidth',2);
        else, QCstate.hlDeff = []; end

        if isfinite(D), Dstr=sprintf('D=%.3g µm²/s',D); else, Dstr='D=n/a'; end
        lQC.Text = sprintf('cell %d · track %d · %d spots · %s   (click Tracks/MSD to select · ▶ Play to animate)', ...
            ci, ni, size(QCstate.selXY,1), Dstr);
        drawSel(size(QCstate.selXY,1));   % static full view
    end

    % draw the selected track at localisation index fIdx in the CURATION style:
    % emitter + link-ring circles for every spot in the frame, gold trail, optional
    % mito/ER overlay. No colorbar + drawnow limitrate -> stable under the timer.
    function drawSel(fIdx)
        if isempty(QCstate) || ~isfield(QCstate,'selXY') || isempty(QCstate.selXY) || ~isgraphics(axSel), return; end
        P = QCstate.selXY; L = size(P,1); fIdx = max(1,min(fIdx,L));
        QCstate.playIdx = fIdx;
        er = 0.15; ring = 0.30;    % emitter footprint / link-ring radii (um), like the curate view
        xr=[min(P(:,1)) max(P(:,1))]; yr=[min(P(:,2)) max(P(:,2))];
        pad = max([2*ring, 0.15*diff(xr), 0.15*diff(yr), 0.3]);
        xl=[xr(1)-pad xr(2)+pad]; yl=[yr(1)-pad yr(2)+pad];
        cla(axSel); hold(axSel,'on');
        drawQCoverlay(axSel);      % mito/ER structure under the track (if enabled)
        sx = P(fIdx,1); sy = P(fIdx,2);
        % every detection in THIS frame within the view -> emitter + link-ring circles
        haveAS = isfield(QCstate,'selFrame') && ~isempty(QCstate.selFrame) && ...
            isfield(QCstate.T,'allSpots') && ~isempty(QCstate.T(QCstate.selCi).allSpots);
        if haveAS
            AS = QCstate.T(QCstate.selCi).allSpots; frNow = QCstate.selFrame(fIdx);
            inF = AS.FRAME==frNow & AS.X>=xl(1) & AS.X<=xl(2) & AS.Y>=yl(1) & AS.Y<=yl(2);
            ox=AS.X(inF); oy=AS.Y(inF);
            for q=1:numel(ox)
                dsel = hypot(ox(q)-sx, oy(q)-sy);
                if     dsel < er,    col=[1 0.84 0];        % the selected spot itself
                elseif dsel <= ring, col=[0.91 0.42 0.14];  % a near spot (possible mislinkage)
                else,                col=[0.62 0.62 0.66];  % another detection
                end
                drawQCcircle(axSel, ox(q), oy(q), er,   col, '-', 1.0);
                drawQCcircle(axSel, ox(q), oy(q), ring, col, ':', 0.6);
            end
        else                        % no allSpots -> at least mark the current spot
            drawQCcircle(axSel, sx, sy, er,   [1 0.84 0], '-', 1.4);
            drawQCcircle(axSel, sx, sy, ring, [1 0.84 0], ':', 0.6);
        end
        % trail: future dashed grey, past solid gold; start = green triangle
        if fIdx<L,  plot(axSel,P(fIdx:L,1),P(fIdx:L,2),'--','Color',[0.6 0.6 0.6],'LineWidth',0.8,'HitTest','off'); end
        if fIdx>=2, plot(axSel,P(1:fIdx,1),P(1:fIdx,2),'-','Color',[1 0.84 0],'LineWidth',1.8,'HitTest','off'); end
        plot(axSel,P(1,1),P(1,2),'^','Color',[0.18 0.80 0.44],'MarkerFaceColor',[0.18 0.80 0.44], ...
            'MarkerSize',7,'HitTest','off');
        hold(axSel,'off'); daspect(axSel,[1 1 1]); xlim(axSel,xl); ylim(axSel,yl);
        D = QCstate.Deff(QCstate.selK);
        title(axSel,sprintf('cell %d · track %d · %d/%d · D=%.3g   [emitter %.2f, ring %.2f um]', ...
            QCstate.selCi,QCstate.selNi,fIdx,L,D,er,ring));
        drawnow limitrate;
    end

    function drawQCcircle(ax, x, y, r, col, ls, lw)
        rectangle('Parent',ax,'Position',[x-r y-r 2*r 2*r],'Curvature',[1 1], ...
            'EdgeColor',col,'LineStyle',ls,'LineWidth',lw,'HitTest','off','PickableParts','none');
    end

    function drawQCoverlay(ax)     % mito/ER structure image spanning the FOV (magenta), like curate
        if isempty(chkQCov) || ~isgraphics(chkQCov) || ~chkQCov.Value || isempty(qcOverlayImg), return; end
        g = qcOverlayImg; [Hh,Ww] = size(g); fov = local_fov();
        g = imadjust(g);          % contrast-stretch so faint structure is visible
        rgb = cat(3, g, zeros(Hh,Ww), g);
        image('Parent',ax,'XData',[0 fov],'YData',[0 fov*Hh/Ww],'CData',rgb,'AlphaData',min(1,0.75*g),'HitTest','off');
    end

    function p = qcCellMitoPath(base)
        % locate this cell's mito max-int via the Experiment tab's folder + pattern
        % (same {prefix} logic as the scanner), so the overlay needs no manual picking.
        p=''; md=''; pat='{prefix}_mito_mip.tif'; pstrip='_spt\d+';
        if ~isempty(eExMito)    && isgraphics(eExMito),    md=eExMito.Value; end
        if ~isempty(eExMitoPat) && isgraphics(eExMitoPat), pat=strtrim(eExMitoPat.Value); end
        if ~isempty(eExPrefix)  && isgraphics(eExPrefix),  pstrip=eExPrefix.Value; end
        if isempty(md) || ~isfolder(md) || isempty(pat), return; end
        if isempty(pstrip), prefix=base; else, prefix=regexprep(base,[pstrip '$'],'','ignorecase'); end
        try
            f=dir(fullfile(md, strrep(pat,'{prefix}',prefix))); f=f(~[f.isdir]);
            if ~isempty(f), p=fullfile(md,f(1).name); end
        catch, end
    end

    function p = qcCellErPath(base)
        % ER counterpart of qcCellMitoPath (Experiment tab's ER folder + pattern).
        p=''; ed=''; pat='{prefix}_er_mip.tif'; pstrip='_spt\d+';
        if ~isempty(eExEr)    && isgraphics(eExEr),    ed=eExEr.Value; end
        if ~isempty(eExErPat) && isgraphics(eExErPat), pat=strtrim(eExErPat.Value); end
        if ~isempty(eExPrefix)&& isgraphics(eExPrefix),pstrip=eExPrefix.Value; end
        if isempty(ed) || ~isfolder(ed) || isempty(pat), return; end
        if isempty(pstrip), prefix=base; else, prefix=regexprep(base,[pstrip '$'],'','ignorecase'); end
        try
            f=dir(fullfile(ed, strrep(pat,'{prefix}',prefix))); f=f(~[f.isdir]);
            if ~isempty(f), p=fullfile(ed,f(1).name); end
        catch, end
    end

    function s = cellOverlayPaths(base)
        % resolver handed to the embedded Curate viewer + used for the refiner: per-cell
        % ER + mito image paths from the Experiment tab, so overlays auto-load (no manual pick).
        s = struct('er', qcCellErPath(base), 'mito', qcCellMitoPath(base));
    end

    function g = readMitoMip(p)   % read a mito TIFF -> normalized grayscale MIP (or [] on miss)
        g = [];
        if isempty(p) || exist(p,'file')~=2, return; end
        try
            info=imfinfo(p); im=imread(p,1);
            for kk=2:numel(info), im=max(im,imread(p,kk)); end
            if size(im,3)==3, g=im2double(rgb2gray(im)); else, g=im2double(im); end
            mx=max(g(:)); if mx>0, g=g/mx; end
        catch, g=[]; end
    end

    function ok = loadQCmito(p)   % load a mito MIP into the QC overlay
        qcOverlayImg = readMitoMip(p); ok = ~isempty(qcOverlayImg);
    end

    function onQCpickOverlay()
        [fn,pth] = uigetfile({'*.tif;*.tiff','TIFF images'},'Pick a mito / ER structure image');
        if isequal(fn,0), return; end
        try
            fp=fullfile(pth,fn); info=imfinfo(fp); im=imread(fp,1);
            for kk=2:numel(info), im=max(im,imread(fp,kk)); end   % running MIP
            if size(im,3)==3, g=im2double(rgb2gray(im)); else, g=im2double(im); end
            mx=max(g(:)); if mx>0, g=g/mx; end
            qcOverlayImg=g; if ~isempty(chkQCov), chkQCov.Value=true; end
            say('QC structure overlay: %s [%dx%d]', fn, size(g,1), size(g,2));
            onQCoverlayChanged();   % repaint Tracks panel + selected view (Value= doesn't fire the callback)
        catch ME, say('overlay load failed: %s', ME.message); end
    end

    function refreshSel()          % redraw the current selection at its current frame
        if ~isempty(QCstate) && isfield(QCstate,'selXY') && ~isempty(QCstate.selXY)
            drawSel(QCstate.playIdx);
        end
    end

    function onQCoverlayChanged()   % overlay toggled -> redraw the Tracks panels + the selected view
        drawTrackPanels();
        refreshSel();
    end

    function drawTrackPanels()      % Tracks (raw) + Centered (time-coloured lines) + structure overlay
        if isempty(QCstate) || ~isfield(QCstate,'T') || ~isgraphics(axTracks), return; end
        T = QCstate.T;
        cla(axTracks); cla(axCentered); hold(axTracks,'on'); hold(axCentered,'on');
        drawQCoverlay(axTracks);    % mito/ER structure BEHIND the tracks (if enabled)
        cxAll=[]; cyAll=[]; ctAll=[];   % NaN-separated polylines for the centered view
        cidx = 1:numel(T); if isfield(QCstate,'cellIdxs') && ~isempty(QCstate.cellIdxs), cidx = QCstate.cellIdxs; end
        for i=cidx           % only the selected cell(s)
            if ~isfield(T,'matrix') || isempty(T(i).matrix) || size(T(i).matrix,3)<3, continue; end
            X=T(i).matrix(:,:,2); Y=T(i).matrix(:,:,3);
            plot(axTracks,X,Y,'-','Color',[0.20 0.40 0.80 0.35]);
            Xc=X-mean(X,1,'omitnan'); Yc=Y-mean(Y,1,'omitnan'); mm=size(Xc,1);
            for t=1:size(Xc,2)
                ok=isfinite(Xc(:,t))&isfinite(Yc(:,t));
                if nnz(ok)<2, continue; end
                ri=(1:mm)';
                cxAll=[cxAll; Xc(ok,t); NaN]; cyAll=[cyAll; Yc(ok,t); NaN]; ctAll=[ctAll; ri(ok); NaN]; %#ok<AGROW>
            end
        end
        hold(axTracks,'off');
        if ~isempty(cxAll)   % one colour-interp polyline (NaN breaks between tracks); colour = within-track time
            surface(axCentered,[cxAll cxAll],[cyAll cyAll],zeros(numel(cxAll),2),[ctAll ctAll], ...
                'EdgeColor','interp','FaceColor','none','LineWidth',0.5,'HitTest','off');
            colormap(axCentered,turbo);
        end
        hold(axCentered,'off');
        axis(axTracks,'equal'); axis(axCentered,'equal');
        set(findobj(axTracks,'Type','line'),'HitTest','off');   % clicks reach the axes
        axTracks.ButtonDownFcn = @(s,e) onTracksClick();
        xlabel(axTracks,'x (\mum)'); ylabel(axTracks,'y (\mum)'); title(axTracks,'Tracks (click to select)');
        xlabel(axCentered,'\Deltax (\mum)'); ylabel(axCentered,'\Deltay (\mum)'); title(axCentered,'Centered tracks (colour = time)');
        if isfield(QCstate,'selXY') && ~isempty(QCstate.selXY)   % restore the highlight (cla cleared it)
            hold(axTracks,'on');
            QCstate.hlTrack = plot(axTracks,QCstate.selXY(:,1),QCstate.selXY(:,2),'-','Color',[1 0.72 0],'LineWidth',2,'HitTest','off');
            hold(axTracks,'off');
        end
    end

    function fov = local_fov()
        fov = 27.61;
        cf = fullfile(getAnalysisDir(),'cs_calib.mat');
        if isfile(cf)
            try Lc=load(cf);
                if isfield(Lc,'calib') && isfield(Lc.calib,'fovUm') && isfinite(Lc.calib.fovUm) && Lc.calib.fovUm>0
                    fov=Lc.calib.fovUm;
                end
            catch, end
        end
    end

    % ================= Contact Site Results (tab 6) =================
    function loadCSresults()
        ana = getAnalysisDir();
        try, clearCStrkUndo(); catch, end   % a reload replaces csData -> any pending track-edit undo is stale
        if ~isfile(fullfile(ana,'CS_final.mat'))
            lRes.Text = 'No CS_final.mat yet — run ContactSites (tab 4) to the end first.'; return;
        end
        L = load(fullfile(ana,'CS_final.mat'));
        % Drop degenerate/placeholder sites (empty or non-scalar cellIndex) — e.g. a run where 0 CS were
        % refined leaves a blank record whose empty cellIndex would crash the per-CS loops below.
        if isfield(L,'CS') && ~isempty(L.CS)
            keep = arrayfun(@(c) isfield(c,'cellIndex') && isnumeric(c.cellIndex) && isscalar(c.cellIndex) && isfinite(c.cellIndex), L.CS);
            L.CS = L.CS(keep);
        end
        if ~isfield(L,'CS') || isempty(L.CS)
            lRes.Text = ['CS_final.mat has no valid contact sites — 0 were refined. In the refiner (tab 6, ' ...
                '"boundary refinement" step) draw a boundary or press "Use full box" to KEEP each site, then re-run from the builder.'];   % e.g. every site deleted / 0 refined
            csData=[]; csSelK=[]; if isgraphics(csTable), csTable.Data={}; end
            if isgraphics(csAx), cla(csAx); title(csAx,'No contact sites'); end
            if ~isempty(axCSall) && isgraphics(axCSall), cla(axCSall); end
            if ~isempty(csAxRad) && isgraphics(csAxRad), cla(csAxRad); title(csAxRad,'local density'); end
            return;
        end
        Tr = [];
        if isfile(fullfile(ana,'Tracks_final.mat'))
            Lt = load(fullfile(ana,'Tracks_final.mat')); if isfield(Lt,'Tracks'), Tr=Lt.Tracks; end
        end
        if isempty(Tr), lRes.Text = 'Tracks_final.mat missing — cannot play tracks.'; return; end
        % ensure the de-blinding key exists (the table below shows only cellIndex, blinded)
        if ~isfile(fullfile(ana,'cell_index_map.csv'))
            try, write_cell_index_map(ana, S.projectDir); catch, end
        end
        dt = local_dt(); CS = L.CS; nCS = numel(CS); dwell = zeros(1,nCS);
        for k=1:nCS
            dwell(k) = computeCSdwell(CS,k,dt);
        end
        % density-map pixel size for the scale readout ONLY (refreshScale). buildLocalDensity
        % reconstructs its own density, so the rho.tif pixels are never needed here — read just the
        % HEADER (imfinfo) of the FIRST cell's raster instead of decoding every cell's multi-MB TIFF.
        cfg = cs_config(ana); rhoWH = [];
        if ~isempty(CS)
            ci0 = CS(1).cellIndex;
            if ci0>=1 && ci0<=numel(Tr)
                rp = fullfile(ana,'Densities',[Tr(ci0).file '_rho.tif']);
                if exist(rp,'file')==2, try info=imfinfo(rp); rhoWH=[info(1).Width info(1).Height]; catch, end, end
            end
        end
        csData=[]; csData.CS=CS; csData.Tracks=Tr; csData.dt=dt; csData.dwell=dwell;
        csData.rhoWH=rhoWH; csData.snapFov=cfg.SnapFOV_um; csData.anaDir=ana;   % capture dir for saves (robust vs S)
        csSelK = [];
        % per-CS density metrics (advisor-style probability + local enrichment) -> table,
        % CSV, and embedded on CS_final. Non-fatal if it fails on odd data.
        try, computeCSDensityMetrics(); catch ME, say('CS density metrics skipped: %s', ME.message); end
        fillCStable();
        lRes.Text = sprintf('%d contact sites (%d mito). p + enrich in table -> analysis/cs_density_metrics.csv. Click a row, then ▶ Play.', nCS, sum(cs_sites_near(CS,'mito')));
        cla(csAx); title(csAx,'Select a contact site from the list');
        if ~isempty(csAxRad) && isgraphics(csAxRad), cla(csAxRad); title(csAxRad,'local density'); end
        refreshScale();   % now that rho is loaded, show the actual raster px/size in the scale readout
    end

    function fillCStable()
        % (re)build the CS table incl. the density-metric columns p (per-cell probability)
        % and enrich (fold over cell baseline) from csData.densMetrics.
        if isempty(csData) || ~isgraphics(csTable), return; end
        CS=csData.CS; Tr=csData.Tracks; nCS=numel(CS);
        M=[]; if isfield(csData,'densMetrics'), M=csData.densMetrics; end
        rows=cell(nCS,8);
        for k=1:nCS
            ci=CS(k).cellIndex; fn='';
            if ci>=1 && ci<=numel(Tr) && isfield(Tr,'file') && ~isempty(Tr(ci).file), fn=Tr(ci).file; end
            pm=''; en='';
            if ~isempty(M) && k<=numel(M)
                if isfinite(M(k).prob_mass),  pm=round(M(k).prob_mass,4); end
                if isfinite(M(k).enrichment), en=round(M(k).enrichment,2); end
            end
            rows(k,:)={sprintf('%d',round(CS(k).csID)), sprintf('%d',round(ci)), fn, tern(cs_site_near(CS(k),'mito'),'mito','non'), ...
                numel(CS(k).tracks), round(csData.dwell(k),3), pm, en};   % CS id + cell as integer strings (no float display)
        end
        csTable.Data=rows;
    end

    function computeCSDensityMetrics()
        % Per-contact-site density metrics, baked into the output.
        % Obara et al. (Nature 626:169, 2024), Methods "Spatial density analysis": localizations
        % are binned into 30 nm pixels and "counts are normalized to the total number of
        % localizations within the dataset" -> a spatial probability mass function (PMF) that
        % "minimizes the effects of differences in photoactivation efficiency or tagged protein
        % expression level". So:
        %  - prob_mass : the PMF integrated over the refined boundary = (RAW localizations inside
        %                the boundary) / (total localizations in the cell). Uses raw counts, exactly
        %                as the paper defines the PMF; this is the cross-cell-comparable metric.
        %  - peak_prob : the PMF at the densest bin inside the site, from the SMOOTHED density map
        %                (the advisor's imgaussfilt display / colorbar "axis max"), robust to
        %                single-pixel shot noise.
        %  - peak_prob_raw : the STRICT paper PMF peak — densest RAW-count bin inside / cell total
        %                (no smoothing). Noisier but exactly the paper's definition at the peak.
        %  - enrichment: SUPPLEMENTARY (not in the paper) — fold of the site's local density over
        %                the cell baseline (mean smoothed density inside / mean over occupied bins),
        %                dimensionless and self-referenced. Answers "how many-fold denser than this
        %                cell's own background", complementary to the PMF.
        % Results go to csData.densMetrics, the CS table, analysis/cs_density_metrics.csv,
        % and are embedded on CS_final.mat (new fields, non-destructive).
        if isempty(csData) || ~isfield(csData,'CS') || isempty(csData.CS), return; end
        CS=csData.CS; Tr=csData.Tracks; nCS=numel(CS);
        PixSize=30; binUm=PixSize/1000; binArea=binUm^2;     % 30 nm bins, 9e-4 um^2/bin
        % ---- per-cell caches: whole-cell smoothed density + baseline + total ----
        cache=containers.Map('KeyType','double','ValueType','any');
        cellList=unique([CS.cellIndex]);
        for ci=cellList(:)'
            if ci<1 || ci>numel(Tr) || ~isfield(Tr,'matrix') || isempty(Tr(ci).matrix), continue; end
            Xc=Tr(ci).matrix(:,:,2); Yc=Tr(ci).matrix(:,:,3); ok=isfinite(Xc)&isfinite(Yc);
            Xc=Xc(ok); Yc=Yc(ok); if isempty(Xc), continue; end
            mg=0.2; ex=(min(Xc)-mg):binUm:(max(Xc)+mg); ey=(min(Yc)-mg):binUm:(max(Yc)+mg);
            if numel(ex)<2 || numel(ey)<2, continue; end
            Hc=histcounts2(Xc,Yc,ex,ey);                     % raw counts [xbin ybin]
            rho=imgaussfilt(Hc,[2 2]);                        % smoothed loc/bin (advisor kernel)
            occ=Hc>=1;                                        % footprint = raw-occupied bins
            rho_bg=mean(rho(occ),'omitnan'); if ~(rho_bg>0), rho_bg=NaN; end
            cxc=(ex(1:end-1)+ex(2:end))/2; cyc=(ey(1:end-1)+ey(2:end))/2;
            fnm=''; if isfield(Tr,'file') && ~isempty(Tr(ci).file), fnm=Tr(ci).file; end
            % Xc/Yc/file cached with the density map so the per-site loop below never touches
            % Tr -> its only inputs are sliced-by-site, which lets it run under parfor.
            cache(ci)=struct('cellTot',numel(Xc),'rho',rho,'Hc',Hc,'cxc',cxc,'cyc',cyc, ...
                'rho_bg',rho_bg,'Xc',Xc,'Yc',Yc,'file',fnm);
        end
        % ---- per-CS metrics ----
        blank=struct('csID',NaN,'cellIndex',NaN,'file','','mito',false,'n_loc_in',0, ...
            'cell_total',0,'prob_mass',NaN,'peak_prob',NaN,'peak_prob_raw',NaN,'area_um2',NaN, ...
            'local_dens',NaN,'cell_bg_dens',NaN,'enrichment',NaN);
        % Pre-resolve each site's per-cell cache entry + file so the compute loop's ONLY inputs
        % are sliced-by-site (CS(k), ccFor{k}, fileFor{k}) -> it runs unchanged under parfor.
        ccFor=cell(1,nCS); fileFor=repmat({''},1,nCS);
        for k=1:nCS
            ci=CS(k).cellIndex;
            if isKey(cache,ci), ccFor{k}=cache(ci); end
            if ci>=1 && ci<=numel(Tr) && isfield(Tr,'file') && ~isempty(Tr(ci).file), fileFor{k}=Tr(ci).file; end
        end
        M=repmat(blank,1,nCS);
        % The bbox pre-filter above already makes each site cheap, so this loop is fast serially.
        % When the Parallel Computing Toolbox is installed AND a worker pool is ALREADY running,
        % also fan the (now cheap) sites across cores as a free extra — but never spin up a pool
        % just for this: on a cheap loop a ~15 s cold-start would cost far more than it saves, and
        % on machines without the toolbox ver('parallel') is empty so we stay fully serial. Any
        % absence or hiccup falls straight through to the identical serial loop below.
        usedPar=false;
        if nCS>=150 && ~isempty(ver('parallel'))
            try
                pool=gcp('nocreate');                 % REUSE a warm pool only; do not start one
                if ~isempty(pool) && pool.NumWorkers>1
                    parfor k=1:nCS
                        M(k)=csDensMetricOne(CS(k), ccFor{k}, fileFor{k}, blank, binArea);
                    end
                    usedPar=true;
                end
            catch
                usedPar=false;   % no pool / toolbox / any error -> serial below
            end
        end
        if ~usedPar
            for k=1:nCS
                M(k)=csDensMetricOne(CS(k), ccFor{k}, fileFor{k}, blank, binArea);
            end
        end
        csData.densMetrics=M;
        % shared cross-cell display scale = the densest site's per-bin PMF peak, so the
        % probability display maps every cell onto ONE colour scale (comparable colours).
        pk_all=[M.peak_prob]; pk_all=pk_all(isfinite(pk_all));
        if ~isempty(pk_all), csData.probScaleMax=max(pk_all); else, csData.probScaleMax=[]; end
        % embed on CS_final (new fields; existing fields untouched) + write the CSV
        for k=1:nCS
            csData.CS(k).probMass    = M(k).prob_mass;
            csData.CS(k).peakProb    = M(k).peak_prob;
            csData.CS(k).peakProbRaw = M(k).peak_prob_raw;
            csData.CS(k).enrichment  = M(k).enrichment;
            csData.CS(k).nLocInside  = M(k).n_loc_in;
            csData.CS(k).cellTotalLoc= M(k).cell_total;
            csData.CS(k).areaUm2     = M(k).area_um2;
            csData.CS(k).localDens   = M(k).local_dens;
            csData.CS(k).cellBgDens  = M(k).cell_bg_dens;
        end
        try, saveCSfinal(); catch, end
        try, writeCSDensityCSV(); catch, end
    end

    function writeCSDensityCSV()
        if isempty(csData) || ~isfield(csData,'densMetrics') || isempty(csData.densMetrics), return; end
        if isfield(csData,'anaDir') && ~isempty(csData.anaDir), ad=csData.anaDir; else, ad=getAnalysisDir(); end
        M=csData.densMetrics; fid=fopen(fullfile(ad,'cs_density_metrics.csv'),'w');
        if fid<0, return; end
        fprintf(fid,['csID,cellIndex,file,mito,n_loc_inside,cell_total_loc,prob_mass,' ...
            'peak_prob,peak_prob_raw,area_um2,local_density_per_um2,cell_baseline_density_per_um2,enrichment\n']);
        for k=1:numel(M)
            fprintf(fid,'%d,%d,%s,%d,%d,%d,%.6g,%.6g,%.6g,%.4f,%.4f,%.4f,%.4f\n', ...
                M(k).csID, M(k).cellIndex, M(k).file, M(k).mito, M(k).n_loc_in, M(k).cell_total, ...
                M(k).prob_mass, M(k).peak_prob, M(k).peak_prob_raw, M(k).area_um2, M(k).local_dens, ...
                M(k).cell_bg_dens, M(k).enrichment);
        end
        fclose(fid);
    end

    function d = computeCSdwell(CS, k, dt)   % longest single residence inside refboundary (s)
        d = 0; cols = CS(k).tracks;
        if isempty(cols) || isempty(CS(k).refboundary) || size(CS(k).CSmatrix,3)<3, return; end
        bx = CS(k).refboundary(:,1)/1000; by = CS(k).refboundary(:,2)/1000;   % um rel refCenter
        for jj=1:min(numel(cols),size(CS(k).CSmatrix,2))
            m = csInsideMask(CS(k).CSmatrix(:,jj,2), CS(k).CSmatrix(:,jj,3), bx, by);
            rev = runsToEvents(m, CS(k).CSmatrix(:,jj,1), dt);   % SAME definition as the Dwell tab
            if ~isempty(rev), d = max(d, max(rev(:,3))); end
        end
    end

    function m = csInsideMask(x,y,bx,by)     % logical mask of localizations inside the boundary
        ok=isfinite(x)&isfinite(y); m=false(size(x)); m(ok)=inpolygon(x(ok),y(ok),bx,by);
    end
    function ev = runsToEvents(inside,fr,dt)  % maximal runs of consecutive INSIDE localizations -> [entryFrame exitFrame dwell]
        ev=zeros(0,3); d=diff([false; inside(:); false]); s=find(d==1); e=find(d==-1)-1;
        for ii=1:numel(s)
            a=s(ii); b=e(ii); ev(end+1,:)=[fr(a) fr(b) (fr(b)-fr(a)+1)*dt]; %#ok<AGROW>
        end
    end
    function mg = mergeIntervals(iv)          % merge overlapping [entryFrame exitFrame] rows (dedup overlapping CS)
        mg=zeros(0,2); if isempty(iv), return; end
        iv=sortrows(iv,1); cur=iv(1,1:2);
        for r=2:size(iv,1)
            if iv(r,1) <= cur(2), cur(2)=max(cur(2),iv(r,2));   % overlap -> extend
            else, mg(end+1,:)=cur; cur=iv(r,1:2); end            %#ok<AGROW>
        end
        mg(end+1,:)=cur;
    end
    function [cls,entF,exF] = classifyInside(iv,frv)
        % Classify a track's residence in ONE contact site from its INSIDE mask, evaluated
        % only at real (finite) localizations in frame order. Four exhaustive classes by
        % boundary CROSSINGS (0<->1 transitions between consecutive localizations):
        %   RESIDENT      inside for its entire observed lifetime (never crosses)
        %   ENTERS        crosses IN at least once  (a 0->1 transition exists)
        %   EXITS         crosses OUT at least once (a 1->0 transition exists)
        %   ENTERS+EXITS  both crossings occur
        % Returns ALL crossings (a track can enter/exit several times): entF = every arrival
        % frame (frame it becomes inside after a 0->1); exF = every departure frame (last inside
        % frame before a 1->0). #in = numel(entF), #out = numel(exF).
        cls='—'; entF=[]; exF=[]; iv=logical(iv(:)); frv=frv(:);
        if isempty(iv) || ~any(iv), return; end            % never inside -> not truly associated
        if all(iv), cls='RESIDENT'; return; end            % inside throughout observed dwell (no crossings)
        du=diff(double(iv)); up=find(du==1); dn=find(du==-1);
        entF=frv(up+1);        % each 0->1 -> arrival (first inside frame of that episode)
        exF =frv(dn);          % each 1->0 -> departure (last inside frame before leaving)
        hasIn=~isempty(up); hasOut=~isempty(dn);
        if hasIn && hasOut, cls='ENTERS+EXITS';
        elseif hasIn,       cls='ENTERS';
        elseif hasOut,      cls='EXITS';
        end
    end
    function s = frTxt(v)                      % frame LIST -> display text ('—' when empty)
        v = v(isfinite(v));
        if isempty(v), s='—'; else, s=strjoin(compose('%d',round(v(:)'))', ';'); end
    end
    function v = frParse(s)                     % editable text ("12;78" / "12 78" / "—") -> sorted unique frame vector
        if isnumeric(s), v=round(s(isfinite(s))); v=unique(v(:)'); return; end
        s = char(string(s)); s = regexprep(s,'[^0-9]+',' ');
        v = str2num(s); %#ok<ST2NM>
        if isempty(v), v=[]; else, v=unique(round(v(:)')); end
    end

    function onCSselect(e)
        if isempty(csData) || isempty(e.Indices), return; end
        k = e.Indices(1); if k<1 || k>numel(csData.CS), return; end
        stopQCplay(); csSelK = k; csIsoTrk = [];   % new site -> clear any isolated-track playback
        % cache the member-track density once per selection (the density the boundary
        % was traced over -> boundary aligns). The whole-cell toggle uses the rendered
        % rho.tif directly (a member-only reconstruction is identical to this in-zoom).
        try, csMemDens = buildLocalDensity(k, csData.CS(k).tracks); catch, csMemDens=[]; end
        csWholeDens=[]; csWholeDensK=[];   % rebuilt lazily on the first whole-cell toggle for this CS
        ci = csData.CS(k).cellIndex; Tr = csData.Tracks;
        % auto-load this cell's mito MIP into the overlay (like the Dwell tab) so the "overlay"
        % toggle just works without a manual pick; reload only when the cell changes. Must run
        % BEFORE drawCS so the first draw shows it.
        if ~isequal(csOvCi, ci)
            csOvCi = ci; csOverlayImg = [];
            if ci>=1 && ci<=numel(Tr) && isfield(Tr,'file') && ~isempty(Tr(ci).file)
                try, csOverlayImg = readMitoMip(qcCellMitoPath(Tr(ci).file)); catch, csOverlayImg=[]; end
            end
        end
        [csFrameMin,csFrameMax] = csFrameRange(k);
        csPlayFrame = csFrameMin;
        % Each panel is independent: an error in the zoomed site view must NOT abort the whole-cell
        % overview / radial panel / track list below it (that would look like "switching is broken").
        try, drawCS(csPlayFrame);   catch ME, say('CS site view error: %s', ME.message); end
        try, drawCSallPanel(k); catch ME, say('CS whole-cell view error: %s', ME.message); end   % whole-cell overview (static, per selection)
        try, drawCSradial(k);   catch, end        % radial concentration curve (keep/discard aid)
        allc = csData.CS(k).tracks(:)'; cols = csTouchingCols(k);   % only tracks touching the boundary
        [nTot,nIn] = csLocCount(k);
        % prefer the original TrackMate ids (threaded through the importer); fall back
        % to matrix column indices if this run predates that field.
        if isfield(Tr,'trackIDs') && ci>=1 && ci<=numel(Tr) && ~isempty(Tr(ci).trackIDs) ...
                && ~isempty(cols) && all(cols>=1 & cols<=numel(Tr(ci).trackIDs)) && any(isfinite(Tr(ci).trackIDs(cols)))
            idvec = Tr(ci).trackIDs(cols); idlabel = 'TrackMate ids';
        else
            idvec = cols; idlabel = 'column ids';
        end
        fnTxt=''; if ci>=1 && ci<=numel(Tr) && isfield(Tr,'file') && ~isempty(Tr(ci).file), fnTxt=[' · ' Tr(ci).file]; end
        % "loc inside boundary" = the localizations actually AT this site (the meaningful count);
        % nTot counts EVERY localization of every member track over its WHOLE trajectory (tracks
        % that merely pass through the ±5.4µm assignment box), so it is much larger — label it clearly.
        if ~isempty(csData.CS(k).refboundary), insideTxt = sprintf('%d loc inside boundary', nIn);
        else,                                  insideTxt = 'not yet refined (no boundary)'; end
        lRes.Text = sprintf(['CS %d · cell %d%s · %s · %d/%d tracks touch boundary · %s · ' ...
            '%d loc across member tracks'' whole trajectories · touching %s: %s'], ...
            csData.CS(k).csID, csData.CS(k).cellIndex, fnTxt, tern(cs_site_near(csData.CS(k),'mito'),'MITO','non'), ...
            numel(cols), numel(allc), insideTxt, nTot, idlabel, mat2str(idvec(:)'));
        fillCStrkList(k);   % per-CS track list (click to isolate)
    end

    function onCSStep(d)   % step to the previous/next contact site (click back and forth)
        if isempty(csData) || isempty(csData.CS), return; end
        n = numel(csData.CS);
        if isempty(csSelK), k = tern(d>0,1,n); else, k = min(max(csSelK + d, 1), n); end
        try, csTable.Selection = [k 1]; catch, end       % highlight row k (cell-select needs [row col]); no callback re-fire
        onCSselect(struct('Indices',[k 1]));            % reuse the full selection + draw logic
    end

    function S = csTrackInStats(k)
        % Per member track of CS k: how many of the track's localizations sit INSIDE the refined
        % boundary vs the track's total. A low fraction = a track that barely sits in the site,
        % so it can be spotted and filtered out. Returns a struct array (col/id/nin/ntot/frac).
        CS=csData.CS; Tr=csData.Tracks; ci=CS(k).cellIndex; rc=CS(k).refCenter;
        cols=CS(k).tracks(:)';
        S=struct('col',{},'id',{},'nin',{},'ntot',{},'frac',{});
        haveB = ~isempty(CS(k).refboundary) && numel(rc)==2 && all(isfinite(rc));
        if haveB, bx=CS(k).refboundary(:,1)/1000+rc(1); by=CS(k).refboundary(:,2)/1000+rc(2); end
        for c=cols
            x=Tr(ci).matrix(:,c,2); y=Tr(ci).matrix(:,c,3); o=isfinite(x)&isfinite(y);
            x=x(o); y=y(o); ntot=numel(x);
            if haveB && ntot>0, nin=nnz(inpolygon(x,y,bx,by)); else, nin=0; end
            id=c;
            if isfield(Tr,'trackIDs') && ci>=1 && ci<=numel(Tr) && ~isempty(Tr(ci).trackIDs) ...
                    && c<=numel(Tr(ci).trackIDs) && isfinite(Tr(ci).trackIDs(c)), id=Tr(ci).trackIDs(c); end
            S(end+1)=struct('col',double(c),'id',id,'nin',nin,'ntot',ntot,'frac',nin/max(ntot,1)); %#ok<AGROW>
        end
    end

    function fillCStrkList(k)
        if isempty(csTrkList) || ~isgraphics(csTrkList), return; end
        % NOTE: use a LOCAL name (St), NOT S. `S` is the shared app-state struct (S.projectDir …)
        % in this nested-function app, so assigning `S = …` here would clobber it and every later
        % getAnalysisDir()/local_fov() would throw "Unrecognized field name projectDir".
        St = csTrackInStats(k);
        if isempty(St), csTrkList.Items={}; csTrkList.ItemsData=[]; return; end
        % Show only the tracks that actually SIT IN the site (>=1 localization inside the refined
        % boundary). The mapper associates every track within its large +-4.5um box — often 100+
        % DISTINCT tracks (not duplicates) — but almost all have 0 localizations inside the tight
        % boundary and are several um away; listing them all buries the real 3-6 that belong here.
        touch = St([St.nin] >= 1);
        if ~isempty(touch), St = touch; end           % keep all members only when nothing touches (e.g. unrefined)
        [~,ord]=sort([St.frac],'ascend');   % barely-in tracks first -> easy to multi-select and drop
        St=St(ord);
        items=cell(1,numel(St)); data=zeros(1,numel(St));
        for j=1:numel(St)
            items{j}=sprintf('track %g · %d/%d in (%d%%)', St(j).id, St(j).nin, St(j).ntot, round(100*St(j).frac));
            data(j)=St(j).col;
        end
        csTrkList.Items=items; csTrkList.ItemsData=data;   % numeric ItemsData -> Value is scalar (single) or vector (multi)
        csTrkList.Value=data(1);
    end

    function onCStrkPick()
        if isempty(csData) || isempty(csSelK) || isempty(csTrkList) || ~isgraphics(csTrkList) || isempty(csTrkList.Value), return; end
        v = csTrkList.Value;
        if numel(v)==1
            isolateCStrk(v);   % single selection -> isolate the picked track AND play it
        else
            say('%d tracks selected — press "－ Remove" to drop them all from CS %d.', numel(v), csData.CS(csSelK).csID);
        end
    end

    function isolateCStrk(c)
        % Isolate track column c and PLAY it: drawCS draws its trail growing to the live
        % playback frame (bright gold), other member tracks dimmed for context. Playback
        % starts at the track's first frame so you see it appear and move.
        if isempty(csData) || isempty(csSelK) || ~isgraphics(csAx), return; end
        k=csSelK; Tr=csData.Tracks; ci=csData.CS(k).cellIndex;
        if ~isempty(csTrkHi) && isgraphics(csTrkHi), delete(csTrkHi); end; csTrkHi=[];
        if ci<1 || ci>numel(Tr) || c<1 || c>size(Tr(ci).matrix,2), csIsoTrk=[]; return; end
        csIsoTrk = c;
        fr = Tr(ci).matrix(:,c,1); fr = fr(isfinite(fr));
        f0 = csFrameMin; if ~isempty(fr), f0 = max(csFrameMin, min(fr)); end
        startCSplay(f0);
    end

    function saveCSfinal()
        if isempty(csData), return; end
        if isfield(csData,'anaDir') && ~isempty(csData.anaDir), ad=csData.anaDir; else, ad=getAnalysisDir(); end
        CS=csData.CS;
        for kk=1:numel(CS)   % safety net: per-track arrays must stay length-aligned across dim2
            n=numel(CS(kk).tracks); bad={};
            if isfield(CS,'CSmatrix')   && ~isempty(CS(kk).CSmatrix)    && size(CS(kk).CSmatrix,2)~=n,   bad{end+1}='CSmatrix'; end %#ok<AGROW>
            if isfield(CS,'CSvec')      && ~isempty(CS(kk).CSvec)       && size(CS(kk).CSvec,2)~=n,      bad{end+1}='CSvec';    end %#ok<AGROW>
            if isfield(CS,'tracksCCids')&& numel(CS(kk).tracksCCids)~=n && ~isempty(CS(kk).tracksCCids), bad{end+1}='tracksCCids'; end %#ok<AGROW>
            if ~isempty(bad), say('WARNING: CS %d per-track fields misaligned (%s vs %d tracks) — saved anyway; re-check track edits.', CS(kk).csID, strjoin(bad,','), n); end
        end
        try, save(fullfile(ad,'CS_final.mat'),'CS'); catch ME, say('CS_final save failed: %s',ME.message); end %#ok<NASGU>
    end

    function refreshCSafterTrackEdit(k)
        % CS track membership changed -> refresh caches/panels AND recompute the metrics that DEPEND
        % on membership (dwell + the density PMF), re-embed them on CS_final, and invalidate the
        % dwell/Compare tabs. Without this, the table dwell/p/enrich columns, the site title, the
        % embedded CS_final fields + CSV, and the Compare tab all stay stale until a full reload.
        try, csMemDens = buildLocalDensity(k, csData.CS(k).tracks); catch, csMemDens=[]; end
        csWholeDens=[]; csWholeDensK=[];   % invalidate whole-cell density (rebuilt lazily; same grid as member -> no shift)
        try, csData.dwell(k) = computeCSdwell(csData.CS, k, csData.dt); catch, end   % dwell reads member CSmatrix
        try, computeCSDensityMetrics(); catch ME, say('CS density metrics skipped: %s', ME.message); end   % re-embeds p/enrich, re-saves CS_final + CSV
        % update this row's derived cells in place (preserves the table selection)
        M=[]; if isfield(csData,'densMetrics'), M=csData.densMetrics; end
        d=csTable.Data;
        if ~isempty(d) && k<=size(d,1)
            d{k,5}=numel(csData.CS(k).tracks); d{k,6}=round(csData.dwell(k),3);   % #trk, dwell
            if ~isempty(M) && k<=numel(M)
                d{k,7}=tern(isfinite(M(k).prob_mass),  round(M(k).prob_mass,4), '');   % p
                d{k,8}=tern(isfinite(M(k).enrichment), round(M(k).enrichment,2), '');  % enrich
            end
            csTable.Data=d;
        end
        drawCS(csPlayFrame); try, drawCSallPanel(k); catch, end
        fillCStrkList(k);
        dwellData=[]; cmpData=[];   % dwell + Compare tabs recompute on next open (both embed membership/metrics)
        if ~isempty(lDwell) && isgraphics(lDwell), lDwell.Text='CS tracks changed — press Compute to refresh the dwell results.'; end
    end

    function onCStrkRemove()
        if isempty(csData) || isempty(csSelK) || isempty(csTrkList) || ~isgraphics(csTrkList) || isempty(csTrkList.Value), return; end
        k=csSelK; CS=csData.CS;
        selCols = csTrkList.Value; selCols = double(selCols(:)');   % Multiselect -> one OR many track columns
        selCols = intersect(selCols, CS(k).tracks);                % keep only real members
        if isempty(selCols), return; end
        if numel(CS(k).tracks) - numel(selCols) < 1
            uialert(fig, sprintf(['That would remove every track from CS %d. A contact site must keep at ' ...
                'least one track — deselect one, or use "Delete CS" to remove the whole site.'], CS(k).csID), ...
                'Cannot remove all tracks');
            return;
        end
        stopQCplay();
        pushCStrkUndo(CS, k, sprintf('remove %d track(s) from CS %d', numel(selCols), CS(k).csID));   % snapshot BEFORE mutating
        for c = selCols
            jj = find(CS(k).tracks==c, 1); if isempty(jj), continue; end
            CS(k).tracks(jj)=[];   % drop from ALL per-track fields to keep them aligned
            if isfield(CS,'CSmatrix')   && size(CS(k).CSmatrix,2)>=jj,   CS(k).CSmatrix(:,jj,:)=[]; end
            if isfield(CS,'CSvec')      && ~isempty(CS(k).CSvec) && size(CS(k).CSvec,2)>=jj, CS(k).CSvec(:,jj,:)=[]; end
            if isfield(CS,'tracksCCids')&& numel(CS(k).tracksCCids)>=jj, CS(k).tracksCCids(jj)=[]; end
        end
        csData.CS=CS; saveCSfinal(); refreshCSafterTrackEdit(k);
        say('Removed %d track(s) from CS %d — %d remain. CS_final.mat re-saved. (Undo available.)', ...
            numel(selCols), CS(k).csID, numel(CS(k).tracks));
    end

    function onCStrkTrimAll()
        % Drop the mapper's over-associated tracks from EVERY refined site: keep only the tracks with
        % >=1 localization inside the refined boundary (csTouchingCols). The mapper's large ±box
        % captures many DISTINCT tracks that never sit at the site; this removes them so each CS holds
        % only its real tracks. Metrics use localizations-inside (not the member count), so p/enrich
        % are unchanged; the '#trk' count and the track list become honest. Not single-undoable.
        if isempty(csData) || ~isfield(csData,'CS') || isempty(csData.CS), return; end
        CS=csData.CS; nSites=numel(CS); nRem=0;
        for k=1:nSites
            if isempty(CS(k).refboundary), continue; end
            tc=csTouchingCols(k); nRem = nRem + numel(CS(k).tracks) - nnz(ismember(CS(k).tracks,tc));
        end
        if nRem==0, say('All refined contact sites already contain only touching tracks.'); return; end
        d=uiconfirm(fig, sprintf(['Remove %d over-associated tracks from %d contact site(s)?\n\nEach refined ' ...
            'site keeps ONLY the tracks with a localization inside its boundary (the ones truly at the site). ' ...
            'This rewrites CS_final.mat and is not single-undoable (re-run the mapper to restore).'], nRem, nSites), ...
            'Trim to touching tracks', 'Options',{'Trim','Cancel'},'DefaultOption',2,'CancelOption',2,'Icon','warning');
        if ~strcmp(d,'Trim'), return; end
        stopQCplay();
        for k=1:nSites
            if isempty(CS(k).refboundary), continue; end
            tc=csTouchingCols(k); keep=ismember(CS(k).tracks, tc); nt=numel(CS(k).tracks);
            if all(keep) || nnz(keep)<1, continue; end   % nothing to trim, or would empty the site -> leave it
            CS(k).tracks = CS(k).tracks(keep);
            if isfield(CS,'CSmatrix')       && size(CS(k).CSmatrix,2)==nt,       CS(k).CSmatrix=CS(k).CSmatrix(:,keep,:); end
            if isfield(CS,'CSvec')          && ~isempty(CS(k).CSvec) && size(CS(k).CSvec,2)==nt, CS(k).CSvec=CS(k).CSvec(:,keep,:); end
            if isfield(CS,'tracksCCids')    && numel(CS(k).tracksCCids)==nt,     CS(k).tracksCCids=CS(k).tracksCCids(keep); end
            if isfield(CS,'ChPts')          && size(CS(k).ChPts,2)==nt,          CS(k).ChPts=CS(k).ChPts(:,keep); end
            if isfield(CS,'IDmatrixCSspec') && size(CS(k).IDmatrixCSspec,2)==nt, CS(k).IDmatrixCSspec=CS(k).IDmatrixCSspec(:,keep); end
        end
        csData.CS=CS;
        try, for k=1:numel(csData.CS), csData.dwell(k)=computeCSdwell(csData.CS,k,csData.dt); end, catch, end
        try, computeCSDensityMetrics(); catch, end   % re-embeds + re-saves CS_final + CSV
        saveCSfinal();
        clearCStrkUndo(); dwellData=[]; cmpData=[]; csTouchCols=[]; csTouchColsSig=[];
        fillCStable();
        if ~isempty(csSelK) && csSelK<=numel(csData.CS), try, onCSselect(struct('Indices',[csSelK 1])); catch, end, end
        say('Trimmed %d over-associated tracks; every refined site now holds only its touching tracks. CS_final.mat re-saved.', nRem);
    end

    function onCStrkAdd()
        if isempty(csData) || isempty(csSelK), return; end
        k=csSelK; CS=csData.CS; Tr=csData.Tracks; ci=CS(k).cellIndex;
        bxx=CS(k).boundaries.x; byy=CS(k).boundaries.y; mrg=0.5;   % non-members within box +0.5 µm
        cand=[];
        for c=setdiff(1:size(Tr(ci).matrix,2), CS(k).tracks)
            x=Tr(ci).matrix(:,c,2); y=Tr(ci).matrix(:,c,3);
            if any(x>=bxx(1)-mrg & x<=bxx(2)+mrg & y>=byy(1)-mrg & y<=byy(2)+mrg), cand(end+1)=c; end %#ok<AGROW>
        end
        if isempty(cand), say('No non-member tracks near CS %d.', CS(k).csID); return; end
        labels = arrayfun(@(c) sprintf('track %g', trkId(Tr,ci,c)), cand, 'UniformOutput',false);
        [selI,ok] = listdlg('PromptString',sprintf('Add a track to CS %d:',CS(k).csID), ...
            'ListString',labels,'SelectionMode','single','ListSize',[220 260]);
        if ~ok || isempty(selI), return; end
        c = cand(selI); rc=CS(k).refCenter;
        col = cat(3, Tr(ci).matrix(:,c,1), Tr(ci).matrix(:,c,2)-rc(1), Tr(ci).matrix(:,c,3)-rc(2));
        % Validate row-count against an existing CSmatrix BEFORE mutating anything,
        % so the per-track fields (tracks / CSmatrix / CSvec / tracksCCids) can never desync.
        if isfield(CS,'CSmatrix') && ~isempty(CS(k).CSmatrix) && size(col,1)~=size(CS(k).CSmatrix,1)
            uialert(fig, sprintf(['Track %g has %d frames but CS %d stores %d — cannot add without ' ...
                'misaligning the per-track arrays.'], trkId(Tr,ci,c), size(col,1), CS(k).csID, ...
                size(CS(k).CSmatrix,1)), 'Cannot add track'); return;
        end
        pushCStrkUndo(CS, k, sprintf('add track to CS %d', CS(k).csID));   % snapshot BEFORE mutating
        CS(k).tracks(end+1)=c;
        if isfield(CS,'CSmatrix')
            if isempty(CS(k).CSmatrix), CS(k).CSmatrix = col; else, CS(k).CSmatrix = cat(2, CS(k).CSmatrix, col); end
        end
        % CSvec MUST stay column-aligned with tracks/CSmatrix. If this cell has no usable .vector,
        % append a NaN column rather than skipping the append (skipping leaves CSvec one column short).
        if isfield(CS,'CSvec') && ~isempty(CS(k).CSvec)
            nrow=size(CS(k).CSvec,1); npg=size(CS(k).CSvec,3);
            if isfield(Tr,'vector') && ~isempty(Tr(ci).vector) && size(Tr(ci).vector,1)==nrow
                CS(k).CSvec = cat(2, CS(k).CSvec, Tr(ci).vector(:,c,:));
            else
                CS(k).CSvec = cat(2, CS(k).CSvec, nan(nrow,1,npg));   % keep length-aligned
            end
        end
        % NaN (not 0) marks "not CC-associated": downstream ConditionAccumulator / ExportCSstruct use isfinite() as the CC sentinel.
        if isfield(CS,'tracksCCids'), CS(k).tracksCCids(end+1)=NaN; end
        csData.CS=CS; saveCSfinal(); refreshCSafterTrackEdit(k);
        say('Added track %g to CS %d — %d tracks now. CS_final.mat re-saved. (Undo available.)', trkId(Tr,ci,c), CS(k).csID, numel(CS(k).tracks));
    end

    function pushCStrkUndo(CS, k, desc)
        % Capture a contact site's FULL element before an Add/Remove edit so onCStrkUndo can
        % restore it exactly (one level). Keyed by cellIndex+csID so the undo still finds the
        % right site even if the list order changed between the edit and the undo.
        csTrkUndo = struct('cellIndex',CS(k).cellIndex,'csID',CS(k).csID,'snap',CS(k),'desc',desc);
        if ~isempty(bTrkUndo) && isgraphics(bTrkUndo)
            bTrkUndo.Enable='on'; bTrkUndo.Tooltip=['Undo: ' desc];
        end
    end

    function clearCStrkUndo()
        csTrkUndo=[];
        if ~isempty(bTrkUndo) && isgraphics(bTrkUndo)
            bTrkUndo.Enable='off';
            bTrkUndo.Tooltip='Undo the last Add/Remove track edit on the current contact site (one level)';
        end
    end

    function onCStrkUndo()
        if isempty(csTrkUndo) || isempty(csData) || ~isfield(csData,'CS'), say('Nothing to undo.'); return; end
        u=csTrkUndo; CS=csData.CS;
        k = find([CS.cellIndex]==u.cellIndex & [CS.csID]==u.csID, 1);
        if isempty(k)
            say('Cannot undo — CS %d (cell %d) is no longer in the results.', u.csID, u.cellIndex);
            clearCStrkUndo(); return;
        end
        stopQCplay();
        CS(k)=u.snap; csData.CS=CS; saveCSfinal();   % restore the pre-edit site element
        csSelK=k; clearCStrkUndo(); refreshCSafterTrackEdit(k);
        say('Undo: reverted "%s" — CS %d now has %d tracks. CS_final.mat re-saved.', ...
            u.desc, u.csID, numel(CS(k).tracks));
    end

    function [nTot,nIn] = csLocCount(k)
        % member-track localizations total, and how many fall inside the refined boundary
        CS=csData.CS; Tr=csData.Tracks; ci=CS(k).cellIndex; cols=CS(k).tracks; rc=CS(k).refCenter;
        X=[]; Y=[];
        for c=cols(:)'
            x=Tr(ci).matrix(:,c,2); y=Tr(ci).matrix(:,c,3); ok=isfinite(x)&isfinite(y);
            X=[X;x(ok)]; Y=[Y;y(ok)]; %#ok<AGROW>
        end
        nTot=numel(X); nIn=0;
        if ~isempty(CS(k).refboundary) && nTot>0
            bx=CS(k).refboundary(:,1)/1000+rc(1); by=CS(k).refboundary(:,2)/1000+rc(2);
            nIn=nnz(inpolygon(X,Y,bx,by));
        end
    end

    function cols = csTouchingCols(k)
        % the member tracks whose localizations ACTUALLY fall inside the refined
        % boundary (not just the big +/-4.5um assignment box) — the tracks truly
        % associated with this contact site.
        CS=csData.CS; Tr=csData.Tracks; ci=CS(k).cellIndex; allc=CS(k).tracks(:)'; rc=CS(k).refCenter;
        if isempty(CS(k).refboundary), cols=allc; return; end   % un-refined: fall back to box members
        bx=CS(k).refboundary(:,1)/1000+rc(1); by=CS(k).refboundary(:,2)/1000+rc(2);
        keep=false(1,numel(allc));
        for j=1:numel(allc)
            x=Tr(ci).matrix(:,allc(j),2); y=Tr(ci).matrix(:,allc(j),3); o=isfinite(x)&isfinite(y);
            keep(j)=any(inpolygon(x(o),y(o),bx,by));
        end
        cols=allc(keep);
    end

    function cols = csTouchingColsCached(k)
        % Per-selection cache of csTouchingCols for the playback hot path (drawCS runs ~12.5x/s).
        % Recomputes only when the site, its member count, its boundary, or its centre changes —
        % a self-invalidating signature, so no edit-path plumbing is needed.
        rb=csData.CS(k).refboundary; rc=csData.CS(k).refCenter(:)';
        sig=[k, numel(csData.CS(k).tracks), size(rb,1), sum(rb(:),'omitnan'), rc];
        if isequal(csTouchColsSig,sig) && ~isempty(csTouchCols), cols=csTouchCols; return; end
        cols=csTouchingCols(k); csTouchCols=cols; csTouchColsSig=sig;
    end

    function md = buildLocalDensity(k, cols)
        % Reconstruct a localization density on the SAME grid the refiner traced the
        % boundary over (30 nm bins, +/-1.2 um around the box centre). cols selects the
        % localizations: the CS member tracks (density the boundary was traced on ->
        % boundary aligns exactly) or ALL tracks in the cell (whole-cell context on the
        % IDENTICAL grid, so the boundary still lands correctly instead of on the
        % separately-rendered rho.tif raster which can be ~pixel-shifted). Both use one
        % reconstruction path, so toggling between them never moves the boundary.
        md=[];
        CS=csData.CS; Tr=csData.Tracks; ci=CS(k).cellIndex;
        % Centre the reconstruction on the REFINED site (refCenter) — the same frame the refiner
        % traced in — so the density lands on the boundary. The pick box (CS.boundaries) can be
        % huge / far from where you actually drew (over-association), which mis-placed the density.
        if isfield(CS,'refCenter') && ~isempty(CS(k).refCenter) && numel(CS(k).refCenter)==2 && all(isfinite(CS(k).refCenter))
            ctr = CS(k).refCenter(:)';
        else
            ctr = [mean(CS(k).boundaries.x) mean(CS(k).boundaries.y)];
        end
        X=[]; Y=[];
        for c=cols(:)'
            x=Tr(ci).matrix(:,c,2); y=Tr(ci).matrix(:,c,3); o=isfinite(x)&isfinite(y);
            X=[X;x(o)-ctr(1)]; Y=[Y;y(o)-ctr(2)]; %#ok<AGROW>
        end
        if isempty(X), return; end
        PixSize=30; ROI=[-40 40];
        % RAW smoothed localization-count density (NOT the 0-255 min/max rescale that
        % LocDensityFigGenerate bakes in) so the colour scale is CONTROLLABLE — a contrast
        % slider clips it, and it can be shown as a per-cell probability comparable across
        % cells. Same 30 nm bins + [2 2] gaussian as the density stage / refiner.
        xn=1000*X; yn=1000*Y; ok=isfinite(xn)&isfinite(yn);
        edges=PixSize*(ROI(1):ROI(2));
        NumLoc=histcounts2(xn(ok),yn(ok),edges,edges);
        D=imgaussfilt(NumLoc,[2 2])';                        % raw counts/bin, row=y col=x (Y-down)
        % image() XData/YData are the CENTRES of the corner pixels, so use the bin
        % CENTRE range (+/-1.185 um) not the bin-EDGE range (+/-1.2 um) — otherwise the
        % density is stretched ~1% (up to ~15 nm at the box edge) vs the boundary.
        hwc=(ROI(2)*PixSize - PixSize/2)/1000;               % 1.185 um
        % cell-wide localization total -> per-cell probability = counts/bin / cellTot
        % (normalises out each cell's expression / imaging depth, so sites are comparable).
        cellTot = nnz(isfinite(Tr(ci).matrix(:,:,2)) & isfinite(Tr(ci).matrix(:,:,3)));
        md=struct('raw',D,'pk',max(D(:)),'nTot',nnz(ok),'cellTot',cellTot, ...
            'xext',ctr(1)+[-hwc hwc],'yext',ctr(2)+[-hwc hwc]);
    end

    function rgb = densToRGB(D, clipFrac)
        % raw density -> turbo RGB, colour scale clipped at clipFrac*peak. clipFrac=1 is
        % the full local range (same look as the old auto-stretch / the whole-cell view);
        % lower clipFrac saturates the top so a faint site pops. Appearance only.
        pk = max(D(:)); if ~(pk>0), pk=1; end
        cmax = max(clipFrac,1e-3)*pk;
        idx = uint8(round(255*min(max(D,0)/cmax,1)));
        rgb = ind2rgb(idx, turbo(256));
    end

    function [f0,f1] = csFrameRange(k)
        CS=csData.CS; cols=csTouchingCols(k); if isempty(cols), cols=CS(k).tracks; end
        ci=CS(k).cellIndex; Tr=csData.Tracks; f0=Inf; f1=-Inf;
        for jj=1:numel(cols)
            fr=Tr(ci).matrix(:,cols(jj),1); fr=fr(isfinite(fr));
            if ~isempty(fr), f0=min(f0,min(fr)); f1=max(f1,max(fr)); end
        end
        if ~isfinite(f0), f0=0; f1=0; end
    end

    function drawCS(f)
        if isempty(csData) || isempty(csSelK) || ~isgraphics(csAx), return; end
        k=csSelK; CS=csData.CS; Tr=csData.Tracks; ci=CS(k).cellIndex; rc=CS(k).refCenter;
        cla(csAx); hold(csAx,'on');
        % --- ZOOM FIRST: a square view centred on the CS box. Setting the limits
        % before any drawing means even a mid-draw error still leaves the correct
        % zoom (a full-FOV blow-up otherwise), and the box-region of the overlay
        % is clipped to the view automatically.
        % Centre on the REFINED boundary when present — that's where YOU drew it, which can differ
        % from the auto-detected pick box (CS.boundaries). Fall back to the pick box if unrefined.
        if ~isempty(CS(k).refboundary) && numel(rc)==2 && all(isfinite(rc))
            bxa=CS(k).refboundary(:,1)/1000+rc(1); bya=CS(k).refboundary(:,2)/1000+rc(2);   % abs um
            cX=rc(1); cY=rc(2);                                       % centre exactly on YOUR drawn refCenter
            bh=max([abs(bxa-cX); abs(bya-cY); 0.001]);
        else
            xlo=min(CS(k).boundaries.x); xhi=max(CS(k).boundaries.x);
            ylo=min(CS(k).boundaries.y); yhi=max(CS(k).boundaries.y);
            cX=(xlo+xhi)/2; cY=(ylo+yhi)/2; bh=max(xhi-xlo,yhi-ylo)/2;
        end
        % boundary + generous context: floor ~1 um so the associated tracks are visible without
        % zooming (the site view is now scroll-zoom/pan-able for finer control).
        half = max(bh + 0.4, 1.0);
        if ~(half>0) || ~isfinite(half), half=1.2; end
        vx=[cX-half cX+half]; vy=[cY-half cY+half];
        pbaspect(csAx,[1 1 1]); daspect(csAx,'auto'); xlim(csAx,vx); ylim(csAx,vy);
        useWhole = ~isempty(chkCSwhole) && isgraphics(chkCSwhole) && chkCSwhole.Value;
        try
            % BOTH toggle states render through buildLocalDensity, which anchors its grid on the
            % refined centre with fixed ±40-bin edges -> the xext/yext are IDENTICAL for member vs
            % whole-cell (only the counts differ). So toggling swaps the density values in place and
            % never shifts the image (the old whole-cell path cropped the separately-rendered rho.tif
            % raster, whose pixel grid was a few pixels off the member grid -> the visible jitter).
            if useWhole
                if ~isequal(csWholeDensK, k) || isempty(csWholeDens)   % lazy: build once per CS, only when toggled on
                    try, csWholeDens = buildLocalDensity(k, 1:size(Tr(ci).matrix,2)); catch, csWholeDens=[]; end
                    csWholeDensK = k;
                end
                Dsrc = csWholeDens;
            else
                Dsrc = csMemDens;
            end
            if ~isempty(Dsrc) && isfield(Dsrc,'raw')
                if csDensProbMode && isfield(csData,'probScaleMax') && isscalar(csData.probScaleMax) && csData.probScaleMax>0 ...
                        && isfield(Dsrc,'cellTot') && Dsrc.cellTot>0
                    % PROBABILITY mode: per-cell PMF (density/bin ÷ cell total) on a scale SHARED
                    % across cells -> expression-invariant, comparable colours. Contrast scales it.
                    P    = Dsrc.raw / Dsrc.cellTot;
                    cmax = csData.probScaleMax * csDensClip;
                    idx  = uint8(round(255*min(max(P,0)/max(cmax,eps),1)));
                    rgbD = ind2rgb(idx, turbo(256));
                else
                    % per-site auto-stretch from raw counts with the contrast clip (csDensClip).
                    rgbD = densToRGB(Dsrc.raw, csDensClip);
                end
                image('Parent',csAx,'XData',Dsrc.xext,'YData',Dsrc.yext, ...
                    'CData',rgbD,'AlphaData',densAlpha,'HitTest','off');
            end
        catch, end
        try, drawCSoverlay(csAx, vx, vy); catch, end
        if ~isempty(CS(k).refboundary)   % a cancelled freehand can leave refboundary empty
            bx=CS(k).refboundary(:,1)/1000+rc(1); by=CS(k).refboundary(:,2)/1000+rc(2);   % absolute um
            plot(csAx,[bx;bx(1)],[by;by(1)],'-','Color',[1 1 1 0.85],'LineWidth',1.4,'HitTest','off');  % CS outline
        end
        % mark the CENTRE the radial plot measures distance from (refined refCenter, else the
        % auto-detected pick centre) so you can visually confirm it lines up with the density peak
        plot(csAx, cX, cY, '+', 'Color',[1 0 1], 'MarkerSize',13, 'LineWidth',1.6, 'HitTest','off');
        text(csAx, cX, cY, '  centre', 'Color',[1 0 1], 'FontSize',8, 'FontWeight','bold', ...
            'VerticalAlignment','bottom', 'HitTest','off', 'Clipping','on');
        % TRACKS: only those that TOUCH the refined boundary (the tracks truly
        % associated with this CS), clipped to the view so they don't sprawl.
        cols=csTouchingColsCached(k);   % cached per selection (drawCS is the playback hot path)
        % ALL SPOTS (like QC / Curate): every detection in THIS frame within the view —
        % small grey dots, orange when within a link radius of a member track's current
        % position (possible missed inclusion / crowding). tracked + untracked.
        if ~isempty(chkCSspots) && isgraphics(chkCSspots) && chkCSspots.Value ...
                && isfield(Tr,'allSpots') && ci>=1 && ci<=numel(Tr) && ~isempty(Tr(ci).allSpots)
            AS = Tr(ci).allSpots;
            inF = AS.FRAME==f & AS.X>=vx(1) & AS.X<=vx(2) & AS.Y>=vy(1) & AS.Y<=vy(2);
            ox=AS.X(inF); oy=AS.Y(inF); mcur=zeros(0,2);
            for jj=1:numel(cols)
                c=cols(jj); xx=Tr(ci).matrix(:,c,2); yy=Tr(ci).matrix(:,c,3); frc=Tr(ci).matrix(:,c,1);
                s=find(isfinite(xx)&isfinite(yy)&frc==f,1);
                if ~isempty(s), mcur(end+1,:)=[xx(s) yy(s)]; end %#ok<AGROW>
            end
            for q=1:numel(ox)
                near = ~isempty(mcur) && any(hypot(mcur(:,1)-ox(q), mcur(:,2)-oy(q)) <= 0.30);
                if near, sc=[0.91 0.42 0.14]; else, sc=[0.68 0.68 0.72]; end
                plot(csAx, ox(q), oy(q), '.', 'Color', sc, 'MarkerSize', 9, 'HitTest','off');
            end
        end
        % "all tracks": the OTHER box-member tracks (near the site but not inside the
        % boundary) drawn faint grey for context.
        if ~isempty(chkCSall) && isgraphics(chkCSall) && chkCSall.Value
            for c=setdiff(CS(k).tracks(:)', cols)
                x=Tr(ci).matrix(:,c,2); y=Tr(ci).matrix(:,c,3);
                inb=x>=vx(1)&x<=vx(2)&y>=vy(1)&y<=vy(2);
                if nnz(inb)>=2, xt=x; yt=y; xt(~inb)=NaN; yt(~inb)=NaN;
                    plot(csAx,xt,yt,'-','Color',[0.6 0.6 0.6 0.35],'LineWidth',0.5,'HitTest','off'); end
            end
        end
        er=0.15; ring=0.30; cmap=turbo(max(numel(cols),1));
        for jj=1:numel(cols)
            c=cols(jj); x=Tr(ci).matrix(:,c,2); y=Tr(ci).matrix(:,c,3); fr=Tr(ci).matrix(:,c,1);
            ok=isfinite(x)&isfinite(y); col=cmap(jj,:);
            inb = x>=vx(1) & x<=vx(2) & y>=vy(1) & y<=vy(2);       % inside the view box
            xt=x; yt=y; xt(~inb)=NaN; yt(~inb)=NaN;                % break the trail where it leaves
            past=ok & fr<=f; cur=ok & fr==f & inb;
            if nnz(past & inb)>=2, plot(csAx,xt(past),yt(past),'-','Color',[col 0.9],'LineWidth',1.2,'HitTest','off'); end
            if any(cur)
                cx=x(cur); cy=y(cur);
                drawQCcircle(csAx,cx(1),cy(1),er,  col,'-',1.2);
                drawQCcircle(csAx,cx(1),cy(1),ring,col,':',0.6);
                plot(csAx,cx(1),cy(1),'o','MarkerSize',6,'MarkerFaceColor',col,'MarkerEdgeColor','k','HitTest','off');
            end
        end
        % ISOLATED TRACK (clicked in the list): its trail grows to the live frame in bright
        % gold, on top of everything, so "click a track" animates that one track.
        if ~isempty(csIsoTrk) && csIsoTrk>=1 && csIsoTrk<=size(Tr(ci).matrix,2)
            c=csIsoTrk; x=Tr(ci).matrix(:,c,2); y=Tr(ci).matrix(:,c,3); fr=Tr(ci).matrix(:,c,1);
            ok=isfinite(x)&isfinite(y); past=ok & fr<=f; cur=ok & fr==f;
            if nnz(past)>=2, plot(csAx,x(past),y(past),'-','Color',[1 0.92 0],'LineWidth',2.5,'HitTest','off'); end
            if any(cur)
                cx=x(cur); cy=y(cur);
                plot(csAx,cx(1),cy(1),'o','MarkerSize',9,'MarkerFaceColor',[1 0.92 0],'MarkerEdgeColor','k','LineWidth',1.2,'HitTest','off');
            end
        end
        hold(csAx,'off'); pbaspect(csAx,[1 1 1]); xlim(csAx,vx); ylim(csAx,vy);   % re-assert the zoom
        % density-scale readout: the ABSOLUTE peak so "bright" is quantified, and the
        % per-cell probability (comparable across cells). Only when the member density shows.
        pkTxt='';
        if ~useWhole && ~isempty(csMemDens) && isfield(csMemDens,'pk') && csMemDens.pk>0
            pval = csMemDens.pk/max(csMemDens.cellTot,1);
            if csDensProbMode && isfield(csData,'probScaleMax') && isscalar(csData.probScaleMax) && csData.probScaleMax>0
                pkTxt = sprintf(' · peak p=%.1e  (shared scale max p=%.1e × %.0f%%)', ...
                    pval, csData.probScaleMax, 100*csDensClip);
            else
                pkTxt = sprintf(' · peak %.2g loc/bin (p=%.1e, clip %.0f%%)', csMemDens.pk, pval, 100*csDensClip);
            end
        end
        title(csAx,sprintf('CS %d · cell %d · %s · %d/%d tracks touch · frame %d · dwell %.3g s%s', ...
            CS(k).csID, ci, tern(cs_site_near(CS(k),'mito'),'MITO','non'), numel(cols), numel(CS(k).tracks), f, csData.dwell(k), pkTxt));
        drawnow limitrate;
    end

    function drawCSradial(k)
        % Bottom keep/discard panel. Default: radial concentration curve (cumulative % of the cell's
        % localizations within radius r of the site centre vs the uniform-density expectation — a steep
        % rise = a real, tight site; a curve hugging the reference = diffuse). Toggle: a histogram of
        % localizations per 30 nm bin across the whole cell (drawCellDensHist).
        if isempty(csData) || ~isgraphics(csAxRad) || isempty(k) || k<1 || k>numel(csData.CS), return; end
        if ~isempty(chkCSradHist) && isgraphics(chkCSradHist) && chkCSradHist.Value
            drawCellDensHist(k); return;
        end
        CS=csData.CS; Tr=csData.Tracks; ci=CS(k).cellIndex;
        if ci<1 || ci>numel(Tr) || ~isfield(Tr,'matrix') || isempty(Tr(ci).matrix), cla(csAxRad); return; end
        rc = CS(k).refCenter; refined = numel(rc)==2 && all(isfinite(rc));
        if ~refined, rc=[mean(CS(k).boundaries.x) mean(CS(k).boundaries.y)]; end   % fall back to the auto-detected pick centre
        Xa=Tr(ci).matrix(:,:,2); Ya=Tr(ci).matrix(:,:,3); o=isfinite(Xa)&isfinite(Ya);   % ALL cell locs (background represented)
        pct=NaN;
        if refined && isfield(CS,'probMass') && ~isempty(CS(k).probMass) && isfinite(CS(k).probMass), pct=100*CS(k).probMass; end
        try, cs_radial_plot(csAxRad, Xa(o)-rc(1), Ya(o)-rc(2), 1.2, pct, refined); catch, end
    end

    function drawCellDensHist(k)
        % Histogram of localizations per 30 nm bin across the WHOLE cell that owns this site — the
        % cell's density distribution (how many 30 nm bins hold 1, 2, 3, ... tracked localizations),
        % independent of the contact site. Occupied bins only (empty bins omitted, else the count-0
        % bar dwarfs the rest). Same 30 nm binning as the density stage / metrics.
        if ~isgraphics(csAxRad), return; end
        cla(csAxRad); set(csAxRad,'YScale','linear');
        CS=csData.CS; Tr=csData.Tracks; ci=CS(k).cellIndex;
        if ci<1 || ci>numel(Tr) || ~isfield(Tr,'matrix') || isempty(Tr(ci).matrix), title(csAxRad,'loc / 30 nm bin'); return; end
        Xc=Tr(ci).matrix(:,:,2); Yc=Tr(ci).matrix(:,:,3); ok=isfinite(Xc)&isfinite(Yc);
        Xc=Xc(ok); Yc=Yc(ok);
        if isempty(Xc), title(csAxRad,'loc / 30 nm bin'); return; end
        binUm=0.03; mg=0.2;                                  % 30 nm bins, 0.2 um margin (matches computeCSDensityMetrics)
        ex=(min(Xc)-mg):binUm:(max(Xc)+mg); ey=(min(Yc)-mg):binUm:(max(Yc)+mg);
        if numel(ex)<2 || numel(ey)<2, title(csAxRad,'loc / 30 nm bin'); return; end
        Hc=histcounts2(Xc,Yc,ex,ey); occ=Hc(Hc>=1);          % per-bin raw counts; keep occupied bins
        if isempty(occ), title(csAxRad,'loc / 30 nm bin'); return; end
        if max(occ) <= 30
            histogram(csAxRad, occ, 'BinMethod','integers','FaceColor',[0.30 0.55 0.85],'EdgeColor',[0.20 0.30 0.45]);
        else
            histogram(csAxRad, occ, 'NumBins',25,'FaceColor',[0.30 0.55 0.85],'EdgeColor',[0.20 0.30 0.45]);
        end
        set(csAxRad,'YScale','log');                         % counts-per-bin are heavily skewed (many 1-loc bins, few high)
        fnT=''; if isfield(Tr,'file') && ~isempty(Tr(ci).file), fnT=[' · ' Tr(ci).file]; end
        title(csAxRad, sprintf('loc / 30 nm bin%s  (%d occ. bins, max %d)', fnT, numel(occ), max(occ)),'FontSize',8);
        xlabel(csAxRad,'localizations per 30 nm bin'); ylabel(csAxRad,'# bins (log)'); box(csAxRad,'on');
    end

    function drawCSallPanel(k)
        % whole-cell overview: every track in the cell (faint), all contact-site
        % boundaries (white, numbered), with the SELECTED site + its touching tracks
        % highlighted — so you can orient the zoomed site within the whole cell.
        if isempty(csData) || ~isgraphics(axCSall), return; end
        CS=csData.CS; Tr=csData.Tracks; ci=CS(k).cellIndex; fov=local_fov();
        if ci<1 || ci>numel(Tr), return; end
        cla(axCSall); hold(axCSall,'on');
        % mito/structure underlay for the WHOLE cell (full FOV) — same overlay used per
        % site, so you can confirm it registers with the tracks/boundaries cell-wide.
        try, drawCSoverlay(axCSall, [0 fov], [0 fov], true); catch, end   % whole-cell mito, gamma-boosted so it's visible
        N=size(Tr(ci).matrix,2);
        for c=1:N
            x=Tr(ci).matrix(:,c,2); y=Tr(ci).matrix(:,c,3); ok=isfinite(x)&isfinite(y);
            if nnz(ok)>=2, plot(axCSall,x(ok),y(ok),'-','Color',[0.55 0.60 0.70 0.22],'LineWidth',0.3,'HitTest','off'); end
        end
        for q=find([CS.cellIndex]==ci)
            if isempty(CS(q).refboundary), continue; end
            rc=CS(q).refCenter; if numel(rc)~=2 || ~all(isfinite(rc)), continue; end   % malformed refCenter: skip this site, don't blank the whole panel
            bx=CS(q).refboundary(:,1)/1000+rc(1); by=CS(q).refboundary(:,2)/1000+rc(2);
            if q==k
                tc=csTouchingCols(k); cm=turbo(max(numel(tc),1));
                for jj=1:numel(tc)
                    c=tc(jj); x=Tr(ci).matrix(:,c,2); y=Tr(ci).matrix(:,c,3); ok=isfinite(x)&isfinite(y);
                    if nnz(ok)>=2, plot(axCSall,x(ok),y(ok),'-','Color',[cm(jj,:) 0.9],'LineWidth',1,'HitTest','off'); end
                end
                plot(axCSall,[bx;bx(1)],[by;by(1)],'-','Color',[0.95 0.20 0.15],'LineWidth',1.8,'HitTest','off');
            else
                % colour each non-selected boundary by its MITO FLAG so the classification reads at a
                % glance against the mito overlay: magenta = flagged mito, white = non-mito.
                mflag = cs_site_near(CS(q),'mito');
                if mflag, bcol=[1 0.35 1 0.9]; lw=1.4; else, bcol=[1 1 1 0.7]; lw=1; end
                plot(axCSall,[bx;bx(1)],[by;by(1)],'-','Color',bcol,'LineWidth',lw,'HitTest','off');
                text(axCSall,mean(bx),mean(by),num2str(CS(q).csID),'Color',[1 1 0.4],'FontSize',8, ...
                    'HorizontalAlignment','center','HitTest','off');
            end
        end
        hold(axCSall,'off'); pbaspect(axCSall,[1 1 1]); xlim(axCSall,[0 fov]); ylim(axCSall,[0 fov]);
        fnT=''; if isfield(Tr,'file') && ~isempty(Tr(ci).file), fnT=[' · ' Tr(ci).file]; end
        selMito = cs_site_near(CS(k),'mito');
        title(axCSall,sprintf('Whole cell%s · %d tracks · CS %d = %s   (magenta boundary = mito)', ...
            fnT, N, CS(k).csID, tern(selMito,'MITO','non-mito')),'FontSize',9);
        xlabel(axCSall,'x (µm)'); ylabel(axCSall,'y (µm)');
        drawnow limitrate;
    end

    function drawCSoverlay(ax, vx, vy, whole)
        if isempty(chkCSov) || ~isgraphics(chkCSov) || ~chkCSov.Value || isempty(csOverlayImg) || ~isgraphics(ax), return; end
        g=csOverlayImg; [Hh,Ww]=size(g); px=local_fov()/Ww;   % um per structure pixel (full FOV, square)
        if nargin>=3 && ~isempty(vx) && ~isempty(vy)
            cc=max(1,floor(vx(1)/px)):min(Ww,ceil(vx(2)/px));
            rr=max(1,floor(vy(1)/px)):min(Hh,ceil(vy(2)/px));
        else
            cc=1:Ww; rr=1:Hh;
        end
        if isempty(cc)||isempty(rr), return; end
        sub=g(rr,cc);
        % ABSOLUTE, cell-wide contrast: threshold the normalized MIP at a background/foreground level
        % computed ONCE from the WHOLE mito image (cached per cell), so the same pixel value looks the
        % same in every panel and at every zoom. This replaces the old per-crop imadjust, which
        % renormalized each zoomed window to its own full range and therefore turned faint background
        % at a NON-mito site into bright false "signal" that disagreed with the whole-cell overlay.
        t0 = csMitoBgLevel();
        val = min(1, max(0, sub - t0) / max(1 - t0, 1e-6));   % 0 at/below background, ramps to 1 at the brightest mito
        [hh,ww]=size(val);
        % whole-cell view gamma-lifts so faint-but-real mito still reads cell-wide; the site view stays
        % linear so empty background genuinely reads as background (no false magenta wash on non-mito CSs).
        if nargin>=4 && ~isempty(whole) && whole, a=min(1, val.^0.5); else, a=val; end
        image('Parent',ax,'XData',[cc(1) cc(end)]*px,'YData',[rr(1) rr(end)]*px, ...
            'CData',cat(3,val,zeros(hh,ww),val),'AlphaData',a,'HitTest','off');
    end

    function t = csMitoBgLevel()
        % Cell-wide mito background/foreground split (Otsu), cached per loaded cell (csOvCi) so it is
        % computed once, not on every playback-frame redraw. Below this level a pixel counts as
        % background (transparent); above it, as mito. Degenerate Otsu results fall back to a high
        % percentile so a flat/no-mito image is never painted solid.
        if ~isequal(csMitoBgCi, csOvCi) || isempty(csMitoBg)
            csMitoBgCi = csOvCi;
            if isempty(csOverlayImg)
                csMitoBg = 0;
            else
                try, lvl = graythresh(csOverlayImg); catch, lvl = []; end
                if isempty(lvl) || ~(lvl>0 && lvl<1)
                    try, lvl = prctile(csOverlayImg(:), 75); catch, lvl = 0.25; end
                end
                csMitoBg = max(0, min(0.95, lvl));
            end
        end
        t = csMitoBg;
    end

    function refreshCSov()
        % the mito overlay toggle affects BOTH the zoomed site panel and the whole-cell
        % panel, so redraw both (whole-cell is otherwise static per selection).
        drawCS(csPlayFrame);
        if ~isempty(csSelK), try, drawCSallPanel(csSelK); catch, end, end
    end

    function redrawCSsite()
        % nested (NOT an anonymous @(s,e) drawCS(csPlayFrame), which would freeze
        % csPlayFrame=0 at build time) so toggles read the LIVE playback frame and
        % don't wipe the track trails back to frame 0.
        drawCS(csPlayFrame);
    end

    function setDensAlpha(v)
        % shared density-background opacity for the CS Results site panel and the Dwell
        % CS-frame panel; keep both sliders in sync and redraw whatever is showing.
        densAlpha = max(0,min(1,v));
        if ~isempty(sldDensCS) && isgraphics(sldDensCS), sldDensCS.Value=densAlpha; end
        if ~isempty(sldDensDw) && isgraphics(sldDensDw), sldDensDw.Value=densAlpha; end
        if ~isempty(csSelK) && isgraphics(csAx), drawCS(csPlayFrame); end
        if ~isempty(dwSel) && isgraphics(axDwSpace), drawDwellFrame(min(dwIdx,numel(dwSel.idxList))); end
    end

    function setDensContrast(v)
        % contrast for the contact-site density: clip the colour scale at v*peak. Re-maps
        % the cached raw density live (no recompute), so it never moves the boundary.
        csDensClip = max(0.05, min(1, v));
        if ~isempty(csSelK) && isgraphics(csAx), drawCS(csPlayFrame); end
    end

    function toggleProbDisp()
        csDensProbMode = ~isempty(chkCSprobDisp) && isgraphics(chkCSprobDisp) && chkCSprobDisp.Value;
        if ~isempty(csSelK) && isgraphics(csAx), drawCS(csPlayFrame); end
    end

    function onCSPlay()
        if isempty(csData) || isempty(csSelK), return; end
        csIsoTrk = [];             % ▶ Play shows the whole site (no single-track isolation)
        startCSplay(csFrameMin);
    end

    function startCSplay(f0)
        if isempty(csData) || isempty(csSelK), return; end
        stopQCplay(); playMode='cs'; csPlayFrame=f0;
        drawCS(csPlayFrame);
        qcTimer=timer('ExecutionMode','fixedRate','Period',0.08,'BusyMode','drop','TimerFcn',@(~,~) qcAdvance());
        start(qcTimer);
    end

    function csAdvance()
        if ~isgraphics(csAx) || isempty(csData) || isempty(csSelK), stopQCplay(); return; end
        csPlayFrame = csPlayFrame + 1;
        if csPlayFrame > csFrameMax, csPlayFrame = csFrameMin; end
        drawCS(csPlayFrame);
    end

    function onCSToggleMito()
        if isempty(csData) || isempty(csSelK), return; end
        k=csSelK;
        csData.CS(k) = cs_site_set_near(csData.CS(k), 'mito', ~cs_site_near(csData.CS(k),'mito'));
        d=csTable.Data; d{k,4}=tern(cs_site_near(csData.CS(k),'mito'),'mito','non'); csTable.Data=d;   % 'mito' is col 4 now
        drawCS(csPlayFrame); try, drawCSallPanel(k); catch, end   % whole-cell boundary colour depends on MitoFlag
        % Dwell + Compare both group/label by MitoFlag -> invalidate so they regroup on next open.
        dwellData=[]; cmpData=[];
        if ~isempty(lDwell) && isgraphics(lDwell), lDwell.Text='CS classification changed — press Compute to refresh the dwell results.'; end
        try
            if isfield(csData,'anaDir') && ~isempty(csData.anaDir), ad=csData.anaDir; else, ad=getAnalysisDir(); end
            CS=csData.CS; save(fullfile(ad,'CS_final.mat'),'CS'); %#ok<NASGU>
            say('CS %d -> %s; CS_final.mat re-saved', csData.CS(k).csID, tern(cs_site_near(csData.CS(k),'mito'),'mito','non'));
        catch ME, say('CS_final.mat save failed: %s', ME.message); end
    end

    function onCSDelete()
        % Remove the selected contact site from CS_final.mat (post-hoc curation: a picked
        % site that isn't a real contact site). Re-saves, then reloads so the table, dwell
        % results and panels all rebuild consistently from the trimmed file.
        if isempty(csData) || isempty(csSelK), return; end
        k=csSelK; CS=csData.CS; if k<1 || k>numel(CS), return; end
        sel = uiconfirm(fig, sprintf(['Delete contact site CS %d (cell %d)?\n\nThis removes it from ' ...
            'CS_final.mat. It stays gone unless you re-run the pipeline. Re-open the Dwell tab and press ' ...
            'Compute to refresh those results.'], ...
            CS(k).csID, CS(k).cellIndex), 'Delete contact site', ...
            'Options',{'Delete','Cancel'}, 'DefaultOption',2, 'CancelOption',2, 'Icon','warning');
        if ~strcmp(sel,'Delete'), return; end
        stopQCplay();
        delID = CS(k).csID; delCell = CS(k).cellIndex; CS(k) = [];   % drop it
        if isfield(csData,'anaDir') && ~isempty(csData.anaDir), ad=csData.anaDir; else, ad=getAnalysisDir(); end
        try
            save(fullfile(ad,'CS_final.mat'),'CS'); %#ok<NASGU>
        catch ME
            uialert(fig, ['Could not save CS_final.mat: ' ME.message], 'Delete failed'); return;
        end
        say('Deleted CS %d (cell %d); %d contact sites remain. CS_final.mat re-saved.', delID, delCell, numel(CS));
        csSelK = [];
        loadCSresults();   % rebuild table + dwell + panels from the trimmed CS_final.mat
        % the Dwell + Compare tabs cache their own copies — invalidate both so neither shows the deleted site
        dwellData = []; cmpData = [];
        if ~isempty(lDwell) && isgraphics(lDwell)
            lDwell.Text = 'A contact site was deleted — press Compute to refresh the dwell results.';
        end
    end

    function onCSpickOverlay()
        [fn,pth]=uigetfile({'*.tif;*.tiff','TIFF images'},'Pick a mito / ER structure image');
        if isequal(fn,0), return; end
        try
            fp=fullfile(pth,fn); info=imfinfo(fp); im=imread(fp,1);
            for kk=2:numel(info), im=max(im,imread(fp,kk)); end
            if size(im,3)==3, g=im2double(rgb2gray(im)); else, g=im2double(im); end
            mx=max(g(:)); if mx>0, g=g/mx; end
            csOverlayImg=g; if ~isempty(chkCSov), chkCSov.Value=true; end
            refreshCSov();
        catch ME, say('overlay load failed: %s',ME.message); end
    end

    function onQCPlay()
        if isempty(QCstate) || ~isfield(QCstate,'selXY') || isempty(QCstate.selXY), return; end
        stopQCplay(); playMode='qc';
        QCstate.playIdx = 1;
        qcTimer = timer('ExecutionMode','fixedRate','Period',0.08,'BusyMode','drop', ...
            'TimerFcn',@(~,~) qcAdvance());
        start(qcTimer);
    end
    function onQCPause(), stopQCplay(); end
    function stopQCplay()
        if ~isempty(qcTimer) && isvalid(qcTimer), stop(qcTimer); delete(qcTimer); end
        qcTimer = [];
    end
    function qcAdvance()
        try
            if strcmp(playMode,'cs'), csAdvance(); return; end   % CS Results playback
            if ~isgraphics(axSel) || isempty(QCstate) || ~isfield(QCstate,'selXY') || isempty(QCstate.selXY)
                stopQCplay(); return;
            end
            L = size(QCstate.selXY,1);
            QCstate.playIdx = QCstate.playIdx + 1;
            if QCstate.playIdx > L, QCstate.playIdx = 1; end
            drawSel(QCstate.playIdx);
        catch
            stopQCplay();
        end
    end
    function onAppClose()
        stopQCplay(); stopDwellPlay();
        delete(fig);
    end

    function dt = local_dt()
        dt = 0.020064;
        cf = fullfile(getAnalysisDir(),'cs_calib.mat');
        if isfile(cf)
            try Lc=load(cf);
                if isfield(Lc,'calib')&&isfield(Lc.calib,'dt_s')&&isfinite(Lc.calib.dt_s)&&Lc.calib.dt_s>0
                    dt=Lc.calib.dt_s;
                end
            catch, end
        end
    end

    function onSendWorkspace()
        ana = getAnalysisDir(); sent={};
        if isfile(fullfile(ana,'TrackStruct.mat')), L=load(fullfile(ana,'TrackStruct.mat'));
            if isfield(L,'Tracks'), assignin('base','Tracks',L.Tracks); sent{end+1}='Tracks'; end, end
        if isfile(fullfile(ana,'Tracks_final.mat')), L=load(fullfile(ana,'Tracks_final.mat'));
            if isfield(L,'Tracks'), assignin('base','Tracks_final',L.Tracks); sent{end+1}='Tracks_final'; end, end
        if isfile(fullfile(ana,'CS_final.mat')), L=load(fullfile(ana,'CS_final.mat'));
            if isfield(L,'CS'), assignin('base','CS',L.CS); sent{end+1}='CS'; end, end
        if isempty(sent), say('nothing to send — Build first.');
        else, say('sent to base workspace: %s', strjoin(sent,', ')); end
    end

    function onSetup(~,~)
        if ~needProject(), return; end
        analysisDir = getAnalysisDir();
        if ~isfile(fullfile(analysisDir,'TrackStruct.mat')) && ~isfile(fullfile(analysisDir,'Tracks.mat'))
            uialert(fig,'Build the Track struct (tab 3) first.','No TrackStruct'); return; end
        suffix = regexp(ddSuffix.Value,'^\S+','match','once');
        args = {analysisDir,'MitoSuffix',suffix};
        if ~isempty(S.mito),   args=[args {'Mito',S.mito}]; end
        if ~isempty(S.maxint), args=[args {'MaxInt',S.maxint}]; end
        busy(true);
        try
            call = ['setup_run_folder(' argstr(args) ');']; say('%s',call);
            say('%s', strtrim(evalc(call))); say('SETUP complete.');
        catch ME, say('ERROR: %s',ME.message); uialert(fig,ME.message,'setup_run_folder failed'); end
        busy(false); refreshLamps(); refreshScale();
    end

    function onRunCS(~,~)
        if ~needProject(), return; end
        stopAfter = ddStop.Value; if strcmp(stopAfter,'(next gate)'), stopAfter=''; end
        startStage = ddStart.Value;
        % GUARD: re-running an early stage over existing REFINED results can re-pick / re-map and
        % OVERWRITE them. "Run / Resume" defaults to 'density' (a full run), so warn first.
        earlyStages = {'density','locdens','quickplot','csid','mapper','part2','snaprename'};
        if any(strcmp(startStage,earlyStages)) && haveRefinedResults()
            d = uiconfirm(fig, sprintf(['This project already has refined results (analysis/CS_final.mat). ' ...
                'Starting at "%s" re-generates earlier stages and can OVERWRITE your picked / refined ' ...
                'contact sites. To CONTINUE where you left off instead, set the start stage to "builder" ' ...
                '(just rebuild outputs) or "refiner" (re-open refining). Re-run from "%s" anyway?'], ...
                startStage, startStage), 'Overwrite refined results?', ...
                'Options',{'Cancel (keep my results)', sprintf('Re-run from "%s"',startStage)}, ...
                'DefaultOption',1,'CancelOption',1,'Icon','warning');
            if ~startsWith(d,'Re-run'), say('Run cancelled — refined results kept.'); return; end
        end
        runCSstages(startStage, stopAfter);
    end
    function tf = haveRefinedResults()
        ana=getAnalysisDir();
        tf = exist(fullfile(ana,'CS_final.mat'),'file')==2 || ~isempty(dir(fullfile(ana,'CSdata','*_CSdata.mat')));
    end

    function onCSReRefine()
        % Refine a contact-site boundary. Three routes:
        %  1. "Adjust boundary here"  -> lightweight in-place re-trace on the CS Results density
        %     panel (refineBoundaryInPlace); recomputes dwell / size / p / inside-tracks and
        %     re-syncs every tab WITHOUT re-running the pipeline. Keeps manual add/remove edits.
        %  2/3. "Re-run refiner"       -> the heavy path: re-open the freehand refiner and rebuild
        %     CS_final.mat (refiner -> ensemble -> builder -> accum) for this site or the whole cell.
        if ~needProject(), return; end
        if isempty(csData) || isempty(csData.CS)
            say('Nothing to refine yet — run ContactSites first.'); return;
        end
        if ~isempty(csSelK) && csSelK>=1 && csSelK<=numel(csData.CS)
            selID = csData.CS(csSelK).csID; selCell = csData.CS(csSelK).cellIndex;
            optHere = sprintf('Adjust boundary here (CS %d)',selID);
            d = uiconfirm(fig, sprintf([...
                '"%s" — re-trace the outline right here on the density panel (fast; recomputes dwell, ' ...
                'size, p and which tracks fall inside; keeps your manual track edits).\n\n' ...
                '"Re-run refiner" re-opens the full freehand refiner and rebuilds CS_final.mat ' ...
                '(heavier, and DISCARDS manual add/remove curation).'], optHere), ...
                'Refine contact site', ...
                'Options',{optHere,'Re-run refiner — this CS','Re-run refiner — all CS','Cancel'}, ...
                'DefaultOption',1,'CancelOption',4);
            if     strcmp(d,optHere),                       refineBoundaryInPlace(csSelK);
            elseif strcmp(d,'Re-run refiner — this CS'),    runCSstages('refiner','builder',selID,selCell);
            elseif strcmp(d,'Re-run refiner — all CS'),     runCSstages('refiner','builder',[],[]);
            end
        else
            d = uiconfirm(fig, ['Select a contact site in the list to adjust just that one. ' ...
                'Otherwise re-run the full freehand refiner on EVERY site in the cell?'], 'Refine contact sites', ...
                'Options',{'Re-run refiner — all CS','Cancel'},'DefaultOption',2,'CancelOption',2);
            if strcmp(d,'Re-run refiner — all CS'), runCSstages('refiner','builder',[],[]); end
        end
    end

    function refineBoundaryInPlace(k)
        % In-place boundary edit on the CS Results density panel (csAx). Re-traces the refined
        % outline WITHOUT re-running the pipeline. refCentre and the per-track membership pool
        % (tracks / CSmatrix / CSvec / tracksCCids) stay FIXED, so nothing can desync; every
        % boundary-derived quantity — dwell, area, p/enrich, which tracks fall inside — is
        % recomputed from the new outline and persisted to CS_final.mat, then Dwell + Compare
        % re-sync. NB the csAx view (+/-1.185um about refCentre) sits well inside the +/-5.4um
        % membership box, so any track you can enclose is already a candidate -> no track goes
        % silently missing. To capture a track OUTSIDE that pool, use Add track.
        if isempty(csData) || isempty(csData.CS) || k<1 || k>numel(csData.CS) || ~isgraphics(csAx), return; end
        rc = csData.CS(k).refCenter;
        if numel(rc)~=2 || ~all(isfinite(rc))
            uialert(fig, sprintf(['CS %d has no valid refined centre yet — run the freehand refiner once ' ...
                '("Re-run refiner") before adjusting it here.'], csData.CS(k).csID), 'Cannot adjust boundary'); return;
        end
        if csRefining, say('A boundary edit is already in progress — finish or cancel it first.'); return; end
        csRefining = true;
        guard = onCleanup(@() endRefine());   %#ok<NASGU>  resets the flag + re-enables the control bar on ANY exit path
        selID = csData.CS(k).csID; selCell = csData.CS(k).cellIndex; nPool = numel(csData.CS(k).tracks);
        stopQCplay(); setCSctlEnable(false);   % lock the control bar so no conflicting action fires mid-draw
        % csAx must hold exactly ONE image while drawing: drawfreehand/drawpolygon call
        % getimage(csAx) internally, which errors with >1 image. The structure overlay is a 2nd
        % image, so turn it off for the draw (drawCSoverlay is gated on chkCSov.Value).
        hadOverlay = ~isempty(chkCSov) && isgraphics(chkCSov) && chkCSov.Value;
        if hadOverlay, chkCSov.Value=false; end
        drawCS(csPlayFrame);                          % clean density + tracks + current outline, centred on refCentre
        seed = [];                                    % seed a draggable polygon from the CURRENT boundary -> ADJUST, not redraw
        if ~isempty(csData.CS(k).refboundary) && size(csData.CS(k).refboundary,1)>=3
            seed = [csData.CS(k).refboundary(:,1)/1000+rc(1), csData.CS(k).refboundary(:,2)/1000+rc(2)];   % abs um
            seed = reduceBoundary(seed);
        end
        if ~isempty(lRes) && isgraphics(lRes)
            lRes.Text = tern(isempty(seed), ...
                'Draw the new boundary on the density panel (press-drag a freehand loop); release to finish, or press Esc to cancel.', ...
                'Adjust the boundary: DRAG vertices, right-click a vertex to add/delete, DOUBLE-CLICK to finish — or press Esc to cancel.');
        end
        drawnow;
        roi = [];
        try
            if isempty(seed)
                roi = drawfreehand(csAx,'Color',[1 0.85 0.1],'FaceAlpha',0.06,'LineWidth',1.5);   % blocks until stroke released
            else
                roi = drawpolygon(csAx,'Position',seed,'Color',[1 0.85 0.1],'FaceAlpha',0.06,'LineWidth',1.5);
                if isvalid(roi), wait(roi); end        % let the user drag vertices, double-click to finish
            end
        catch ME
            say('Boundary edit cancelled (%s).', ME.message);
        end
        if isempty(roi) || ~isvalid(roi) || isempty(roi.Position) || size(roi.Position,1)<3
            if ~isempty(roi) && isvalid(roi), delete(roi); end
            if hadOverlay, chkCSov.Value=true; end
            if ~isempty(lRes)&&isgraphics(lRes), lRes.Text='Boundary unchanged.'; end
            drawCS(csPlayFrame); return;
        end
        P = roi.Position; delete(roi);
        newRB = [(P(:,1)-rc(1))*1000, (P(:,2)-rc(2))*1000];   % nm rel refCentre (the frame the refiner stores)
        % preview the effect BEFORE committing
        [nTouchNew,nInNew,nTot] = previewBoundary(k, P(:,1), P(:,2));
        arNew = csDims(newRB);
        d = uiconfirm(fig, sprintf(['Apply this boundary to CS %d?\n\n' ...
            '%d of %d member tracks now fall inside  ·  %d of %d localizations inside  ·  area %.3f um^2.\n\n' ...
            'This rewrites CS_final.mat and updates CS Results now; the Dwell and Compare tabs refresh ' ...
            'when you next open them. refCentre and the track pool are unchanged — only the outline ' ...
            '(and what counts as inside) moves.'], ...
            selID, nTouchNew, nPool, nInNew, nTot, arNew), ...
            'Apply refined boundary', 'Options',{'Apply & re-sync','Cancel'}, ...
            'DefaultOption',1,'CancelOption',2,'Icon','question');
        if ~strcmp(d,'Apply & re-sync')
            if hadOverlay, chkCSov.Value=true; end
            if ~isempty(lRes)&&isgraphics(lRes), lRes.Text='Boundary edit cancelled — nothing saved.'; end
            drawCS(csPlayFrame); return;
        end
        % ---- COMMIT: single source of truth = CS_final.mat on disk. Load fresh, set ONLY
        % refboundary on the matching site, save, invalidate every cache, reload, re-select. ----
        ad = csData.anaDir; if isempty(ad), ad=getAnalysisDir(); end
        f = fullfile(ad,'CS_final.mat');
        try, Lc = load(f); catch ME, uialert(fig,['Could not read CS_final.mat: ' ME.message],'Save failed'); return; end
        if ~isfield(Lc,'CS') || isempty(Lc.CS), uialert(fig,'CS_final.mat has no contact sites.','Save failed'); return; end
        CS = Lc.CS;
        kd = find([CS.cellIndex]==selCell & [CS.csID]==selID, 1);
        if isempty(kd), uialert(fig,'Could not find this contact site on disk (was it deleted?).','Save failed'); return; end
        CS(kd).refboundary = newRB;
        try, save(f,'CS'); catch ME, uialert(fig,['CS_final.mat save FAILED: ' ME.message],'Save failed'); return; end %#ok<NASGU>
        csData=[]; dwellData=[]; cmpData=[];          % invalidate EVERY cache so all tabs re-read the edited file
        loadCSresults();                              % rebuild table + densMetrics + dwell from disk
        if hadOverlay && ~isempty(chkCSov) && isgraphics(chkCSov), chkCSov.Value=true; end   % always restore the overlay we forced off for the draw
        if ~isempty(csData) && ~isempty(csData.CS)
            k2 = find([csData.CS.cellIndex]==selCell & [csData.CS.csID]==selID, 1);
            if ~isempty(k2)
                try, csTable.Selection=[k2 1]; catch, end
                onCSselect(struct('Indices',[k2 1]));
            end
        end
        try, updateLoadedInfo(); catch, end
        say(['CS %d boundary refined in place — CS_final.mat re-saved; dwell / area / p / inside-tracks recomputed. ' ...
            'CS Results is updated now; the Dwell and Compare tabs refresh automatically when you next open them.'], selID);
    end

    function [nTouch,nIn,nTot] = previewBoundary(k, bx, by)
        % member tracks (and their localizations) that fall inside a candidate boundary (abs um)
        CS=csData.CS; Tr=csData.Tracks; ci=CS(k).cellIndex; cols=CS(k).tracks(:)';
        nTouch=0; nIn=0; nTot=0;
        if ci<1 || ci>numel(Tr), return; end
        for c=cols
            x=Tr(ci).matrix(:,c,2); y=Tr(ci).matrix(:,c,3); o=isfinite(x)&isfinite(y);
            x=x(o); y=y(o); if isempty(x), continue; end
            nTot=nTot+numel(x); insd=inpolygon(x,y,bx,by);
            if any(insd), nTouch=nTouch+1; end
            nIn=nIn+nnz(insd);
        end
    end

    function P = reduceBoundary(P)
        % keep a seeded boundary draggable: cap the vertex count so drawpolygon shows a
        % manageable number of handles (~40) while preserving the outline shape. reducepoly
        % needs Image Processing Toolbox (present — the refiner uses drawfreehand); fall back
        % to uniform subsampling if it is unavailable or under-reduces.
        if size(P,1)<=40, return; end
        try
            Q = reducepoly(P, 0.008);
            if size(Q,1)>=8, P=Q; end
        catch, end
        if size(P,1)>40
            idx = unique(round(linspace(1,size(P,1),40)));
            P = P(idx,:);
        end
    end

    function endRefine()
        % onCleanup target for refineBoundaryInPlace: guaranteed to run on every exit path
        % (normal finish, cancel, or error) so the re-entrancy flag and the control bar are
        % always restored — never left locked.
        csRefining = false;
        setCSctlEnable(true);
    end

    function setCSctlEnable(on)
        % enable/disable the CS Results control bar during a modal boundary draw so the user
        % cannot launch a conflicting action (Play, Delete CS, another Refine, tab reload) mid-draw.
        if isempty(resCtl) || ~isgraphics(resCtl), return; end
        st = tern(on,'on','off'); kids = resCtl.Children;
        for h = 1:numel(kids)
            if isequal(kids(h),lRes), continue; end   % keep the status/instruction label readable during the draw
            try, if isprop(kids(h),'Enable'), kids(h).Enable = st; end, catch, end
        end
    end

    function runCSstages(startStage, stopAfter, onlyCS, onlyCell)
        if nargin<3, onlyCS=[]; end
        if nargin<4, onlyCell=[]; end
        % Re-entrancy guard: a ContactSites run is interactive and BLOCKS this
        % callback at the picker/refiner's uiwait. A second Run click there would
        % re-enter and delete the live picking UI, corrupting output.
        if csRunning
            say('A ContactSites run is already in progress — ignoring this Run click.');
            return;
        end
        csRunning = true; bRun.Enable = 'off';
        analysisDir = getAnalysisDir();
        % UIParent = the Contact Sites tab, so cs_identify/cs_refine render there
        % (a graphics handle can't be stringified, so call with argsC{:}).
        argsC = {analysisDir,'StartStage',startStage,'JBM',logical(cbJBM.Value), ...
                 'MitoOnly',logical(cbMito.Value),'OnlyCS',onlyCS,'OnlyCell',onlyCell, ...
                 'SuitePath',S.suitePath,'UIParent',tCS,'ProgressFcn',@onCSprogress};
        % pass the Experiment tab's mito folder + {prefix} pattern so the picker auto-loads
        % each cell's mito overlay (same source as qcCellMitoPath), no manual "Load mito…".
        mdir=''; mpat='{prefix}_mito_mip.tif'; mstrip='_spt\d+'; edir=''; epat='{prefix}_er_mip.tif';
        if ~isempty(eExMito)    && isgraphics(eExMito),    mdir=eExMito.Value; end
        if ~isempty(eExMitoPat) && isgraphics(eExMitoPat), mpat=strtrim(eExMitoPat.Value); end
        if ~isempty(eExPrefix)  && isgraphics(eExPrefix),  mstrip=eExPrefix.Value; end
        if ~isempty(eExEr)      && isgraphics(eExEr),      edir=eExEr.Value; end
        if ~isempty(eExErPat)   && isgraphics(eExErPat),   epat=strtrim(eExErPat.Value); end
        argsC=[argsC {'MitoDir',mdir,'MitoPat',mpat,'MitoStrip',mstrip,'ErDir',edir,'ErPat',epat}];
        % Session file selection (Experiment tab "work" ticks): the picker only opens these cells.
        % Empty = all cells (no subset chosen), so a normal run is unaffected.
        if ~isempty(exptCells) && isfield(exptCells,'work')
            wmask = arrayfun(@(c) ~isfield(c,'work') || isempty(c.work) || logical(c.work), exptCells);
            if ~all(wmask)
                incFiles = {exptCells(wmask).name};
                argsC=[argsC {'IncludeFiles',incFiles}];
                say('Session selection: picking %d of %d cell(s).', numel(incFiles), numel(exptCells));
            end
        end
        % which TrackStruct .mat to run on (named build like Day1.mat, or a combined TrackStruct.mat)
        if ~isempty(ddTsFile) && isgraphics(ddTsFile) && ~isempty(ddTsFile.Value)
            tsRun = fullfile(analysisDir, ddTsFile.Value);
            if exist(tsRun,'file')==2, argsC=[argsC {'TrackStructFile',tsRun}]; say('Run input: %s', ddTsFile.Value); end
        end
        % skip the slow Excel/reference-image export (accum) unless the user wants it -> CS Results opens after builder
        if ~isempty(cbAccum) && isgraphics(cbAccum) && ~cbAccum.Value && (isempty(stopAfter) || strcmp(stopAfter,'accum'))
            stopAfter='builder'; say('Excel/reference-image export OFF — CS Results will open right after CS_final.mat is built.');
        end
        % Iterative re-refine (StartStage=refiner, stop at builder): only CS_final.mat needs to
        % rebuild for Tabs 7/8 to update. The accum re-renders ~9 images for EVERY site (not just
        % the one you refined), so running it on each tweak is what makes 6->7 crawl on hundreds of
        % sites. Skip it here; regenerate the QC images/Excel once at the end via a full Run with
        % "Excel + reference images" ticked.
        if strcmpi(startStage,'refiner') && strcmpi(stopAfter,'builder')
            say('Re-refine: stopping after CS_final.mat — skipping the per-site image/Excel export (run the full pipeline with "Excel + reference images" ticked to regenerate those once you''re done refining).');
        end
        if ~isempty(stopAfter), argsC=[argsC {'StopAfter',stopAfter}]; end
        csRunT0=tic; csPrevKey=''; csLastTic=tic; csAutoElapsed=0; csAutoDone=0;   % reset the live timer
        busy(true);
        csPlaceholder('Running… the picker / refiner will appear here when their stage is reached.');
        tg.SelectedTab = tCS;
        if exist('cs_preflight','file')==2
            try, say('%s', strtrim(evalc(sprintf('cs_preflight(''%s'',''Stage'',''%s'');',analysisDir,startStage))));
            catch ME, say('preflight skipped: %s',ME.message); end
        end
        % Capture per-stage progress via diary so it survives a late-stage error
        % (a single trailing evalc would discard everything on exception).
        logFile = [tempname '.log'];
        say('run_contactsite_analysis(%s, StartStage=%s, JBM=%d, MitoOnly=%d, UIParent=Contact Sites tab)', ...
            analysisDir, startStage, logical(cbJBM.Value), logical(cbMito.Value));
        diary(logFile);
        try
            run_contactsite_analysis(argsC{:});   % argsC{1} IS analysisDir (positional workDir)
            diary('off');
            if isfile(logFile), say('%s', strtrim(fileread(logFile))); delete(logFile); end
            try, loadCSresults(); tg.SelectedTab=tRes; catch MEr, say('results view skipped: %s',MEr.message); end
        catch ME
            diary('off');
            if isfile(logFile), say('%s', strtrim(fileread(logFile))); delete(logFile); end
            say('ERROR: %s',ME.message); uialert(fig,ME.message,'run_contactsite_analysis failed');
        end
        csRunning = false; if isvalid(bRun), bRun.Enable = 'on'; end
        if ~isempty(lProg) && isgraphics(lProg)
            lProg.Text = sprintf('✓ finished in %s', fmtDur(toc(csRunT0))); lProg.FontColor=[0.2 0.5 0.3];
        end
        busy(false); refreshLamps(); refreshScale();
        try, figure(fig); catch, end   % MATLAB console often grabs focus during the run; restore the app window
    end

    function onCSprogress(k, N, key, ~, ~)
        % live per-stage feedback (runs between stages; the UI is frozen DURING a
        % stage since MATLAB is single-threaded, so the glyph steps per stage).
        el = toc(csRunT0);
        prevKey = csPrevKey;
        if ~isempty(csPrevKey) && ~any(strcmp(csPrevKey,{'csid','refiner'}))
            csAutoElapsed = csAutoElapsed + toc(csLastTic); csAutoDone = csAutoDone + 1;   % time the prev auto stage
        end
        csPrevKey = key; csLastTic = tic;
        interactive = any(strcmp(key,{'csid','refiner'}));
        % Just left the refiner -> the rest (ensemble/builder/accum) runs with the UI
        % frozen. Replace the refiner with a clear "building results" panel so the long
        % gap before CS Results isn't a blank/stale screen, and pull the app forward.
        if strcmp(prevKey,'refiner') && ~interactive, csBuildingPanel(); end
        if interactive, try, figure(fig); catch, end, end   % MATLAB console can steal focus; bring the app back when input is needed
        gly = {'⠋','⠙','⠹','⠸','⠼','⠴','⠦','⠧','⠇','⠏'}; g = gly{mod(k,numel(gly))+1};
        if ~isempty(lProg) && isgraphics(lProg)
            if interactive
                lProg.Text = sprintf('%s  [%d/%d] %s — waiting for your input…', g,k,N,key);
                lProg.FontColor = [0.75 0.45 0.05];
            else
                eta = '';
                if csAutoDone>=1, eta = sprintf('  ·  ~%s left', fmtDur((csAutoElapsed/csAutoDone)*max(0,N-k))); end
                lProg.Text = sprintf('%s  [%d/%d] %s — %s elapsed%s', g,k,N,key,fmtDur(el),eta);
                lProg.FontColor = [0.2 0.5 0.3];
            end
        end
        say('▶ [%d/%d] %s%s', k, N, csStageLabel(key), tern(interactive,'  — your input needed',''));
        if strcmp(key,'accum')
            say('   Excel table + per-CS reference images (final export). CS_final.mat is already built — the UI is frozen only while this writes; CS Results opens when it finishes.');
        end
        drawnow;
    end

    function s = csStageLabel(key)   % human-readable stage names for the log / progress line
        switch key
            case 'density',    s='density maps';
            case 'locdens',    s='localization-density tiffs';
            case 'quickplot',  s='track QC overlays';
            case 'csid',       s='contact-site picking';
            case 'mapper',     s='mapping contact sites to tracks';
            case 'part2',      s='per-track metrics';
            case 'snaprename', s='snapshot rename';
            case 'refiner',    s='boundary refinement';
            case 'ensemble',   s='ensemble diffusion';
            case 'builder',    s='building CS_final.mat';
            case 'accum',      s='writing Excel + reference images';
            otherwise,         s=key;
        end
    end

    function s = fmtDur(t)
        t = max(0,round(t));
        if t<60, s=sprintf('%ds',t); else, s=sprintf('%dm %02ds',floor(t/60),mod(t,60)); end
    end

    % ---- Dwell & labels: automatic dwell = time a track spends INSIDE the refined boundary ----
    function loadDwell()
        if ~needProject(), return; end
        try, dwellData = computeDwell();
        catch ME, if ~isempty(lDwell), lDwell.Text=['Compute failed: ' ME.message]; end, return; end
        if isempty(dwellData) || isempty(dwellData.CS)
            if ~isempty(lDwell), lDwell.Text='No refined contact sites — run/refine ContactSites first.'; end
            return;
        end
        drawDwellDist(); fillDwellTable();
        nAt = 0; if ~isempty(dwellData.rows), nAt = nnz([dwellData.rows{:,9}]); end
        lDwell.Text = sprintf('%d dwell events · %d tracks at a contact site · k_out ≈ %.2f /s · dwell = time inside the refined boundary', ...
            numel(dwellData.events), nAt, dwellData.kout);
    end

    function dd = computeDwell()
        dd=[]; ana=getAnalysisDir(); loadDwellOverrides();   % pull any saved manual class/frame edits
        f=fullfile(ana,'CS_final.mat'); if exist(f,'file')~=2, return; end
        Lc=load(f); if ~isfield(Lc,'CS')||isempty(Lc.CS), return; end
        CS=Lc.CS;
        % Tracks only needed for the optional 'none' rows + TrackMate ids; the dwell
        % events come from CS(k).CSmatrix (self-contained in CS_final -> provenance-safe).
        Tr=[]; if ~isempty(csData) && isfield(csData,'Tracks'), Tr=csData.Tracks; end
        if isempty(Tr)
            tf=fullfile(ana,'Tracks_final.mat'); if exist(tf,'file')~=2, tf=fullfile(ana,'TrackStruct.mat'); end
            if exist(tf,'file')==2, Lt=load(tf); fn=fieldnames(Lt);
                ix=find(cellfun(@(x)isstruct(Lt.(x))&&isfield(Lt.(x),'matrix'),fn),1);
                if ~isempty(ix), Tr=Lt.(fn{ix}); end
            end
        end
        cfg=cs_config(ana); dt=cfg.FrameInt_s;
        % per-CS dwell events from CS(k).CSmatrix (X/Y already relative to refCenter, um)
        ev=struct('cellIndex',{},'csK',{},'csID',{},'mito',{},'trackCol',{},'csCol',{}, ...
                  'trackID',{},'entryFrame',{},'exitFrame',{},'dwell',{});
        clsMap=containers.Map('KeyType','char','ValueType','any');  % "ci_col" -> enter/exit class of the track's PRIMARY (longest-residence) CS
        for k=1:numel(CS)
            if isempty(CS(k).refboundary) || isempty(CS(k).CSmatrix) || size(CS(k).CSmatrix,3)<3, continue; end
            ci=CS(k).cellIndex; mito=cs_site_near(CS(k),'mito'); cols=CS(k).tracks;
            bx=CS(k).refboundary(:,1)/1000; by=CS(k).refboundary(:,2)/1000;   % um rel refCenter
            for jj=1:min(numel(cols),size(CS(k).CSmatrix,2))
                fr=CS(k).CSmatrix(:,jj,1); xr=CS(k).CSmatrix(:,jj,2); yr=CS(k).CSmatrix(:,jj,3);
                insideMask=csInsideMask(xr,yr,bx,by);
                rev=runsToEvents(insideMask, fr, dt);
                for r=1:size(rev,1)
                    ev(end+1)=struct('cellIndex',ci,'csK',k,'csID',CS(k).csID,'mito',mito, ...
                        'trackCol',cols(jj),'csCol',jj,'trackID',trkId(Tr,ci,cols(jj)), ...
                        'entryFrame',rev(r,1),'exitFrame',rev(r,2),'dwell',rev(r,3)); %#ok<AGROW>
                end
                % enter/exit classification for THIS (track, CS); keep the track's longest-residence CS
                vld=isfinite(xr)&isfinite(yr);
                if any(vld)
                    [cls,entF,exF]=classifyInside(insideMask(vld), fr(vld));
                    inT=sum(insideMask(vld))*dt;
                    ky=sprintf('%d_%d',ci,cols(jj));
                    if ~isKey(clsMap,ky) || inT>clsMap(ky).t
                        clsMap(ky)=struct('class',cls,'entries',entF,'exits',exF,'t',inT);
                    end
                end
            end
        end
        dd.dt=dt; dd.events=ev; dd.CS=CS; dd.Tr=Tr;
        % per-track aggregation: MERGE overlapping residences (a track inside two
        % overlapping boundaries at once is one physical dwell, not two).
        rows={}; allDwell=[]; cells=unique([CS.cellIndex]);
        if isempty(ev), evCell=[]; evCol=[]; else, evCell=[ev.cellIndex]; evCol=[ev.trackCol]; end
        seen=containers.Map('KeyType','char','ValueType','logical');
        for ci=cells(:)'
            atCols=unique(evCol(evCell==ci));
            for c=atCols(:)'
                sel = evCell==ci & evCol==c;
                mg=mergeIntervals([[ev(sel).entryFrame]' [ev(sel).exitFrame]']);
                mgd=(mg(:,2)-mg(:,1)+1)*dt;                      % merged residence durations (s)
                allDwell=[allDwell; mgd]; %#ok<AGROW>
                anymito=any([ev(sel).mito]); csids=unique([ev(sel).csID]);
                lab=tern(anymito,'mito CS','non-mito CS');
                csidStr=char(strjoin(string(sort(csids(:)')),','));   % which contact-site id(s) this track visits
                ky=sprintf('%d_%d',ci,c); tcls='—'; tent=[]; tex=[];
                if isKey(clsMap,ky), cc=clsMap(ky); tcls=cc.class; tent=cc.entries; tex=cc.exits; end
                rows(end+1,:)={trkId(Tr,ci,c),ci,lab,csidStr,numel(mgd),max(mgd),sum(mgd),c,true,tcls,tent,tex}; %#ok<AGROW>
                seen(sprintf('%d_%d',ci,c))=true;
            end
        end
        % 'none' rows for tracks never inside any boundary (only if Tracks are available)
        for ci=cells(:)'
            if ci<1 || ci>numel(Tr), continue; end
            N=size(Tr(ci).matrix,2);
            for c=1:N
                if ~isKey(seen,sprintf('%d_%d',ci,c))
                    rows(end+1,:)={trkId(Tr,ci,c),ci,'none','—',0,0,0,c,false,'—',[],[]}; %#ok<AGROW>
                end
            end
        end
        rows = applyDwellOverrides(rows);   % user's manual class / entry / exit edits win over the auto values
        dd.rows=rows; dd.allDwell=allDwell(:)';
        dd.kout = numel(dd.allDwell)/max(sum(dd.allDwell),eps);   % pooled exits per second of residence
    end

    % ---- manual class / entry-exit overrides (Tab 8), persisted to analysis/dwell_overrides.csv ----
    function loadDwellOverrides()
        dwellOverrides = containers.Map('KeyType','char','ValueType','any');
        f = fullfile(getAnalysisDir(),'dwell_overrides.csv');
        if exist(f,'file')~=2, return; end
        try
            T = readtable(f,'TextType','string','Delimiter',',');
            for r=1:height(T)
                key = sprintf('%d_%d', double(T.cell(r)), double(T.trackCol(r)));
                dwellOverrides(key) = struct('class',char(T.class(r)), ...
                    'entries',frParse(char(T.entries(r))), 'exits',frParse(char(T.exits(r))));
            end
        catch ME, say('Dwell overrides load failed: %s', ME.message);
        end
    end
    function rows = applyDwellOverrides(rows)
        if isempty(dwellOverrides) || dwellOverrides.Count==0, return; end
        for r=1:size(rows,1)
            key = sprintf('%d_%d', rows{r,2}, rows{r,8});
            if isKey(dwellOverrides,key)
                o = dwellOverrides(key);
                rows{r,10}=o.class; rows{r,11}=o.entries; rows{r,12}=o.exits;
            end
        end
    end
    function saveDwellOverrides()
        f = fullfile(getAnalysisDir(),'dwell_overrides.csv');
        ks = keys(dwellOverrides);
        if isempty(ks), if exist(f,'file')==2, try, delete(f); catch, end, end, return; end
        cel=zeros(numel(ks),1); col=cel; cls=strings(numel(ks),1); ent=cls; exx=cls;
        for i=1:numel(ks)
            p=sscanf(ks{i},'%d_%d'); cel(i)=p(1); col(i)=p(2); o=dwellOverrides(ks{i});
            cls(i)=string(o.class); ent(i)=string(frTxt(o.entries)); exx(i)=string(frTxt(o.exits));
        end
        try
            writetable(table(cel,col,cls,ent,exx,'VariableNames',{'cell','trackCol','class','entries','exits'}), f);
        catch ME, say('Dwell overrides save failed: %s', ME.message);
        end
    end

    function id=trkId(Tr,ci,c)
        id=c;
        if isfield(Tr,'trackIDs') && ci>=1 && ci<=numel(Tr) && ~isempty(Tr(ci).trackIDs) ...
                && c<=numel(Tr(ci).trackIDs) && isfinite(Tr(ci).trackIDs(c)), id=Tr(ci).trackIDs(c); end
    end
    function m=maxOr0(v), if isempty(v), m=0; else, m=max(v); end, end

    function fillDwellTable()
        if isempty(dwellData) || ~isgraphics(dwTable), return; end
        rows=dwellData.rows;
        showAll = ~isempty(chkDwAll) && isgraphics(chkDwAll) && chkDwAll.Value;
        if ~showAll && ~isempty(rows), rows=rows([rows{:,9}]==1,:); end
        if isempty(rows), dwTable.Data={}; dwTable.UserData={}; return; end
        D=cell(size(rows,1),11);
        for r=1:size(rows,1)
            D(r,:)={rows{r,1}, rows{r,2}, rows{r,3}, rows{r,4}, rows{r,10}, ...
                    numel(rows{r,11}), numel(rows{r,12}), frTxt(rows{r,11}), frTxt(rows{r,12}), ...
                    round(rows{r,6},3), round(rows{r,7},3)};
        end
        dwTable.Data=D; dwTable.UserData=rows;   % keep full rows (with hidden col+atCS) for selection/edit
    end

    function onDwellEdit(e)          % user edited class / entry(s) / exit(s) -> store + persist the override
        if isempty(dwellData) || isempty(e.Indices), return; end
        rows=dwTable.UserData; r=e.Indices(1); c=e.Indices(2);
        if isempty(rows) || r<1 || r>size(rows,1), return; end
        ci=rows{r,2}; col=rows{r,8}; key=sprintf('%d_%d',ci,col);
        o=struct('class',rows{r,10},'entries',rows{r,11},'exits',rows{r,12});   % seed from current effective values
        switch c
            case 5, o.class=char(string(e.NewData));      % class dropdown
            case 8, o.entries=frParse(e.NewData);         % entry(s) text list
            case 9, o.exits=frParse(e.NewData);           % exit(s) text list
            otherwise, return;
        end
        dwellOverrides(key)=o; saveDwellOverrides();
        for rr=1:size(dwellData.rows,1)                   % mirror into the master rows (display + exports)
            if isequal(dwellData.rows{rr,2},ci) && isequal(dwellData.rows{rr,8},col)
                dwellData.rows{rr,10}=o.class; dwellData.rows{rr,11}=o.entries; dwellData.rows{rr,12}=o.exits; break;
            end
        end
        fillDwellTable();
        say('Dwell: track %g (cell %d) → %s · %d in / %d out (saved to dwell_overrides.csv).', ...
            rows{r,1}, ci, o.class, numel(o.entries), numel(o.exits));
    end

    function onDwellRemoveTrack()   % Tab 8: drop the selected track from its contact site(s) to refine them
        if isempty(dwSel) || isempty(dwSel.ci) || isempty(dwSel.col)
            if ~isempty(lDwell), lDwell.Text='Click a track row (one that IS at a contact site) first, then right-click → Remove.'; end
            return;
        end
        ci=dwSel.ci; col=dwSel.col; tid=dwSel.tid;
        d = uiconfirm(fig, sprintf(['Remove track %g from its contact site(s) in cell %d?\n\n' ...
            'This rewrites CS_final.mat — the track stops counting toward that site''s dwell, size and every ' ...
            'metric — and re-syncs CS Results, Dwell and Compare. Reversible by re-running the mapper.'], tid, ci), ...
            'Remove track from contact site', 'Options',{'Remove & re-sync','Cancel'}, ...
            'DefaultOption',2,'CancelOption',2,'Icon','warning');
        if ~strcmp(d,'Remove & re-sync'), return; end
        removeTrackFromCS_all(ci, col, tid);
    end

    function removeTrackFromCS_all(ci, col, tid)
        % SINGLE source of truth = CS_final.mat on disk. Load fresh, drop the track from EVERY CS in
        % this cell (all per-track fields stay length-aligned), save, then invalidate ALL caches and
        % recompute — so no tab can show a stale membership.
        ad = getAnalysisDir(); f = fullfile(ad,'CS_final.mat');
        if exist(f,'file')~=2, say('No CS_final.mat to edit.'); return; end
        try, Lc = load(f); catch ME, say('Could not read CS_final.mat: %s', ME.message); return; end
        if ~isfield(Lc,'CS') || isempty(Lc.CS), say('CS_final.mat has no contact sites.'); return; end
        CS = Lc.CS; removed=[]; skipped=[];
        for k = find([CS.cellIndex]==ci)
            jj = find(CS(k).tracks==col, 1); if isempty(jj), continue; end
            if numel(CS(k).tracks) <= 1, skipped(end+1)=CS(k).csID; continue; end %#ok<AGROW> % keep >=1 track; use Delete CS instead
            CS(k).tracks(jj) = [];
            if isfield(CS,'CSmatrix')    && ~isempty(CS(k).CSmatrix) && size(CS(k).CSmatrix,2)>=jj, CS(k).CSmatrix(:,jj,:)=[]; end
            if isfield(CS,'CSvec')       && ~isempty(CS(k).CSvec)    && size(CS(k).CSvec,2)>=jj,    CS(k).CSvec(:,jj,:)=[]; end
            if isfield(CS,'tracksCCids') && numel(CS(k).tracksCCids)>=jj,                           CS(k).tracksCCids(jj)=[]; end
            removed(end+1)=CS(k).csID; %#ok<AGROW>
        end
        if isempty(removed)
            if ~isempty(skipped), say('Track %g is the only track in CS %s — use "Delete CS" (Tab 7) to remove the whole site.', tid, mat2str(skipped));
            else,                 say('Track %g is not a member of any contact site.', tid); end
            return;
        end
        try, save(f,'CS'); catch ME, say('CS_final.mat save FAILED: %s — no caches touched.', ME.message); return; end %#ok<NASGU>
        csData=[]; dwellData=[]; cmpData=[];   % invalidate EVERY cache so all tabs re-read the edited file
        loadDwell();                            % recompute the tab we are on
        try, updateLoadedInfo(); catch, end
        say('Removed track %g from CS %s. CS_final.mat re-saved; CS Results / Dwell / Compare re-synced%s.', ...
            tid, mat2str(removed), tern(isempty(skipped),'',sprintf(' (kept CS %s — last track)',mat2str(skipped))));
    end

    function drawDwellDist()
        if isempty(dwellData) || ~isgraphics(axDwDist), return; end
        cla(axDwDist); dw=dwellData.allDwell;
        if isempty(dw), title(axDwDist,'No dwell events'); return; end
        hi=max(0.5, ceil(max(dw)*2)/2); edges=0:0.25:hi;
        h=histcounts(dw,edges); h=h/max(sum(h),1);
        ctr=(edges(1:end-1)+edges(2:end))/2;
        hold(axDwDist,'on');
        bar(axDwDist,ctr,h,1,'FaceColor',[0.90 0.55 0.50],'EdgeColor','none');
        plot(axDwDist,ctr,h,'-','Color',[0.75 0.12 0.10],'LineWidth',1.6);
        hold(axDwDist,'off'); xlim(axDwDist,[0 hi]); box(axDwDist,'on');
        title(axDwDist,sprintf('Dwell-time distribution  (n=%d · median %.2fs · k_{out}≈%.2f/s)', numel(dw), median(dw), dwellData.kout));
        xlabel(axDwDist,'Dwell time (s)'); ylabel(axDwDist,'Relative abundance');
    end

    function onDwellSelect(e)
        if isempty(dwellData) || isempty(e.Indices), return; end
        rows=dwTable.UserData; if isempty(rows), return; end
        r=e.Indices(1); if r<1 || r>size(rows,1), return; end
        stopDwellPlay();
        buildDwellSel(rows{r,2}, rows{r,8}, rows{r,1});   % cellIndex, trackCol, trackID
        if isempty(dwSel)
            drawDwellTrace(rows{r,2}, rows{r,8}, rows{r,1});
            if isgraphics(axDwSpace), cla(axDwSpace); title(axDwSpace,'track not inside a contact site','FontSize',8); end
            try, drawDwellCell(rows{r,2}, rows{r,8}); catch, end   % still orient it in the whole cell
            return;
        end
        dwIdx = numel(dwSel.idxList); drawDwellFrame(dwIdx);   % show the whole track initially
        try, drawDwellCell(dwSel.ci, dwSel.col, dwSel.k); catch, end
    end

    function buildDwellSel(ci,col,tid)
        dwSel=[]; ev=dwellData.events;
        if isempty(ev), return; end
        sel=[ev.cellIndex]==ci & [ev.trackCol]==col; evT=ev(sel);
        if isempty(evT), return; end
        [~,mi]=max([evT.dwell]); k=evT(mi).csK; jj=evT(mi).csCol; CS=dwellData.CS;
        fr=CS(k).CSmatrix(:,jj,1); xr=CS(k).CSmatrix(:,jj,2); yr=CS(k).CSmatrix(:,jj,3);
        idxList=find(isfinite(xr)&isfinite(yr));
        if isempty(CS(k).refboundary), bx=[]; by=[]; else, bx=CS(k).refboundary(:,1)/1000; by=CS(k).refboundary(:,2)/1000; end
        D = perTimestepD(xr,yr,fr,dwellData.dt,dwDwin,dwSigNm/1000);   % um^2/s per localization
        % member-track density in the CS reference frame (all member localizations,
        % same 30 nm grid as the site view) so the spatial panel shows the density the
        % track is moving over, not just the boundary outline.
        dens=[];
        try
            Xa=CS(k).CSmatrix(:,:,2); Ya=CS(k).CSmatrix(:,:,3); o=isfinite(Xa)&isfinite(Ya);
            if any(o(:))
                imG=LocDensityFigGenerate(Xa(o),Ya(o),30,[-40 40]);
                hwc=(40*30-30/2)/1000;   % 1.185 um (pixel-centre extent)
                g=max(min(double(imG),255),0);
                % alpha = intensity (gamma-lifted) so EMPTY bins are transparent instead
                % of opaque turbo-blue that hides the boundary/track drawn on top.
                a=(g/max(g(:)+eps)).^0.6;
                dens=struct('rgb',ind2rgb(uint8(round(g)),turbo(256)),'alpha',a,'ext',[-hwc hwc]);
            end
        catch, dens=[]; end
        dwSel=struct('ci',ci,'col',col,'tid',tid,'k',k,'jj',jj,'csID',CS(k).csID,'mito',cs_site_near(CS(k),'mito'), ...
            'fr',fr,'xr',xr,'yr',yr,'idxList',idxList,'bx',bx,'by',by,'dt',dwellData.dt,'evT',evT,'D',D,'dens',dens);
    end

    function D = perTimestepD(x,y,fr,dt,halfwin,sigUm)
        % per-localization diffusion coefficient (um^2/s, 2D) via a symmetric window
        % of steps. The localization-noise floor σ²/τ is removed PER STEP (gap-aware:
        % τ = gap·dt), and the SIGNED estimate is kept (near-arrest reads ~0, unbiased),
        % so slow diffusion and true arrest stay distinguishable.
        ok=isfinite(x)&isfinite(y); xi=x(ok); yi=y(ok); fi=fr(ok); n=numel(xi);
        D=nan(size(x)); if n<2, return; end
        dtstep=max(diff(fi),1)*dt;                                          % gap-aware time per step
        dstep=(diff(xi).^2+diff(yi).^2)./(4*dtstep) - (sigUm^2)./dtstep;    % per-step D, noise floor removed per step
        Di=nan(n,1);
        for i=1:n
            lo=max(1,i-halfwin); hi=min(n-1,i+halfwin-1);                   % 2·halfwin steps centred on localization i
            if hi>=lo, Di(i)=mean(dstep(lo:hi),'omitnan'); end
        end
        D(ok)=Di;
    end

    function onDwellDparam()
        if ~isempty(spDwin) && isgraphics(spDwin), dwDwin=round(spDwin.Value); end
        if ~isempty(spSig)  && isgraphics(spSig),  dwSigNm=spSig.Value; end
        if isempty(dwSel), return; end
        stopDwellPlay();
        buildDwellSel(dwSel.ci, dwSel.col, dwSel.tid);   % recompute D with new params
        if ~isempty(dwSel), drawDwellFrame(numel(dwSel.idxList)); end
    end

    function drawDwellFrame(j)
        if isempty(dwSel) || ~isgraphics(axDwSpace) || ~isgraphics(axDwTrace), return; end
        DS=dwSel; nL=numel(DS.idxList); if nL==0, return; end   % DS, NOT S — S is the shared app-state struct
        j=max(1,min(round(j),nL)); cur=DS.idxList(j); trail=DS.idxList(1:j); tNow=DS.fr(cur)*DS.dt;
        inb = ~isempty(DS.bx) && inpolygon(DS.xr(cur),DS.yr(cur),DS.bx,DS.by);
        cc=[0.9 0.25 0.2]; if inb, cc=[0.15 0.9 0.3]; end
        % centre reference: the CS reference centre (origin) OR — if "center on boundary"
        % is ticked — the refined-boundary centroid (distance-from-centre uses this too).
        useBC = ~isempty(chkDwCenter) && isgraphics(chkDwCenter) && chkDwCenter.Value && ~isempty(DS.bx);
        if useBC, ctrx=mean(DS.bx); ctry=mean(DS.by); ctrTxt='boundary'; else, ctrx=0; ctry=0; ctrTxt='CS'; end
        % --- spatial: the track moving in the CS reference frame (density + boundary + centre) ---
        cla(axDwSpace); hold(axDwSpace,'on');
        if ~isempty(DS.dens)
            image('Parent',axDwSpace,'XData',DS.dens.ext,'YData',DS.dens.ext,'CData',DS.dens.rgb, ...
                'AlphaData',DS.dens.alpha*densAlpha,'HitTest','off');   % transparent where empty, scaled by opacity slider
        end
        if ~isempty(DS.bx), patch(axDwSpace,DS.bx,DS.by,[1 0.9 0.6],'FaceAlpha',0.05,'EdgeColor',[0.95 0.5 0],'LineWidth',1.6,'HitTest','off'); end
        plot(axDwSpace,ctrx,ctry,'+','Color',[0 0 0],'MarkerSize',11,'LineWidth',1.3,'HitTest','off');   % centre marker
        plot(axDwSpace,DS.xr(trail),DS.yr(trail),'-','Color',[0.35 0.65 1],'LineWidth',1,'HitTest','off');% path so far
        plot(axDwSpace,DS.xr(cur),DS.yr(cur),'o','MarkerFaceColor',cc,'MarkerEdgeColor','k','MarkerSize',8,'HitTest','off');
        hold(axDwSpace,'off'); axis(axDwSpace,'equal');
        if ~isempty(DS.bx)   % centre the view on the SAME point as the centre marker (refCenter, or boundary centroid), framing the boundary
            m=0.15; half=max([abs(DS.bx-ctrx); abs(DS.by-ctry); 0.001]) + m;
            xlim(axDwSpace,[ctrx-half ctrx+half]); ylim(axDwSpace,[ctry-half ctry+half]);
        end
        title(axDwSpace,sprintf('track %g in CS %d  (%s)', DS.tid, DS.csID, tern(inb,'INSIDE','outside')),'FontSize',8);
        xlabel(axDwSpace,sprintf('x − %s centre (µm)',ctrTxt)); ylabel(axDwSpace,sprintf('y − %s centre (µm)',ctrTxt));
        % --- distance (left axis, blue) + diffusion coefficient D(t) (right axis, red) ---
        okA=isfinite(DS.xr)&isfinite(DS.yr); t=DS.fr*DS.dt; rho=sqrt((DS.xr-ctrx).^2+(DS.yr-ctry).^2); yl=[0 max([rho(okA);1e-3])*1.1];
        yyaxis(axDwTrace,'left'); cla(axDwTrace); hold(axDwTrace,'on');
        for q=1:numel(DS.evT)
            if DS.evT(q).csK~=DS.k, continue; end
            xa=DS.evT(q).entryFrame*DS.dt; xb=DS.evT(q).exitFrame*DS.dt;
            patch(axDwTrace,[xa xb xb xa],[yl(1) yl(1) yl(2) yl(2)],[1 0.85 0.4],'FaceAlpha',0.35,'EdgeColor','none','HitTest','off');
        end
        plot(axDwTrace,t(okA),rho(okA),'-','Color',[0.20 0.40 0.80],'LineWidth',1,'HitTest','off');
        plot(axDwTrace,tNow,sqrt((DS.xr(cur)-ctrx)^2+(DS.yr(cur)-ctry)^2),'o','MarkerFaceColor',cc,'MarkerEdgeColor','k','MarkerSize',6,'HitTest','off');
        ylim(axDwTrace,yl); ylabel(axDwTrace,sprintf('Dist. from %s centre (µm)',ctrTxt)); axDwTrace.YColor=[0.20 0.40 0.80];
        yyaxis(axDwTrace,'right'); cla(axDwTrace);
        Dv=DS.D; okD=isfinite(Dv); Dnow=NaN;
        if any(okD)
            plot(axDwTrace,t(okD),Dv(okD),'-','Color',[0.85 0.20 0.15],'LineWidth',1,'HitTest','off');
            yline(axDwTrace,0,':','Color',[0.85 0.20 0.15]);        % arrest / noise-floor level
            if isfinite(Dv(cur)), Dnow=Dv(cur); plot(axDwTrace,tNow,Dnow,'o','MarkerFaceColor',[0.85 0.20 0.15],'MarkerEdgeColor','k','MarkerSize',6,'HitTest','off'); end
            dmin=min(Dv(okD)); dmax=max(Dv(okD)); if ~isfinite(dmax)||dmax<=dmin, dmax=dmin+1e-3; end
            pad=0.1*(dmax-dmin); ylim(axDwTrace,[min(0,dmin)-pad dmax+pad]);
        end
        ylabel(axDwTrace,'D − noise floor (µm²/s)'); axDwTrace.YColor=[0.85 0.20 0.15];
        xline(axDwTrace,tNow,'-','Color',[0.1 0.1 0.1],'LineWidth',1);
        hold(axDwTrace,'off'); box(axDwTrace,'on');
        title(axDwTrace,sprintf('distance (blue) & D (red) · t=%.2fs · D=%.3g µm²/s', tNow, Dnow),'FontSize',8);
        xlabel(axDwTrace,'Time (s)');
        drawnow limitrate;
    end

    function redrawDwellStatic()
        % re-render the current (paused) frame + whole-cell panel after a display option
        % changes (e.g. "center on boundary"), without disturbing playback.
        if isempty(dwSel), return; end
        drawDwellFrame(min(dwIdx,numel(dwSel.idxList)));
        try, drawDwellCell(dwSel.ci, dwSel.col, dwSel.k); catch, end
    end

    function drawDwellCell(ci, hlCol, hlK)
        % whole-cell overview for the Dwell tab: every track faint, all CS boundaries
        % (white, numbered), the selected track highlighted (cyan) + its dwell site red.
        if isempty(dwellData) || ~isgraphics(axDwCell), return; end
        CS=dwellData.CS; Tr=dwellData.Tr; fov=local_fov();
        % auto-match this cell's mito max-int (cache by cell index) for the overlay
        if ~isequal(dwMitoCi, ci)
            dwMitoCi = ci; dwMitoImg = [];
            if ~isempty(Tr) && ci>=1 && ci<=numel(Tr)
                try, dwMitoImg = readMitoMip(qcCellMitoPath(Tr(ci).file)); catch, end
            end
        end
        cla(axDwCell); hold(axDwCell,'on'); N=0;
        % mito underlay (magenta), full FOV, below the tracks
        if ~isempty(dwMitoImg) && ~isempty(chkDwMito) && isgraphics(chkDwMito) && chkDwMito.Value
            g=dwMitoImg; [Hh,Ww]=size(g); px=fov/Ww;
            if max(g(:))>min(g(:))+1e-6, g=imadjust(g); end
            image(axDwCell,'XData',[1 Ww]*px,'YData',[1 Hh]*px,'CData',cat(3,g,zeros(Hh,Ww),g), ...
                'AlphaData',min(1,0.55*g),'HitTest','off');
        end
        if ~isempty(Tr) && ci>=1 && ci<=numel(Tr)
            N=size(Tr(ci).matrix,2);
            for c=1:N
                x=Tr(ci).matrix(:,c,2); y=Tr(ci).matrix(:,c,3); ok=isfinite(x)&isfinite(y);
                if nnz(ok)>=2, plot(axDwCell,x(ok),y(ok),'-','Color',[0.55 0.60 0.70 0.20],'LineWidth',0.3,'HitTest','off'); end
            end
        end
        for q=find([CS.cellIndex]==ci)
            if isempty(CS(q).refboundary), continue; end
            rc=CS(q).refCenter; if numel(rc)~=2 || ~all(isfinite(rc)), continue; end   % malformed refCenter: skip this site, don't blank the whole panel
            bx=CS(q).refboundary(:,1)/1000+rc(1); by=CS(q).refboundary(:,2)/1000+rc(2);
            if nargin>=3 && q==hlK
                plot(axDwCell,[bx;bx(1)],[by;by(1)],'-','Color',[0.95 0.20 0.15],'LineWidth',1.8,'HitTest','off');
            else
                plot(axDwCell,[bx;bx(1)],[by;by(1)],'-','Color',[1 1 1 0.6],'LineWidth',0.8,'HitTest','off');
                text(axDwCell,mean(bx),mean(by),num2str(CS(q).csID),'Color',[1 1 0.4],'FontSize',7,'HorizontalAlignment','center','HitTest','off');
            end
        end
        if ~isempty(Tr) && nargin>=2 && ci>=1 && ci<=numel(Tr) && hlCol>=1 && hlCol<=N
            x=Tr(ci).matrix(:,hlCol,2); y=Tr(ci).matrix(:,hlCol,3); ok=isfinite(x)&isfinite(y);
            if nnz(ok)>=2
                plot(axDwCell,x(ok),y(ok),'-','Color',[0.10 0.75 1],'LineWidth',1.6,'HitTest','off');
                i0=find(ok,1); plot(axDwCell,x(i0),y(i0),'o','MarkerFaceColor',[0.10 0.75 1],'MarkerEdgeColor','k','MarkerSize',5,'HitTest','off');
            end
        end
        hold(axDwCell,'off'); pbaspect(axDwCell,[1 1 1]); xlim(axDwCell,[0 fov]); ylim(axDwCell,[0 fov]);
        title(axDwCell,sprintf('Whole cell %d · track (cyan) · CS (red)', ci),'FontSize',8);
        xlabel(axDwCell,'x (µm)'); ylabel(axDwCell,'y (µm)');
        drawnow limitrate;
    end

    function onDwellPlay()
        if isempty(dwSel) || isempty(dwSel.idxList)
            if ~isempty(lDwell), lDwell.Text='Click a track (at a contact site) first, then Play.'; end, return;
        end
        stopDwellPlay(); dwIdx=1;
        dwTimer=timer('ExecutionMode','fixedRate','Period',0.08,'BusyMode','drop','TimerFcn',@(~,~) dwAdvance());
        start(dwTimer);
    end
    function stopDwellPlay()
        if ~isempty(dwTimer) && isvalid(dwTimer), stop(dwTimer); delete(dwTimer); end
        dwTimer=[];
    end
    function dwAdvance()
        if isempty(dwSel) || ~isgraphics(axDwSpace), stopDwellPlay(); return; end
        dwIdx=dwIdx+1; if dwIdx>numel(dwSel.idxList), dwIdx=1; end
        drawDwellFrame(dwIdx);
    end

    function drawDwellTrace(~, ~, tid)
        % fallback for a track that never enters any contact site (no dwSel).
        if ~isgraphics(axDwTrace), return; end
        yyaxis(axDwTrace,'right'); cla(axDwTrace); ylabel(axDwTrace,''); axDwTrace.YColor=[0.15 0.15 0.15];
        yyaxis(axDwTrace,'left');  cla(axDwTrace); axDwTrace.YColor=[0.15 0.15 0.15];
        plot(axDwTrace,NaN,NaN);
        title(axDwTrace,sprintf('track %g — never inside a contact site',tid),'FontSize',8);
        xlabel(axDwTrace,'Time (s)'); ylabel(axDwTrace,'Distance from CS centre (µm)');
    end

    function dwellTraceGrid()
        % curate-style multi-panel: every at-CS track's distance-from-CS-centre vs
        % time (Fig 1c) in its own small panel, with dwell windows shaded.
        if isempty(dwellData) || isempty(dwellData.rows)
            if ~isempty(lDwell), lDwell.Text='Press Compute first.'; end, return;
        end
        rows=dwellData.rows; atRows=rows([rows{:,9}]==1,:); n=size(atRows,1);
        if n==0, if ~isempty(lDwell), lDwell.Text='No tracks inside any contact site.'; end, return; end
        nc=ceil(sqrt(n)); nr=ceil(n/nc);
        fg=uifigure('Name','Dwell traces — distance from CS centre vs time (all at-CS tracks)', ...
            'Position',[120 90 min(1500,270*nc) min(950,230*nr)]);
        gl=uigridlayout(fg,[nr nc],'Padding',[8 8 8 8],'RowSpacing',6,'ColumnSpacing',6);
        ev=dwellData.events; CS=dwellData.CS; dt=dwellData.dt;
        for r=1:n
            ci=atRows{r,2}; col=atRows{r,8}; tid=atRows{r,1};
            ax=uiaxes(gl); box(ax,'on'); ax.FontSize=8; disableDefaultInteractivity(ax);
            sel=[ev.cellIndex]==ci & [ev.trackCol]==col; evT=ev(sel);
            if isempty(evT), title(ax,sprintf('trk %g',tid)); continue; end
            [~,mi]=max([evT.dwell]); k=evT(mi).csK; jj=evT(mi).csCol;
            fr=CS(k).CSmatrix(:,jj,1); xr=CS(k).CSmatrix(:,jj,2); yr=CS(k).CSmatrix(:,jj,3);
            ok=isfinite(xr)&isfinite(yr); t=fr*dt; rho=sqrt(xr.^2+yr.^2);
            yl=[0 max([rho(ok);1e-3])*1.1]; hold(ax,'on');
            for q=1:numel(evT)
                if evT(q).csK~=k, continue; end
                xa=evT(q).entryFrame*dt; xb=evT(q).exitFrame*dt;
                patch(ax,[xa xb xb xa],[yl(1) yl(1) yl(2) yl(2)],[1 0.85 0.4], ...
                    'FaceAlpha',0.35,'EdgeColor','none','HitTest','off');
            end
            plot(ax,t(ok),rho(ok),'-','Color',[0.2 0.4 0.8],'LineWidth',0.8); hold(ax,'off');
            ylim(ax,yl); title(ax,sprintf('trk %g · CS%d · %.2fs', tid, CS(k).csID, max([evT.dwell])),'FontSize',8);
        end
    end

    function exportDwellCSV()
        if isempty(dwellData) || isempty(dwellData.events)
            if ~isempty(lDwell), lDwell.Text='Nothing to export — press Compute first.'; end, return;
        end
        [fn,pth]=uiputfile('*.csv','Save per-event dwell times', fullfile(getAnalysisDir(),'dwell_times.csv'));
        if isequal(fn,0), return; end
        ev=dwellData.events;
        try
            Et=table([ev.cellIndex]',[ev.csID]',logical([ev.mito])',[ev.trackID]',[ev.trackCol]', ...
                [ev.entryFrame]',[ev.exitFrame]',[ev.dwell]', ...
                'VariableNames',{'cell','csID','mitoCS','trackID','trackCol','entryFrame','exitFrame','dwell_s'});
            writetable(Et, fullfile(pth,fn));
            R=dwellData.rows; base=erase(fn,'.csv'); nR=size(R,1);
            entS=strings(nR,1); exS=strings(nR,1); nIn=zeros(nR,1); nOut=zeros(nR,1);
            for r=1:nR, entS(r)=string(frTxt(R{r,11})); exS(r)=string(frTxt(R{r,12})); nIn(r)=numel(R{r,11}); nOut(r)=numel(R{r,12}); end
            Lt=table([R{:,1}]',[R{:,2}]',string(R(:,3)),string(R(:,4)),[R{:,5}]',[R{:,6}]',[R{:,7}]', ...
                string(R(:,10)),nIn,nOut,entS,exS, ...
                'VariableNames',{'trackID','cell','label','csIDs','numDwell','longest_s','total_s','csClass','numEntries','numExits','entryFrames','exitFrames'});
            writetable(Lt, fullfile(pth,[base '_track_labels.csv']));
            lDwell.Text=sprintf('Exported %d events -> %s  (+ track labels -> %s_track_labels.csv)', numel(ev), fn, base);
        catch ME, if ~isempty(lDwell), lDwell.Text=['Export failed: ' ME.message]; end
        end
    end

    % ===== Multi-condition comparison (tab 9) =================================
    % All cells (across every condition) are analysed together into ONE CS_final.mat;
    % `condition` is a per-cell label from the Experiment manifest. This layer JOINS each
    % cell back to its condition (Tr(ci).file == exptCells.name) and rolls the per-cell
    % dwell / k_out / mito / CC metrics up per condition. Cells are the replicates (n = cells).
    function computeComparison()
        if ~needProject(), return; end
        gb='condition'; if ~isempty(cmpGroupBy)&&isgraphics(cmpGroupBy), gb=cmpGroupBy.Value; end
        say('Compare: computing (%s)…', tern(strcmp(gb,'mito'),'mito vs non-mito','by condition'));
        if ~isempty(lCmp), lCmp.Text='Computing…'; end, drawnow;
        dd = computeDwell();
        if isempty(dd) || ~isfield(dd,'CS') || isempty(dd.CS)
            cmpData=[]; if isgraphics(cmpTable), cmpTable.Data={}; end
            if isgraphics(axCmpMain), cla(axCmpMain); end, if isgraphics(axCmpDist), cla(axCmpDist); end
            m='No CS_final.mat — run ContactSites (tab 5) first.';
            if ~isempty(lCmp), lCmp.Text=m; end, say(m); return;
        end
        CS=dd.CS; Tr=dd.Tr; dt=dd.dt; ev=dd.events;
        if strcmp(gb,'mito')                                   % ---- replicate = contact site ----
            P=struct('cell',{},'file',{},'condition',{},'nCS',{},'nMitoCS',{},'mitoFrac',{}, ...
                     'nTracksInCS',{},'ccFrac',{},'medDwell',{},'meanDwell',{},'kout',{},'area',{}, ...
                     'perim',{},'major',{},'minor',{},'aspect',{},'dwell',{});
            evK = []; if ~isempty(ev), evK=[ev.csK]; end
            for k=1:numel(CS)
                if isempty(CS(k).refboundary), continue; end   % only real (refined) sites
                flag=cs_site_near(CS(k),'mito');
                dws=[]; if ~isempty(ev), dws=[ev(evK==k).dwell]; end
                if isempty(dws), medDw=NaN;meanDw=NaN;kout=NaN;
                else, medDw=median(dws);meanDw=mean(dws);kout=numel(dws)/max(sum(dws),eps); end
                [ar,perim,majr,minr]=csDims(CS(k).refboundary); asp=majr/max(minr,eps);
                ccF=NaN; if isfield(CS,'tracksCCids')&&~isempty(CS(k).tracksCCids), cc=CS(k).tracksCCids(:); ccF=nnz(isfinite(cc))/numel(cc); end
                P(end+1)=struct('cell',CS(k).cellIndex,'file','','condition',tern(flag,'mito CS','non-mito CS'), ...
                    'nCS',1,'nMitoCS',double(flag),'mitoFrac',double(flag),'nTracksInCS',numel(CS(k).tracks), ...
                    'ccFrac',ccF,'medDwell',medDw,'meanDwell',meanDw,'kout',kout,'area',ar, ...
                    'perim',perim,'major',majr,'minor',minr,'aspect',asp,'dwell',dws(:)'); %#ok<AGROW>
            end
            uc={'mito CS','non-mito CS'}; uc=uc(ismember(uc,{P.condition}));   % keep only present groups, mito first
            cmpData=struct('P',P,'conds',{uc},'dt',dt,'groupBy','mito','replicate','contact sites');
            fillCmpTable(); drawComparison();
            say('Compare: done — %d contact sites, %d group(s): %s', numel(P), numel(uc), strjoin(uc,', '));
            return;
        end
        if isempty(ev), evCell=[]; evCol=[]; else, evCell=[ev.cellIndex]; evCol=[ev.trackCol]; end
        % Which cells are replicates? A cell with >=1 CS is definitely processed. A cell with
        % ZERO CS is a legitimate zero ONLY if the user explicitly assigned it a condition in the
        % manifest (Tracks_final holds every BUILT cell — many are simply not yet CS-picked, and
        % counting those as 0 would bias '# CS per cell' downward). So enumerate the UNION of
        % {cells with >=1 CS} and {condition-assigned cells}. With no manifest this collapses to
        % the CS-bearing cells (the safe default).
        csCells = unique([CS.cellIndex]);
        manCells = [];
        if ~isempty(Tr) && ~isempty(exptCells) && isfield(Tr,'file')
            for ci=1:numel(Tr)
                if ~strcmp(condOf(Tr(ci).file),'unassigned'), manCells(end+1)=ci; end %#ok<AGROW>
            end
        end
        cells = unique([csCells(:); manCells(:)])';
        if isempty(cells), cells = csCells; end
        P=struct('cell',{},'file',{},'condition',{},'nCS',{},'nMitoCS',{},'mitoFrac',{}, ...
                 'nTracksInCS',{},'ccFrac',{},'medDwell',{},'meanDwell',{},'kout',{},'area',{}, ...
                 'perim',{},'major',{},'minor',{},'aspect',{},'dwell',{});
        for ci=cells(:)'
            idx=find([CS.cellIndex]==ci); nCS=numel(idx);
            flags=false(1,nCS); ccAll=[]; nTrk=0; areas=[]; perims=[]; majors=[]; minors=[];
            for a=1:nCS
                k=idx(a); flags(a)=cs_site_near(CS(k),'mito');
                if isfield(CS,'tracksCCids'), ccAll=[ccAll CS(k).tracksCCids(:)']; end %#ok<AGROW>
                nTrk=nTrk+numel(CS(k).tracks);
                if ~isempty(CS(k).refboundary)
                    [aa,pp,mj,mn]=csDims(CS(k).refboundary);
                    areas(end+1)=aa; perims(end+1)=pp; majors(end+1)=mj; minors(end+1)=mn; %#ok<AGROW>
                end
            end
            nMito=nnz(flags);
            if nCS==0, mitoFrac=NaN; else, mitoFrac=nMito/nCS; end   % fraction undefined with no CS
            if isempty(ccAll), ccFrac=NaN; else, ccFrac=nnz(isfinite(ccAll))/numel(ccAll); end
            % per-cell merged residence durations (same merge as computeDwell, bucketed by cell)
            cellDwell=[];
            if ~isempty(ev)
                for c=unique(evCol(evCell==ci))
                    sel=evCell==ci & evCol==c;
                    mg=mergeIntervals([[ev(sel).entryFrame]' [ev(sel).exitFrame]']);
                    cellDwell=[cellDwell; (mg(:,2)-mg(:,1)+1)*dt]; %#ok<AGROW>
                end
            end
            if isempty(cellDwell), medDw=NaN; meanDw=NaN; kout=NaN;
            else, medDw=median(cellDwell); meanDw=mean(cellDwell); kout=numel(cellDwell)/max(sum(cellDwell),eps); end
            fn=''; if ci>=1 && ci<=numel(Tr) && isfield(Tr,'file'), fn=Tr(ci).file; end
            majMean=cmpMeanOr(majors); minMean=cmpMeanOr(minors);
            P(end+1)=struct('cell',ci,'file',fn,'condition',condOf(fn),'nCS',nCS,'nMitoCS',nMito, ...
                'mitoFrac',mitoFrac,'nTracksInCS',nTrk,'ccFrac',ccFrac,'medDwell',medDw,'meanDwell',meanDw, ...
                'kout',kout,'area',cmpMeanOr(areas),'perim',cmpMeanOr(perims),'major',majMean,'minor',minMean, ...
                'aspect',majMean/max(minMean,eps),'dwell',cellDwell(:)'); %#ok<AGROW>
        end
        uc=unique({P.condition},'stable'); ua=strcmp(uc,'unassigned'); uc=[uc(~ua) uc(ua)];  % 'unassigned' last
        cmpData=struct('P',P,'conds',{uc},'dt',dt,'groupBy','condition','replicate','cells');
        fillCmpTable(); drawComparison();
        say('Compare: done — %d cells, %d condition(s): %s', numel(P), numel(uc), strjoin(uc,', '));
    end

    function c = condOf(name)   % manifest cell name (== Tr.file) -> condition label
        c='unassigned';
        if isempty(exptCells) || isempty(name), return; end
        keys={exptCells.name};
        j=find(strcmp(keys,name),1);
        if isempty(j)   % fallback: manifest name is a substring of the tracks file base (or vice-versa)
            j=find(cellfun(@(k) ~isempty(k) && (startsWith(name,k)||contains(name,k)), keys),1);
        end
        if ~isempty(j) && ~isempty(strtrim(exptCells(j).condition)), c=strtrim(exptCells(j).condition); end
    end

    function m = cmpMeanOr(v), if isempty(v), m=NaN; else, m=mean(v,'omitnan'); end, end

    function s = cmpMsem(v)     % "mean ± sem" over finite values (— if none)
        v=v(isfinite(v)); if isempty(v), s='—'; return; end
        m=mean(v); if numel(v)>1, e=std(v)/sqrt(numel(v)); else, e=0; end
        s=sprintf('%.3g ± %.2g', m, e);
    end

    function [v,ylab] = cmpMetricValues(P, name)   % per-replicate metric vector aligned to P
        switch name
            case 'k_out (/s)',             v=[P.kout];     ylab='k_{out} (/s)';
            case 'mito fraction of CS',    v=[P.mitoFrac]; ylab='mito fraction of CS';
            case 'CC-associated fraction', v=[P.ccFrac];   ylab='CC-associated fraction';
            case '# CS per cell',          v=[P.nCS];      ylab='# contact sites / cell';
            case '# tracks per CS',        v=arrayfun(@(p) p.nTracksInCS/max(p.nCS,1), P); ylab='# tracks / CS';
            case 'CS area (um^2)',         v=[P.area];     ylab='mean CS area (\mum^2)';
            case 'CS perimeter (um)',      v=[P.perim];    ylab='mean CS perimeter (\mum)';
            case 'CS length (um)',         v=[P.major];    ylab='mean CS length (\mum)';
            case 'CS width (um)',          v=[P.minor];    ylab='mean CS width (\mum)';
            case 'CS aspect (L/W)',        v=[P.aspect];   ylab='mean CS aspect ratio (length/width)';
            otherwise,                     v=[P.medDwell]; ylab='median dwell (s)';
        end
    end

    function [ar,perim,majr,minr] = csDims(rb)   % refboundary (nm, Nx2) -> area, perimeter, length, width (um)
        ar=NaN; perim=NaN; majr=NaN; minr=NaN;
        if isempty(rb) || size(rb,1)<3, return; end
        x=rb(:,1)/1000; y=rb(:,2)/1000;                       % um
        try, ar=polyarea(x,y); catch, end
        dx=diff([x;x(1)]); dy=diff([y;y(1)]); perim=sum(hypot(dx,dy));   % closed-polygon perimeter
        Q=[x-mean(x), y-mean(y)];                             % length/width = extent along the shape's principal axes
        try, [V,~]=eig(cov(Q)); pc=Q*V; ext=max(pc,[],1)-min(pc,[],1); majr=max(ext); minr=min(ext); catch, end
    end

    function fillCmpTable()
        if isempty(cmpData) || ~isgraphics(cmpTable), return; end
        P=cmpData.P; uc=cmpData.conds; D=cell(numel(uc),7);
        for i=1:numel(uc)
            m=strcmp({P.condition},uc{i});
            D(i,:)={uc{i}, nnz(m), cmpMsem([P(m).nCS]), cmpMsem([P(m).mitoFrac]), ...
                    cmpMsem([P(m).ccFrac]), cmpMsem([P(m).medDwell]), cmpMsem([P(m).kout])};
        end
        cmpTable.Data=D;
    end

    function drawComparison()
        if isempty(cmpData) || ~isgraphics(axCmpMain), return; end
        P=cmpData.P; uc=cmpData.conds; nc=numel(uc);
        rep='cells'; if isfield(cmpData,'replicate') && ~isempty(cmpData.replicate), rep=cmpData.replicate; end
        [vals,ylab]=cmpMetricValues(P, cmpMetric.Value);
        clr=lines(max(nc,1));
        % --- main axes: per-cell values per condition (dots = cells) + mean ± s.e.m. ---
        cla(axCmpMain); hold(axCmpMain,'on');
        means=nan(1,nc); sems=nan(1,nc);
        for i=1:nc
            m=strcmp({P.condition},uc{i}); vi=vals(m); vi=vi(isfinite(vi));
            if isempty(vi), continue; end
            xj=i+(rand(1,numel(vi))-0.5)*0.18;
            scatter(axCmpMain, xj, vi, 26, clr(i,:), 'filled', 'MarkerFaceAlpha',0.6);
            means(i)=mean(vi); if numel(vi)>1, sems(i)=std(vi)/sqrt(numel(vi)); else, sems(i)=0; end
        end
        errorbar(axCmpMain, 1:nc, means, sems, 'k.', 'MarkerSize',15, 'LineWidth',1.1, 'CapSize',12);
        axCmpMain.XLim=[0.5 nc+0.5]; axCmpMain.XTick=1:nc; axCmpMain.XTickLabel=uc; axCmpMain.XTickLabelRotation=15;
        ylabel(axCmpMain, ylab);
        ttl=sprintf('%s   (dots = %s, bars = mean ± s.e.m.)', cmpMetric.Value, rep);
        try   % rank-sum p when exactly two groups and the Statistics Toolbox is present
            if nc==2 && exist('ranksum','file')==2
                a=vals(strcmp({P.condition},uc{1})); a=a(isfinite(a));
                b=vals(strcmp({P.condition},uc{2})); b=b(isfinite(b));
                if numel(a)>=2 && numel(b)>=2
                    ttl=sprintf('%s   (rank-sum p = %.3g, n = %d / %d %s)', cmpMetric.Value, ranksum(a,b), numel(a), numel(b), rep);
                end
            end
        catch, end
        title(axCmpMain, ttl, 'FontSize',9); hold(axCmpMain,'off');
        % --- dist axes: pooled dwell-time CDF overlaid by condition ---
        cla(axCmpDist); hold(axCmpDist,'on'); lg={};
        for i=1:nc
            m=strcmp({P.condition},uc{i}); dw=[P(m).dwell]; dw=dw(isfinite(dw)&dw>0);
            if isempty(dw), continue; end
            xs=sort(dw(:)'); ys=(1:numel(xs))/numel(xs);
            stairs(axCmpDist, xs, ys, 'LineWidth',1.4, 'Color',clr(i,:));
            lg{end+1}=sprintf('%s (%d dwells)', uc{i}, numel(dw)); %#ok<AGROW>
        end
        xlabel(axCmpDist,'dwell time (s)'); ylabel(axCmpDist,'cumulative fraction');
        title(axCmpDist,'Dwell-time distribution by group (pooled)','FontSize',9);
        axCmpDist.YLim=[0 1]; if ~isempty(lg), legend(axCmpDist, lg, 'Location','southeast','FontSize',8,'Box','off'); end
        hold(axCmpDist,'off');
        if ~isempty(lCmp)
            if strcmp(rep,'cells')
                nAssigned=nnz(~strcmp({P.condition},'unassigned'));
                lCmp.Text=sprintf('%d cells (%d assigned) across %d condition(s): %s', numel(P), nAssigned, nc, strjoin(uc,', '));
            else
                lCmp.Text=sprintf('%d %s across %d group(s): %s', numel(P), rep, nc, strjoin(uc,', '));
            end
        end
    end

    function exportComparisonCSV()
        if isempty(cmpData) || isempty(cmpData.P)
            if ~isempty(lCmp), lCmp.Text='Nothing to export — press Compute first.'; end, return;
        end
        P=cmpData.P;
        [fn,pth]=uiputfile('*.csv','Save per-cell condition metrics', fullfile(getAnalysisDir(),'condition_metrics_percell.csv'));
        if isequal(fn,0), return; end
        try
            T=table({P.file}', {P.condition}', [P.nCS]', [P.nMitoCS]', [P.mitoFrac]', [P.nTracksInCS]', ...
                [P.ccFrac]', [P.medDwell]', [P.meanDwell]', [P.kout]', [P.area]', ...
                'VariableNames',{'cell','condition','nCS','nMitoCS','mitoFrac','nTracksInCS', ...
                'ccFrac','medDwell_s','meanDwell_s','kout_perS','meanArea_um2'});
            writetable(T, fullfile(pth,fn));
            if ~isempty(lCmp), lCmp.Text=sprintf('Exported %d cells -> %s', numel(P), fn); end
        catch ME, if ~isempty(lCmp), lCmp.Text=['Export failed: ' ME.message]; end
        end
    end

    % ---- helpers ----
    function d = getAnalysisDir(), d = fullfile(S.projectDir, valOr(eAnalysis,'analysis')); end
    function d = tracksSourceDir()
        % tracks folder to curate/build from: the Experiment tab's folder if set, else
        % the project's tracks/ subfolder (legacy single-folder flow).
        if ~isempty(eExTracks) && isgraphics(eExTracks) && ~isempty(eExTracks.Value) && isfolder(eExTracks.Value)
            d = eExTracks.Value;
        else
            d = fullfile(S.projectDir, valOr(eTracks,'tracks'));
        end
    end
    function ok = needProject()
        ok = ~isempty(S.projectDir) && isfolder(S.projectDir);
        if ~ok, uialert(fig,'Pick a valid project folder first.','No project'); end
    end
    function refreshLamps()
        if ~isvalid(fig) || isempty(tabLamps), return; end
        haveProj = ~isempty(S.projectDir) && isfolder(S.projectDir); a = getAnalysisDir();
        exf = @(f) haveProj && exist(fullfile(a,f),'file')==2;
        cnt = @(d,pat) tern(haveProj && isfolder(fullfile(a,d)), numel(dir(fullfile(a,d,pat))), 0);
        cal   = exf('cs_calib.mat');
        haveExp = ~isempty(exptCells);
        build = exf('TrackStruct.mat') || exf('Tracks.mat');
        dens  = cnt('Densities','*_rho.tif') > 0;
        nPick = cnt('CSdata','*_CSdata.mat');
        fin   = exf('CS_final.mat');
        A = [0.95 0.75 0.15];   % amber = partial / in progress
        % lamps: 1 Cal · 2 Exp · 3 Curate · 4 Build · 4b QC · 5 Run · 6 Picker · 7 Results · 8 Dwell · 9 Compare
        cols = { tern(cal,GREEN,GREY), tern(haveExp,GREEN,GREY), tern(build,GREEN,GREY), ...
                 tern(build,GREEN,GREY), tern(build,GREEN,GREY), tern(dens,GREEN,GREY), ...
                 tern(fin,GREEN,tern(nPick>0,A,GREY)), tern(fin,GREEN,GREY), tern(fin,GREEN,GREY), tern(fin,GREEN,GREY) };
        for i=1:min(numel(tabLamps),numel(cols))
            try, if isgraphics(tabLamps(i)), tabLamps(i).Color = cols{i}; end, catch, end
        end
    end

    function ci = calibInfo()
        % current scale/calibration: cs_config already merges this project's cs_calib.mat
        % (falls back to the built-in defaults when no project / no calibration is saved).
        ci = struct('pixUm',0.10785,'fovUm',27.61,'dt',0.020064,'binNm',30,'snapFov',27.61,'src','defaults');
        hasProj = ~isempty(S.projectDir) && isfolder(S.projectDir); haveCal=false;
        if hasProj, try, haveCal = exist(fullfile(getAnalysisDir(),'cs_calib.mat'),'file')==2; catch, end, end
        try
            if hasProj, c0=cs_config(getAnalysisDir()); else, c0=cs_config(); end
            if isfield(c0,'PixSize_um')&&isfinite(c0.PixSize_um), ci.pixUm=c0.PixSize_um; end
            if isfield(c0,'FOV_um')&&isfinite(c0.FOV_um),         ci.fovUm=c0.FOV_um; end
            if isfield(c0,'FrameInt_s')&&isfinite(c0.FrameInt_s), ci.dt=c0.FrameInt_s; end
            if isfield(c0,'SnapFOV_um')&&isfinite(c0.SnapFOV_um), ci.snapFov=c0.SnapFOV_um; end
        catch, end
        if haveCal
            ci.src='cs_calib.mat';
            try, L=load(fullfile(getAnalysisDir(),'cs_calib.mat'));
                if isfield(L,'calib')&&isfield(L.calib,'binNm')&&isfinite(L.calib.binNm)&&L.calib.binNm>0, ci.binNm=L.calib.binNm; end
            catch, end
        end
    end

    function refreshScale()
        if isempty(lblScale) || ~isgraphics(lblScale), return; end
        ci = calibInfo();
        % density px: prefer the ACTUAL loaded rho raster (snapFov/size, what picking &
        % mapping use), else the nominal density bin — both ~30 nm.
        densNm = ci.binNm; rhoTxt = '';
        try
            if ~isempty(csData) && isfield(csData,'rhoWH') && ~isempty(csData.rhoWH)
                W=csData.rhoWH(1); H=csData.rhoWH(2);   % Width×Height px of the density raster
                densNm = csData.snapFov/H*1000;
                rhoTxt = sprintf(' · rho %d×%d px', W, H);
            end
        catch, end
        lblScale.Text = sprintf(['%s      scale:  density %.1f nm/px  ·  camera %.4g µm/px  ·  ' ...
            'FOV %.4g µm  ·  frame dt %.4g ms%s   [%s]'], loadedInfoStr(), densNm, ci.pixUm, ci.fovUm, ci.dt*1000, rhoTxt, ci.src);
    end

    function s = loadedInfoStr()   % what's currently loaded — always visible so you never edit the wrong data
        if isempty(S.projectDir) || ~isfolder(S.projectDir), s='⬚ no project loaded'; return; end
        [~,pn] = fileparts(S.projectDir);
        ts='—'; if ~isempty(ddTsFile) && isgraphics(ddTsFile) && ~isempty(ddTsFile.Value), ts=ddTsFile.Value; end
        extra='';
        if ~isempty(csData) && isfield(csData,'CS'), extra=sprintf(' · %d CS', numel(csData.CS));
        elseif ~isempty(dwellData) && isfield(dwellData,'CS'), extra=sprintf(' · %d CS', numel(dwellData.CS)); end
        s = sprintf('▣ loaded: %s · %s%s', pn, ts, extra);
    end
    function updateLoadedInfo(), try, refreshScale(); catch, end, end

    function busy(on)
        if ~isvalid(fig), return; end
        if on, fig.Pointer='watch'; else, fig.Pointer='arrow'; end
        drawnow;
    end
    function y = tern(c,a,b), if c, y=a; else, y=b; end, end
    function v = valOr(h,dflt), v = strtrim(h.Value); if isempty(v), v = dflt; end, end
    function s = argstr(args)
        parts = cell(1,numel(args));
        for i=1:numel(args)
            x = args{i};
            if ischar(x)||isstring(x), parts{i}=['''' char(x) ''''];
            elseif islogical(x),       parts{i}=mat2str(x);
            else,                      parts{i}=num2str(x); end
        end
        s = strjoin(parts,',');
    end
end

% ===========================================================================
function lblRow(gl,row,str,cols)
h = uilabel(gl,'Text',str,'WordWrap','on','FontAngle','italic');
h.Layout.Row = row; h.Layout.Column = cols;
end

% ---------------------------------------------------------------------------
function rec = csDensMetricOne(cs, cc, file, blank, binArea)
% One contact site's density metrics (Obara PMF + supplementary enrichment). Pure and
% self-contained (no shared/nested state) so computeCSDensityMetrics can run it under either a
% parfor or a serial for and get byte-identical results. cc is that site's per-cell cache
% struct (whole-cell density map + cached localizations) or [] when the cell had no usable
% localizations; file is the cell's tracks-file name resolved by the caller.
rec = blank;
rec.csID = cs.csID; rec.cellIndex = cs.cellIndex; rec.mito = cs_site_near(cs,'mito');
rec.file = file;
if isempty(cc) || isempty(cs.refboundary), return; end
rc = cs.refCenter;
bx = cs.refboundary(:,1)/1000+rc(1); by = cs.refboundary(:,2)/1000+rc(2);   % abs um
xmn=min(bx); xmx=max(bx); ymn=min(by); ymx=max(by);                         % site bounding box (um)
rec.area_um2 = polyarea(bx,by);
% bbox pre-filter: a site is tiny vs the whole cell, so only localizations inside the boundary's
% bounding box can possibly be inside the polygon. Restricting the expensive point-in-polygon to
% that handful is EXACT (points outside the bbox are outside the polygon) and cuts the dominant
% serial cost — inpolygon over tens of thousands of loc/cell x hundreds of sites — by orders of
% magnitude. This is the speed-up that needs no toolbox; the parfor below is an extra on top.
inbb = cc.Xc>=xmn & cc.Xc<=xmx & cc.Yc>=ymn & cc.Yc<=ymx;
rec.n_loc_in = nnz(inpolygon(cc.Xc(inbb),cc.Yc(inbb),bx,by));
rec.cell_total = cc.cellTot;
rec.prob_mass = rec.n_loc_in/max(cc.cellTot,1);
% smoothed-density bins whose CENTRES fall inside the boundary (bbox-limited)
ix = find(cc.cxc>=xmn&cc.cxc<=xmx); iy = find(cc.cyc>=ymn&cc.cyc<=ymx);
if ~isempty(ix)&&~isempty(iy)
    [GX,GY] = ndgrid(cc.cxc(ix),cc.cyc(iy)); sub = cc.rho(ix,iy); subR = cc.Hc(ix,iy);
    inG = inpolygon(GX(:),GY(:),bx,by); rhoIn = sub(inG); rawIn = subR(inG);
    if ~isempty(rhoIn)
        rec.peak_prob     = max(rhoIn)/max(cc.cellTot,1);   % smoothed-map peak (robust)
        rec.peak_prob_raw = max(rawIn)/max(cc.cellTot,1);   % strict raw-count PMF peak
        rec.local_dens    = mean(rhoIn)/binArea;            % loc/um^2
    end
end
if isfinite(cc.rho_bg), rec.cell_bg_dens = cc.rho_bg/binArea; end
if isfinite(rec.local_dens) && rec.cell_bg_dens>0
    rec.enrichment = rec.local_dens/rec.cell_bg_dens;       % dimensionless fold
end
end

function p = firstTif(varargin)
p = '';
for k=1:numel(varargin)
    d = varargin{k};
    if ischar(d) && isfolder(d)
        L = dir(fullfile(d,'*.tif')); L = L(~[L.isdir]);
        if ~isempty(L), p = fullfile(L(1).folder,L(1).name); return; end
    end
end
end

function p = firstXml(tracksDir)
p = '';
if isempty(tracksDir) || ~isfolder(tracksDir), return; end
L = dir(fullfile(tracksDir,'*_tracks_filtered.xml'));
if isempty(L), L = dir(fullfile(tracksDir,'*_tracks.xml')); end
L = L(~[L.isdir]);
if ~isempty(L), p = fullfile(L(1).folder,L(1).name); end
end

function M = padcat_cols(cols)
% Horizontally concatenate matrices with differing row counts, NaN-padding
% shorter ones to the max row count (per-cell MSD/CSD have different lengths).
maxR = 0;
for i = 1:numel(cols), maxR = max(maxR, size(cols{i},1)); end
M = [];
for i = 1:numel(cols)
    c = cols{i};
    if size(c,1) < maxR, c(end+1:maxR,:) = NaN; end
    M = [M c]; %#ok<AGROW>
end
end

function [D, b, nf] = fitDeff(msd, dt, fracLags)
% Effective diffusion coefficient from a linear fit of one track's MSD:
% MSD(tau) = 4*D*tau + b (2D). D = slope/4, b = offset (localization error).
% NaN if too few finite points. Requires a true squared-displacement MSD (um^2).
% Fits the first fracLags (default 0.5 = 50%) of the FINITE lags. Long lags are
% poorly sampled (lag tau averages only L-tau displacements per track) and can bend
% away from linear under confinement, so only the earlier, better-sampled part of the
% curve is fit. (Prior default was the first ~4 lags; 50% uses more of the curve.)
if nargin < 3 || isempty(fracLags), fracLags = 0.5; end
m = msd(:); lag = (1:numel(m))'*dt;
ok = isfinite(m); m = m(ok); lag = lag(ok);
if numel(m) < 2, D = NaN; b = NaN; nf = 0; return; end
nf = max(2, min(numel(m), round(fracLags*numel(m))));   % first ~fracLags of the finite lags
p = polyfit(lag(1:nf), m(1:nf), 1);           % [slope offset]
D = p(1)/4; b = p(2);
end
