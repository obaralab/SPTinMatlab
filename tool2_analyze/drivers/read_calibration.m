function calib = read_calibration(varargin)
%READ_CALIBRATION  Best-effort per-dataset calibration from file metadata.
%
% Reads pixel size / field of view from a TIFF's resolution tags and the frame
% interval from a TrackMate XML. This is a CONVENIENCE PREFILL for the manual
% Calibration panel — TIFF resolution tags and TrackMate frameInterval are
% stripped by some acquisition/export chains, which is exactly why manual entry
% exists. This function therefore NEVER errors: anything it cannot read comes
% back as NaN so the caller falls back to manual entry.
%
% USAGE
%   calib = read_calibration('Image', tifPath, 'XML', trackmateXmlPath)
%   calib = read_calibration('Image', tifPath)      % pixel size + FOV only
%
% OUTPUT struct
%   .pixSizeUm   camera pixel size, µm/px         (NaN if unknown)
%   .nPix        image dimension, px (max of H,W) (NaN if unknown)
%   .fovUm       field of view, µm (= pixSizeUm*nPix)
%   .dt_s        frame interval, s                (NaN if unknown)
%   .pixSize_src / .fov_src / .dt_src : 'metadata' | 'missing'
%
% Assumes a square field of view (max of height/width). Correct or override any
% value in the Calibration panel before running.

ip = inputParser;
ip.addParameter('Image','', @(s) ischar(s) || (isstring(s) && isscalar(s)));
ip.addParameter('XML',  '', @(s) ischar(s) || (isstring(s) && isscalar(s)));
ip.parse(varargin{:});
imgPath = char(ip.Results.Image);
xmlPath = char(ip.Results.XML);

calib = struct('pixSizeUm',NaN,'nPix',NaN,'fovUm',NaN,'dt_s',NaN, ...
               'pixSize_src','missing','fov_src','missing','dt_src','missing');

% ---- pixel size + FOV from the TIFF ---------------------------------------
if ~isempty(imgPath) && exist(imgPath,'file')==2
    try
        info = imfinfo(imgPath);
        info = info(1);
        nPix = NaN;
        if isfield(info,'Height') && isfield(info,'Width')
            nPix = max(double(info.Height), double(info.Width));   % square FOV assumed
        end
        umPerPx = local_um_per_px(info);
        if isfinite(umPerPx) && umPerPx > 0
            calib.pixSizeUm  = umPerPx;
            calib.pixSize_src = 'metadata';
            if isfinite(nPix) && nPix > 0
                calib.nPix   = nPix;
                calib.fovUm  = umPerPx * nPix;
                calib.fov_src = 'metadata';
            end
        elseif isfinite(nPix) && nPix > 0
            calib.nPix = nPix;      % have the size, not the scale
        end
    catch
        % leave pixel size / FOV as NaN / 'missing'
    end
end

% ---- frame interval from the TrackMate XML --------------------------------
if ~isempty(xmlPath) && exist(xmlPath,'file')==2
    try
        xdoc = xmlread(xmlPath);
        root = xdoc.getDocumentElement();
        dtv  = str2double(root.getAttribute('frameInterval'));
        if isfinite(dtv) && dtv > 0
            calib.dt_s   = dtv;
            calib.dt_src = 'metadata';
        end
    catch
        % leave dt as NaN / 'missing'
    end
end
end

% ===========================================================================
function um = local_um_per_px(info)
% Interpret a TIFF's XResolution into µm/px across the common conventions.
% ImageJ typically writes XResolution as *pixels per micron* with
% ResolutionUnit 'None' and 'unit=micron' in the ImageDescription; baseline
% TIFF uses pixels-per-cm / -inch. Ambiguous cases fall back to px/µm and can
% be corrected by hand in the panel.
um = NaN;
if ~isfield(info,'XResolution') || isempty(info.XResolution), return; end
xr = double(info.XResolution);
if ~isfinite(xr) || xr <= 0, return; end

unit = '';
if isfield(info,'ResolutionUnit') && ~isempty(info.ResolutionUnit)
    unit = lower(char(string(info.ResolutionUnit)));
end
desc = '';
if isfield(info,'ImageDescription') && ~isempty(info.ImageDescription)
    desc = lower(char(info.ImageDescription));
end
micronDesc = contains(desc,'unit=micron') || contains(desc,'unit=um') || contains(desc,'unit=micro');

if micronDesc || any(strcmp(unit,{'none','undefined',''}))
    um = 1 / xr;            % ImageJ px-per-µm
elseif contains(unit,'cent')
    um = 1e4 / xr;          % px-per-cm
elseif contains(unit,'inch')
    um = 25400 / xr;        % px-per-inch
else
    um = 1 / xr;            % last resort: assume px-per-µm
end
end
