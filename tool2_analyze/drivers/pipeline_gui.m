function pipeline_gui
% PIPELINE_GUI  One-window control panel for the integrated SPT + ContactSites
% pipeline. Wraps the command-line drivers (build_trackstruct, setup_run_folder,
% run_contactsite_analysis) behind buttons, folder/file pickers, status lamps
% and a live log — so a run is clicks, not typed name-value pairs.
%
%   >> pipeline_gui
%
% It does not change any analysis logic: every button calls the same driver a
% power user would call by hand, capturing its console output into the log.
% The ContactSites suite is still driven UNCHANGED underneath.
%
% COMPATIBILITY: built entirely on the classic figure + uicontrol toolkit
% (works on every MATLAB release back to ~R2007, and on Octave). It does NOT
% use uifigure/App-Designer widgets, so it runs on installs older than R2016a.
%
% Layout (top -> bottom):
%   Project   : pick projectDir; set tracks/ and analysis/ subfolders; SuitePath
%   [5] Import: build the Tracks struct from curated XML/CSV
%   [5.5] Setup: pick mito/MaxInt/ER images -> scaffold analysis/ with correct names
%   [6] CS run: options + Start/Stop stage; runs the suite to the next manual gate
%   Status    : one lamp per stage;   Log: timestamped output from every action

% ---- resolve sibling code folders onto the path ---------------------------
here = fileparts(mfilename('fullpath'));
addpath(here);                                   % drivers/
% Prefer the hardened suite; fall back to original / legacy name.
root = fileparts(here);
cand = {fullfile(root,'ContactSites_robust'), ...
        fullfile(root,'ContactSites_original'), ...
        fullfile(root,'ContactSites')};
sib = '';
for c = cand
    if isfolder(c{1}), sib = c{1}; break; end
end
if ~isempty(sib), addpath(genpath(sib)); end

% ---- shared state ----------------------------------------------------------
S.projectDir = '';
S.suitePath  = sib;
S.mito = ''; S.maxint = ''; S.er = '';

GREY  = [0.60 0.60 0.60];
GREEN = [0.30 0.75 0.30];
FIXED = get(0,'FixedWidthFontName');

% ===========================================================================
% BUILD THE WINDOW  (classic figure; pixel layout, y measured from bottom)
% ===========================================================================
f = figure('Name','SPT + ContactSites Pipeline','NumberTitle','off', ...
    'MenuBar','none','ToolBar','none','Color',[0.94 0.94 0.94], ...
    'Units','pixels','Position',[100 80 880 760],'Resize','off', ...
    'IntegerHandle','off','HandleVisibility','off');  % HandleVisibility off:
    % the ContactSites plotting scripts call `close all`; that only closes
    % handle-VISIBLE figures, so this keeps the control panel alive while the
    % suite opens and closes its own plot windows.

% ---------------- Panel: Project -------------------------------------------
pProj = uipanel(f,'Title','Project','Units','pixels','Position',[10 636 860 110]);
lbl(pProj,'Project folder:',      [10 76 100 20]);
eProj  = edt(pProj,'',            [115 76 430 22],false);
btn(pProj,'Browse…',              [555 76 90 24],@onBrowseProject,false);
lbl(pProj,'tracks/ subdir:',      [10 44 100 20]);
eTracks = edt(pProj,'tracks',     [115 44 120 22],true);
lbl(pProj,'analysis/ subdir:',    [250 44 110 20]);
eAnalysis = edt(pProj,'analysis', [365 44 120 22],true);
lbl(pProj,'ContactSites path:',   [10 12 110 20]);
eSuite = edt(pProj,S.suitePath,   [125 12 420 22],true);
btn(pProj,'Browse…',              [555 12 90 24],@onBrowseSuite,false);

% ---------------- Panel: [5] Build Track Struct ----------------------------
p5 = uipanel(f,'Title','[5] Build Track Struct  (curated XML/CSV -> TrackStruct.mat)', ...
    'Units','pixels','Position',[10 540 860 90]);
lbl(p5,'Time unit:',              [10 48 90 20]);
ddTime = pop(p5,{'frame','seconds'}, [105 48 110 22]);
lbl(p5,'FileSuffix (opt):',       [240 48 110 20]);
eSuffix = edt(p5,'',              [355 48 120 22],true);
lamp5 = lamp(p5,[10 14]);
lbl(p5,'writes analysis/TrackStruct.mat', [35 12 320 20]);
btn(p5,'Build Tracks',            [695 10 150 26],@onBuildStruct,true);

% ---------------- Panel: [5.5] Setup run folder ----------------------------
p55 = uipanel(f,'Title','[5.5] Setup Run Folder  (scaffold analysis/ + name images to the suite convention)', ...
    'Units','pixels','Position',[10 404 860 130]);
