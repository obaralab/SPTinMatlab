function px = spt_pixel_size(tiffPath)
%SPT_PIXEL_SIZE  Best-effort µm/pixel from a TIFF's resolution tags. Returns [] if not determinable.
%
% Reads XResolution (pixels per ResolutionUnit) + ResolutionUnit (inch/cm) and converts to µm/px.
% Only returns a value in a plausible microscopy range (0.01–2 µm/px); otherwise [] so the caller
% keeps the manual default. Many microscopy TIFFs lack meaningful tags — that's the [] case.
px = [];
try
    info = imfinfo(tiffPath); info = info(1);
    if ~isfield(info,'XResolution') || isempty(info.XResolution) || info.XResolution <= 0, return; end
    xr = double(info.XResolution);                     % pixels per ResolutionUnit
    unit = 3;                                          % default assume cm
    if isfield(info,'ResolutionUnit') && ~isempty(info.ResolutionUnit)
        ru = info.ResolutionUnit;
        if ischar(ru)
            if     strcmpi(ru,'Inch'),        unit = 2;
            elseif strcmpi(ru,'Centimeter'),  unit = 3;
            else,                             unit = 0; end
        else
            unit = double(ru);                         % 2 = inch, 3 = cm, 1 = none
        end
    end
    switch unit
        case 2, umPerUnit = 25400;                     % inch
        case 3, umPerUnit = 10000;                     % cm
        otherwise, return;                             % none/unknown -> undeterminable
    end
    cand = umPerUnit / xr;                             % µm per pixel
    if isfinite(cand) && cand >= 0.01 && cand <= 2, px = cand; end
catch
    px = [];
end
end
