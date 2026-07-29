function cs_refine(analysisDir, varargin)
%CS_REFINE  In-MATLAB, mouse-driven replacement for the Wacom CSrefiner2 gate.
%
% For each contact site the mapper found, this shows the CS-local density map and
% lets you, with a MOUSE:
%   1. click the refined CENTRE of the contact site            (drawpoint)
%   2. trace its BOUNDARY — press-and-drag freehand (drawfreehand)
% then Accept (or Redo, or "Use full box" to keep it unrefined). No Wacom needed.
%
% It writes CSdata/<base>_CSdata.mat with the refined fields (refCenter,
% refboundary, refLocIDs, CSLocIDs, IDmatrixMN, EllipseFit) added to the mapper's
% struct — coordinate-IDENTICAL to CS_refiner_v2_wacom.m — so CS_builderNoJBM
% reads it unchanged.
%
%   cs_refine(analysisDir)                     % ALL CSs, in its own window
%   cs_refine(analysisDir,'MitoFlag',1)        % only mito-flagged CSs
%   cs_refine(analysisDir,'Parent',uiPanel)    % embed the UI in an app panel/tab
%
% NAME-VALUE
%   'MitoFlag' : 0 (default) refine every CS (REQUIRED for CS_builderNoJBM, which
%                reads ref fields on every CS); 1 = mito only; -1 = non-mito only.
%   'Parent'   : a uipanel / uitab / uifigure to build the UI inside (for the
%                integrated app). [] (default) opens a standalone uifigure window.
%
% Runs AFTER the mapper + snaprename: reads Tracks_final.mat (matrix source) and
% TrackData/<base>_CSdata.mat (mapper structs), writes CSdata/<base>_CSdata.mat.

ip = inputParser;
ip.addParameter('MitoFlag',0,@(x)isnumeric(x)&&isscalar(x));
ip.addParameter('OnlyCS',[],@isnumeric);   % re-refine only these csIDs (keep the rest as-is); [] = all
ip.addParameter('OnlyCell',[],@isnumeric); % ...IN this cell only (csID is per-cell, not global)
ip.addParameter('Parent',[]);
ip.addParameter('MitoDir','',@ischar);                     % ER/mito overlay folders + patterns (Experiment tab)
ip.addParameter('MitoPat','{prefix}_mito_mip.tif',@ischar);
ip.addParameter('MitoStrip','_spt\d+',@ischar);
ip.addParameter('ErDir','',@ischar);
ip.addParameter('ErPat','{prefix}_er_mip.tif',@ischar);
ip.parse(varargin{:});
MitoFlag = ip.Results.MitoFlag;
OnlyCS   = ip.Results.OnlyCS(:)';
OnlyCell = ip.Results.OnlyCell;
inParent = ip.Results.Parent;
ovMitoDir=ip.Results.MitoDir; ovMitoPat=ip.Results.MitoPat; ovStrip=ip.Results.MitoStrip;
ovErDir=ip.Results.ErDir; ovErPat=ip.Results.ErPat;
if ~isempty(inParent) && ~isgraphics(inParent), inParent = []; end   % stale handle -> standalone

assert(isfolder(analysisDir),'cs_refine: analysisDir not found: %s',analysisDir);
cfg    = cs_config(analysisDir);   % this run's cs_calib.mat drives SF, regardless of pwd (match cs_identify)
Tracks = local_load_tracks(analysisDir);

inputDir  = fullfile(analysisDir,cfg.dir.TrackData);
outputDir = fullfile(analysisDir,cfg.dir.CSdata);
assert(isfolder(inputDir),'cs_refine: %s not found — run the mapper first.',inputDir);
if ~isfolder(outputDir), mkdir(outputDir); end

% Constants. SF/AmpFactor/PixSize MUST match CS_refiner_v2_wacom.m (coordinate-identical:
% they define the pixel<->um map used by compute_ref). ROI only sets the WINDOW SIZE and does
% NOT enter SF, so it can be widened freely: a bigger box stops a large / off-centre contact
% site being clipped at the density-window edge, and stored boundaries (in nm) stay valid.
PixSize=30; ROI=[-80 80]; AmpFactor=10; SF=(1/AmpFactor)*(PixSize/1000);   % ROI=+/-2.4 um window
boxUm = SF*AmpFactor*diff(ROI);   % full-box width in um (4.8), for the prompt

