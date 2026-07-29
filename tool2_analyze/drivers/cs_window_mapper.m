function CSW = cs_window_mapper(anaDir, opts)
%CS_WINDOW_MAPPER  Assign per-window contact-site picks their members + metrics (headless).
%
%   CSW = cs_window_mapper(anaDir)
%   CSW = cs_window_mapper(anaDir, opts)
%
% The foundation stage of the downstream analysis. Reads the picker's per-cell outputs
%   csIDs/<base>_CSsites.txt         (one row per site; col6 Slice = window index, col7 = mito 1/2)
%   Density_<base>_CSwindows.mat     (windows.ranges [nW x 2] INCLUSIVE frame bins; SF; grid; dt)
%   TrackStruct.mat                  (Tracks(i).matrix [m x n x 3]; allSpots; frameInterval)
% and, for each (site j, window w=Slice(j)):
%   (1) rebuilds the WINDOW density via cs_window_density (the same map the picker showed),
%   (2) derives an auto footprint polygon via cs_window_footprint (replaces the mouse refiner),
%   (3) assigns member tracks + localizations by a SPATIAL (in-footprint) AND TEMPORAL
%       (frame in the window) mask over the TRACKED matrix,
%   (4) computes area / n_loc / prob_mass / peak_prob / enrichment via csDensMetricOne's kernel.
% Emits ONE flat struct per (site x window) -> analysis/CSW_final.mat + cs_window_metrics.csv.
% This is the single file every downstream tab (Sites/Dwell/Compare) reads.
%
% Membership + the dwell coordinate frame (CSmatrix) are ALWAYS on the tracked matrix (dwell needs
% track continuity); the density/enrichment SOURCE may be the full localization cloud (opts.src).
%
% opts fields (all optional):
%   .footprintMode  'halfmax'(default) | 'box' | 'disk'
%   .fracHalfMax    0.5     .maxRadiusUm 0.6     .boxHalfWidthUm 0.5     .sig 8
%   .src            'all'(default, allSpots cloud) | 'tracked' (matrix) — density source only
%   .save           true (write CSW_final.mat + cs_window_metrics.csv)
%   .verbose        true
%
% Units in CSW: micrometres everywhere; refCenter/refboundary/CSmatrix are um, refCentre-relative.

if nargin<2 || ~isstruct(opts), opts = struct(); end
fpMode = lower(getf(opts,'footprintMode','halfmax'));
sig    = getf(opts,'sig',8);
src    = lower(getf(opts,'src','all'));
doSave = getf(opts,'save',true);
verb   = getf(opts,'verbose',true);
useRefined = getf(opts,'useRefined',true);                                  % apply the Refine tab's footprints
footFile   = getf(opts,'footprintFile', fullfile(anaDir,'CS_footprints.mat'));
fpOpts = struct('mode',fpMode,'frac',getf(opts,'fracHalfMax',0.5), ...
                'maxRadiusUm',getf(opts,'maxRadiusUm',0.6), ...
                'boxHalfWidthUm',getf(opts,'boxHalfWidthUm',0.5));

% Make the reused robust-suite helpers (cs_config, cellBase) resolvable.
here = fileparts(mfilename('fullpath'));
rob  = fullfile(here,'..','ContactSites_robust');
if isfolder(rob), addpath(rob); end

% ---- load TrackStruct ----
tsPath = cs_active_trackstruct(anaDir);        % the ACTIVE build, which may be named (Day1_WT.mat)
assert(~isempty(tsPath) && isfile(tsPath), 'cs_window_mapper:noTrackStruct', ...
    'No TrackStruct build in %s', anaDir);
S = load(tsPath); fn = fieldnames(S); Tracks = S.(fn{1});
nCells = numel(Tracks);

% default grid/SF from a rho.tif + cs_config (used when a cell has no CSwindows.mat)
[gridDef, SFdef] = cs_default_gridsf(anaDir);

