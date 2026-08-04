function M = spt_load_seg(segPath, nFrames)
%SPT_LOAD_SEG  Load a per-frame segmentation stack as a logical foreground mask (HxWxT).
%
%   M = spt_load_seg(segPath, nFrames)
%
% Handles ilastik Simple-Segmentation label maps (label 1 = foreground, 2 = background) and plain
% binary masks (0 / 255): the foreground label is the MINIMUM non-zero value in the stack (1 for a
% label map, 255 for a 0/255 binary). Returns M(:,:,t) = true where foreground.
info = imfinfo(segPath);
T = numel(info);
if nargin >= 2 && ~isempty(nFrames), T = min(T, nFrames); end
a1 = imread(segPath, 1); [H, W] = size(a1);
% Take the foreground label from a SAMPLE SPREAD THROUGH THE STACK, not from page 1 alone: an
% ilastik page that happens to contain no ER is entirely label 2, and reading the label off that
% page would silently INVERT every frame — which strict geodesic linking would then enforce against
% the complement of the ER, keeping exactly the off-ER detections.
probe = unique(round(linspace(1, T, min(T, 16))));
vals = [];
for t = probe
    v = unique(imread(segPath, t)); vals = unique([vals; v(:)]);
end
nz = vals(vals > 0);
fg = 1; if ~isempty(nz), fg = min(nz); end            % 1 for a label map, 255 for a 0/255 binary
M = false(H, W, T);
for t = 1:T
    M(:,:,t) = imread(segPath, t) == fg;
end
frac = mean(M(:));
if frac > 0.9
    warning('spt_load_seg:suspectInversion', ...
        ['%s: foreground covers %.0f%% of the field — the label map may be INVERTED (foreground ' ...
         'read as %g). Check the segmentation before trusting ER-penalty or ER-geodesic linking.'], ...
        segPath, 100*frac, double(fg));
end
end
