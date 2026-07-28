function cfg = cs_config(calibSource)
%CS_CONFIG  Single source of truth for the ContactSites pipeline.
%
% Every constant, folder name, and file-naming rule the suite depends on lives
% HERE — instead of being scattered as magic numbers across ~30 scripts. Edit
% this file to retarget the pipeline; the scripts read from it.
%
%   cfg = cs_config();            % defaults, optionally overridden by a per-run
%                                 % cs_calib.mat found in the CURRENT folder
%   cfg = cs_config(dirOrFile);  % load cs_calib.mat from a folder or a .mat path
%   cfg = cs_config(calibStruct);% apply an in-memory calib struct directly
%
% PER-RUN CALIBRATION (multi-camera support)
%   Different cameras have different pixel sizes and fields of view, and
%   different acquisitions have different frame intervals. Rather than editing
%   the constants below for every dataset, drop a 'cs_calib.mat' (a struct named
%   'calib') into the run's working folder (its analysis/ directory, which the
%   suite runs cd'd into). cs_config() picks it up automatically and overrides
%   the physical calibration for that run only. Create it from the GUI
%   ("Calibration…" button) or with calibration_panel.m / read_calibration.m.
%
%   Recognised calib fields (any subset; missing ones keep the defaults):
%     .pixSizeUm  camera pixel size in object space (µm/px)
%     .fovUm      field of view (µm)  ->  also sets the density-map scale
%     .dt_s       frame interval (s)
%     .snapFovUm  density-image FOV for SF; defaults to .fovUm if omitted
%
% Reproducibility note: the values below are the defaults for the integrated
% SPT pipeline (importer sets Tracks(i).file to the full base name). To
% reproduce the original Nature-paper runs — whose filenames carried a 7-char
% trailing tag — set cfg.FileTagChars = 7 (see cellBase.m).

% ---- microscope / physical calibration (DEFAULTS) -------------------------
cfg.FOV_um       = 27.61;    % field of view, microns (256 px * 0.10785 um/px)
cfg.PixSize_um   = 0.10785;  % camera pixel size in object space, microns
cfg.DL_PixSize_um= cfg.PixSize_um; % pixel size (um/px) of the diffraction-limited mito/MaxInt STRUCTURE
                                   % images used to place & reorient contact sites. Defaults to the SPT
                                   % pixel size; set calib.dlPixSizeUm if the structure channel differs.
                                   % Replaces the paper's hardcoded 6.25 px/um (=1/0.16).
cfg.FrameInt_s   = 0.020064; % frame interval, seconds (suite historically rounds to 0.020)

% ---- density-map scale factor ---------------------------------------------
% SF converts density-image pixels -> microns: SF = SnapFOV_um / size(imG,1).
% The density map (_rho.tif) spans FOV_um, so SnapFOV_um SHOULD equal FOV_um.
% NOTE: the original ContactSiteMapper.m used 20.48 here while
% ContactSiteMapperNoDeff.m used 27.61 — that was the Nature rig's 20.48 µm FOV
% leaking onto 27.61 µm data. Both mappers now derive SF from SnapFOV_um.
cfg.SnapFOV_um   = cfg.FOV_um;

% ---- filename convention ---------------------------------------------------
% Number of trailing characters that distinguish Tracks(i).file from the
% per-cell image "base". 0 = the integrated pipeline (file IS the base).
% 7 = the original paper convention (file = <base> + 7-char tag).
cfg.FileTagChars = 0;

% Canonical image-name suffixes, appended to the cell base:
cfg.suffix.MaxIntRGB = '_3_MaxInt_RGB.tif';
cfg.suffix.Density   = '_rho.tif';
cfg.suffix.MitoV2    = '_3_TA_BC.tif';       % Final/CS_reorienter_v2
cfg.suffix.MitoV3    = '_3_maxS2N_8bit.tif'; % Final/CS_reorienter_v3
cfg.suffix.CSsites   = '_CSsites.txt';
cfg.suffix.CSdataMat = '_CSdata.mat';
cfg.suffix.TracksMat = '_Tracks.mat';

% ---- canonical folder names (ONE case, everywhere) ------------------------
% The original suite wrote 'CSData' in the refiners but read 'CSdata'
% elsewhere; on a case-sensitive filesystem that silently splits the data.
% All robust scripts use these names.
cfg.dir.MaxInt    = 'MaxInt';
cfg.dir.Mito      = 'Mito';
cfg.dir.ER        = 'ER';
cfg.dir.Maps      = 'Maps';
cfg.dir.Densities = 'Densities';
cfg.dir.csIDs     = 'csIDs';
cfg.dir.TrackData = 'TrackData';
cfg.dir.CSdata    = 'CSdata';   % canonical (was 'CSData' in refiners)
cfg.dir.CSsnaps   = 'CSsnaps';

% ---- per-run calibration override -----------------------------------------
% Default source: cs_calib.mat in the working directory (the run's analysis/).
if nargin < 1 || isempty(calibSource)
    calibSource = fullfile(pwd, 'cs_calib.mat');
end
cfg.CalibSource = 'defaults';
calib = local_resolve_calib(calibSource);   % [] if nothing usable found
if ~isempty(calib) && isstruct(calib)
    if local_good(calib,'pixSizeUm'), cfg.PixSize_um = double(calib.pixSizeUm); cfg.DL_PixSize_um = cfg.PixSize_um; end
    if local_good(calib,'fovUm'),     cfg.FOV_um     = double(calib.fovUm);     end
    if local_good(calib,'dt_s'),      cfg.FrameInt_s = double(calib.dt_s);      end
    if local_good(calib,'snapFovUm'), cfg.SnapFOV_um = double(calib.snapFovUm);
    else,                             cfg.SnapFOV_um = cfg.FOV_um; end
    if local_good(calib,'dlPixSizeUm'), cfg.DL_PixSize_um = double(calib.dlPixSizeUm); end
    if ischar(calibSource) || (isstring(calibSource) && isscalar(calibSource))
        cfg.CalibSource = char(calibSource);
    else
        cfg.CalibSource = 'calib struct (in memory)';
    end
end
end

% ===========================================================================
function calib = local_resolve_calib(src)
% Return a calib struct from a struct, a .mat path, or a folder holding
% cs_calib.mat. Never errors — any problem yields [] (defaults are used).
calib = [];
try
    if isstruct(src)
        calib = src; return;
    end
    if ~(ischar(src) || (isstring(src) && isscalar(src))), return; end
    src = char(src);
    if isempty(src), return; end
    if isfolder(src)
        src = fullfile(src, 'cs_calib.mat');
    end
    if exist(src, 'file') ~= 2, return; end
    S = load(src);
    if isfield(S, 'calib') && isstruct(S.calib)
        calib = S.calib;
    else
        % accept the first struct variable in the file
        fn = fieldnames(S);
        for k = 1:numel(fn)
            if isstruct(S.(fn{k})), calib = S.(fn{k}); break; end
        end
    end
catch
    calib = [];   % defensive: a bad calib file must not break the suite
end
end

% ===========================================================================
function tf = local_good(s, f)
% True when field f exists and is a positive finite scalar.
tf = isfield(s, f) && isnumeric(s.(f)) && isscalar(s.(f)) && ...
     isfinite(s.(f)) && s.(f) > 0;
end