lbl(p55,'Mito image:',            [10 92 120 20]);
eMito = edt(p55,'',               [135 92 560 22],false);
btn(p55,'Pick…',                  [705 92 100 24],@(o,e)onPickImg('mito',eMito),false);
lbl(p55,'MaxInt RGB image:',      [10 62 120 20]);
eMax  = edt(p55,'',               [135 62 560 22],false);
btn(p55,'Pick…',                  [705 62 100 24],@(o,e)onPickImg('maxint',eMax),false);
lbl(p55,'Mito name suffix:',      [10 32 120 20]);
ddSuffix = pop(p55,{'_3_TA_BC.tif  (reorienter v2)', ...
    '_3_maxS2N_8bit.tif  (reorienter v3)'}, [135 32 320 22]);
btn(p55,'Calibration…',           [470 31 135 24],@onCalibration,false);
lamp55 = lamp(p55,[10 6]);
lbl(p55,'copies + renames images to Tracks(i).file', [35 4 380 20]);
btn(p55,'Setup Folders',          [705 4 100 26],@onSetupFolders,true);

% ---------------- Panel: [6] Run ContactSites ------------------------------
p6 = uipanel(f,'Title','[6] Run ContactSites Suite  (staged; halts at each Fiji / Wacom gate)', ...
    'Units','pixels','Position',[10 258 860 140]);
stages = {'density','locdens','quickplot','csid','mapper','part2', ...
          'snaprename','refiner','ensemble','builder','accum'};
lbl(p6,'Start stage:',            [10 100 100 20]);
ddStart = pop(p6,stages,          [115 100 140 22]);
lbl(p6,'Stop after (opt):',       [280 100 120 20]);
ddStop  = pop(p6,[{'(next gate)'} stages], [405 100 140 22]);
cbJBM   = chk(p6,'JBM / Deff branch',true,               [115 70 200 20]);
cbMito  = chk(p6,'Mito-flagged CSs only (refiner1/ensemble1)',false, [115 44 340 20]);
lamp6 = lamp(p6,[10 14]);
lbl(p6,'runs to the next manual gate, then resume from Start stage', [35 12 420 20]);
btn(p6,'Run / Resume',            [695 10 150 26],@onRunCS,true);

% ---------------- Status + Log ---------------------------------------------
pS = uipanel(f,'Title','Status','Units','pixels','Position',[10 206 860 46]);
lbl(pS,'5 Import',  [10 6 70 20]);  lampImp = lamp(pS,[82 8]);
lbl(pS,'5.5 Setup', [110 6 70 20]); lampSet = lamp(pS,[182 8]);
lbl(pS,'6 CS done', [210 6 70 20]); lampCS  = lamp(pS,[288 8]);

pL = uipanel(f,'Title','Log','Units','pixels','Position',[10 10 860 190]);
logArea = uicontrol(pL,'Style','listbox','Units','pixels', ...
    'Position',[8 8 844 165],'String',{'Ready. Pick a project folder to begin.'}, ...
    'FontName',FIXED,'FontSize',11,'Min',0,'Max',2,'Value',1, ...
    'BackgroundColor',[1 1 1]);

