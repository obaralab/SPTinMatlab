function fg = spt_seg_fg_label(segPath)
%SPT_SEG_FG_LABEL  The foreground label of a segmentation stack (ilastik label map or 0/255 binary).
%
%   fg = spt_seg_fg_label(segPath)
%
% The label is the MINIMUM non-zero value over a sample of pages spread through the stack — never
% from a single page. An ilastik Simple-Segmentation page that happens to contain no ER is entirely
% label 2, so reading the label off that one page inverts the mask: background becomes "ER". Under
% strict geodesic linking that inversion is silent and maximally damaging (it keeps exactly the
% off-ER detections), so the label must be a property of the stack, not of whichever page was read.
%
% Cached per file (invalidated when the file's timestamp changes), because the per-frame loaders in
% the comparison tools call this inside a loop.
persistent cKey cVal
d = dir(segPath);
if isempty(d), fg = 1; return; end
key = sprintf('%s|%.6f|%d', segPath, d.datenum, d.bytes);
if ~isempty(cKey) && strcmp(cKey, key), fg = cVal; return; end
T = numel(imfinfo(segPath));
probe = unique(round(linspace(1, T, min(T, 16))));
vals = [];
for t = probe
    v = unique(imread(segPath, t)); vals = unique([vals; v(:)]);
end
nz = vals(vals > 0);
fg = 1; if ~isempty(nz), fg = min(nz); end
% A stack with a SINGLE distinct value has no foreground/background distinction: every pixel either
% matches fg (the whole field becomes "ER", and an ER link mode silently stops constraining
% anything) or none does. Neither is a usable segmentation — say so rather than failing quietly.
if numel(vals) == 1
    warning('spt_seg_fg_label:uniformStack', ...
        ['%s: every sampled pixel has the same value (%g), so there is no foreground/background ' ...
         'distinction. ER-penalty / ER-geodesic linking against this mask is meaningless — check the segmentation.'], ...
        segPath, double(vals(1)));
end
cKey = key; cVal = fg;
end