% refined-footprint overrides + deletions (from the Refine tab). Keys "file|csID|window".
ovr = containers.Map('KeyType','char','ValueType','any');   % refined footprint per site
del = containers.Map('KeyType','char','ValueType','any');   % deleted sites (skip them)
if useRefined && isfile(footFile)
    try
        Lf = load(footFile);
        if isfield(Lf,'CSfoot') && ~isempty(Lf.CSfoot)
            for q = 1:numel(Lf.CSfoot)
                ff = Lf.CSfoot(q);
                ovr(sprintf('%s|%d|%d', ff.file, ff.csID, ff.window)) = ff;
            end
            if verb, fprintf('  using %d refined footprint(s) from %s\n', numel(Lf.CSfoot), footFile); end
        end
        if isfield(Lf,'CSdeleted') && ~isempty(Lf.CSdeleted)
            for q = 1:numel(Lf.CSdeleted)
                dd = Lf.CSdeleted(q);
                del(sprintf('%s|%d|%d', dd.file, dd.csID, dd.window)) = dd;
            end
            if verb, fprintf('  skipping %d deleted site(s) from %s\n', numel(Lf.CSdeleted), footFile); end
        end
    catch ME
        if verb, warning('cs_window_mapper:footprintLoad','could not read %s: %s', footFile, ME.message); end
    end
end
% per-site track exclusions (from the Sites tab): key "file|csID|window" -> struct(pickPx, cols[])
exc = containers.Map('KeyType','char','ValueType','any');
teFile = fullfile(anaDir,'CS_trackedits.mat');
if useRefined && isfile(teFile)
    try
        Le = load(teFile);
        if isfield(Le,'CSexclude') && ~isempty(Le.CSexclude)
            for q = 1:numel(Le.CSexclude)
                ee = Le.CSexclude(q); ekey = sprintf('%s|%d|%d', ee.file, ee.csID, ee.window);
                if isKey(exc,ekey), s0 = exc(ekey); else, s0 = struct('pickPx',getf(ee,'pickPx',[]),'cols',[]); end
                s0.cols = unique([s0.cols, ee.trackCol]);
                exc(ekey) = s0;
            end
            if verb, fprintf('  applying %d track-exclusion(s) from %s\n', numel(Le.CSexclude), teFile); end
        end
    catch, end
end

blank = struct('csID',NaN,'cellIndex',NaN,'file','','mito',false,'n_loc_in',0, ...
    'cell_total',0,'prob_mass',NaN,'peak_prob',NaN,'peak_prob_raw',NaN,'area_um2',NaN, ...
    'local_dens',NaN,'cell_bg_dens',NaN,'enrichment',NaN);

