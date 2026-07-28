function calib = calibration_panel(analysisDir, varargin)
%CALIBRATION_PANEL  Per-dataset calibration entry (manual + auto-detect).
%
% Writes <analysisDir>/cs_calib.mat (a struct named 'calib') which cs_config()
% reads to override the suite's field of view / pixel size / frame interval for
% THAT run only. Use it whenever your camera differs from the defaults, or when
% acquisition/export stripped the image metadata and you must type the values
% you see (e.g. in ImageJ ▸ Image ▸ Properties…).
%
% USAGE
%   calib = calibration_panel(analysisDir)
%   calib = calibration_panel(analysisDir,'TracksDir',td,'Image',img,'XML',xml)
%
% NAME-VALUE
%   'Image'     : a TIFF to read pixel size / FOV from (else auto-located)
%   'XML'       : a TrackMate *_tracks.xml to read dt from (else auto-located)
%   'TracksDir' : folder to search for the tracks XML (default <analysisDir>/../tracks)
%
% RETURNS the saved calib struct, or [] if the user cancelled.
%
% Built on the classic figure + uicontrol toolkit so it runs on any MATLAB
% release (and Octave), matching pipeline_gui.

ip = inputParser;
ip.addParameter('Image','',    @(s) ischar(s) || (isstring(s) && isscalar(s)));
ip.addParameter('XML','',      @(s) ischar(s) || (isstring(s) && isscalar(s)));
ip.addParameter('TracksDir','',@(s) ischar(s) || (isstring(s) && isscalar(s)));
ip.parse(varargin{:});
opt = ip.Results;
opt.Image = char(opt.Image); opt.XML = char(opt.XML); opt.TracksDir = char(opt.TracksDir);

if nargin < 1 || isempty(analysisDir) || ~isfolder(analysisDir)
    error('calibration_panel:noDir','Pass an existing analysis folder.');
end
if isempty(opt.TracksDir)
    opt.TracksDir = fullfile(fileparts(analysisDir),'tracks');
end
calibFile = fullfile(analysisDir,'cs_calib.mat');

calib = [];   % return value; set on Save, stays [] on Cancel

% ---- initial values: existing cs_calib.mat, else best-effort auto-detect ----
v = struct('pixSizeUm',NaN,'nPix',NaN,'fovUm',NaN,'dt_s',NaN,'binNm',30);
srcNote = 'defaults';
if exist(calibFile,'file')==2
    try
        L = load(calibFile);
        if isfield(L,'calib'), c0 = L.calib;
            v.pixSizeUm = getf(c0,'pixSizeUm',NaN);
            v.nPix      = getf(c0,'nPix',NaN);
            v.fovUm     = getf(c0,'fovUm',NaN);
            v.dt_s      = getf(c0,'dt_s',NaN);
            v.binNm     = getf(c0,'binNm',30);
            srcNote = 'loaded existing cs_calib.mat';
        end
    catch
    end
else
    a = try_autodetect();
    if ~isempty(a)
        v.pixSizeUm=a.pixSizeUm; v.nPix=a.nPix; v.fovUm=a.fovUm; v.dt_s=a.dt_s;
        srcNote = 'auto-detected from metadata (confirm below)';
    end
end

% ===========================================================================
% BUILD THE DIALOG (classic figure; pixels, y from bottom)
% ===========================================================================
BG = [0.94 0.94 0.94];
f = figure('Name','Calibration — this dataset','NumberTitle','off', ...
    'MenuBar','none','ToolBar','none','Color',BG,'Units','pixels', ...
    'Position',[300 250 480 400],'Resize','off','WindowStyle','modal', ...
    'IntegerHandle','off','CloseRequestFcn',@onCancel);

txt('Physical calibration for this run',[20 366 440 22],'bold',11);
txt(['Auto-filled from file metadata when present. If your camera differs, or ' ...
     'the metadata was stripped on export, TYPE the values you see (ImageJ ▸ ' ...
     'Image ▸ Properties). Saved to cs_calib.mat; used for this run only.'], ...
     [20 320 440 42],'normal',9);

