function cs_window_picker(parent, anaDir, opts)
%CS_WINDOW_PICKER  Windowed, time-resolved contact-site picker (embeds in a panel; non-blocking).
%
%   cs_window_picker(parent, anaDir, opts)
%
% Splits each cell's movie into FRAME windows, shows one localization-density panel per window in a
% grid, and lets you click a window to open a large zoomed detail view where you add / detect / select
% contact sites FOR THAT WINDOW. Detection is manual (on demand): ER Monte-Carlo (null scatters the
% localizations uniformly inside the ER footprint of that window's start frame — no intensity weight),
% Local background, or Relative. Sites are classified mito / non-mito from per-spot MITODIST. The detail
% view has a density colorbar showing the ER-MC null band + detection cutoff, or a per-pixel significance
% (p) recolour. Save writes, per cell, <cell>_CSsites.txt (X,Y density px; Slice = window index; Counter
% = mito flag) + Density_<cell>_CSwindows.mat (per-window frame ranges) for time-resolved downstream.
%
% opts (optional): FOV_um (27.61), grid (from a saved _rho.tif or ceil(FOV/binUm)), binNm (30),
%   sig (8), framesPerWindow (1495), contactUm (0.15), mipDir (whole-movie ER MIP folder, fallback ER
%   support), segResolver (@(base)->struct('er',path,'mito',path) for the per-window start-frame masks).

if nargin < 3 || ~isstruct(opts), opts = struct(); end
st = struct();
st.anaDir = anaDir;
st.FOV    = getf(opts,'FOV_um',27.61);
st.binNm  = getf(opts,'binNm',30);
st.sig    = getf(opts,'sig',8);
st.fpw    = getf(opts,'framesPerWindow',1495);
st.step   = getf(opts,'stepFrames',0);        % window start stride; 0 (or >=fpw) = non-overlapping
st.minLocs= getf(opts,'minLocsPerWin',1000);  % per-window tracked-loc floor for the low-count warning
st.contactUm = getf(opts,'contactUm',0.15);
st.mipDir = getf(opts,'mipDir', fullfile(anaDir,'mips'));
st.segResolver = getf(opts,'segResolver',[]);
st.method = 'ermc';  st.sens = 0.01;  st.MC = 300;  st.minArea = 3;   % more MC runs -> steadier per-window cutoff
st.clip = 0.5;  st.alpha = 1;  st.src = 'tracked';  st.scaleMode = 'density';  st.cbInfo = '';   % default: tracked-only density (excludes single-frame noise)
st.addMode = false;  st.ci = 1;  st.cw = 1;  st.MAXPANELS = 24;

% ---- Tracks: use the caller's already-loaded struct when it hands one over ----
% The app holds the ACTIVE (possibly named) build in memory; re-loading it here would put a second
% full copy of the same data in RAM. Nothing below writes st.Tracks, so this shares rather than
% copies. Falling back to disk keeps the picker usable standalone.
L = getf(opts,'Tracks',[]);
if isempty(L)
    cand = {};
    tsf = getf(opts,'tsFile','');                       % the caller's active build, if it named one
    if ~isempty(tsf), cand{end+1} = tsf; end
    a = activeTsFile_(anaDir); if ~isempty(a), cand{end+1} = a; end   % analysis/active_trackstruct.txt
    cand = [cand, {fullfile(anaDir,'Tracks.mat'), fullfile(anaDir,'TrackStruct.mat')}];
    for f = cand
        if isfile(f{1}), Lt = load(f{1}); if isfield(Lt,'Tracks'), L = Lt.Tracks; break; end, end
    end
end
assert(~isempty(L), 'cs_window_picker: no Tracks passed in, and no Tracks.mat / TrackStruct.mat in %s', anaDir);
st.Tracks = L;
st.grid = getf(opts,'grid', pickGrid());
st.SF   = st.FOV / st.grid;

% per-cell state
st.aX=[]; st.aY=[]; st.aF=[]; st.aMD=[]; st.haveMD=false; st.nDet=0; st.nAll=0; st.aT=[];   % st.aT = per-localization track id
st.aConf=[]; st.aSC=[]; st.haveDiff=false; st.densMode='tracked';   % per-loc confined/state-change flags + the density channel
st.splitPeaks=true; st.minEnrich=1.0; st.minTracks=1; st.minSiteLocs=0;   % detection-quality gates (1.0/1 = off)
% st.sites{w} column map (widened to carry per-site stats through add/remove/reorder):
SC = struct('x',1,'y',2,'flag',3,'manual',4,'peak',5,'pval',6,'enr',7,'nloc',8,'ntrk',9,'stab',10,'area',11,'dwell',12);
NCOL = 12;   % ...'dwell' = median % of associated tracks' localizations inside the site (dwelling vs passing)
st.win=zeros(0,2); st.nW=0;
st.sites={}; st.wrc={}; st.wdens={}; st.werM={}; st.wmitoM={}; st.wnull={};
st.thumbAx=[]; st.selList=[]; st.erPath=''; st.mitoPath=''; st.segNfr=0; st.segMitoNfr=0; st.erMip=[];

% =====================================================================
% UI
% =====================================================================
delete(allchild(parent));
g = uigridlayout(parent,[5 1],'RowHeight',{32,30,30,30,'1x'},'Padding',[8 8 8 8],'RowSpacing',5);

% ---- control row A: data + detection ----
rA = uigridlayout(g,[1 13],'ColumnWidth', ...
    {34,140, 62,58, 52,140, 40,78, 74,72, 66,66, '1x'}, 'Padding',[0 0 0 0],'ColumnSpacing',5);
uilabel(rA,'Text','Cell','HorizontalAlignment','right');
ddCell = uidropdown(rA,'Items',cellNames(),'ValueChangedFcn',@(s,e) onCell());
% density is always built from TRACKED localizations (single-frame detections are excluded as noise)
uilabel(rA,'Text','frames/win','HorizontalAlignment','right');
eFpw = uispinner(rA,'Limits',[10 1e6],'Value',st.fpw,'Step',50,'ValueChangedFcn',@(s,e) onFpw(), ...
    'Tooltip','Window length in FRAMES → ceil(nFrames/this) windows; a tiny trailing remainder merges into the last.');
uilabel(rA,'Text','method','HorizontalAlignment','right');
ddMeth = uidropdown(rA,'Items',{'ER Monte-Carlo','Local background','Relative'}, ...
    'ItemsData',{'ermc','local','relative'},'Value','ermc','ValueChangedFcn',@(s,e) onMeth());
uilabel(rA,'Text','sens','HorizontalAlignment','right');
eSens = uispinner(rA,'Limits',[0 1],'Value',st.sens,'Step',0.01, ...
    'Tooltip','ER-MC: family-wise α (lower = stricter = fewer sites; = the cutoff line on the colorbar). Relative: fraction of peak. Local: strictness.', ...
    'ValueChangedFcn',@(s,e) onSens());
uilabel(rA,'Text','contact µm','HorizontalAlignment','right');
eContact = uispinner(rA,'Limits',[-1 2],'Value',st.contactUm,'Step',0.05,'ValueChangedFcn',@(s,e) reclassify(), ...
    'Tooltip','A site is mito-contact when nearby localizations'' median signed MITODIST ≤ this (µm).');
btnDetW = uibutton(rA,'Text','Detect win','ButtonPushedFcn',@(s,e) detectCur(), ...
    'Tooltip','Detect candidate sites in the CURRENT window (manual, on demand).');
btnDetA = uibutton(rA,'Text','Detect all','ButtonPushedFcn',@(s,e) detectAll());
lbl = uilabel(rA,'Text','','FontColor',[0.2 0.4 0.5]);

% ---- control row B: display + overlays + save ----
rB = uigridlayout(g,[1 16],'ColumnWidth', ...
    {80,70, 56,50, 40,50, 50,42,46, 40,150, 62, 34,52, '1x', 76}, 'Padding',[0 0 0 0],'ColumnSpacing',5);
btnAdd = uibutton(rB,'Text','＋ Add site','FontWeight','bold','BackgroundColor',[0.98 0.88 0.70],'FontColor',[0.55 0.32 0.05], ...
    'Tooltip','Manually add a contact site: click here to arm, then click the density map to drop a site.','ButtonPushedFcn',@(s,e) toggleAdd());
btnClr = uibutton(rB,'Text','Clear win','ButtonPushedFcn',@(s,e) clearWindow());
uilabel(rB,'Text','contrast','HorizontalAlignment','right');
eContrast = uispinner(rB,'Limits',[0.05 1],'Value',st.clip,'Step',0.05,'ValueChangedFcn',@(s,e) onContrast(), ...
    'Tooltip','Turbo saturates at contrast × per-window peak (lower = brighter faint structure). Also sets the colorbar top.');
uilabel(rB,'Text','map α','HorizontalAlignment','right');
eAlpha = uispinner(rB,'Limits',[0.1 1],'Value',st.alpha,'Step',0.1,'ValueChangedFcn',@(s,e) drawDetail(), ...
    'Tooltip','Density-map opacity — lower it (with ＋locs on) to see individual localizations.');
uilabel(rB,'Text','overlay','HorizontalAlignment','right');
chkER   = uicheckbox(rB,'Text','ER','Value',false,'ValueChangedFcn',@(s,e) drawDetail(), ...
    'Tooltip','ER segmentation contour at this window''s START frame (moving-organelle view).');
chkMito = uicheckbox(rB,'Text','mito','Value',false,'ValueChangedFcn',@(s,e) drawDetail());
uilabel(rB,'Text','scale','HorizontalAlignment','right');
ddScale = uidropdown(rB,'Items',{'density (a.u.)','locs / 30 nm bin','significance (p)'},'ItemsData',{'density','raw','sigp'}, ...
    'Value','density','ValueChangedFcn',@(s,e) onScale(), ...
    'Tooltip', ['Colorbar/display mode. density (a.u.) = σ-smoothed density + CSR null band + cutoff (what the detector uses). ' ...
                'locs / 30 nm bin = raw localization COUNT per bin (interpretable units). ' ...
                'significance (p) = recolour by per-pixel p vs the ER-MC null (needs ER-MC + a Detect).']);
chkLoc = uicheckbox(rB,'Text','＋locs','Value',false,'ValueChangedFcn',@(s,e) drawDetail(), ...
    'Tooltip','Overlay this window''s localizations as points.');
uilabel(rB,'Text','sims','HorizontalAlignment','right');
eSims = uispinner(rB,'Limits',[20 2000],'Value',st.MC,'Step',20, ...
    'Tooltip', ['ER-Monte-Carlo null runs. More runs = finer α resolution (the smallest resolvable α ≈ 1/sims) ' ...
                'and a steadier cutoff, but slower. Changing it re-runs the null on the next draw/Detect.'], ...
    'ValueChangedFcn',@(s,e) onSims());
uilabel(rB,'Text','');   % spacer ('1x')
btnSave = uibutton(rB,'Text','💾 Save','BackgroundColor',[0.18 0.45 0.70],'FontColor','w', ...
    'ButtonPushedFcn',@(s,e) doSave(),'Tooltip','Write per-window <cell>_CSsites.txt (Slice=window) + Density_<cell>_CSwindows.mat.');

% ---- control row C: windowing (overlap) + per-window count floor + window-length sweep ----
rC = uigridlayout(g,[1 7],'ColumnWidth',{88,58, 96,60, 168, 300, '1x'},'Padding',[0 0 0 0],'ColumnSpacing',5);
uilabel(rC,'Text','step frames','HorizontalAlignment','right');
eStep = uispinner(rC,'Limits',[0 1e6],'Value',st.step,'Step',50,'ValueChangedFcn',@(s,e) onStep(), ...
    'Tooltip',['Window START stride in frames. 0 (or ≥ frames/win) = non-overlapping windows. A SMALLER ' ...
               'step makes overlapping windows that track a moving contact site more smoothly (more panels, ' ...
               'up to the panel cap; overlapping windows are not statistically independent).']);
uilabel(rC,'Text','min locs/win','HorizontalAlignment','right');
eMinLocs = uispinner(rC,'Limits',[0 1e7],'Value',st.minLocs,'Step',250,'ValueChangedFcn',@(s,e) onMinLocs(), ...
    'Tooltip','Per-window tracked-localization floor: a window with fewer localizations turns RED (⚠) — its density is under-powered for reliable peak detection.');
btnSweep = uibutton(rC,'Text','⇢ Sweep window length','ButtonPushedFcn',@(s,e) onSweep(), ...
    'Tooltip','Vary frames/window and plot the # of detected sites + median significance vs window length, to find the knee where results stabilize (uses the whole-movie ER support + a fast 80-run MC; ~15–30 s).');
lblSweep = uilabel(rC,'Text','','FontColor',[0.35 0.35 0.45]);

% ---- control row D: detection-quality gates + spot inspector (transparency) ----
rD = uigridlayout(g,[1 9],'ColumnWidth',{92, 96,60, 82,54, 56,150, 118, '1x'},'Padding',[0 0 0 0],'ColumnSpacing',5);
chkSplit = uicheckbox(rD,'Text','split peaks','Value',st.splitPeaks,'ValueChangedFcn',@(s,e) onSplit(), ...
    'Tooltip','Marker-controlled watershed: two touching real peaks become two sites instead of one blob centroid at the saddle. Re-run Detect to apply.');
uilabel(rD,'Text','min enrich ×','HorizontalAlignment','right');
eMinEnr = uispinner(rD,'Limits',[1 1e4],'Value',st.minEnrich,'Step',0.5,'ValueChangedFcn',@(s,e) onGate(), ...
    'Tooltip','Effect-size gate: keep a site only if its peak density is at least this multiple of the ER-median background. 1 = off. Re-run Detect to apply.');
uilabel(rD,'Text','min tracks','HorizontalAlignment','right');
eMinTrk = uispinner(rD,'Limits',[1 1e4],'Value',st.minTracks,'Step',1,'ValueChangedFcn',@(s,e) onGate(), ...
    'Tooltip','Distinct-molecule gate: keep a site only if at least this many DISTINCT tracks contribute localizations to it — rejects a single parked molecule. 1 = off. Re-run Detect to apply.');
uilabel(rD,'Text','channel','HorizontalAlignment','right');
ddChannel = uidropdown(rD,'Items',{'Tracked','Confined (low D)','State-change'},'ItemsData',{'tracked','confined','statechange'}, ...
    'Value','tracked','Enable','off', ...
    'Tooltip',['Density CHANNEL. Tracked = all tracked localizations. Confined = only low-D (dwelling) localizations. ' ...
               'State-change = only fast→slow transition localizations. Confined/State-change identify sites by DIFFUSION ' ...
               'STATE (needs a Build with diffusion). Re-run Detect after switching.'], ...
    'ValueChangedFcn',@(s,e) onDensMode());
chkExplain = uicheckbox(rD,'Text','🔍 explain spot','Value',false, ...
    'Tooltip','When on, clicking the density map reports that location''s density, null percentile, enrichment, #tracks and p — even for non-detected spots (no site is added/selected).');
lblExplain = uilabel(rD,'Text','','FontColor',[0.30 0.30 0.45]);

% ---- main: [ thumbnails | detail+colorbar | site list ] ----
mn = uigridlayout(g,[1 3],'ColumnWidth',{'1.0x','1.5x',290},'Padding',[0 0 0 0],'ColumnSpacing',8);
pnThumbs = uipanel(mn,'Title','Windows — click one to zoom','BorderType','line');
dc = uigridlayout(mn,[1 2],'ColumnWidth',{'1x',66},'Padding',[0 0 0 0],'ColumnSpacing',4);
axDet = uiaxes(dc); axDet.Toolbar.Visible='on'; title(axDet,'window detail'); axDet.YDir='reverse';
disableDefaultInteractivity(axDet); axDet.Interactions = [zoomInteraction panInteraction];
try, axDet.Toolbar = axtoolbar(axDet,{'zoomin','zoomout','restoreview'}); catch, end
axDet.ButtonDownFcn = @(s,e) onDetailClick(e);
axCbar = uiaxes(dc); axCbar.Toolbar.Visible='off'; disableDefaultInteractivity(axCbar); axCbar.XTick=[];
rp = uigridlayout(mn,[3 1],'RowHeight',{20,'1x',30},'Padding',[0 0 0 0],'RowSpacing',4);
lblList = uilabel(rp,'Text','Sites in window','FontWeight','bold');
tblSites = uitable(rp,'ColumnName',{'#','p','enr×','trk','dw%','stab'}, ...
    'ColumnWidth',{30,52,44,34,44,'auto'},'RowName',{},'SelectionType','row', ...
    'SelectionChangedFcn',@(s,e) onTableSel(e), ...
    'Tooltip',['Per-site stats. p = significance (fraction of MC null peaks ≥ the site; smaller = stronger). ' ...
               'enr× = peak density / ER-median background. trk = distinct contributing tracks. ' ...
               'dw% = median % of each track''s localizations INSIDE the site (high = tracks dwell; low = just passing). ' ...
               'stab = split-half reproducibility (0–1). Click a row to overlay its tracks + highlight it.']);
btnRem = uibutton(rp,'Text','－ Remove selected','ButtonPushedFcn',@(s,e) removeSelected());

onCell();

% =====================================================================
% Nested functions
% =====================================================================
    function nm = cellNames()
        nm = arrayfun(@(t) char(t.file), st.Tracks, 'uni', 0);
        if isempty(nm), nm = {'(no cells)'}; end
    end
    function gsz = pickGrid()
        gsz = ceil(st.FOV/(st.binNm/1000));
        D = dir(fullfile(anaDir,'Densities','*_rho.tif'));
        if ~isempty(D), try, info = imfinfo(fullfile(D(1).folder, D(1).name)); gsz = info(1).Height; catch, end, end
    end

    function onCell()
        st.ci = max(1, find(strcmp(ddCell.Items, ddCell.Value), 1)); if isempty(st.ci), st.ci=1; end
        T = st.Tracks(st.ci);
        [st.aX, st.aY, st.aF, st.aMD, st.haveMD, st.aT, st.aConf, st.aSC] = cellLocs(T, true);   % density is ALWAYS tracked-only (matrix, not the cloud)
        st.haveDiff = (isfield(T,'confined')&&~isempty(T.confined)) || (isfield(T,'stateChange')&&~isempty(T.stateChange));
        if ~isempty(ddChannel) && isgraphics(ddChannel)
            ddChannel.Enable = tern(st.haveDiff,'on','off');
            if ~st.haveDiff, ddChannel.Value='tracked'; st.densMode='tracked'; end
        end
        st.nDet = numel(st.aX);                                          % tracked localizations (what the density is built from)
        st.nAll = st.nDet;                                              % total detections (full cloud) — for the total-vs-tracked readout
        if isstruct(T.allSpots) && isfield(T.allSpots,'X') && ~isempty(T.allSpots.X)
            st.nAll = nnz(isfinite(double(T.allSpots.X(:))) & isfinite(double(T.allSpots.Y(:))));
        end
        % resolve this cell's seg stacks (for per-window start-frame masks) + the whole-movie ER MIP fallback
        st.erPath=''; st.mitoPath=''; st.segNfr=0; st.segMitoNfr=0; st.erMip=[];
        if ~isempty(st.segResolver)
            try, ov = st.segResolver(char(T.file)); catch, ov=[]; end
            if isstruct(ov)
                if isfield(ov,'er')   && ~isempty(ov.er)   && isfile(ov.er),   st.erPath=ov.er;     info=imfinfo(ov.er);   st.segNfr=numel(info);   end
                if isfield(ov,'mito') && ~isempty(ov.mito) && isfile(ov.mito), st.mitoPath=ov.mito; info=imfinfo(ov.mito); st.segMitoNfr=numel(info); end
            end
        end
        st.erMip = erMipMask(char(T.file));     % whole-movie ER support fallback
        buildWindows();                         % -> selectWindow -> drawDetail sets the full total/tracked/window readout
    end

    function [X,Y,F,MD,have,TID,CONF,SC] = cellLocs(T, useTracked)
        have=false; MD=[]; TID=[]; CONF=[]; SC=[];
        haveCloud = isstruct(T.allSpots) && isfield(T.allSpots,'X') && ~isempty(T.allSpots.X);
        if ~useTracked && haveCloud
            X=double(T.allSpots.X(:)); Y=double(T.allSpots.Y(:)); F=double(T.allSpots.FRAME(:));
            TID=(1:numel(X))';                                   % cloud: each detection its own "track"
            CONF=false(size(X)); SC=false(size(X));
            if isfield(T.allSpots,'MITODIST') && numel(T.allSpots.MITODIST)==numel(X), MD=double(T.allSpots.MITODIST(:)); have=true; end
        else
            M=T.matrix; [nF,nT,~]=size(M); X=reshape(M(:,:,2),[],1); Y=reshape(M(:,:,3),[],1); F=reshape(M(:,:,1),[],1);
            TID=reshape(repmat(1:nT,nF,1),[],1);                 % track id = matrix column of each localization
            CONF=false(numel(X),1); SC=false(numel(X),1);        % per-loc diffusion state (from spt_track_diffusion at Build)
            if isfield(T,'confined')    && isequal(size(T.confined),[nF nT]),    CONF=logical(reshape(T.confined,[],1)); end
            if isfield(T,'stateChange') && isequal(size(T.stateChange),[nF nT]), SC=logical(reshape(T.stateChange,[],1)); end
            if isfield(T,'mitoDist') && isequal(size(T.mitoDist),size(M(:,:,1))), MD=reshape(T.mitoDist,[],1); have=true; end
        end
        ok=isfinite(X)&isfinite(Y); X=X(ok); Y=Y(ok); F=F(ok); TID=TID(ok); CONF=CONF(ok); SC=SC(ok); if have, MD=MD(ok); end
        if ~have, MD=nan(size(X)); end
    end

    function m = erMipMask(base)
        % whole-movie ER support from the MIP (fallback when a window has no start-frame ER mask)
        m = true(st.grid, st.grid);
        prefix = regexprep(base,'_spt\d+$','','ignorecase');
        p = fullfile(st.mipDir,[prefix '_er_mip.tif']);
        if isfile(p)
            try, e=double(imread(p)); if ndims(e)==3, e=mean(e,3); end
                m = imresize(e,[st.grid st.grid],'bilinear') > 0.05*max(e(:)); catch, end
        end
        if ~any(m(:)), m = true(st.grid, st.grid); end
    end

    function m = segMaskAt(segPath, nfr, frame0)
        % binary organelle mask (fg = min nonzero label) at a 0-based frame, resized to the density grid
        m = [];
        if isempty(segPath) || nfr<1, return; end
        page = min(max(round(frame0)+1,1), nfr);
        try, a=imread(segPath,page); v=unique(a(:)); nz=v(v>0); fg=1; if ~isempty(nz), fg=double(min(nz)); end
            m = imresize(double(a==fg),[st.grid st.grid],'nearest') > 0.5; catch, m=[]; end
    end

    function m = werMask(w)
        % per-window ER support = ER seg at the window START frame; falls back to the whole-movie MIP
        if numel(st.werM)>=w && ~isempty(st.werM{w}), m=st.werM{w}; return; end
        m = segMaskAt(st.erPath, st.segNfr, st.win(w,1));
        if isempty(m) || ~any(m(:)), m = st.erMip; end
        st.werM{w} = m;
    end
    function m = wmitoMask(w)
        if numel(st.wmitoM)>=w && ~isempty(st.wmitoM{w}), m=st.wmitoM{w}; return; end
        m = segMaskAt(st.mitoPath, st.segMitoNfr, st.win(w,1)); st.wmitoM{w}=m;
    end

    function buildWindows()
        n=st.fpw; f1max=max(st.aF); if ~isfinite(f1max), f1max=0; end
        T=f1max+1;                                            % total frames (0-based span → count)
        step=st.step; if ~(step>0), step=n; end; step=min(step,n);
        if step>=n                                            % non-overlapping: absorb trailing remainder (legacy)
            nW=max(1, floor(T/n)); edges=(0:nW)*n; edges(end)=T;
            st.win=[edges(1:end-1)', edges(2:end)'-1];
        else                                                  % sliding / overlapping windows of length n, stride step
            starts=(0:step:max(0,T-n))'; if isempty(starts), starts=0; end
            W=[starts, min(starts+n,T)-1];
            if W(end,2) < T-1, W=[W; max(0,T-n), T-1]; end     % make sure the movie tail is covered
            st.win=W;
        end
        st.nW=size(st.win,1);
        if st.nW>st.MAXPANELS, st.win=st.win(1:st.MAXPANELS,:); st.nW=st.MAXPANELS; end
        st.sites=repmat({zeros(0,NCOL)},1,st.nW);
        st.wrc=cell(1,st.nW); st.wdens=cell(1,st.nW); st.werM=cell(1,st.nW); st.wmitoM=cell(1,st.nW); st.wnull=cell(1,st.nW);
        st.cw=1; st.selList=[];
        buildThumbs(); selectWindow(1);
    end

    function rc = windowRaw(w)
        if numel(st.wrc)>=w && ~isempty(st.wrc{w}), rc=st.wrc{w}; return; end
        m = densMask();                                  % density channel: tracked | confined | state-change
        rc = cs_window_density(st.aX(m), st.aY(m), st.aF(m), st.win(w,1), st.win(w,2), st.SF, st.grid, st.grid, st.sig);
        st.wrc{w}=rc;
    end
    function D = windowDensity(w)
        if numel(st.wdens)>=w && ~isempty(st.wdens{w}), D=st.wdens{w}; return; end
        D = imgaussfilt(windowRaw(w), st.sig); st.wdens{w}=D;
    end
    function [Dthr, nullMax] = windowNull(w)
        % cache nullMax (fixed per window/mask/M) + recompute Dthr live from the current sens (alpha)
        if numel(st.wnull)<w || isempty(st.wnull{w})
            [~, nm] = cs_mc_threshold(windowRaw(w), werMask(w), st.sig, max(min(st.sens,1),1e-4), st.MC);
            st.wnull{w} = nm;
        end
        nullMax = st.wnull{w};
        Dthr = cs_quantile_(nullMax, 1 - max(min(st.sens,1),1e-4));
    end

    % ---- thumbnails ----
    function buildThumbs()
        delete(allchild(pnThumbs));
        nc=min(st.nW, ceil(sqrt(st.nW))); if nc<1, nc=1; end; nr=ceil(st.nW/nc);
        tg2=uigridlayout(pnThumbs,[nr nc],'Padding',[4 4 4 4],'RowSpacing',3,'ColumnSpacing',3);
        st.thumbAx=gobjects(1,st.nW);
        for w=1:st.nW
            ax=uiaxes(tg2); ax.Toolbar.Visible='off'; disableDefaultInteractivity(ax); ax.YDir='reverse';
            ax.XTick=[]; ax.YTick=[]; ax.ButtonDownFcn=@(s,e) selectWindow(w);
            st.thumbAx(w)=ax; drawThumb(w);
        end
    end
    function drawThumb(w)
        ax=st.thumbAx(w); if ~isgraphics(ax), return; end
        cla(ax); image('Parent',ax,'CData',densRGB(windowDensity(w),st.clip),'HitTest','off');
        set(ax,'YDir','reverse'); axis(ax,'image'); xlim(ax,[1 st.grid]); ylim(ax,[1 st.grid]);
        P=st.sites{w};
        if ~isempty(P), hold(ax,'on'); scatter(ax,P(:,1),P(:,2),8,flagCol(P(:,3)),'filled','HitTest','off'); hold(ax,'off'); end
        sel=(w==st.cw); nl=winLocCount(w); low=nl<st.minLocs;
        tc=tern(sel,[0.1 0.35 0.75],[0.25 0.25 0.25]); if low, tc=[0.85 0.12 0.12]; end   % under the floor → red ⚠
        title(ax,sprintf('w%d · %d loc%s · %d site',w,nl,tern(low,' ⚠',''),size(P,1)),'FontSize',8, ...
            'Color',tc,'FontWeight',tern(sel||low,'bold','normal'));
        ec=tern(sel,[0.1 0.35 0.75],[0.6 0.6 0.6]); if low, ec=[0.85 0.12 0.12]; end
        ax.XColor=ec; ax.YColor=ec; ax.LineWidth=tern(sel,2,tern(low,1.4,0.5)); box(ax,'on');
    end

    function selectWindow(w)
        prev=st.cw; st.cw=w;
        if prev>=1 && prev<=st.nW && isgraphics(st.thumbAx(prev)), drawThumb(prev); end
        if isgraphics(st.thumbAx(w)), drawThumb(w); end
        drawDetail(); refreshList();
    end

    % ---- detail view ----
    function drawDetail()
      try
        w=st.cw; cla(axDet); D=windowDensity(w); erm=werMask(w);
        if strcmp(st.scaleMode,'sigp') && strcmp(st.method,'ermc') && numel(st.wnull)>=w && ~isempty(st.wnull{w})
            image('Parent',axDet,'CData',sigRGB(D,w,erm),'HitTest','off');           % recolour by p vs the ER-MC null
        elseif strcmp(st.scaleMode,'raw')
            image('Parent',axDet,'CData',densRGB(windowRaw(w),st.clip),'AlphaData',st.alpha,'HitTest','off');   % raw counts / 30 nm bin
        else
            image('Parent',axDet,'CData',densRGB(D,st.clip),'AlphaData',st.alpha,'HitTest','off');              % σ-smoothed density (a.u.)
        end
        set(axDet,'YDir','reverse','Color',[0 0 0]); axis(axDet,'image'); xlim(axDet,[1 st.grid]); ylim(axDet,[1 st.grid]);
        hold(axDet,'on');
        if chkLoc.Value                                                              % this window's localizations
            inw=st.aF>=st.win(w,1)&st.aF<=st.win(w,2); lx=st.aX(inw)/st.SF; ly=st.aY(inw)/st.SF;
            if numel(lx)>60000, s2=ceil(numel(lx)/60000); lx=lx(1:s2:end); ly=ly(1:s2:end); end
            scatter(axDet,lx,ly,2,'w','filled','MarkerFaceAlpha',0.15,'HitTest','off');
        end
        if chkER.Value,   drawMaskBnd(axDet, werMask(w),  [0.25 1 0.5]);  end   % ER contour, start-frame
        if chkMito.Value, drawMaskBnd(axDet, wmitoMask(w),[1 0.30 0.85]); end   % mito contour, start-frame
        P=st.sites{w};
        for i=1:size(P,1)
            selHi=ismember(i,st.selList);
            rectangle('Parent',axDet,'Position',[P(i,1)-8 P(i,2)-8 16 16],'Curvature',[1 1], ...
                'EdgeColor',flagCol(P(i,3)),'LineWidth',tern(selHi,2.4,1.2),'HitTest','off');
            if selHi, plot(axDet,P(i,1),P(i,2),'w+','MarkerSize',9,'LineWidth',1.2,'HitTest','off'); end
        end
        if numel(st.selList)==1, drawSiteTracks(st.selList); end   % one site selected → overlay its tracks by dwell
        hold(axDet,'off');
        nlw=winLocCount(w); tc=[0.1 0.1 0.1]; warnTxt='';
        if nlw<st.minLocs, tc=[0.85 0.12 0.12]; warnTxt=sprintf(' · ⚠ LOW (%d<%d locs)',nlw,st.minLocs); end
        title(axDet,sprintf('window %d/%d [frames %d-%d] · %d loc · %d site(s)%s  %s', w,st.nW,st.win(w,1),st.win(w,2), ...
            nlw, size(P,1), warnTxt, tern(st.addMode,'— CLICK to add','')),'FontSize',10,'Color',tc);
        xlabel(axDet,'density px (x)'); ylabel(axDet,'density px (y)');
        drawColorbar(w);
        nwin = winLocCount(w);                                   % tracked locs in THIS window (matches the titles)
        set(lbl,'Text', sprintf('%s · THIS window %d tracked locs%s', statusText(), nwin, ...
            tern(isempty(st.cbInfo),'',[' · ' st.cbInfo])));
      catch ME
        set(lbl,'Text',['detail draw error: ' ME.message]);
      end
    end

    function rgb = sigRGB(D, w, erm)
        p = pmapFor(D, w); p(~erm)=1;                       % outside ER → not significant
        idx = uint8(round(255*(1 - min(p/0.2,1))));         % small p (<=0.2) → hot; zoom the low-p range
        rgb = ind2rgb(idx, hot(256)); rgb(repmat(~erm,[1 1 3]))=0.05;
    end
    function p = pmapFor(D, w)
        [~, nm] = windowNull(w); M=numel(nm);
        p = zeros(size(D)); for m=1:M, p = p + double(nm(m) >= D); end; p = p/max(M,1);
    end

    function drawColorbar(w)
        % Draw the colorbar and set st.cbInfo (a short cutoff/peak readout for the status line — the
        % colorbar itself carries no title, which is what got cut off in the narrow axes).
        cla(axCbar); st.cbInfo=''; D=windowDensity(w); erm=werMask(w);
        pkobs = max(D(erm)); if isempty(pkobs)||~(pkobs>0), pkobs=max(D(:)); end; if ~(pkobs>0), pkobs=1; end
        if strcmp(st.scaleMode,'sigp') && strcmp(st.method,'ermc') && numel(st.wnull)>=w && ~isempty(st.wnull{w})
            strip=reshape(flipud(hot(256)),[256 1 3]);      % top p=0 (hot) … bottom p=0.2
            image('Parent',axCbar,'XData',[0 1],'YData',[0 0.2],'CData',strip,'HitTest','off');
            set(axCbar,'YDir','reverse','XLim',[0 1],'YLim',[0 0.2],'XTick',[]); hold(axCbar,'on');
            a=max(min(st.sens,1),1e-4); if a<=0.2, plot(axCbar,[0 1],[a a],'-','Color',[0.1 0.5 1],'LineWidth',2); end
            hold(axCbar,'off'); ylabel(axCbar,'p (vs ER-MC null)');
            st.cbInfo = sprintf('sig(p): sites where p ≤ α=%.3g', st.sens);
        elseif strcmp(st.scaleMode,'raw')
            R=windowRaw(w); rpk=max(R(erm)); if isempty(rpk)||~(rpk>0), rpk=max(R(:)); end; if ~(rpk>0), rpk=1; end
            lam = sum(R(erm)) / max(nnz(erm),1);             % ER-MC CSR background: on-ER locs / ER bin (locs per 30 nm bin)
            top=max(st.clip*rpk,eps); strip=reshape(turbo(256),[256 1 3]);
            image('Parent',axCbar,'XData',[0 1],'YData',[0 top],'CData',strip,'HitTest','off');
            set(axCbar,'YDir','normal','XLim',[0 1],'YLim',[0 top],'XTick',[]); hold(axCbar,'on');
            if lam<=top, plot(axCbar,[0 1],[lam lam],'-','Color',[0.1 0.5 1],'LineWidth',2); end   % CSR background line
            plot(axCbar,0.5,min(rpk,top),'v','MarkerFaceColor','k','MarkerEdgeColor','w','MarkerSize',7);
            hold(axCbar,'off'); ylabel(axCbar,'localizations / 30 nm bin');
            st.cbInfo = sprintf('ER-MC background %.2g locs/bin · peak %g (%.1f× enrich)', lam, rpk, rpk/max(lam,eps));
        else
            top=max(st.clip*pkobs,eps); strip=reshape(turbo(256),[256 1 3]);
            image('Parent',axCbar,'XData',[0 1],'YData',[0 top],'CData',strip,'HitTest','off');
            set(axCbar,'YDir','normal','XLim',[0 1],'YLim',[0 top],'XTick',[]); hold(axCbar,'on');
            if strcmp(st.method,'ermc') && numel(st.wnull)>=w && ~isempty(st.wnull{w})
                nm=st.wnull{w}; Dthr=cs_quantile_(nm, 1-max(min(st.sens,1),1e-4)); nmed=median(nm);   % cached null only
                yb0=min(nmed,top); yb1=min(Dthr,top);
                if yb1>yb0, patch(axCbar,[0 1 1 0],[yb0 yb0 yb1 yb1],[0.55 0.6 0.66],'FaceAlpha',0.55,'EdgeColor','none','HitTest','off'); end
                if Dthr<=top, plot(axCbar,[0 1],[Dthr Dthr],'-','Color',[0.9 0.1 0.1],'LineWidth',2.2);
                else, plot(axCbar,0.5,top,'^','MarkerFaceColor',[0.9 0.1 0.1],'MarkerEdgeColor','w','MarkerSize',8); end
                st.cbInfo = sprintf('cutoff α=%.3g · peak p=%.3g', st.sens, mean(nm>=pkobs));
            elseif strcmp(st.method,'ermc')
                st.cbInfo = 'run Detect to compute the ER-MC cutoff';
            elseif strcmp(st.method,'relative')
                thr=max(min(st.sens,1),0.02)*pkobs; if thr<=top, plot(axCbar,[0 1],[thr thr],'-','Color',[0.9 0.1 0.1],'LineWidth',2.2); end
                st.cbInfo = sprintf('rel cutoff %.2f×peak', st.sens);
            else
                st.cbInfo = 'local bg (per-pixel threshold)';
            end
            plot(axCbar,0.5,min(pkobs,top),'v','MarkerFaceColor','k','MarkerEdgeColor','w','MarkerSize',7);
            hold(axCbar,'off'); ylabel(axCbar,'density (a.u., σ-smoothed)');
        end
    end

    function onDetailClick(e)
        try, p=e.IntersectionPoint(1:2); catch, return; end
        if ~isempty(chkExplain) && isgraphics(chkExplain) && chkExplain.Value, explainSpot(p(1),p(2)); return; end
        w=st.cw; P=st.sites{w};
        if st.addMode
            fl=classifyOne(p(1),p(2)); st.sites{w}=[P; p(1) p(2) fl 1 nan(1,NCOL-4)];   % manual site: no auto stats
            drawDetail(); drawThumb(w); refreshList();
        else
            if isempty(P), return; end
            d=hypot(P(:,1)-p(1),P(:,2)-p(2)); [md,mi]=min(d);
            if md<=14
                if ismember(mi,st.selList), st.selList=setdiff(st.selList,mi); else, st.selList=union(st.selList,mi); end
                syncListFromSel(); drawDetail();
            end
        end
    end

    function explainSpot(xc, yc)
        % Report the clicked location's stats — even where no site was detected (near-miss transparency).
        w=st.cw; ci=round(xc); ri=round(yc);
        if ci<1||ci>st.grid||ri<1||ri>st.grid, set(lblExplain,'Text','(outside grid)'); return; end
        D=windowDensity(w); dv=D(ri,ci);
        bg=median(D(werMask(w))); if ~(bg>0), bg=eps; end; enr=dv/bg;
        pstr='';
        if strcmp(st.method,'ermc'), [~,nm]=windowNull(w); pstr=sprintf(' · p=%.2g (%.0f%%ile of null)', mean(nm>=dv), 100*mean(nm<dv)); end
        rpx=max(2,round(max(st.contactUm,0.15)/st.SF));
        inw=st.aF>=st.win(w,1)&st.aF<=st.win(w,2); lx=st.aX(inw)/st.SF; ly=st.aY(inw)/st.SF; lt=st.aT(inw);
        near=hypot(lx-xc,ly-yc)<=rpx; ntrk=numel(unique(lt(near)));
        set(lblExplain,'Text',sprintf('spot (%.0f,%.0f): dens %.2g · %.1f×bg · %d loc / %d trk%s', xc,yc,dv,enr,nnz(near),ntrk,pstr));
        drawDetail(); hold(axDet,'on'); plot(axDet,xc,yc,'x','Color',[1 1 1],'MarkerSize',13,'LineWidth',1.6,'HitTest','off'); hold(axDet,'off');
    end

    function drawSiteTracks(siteRow)
        % Overlay the tracks associated with the selected site, coloured by how much each DWELLS inside
        % it (blue = passing through → red = dwelling). Membership = within the site's equivalent-circle
        % radius (√(area/π)) of its centroid — a quick track-behaviour view before the boundary is refined.
        w=st.cw; P=st.sites{w}; if siteRow<1||siteRow>size(P,1)||isempty(st.aT), return; end
        cx=P(siteRow,SC.x); cy=P(siteRow,SC.y);
        aUm=P(siteRow,SC.area); if ~(aUm>0), aUm=(3*st.SF)^2; end
        rpx=max(sqrt(aUm/pi)/st.SF, 3);                       % site radius in density px
        inw=st.aF>=st.win(w,1)&st.aF<=st.win(w,2);
        lx=st.aX(inw)/st.SF; ly=st.aY(inw)/st.SF; lt=st.aT(inw);
        d=hypot(lx-cx,ly-cy); utrk=unique(lt(d<=rpx));
        if isempty(utrk), return; end
        dwp=zeros(numel(utrk),1);
        for k=1:numel(utrk)
            m=lt==utrk(k); dwp(k)=100*nnz(d(m)<=rpx)/max(nnz(m),1);
            plot(axDet, lx(m), ly(m), '-','Color',dwellColor(dwp(k)),'LineWidth',1.0,'HitTest','off');
        end
        th=linspace(0,2*pi,48); plot(axDet, cx+rpx*cos(th), cy+rpx*sin(th), '-','Color',[1 1 1 0.7],'LineWidth',0.7,'HitTest','off');
        set(lblExplain,'Text',sprintf('site %d: %d assoc track(s) · dwell%% med %.0f · %d >50%% inside  (blue passing → red dwelling)', ...
            siteRow, numel(utrk), median(dwp), nnz(dwp>50)));
    end
    function c=dwellColor(pct), t=min(max(pct/100,0),1); c=[t 0.30 1-t]; end   % 0% → blue, 100% → red

    % ---- detection ----
    function detectWindow(w)
        set(lbl,'Text',sprintf('Detecting window %d (%s)…',w,st.method)); drawnow;
        rc=windowRaw(w); erm=werMask(w); dens=imgaussfilt(rc,st.sig); st.wdens{w}=dens;
        p=detParams();
        p.splitPeaks=st.splitPeaks; p.minEnrich=st.minEnrich; p.minSiteLocs=st.minSiteLocs;
        if strcmp(st.method,'ermc'), [p.Dthr, p.nullMax]=windowNull(w); end   % one MC run, reused for detection + p-values + colorbar
        [xy,~,~,S]=cs_detect(rc, erm, st.sig, st.method, p);
        % per-site: distinct contributing tracks + median dwell % + split-half stability + mito class
        [nTrk, stab, dwell] = siteTrackStability(w, S, erm, dens);
        keep = nTrk >= st.minTracks;                                          % distinct-molecule gate
        xy=xy(keep,:); S=S(keep); nTrk=nTrk(keep); stab=stab(keep); dwell=dwell(keep); nDrop=nnz(~keep);
        K=size(xy,1); rows=zeros(K,NCOL);
        for i=1:K
            fl=classifyOne(xy(i,1),xy(i,2));
            rows(i,:)=[xy(i,1) xy(i,2) fl 0 S(i).peak S(i).pval S(i).enrich S(i).nLocs nTrk(i) stab(i) S(i).areaPx*st.SF^2 dwell(i)];
        end
        keepManual=st.sites{w}(st.sites{w}(:,SC.manual)==1,:);
        st.sites{w}=[keepManual; rows]; st.selList=[];
        selectWindow(w);
        gtxt=''; if nDrop>0, gtxt=sprintf(' · %d dropped (<%d tracks)',nDrop,st.minTracks); end
        set(lbl,'Text',sprintf('Window %d: %d auto + %d manual site(s) [%s]%s  ·  %s', w, K, size(keepManual,1), st.method, gtxt, statusText()));
    end

    function [nTrk, stab, dwell] = siteTrackStability(w, S, erm, dens)
        % Per detected site: (a) # DISTINCT tracks whose localizations fall in its footprint, (b) the
        % median DWELL % of those tracks = for each track, what fraction of ITS window localizations
        % lie inside the site (dwelling vs merely passing through), and (c) a split-half stability
        % score = fraction of seeded random half-splits where the site PEAK stays enriched in BOTH halves.
        nS=numel(S); nTrk=zeros(nS,1); stab=nan(nS,1); dwell=nan(nS,1);
        inw = st.aF>=st.win(w,1) & st.aF<=st.win(w,2);
        lx=st.aX(inw)/st.SF; ly=st.aY(inw)/st.SF; lt=st.aT(inw);
        col=round(lx); row=round(ly); ok=col>=1&col<=st.grid&row>=1&row<=st.grid;
        col=col(ok); row=row(ok); lt=lt(ok); lin=sub2ind([st.grid st.grid],row,col);
        [~,~,ic]=unique(lt); totPer=accumarray(ic,1);          % total window locs per track
        pkpix=zeros(nS,1);
        for i=1:nS
            inSite = ismember(lin, S(i).pixels);
            icIn = ic(inSite); uu=unique(icIn);
            nTrk(i) = numel(uu);                               % distinct tracks in the footprint
            if ~isempty(uu)
                insPer = accumarray(icIn, 1, [numel(totPer) 1]);
                dwell(i) = median(100*insPer(uu)./totPer(uu)); % median % of each track's locs inside the site
            end
            [~,mi]=max(dens(S(i).pixels)); pkpix(i)=S(i).pixels(mi);   % the site's peak pixel
        end
        nL=numel(lin); if nL<20 || nS<1, return; end           % too few to split-half meaningfully
        nSp=4; stab(:)=0;
        for s=1:nSp
            rng(90210+s,'twister'); h=rand(nL,1)<0.5;
            DA=imgaussfilt(accumarray([row(h) col(h)],1,[st.grid st.grid]), st.sig);
            DB=imgaussfilt(accumarray([row(~h) col(~h)],1,[st.grid st.grid]), st.sig);
            bgA=median(DA(erm)); bgB=median(DB(erm)); if ~(bgA>0),bgA=eps; end; if ~(bgB>0),bgB=eps; end
            for i=1:nS
                stab(i)=stab(i) + (DA(pkpix(i))>=1.5*bgA && DB(pkpix(i))>=1.5*bgB);
            end
        end
        stab = stab / nSp;
    end
    function detectCur(), detectWindow(st.cw); end   % nested -> reads the LIVE current window (not a captured value)
    function detectAll()
        for w=1:st.nW, detectWindow(w); end
        set(lbl,'Text',sprintf('Detected all %d windows (%s): %d site(s) total.',st.nW,st.method,totalSites()));
    end

    % ---- window-length sweep: how # sites + significance depend on the window length ----
    function onSweep()
        if isempty(st.aF), set(lblSweep,'Text','Load a cell first.'); return; end
        T = max(st.aF)+1; if ~(T>1), return; end
        Ks   = [1 2 4 8 16]; Ks = Ks(Ks <= st.MAXPANELS);          % candidate # of (non-overlapping) windows
        fpws = unique(round(T ./ Ks)); fpws = fpws(fpws>=50);      % frames/window for each K (floor 50)
        if numel(fpws)<2, set(lblSweep,'Text','Movie too short to sweep.'); return; end
        mcS  = min(st.MC, 80);                                     % cheaper MC just for the sweep
        erm  = st.erMip; if isempty(erm) || ~any(erm(:)), erm = true(st.grid,st.grid); end
        alpha= max(min(st.sens,1),1e-4);
        nSites=nan(size(fpws)); medSig=nan(size(fpws)); locsW=nan(size(fpws)); nWins=nan(size(fpws));
        btnSweep.Enable='off'; drawnow;
        try
            for k=1:numel(fpws)
                n=fpws(k); nw=max(1,floor(T/n)); edges=(0:nw)*n; edges(end)=T; W=[edges(1:end-1)', edges(2:end)'-1];
                nWins(k)=size(W,1); tot=0; sigs=[]; lpw=[];
                for w=1:size(W,1)
                    rc = cs_window_density(st.aX,st.aY,st.aF, W(w,1),W(w,2), st.SF,st.grid,st.grid,st.sig);
                    lpw(end+1)=round(sum(rc,'all')); %#ok<AGROW>
                    [~, nm] = cs_mc_threshold(rc, erm, st.sig, alpha, mcS);
                    p=detParams(); p.M=mcS; if strcmp(st.method,'ermc'), p.Dthr=cs_quantile_(nm, 1-alpha); end
                    xy = cs_detect(rc, erm, st.sig, st.method, p);
                    tot = tot + size(xy,1);
                    if ~isempty(xy)
                        D=imgaussfilt(rc,st.sig);
                        for i=1:size(xy,1)
                            xc=round(xy(i,1)); yc=round(xy(i,2));
                            if xc>=1&&xc<=st.grid&&yc>=1&&yc<=st.grid, sigs(end+1)=mean(nm>=D(yc,xc)); end %#ok<AGROW>
                        end
                    end
                end
                nSites(k)=tot; locsW(k)=round(mean(lpw)); if ~isempty(sigs), medSig(k)=median(sigs); end
                set(lblSweep,'Text',sprintf('Sweeping… %d/%d (fpw %d → %d win, %d sites)',k,numel(fpws),n,size(W,1),tot)); drawnow;
            end
        catch ME
            btnSweep.Enable='on'; set(lblSweep,'Text',['Sweep error: ' ME.message]); return;
        end
        btnSweep.Enable='on'; set(lblSweep,'Text',sprintf('Sweep done (%d points) — see the popup.',numel(fpws)));
        sweepPlot(fpws, nWins, locsW, nSites, medSig);
    end

    function sweepPlot(fpws, nWins, locsW, nSites, medSig)
        [fs,o]=sort(fpws); nWins=nWins(o); locsW=locsW(o); nSites=nSites(o); medSig=medSig(o);
        fp=uifigure('Name','Window-length sweep','Position',[200 200 780 500]);
        gg=uigridlayout(fp,[2 1],'RowHeight',{'1x',70},'Padding',[10 10 10 10]);
        ax=uiaxes(gg);
        yyaxis(ax,'left');
        plot(ax,fs,nSites,'-o','LineWidth',1.7,'MarkerFaceColor',[0.13 0.40 0.66]);
        for i=1:numel(fs), text(ax,fs(i),nSites(i),sprintf('  %dwin',nWins(i)),'FontSize',7,'Color',[0.2 0.3 0.5]); end
        ylabel(ax,'# contact sites detected (all windows)');
        yyaxis(ax,'right');
        plot(ax,fs,1-medSig,'--s','LineWidth',1.4,'MarkerFaceColor',[0.80 0.30 0.20]);
        ylabel(ax,'median site significance (1 − p)'); ylim(ax,[0 1.05]);
        xlabel(ax,'frames / window  (→ shorter windows = more temporal detail, fewer locs each)');
        set(ax,'XScale','log'); grid(ax,'on');
        try, xline(ax, st.fpw, ':', sprintf('current %d',st.fpw), 'Color',[0.4 0.4 0.4], 'LabelVerticalAlignment','bottom'); catch, end
        title(ax,'Window-length sweep — pick the knee where # sites stabilizes & significance stays high');
        rows = arrayfun(@(i) sprintf('fpw %d: %d win · ~%d loc/win · %d sites · med sig %.2f', ...
            fs(i), nWins(i), locsW(i), nSites(i), 1-medSig(i)), 1:numel(fs), 'uni',0);
        uilabel(gg,'Text',['Approximate (whole-movie ER support, ' num2str(min(st.MC,80)) '-run MC).   ' strjoin(rows,'    |    ')], ...
            'WordWrap','on','FontColor',[0.3 0.3 0.4],'FontSize',11);
    end
    function clearWindow(), st.sites{st.cw}=zeros(0,NCOL); st.selList=[]; selectWindow(st.cw); end
    function toggleAdd()
        st.addMode=~st.addMode; btnAdd.Text=tern(st.addMode,'＋ Adding — click map','＋ Add site');
        btnAdd.BackgroundColor=tern(st.addMode,[0.20 0.55 0.30],[0.98 0.88 0.70]); btnAdd.FontColor=tern(st.addMode,'w',[0.55 0.32 0.05]);
        drawDetail();
    end

    function fl=classifyOne(cx,cy)
        if ~st.haveMD, fl=2; return; end
        w=st.cw; inw=st.aF>=st.win(w,1)&st.aF<=st.win(w,2);
        lx=st.aX(inw)/st.SF; ly=st.aY(inw)/st.SF; md=st.aMD(inw);
        fl=cs_mito_from_dist([cx cy], lx, ly, md, max(0.6/st.SF,3), st.contactUm, false);
    end
    function reclassify()
        st.contactUm=eContact.Value;
        for w=1:st.nW, P=st.sites{w}; for i=1:size(P,1), c0=st.cw; st.cw=w; P(i,3)=classifyOne(P(i,1),P(i,2)); st.cw=c0; end, st.sites{w}=P; end
        drawThumbAll(); drawDetail(); refreshList();
    end

    function p=detParams()
        p=struct('M',st.MC,'minArea',st.minArea);
        switch st.method
            case 'ermc',     p.alpha=max(min(st.sens,1),1e-4);
            case 'relative', p.relFrac=max(min(st.sens,1),0.02);
            case 'local',    p.localK=1+4*max(min(st.sens,1),0);
        end
    end

    % ---- control callbacks ----
    function onFpw(),  st.fpw=round(eFpw.Value); buildWindows(); end
    function onStep(), st.step=round(eStep.Value); buildWindows(); end
    function onMinLocs(), st.minLocs=round(eMinLocs.Value); drawThumbAll(); drawDetail(); end
    function onSplit(), st.splitPeaks=chkSplit.Value; set(lbl,'Text','Split-peaks changed — re-run Detect to apply.'); end
    function onGate(), st.minEnrich=eMinEnr.Value; st.minTracks=round(eMinTrk.Value); set(lbl,'Text','Gate changed — re-run Detect (win/all) to apply.'); end
    function onDensMode()
        st.densMode = ddChannel.Value;
        st.wrc=cell(1,st.nW); st.wdens=cell(1,st.nW); st.wnull=cell(1,st.nW);   % channel changed -> density/null caches stale
        drawThumbAll(); drawDetail();
        set(lbl,'Text',sprintf('Density channel: %s — re-run Detect to find sites on this channel.', ddChannel.Value));
    end
    function m = densMask()
        switch st.densMode
            case 'confined',    m = st.aConf;         % only low-D (dwelling) localizations
            case 'statechange', m = st.aSC;           % only fast->slow transition localizations
            otherwise,          m = [];               % tracked = all
        end
        if isempty(m) || numel(m)~=numel(st.aX), m = true(numel(st.aX),1); end
    end
    function c = winLocCount(w)                                   % localizations of the CURRENT channel in window w
        if w<1 || w>st.nW, c=0; return; end
        m = densMask();
        c = nnz(m & st.aF>=st.win(w,1) & st.aF<=st.win(w,2));
    end
    function onMeth()
        st.method=ddMeth.Value;
        switch st.method, case 'ermc', eSens.Value=0.01; case 'relative', eSens.Value=0.5; case 'local', eSens.Value=0.15; end
        st.sens=eSens.Value;
        if strcmp(st.scaleMode,'sigp') && ~strcmp(st.method,'ermc'), ddScale.Value='density'; st.scaleMode='density'; end
        drawDetail();
    end
    function onSens(), st.sens=eSens.Value; drawColorbar(st.cw); if strcmp(st.scaleMode,'sigp'), drawDetail(); end, end
    function onSims(), st.MC=round(eSims.Value); st.wnull=cell(1,st.nW); drawDetail(); end   % M changed -> null cache stale
    function onContrast(), st.clip=eContrast.Value; drawThumbAll(); drawDetail(); end
    function onScale()
        st.scaleMode=ddScale.Value;
        if strcmp(st.scaleMode,'sigp') && (~strcmp(st.method,'ermc') || numel(st.wnull)<st.cw || isempty(st.wnull{st.cw}))
            set(lbl,'Text','Significance (p) needs ER-MC + a Detect on this window first.');
        end
        drawDetail();
    end

    % ---- site table (per-site stats, transparency) ----
    function refreshList()
        P=st.sites{st.cw}; n=size(P,1); D=cell(n,6);
        for i=1:n
            D(i,:)={ sprintf('%d',i), fmtStat(P(i,SC.pval),'%.2g'), fmtStat(P(i,SC.enr),'%.1f'), ...
                     fmtStat(P(i,SC.ntrk),'%d'), fmtStat(P(i,SC.dwell),'%.0f'), fmtStat(P(i,SC.stab),'%.2f') };
        end
        tblSites.Data=D;
        lblList.Text=sprintf('Sites in window %d (%d) — click a row to see its tracks',st.cw,n); syncListFromSel();
    end
    function s=fmtStat(v,f), if isnan(v), s='—'; else, s=sprintf(f,v); end, end
    function onTableSel(e), try, st.selList=e.Selection(:)'; catch, st.selList=[]; end, drawDetail(); end
    function syncListFromSel()
        try, if isempty(st.selList), tblSites.Selection=[]; else, tblSites.Selection=intersect(st.selList,1:size(tblSites.Data,1)); end, catch, end
    end
    function removeSelected()
        if isempty(st.selList), return; end
        P=st.sites{st.cw}; st.sites{st.cw}=P(setdiff(1:size(P,1),st.selList),:); st.selList=[]; selectWindow(st.cw);
    end

    % ---- save ----
    function doSave()
      try
        base=char(st.Tracks(st.ci).file);
        csDir=fullfile(anaDir,'csIDs'); if ~isfolder(csDir), mkdir(csDir); end
        rows=zeros(0,3); widx=zeros(0,1);
        for w=1:st.nW, P=st.sites{w}; for i=1:size(P,1), rows(end+1,:)=[P(i,1) P(i,2) P(i,3)]; widx(end+1,1)=w; end, end %#ok<AGROW>
        fp=fullfile(csDir,[base '_CSsites.txt']);
        if isempty(rows)
            if isfile(fp), delete(fp); end
        else
            fid=fopen(fp,'w'); fprintf(fid,' \tX\tY\tXM\tYM\tSlice\tCounter\tCount\n');
            for j=1:size(rows,1)
                fprintf(fid,'%d\t%.3f\t%.3f\t%.3f\t%.3f\t%d\t%d\t%d\n', j, rows(j,1),rows(j,2),rows(j,1),rows(j,2),widx(j),rows(j,3),0);
            end
            fclose(fid);
        end
        windows=struct('framesPerWindow',st.fpw,'nWindows',st.nW,'ranges',st.win,'grid',st.grid, ...
            'SF_umPerPx',st.SF,'frameInterval',st.Tracks(st.ci).frameInterval,'source',st.src); %#ok<NASGU>
        save(fullfile(anaDir,['Density_' base '_CSwindows.mat']),'windows');
        % --- provenance stamp: every result traceable to exactly how it was made ---
        try
            prov=struct('date',char(datetime('now','Format','yyyy-MM-dd HH:mm:ss')),'cell',base, ...
                'densitySource','tracked (matrix)','method',st.method,'alpha_sens',st.sens,'MC_sims',st.MC, ...
                'sigma_px',st.sig,'minArea_px',st.minArea,'splitPeaks',st.splitPeaks,'minEnrich',st.minEnrich, ...
                'minTracks',st.minTracks,'minSiteLocs',st.minSiteLocs,'contactUm',st.contactUm, ...
                'framesPerWindow',st.fpw,'stepFrames',st.step,'nWindows',st.nW,'windowRanges',st.win, ...
                'grid',st.grid,'SF_umPerPx',st.SF,'FOV_um',st.FOV,'binNm',st.binNm, ...
                'totalDetections',st.nAll,'trackedLocs',st.nDet,'nSites',size(rows,1));
            fid2=fopen(fullfile(csDir,[base '_CSsites_provenance.json']),'w');
            fprintf(fid2,'%s', jsonencode(prov,'PrettyPrint',true)); fclose(fid2);
        catch, end
        % --- per-site stats CSV (p, enrichment, #tracks, #locs, stability) for the record ---
        try
            fid3=fopen(fullfile(csDir,[base '_CSsites_stats.csv']),'w'); sidx=0;
            fprintf(fid3,'site,window,x_px,y_px,mito,manual,peak,pval,enrich,nLocs,nTracks,stability,dwell_pct,area_um2\n');
            for w=1:st.nW, P=st.sites{w};
                for i=1:size(P,1), sidx=sidx+1;
                    fprintf(fid3,'%d,%d,%.3f,%.3f,%d,%d,%.4g,%.4g,%.4g,%g,%g,%.3g,%.3g,%.4g\n', sidx,w, ...
                        P(i,SC.x),P(i,SC.y),P(i,SC.flag),P(i,SC.manual),P(i,SC.peak),P(i,SC.pval), ...
                        P(i,SC.enr),P(i,SC.nloc),P(i,SC.ntrk),P(i,SC.stab),P(i,SC.dwell),P(i,SC.area));
                end
            end
            fclose(fid3);
        catch, end
        set(lbl,'Text',sprintf('Saved %d site(s)/%d windows → %s_CSsites.txt + _CSsites_stats.csv + _CSsites_provenance.json + Density_%s_CSwindows.mat', size(rows,1), st.nW, base, base));
      catch ME
        set(lbl,'Text',['Save failed: ' ME.message]);
      end
    end

    % ---- helpers ----
    function s=statusText()
        pct = tern(st.nAll>0, 100*st.nDet/max(st.nAll,1), 100);
        ch = ''; if ~strcmp(st.densMode,'tracked'), ch = sprintf(' · channel %s (%d locs)', st.densMode, nnz(densMask())); end
        s=sprintf('%s · detections %d · tracked %d (%.0f%%)%s · %d windows · %s', ...
            char(st.Tracks(st.ci).file), st.nAll, st.nDet, pct, ch, st.nW, ...
            tern(st.haveMD,'mito from MITODIST','no MITODIST'));
    end
    function n=totalSites(), n=0; for w=1:st.nW, n=n+size(st.sites{w},1); end, end
    function drawThumbAll(), for w=1:st.nW, drawThumb(w); end, end
    function rgb=densRGB(D,clip)
        pk=max(D(:)); if ~(pk>0), pk=1; end
        idx=uint8(round(255*min(max(D,0)/(clip*pk),1))); rgb=ind2rgb(idx,turbo(256));
    end
    function col=flagCol(fl)
        col=zeros(numel(fl),3); for i=1:numel(fl), if fl(i)==1, col(i,:)=[1 0.2 0.9]; else, col(i,:)=[0.1 0.85 1]; end, end
    end
    function drawMaskBnd(ax, mask, col)
        % organelle boundary as line(s) — robust on a uiaxes (unlike contour with 'HitTest')
        if isempty(mask) || ~any(mask(:)), return; end
        try, B = bwboundaries(mask,'noholes'); catch, return; end
        for bi=1:numel(B), bb=B{bi}; plot(ax, bb(:,2), bb(:,1), '-','Color',col,'LineWidth',1.1,'HitTest','off'); end
    end
end

% -------------------------------------------------------------------------
function v=getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end

function p = activeTsFile_(anaDir)
% The named build in force for this project, per analysis/active_trackstruct.txt (written by the
% Curate & Build tool). Empty when there is no pointer or it names a file that is not there.
p = '';
try
    q = fullfile(anaDir,'active_trackstruct.txt');
    if ~isfile(q), return; end
    s = strtrim(fileread(q));
    if ~isempty(s) && isfile(fullfile(anaDir,s)), p = fullfile(anaDir,s); end
catch
end
end
function y=tern(c,a,b), if c, y=a; else, y=b; end, end
function q=cs_quantile_(x,p)
x=sort(x(:)); n=numel(x);
if n==0, q=Inf; return; end
if n==1, q=x(1); return; end
h=(n-1)*min(max(p,0),1)+1; lo=floor(h); q=x(lo)+(h-lo)*(x(min(lo+1,n))-x(lo));
end