% Shared UI handles (built / rebuilt by ensureUI).
container=[]; gl=[]; ax=[]; msg=[]; btnAccept=[]; btnRedo=[]; btnBox=[]; waitFig=[];
btnBack=[]; btnDraw=[]; btnSkip=[]; btnDel=[]; lstRef=[]; btnAddCS=[];   % navigate/draw + delete + list + add-another
lstCell=[]; chkLbl=[]; lblCSid=[];   % cell navigator list + "show CS label" toggle + the label handle
decision=''; CSdata=[]; aborted=false;
listCSs=[]; jumpTarget=[];            % the CS being refined this cell + a click-to-jump target
cellList=[]; cellJump=[]; savedCells=[]; curCellI=[];   % cells with CSdata + a click-to-switch-cell target
pendingDrop=[];                       % CSdata indices queued for a multi-select delete from the CS list
axLoc=[]; chkLoc=[]; chkProb=[]; densCbar=[];           % whole-cell locator + localizations/probability toggles + colorbar
axRad=[];                                               % radial-concentration curve (keep/discard aid)
sldRefCon=[]; curSiteCellTot=1; lastRenderedC=NaN;      % site density-contrast slider + cell total + last site (auto-contrast on new site)
locDensCache=[]; locFovCache=27.61; locCellCache=[]; curArgs=[];   % cached whole-cell density + last renderCS args (for re-render on toggle)
mitoImg=[]; erImg=[]; ovCellCache=[]; ovMainH=gobjects(0);   % per-cell mito/ER MIP + the site-panel overlay handle
chkMitoR=[]; chkErR=[]; sldOvA=[]; btnMitoFlag=[]; ovAlpha=0.5;   % overlay toggles / opacity / mito-flag button
drawingNow=false;                     % true during a boundary draw/decide -> a display-toggle re-render must NOT cla the live ROIs
ensureUI();
% Close standalone windows by TAG on exit (self-contained; leaves an embedded
% app panel alone — that isn't tagged). onCleanup must not touch uplevel vars.
guard = onCleanup(@close_cs_windows); %#ok<NASGU>

nCell = numel(Tracks);
% Cells that have a CSdata file (raw or refined) -> the navigable cell list. The user can
% click any of them to switch (save-on-switch); an app subset re-refine pins to OnlyCell.
cellList = [];
for i0 = 1:nCell
    b0 = cellBase(Tracks(i0).file);
    if exist(fullfile(inputDir,[b0 cfg.suffix.CSdataMat]),'file')==2 || exist(fullfile(outputDir,outNameFor(b0)),'file')==2
        cellList(end+1) = i0; %#ok<AGROW>
    end
end
if ~isempty(OnlyCell), cellList = OnlyCell(:)'; end
if isempty(cellList), finishUI(0); return; end

ci = 1; cellJump = []; savedCells = [];
while ci>=1 && ci<=numel(cellList) && ~aborted
    i = cellList(ci); curCellI = i;
    base = cellBase(Tracks(i).file);
    fCS  = fullfile(inputDir,[base cfg.suffix.CSdataMat]);
    outName = outNameFor(base);
    refinedPath = fullfile(outputDir,outName);
    haveRaw = exist(fCS,'file')==2; haveRefined = exist(refinedPath,'file')==2;
    if ~haveRaw && ~haveRefined
        warning('cs_refine:noCSdata','%s: missing %s — skipping.', base,[base cfg.suffix.CSdataMat]);
        ci = ci + 1; cellJump = []; continue;
    end
    % Subset re-refine (OnlyCS): csID is PER-CELL, only touch the selected cell.
    onlyThis = OnlyCS;
    if ~isempty(OnlyCS) && ~haveRefined
        warning('cs_refine:noRefinedBase', ...
            '%s: no refined CSdata to preserve — doing a FULL refine of this cell.', base);
        onlyThis = [];
    end
    % Load from the REFINED file when preserving a subset OR when we already saved this cell
    % THIS session (so switching away and back keeps your work); else from raw.
    if (~isempty(onlyThis) || ismember(i,savedCells)) && haveRefined
        Sload = load(refinedPath,'CSdata');
    elseif haveRaw
        Sload = load(fCS,'CSdata');
    else
        Sload = load(refinedPath,'CSdata');
    end
    CSdata = Sload.CSdata;
    listCSs = local_listCSs(CSdata,MitoFlag);
    if ~isempty(onlyThis)
        listCSs = listCSs(ismember([CSdata(listCSs).csID], onlyThis));   % only the requested sites
    end
    refreshCellList();

    dropped = [];   % CSdata indices the user deleted this cell (removed from the saved file)
    jj = 1; cellJump = []; didCellJump = false;   % clear any out-of-band cellJump from a prior turn
    while jj>=1 && jj<=numel(listCSs) && ~aborted
        nav = refineOne(i, listCSs(jj), jj, numel(listCSs));
        switch nav
            case 'back',  jj = max(1, jj-1);
            case 'jump',  if ~isempty(jumpTarget) && jumpTarget>=1 && jumpTarget<=numel(listCSs), jj = jumpTarget; else, jj = jj+1; end
                          jumpTarget = [];
            case 'celljump', didCellJump = true; break;   % user clicked another CELL -> save this one, then switch
            case 'delete' % drop the current CS from the working list; it's removed from CSdata at save
                dropped(end+1) = listCSs(jj); %#ok<AGROW>
                listCSs(jj) = [];             % jj now indexes the NEXT site (or past the end -> loop ends)
            case 'multidelete' % drop every CS selected in the list (CSdata indices in pendingDrop)
                dropped = [dropped, pendingDrop(:)'];               %#ok<AGROW>
                listCSs = listCSs(~ismember(listCSs, pendingDrop)); % remove them from the working list
                pendingDrop = [];
                jj = min(max(jj,1), max(numel(listCSs),1));         % keep jj in range (loop ends if list now empty)
            otherwise,    jj = jj+1;          % 'next' / refined / box
        end
    end
    % OMIT skipped/unrefined sites (user preference): any listed CS navigated past without a
    % drawn boundary is DROPPED from the saved CSdata rather than box-filled. "Use full box"
    % (decide 'box') is the explicit way to keep a site with a boxed boundary; every SURVIVING
    % CS therefore still ends with a boundary, as the builder requires.
    for qb = 1:numel(listCSs)
        c = listCSs(qb);
        if ~isfield(CSdata,'refboundary') || isempty(CSdata(c).refboundary)
            dropped(end+1) = c; %#ok<AGROW>
        end
    end
    % Physically remove deleted sites LAST (indices above are valid until now).
    if ~isempty(dropped)
        dropped = unique(dropped(dropped>=1 & dropped<=numel(CSdata)));
        CSdata(dropped) = [];
    end

    save(refinedPath,'CSdata');
    savedCells = union(savedCells, i);
    fprintf('cs_refine: %s -> %d CS kept (%d dropped: deleted + skipped/unrefined) -> %s/%s\n', ...
        base, numel(CSdata), numel(dropped), cfg.dir.CSdata, outName);
    % Advance: honor a cell click ONLY when the inner loop actually broke via 'celljump'
    % (a cellJump set out-of-band, e.g. a list click during a render, is ignored — otherwise
    % it would silently hijack the advance and skip cells).
    if didCellJump && ~isempty(cellJump) && cellJump>=1 && cellJump<=numel(cellList), ci = cellJump; else, ci = ci + 1; end
    cellJump = [];
end
finishUI(nCell);

% ======================= nested (share workspace) =======================
    function nav = refineOne(iCell, c, cj, nJ)
        nav = 'next';
        if aborted, applyRef(c, fill_box(CSdata(c),Tracks(iCell),SF,AmpFactor,ROI)); return; end
        ctr = CSdata(c).center;
        X = Tracks(iCell).matrix(:,CSdata(c).Tracks,2) - ctr(1);
        Y = Tracks(iCell).matrix(:,CSdata(c).Tracks,3) - ctr(2);
        already = isfield(CSdata,'refboundary') && ~isempty(CSdata(c).refboundary);
        while true
            ensureUI();
            renderCS(iCell, c, cj, nJ, ctr, X, Y);
            refreshRefList(cj);                              % keep the CS list + current marker in sync
            % NAVIGATE state: draw to refine, add another site in this view, or box/skip/back
            set([btnBack btnDraw btnBox btnSkip btnAddCS],'Visible','on');
            set([btnAccept btnRedo],'Visible','off');
            enableList(true);                                % list + Delete active between sites
            drawingNow=false;                                % back in NAVIGATE -> display toggles safe again
            if ~isempty(chkLoc) && isgraphics(chkLoc), set([chkLoc chkProb],'Enable','on'); end
            if ~isempty(chkMitoR) && isgraphics(chkMitoR), set([chkMitoR chkErR],'Enable','on'); end
            if already, st='(already refined — the DASHED green outline is its existing boundary, shown for reference)'; else, st='(NOT yet refined — a big square means unrefined)'; end
            msg.Text = sprintf(['CS %d/%d.  %s  —  "Draw boundary" refines THIS site; "＋ Add another CS in this ' ...
                'view" makes a new site from an extra boundary; "Use full box" keeps the whole %.1f um box; ' ...
                '"Skip"/"◀ Back" to move; or click any site in the list.'], cj, nJ, st, boxUm);
            switch awaitButtons()
                case 'back', nav='back'; return;
                case 'skip', nav='next'; return;              % keep current (box-filled at the end if never refined)
                case 'jump', nav='jump'; return;              % clicked another site in the list
                case 'celljump', nav='celljump'; return;      % clicked another CELL -> save + switch
                case 'delete', nav='delete'; return;          % delete this site (dropped at save)
                case 'multidelete', nav='multidelete'; return; % delete the sites selected in the list
                case 'box',  applyRef(c, fill_box(CSdata(c),Tracks(iCell),SF,AmpFactor,ROI)); return;
                case 'abort',markAbort(); applyRef(c, fill_box(CSdata(c),Tracks(iCell),SF,AmpFactor,ROI)); return;
                case ''     ,if ~isgraphics(waitFig), markAbort(); end; return;   % window closed
                case 'addcs'
                    % Draw an ADDITIONAL contact site in this same (larger) view. It becomes its
                    % OWN CS (cloned cell/track context + a new csID), leaving the current site
                    % untouched. Stay on this view so several sites can be added in one FOV.
                    set([btnBack btnDraw btnBox btnSkip btnAccept btnRedo btnAddCS],'Visible','off');
                    enableList(false); drawingNow=true; lockToggles();
                    msg.Text='ADD ANOTHER CS: click its CENTRE, then press-and-drag to TRACE its boundary. Esc = cancel.';
                    drawnow;
                    r1 = safe_draw(@() drawpoint(ax));
                    if isempty(r1), if ~isgraphics(waitFig), markAbort(); return; end; continue; end
                    r2 = safe_draw(@() drawfreehand(ax));
                    if isempty(r2) || size(r2.Position,1) < 3
                        if ~isempty(r2) && isvalid(r2), delete(r2); end
                        if ~isgraphics(waitFig), markAbort(); return; end
                        continue;
                    end
                    try, r2.Position = smoothClosedPolygon(r2.Position); catch, end   % clean up the hand-drawn loop
                    newID = spawnCS(c, iCell, X, Y, r1, r2);
                    if isvalid(r1), delete(r1); end; if isvalid(r2), delete(r2); end
                    msg.Text = sprintf('Added a new contact site (id %d) in this view — draw more, or Skip/Back to move on.', newID);
                    drawnow;
                    continue;                                  % re-render: the new boundary now shows in the overlay
                case 'draw'
                    set([btnBack btnDraw btnBox btnSkip btnAccept btnRedo btnAddCS],'Visible','off');
                    enableList(false); drawingNow=true; lockToggles();   % lock list + display toggles for the WHOLE
                                                             % draw+decide window (a toggle re-render would cla the ROIs)
                    if already
                        msg.Text=['Click the refined CENTRE, then press-and-drag to TRACE the NEW boundary (freehand). ' ...
                            'The dashed green outline is the existing boundary, shown only for reference — your new trace REPLACES it. Esc = cancel.'];
                    else
                        msg.Text='Click the refined CENTRE, then press-and-drag to TRACE the boundary (freehand). Esc = cancel.';
                    end
                    drawnow;
                    roi1 = safe_draw(@() drawpoint(ax));
                    if isempty(roi1)
                        if ~isgraphics(waitFig), markAbort(); return; end
                        continue;                              % Esc -> back to the nav buttons
                    end
                    roi2 = safe_draw(@() drawfreehand(ax));
                    if isempty(roi2) || size(roi2.Position,1) < 3
                        if ~isempty(roi2) && isvalid(roi2), delete(roi2); end
                        if ~isgraphics(waitFig), markAbort(); return; end
                        continue;                              % Esc -> back to the nav buttons
                    end
                    try, roi2.Position = smoothClosedPolygon(roi2.Position); catch, end   % clean up the hand-drawn loop
                    % DECIDE state
                    set([btnBack btnAccept btnRedo btnBox],'Visible','on'); set([btnDraw btnSkip btnAddCS],'Visible','off');
                    enableList(true);                        % list + Delete active again once the draw is done
                    msg.Text='Drag the centre/boundary to adjust, then Accept.  Redo = start over.  < Back = previous site.';
                    switch awaitButtons()
                        case 'accept'
                            if isvalid(roi1) && isvalid(roi2)
                                applyRef(c, compute_ref(CSdata(c),Tracks(iCell),X,Y,roi1,roi2,SF,AmpFactor,ROI));
                            else
                                applyRef(c, fill_box(CSdata(c),Tracks(iCell),SF,AmpFactor,ROI));
                            end
                            return;
                        case 'box',  applyRef(c, fill_box(CSdata(c),Tracks(iCell),SF,AmpFactor,ROI)); return;
                        case 'back', nav='back'; return;
                        case 'jump', if isvalid(roi1), delete(roi1); end; if isvalid(roi2), delete(roi2); end; nav='jump'; return;
                        case 'celljump', if isvalid(roi1), delete(roi1); end; if isvalid(roi2), delete(roi2); end; nav='celljump'; return;
                        case 'delete', if isvalid(roi1), delete(roi1); end; if isvalid(roi2), delete(roi2); end; nav='delete'; return;
                        case 'multidelete', if isvalid(roi1), delete(roi1); end; if isvalid(roi2), delete(roi2); end; nav='multidelete'; return;
                        case 'abort',markAbort(); applyRef(c, fill_box(CSdata(c),Tracks(iCell),SF,AmpFactor,ROI)); return;
                        case ''     ,if ~isgraphics(waitFig), markAbort(); end; return;
                        case 'redo'
                            if isvalid(roi1), delete(roi1); end; if isvalid(roi2), delete(roi2); end
                            % fall through -> re-render + nav buttons
                    end
            end
        end
    end

    function renderCS(iCell, c, cj, nJ, ctr, X, Y)
        curArgs = {iCell, c, cj, nJ, ctr, X, Y};   % remember so a display toggle can re-render
        loadCellOverlay(iCell);                     % this cell's mito/ER MIP (cached per cell)
        % Raw (un-normalized) CS-local density on the same grid LocDensityFigGenerate/compute_ref
        % use. Rendered on the SAME absolute colour scale as the whole-cell picker (see below), so
        % a site's colours match the locator/picker instead of being auto-stretched per site.
        [imP, pk, nTot] = csLocalDensity(X, Y); %#ok<ASGLU>
        % ABSOLUTE colour scale, matched to the whole-cell picker (Density_*.tif capped at 255 =
        % 30*counts, i.e. 255/30 = 8.5 loc/bin), so a site is NOT auto-stretched to its own peak
        % and its colours match the locator / picker instead of shifting per site. Probability
        % divides by the CELL total (same denominator as the picker's PMF), not the member total.
        DENS_GAIN=30; capCounts = 255/DENS_GAIN;                                 % 8.5 smoothed loc/bin = advisor's absolute ceiling
        cellTot = nnz(isfinite(Tracks(iCell).matrix(:,:,2)) & isfinite(Tracks(iCell).matrix(:,:,3)));
        curSiteCellTot = max(cellTot,1);
        useProb = ~isempty(chkProb) && isgraphics(chkProb) && chkProb.Value;
        if useProb, dispIm = imP/curSiteCellTot; cbLab='localization probability / bin';
        else,       dispIm = imP;                cbLab='\approx localizations / bin'; end
        cla(ax); imagesc(ax,dispIm); colormap(ax,turbo);
        % When a NEW site loads, auto-open it at full brightness (its own peak = top of the scale)
        % so a modest site is not muted by the absolute cap; the density-contrast slider then clips
        % toward the advisor's absolute scale (right = cross-site comparable) or brighter (left).
        newSite = ~isequal(c, lastRenderedC); lastRenderedC = c;
        if newSite && ~isempty(sldRefCon) && isgraphics(sldRefCon)
            sldRefCon.Value = min(max(max(pk,eps)/capCounts, 0.05), 1);   % programmatic set -> no callback
        end
        updateRefDensCap();   % ax.CLim from the (auto or user-set) contrast, in the current units
        % YDir REVERSE to match the picker (imshow rho.tif), the locator, and CS Results —
        % all image-convention (y increases downward). The density array here is oriented the
        % same as rho.tif, so 'normal' rendered this panel vertically MIRRORED vs everything
        % else (the CS looked flipped vs the locator ring). YDir is display-only: ROI positions
        % and compute_ref's boundary map are in data coords, so the saved boundary is unchanged.
        axis(ax,'image'); set(ax,'YDir','reverse','XTick',[],'YTick',[]); hold(ax,'on');
        drawRefOverlay(ax, true, ctr);   % mito/ER structure over the zoomed site (magenta/green)
        updateMitoFlagBtn(c);            % reflect THIS site's mito classification on the button
        try
            if ~isempty(densCbar) && isgraphics(densCbar), delete(densCbar); end
            densCbar = colorbar(ax); densCbar.Label.String = cbLab;
        catch, end
        % raw localizations overlaid (same pixel frame as compute_ref: px = X/SF - AmpFactor*ROI(1))
        if ~isempty(chkLoc) && isgraphics(chkLoc) && chkLoc.Value
            px = X(:)/SF - AmpFactor*ROI(1); py = Y(:)/SF - AmpFactor*ROI(1);
            ok = isfinite(px)&isfinite(py);
            if any(ok), scatter(ax, px(ok), py(ok), 5, [1 1 1], 'filled', 'MarkerFaceAlpha',0.30,'HitTest','off'); end
        end
        % CS id label — toggleable (it can obstruct a small site). Store the handle so the
        % "show CS label" checkbox can hide/show it without a full re-render.
        lblCSid = text(ax,0.5,0.70,sprintf('CS %d',CSdata(c).csID),'Units','normalized', ...
            'Color',[1 1 0.2],'FontSize',18,'FontWeight','bold', ...
            'VerticalAlignment','middle','HorizontalAlignment','center', ...
            'BackgroundColor',[0 0 0 0.35],'Margin',3,'HitTest','off');
        if ~isempty(chkLbl) && isgraphics(chkLbl) && ~chkLbl.Value, lblCSid.Visible='off'; end
        % significance readout so you can judge keep/discard: localizations in the ±ROI view,
        % their share of the whole cell, and the peak density as a per-cell probability (PMF).
        pctCell = 100*nTot/max(curSiteCellTot,1); pkPMF = pk/max(curSiteCellTot,1);
        title(ax,sprintf('Cell %d/%d   CS %d of %d (id %d)   centre [%.2f, %.2f] um   ·   %d loc in view (%.2f%% of cell) · peak %.2g loc/bin (p=%.1e)', ...
            iCell,nCell,cj,nJ,CSdata(c).csID,ctr(1),ctr(2), nTot, pctCell, pk, pkPMF));
        % Overlay every already-refined boundary in this cell, mapped into THIS view (exact
        % inverse of compute_ref). Lets you see multiple sites drawn in one larger field of
        % view: the current site is green, the others (incl. ones just added) are white.
        if isfield(CSdata,'refboundary')
            for qq = 1:numel(CSdata)
                if isempty(CSdata(qq).refboundary) || ~isfield(CSdata,'refCenter') || isempty(CSdata(qq).refCenter), continue; end
                Pp = boundaryToPix(CSdata(qq).refboundary, CSdata(qq).refCenter, ctr);
                if isempty(Pp), continue; end
                % current site = DASHED green (its existing boundary, kept only for reference — a
                % fresh "Draw boundary" replaces it); other already-refined sites = solid white.
                if qq==c, clr=[0.2 1 0.2]; lw=2.0; ls='--'; else, clr=[1 1 1]; lw=1.3; ls='-'; end
                plot(ax,[Pp(:,1);Pp(1,1)],[Pp(:,2);Pp(1,2)],ls,'Color',clr, ...
                    'LineWidth',lw,'HitTest','off');
            end
        end
        % mark the site CENTRE (the refined refCenter if it exists, else the auto-detected pick
        % centre ctr) in the density pixel frame, so you can see it during refinement
        rcC = ctr;
        if isfield(CSdata,'refCenter') && ~isempty(CSdata(c).refCenter) ...
                && numel(CSdata(c).refCenter)==2 && all(isfinite(CSdata(c).refCenter))
            rcC = CSdata(c).refCenter;
        end
        pcx = (rcC(1)-ctr(1))/SF - AmpFactor*ROI(1); pcy = (rcC(2)-ctr(2))/SF - AmpFactor*ROI(1);
        plot(ax, pcx, pcy, '+', 'Color',[1 0 1], 'MarkerSize',13, 'LineWidth',1.6, 'HitTest','off');
        autoZoomToSignal(imP);   % a small CS is otherwise lost in the big +/-ROI box
        updateLocator(iCell, ctr);   % show where this CS sits in the whole cell
        try, refineRadial(iCell, c, ctr); catch, end   % radial concentration curve (keep/discard aid)
        drawnow;
    end

    function refineRadial(iCell, c, ctr)
        % Radial concentration curve for this site: cumulative % of the CELL's localizations
        % within radius r of the site centre vs the uniform-density expectation. A steep rise
        % above the reference = a real, tight site; hugging it = diffuse. Annotated with the
        % % of the whole cell inside the refined boundary (once the site has been refined).
        if isempty(axRad) || ~isgraphics(axRad) || iCell<1 || iCell>numel(Tracks), return; end
        if ~isfield(Tracks,'matrix') || isempty(Tracks(iCell).matrix), cla(axRad); return; end
        Xa=Tracks(iCell).matrix(:,:,2); Ya=Tracks(iCell).matrix(:,:,3); o=isfinite(Xa)&isfinite(Ya);
        haveRC = isfield(CSdata,'refCenter') && ~isempty(CSdata(c).refCenter) ...
                 && numel(CSdata(c).refCenter)==2 && all(isfinite(CSdata(c).refCenter));
        rc = ctr(:)'; if haveRC, rc = CSdata(c).refCenter(:)'; end   % refined centre when available (matches Tab 7); else the mapper centre
        pct=NaN;
        if haveRC && isfield(CSdata,'refboundary') && ~isempty(CSdata(c).refboundary)
            bx=CSdata(c).refboundary(:,1)/1000+rc(1); by=CSdata(c).refboundary(:,2)/1000+rc(2);
            nC=nnz(o); if nC>0, pct=100*nnz(inpolygon(Xa(o),Ya(o),bx,by))/nC; end
        end
        try, cs_radial_plot(axRad, Xa(o)-rc(1), Ya(o)-rc(2), 1.2, pct, haveRC); catch, end
    end

    function updateRefDensCap()      % density-contrast slider -> colour cap (CLim only, no re-render)
        if isempty(ax) || ~isgraphics(ax), return; end
        capCounts = 255/30;          % advisor absolute ceiling (8.5 loc/bin)
        clip = 1; if ~isempty(sldRefCon) && isgraphics(sldRefCon), clip = sldRefCon.Value; end
        cap = clip * capCounts;      % clip<1 brightens; clip=1 = absolute advisor scale (cross-site comparable)
        if ~isempty(chkProb) && isgraphics(chkProb) && chkProb.Value, cap = cap / max(curSiteCellTot,1); end
        if cap>0, ax.CLim = [0 cap]; end
    end

    function [imP, pk, nTot] = csLocalDensity(X, Y)
        % Raw smoothed localization-count density on the SAME grid LocDensityFigGenerate uses
        % (edges = PixSize*(ROI(1):ROI(2)) nm, [2 2] gaussian, upsampled by AmpFactor) — so the
        % display registers with compute_ref's pixel<->um map — but WITHOUT the 0..255 min/max
        % rescale, so the colour scale can be controlled (probability / fixed) instead of double-
        % normalized. Returns the display-px image, its peak, and the localization count.
        x = 1000*double(X(:)); y = 1000*double(Y(:)); ok = isfinite(x)&isfinite(y);
        edges = PixSize*(ROI(1):ROI(2));
        NumLoc = histcounts2(x(ok), y(ok), edges, edges);   % [xbin ybin]
        D = imgaussfilt(NumLoc,[2 2])';                      % [ybin xbin]
        imP = max(imresize(D, AmpFactor, 'bilinear'), 0);
        pk = max(imP(:)); nTot = nnz(ok);
    end

    function updateLocator(iCell, ctr)
        % Whole-cell density (all the cell's localizations, per-cell turbo like _rho.tif) with a
        % red ring on THIS contact site and dots on the others — so you can reorient.
        if isempty(axLoc) || ~isgraphics(axLoc), return; end
        if ~isequal(locCellCache, iCell) || isempty(locDensCache)
            Mx = Tracks(iCell).matrix(:,:,2); My = Tracks(iCell).matrix(:,:,3);
            ok = isfinite(Mx)&isfinite(My);
            fov = 27.61; try, fov = cfg.FOV_um; catch, end
            ed = linspace(0, fov, 181);
            D = histcounts2(Mx(ok), My(ok), ed, ed);         % [xbin ybin]
            locDensCache = imgaussfilt(D,1.2)';               % [ybin xbin]
            locFovCache = fov; locCellCache = iCell;
        end
        cla(axLoc);
        imagesc(axLoc, [0 locFovCache],[0 locFovCache], locDensCache); colormap(axLoc, turbo);
        axLoc.YDir='reverse'; axis(axLoc,'image'); axLoc.XTick=[]; axLoc.YTick=[]; hold(axLoc,'on');
        drawRefOverlay(axLoc, false, []);   % mito/ER structure over the whole-cell density
        for q = 1:numel(CSdata)
            cc = CSdata(q).center; if numel(cc)<2, continue; end
            plot(axLoc, cc(1), cc(2), '.','Color',[1 1 0.4],'MarkerSize',6,'HitTest','off');
        end
        if numel(ctr)>=2
            plot(axLoc, ctr(1), ctr(2), 'o','MarkerSize',13,'LineWidth',2,'MarkerEdgeColor',[1 0.15 0.15],'HitTest','off');
        end
        title(axLoc,'\circ = this CS','FontSize',9); hold(axLoc,'off');
    end

    % ---- Structure overlay (mito magenta / ER green) on both panels ----------
    function loadCellOverlay(iCell)
        % Resolve + read THIS cell's mito + ER MIP (Experiment folder + {prefix} pattern),
        % cached per cell. Same resolution as the picker / app's qcCellMitoPath.
        if isequal(ovCellCache, iCell), return; end
        ovCellCache = iCell; mitoImg=[]; erImg=[];
        if iCell<1 || iCell>numel(Tracks), return; end
        base = cellBase(Tracks(iCell).file, cfg);
        mitoImg = ov_read(ov_resolve(ovMitoDir, ovMitoPat, base));
        erImg   = ov_read(ov_resolve(ovErDir,   ovErPat,   base));
    end

    function fp = ov_resolve(dir_, pat, base)
        fp='';
        if isempty(dir_) || ~isfolder(dir_) || isempty(pat), return; end
        if isempty(ovStrip), prefix=base; else, prefix=regexprep(base,[ovStrip '$'],'','ignorecase'); end
        try
            f=dir(fullfile(dir_, strrep(pat,'{prefix}',prefix))); f=f(~[f.isdir]);
            if ~isempty(f), fp=fullfile(dir_,f(1).name); end
        catch, end
    end

    function g = ov_read(fp)
        g=[];
        if isempty(fp) || exist(fp,'file')~=2, return; end
        try
            info=imfinfo(fp); im=imread(fp,1);
            for k=2:numel(info), im=max(im,imread(fp,k)); end   % running MIP
            if size(im,3)==3, g=im2double(rgb2gray(im)); else, g=im2double(im); end
            mx=max(g(:)); if mx>0, g=g/mx; end
        catch, g=[]; end
    end

    function drawRefOverlay(axT, isMain, ctr)
        % magenta mito + green ER over axT. isMain -> map whole-cell um extent [0 fov] into the
        % site panel's pixel frame (px = um/SF - AmpFactor*ROI(1)); else the locator's um axes.
        if isempty(axT) || ~isgraphics(axT), return; end
        showM = ~isempty(chkMitoR) && isgraphics(chkMitoR) && chkMitoR.Value && ~isempty(mitoImg);
        showE = ~isempty(chkErR)   && isgraphics(chkErR)   && chkErR.Value   && ~isempty(erImg);
        if ~showM && ~showE, return; end
        if showM, ref=mitoImg; else, ref=erImg; end
        Hh=size(ref,1); Ww=size(ref,2);
        M=zeros(Hh,Ww); E=zeros(Hh,Ww);
        if showM, M=mitoImg; end
        if showE, e=erImg; if size(e,1)~=Hh||size(e,2)~=Ww, e=imresize(e,[Hh Ww]); end; E=max(min(e,1),0); end
        rgb=cat(3, M, E, M);                         % magenta (R+B)=mito, green (G)=ER
        alpha = ovAlpha * min(1, max(M,E));          % opacity * intensity
        fov = 27.61; try, fov = cfg.FOV_um; catch, end   % same um FOV as the locator density
        if isMain && numel(ctr)>=2
            xd = ([0 fov]-ctr(1))/SF - AmpFactor*ROI(1);
            yd = ([0 fov]-ctr(2))/SF - AmpFactor*ROI(1);
        else
            xd = [0 fov]; yd = [0 fov];
        end
        h = image('Parent',axT,'XData',xd,'YData',yd,'CData',rgb,'AlphaData',alpha,'HitTest','off');
        if isMain, ovMainH = h; end   % remembered so a draw can drop it (drawpoint/freehand need ONE image in the axes)
    end

    function onOvAlpha(v)
        ovAlpha = max(0,min(1,v));
        redrawCurrent();
    end

    function updateMitoFlagBtn(c)
        if isempty(btnMitoFlag) || ~isgraphics(btnMitoFlag), return; end
        if c>=1 && c<=numel(CSdata) && logical(CSdata(c).MitoFlag)
            btnMitoFlag.Text='Flag: MITO ✓'; btnMitoFlag.FontColor=[0.6 0.1 0.6];
        else
            btnMitoFlag.Text='Flag: non-mito'; btnMitoFlag.FontColor=[0.2 0.2 0.2];
        end
    end

    function toggleMitoFlag()
        if isempty(curArgs), return; end
        c = curArgs{2};
        if c<1 || c>numel(CSdata), return; end
        CSdata(c).MitoFlag = double(~logical(CSdata(c).MitoFlag));   % flip; saved when the cell writes
        updateMitoFlagBtn(c);
        if logical(CSdata(c).MitoFlag), lab='MITO'; else, lab='non-mito'; end
        if ~isempty(msg) && isgraphics(msg)
            msg.Text = sprintf('CS %d set to %s (saved with this cell).', CSdata(c).csID, lab);
        end
    end

    function redrawCurrent()
        % re-render the current CS after a display toggle. NEVER while a boundary is being drawn
        % or decided: renderCS starts with cla(ax), which would delete the live drawpoint/
        % drawfreehand ROIs and silently discard the user's boundary.
        if drawingNow || isempty(curArgs), return; end
        try, renderCS(curArgs{:}); catch, end
    end

    function autoZoomToSignal(imG)
        % Zoom the axes to the density signal (+ generous margin so there is room to trace
        % the boundary), so a small contact site fills the view instead of sitting as a tiny
        % blob in the full box. "restoreview" on the toolbar / scroll-zoom still adjust freely.
        if isempty(ax) || ~isgraphics(ax), return; end
        sig = double(imG); if ndims(sig)==3, sig = sum(sig,3); end
        [Hh,Ww] = size(sig); lo = min(sig(:)); hi = max(sig(:));
        if hi<=lo, return; end
        [ys,xs] = find(sig > lo + 0.04*(hi-lo));
        if numel(xs) < 4, return; end
        cx = (min(xs)+max(xs))/2; cy = (min(ys)+max(ys))/2;
        half = max(max(xs)-min(xs), max(ys)-min(ys))/2;
        half = max(half*1.8, min(Ww,Hh)*0.12);       % >=1.8x the blob, and >=12% of the frame
        half = min(half, max(Ww,Hh)/2);
        try
            xlim(ax, [max(0.5,cx-half), min(Ww+0.5,cx+half)]);
            ylim(ax, [max(0.5,cy-half), min(Hh+0.5,cy+half)]);
        catch
        end
    end

    function onToggleLbl()
        if ~isempty(lblCSid) && isgraphics(lblCSid)
            if chkLbl.Value, lblCSid.Visible='on'; else, lblCSid.Visible='off'; end
        end
    end

    function P = boundaryToPix(rb, rc, ctr)
        % Map a refined boundary (rb = nm rel refCenter rc, µm) into the CURRENT view's
        % pixel coords (view centred at ctr µm). Exact inverse of compute_ref's forward map.
        P = [];
        if isempty(rb) || numel(rc)<2 || numel(ctr)<2, return; end
        P = [ (rb(:,1)/1000 + (rc(1)-ctr(1)))/SF - AmpFactor*ROI(1), ...
              (rb(:,2)/1000 + (rc(2)-ctr(2)))/SF - AmpFactor*ROI(1) ];
    end

    function newID = spawnCS(srcC, iCell, X, Y, r1, r2)
        % Create a NEW contact site from an extra boundary drawn in srcC's view: clone srcC's
        % mapper context (cell/tracks/box) with a fresh per-cell csID, then attach the refined
        % fields from the drawn centre+boundary. Appended to CSdata + the working list.
        ref = compute_ref(CSdata(srcC), Tracks(iCell), X, Y, r1, r2, SF, AmpFactor, ROI);
        ids = [CSdata.csID]; newID = max(ids(isfinite(ids))) + 1;
        CSdata(end+1) = CSdata(srcC);          % clone (existing element -> identical fields, no dissimilar-struct error)
        newIdx = numel(CSdata);
        CSdata(newIdx).csID = newID;
        applyRef(newIdx, ref);                 % refCenter/refboundary/refLocIDs/... (field-by-field, auto-adds fields)
        listCSs(end+1) = newIdx;               % track it (already refined; appended after the originals)
    end

    function markAbort()
        if ~aborted
            aborted = true;
            fprintf(['cs_refine: window closed — remaining contact sites kept as unrefined ' ...
                'boxes. Re-run the ''refiner'' stage to refine them.\n']);
        end
    end

    function applyRef(c, ref)
        % Field-by-field assignment (auto-adds the new fields across the whole
        % CSdata array; whole-struct assignment would error on dissimilar fields).
        fn = fieldnames(ref);
        for k = 1:numel(fn), CSdata(c).(fn{k}) = ref.(fn{k}); end
    end

    function ensureUI()
        if ~isempty(gl) && isgraphics(gl), return; end     % UI already built and alive
        if isempty(inParent) || ~isgraphics(inParent)      % standalone window
            container = uifigure('Name','CS refine (mouse)','Position',[200 120 760 820], ...
                'Tag','cs_refine_window');
        else                                               % embed into the app panel/tab
            container = inParent; delete(allchild(container));
        end
        waitFig = ancestor(container,'matlab.ui.Figure');
        gl  = uigridlayout(container,[1 3],'ColumnWidth',{200,'1x',300}, ...
            'Padding',[8 8 8 8],'ColumnSpacing',8);
        % LEFT: cell navigator (jump between cells) + clickable CS list + Delete + label toggle
        lp = uigridlayout(gl,[6 1],'RowHeight',{16,'0.8x',16,'1x',22,28},'RowSpacing',4,'Padding',[0 0 0 0]);
        lp.Layout.Row=1; lp.Layout.Column=1;
        uilabel(lp,'Text','Cells (click to switch)','FontWeight','bold','FontSize',11);
        lstCell = uilistbox(lp,'Items',{},'ValueChangedFcn',@(s,e) onCellListJump());
        uilabel(lp,'Text','Contact sites (click to refine)','FontWeight','bold','FontSize',11);
        lstRef = uilistbox(lp,'Items',{},'Multiselect','on', ...
            'Tooltip','Click a site to refine it; Ctrl/Shift-click several, then "Delete selected" to remove them all', ...
            'ValueChangedFcn',@(s,e) onListJump());
        chkLbl = uicheckbox(lp,'Text','show CS label','Value',true, ...
            'Tooltip','Hide the big "CS n" label when it obstructs a small site', ...
            'ValueChangedFcn',@(s,e) onToggleLbl());
        btnDel = uibutton(lp,'Text','🗑 Delete selected','FontColor',[0.75 0.1 0.1], ...
            'Tooltip','Drop the contact site(s) selected in the list (Ctrl/Shift for several) so the builder omits them', ...
            'ButtonPushedFcn',@(s,e) onDeleteCS());
        % RIGHT: CS-local density + the navigate / draw controls
        rp = uigridlayout(gl,[2 1],'RowHeight',{'1x',152},'RowSpacing',6,'Padding',[0 0 0 0]);
        rp.Layout.Row=1; rp.Layout.Column=2;
        ax  = uiaxes(rp); ax.Layout.Row=1; ax.Layout.Column=1;
        % RIGHT: whole-cell locator (where is this CS in the cell) + display toggles
        rpR = uigridlayout(gl,[10 1],'RowHeight',{16,'1x',16,'0.9x',22,22,24,22,24,30},'RowSpacing',4,'Padding',[0 0 0 0]);
        rpR.Layout.Row=1; rpR.Layout.Column=3;
        uilabel(rpR,'Text','Whole-cell locator','FontWeight','bold','FontSize',11);
        axLoc = uiaxes(rpR); box(axLoc,'on'); axLoc.XTick=[]; axLoc.YTick=[]; disableDefaultInteractivity(axLoc);
        uilabel(rpR,'Text','Local density (keep/discard)','FontWeight','bold','FontSize',11);
        axRad = uiaxes(rpR); box(axRad,'on'); axRad.FontSize=8; disableDefaultInteractivity(axRad);   % cumulative % of loc vs radius from centre
        chkLoc  = uicheckbox(rpR,'Text','show localizations','Value',false, ...
            'Tooltip','Overlay the raw localization points on the density','ValueChangedFcn',@(s,e) redrawCurrent());
        chkProb = uicheckbox(rpR,'Text','probability scale','Value',true, ...
            'Tooltip','Colorbar in normalized-probability units (localizations per bin / total) instead of raw counts', ...
            'ValueChangedFcn',@(s,e) redrawCurrent());
        % density contrast: each site opens auto-scaled to its own peak (full brightness); drag
        % right toward the absolute advisor scale (cross-site comparable), left to brighten further
        scg = uigridlayout(rpR,[1 2],'ColumnWidth',{80,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',4);
        uilabel(scg,'Text','density contrast','FontSize',10);
        sldRefCon = uislider(scg,'Limits',[0.05 1],'Value',1,'MajorTicks',[],'MinorTicks',[], ...
            'Tooltip','Clip the density colour cap. Each site opens auto-scaled to its own peak; drag RIGHT toward the absolute advisor scale (8.5 loc/bin, cross-site comparable), LEFT to brighten.', ...
            'ValueChangedFcn',@(s,e) updateRefDensCap());
        % structure overlay (mito magenta / ER green) on BOTH the zoomed site and the locator
        ovg = uigridlayout(rpR,[1 2],'ColumnWidth',{'1x','1x'},'Padding',[0 0 0 0],'ColumnSpacing',4);
        chkMitoR = uicheckbox(ovg,'Text','mito','Value',true, ...
            'Tooltip','Overlay the mitochondria MIP (magenta) for orientation','ValueChangedFcn',@(s,e) redrawCurrent());
        chkErR   = uicheckbox(ovg,'Text','ER','Value',false, ...
            'Tooltip','Overlay the ER MIP (green) for orientation','ValueChangedFcn',@(s,e) redrawCurrent());
        ovag = uigridlayout(rpR,[1 2],'ColumnWidth',{62,'1x'},'Padding',[0 0 0 0],'ColumnSpacing',4);
        uilabel(ovag,'Text','overlay α','FontSize',10);
        sldOvA = uislider(ovag,'Limits',[0 1],'Value',0.5,'MajorTicks',[],'MinorTicks',[], ...
            'Tooltip','Structure-overlay opacity (like Tab 7 density α)','ValueChangedFcn',@(s,e) onOvAlpha(s.Value));
        btnMitoFlag = uibutton(rpR,'Text','Flag: —','FontSize',11, ...
            'Tooltip','Toggle THIS contact site''s mito / non-mito classification (saved with the cell)', ...
            'ButtonPushedFcn',@(s,e) toggleMitoFlag());
        % explicit zoom controls + scroll-wheel zoom so the CS can be magnified to trace its
        % boundary closely (drawfreehand still captures the press-drag once "Draw boundary" is on)
        axtoolbar(ax,{'zoomin','zoomout','pan','restoreview'});
        try, ax.Interactions = [zoomInteraction panInteraction]; catch, end
        cp  = uigridlayout(rp,[4 3],'RowHeight',{'1x',30,30,30},'RowSpacing',4, ...
            'Padding',[0 0 0 0]); cp.Layout.Row=2;
        msg = uilabel(cp,'Text','','WordWrap','on'); msg.Layout.Row=1; msg.Layout.Column=[1 3];
        % Row 2 = navigate between sites; Row 3 = draw decision; Row 4 = add another site here.
        btnBack = uibutton(cp,'Text','◀ Back','ButtonPushedFcn',@(s,e) decide('back'));
        btnBack.Layout.Row=2; btnBack.Layout.Column=1;
        btnDraw = uibutton(cp,'Text','✎ Draw boundary','FontWeight','bold', ...
            'BackgroundColor',[0.20 0.45 0.70],'FontColor','w','ButtonPushedFcn',@(s,e) decide('draw'));
        btnDraw.Layout.Row=2; btnDraw.Layout.Column=2;
        btnSkip = uibutton(cp,'Text','Skip ▶','ButtonPushedFcn',@(s,e) decide('skip'));
        btnSkip.Layout.Row=2; btnSkip.Layout.Column=3;
        btnAccept = uibutton(cp,'Text','✓ Accept','FontWeight','bold', ...
            'BackgroundColor',[0.18 0.55 0.30],'FontColor','w','ButtonPushedFcn',@(s,e) decide('accept'));
        btnAccept.Layout.Row=3; btnAccept.Layout.Column=1;
        btnRedo = uibutton(cp,'Text','↻ Redo','ButtonPushedFcn',@(s,e) decide('redo'));
        btnRedo.Layout.Row=3; btnRedo.Layout.Column=2;
        btnBox = uibutton(cp,'Text','Use full box','ButtonPushedFcn',@(s,e) decide('box'));
        btnBox.Layout.Row=3; btnBox.Layout.Column=3;
        % Draw an EXTRA contact site in the same (larger) field of view -> its own CS.
        btnAddCS = uibutton(cp,'Text','＋ Add another CS in this view','FontWeight','bold', ...
            'BackgroundColor',[0.40 0.30 0.55],'FontColor','w','ButtonPushedFcn',@(s,e) decide('addcs'));
        btnAddCS.Layout.Row=4; btnAddCS.Layout.Column=[1 3];
        set([btnBack btnDraw btnSkip btnAccept btnRedo btnBox btnAddCS],'Visible','off');
    end

    function decide(a)
        decision = a;
        if ~isempty(waitFig) && isgraphics(waitFig), uiresume(waitFig); end
    end

    function enableList(on)
        % enable/disable the cell + CS lists + Delete button (locked during a boundary draw so
        % a mid-draw click can't be silently dropped or cancel the draw).
        v = [lstRef btnDel lstCell]; v = v(isgraphics(v));   % list + Delete (display toggles handled by lockToggles)
        if isempty(v), return; end
        if on, set(v,'Enable','on'); else, set(v,'Enable','off'); end
    end

    function lockToggles()
        % disable the display toggles for the whole draw+decide window (re-enabled at NAVIGATE top)
        if ~isempty(chkLoc) && isgraphics(chkLoc), set([chkLoc chkProb],'Enable','off'); end
        if ~isempty(chkMitoR) && isgraphics(chkMitoR), set([chkMitoR chkErR],'Enable','off'); end
        % drawpoint/drawfreehand call getimage(ax) internally, which ERRORS when the axes holds
        % more than one image — so drop the structure overlay before the draw (it returns on the
        % next render). Orientation happens at NAVIGATE, when the overlay is shown.
        if ~isempty(ovMainH) && isgraphics(ovMainH), delete(ovMainH); end; ovMainH=gobjects(0);
    end

    function onListJump()
        % single-click a site -> jump to it (index into listCSs). A multi-selection (Ctrl/Shift)
        % is for "Delete selected", not navigation, so don't jump when more than one is selected.
        if isempty(lstRef) || ~isgraphics(lstRef) || isempty(listCSs), return; end
        idx = lstRef.ValueIndex;
        if numel(idx)~=1 || idx<1 || idx>numel(listCSs), return; end
        jumpTarget = idx;
        decide('jump');
    end

    function nm = outNameFor(b)          % refined-file name for a cell base (respects MitoFlag)
        nm = [b cfg.suffix.CSdataMat];
        if     MitoFlag==1,  nm = [b '_mito_CSdata.mat'];
        elseif MitoFlag==-1, nm = [b '_other_CSdata.mat'];
        end
    end

    function refreshCellList()          % populate the cell navigator (✓ = saved this session, ◀ = current)
        if isempty(lstCell) || ~isgraphics(lstCell), return; end
        items = cell(1,numel(cellList));
        for k = 1:numel(cellList)
            b = cellBase(Tracks(cellList(k)).file);
            tag=''; if ismember(cellList(k),savedCells), tag=' ✓'; end
            cur=''; if cellList(k)==curCellI, cur='  ◀'; end
            items{k} = sprintf('%d · %s%s%s', cellList(k), b, tag, cur);
        end
        lstCell.Items = items;
        ix = find(cellList==curCellI,1);
        if ~isempty(ix), try lstCell.ValueIndex = ix; catch, end, end
    end

    function onCellListJump()           % clicked a cell -> save the current one, switch to it
        if isempty(lstCell) || ~isgraphics(lstCell) || isempty(cellList), return; end
        idx = lstCell.ValueIndex;
        if isempty(idx) || idx<1 || idx>numel(cellList), return; end
        if cellList(idx)==curCellI, return; end   % already on this cell
        cellJump = idx;
        decide('celljump');
    end

    function onDeleteCS()
        % delete ALL sites selected in the list (Ctrl/Shift for several) via the nav loop.
        if isempty(waitFig) || ~isgraphics(waitFig) || isempty(lstRef) || ~isgraphics(lstRef), return; end
        idxSel = lstRef.ValueIndex; idxSel = idxSel(idxSel>=1 & idxSel<=numel(listCSs));
        if isempty(idxSel)
            if ~isempty(msg) && isgraphics(msg)
                msg.Text = 'Select one or more contact sites in the list to delete (Ctrl/Shift-click for several).';
            end
            return;
        end
        sel = uiconfirm(waitFig, sprintf(['Delete %d selected contact site(s)? They will be dropped ' ...
            'from this cell so the builder omits them.'], numel(idxSel)), 'Delete contact sites', ...
            'Options',{'Delete','Cancel'}, 'DefaultOption',2, 'CancelOption',2, 'Icon','warning');
        if ~strcmp(sel,'Delete'), return; end
        pendingDrop = listCSs(idxSel);   % CSdata indices to drop (resolved by the nav loop)
        decide('multidelete');
    end

    function refreshRefList(cj)
        % populate the CS list with each site's number/id, a ✓ if already refined, and a
        % marker on the current one; select the current row (programmatic -> no callback).
        if isempty(lstRef) || ~isgraphics(lstRef), return; end
        items = cell(1,numel(listCSs));
        for qi = 1:numel(listCSs)
            c = listCSs(qi); tag = '';
            if isfield(CSdata,'refboundary') && ~isempty(CSdata(c).refboundary)
                % a 4-corner boundary is a box-fill (unrefined default), not a hand-drawn one
                if size(CSdata(c).refboundary,1) <= 4, tag = ' □box'; else, tag = ' ✓'; end
            end
            cur = ''; if qi==cj, cur = '  ◀'; end
            items{qi} = sprintf('CS %d  (id %d)%s%s', qi, CSdata(c).csID, tag, cur);
        end
        lstRef.Items = items;
        if cj>=1 && cj<=numel(items), try lstRef.ValueIndex = cj; catch, end, end
    end

    function a = awaitButtons()
        % Wait for any of the refiner buttons (visibility is set by the caller).
        decision = '';
        uiwait(waitFig);
        a = decision;
        if isempty(a) && ~isgraphics(waitFig), a = 'abort'; end   % window closed
        if ~isempty(btnBack) && isgraphics(btnBack)
            set([btnBack btnDraw btnSkip btnAccept btnRedo btnBox btnAddCS],'Visible','off');
        end
    end

    function finishUI(n)
        % Standalone window is closed by the onCleanup tag-teardown. For an
        % embedded panel, replace the interactive UI with a completion note.
        if ~isempty(inParent) && isgraphics(inParent)
            delete(allchild(inParent));
            g = uigridlayout(inParent,[1 1],'Padding',[16 16 16 16]);
            uilabel(g,'Text',sprintf('Contact-site refinement complete (%d cell(s)).',n), ...
                'WordWrap','on','FontSize',13);
        end
    end
end

% ============================ local functions ============================
function ref = compute_ref(CSj, Tr, X, Y, roi1, roi2, SF, AmpFactor, ROI)
% Refined fields from the drawn centre (roi1) + boundary (roi2), byte-identical
% to CS_refiner_v2_wacom.m L122-177.
ctr = CSj.center;
ref.refCenter = [ SF*(roi1.Position(1)+AmpFactor*ROI(1))+ctr(1), ...
                  SF*(roi1.Position(2)+AmpFactor*ROI(1))+ctr(2) ];        % L122-123
Xb = 1000*SF*(roi2.Position(:,1)+AmpFactor*ROI(1));
Xd = 1000*(ref.refCenter(1)-ctr(1));
Yb = 1000*SF*(roi2.Position(:,2)+AmpFactor*ROI(1));
Yd = 1000*(ref.refCenter(2)-ctr(2));
ref.refboundary = [Xb-Xd, Yb-Yd];                                         % L134-138 (nm rel refCenter)

Aprime = X - SF*AmpFactor*ROI(1); Aprime(~isfinite(Aprime)) = 0;          % L146-149
Bprime = Y - SF*AmpFactor*ROI(1); Bprime(~isfinite(Bprime)) = 0;
Subset = inROI(roi2, (1/SF)*Aprime(:), (1/SF)*Bprime(:));                 % L153
ref.CSLocIDs = find(Subset);                                              % L156 (CS-local)
[m, n_CS] = find(reshape(Subset,size(Aprime)));                          % L159
m = m(:);                                                                % force Nx1 (survives empty Subset / M==1)
Dummy   = zeros(size(Tr.matrix(:,:,1)));                                  % L163 (full M x N)
n_index = CSj.Tracks(n_CS); n_index = n_index(:);                        % local col -> global track, forced Nx1
CSind = sub2ind(size(Dummy), m, n_index);                                % L168 (empty -> empty, no error)
ref.refLocIDs  = CSind;                                                   % L169 (global M x N linear idx)
Dummy(CSind) = 1; ref.IDmatrixMN = Dummy;                                 % L170-171

% Ellipse fit of the drawn boundary (wacom L173-177), hardened: a polygon that
% touches the view border makes imclearborder empty the mask, and regionprops
% would then return an empty struct -> ConditionAccumulator reads
% CS.EllipseFit.MajorAxisLength and crashes. Keep the mask non-empty and always
% return a 1x1 struct with the four fields.
bw  = createMask(roi2);                                                   % L173
bwc = imclearborder(bw);
if any(bwc(:)), bw = bwc; end            % drop border-clearing only if it leaves something
if any(bw(:)),  bw = bwareafilt(bw,1); end
ref.EllipseFit = regionprops(bw,{'Centroid','Orientation', ...
    'MajorAxisLength','MinorAxisLength'});                                % L176-177
if isempty(ref.EllipseFit)               % fully degenerate mask -> synthesize from the polygon bbox
    ref.EllipseFit = local_ellipse_from_poly(roi2.Position);
end
end

% -------------------------------------------------------------------------
function s = local_ellipse_from_poly(P)
% Minimal valid EllipseFit (Centroid/Orientation/Major/Minor) from a polygon's
% bounding box, for the rare degenerate mask where regionprops finds nothing.
xr = [min(P(:,1)) max(P(:,1))]; yr = [min(P(:,2)) max(P(:,2))];
s.Centroid        = [mean(xr) mean(yr)];
s.Orientation     = 0;
s.MajorAxisLength = max(diff(xr),diff(yr));
s.MinorAxisLength = min(diff(xr),diff(yr));
end

% -------------------------------------------------------------------------
function ref = fill_box(CSj, Tr, SF, AmpFactor, ROI)
% Unrefined default (Esc / "Use full box"): the whole +/-ROI box is the CS.
% refCenter = original centre, boundary = full box, refLocIDs = every mapper loc
% in the box (so the builder's neighborIDs = setdiff(LocIDs,refLocIDs) is empty).
ctr  = CSj.center;
ref.refCenter = ctr;
half = 1000*SF*AmpFactor*abs(ROI(1));                       % nm half-box (derived from ROI: 2400 nm at +/-80)
ref.refboundary = [-half -half; half -half; half half; -half half];
ref.CSLocIDs = [];
Dummy  = zeros(size(Tr.matrix(:,:,1)));
locID  = CSj.LocIDs(:); locID = locID(locID>=1 & locID<=numel(Dummy));
Dummy(locID) = 1;
ref.refLocIDs  = locID;
ref.IDmatrixMN = Dummy;
bw = true(round(AmpFactor*abs(diff(ROI))));                 % full-box mask -> valid ellipse
ref.EllipseFit = regionprops(bw,{'Centroid','Orientation', ...
    'MajorAxisLength','MinorAxisLength'});
end

% -------------------------------------------------------------------------
function Q = smoothClosedPolygon(P)
% Gentle CIRCULAR moving-average smoothing of a closed hand-drawn boundary, so the loop
% is clean and smoothly closed even if the freehand trace was jittery or didn't meet its
% start neatly (the ROI is closed implicitly, so wrapping the window handles the seam).
Q = P;
if isempty(P) || size(P,1) < 8, return; end
n = size(P,1);
k = min(max(round(0.05*n),2), 12);        % half-window ~5% of the perimeter, capped
Q = zeros(n,2);
for j = 1:n
    w = mod((j-k:j+k)-1, n) + 1;           % circular window indices (wrap the seam)
    Q(j,:) = mean(P(w,:),1);
end
end

% -------------------------------------------------------------------------
function roi = safe_draw(drawFcn)
% Run an ROI draw fcn (drawpoint/drawfreehand); return [] if the user cancels.
roi = [];
try
    r = drawFcn();
catch
    return;                       % figure closed mid-draw, etc.
end
if ~isvalid(r), return; end
if isempty(r.Position), delete(r); return; end
roi = r;
end

% -------------------------------------------------------------------------
function listCSs = local_listCSs(CSdata, MitoFlag)
if isempty(CSdata), listCSs = []; return; end
MitoFlagList = false(1,numel(CSdata));
for k = 1:numel(CSdata), MitoFlagList(k) = logical(CSdata(k).MitoFlag); end
switch MitoFlag
    case 1,   listCSs = find(MitoFlagList);
    case -1,  listCSs = find(~MitoFlagList);
    case 0,   listCSs = 1:numel(CSdata);
    otherwise, error('cs_refine:MitoFlag','MitoFlag must be 0, 1, or -1.');
end
end

% -------------------------------------------------------------------------
function Tracks = local_load_tracks(analysisDir)
% Tracks_final.mat first (it carries the MitoCSindex the legacy stages add), then the ACTIVE build —
% which may be a named one — before the fixed legacy names.
cands = {'Tracks_final.mat'};
if exist('cs_active_trackstruct','file')==2
    try, a = cs_active_trackstruct(analysisDir); if ~isempty(a), [~,n,e] = fileparts(a); cands{end+1} = [n e]; end, catch, end
end
cands = [cands, {'Tracks.mat','TrackStruct.mat'}];
for k = 1:numel(cands)
    p = fullfile(analysisDir,cands{k});
    if isfile(p)
        L = load(p);
        if isfield(L,'Tracks'),      Tracks = L.Tracks;      return; end
        if isfield(L,'TrackStruct'), Tracks = L.TrackStruct; return; end
    end
end
error('cs_refine:noTracks', ...
    'No Tracks_final.mat / Tracks.mat / TrackStruct.mat in %s.', analysisDir);
end

% -------------------------------------------------------------------------
function close_cs_windows()
% Self-contained teardown for onCleanup: close any standalone cs_refine window
% by tag (an embedded app panel is untagged and left untouched).
h = findall(groot,'Type','figure','Tag','cs_refine_window');
if ~isempty(h), close(h); end
end
