function CSfoot = cs_footprints_build(anaDir, opts)
%CS_FOOTPRINTS_BUILD  Initial (auto) footprints for every picked contact site — the Refine stage's input.
%
%   CSfoot = cs_footprints_build(anaDir, opts)
%
% For each picked site (csIDs/<base>_CSsites.txt, grouped by window=Slice) it rebuilds the window
% density (cs_window_density) and derives the auto footprint (cs_window_footprint) — the SAME
% footprint the mapper would compute. It does NOT compute membership/metrics (that's the mapper's
% job); this is a lightweight, editable geometry layer the Refine tab loads, adjusts, and saves to
% analysis/CS_footprints.mat, which cs_window_mapper then reads to OVERRIDE the auto footprints.
%
% opts: .footprintMode ('halfmax'|'box'|'disk'), .fracHalfMax (0.5), .maxRadiusUm (0.6),
%       .boxHalfWidthUm (0.5), .src ('all'|'tracked' for the density), .save (false),
%       .outlineSigmaNm (the project's, cs_outline_sigma): the smoothing the outline is made at.
%       .sig (px) overrides it. It used to default to the picker's 8 px (240 nm), which made
%       every automatic outline at least 0.25 µm² - see cs_outline_sigma.
%
% CSfoot(k): file, cellIndex, csID, window, winFrames, pickPx (density px), center ([x y] um),
%   refboundary (K x 2 um, rel center), mode, frac, maxRadiusUm, SF, grid, densSrc, mito, areaUm2,
%   edited, deleted, sigmaNm (the smoothing the outline was made at; NaN = not recorded),
%   note ('' or why the site should be looked at, e.g. set by cs_footprints_regenerate).

if nargin<2 || ~isstruct(opts), opts = struct(); end
fpMode = lower(getf(opts,'footprintMode','halfmax'));
frac   = getf(opts,'fracHalfMax',0.5);
maxRu  = getf(opts,'maxRadiusUm',0.6);
boxHu  = getf(opts,'boxHalfWidthUm',0.5);
sigPxFix = getf(opts,'sig',[]);                          % explicit px override (tests, old callers)
sigNm    = getf(opts,'outlineSigmaNm',[]);
if isempty(sigNm), sigNm = cs_outline_sigma(anaDir); end
src    = lower(getf(opts,'src','all'));
doSave = getf(opts,'save',false);
verb   = getf(opts,'verbose',true);
fpOpts = struct('mode',fpMode,'frac',frac,'maxRadiusUm',maxRu,'boxHalfWidthUm',boxHu);

% cs_config lives alongside this file in drivers/, so nothing extra to put on the path.

tsPath = cs_active_trackstruct(anaDir);        % the ACTIVE build, which may be named (Day1_WT.mat)
assert(~isempty(tsPath) && isfile(tsPath),'cs_footprints_build:noTrackStruct', ...
    'No TrackStruct build in %s', anaDir);
S = load(tsPath); fn = fieldnames(S); Tracks = S.(fn{1});
% Hand-rejected tracks (QC tab) are BLANKED, not removed: the auto footprint is a half-max of the
% density, so a rejected track would otherwise still shape it, while every track number the mapper
% and the Sites tab key on stays where it was. The picker, the Refine tab and the mapper do the same.
try, Tracks = cs_track_exclusions('blank', cs_track_exclusions('load', fileparts(regexprep(char(anaDir),'[\\/]+$',''))), Tracks); catch, end
[gridDef, SFdef] = cs_default_gridsf(anaDir);

CSfoot = struct([]);
for i = 1:numel(Tracks)
    [~,base] = fileparts(char(Tracks(i).file));
    txt = fullfile(anaDir,'csIDs',[base '_CSsites.txt']);
    if ~isfile(txt) || ~isfield(Tracks,'matrix') || isempty(Tracks(i).matrix), continue; end
    sites = cs_read_sites(txt); if isempty(sites.Xpx), continue; end
    [ranges, SF, grid, srcSaved] = cs_load_windows(anaDir, base, sites.w, gridDef, SFdef);
    srcCell = src; if ~isempty(srcSaved), srcCell = srcSaved; end     % LOCK to the picker's density source
    if strcmp(srcCell,'tracked')
        sX = reshape(Tracks(i).matrix(:,:,2),[],1); sY = reshape(Tracks(i).matrix(:,:,3),[],1); sF = reshape(Tracks(i).matrix(:,:,1),[],1);
    else
        a = Tracks(i).allSpots; sX = a.X(:); sY = a.Y(:); sF = a.FRAME(:);
    end
    if isempty(sigPxFix)
        [sig, peakR] = cs_outline_sigma('scale', sigNm, SF, maxRu); sigRec = sigNm;
    else
        sig = sigPxFix; peakR = maxRu; sigRec = sigPxFix * SF * 1000;
    end
    fpOpts.peakRadiusUm = peakR;
    dcache = containers.Map('KeyType','double','ValueType','any');
    for j = 1:numel(sites.Xpx)
        w = sites.w(j); if w<1 || w>size(ranges,1), w = 1; end
        f0 = ranges(w,1); f1 = ranges(w,2);
        if isKey(dcache,w), Dens = dcache(w);
        else, [~,Dens] = cs_window_density(sX,sY,sF,f0,f1,SF,grid,grid,sig); dcache(w)=Dens; end
        fp = cs_window_footprint(Dens, [sites.Xpx(j) sites.Ypx(j)], SF, fpOpts);
        e = struct('file',base,'cellIndex',i,'csID',j,'window',w,'winFrames',[f0 f1], ...
            'pickPx',[sites.Xpx(j) sites.Ypx(j)],'center',fp.centerUm,'refboundary',fp.refboundary, ...
            'mode',fp.mode,'frac',frac,'maxRadiusUm',maxRu,'SF',SF,'grid',grid,'densSrc',srcCell, ...
            'mito',logical(sites.mito(j)),'areaUm2',fp.areaUm2,'edited',false,'deleted',false, ...
            'sigmaNm',sigRec,'note','');
        if isempty(CSfoot), CSfoot = e; else, CSfoot(end+1) = e; end %#ok<AGROW>
    end
end
if doSave && ~isempty(CSfoot)
    save(fullfile(anaDir,'CS_footprints.mat'),'CSfoot','-v7.3');
    if verb, fprintf('cs_footprints_build: wrote CS_footprints.mat (%d footprints)\n', numel(CSfoot)); end
end
end

function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