CSW = struct([]);
uid = 0;
for i = 1:nCells
    base = cellBaseName(Tracks(i).file);
    txt  = fullfile(anaDir,'csIDs',[base '_CSsites.txt']);
    if ~isfile(txt)
        if verb, warning('cs_window_mapper:noSites','no CSsites for %s — skip', base); end
        continue;
    end
    sites = cs_read_sites(txt);             % .Xpx .Ypx .w .mito (row per site)
    if isempty(sites.Xpx)
        if verb, fprintf('  %s: 0 sites\n', base); end
        continue;
    end
    if ~isfield(Tracks,'matrix') || isempty(Tracks(i).matrix)
        if verb, warning('cs_window_mapper:noMatrix','%s has no matrix — skip', base); end
        continue;
    end
    mat = Tracks(i).matrix;
    Frame = mat(:,:,1); Amat = mat(:,:,2); Bmat = mat(:,:,3);
    dt = getf2(Tracks(i),'frameInterval', getf2(Tracks(i),'dt',0.02));

    % window frame ranges (authoritative CSwindows.mat, else whole-movie fallback)
    [ranges, SF, grid, srcSaved] = cs_load_windows(anaDir, base, sites.w, gridDef, SFdef);
    srcCell = src; if ~isempty(srcSaved), srcCell = srcSaved; end   % LOCK the density source to the picker's

    % density source coords
    switch srcCell
        case 'tracked'
            sX = Amat(:); sY = Bmat(:); sF = Frame(:);
        otherwise % 'all'
            a = Tracks(i).allSpots;
            sX = a.X(:); sY = a.Y(:); sF = a.FRAME(:);
    end

    % cache the (window -> density) since many sites share a window
    dcache = containers.Map('KeyType','double','ValueType','any');

    for j = 1:numel(sites.Xpx)
        w  = sites.w(j);  if w<1 || w>size(ranges,1), w = 1; end
        % skip a site the user deleted in the Refine tab (pickPx-guarded so a re-pick can't mis-skip)
        dkey = sprintf('%s|%d|%d', base, j, w);
        if isKey(del, dkey)
            dd0 = del(dkey); pxOk = true;
            if isfield(dd0,'pickPx') && numel(dd0.pickPx)==2
                pxOk = hypot(dd0.pickPx(1)-sites.Xpx(j), dd0.pickPx(2)-sites.Ypx(j)) < 1.5;
            end
            if pxOk, continue; end
        end
        f0 = ranges(w,1); f1 = ranges(w,2);
        if isKey(dcache,w)
            dd = dcache(w);
        else
            [rawCounts,Dens] = cs_window_density(sX, sY, sF, f0, f1, SF, grid, grid, sig);
            dd = struct('raw',rawCounts,'dens',Dens);
            dcache(w) = dd;
        end
        rawCounts = dd.raw; Dens = dd.dens;

        % (2) auto footprint (overridden by a refined footprint from the Refine tab, if present)
        fp = cs_window_footprint(Dens, [sites.Xpx(j) sites.Ypx(j)], SF, fpOpts);
        cUm = fp.centerUm; refb = fp.refboundary; fpmode = fp.mode; ellip = fp.EllipseFit;   % um, rel centre
        okey = sprintf('%s|%d|%d', base, j, w);
        if isKey(ovr, okey)
            ff = ovr(okey);
            % STALENESS GUARD: csID is a positional site index, so a CS_footprints.mat left over from a
            % previous pick-set would silently map footprints onto the wrong sites. Only apply the
            % override when the saved pick still coincides with THIS site's pick (density px).
            pxOk = true;
            if isfield(ff,'pickPx') && numel(ff.pickPx)==2
                pxOk = hypot(ff.pickPx(1)-sites.Xpx(j), ff.pickPx(2)-sites.Ypx(j)) < 1.5;
            end
            if pxOk && isfield(ff,'refboundary') && ~isempty(ff.refboundary)
                refb = ff.refboundary;
                if isfield(ff,'center') && numel(ff.center)==2, cUm = ff.center(:)'; end
                fpmode = 'refined'; ellip = [];
                if isfield(ff,'mode') && ~isempty(ff.mode), fpmode = ['refined:' char(ff.mode)]; end
            elseif ~pxOk && verb
                warning('cs_window_mapper:staleFootprint', ...
                    'skipped a stale refined footprint for %s site %d (the pick moved — re-run the Refine tab)', base, j);
            end
        end

        % (3) membership on the tracked matrix (spatial AND temporal)
        Ar = Amat - cUm(1); Br = Bmat - cUm(2);
        okxy = isfinite(Amat) & isfinite(Bmat);
        inPoly = false(size(Amat));
        inPoly(okxy) = inpolygon(Ar(okxy), Br(okxy), refb(:,1), refb(:,2));
        if isinf(f0) && isinf(f1), inWin = true(size(Frame));
        else, inWin = Frame>=f0 & Frame<=f1; end
        mnID   = inPoly & inWin & okxy;
        tracks = find(sum(mnID,1));
        % per-site track exclusions from the Sites tab (pickPx-guarded): drop those track columns
        if isKey(exc, okey)
            ex = exc(okey); expx = true;
            if isfield(ex,'pickPx') && numel(ex.pickPx)==2
                expx = hypot(ex.pickPx(1)-sites.Xpx(j), ex.pickPx(2)-sites.Ypx(j)) < 1.5;
            end
            if expx && ~isempty(ex.cols)
                drop = intersect(tracks, ex.cols);
                if ~isempty(drop), mnID(:,drop) = false; tracks = setdiff(tracks, drop); end
            end
        end
        LocIDs = find(mnID);
        % per-member-track: how much of that track sits INSIDE the contact site during the window —
        % locsInside / (track's localizations present in the window). High % = dwelling at the site;
        % low % = merely passing through. (winCol counts the track's finite positions in the window.)
        inCol  = sum(mnID, 1);
        winCol = sum(inWin & okxy, 1);
        trackLocsInside = inCol(tracks);
        trackLocsWin    = winCol(tracks);
        trackPctInside  = 100 * trackLocsInside ./ max(trackLocsWin, 1);
        CSmatrix = cat(3, Frame(:,tracks), Amat(:,tracks)-cUm(1), Bmat(:,tracks)-cUm(2));

        % (5) density metrics via the reused kernel (its cc grid + nm-refboundary contract)
        inw  = (isinf(f0)&isinf(f1)) | (sF>=f0 & sF<=f1);
        okc  = inw & isfinite(sX) & isfinite(sY);
        cc = struct();
        cc.rho    = Dens.';                 % csDensMetricOne indexes rho(xbin,ybin) -> transpose [y,x]->[x,y]
        cc.Hc     = rawCounts.';
        cc.cxc    = (1:grid)*SF;            % x bin centres (um): pixel c centre = c*SF
        cc.cyc    = (1:grid)*SF;
        cc.rho_bg = occBg(Dens, rawCounts);
        cc.Xc     = sX(okc); cc.Yc = sY(okc);
        cc.cellTot= numel(cc.Xc);
        cs = struct('csID',j,'cellIndex',i,'MitoFlag',sites.mito(j), ...
                    'refCenter',cUm,'refboundary',refb*1000);   % nm rel centre for the kernel
        rec = csDensMetricOne(cs, cc, base, blank, SF^2);

        % (6) append flat record
        uid = uid + 1;
        e = struct();
        e.file=base; e.cellIndex=i; e.csID=j; e.window=w; e.winFrames=[f0 f1]; e.siteUID=uid;
        e.pickPx=[sites.Xpx(j) sites.Ypx(j)];                              % ORIGINAL detection pick (for later edits/exclusions)
        e.center=cUm; e.refCenter=cUm; e.refboundary=refb; e.footprintMode=fpmode;
        e.EllipseFit=ellip;
        e.boundaries=struct('x',refb(:,1)+cUm(1),'y',refb(:,2)+cUm(2));   % abs um (compat)
        e.tracks=tracks; e.nTracks=numel(tracks); e.LocIDs=LocIDs; e.nMemberLocs=numel(LocIDs);
        e.trackLocsInside=trackLocsInside; e.trackLocsWin=trackLocsWin; e.trackPctInside=trackPctInside;   % per-track dwell fraction
        e.CSmatrix=CSmatrix; e.MitoFlag=logical(sites.mito(j));
        e.SF=SF; e.grid=grid; e.binAreaUm2=SF^2; e.dt=dt;
        e.areaUm2=rec.area_um2; e.nLocInside=rec.n_loc_in; e.cellTotalLocWin=rec.cell_total;
        e.probMass=rec.prob_mass; e.peakProb=rec.peak_prob; e.peakProbRaw=rec.peak_prob_raw;
        e.localDens=rec.local_dens; e.cellBgDens=rec.cell_bg_dens; e.enrichment=rec.enrichment;
        e.densSrc=srcCell;
        if isempty(CSW), CSW = e; else, CSW(end+1) = e; end %#ok<AGROW>
    end
    if verb
        fprintf('  %s: %d sites over %d window(s)\n', base, numel(sites.Xpx), size(ranges,1));
    end
end

if doSave && ~isempty(CSW)
    save(fullfile(anaDir,'CSW_final.mat'),'CSW','-v7.3');
    writeMetricsCSV(fullfile(anaDir,'cs_window_metrics.csv'), CSW);
    if verb, fprintf('cs_window_mapper: wrote CSW_final.mat (%d site-windows) + cs_window_metrics.csv\n', numel(CSW)); end
end
end

% ================================================================================================
% Site parsing (cs_read_sites.m), window ranges (cs_load_windows.m) and grid/SF defaults
% (cs_default_gridsf.m) are standalone drivers so the Refine tab reuses the SAME logic.

function bg = occBg(Dens, rawCounts)
occ = rawCounts>=1; bg = mean(Dens(occ),'omitnan'); if ~(bg>0), bg = NaN; end
end

function b = cellBaseName(f)
[~,b,~] = fileparts(char(f));   % Tracks.file is usually already the base ('..._spt1')
end

function writeMetricsCSV(path, CSW)
hdr = {'file','cellIndex','csID','window','f0','f1','mitoCS','areaUm2','nLocInside', ...
       'nMemberLocs','nTracks','probMass','peakProb','enrichment'};
fid = fopen(path,'w'); if fid<0, return; end
fprintf(fid,'%s\n',strjoin(hdr,','));
for k=1:numel(CSW)
    e = CSW(k);
    fprintf(fid,'%s,%d,%d,%d,%g,%g,%d,%.6g,%d,%d,%d,%.6g,%.6g,%.6g\n', ...
        e.file, e.cellIndex, e.csID, e.window, e.winFrames(1), e.winFrames(2), e.MitoFlag, ...
        e.areaUm2, e.nLocInside, e.nMemberLocs, e.nTracks, e.probMass, e.peakProb, e.enrichment);
end
fclose(fid);
end

function v = getf(s,f,d),  if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
function v = getf2(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
