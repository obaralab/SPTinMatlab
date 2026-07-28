function TracksOverRawImage(Tracks, i, imS)
%TRACKSOVERRAWIMAGE  QC overlay of a cell's trajectories on its raw/MaxInt image.
%
% Self-contained reconstruction of the advisor's external QC helper (not shipped
% with the suite). QC ONLY — the density/CS analysis does not depend on it, and
% the driver calls QuickPlotterTracks inside a try/catch, so an imperfect scale
% here never blocks a run.
%
%   TracksOverRawImage(Tracks, i, imS)
%   Tracks(i).matrix is [step x track x 3] = (t, X_um, Y_um).
%
% Tracks are mapped um -> image pixels using the structure-image pixel size from
% cs_config (DL_PixSize_um). If your raw image has a different pixel size, set
% cs_config.DL_PixSize_um (or calib.dlPixSizeUm) accordingly.

figure; imshow(imS,'Border','tight'); hold on;
try
    cfg = cs_config(); pxPerUm = 1/cfg.DL_PixSize_um;
catch
    pxPerUm = 1;                       % fall back to image pixels if no config
end
X = Tracks(i).matrix(:,:,2) * pxPerUm;
Y = Tracks(i).matrix(:,:,3) * pxPerUm;
plot(X, Y, 'LineWidth', 0.5);
title(sprintf('Cell %d: %s', i, strrep(Tracks(i).file,'_','\_')), 'Interpreter','tex');
hold off;
end