% =====================================================================
% CALLBACKS  (nested — share all handles + S above)
% =====================================================================
    function say(varargin)
        msg = sprintf(varargin{:});
        ts  = datestr(now,'HH:MM:SS'); %#ok<TNOW1,DATST>
        if ~ishghandle(logArea)          % window closed mid-run: fall back to console
            fprintf('[%s] %s\n',ts,msg); return;
        end
        old = get(logArea,'String');
        if ischar(old), old = cellstr(old); end
        new = [old; {sprintf('[%s] %s',ts,msg)}];
        set(logArea,'String',new,'Value',numel(new), ...
            'ListboxTop',max(1,numel(new)-8));
        drawnow;
    end

    function onBrowseProject(~,~)
        d = uigetdir(pwd,'Choose project folder');
        if isequal(d,0), return; end
        S.projectDir = d; set(eProj,'String',d);
        say('project = %s',d);
        refreshLamps();
    end

    function onBrowseSuite(~,~)
        d = uigetdir(S.suitePath,'Choose ContactSites suite root');
        if isequal(d,0), return; end
        S.suitePath = d; set(eSuite,'String',d); addpath(genpath(d));
        say('ContactSites path = %s',d);
    end

    function onPickImg(kind,ef)
        [fn,pth] = uigetfile({'*.tif;*.tiff','TIFF images'},['Pick ' kind ' image']);
        if isequal(fn,0), return; end
        full = fullfile(pth,fn); S.(kind) = full; set(ef,'String',full);
        say('%s image = %s',kind,fn);
    end

    function ok = needProject()
        ok = ~isempty(S.projectDir) && isfolder(S.projectDir);
        if ~ok, errordlg('Pick a valid project folder first.','No project'); end
    end

    function analysisDir = getAnalysisDir()
        analysisDir = fullfile(S.projectDir,uval(eAnalysis));
    end

    function onBuildStruct(~,~)
        if ~needProject(), return; end
        tracksDir = fullfile(S.projectDir,uval(eTracks));
        if ~isfolder(tracksDir)
            errordlg(sprintf('tracks/ folder not found:\n%s',tracksDir),'Missing'); return;
        end
        analysisDir = getAnalysisDir();
        if ~isfolder(analysisDir), mkdir(analysisDir); end
        set(f,'Pointer','watch'); drawnow;
        clean = onCleanup(@() safeArrow(f)); %#ok<NASGU>
        try
            say('build_trackstruct(%s, TimeUnit=%s, FileSuffix="%s")', ...
                tracksDir,uval(ddTime),uval(eSuffix));
            % NB: no "Tracks =" here — pipeline_gui has nested functions, so its
            % workspace is static and evalc cannot add a new variable to it.
            % build_trackstruct saves to disk ('Save',true); we don't need the return.
            out = evalc(sprintf(['build_trackstruct(''%s'',''TimeUnit'',''%s'',' ...
                '''FileSuffix'',''%s'',''AttachCSV'',true,''Save'',true,''Verbose'',true);'], ...
                tracksDir,uval(ddTime),uval(eSuffix)));
            say('%s',strtrim(out));
            % move the struct next to the CS working dir
            src = fullfile(tracksDir,'TrackStruct.mat');
            if isfile(src)
                movefile(src,fullfile(analysisDir,'TrackStruct.mat'));
                say('-> moved TrackStruct.mat into %s',analysisDir);
            end
            say('IMPORT complete.');
        catch ME
            say('ERROR: %s',ME.message);
            errordlg(ME.message,'build_trackstruct failed');
        end
        refreshLamps();
    end

    function onSetupFolders(~,~)
        if ~needProject(), return; end
        analysisDir = getAnalysisDir();
        if ~isfile(fullfile(analysisDir,'TrackStruct.mat')) && ...
           ~isfile(fullfile(analysisDir,'Tracks.mat'))
            errordlg('Build the Track struct (step 5) first.','No TrackStruct'); return;
        end
        suffix = regexp(uval(ddSuffix),'^\S+','match','once');  % strip the "(reorienter …)" note
        args = {analysisDir,'MitoSuffix',suffix};
        if ~isempty(S.mito),   args = [args {'Mito',S.mito}]; end
        if ~isempty(S.maxint), args = [args {'MaxInt',S.maxint}]; end
        if ~isempty(S.er),     args = [args {'ER',S.er}]; end
        set(f,'Pointer','watch'); drawnow;
        clean = onCleanup(@() safeArrow(f)); %#ok<NASGU>
        try
            call = ['setup_run_folder(' argstr(args) ');'];
            say('%s',call);
            out = evalc(call);
            say('%s',strtrim(out));
            say('SETUP complete.');
        catch ME
            say('ERROR: %s',ME.message);
            errordlg(ME.message,'setup_run_folder failed');
        end
        refreshLamps();
    end

    function onCalibration(~,~)
        % Manual + auto per-dataset calibration -> writes analysis/cs_calib.mat,
        % which cs_config() reads to override FOV / pixel size / dt for this run.
        % Use it when your camera differs from the defaults, OR when the image
        % metadata was stripped and you must type what you see (ImageJ ▸ Image ▸
        % Properties). Set this BEFORE [6] so the suite picks up the right scale.
        if ~needProject(), return; end
        analysisDir = getAnalysisDir();
        if ~isfolder(analysisDir), mkdir(analysisDir); end
        tracksDir = fullfile(S.projectDir,uval(eTracks));
        if exist('calibration_panel','file')~=2
            errordlg('calibration_panel.m not found (expected in drivers/).','Calibration'); return;
        end
        try
            calib = calibration_panel(analysisDir,'TracksDir',tracksDir,'Image',S.mito);
            if isempty(calib)
                say('calibration: cancelled (unchanged).');
            else
                say('calibration saved -> %s',fullfile(analysisDir,'cs_calib.mat'));
                say('  FOV=%.4g um | pixel=%s um/px | dt=%.5g s | bin=%g nm', ...
                    calib.fovUm,num2str(calib.pixSizeUm),calib.dt_s,calib.binNm);
            end
        catch ME
            say('ERROR (calibration): %s',ME.message);
            errordlg(ME.message,'calibration_panel failed');
        end
    end

    function onRunCS(~,~)
        if ~needProject(), return; end
        analysisDir = getAnalysisDir();
        stopAfter = uval(ddStop); if strcmp(stopAfter,'(next gate)'), stopAfter=''; end
        argsC = {analysisDir,'StartStage',uval(ddStart),'JBM',uval(cbJBM), ...
                 'MitoOnly',uval(cbMito),'SuitePath',S.suitePath};
        if ~isempty(stopAfter), argsC = [argsC {'StopAfter',stopAfter}]; end
        % preflight the run folder if the robust validator is on the path
        if exist('cs_preflight','file')==2
            try
                say('preflight: cs_preflight(%s, Stage=%s)',analysisDir,uval(ddStart));
                pout = evalc(sprintf('cs_preflight(''%s'',''Stage'',''%s'');', ...
                    analysisDir,uval(ddStart)));
                say('%s',strtrim(pout));
            catch ME
                say('preflight skipped: %s',ME.message);
            end
        end
        set(f,'Pointer','watch'); drawnow;
        clean = onCleanup(@() safeArrow(f)); %#ok<NASGU>
        try
            % no "state =" — static workspace (nested functions); driver persists
            % its own progress to disk, so the return value isn't needed here.
            call = ['run_contactsite_analysis(' argstr(argsC) ');'];
            say('%s',call);
            out = evalc(call);
            say('%s',strtrim(out));
        catch ME
            say('ERROR: %s',ME.message);
            errordlg(ME.message,'run_contactsite_analysis failed');
        end
        refreshLamps();
    end

    function refreshLamps()
        if ~ishghandle(f), return; end   % window closed: nothing to paint
        imp = false; setp = false; csd = false;
        if ~isempty(S.projectDir) && isfolder(S.projectDir)
            a = getAnalysisDir();
            imp  = isfile(fullfile(a,'TrackStruct.mat')) || isfile(fullfile(a,'Tracks.mat'));
            setp = isfolder(fullfile(a,'Mito')) || isfolder(fullfile(a,'MaxInt')) || ...
                   isfolder(fullfile(a,'Densities'));
            csd  = isfile(fullfile(a,'CS_final.mat')) || isfolder(fullfile(a,'TrackData'));
        end
        set([lamp5  lampImp],'BackgroundColor',tern(imp,GREEN,GREY));
        set([lamp55 lampSet],'BackgroundColor',tern(setp,GREEN,GREY));
        set([lamp6  lampCS ],'BackgroundColor',tern(csd,GREEN,GREY));
    end

    function s = argstr(args)
        parts = cell(1,numel(args));
        for i=1:numel(args)
            v = args{i};
            if ischar(v) || isstring(v), parts{i} = ['''' char(v) ''''];
            elseif islogical(v),         parts{i} = mat2str(v);
            else,                        parts{i} = num2str(v);
            end
        end
        s = strjoin(parts,',');
    end

    function y = tern(c,a,b), if c, y=a; else, y=b; end, end

    % ---- classic-toolkit widget builders (work on every release + Octave) --
    function h = lbl(parent,str,pos)
        h = uicontrol(parent,'Style','text','String',str,'Units','pixels', ...
            'Position',pos,'HorizontalAlignment','left', ...
            'BackgroundColor',get(parent,'BackgroundColor'));
    end
    function h = edt(parent,str,pos,editable)
        if editable, en='on'; else, en='inactive'; end   % inactive = readable, non-editable
        h = uicontrol(parent,'Style','edit','String',str,'Units','pixels', ...
            'Position',pos,'HorizontalAlignment','left', ...
            'BackgroundColor',[1 1 1],'Enable',en);
    end
    function h = btn(parent,str,pos,cb,bold)
        if bold, fw='bold'; else, fw='normal'; end
        h = uicontrol(parent,'Style','pushbutton','String',str,'Units','pixels', ...
            'Position',pos,'FontWeight',fw,'Callback',cb);
    end
    function h = pop(parent,items,pos)
        h = uicontrol(parent,'Style','popupmenu','String',items,'Units','pixels', ...
            'Position',pos,'BackgroundColor',[1 1 1]);
    end
    function h = chk(parent,str,val,pos)
        h = uicontrol(parent,'Style','checkbox','String',str,'Value',double(val), ...
            'Units','pixels','Position',pos, ...
            'BackgroundColor',get(parent,'BackgroundColor'));
    end
    function h = lamp(parent,xy)
        h = uicontrol(parent,'Style','text','String','','Units','pixels', ...
            'Position',[xy(1) xy(2) 18 18],'BackgroundColor',GREY);
    end
    function safeArrow(fh)   % restore cursor only if the window still exists
        if ishghandle(fh), set(fh,'Pointer','arrow'); end
    end
    function v = uval(h)     % read a uicontrol value uniformly
        switch get(h,'Style')
            case 'popupmenu', it = get(h,'String'); v = it{get(h,'Value')};
            case 'checkbox',  v = logical(get(h,'Value'));
            otherwise,        v = get(h,'String');   % edit / text
        end
    end

refreshLamps();
end
