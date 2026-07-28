function [rawCounts, Dens] = cs_window_density(sX, sY, sFrame, t0, t1, SFq, Hh, Ww, sig)
%CS_WINDOW_DENSITY  Localization-density map for a TIME WINDOW (moving-contact-site aware).
%
% Bins the localizations whose FRAME is in [t0,t1] onto the density grid and Gaussian-smooths
% them. A short window keeps a MOVING contact site sharp; the whole-movie window (t0=-Inf,
% t1=Inf, or sFrame=[]) reproduces cs_identify's classic pooled density exactly. Uses the SAME
% grid transform cs_identify uses everywhere: col = round(X/SFq), row = round(Y/SFq),
% accumarray([row col]) -> counts, then imgaussfilt(counts, sig).
%
% INPUT
%   sX,sY   : localization coords in MICRONS (Nx1) — e.g. Tracks(i).allSpots.X / .Y.
%   sFrame  : integer frame index per localization (Nx1); [] -> no windowing (all localizations).
%   t0,t1   : inclusive window bounds in the same units as sFrame; use -Inf/Inf for unbounded.
%   SFq     : microns per density pixel (cfg.SnapFOV_um / gridsize).
%   Hh,Ww   : density grid size (rows, cols).
%   sig     : Gaussian sigma in px for the detection-scale smoothing (cs_identify uses 8). Default 8.
%
% OUTPUT
%   rawCounts : [Hh x Ww] integer count image (row=y, col=x).
%   Dens      : imgaussfilt(rawCounts, sig) — the smoothed detection density.
if nargin<9 || isempty(sig), sig = 8; end
rawCounts = zeros(Hh, Ww);
sX = sX(:); sY = sY(:);
if isempty(sX), Dens = imgaussfilt(rawCounts, sig); return; end
inwin = true(numel(sX),1);
if nargin>=3 && ~isempty(sFrame)
    f = sFrame(:);
    if isinf(t0) && isinf(t1)
        inwin = true(numel(f),1);            % whole-movie: keep EVERY localization, incl. any NaN frame
    else                                     % (NaN>=−Inf is false, so a plain compare would wrongly drop them)
        inwin = (f >= t0) & (f <= t1);       % bounded window: NaN frames excluded (they carry no frame)
    end
end
Lx = round(sX/SFq); Ly = round(sY/SFq);
inb = inwin & isfinite(Lx) & isfinite(Ly) & Lx>=1 & Lx<=Ww & Ly>=1 & Ly<=Hh;
if any(inb)
    rawCounts = accumarray([Ly(inb) Lx(inb)], 1, [Hh Ww]);   % row=y, col=x
end
Dens = imgaussfilt(rawCounts, sig);
end