txt('Pixel size:',        [20 288 150 20],'normal',10);
ePix = ebox(fmt(v.pixSizeUm), [175 288 110 24], @onScaleChanged);
txt('µm / px',             [292 288 80 20],'normal',10);

txt('Image size:',        [20 258 150 20],'normal',10);
eNpx = ebox(fmt(v.nPix),   [175 258 110 24], @onScaleChanged);
txt('px (width)',          [292 258 90 20],'normal',10);

txt('Field of view:',     [20 228 150 20],'normal',10);
eFov = ebox(fmt(v.fovUm),  [175 228 110 24], @noop);
txt('µm',                  [292 228 80 20],'normal',10);
cFovDirect = uicontrol(f,'Style','checkbox','String','enter FOV directly', ...
    'Units','pixels','Position',[175 206 200 18],'BackgroundColor',BG, ...
    'Value',0,'Callback',@onFovDirectToggle);

txt('Frame interval (dt):',[20 172 150 20],'normal',10);
eDt  = ebox(fmt(v.dt_s),   [175 172 110 24], @noop);
txt('s',                   [292 172 80 20],'normal',10);

txt('Density bin:',       [20 142 150 20],'normal',10);
eBin = ebox(fmt(v.binNm),  [175 142 110 24], @noop);
txt('nm (usually 30)',     [292 142 120 20],'normal',10);

sStatus = txt(srcNote,     [20 104 440 30],'normal',9);
set(sStatus,'ForegroundColor',[0.25 0.35 0.55]);

uicontrol(f,'Style','pushbutton','String','Auto-detect from files','Units','pixels', ...
    'Position',[20 24 165 32],'Callback',@onAuto);
uicontrol(f,'Style','pushbutton','String','Cancel','Units','pixels', ...
    'Position',[285 24 85 32],'Callback',@onCancel);
uicontrol(f,'Style','pushbutton','String','Save','Units','pixels','FontWeight','bold', ...
    'Position',[378 24 85 32],'Callback',@onSave);

onScaleChanged();          % initialise FOV field state
uiwait(f);                 % block until Save / Cancel
% -------- (execution resumes here after uiresume) --------
return

% ===========================================================================
% NESTED CALLBACKS
% ===========================================================================
    function onScaleChanged(~,~)
        if get(cFovDirect,'Value'), return; end     % user owns FOV, don't clobber
        px = str2double(get(ePix,'String'));
        np = str2double(get(eNpx,'String'));
        if isfinite(px) && px>0 && isfinite(np) && np>0
            set(eFov,'String',fmt(px*np),'Enable','inactive');
        else
            set(eFov,'Enable','inactive');
        end
    end

    function onFovDirectToggle(~,~)
        if get(cFovDirect,'Value')
            set(eFov,'Enable','on');
            setStatus('FOV is now typed directly (pixel size × image size ignored for FOV).');
        else
            set(eFov,'Enable','inactive');
            onScaleChanged();
        end
    end

    function onAuto(~,~)
        a = try_autodetect();
        if isempty(a)
            setStatus('Auto-detect: no readable image/XML metadata found. Enter values manually.');
            return;
        end
        if isfinite(a.pixSizeUm), set(ePix,'String',fmt(a.pixSizeUm)); end
        if isfinite(a.nPix),      set(eNpx,'String',fmt(a.nPix));      end
        if isfinite(a.dt_s),      set(eDt, 'String',fmt(a.dt_s));      end
        if get(cFovDirect,'Value') && isfinite(a.fovUm)
            set(eFov,'String',fmt(a.fovUm));
        else
            onScaleChanged();
        end
        miss = {};
        if ~isfinite(a.pixSizeUm), miss{end+1}='pixel size'; end
        if ~isfinite(a.dt_s),      miss{end+1}='frame interval'; end
        if isempty(miss)
            setStatus('Auto-detect: filled from metadata — confirm and Save.');
        else
            setStatus(sprintf('Auto-detect: %s missing from metadata — enter %s by hand.', ...
                strjoin(miss,' and '), strjoin(miss,' and ')));
        end
    end

    function onSave(~,~)
        px  = str2double(get(ePix,'String'));
        np  = str2double(get(eNpx,'String'));
        fov = str2double(get(eFov,'String'));
        dt  = str2double(get(eDt, 'String'));
        bin = str2double(get(eBin,'String'));
        if ~(isfinite(fov) && fov>0) && isfinite(px) && px>0 && isfinite(np) && np>0
            fov = px*np;   % derive if not typed
        end
        if ~(isfinite(fov) && fov>0)
            setStatus('Cannot save: enter a Field of view (µm), or a pixel size AND image size.');
            return;
        end
        if ~(isfinite(dt) && dt>0)
            setStatus('Cannot save: enter a Frame interval dt (s) — it sets physical Deff.');
            return;
        end
        if ~(isfinite(bin) && bin>0), bin = 30; end
        c = struct();
        c.pixSizeUm = px;                 % may be NaN if FOV entered directly
        c.nPix      = np;
        c.fovUm     = fov;
        c.snapFovUm = fov;                % density-map SF uses this
        c.dt_s      = dt;
        c.binNm     = bin;
        c.source    = 'manual/panel';
        c.savedFrom = analysisDir;
        calib = c;                        % the variable cs_config loads AND the return value
        try
            save(calibFile,'calib');
        catch ME
            setStatus(['Could not write cs_calib.mat: ' ME.message]);
            calib = [];
            return;
        end
        uiresume(f);
        if ishghandle(f), delete(f); end
    end

    function onCancel(~,~)
        calib = [];
        uiresume(f);
        if ishghandle(f), delete(f); end
    end

    function a = try_autodetect()
        a = [];
        if exist('read_calibration','file')~=2, return; end
        img = opt.Image; if isempty(img) || exist(img,'file')~=2, img = local_find_image(analysisDir); end
        xml = opt.XML;   if isempty(xml) || exist(xml,'file')~=2, xml = local_find_xml(opt.TracksDir); end
        try
            a = read_calibration('Image',img,'XML',xml);
        catch
            a = [];
        end
    end

    function setStatus(msg), if ishghandle(sStatus), set(sStatus,'String',msg); end, end
    function noop(~,~), end

    % ---- classic widget helpers -------------------------------------------
    function h = txt(str,pos,weight,fs)
        h = uicontrol(f,'Style','text','String',str,'Units','pixels','Position',pos, ...
            'HorizontalAlignment','left','BackgroundColor',BG,'FontWeight',weight,'FontSize',fs);
    end
    function h = ebox(str,pos,cb)
        h = uicontrol(f,'Style','edit','String',str,'Units','pixels','Position',pos, ...
            'HorizontalAlignment','left','BackgroundColor',[1 1 1],'Callback',cb);
    end
end

% ===========================================================================
function s = fmt(x)
if isempty(x) || ~isfinite(x), s = ''; else, s = num2str(x); end
end

function y = getf(s,f,dflt)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), y = s.(f); else, y = dflt; end
end

function p = local_find_image(analysisDir)
% Prefer a mito or MaxInt image; fall back to any TIFF in the analysis folder.
p = '';
cands = {fullfile(analysisDir,'Mito'), fullfile(analysisDir,'MaxInt'), analysisDir};
for k = 1:numel(cands)
    if isfolder(cands{k})
        L = dir(fullfile(cands{k},'*.tif'));
        L = L(~[L.isdir]);
        if ~isempty(L), p = fullfile(L(1).folder,L(1).name); return; end
    end
end
end

function p = local_find_xml(tracksDir)
% Prefer a filtered/curated tracks XML, else any *_tracks.xml.
p = '';
if isempty(tracksDir) || ~isfolder(tracksDir), return; end
L = dir(fullfile(tracksDir,'*_tracks_filtered.xml'));
if isempty(L), L = dir(fullfile(tracksDir,'*_tracks.xml')); end
L = L(~[L.isdir]);
if ~isempty(L), p = fullfile(L(1).folder,L(1).name); end
end
