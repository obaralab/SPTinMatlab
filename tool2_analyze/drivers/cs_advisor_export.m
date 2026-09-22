function R = cs_advisor_export(anaDir, opts)
%CS_ADVISOR_EXPORT  One folder to hand to someone else: every cell's density (.mat + .tif) together
%with its contact sites, all built from the SAME filtered localizations the picker and Refine show.
%
%   R = cs_advisor_export(anaDir, opts)
%
% opts  .name            folder name under analysis/exports/ (default export_<yyyymmdd-HHMMSS>)
%       .outDir          full path instead of a name. Either way the folder must NOT already hold
%                        files: what you sent stays what you sent, and nothing is overwritten.
%       .cells           cellstr of cell base names to include (default: every cell with saved sites)
%       .fovUm .binNm    project fallbacks for a cell that carries no calibration of its own
%       .includeDeleted  false — sites deleted on the Refine tab are left out and counted
%
% R     .outDir .nCells .nSites .nDeleted .nRejectedTracks .cells .skipped (cellstr, with reasons)
%
% WHAT GOES IN
%   Density_<cell>.mat           imG = 30 * smoothed counts            } the external ContactSites
%   Density_<cell>.tif           uint16(imG)                            } code's own format and grid
%   Densities/<cell>_rho.tif     turbo rendering of the same           }  (cs_advisor_density)
%   Density_<cell>_windows.tif   the same density per picker WINDOW, one page per window — sites are
%                                picked on window densities, and a window-2 site need not be visible
%                                on the whole-movie map
%   csIDs/<cell>_CSsites.txt     the picks, in the format the external mapper reads
%   Both site tables carry the NORMALIZED metrics as well as the raw counts, from the same kernel
%   the mapper uses (csDensMetricOne): prob_mass (localizations inside / the cell's localizations in
%   that window) and enrichment (the site's density / that cell's own background). Raw counts are
%   not comparable between cells - a cell with twice the labelling has twice the counts - and these
%   are what make them comparable.
%
%   sites/<cell>_contactsites.csv + .mat   the CONTACT SITES as the picker found them: every pick
%                                (including ones later deleted on Refine, flagged), the picker's own
%                                detection statistics, and the AUTOMATIC outline around it with the
%                                localizations and tracks inside
%   sites/<cell>_refinedsites.csv + .mat   the REFINED SITES: every site as it now stands, each saved
%                                Refine edit applied and deleted sites left out, with the localizations
%                                and tracks inside the refined outline
%   (the .mat files add the outline polygons and each site's member-track list)
%   tracks/<cell>_tracks.mat + _localizations.csv   the filtered tracks themselves - frame, x, y per
%                                localization - so every number above can be recomputed from the export
%   contactsites_all.csv, refinedsites_all.csv   every cell in one table each
%   analyse_export_one_cell.m    base-MATLAB script: loads one cell at a time, recounts every site
%                                from tracks/ and checks the tables, plots the outlines
%   advisor_format/<condition>/  the same sites in the layout of the lab's published ContactSites
%                                dataset (CS_final_v3.mat, <cond>_Tracks_finalv3.mat, <cond>_EC.mat,
%                                BindingInfo.mat and the four spreadsheets) - see cs_advisor_format
%
% opts.conditions      containers.Map cell name -> condition (Experiment tab). One advisor_format
%                      set per condition; with none assigned, one set named after the export.
% opts.advisorFormat   (true) write advisor_format/
% opts.advisorBoxUm    (1.024) neighbourhood square for advisor_format, um
%   README.txt                   what all of the above is, and the coordinate conventions
%
% THE LOCALIZATIONS are the build's tracked matrix — the tracks that survived filtering and
% curation — with the tracks hand-rejected on the QC tab removed. Not the full detection cloud: that
% includes every single-frame detection that never linked into a track, and the picker never used it.
%
% THE FOOTPRINTS are cs_footprints_resolve's: the auto footprint with every SAVED Refine edit
% applied. An unsaved edit on the Refine tab is not in the files — the caller says so.

if nargin < 2 || ~isstruct(opts), opts = struct(); end
anaDir = regexprep(char(anaDir), '[\\/]+$', '');
projectDir = fileparts(anaDir);
stamp = char(datetime('now','Format','yyyyMMdd-HHmmss'));
outDir = getf(opts, 'outDir', '');
if isempty(outDir)
    name = getf(opts, 'name', '');
    root = cs_ana_path(anaDir, 'export');
    if isempty(name)
        % No name given: a fresh stamped folder. Two exports inside the same second would otherwise
        % share one.
        outDir = fullfile(root, ['export_' stamp]);
        q = 1;
        while isfolder(outDir), q = q + 1; outDir = fullfile(root, sprintf('export_%s_%d', stamp, q)); end
    else
        outDir = fullfile(root, cs_advisor_export_name(name));
    end
end
% NEVER write into a folder that already holds files. A re-export under the same name would replace
% some files and leave others from the earlier run — a cell dropped since then would still be there,
% looking current. The caller picks a new name instead.
if isfolder(outDir)
    d = dir(outDir); d = d(~ismember({d.name}, {'.','..'}));
    assert(isempty(d), 'cs_advisor_export:exists', ...
        'The export folder %s already exists and is not empty — choose another name.', outDir);
end
incDel = getf(opts, 'includeDeleted', false);

R = struct('outDir','','nCells',0,'nSites',0,'nContact',0,'nRefinedEdited',0,'nDeleted',0, ...
           'nRejectedTracks',0,'cells',{{}},'skipped',{{}});

R.outDir = outDir;
tsPath = cs_active_trackstruct(anaDir);
assert(~isempty(tsPath) && isfile(tsPath), 'cs_advisor_export:noTrackStruct', 'No TrackStruct build in %s', anaDir);
S = load(tsPath); fn = fieldnames(S); Tracks = S.(fn{1});
[~, tsName] = fileparts(tsPath);
ex = []; try, ex = cs_track_exclusions('load', projectDir); catch, end
R.nRejectedTracks = cs_track_exclusions('count', ex);
Tb = cs_track_exclusions('blank', ex, Tracks);

[F, finfo, Fauto] = cs_footprints_resolve(anaDir);
boxUm = getf(opts, 'neighbourBoxUm', []); if isempty(boxUm), boxUm = cs_neighbour_box(anaDir); end
TS = cs_tessellate('load', anaDir);          % per-localization diffusion map, when it has been run
if isempty(F), R.skipped = {'no saved contact sites in csIDs/'}; return; end
bases = unique({F.file}, 'stable');
if isfield(opts,'cells') && ~isempty(opts.cells)
    want = cellstr(opts.cells);
    for q = 1:numel(want)
        if ~any(strcmp(bases, want{q})), R.skipped{end+1} = sprintf('%s: no saved sites', want{q}); end
    end
    bases = bases(ismember(bases, want));
end
if isempty(bases), return; end

for d = {outDir, fullfile(outDir,'Densities'), fullfile(outDir,'csIDs'), fullfile(outDir,'sites'), fullfile(outDir,'tracks')}
    if ~isfolder(d{1}), mkdir(d{1}); end
end

allA = []; allR = [];
advCells = struct('base', {}, 'T', {}, 'sites', {}, 'cond', {}, 'dims', {}, 'Deff', {}, 'Tess', {});
for b = 1:numel(bases)
    base = bases{b};
    Fi = F(strcmp({F.file}, base));
    k = Fi(1).cellIndex;
    T = Tb(k);
    [fovUm, binNm] = cellCalib(T, opts);
    if ~(fovUm > 0) || ~(binNm > 0)
        R.skipped{end+1} = sprintf('%s: no field of view / bin size to build a density with', base); continue
    end
    M = T.matrix; Fr = M(:,:,1); A = M(:,:,2); B = M(:,:,3);
    okxy = isfinite(A) & isfinite(B);
    [Dcell, TessCell] = cs_tessellate('cell', TS, base, size(A));   % NaN when never run
    DtCell = [];
    try, DtCell = Tracks(k).Dt; catch, end
    if ~isequal(size(DtCell), size(A)), DtCell = nan(size(A)); end

    % ---- the tracks themselves ---------------------------------------------------------------------
    % Without them the export is pictures and summaries: nothing in it could be recounted. Only
    % tracks with positions go out (hand-rejected ones are blanked and so dropped here), numbered
    % 1..nTracks in export order; build_col keeps the column each came from. member_tracks on every
    % site uses the EXPORT numbers, so it indexes straight into these arrays.
    keepCols = find(any(okxy, 1));
    expNum = zeros(1, size(M,2)); expNum(keepCols) = 1:numel(keepCols);
    dtS = NaN; if isfield(T,'frameInterval') && ~isempty(T.frameInterval), dtS = double(T.frameInterval); end
    tracks = struct('file', base, 'frameInterval_s', dtS, 'fov_um', fovUm, 'bin_nm', binNm, ...
        'frame', Fr(:, keepCols), 'x_um', A(:, keepCols), 'y_um', B(:, keepCols), ...
        'build_col', keepCols, 'n_loc', sum(okxy(:, keepCols), 1), ...
        'note', ['Column j = track j (the number in member_tracks). Rows are localizations in time ' ...
                 'order, NaN-padded. frame is 0-based. Hand-rejected tracks are not included.']); %#ok<NASGU>
    save(fullfile(outDir, 'tracks', [base '_tracks.mat']), 'tracks');
    [rr, cc] = find(okxy(:, keepCols));
    Lt = table(cc, keepCols(cc)', Fr(sub2ind(size(Fr), rr, keepCols(cc)')), ...
        A(sub2ind(size(A), rr, keepCols(cc)')), B(sub2ind(size(B), rr, keepCols(cc)')), ...
        'VariableNames', {'track','build_col','frame','x_um','y_um'});
    writetable(Lt, fullfile(outDir, 'tracks', [base '_localizations.csv']));

    % ---- densities: whole movie, and per window -------------------------------------------------
    [sm, di] = cs_advisor_density(A, B, fovUm, binNm);
    imG = 30*sm; %#ok<NASGU>
    save(fullfile(outDir, ['Density_' base '.mat']), 'imG');
    writeU16(uint16(30*sm), fullfile(outDir, ['Density_' base '.tif']), false);
    lo = min(sm,[],'all'); hi = max(sm,[],'all'); if ~(hi > lo), hi = lo + 1; end
    imwrite(ind2rgb(uint8(round(255*(sm-lo)/(hi-lo))), turbo(256)), fullfile(outDir,'Densities',[base '_rho.tif']));

    [ranges, SFpick, gridPick] = cs_load_windows(anaDir, base, [Fi.window], Fi(1).grid, Fi(1).SF);
    ccache = containers.Map('KeyType','double','ValueType','any');   % per window, for the metrics
    wtif = fullfile(outDir, ['Density_' base '_windows.tif']);
    for w = 1:size(ranges,1)
        if isinf(ranges(w,1)) && isinf(ranges(w,2)), inW = true(size(Fr));
        else, inW = Fr >= ranges(w,1) & Fr <= ranges(w,2); end
        smw = cs_advisor_density(A(inW), B(inW), fovUm, binNm);
        writeU16(uint16(30*smw), wtif, w > 1);
    end
    wsrc = cs_ana_path(anaDir, 'find', ['Density_' base '_CSwindows.mat']);
    if ~isempty(wsrc), copyfile(wsrc, fullfile(outDir, ['Density_' base '_CSwindows.mat'])); end

    txt = fullfile(anaDir, 'csIDs', [base '_CSsites.txt']);
    if isfile(txt), copyfile(txt, fullfile(outDir, 'csIDs', [base '_CSsites.txt'])); end

    % ---- sites: the picker's contact sites, and the refined ones --------------------------------
    % Both are counted on the same filtered tracks, in each site's own window. The contact-site
    % table keeps EVERY pick — a site deleted on Refine is still something the picker found — and
    % flags it; the refined table is the final set, so deleted sites are not in it.
    Ai = Fauto(strcmp({Fauto.file}, base));
    det = pickerStats(anaDir, base, numel(Ai));
    prov = pickerProvenance(anaDir, base);
    del = [Fi.deleted];
    R.nDeleted = R.nDeleted + nnz(del);

    CSa = struct([]); rowsA = cell(numel(Ai), 1);
    for j = 1:numel(Ai)
        e = Ai(j);
        [nLoc, nTrk, mcols] = countInside(A, B, Fr, okxy, e.center, e.refboundary, e.winFrames);
        nm = siteMetrics(ccache, A, B, Fr, e, SFpick, gridPick);
        pk = e.pickPx(:)' * e.SF;                          % the pick, in um, on the grid it was made on
        rec = struct('file',base,'cellIndex',k,'csID',e.csID,'window',e.window, ...
            'frame0',e.winFrames(1),'frame1',e.winFrames(2), ...
            'pick_x_um',pk(1),'pick_y_um',pk(2),'pick_x_px',pk(1)/di.SF,'pick_y_px',pk(2)/di.SF, ...
            'mito',logical(e.mito),'manual',det.manual(j),'detect_method',prov.method, ...
            'detect_peak',det.peak(j),'detect_pval',det.pval(j),'detect_enrich',det.enrich(j), ...
            'detect_n_loc',det.nloc(j),'detect_n_tracks',det.ntrk(j),'detect_stability',det.stab(j), ...
            'detect_dwell_pct',det.dwell(j),'detect_area_um2',det.area(j), ...
            'auto_x_um',e.center(1),'auto_y_um',e.center(2),'auto_area_um2',e.areaUm2, ...
            'auto_n_loc_inside',nLoc,'auto_n_tracks',nTrk,'auto_member_tracks',numList(expNum(mcols)), ...
            'auto_prob_mass',nm.prob_mass,'auto_enrichment',nm.enrichment, ...
            'auto_local_dens_loc_um2',nm.local_dens,'auto_peak_prob',nm.peak_prob, ...
            'refined',logical(e.edited),'deleted_in_refine',logical(e.deleted), ...
            'SF_um_per_px',di.SF,'grid_px',di.n,'grid_picker_px',gridPick,'fov_um',fovUm,'bin_nm',binNm);
        rowsA{j} = rec;
        rec.auto_member_tracks = expNum(mcols);              % numeric in the .mat
        rec.auto_boundary_um = e.refboundary + e.center(:)';
        rec.auto_boundary_px = rec.auto_boundary_um / di.SF;
        if isempty(CSa), CSa = rec; else, CSa(end+1) = rec; end %#ok<AGROW>
    end
    contactsites = CSa; %#ok<NASGU>
    save(fullfile(outDir, 'sites', [base '_contactsites.mat']), 'contactsites');
    allA = appendRows(allA, rowsA, fullfile(outDir, 'sites', [base '_contactsites.csv']));

    Fkeep = Fi; if ~incDel, Fkeep = Fi(~del); end
    CSr = struct([]); rowsR = cell(numel(Fkeep), 1);
    for j = 1:numel(Fkeep)
        e = Fkeep(j); c = e.center(:)';
        [nLoc, nTrk, mcols] = countInside(A, B, Fr, okxy, c, e.refboundary, e.winFrames);
        nm = siteMetrics(ccache, A, B, Fr, e, SFpick, gridPick);
        [nNear, nTrkNear, nearIDs, inIDs] = countNear(A, B, Fr, e, boxUm);
        sgm = NaN; if isfield(e,'sigmaNm') && ~isempty(e.sigmaNm), sgm = e.sigmaNm; end
        nte = '';  if isfield(e,'note') && ~isempty(e.note), nte = char(e.note); end
        rec = struct('file',base,'cellIndex',k,'csID',e.csID,'window',e.window, ...
            'frame0',e.winFrames(1),'frame1',e.winFrames(2), ...
            'x_um',c(1),'y_um',c(2),'x_px',c(1)/di.SF,'y_px',c(2)/di.SF, ...
            'pick_x_px',e.pickPx(1),'pick_y_px',e.pickPx(2),'mito',logical(e.mito), ...
            'area_um2',e.areaUm2,'n_loc_inside',nLoc,'n_tracks',nTrk,'member_tracks',numList(expNum(mcols)), ...
            'cell_total_loc_win',nm.cell_total,'prob_mass',nm.prob_mass,'peak_prob',nm.peak_prob, ...
            'local_dens_loc_um2',nm.local_dens,'cell_bg_loc_um2',nm.cell_bg_dens,'enrichment',nm.enrichment, ...
            'box_um',boxUm,'n_loc_near',nNear,'n_tracks_near',nTrkNear, ...
            'D_in_um2s',med(Dcell, inIDs),'D_near_um2s',med(Dcell, nearIDs), ...
            'rollD_in_um2s',med(DtCell, inIDs),'rollD_near_um2s',med(DtCell, nearIDs), ...
            'footprint',char(e.mode),'outline_sigma_nm',sgm,'outline_note',nte, ...
            'edited',logical(e.edited),'deleted',logical(e.deleted), ...
            'SF_um_per_px',di.SF,'grid_px',di.n,'grid_picker_px',gridPick,'fov_um',fovUm,'bin_nm',binNm);
        rowsR{j} = rec;
        rec.member_tracks = expNum(mcols);                   % numeric in the .mat
        rec.boundary_um = e.refboundary + c;
        rec.boundary_px = rec.boundary_um / di.SF;
        if isempty(CSr), CSr = rec; else, CSr(end+1) = rec; end %#ok<AGROW>
    end
    refinedsites = CSr; %#ok<NASGU>
    save(fullfile(outDir, 'sites', [base '_refinedsites.mat']), 'refinedsites');
    allR = appendRows(allR, rowsR, fullfile(outDir, 'sites', [base '_refinedsites.csv']));
    R.nContact = R.nContact + numel(Ai);
    R.nRefinedEdited = R.nRefinedEdited + nnz([Fkeep.edited]);
    R.nSites = R.nSites + numel(Fkeep);
    % the advisor layout: the ORIGINAL tracks with the same columns kept as tracks/ (so track numbers
    % agree across the whole export), and the refined sites
    advCells(end+1) = struct('base', base, 'T', cs_track_slice(Tracks(k), keepCols), ... %#ok<AGROW>
        'sites', Fkeep, 'cond', condOf(opts, base), 'dims', movieDims(projectDir, base), ...
        'Deff', cs_track_slice_cols(Dcell, keepCols), 'Tess', cs_track_slice_cols(TessCell, keepCols));
    R.nCells = R.nCells + 1; R.cells{end+1} = base;
end
tpl = fullfile(fileparts(mfilename('fullpath')), 'export_template', 'analyse_export_one_cell.m');
if isfile(tpl), copyfile(tpl, fullfile(outDir, 'analyse_export_one_cell.m')); end
if ~isempty(allA), writetable(allA, fullfile(outDir, 'contactsites_all.csv')); end
R.advisor = struct('nCells',{},'nCS',{},'nMito',{},'label',{},'files',{});
if getf(opts, 'advisorFormat', true) && ~isempty(advCells)
    labels = {advCells.cond};
    [~, expName] = fileparts(outDir);
    if all(cellfun(@isempty, labels)), labels(:) = {expName};
    else, labels(cellfun(@isempty, labels)) = {'unassigned'}; end
    ul = unique(labels, 'stable');
    dtAdv = NaN;
    if isfield(Tracks, 'frameInterval') && ~isempty(Tracks(1).frameInterval), dtAdv = double(Tracks(1).frameInterval); end
    for q = 1:numel(ul)
        sel = strcmp(labels, ul{q});
        R.advisor(q) = cs_advisor_format(fullfile(outDir, 'advisor_format', cs_advisor_export_name(ul{q})), ...
            ul{q}, advCells(sel), struct('boxUm', getf(opts, 'advisorBoxUm', boxUm), 'frameInterval_s', dtAdv));
    end
end
if ~isempty(allR), writetable(allR, fullfile(outDir, 'refinedsites_all.csv')); end
writeReadme(outDir, R, finfo, tsName, stamp, incDel);
end

% =================================================================================================
function d = movieDims(projectDir, base)
% The movie's width and height in pixels, from the calibration resolver (which reads the movie).
% [NaN NaN] when it cannot say; the formatter then derives them from the field of view.
d = [NaN NaN];
try
    c = spt_project_calib(projectDir, base);
    if isfinite(c.width) && isfinite(c.height), d = [c.width c.height]; end
catch
end
end

function c = condOf(opts, base)
% The cell's condition from the Experiment tab, '' when none is assigned.
c = '';
if ~isfield(opts, 'conditions') || isempty(opts.conditions), return; end
m = opts.conditions;
if isa(m, 'containers.Map') && isKey(m, base), c = char(m(base)); end
end

function [fovUm, binNm] = cellCalib(T, opts)
% The cell's own calibration first — a plate can mix cameras — then the project fallback.
fovUm = getf(opts,'fovUm',NaN); binNm = getf(opts,'binNm',NaN);
if isfield(T,'calib') && isstruct(T.calib)
    c = T.calib;
    if isfield(c,'fovUm')  && isscalar(c.fovUm)  && isfinite(c.fovUm)  && c.fovUm  > 0, fovUm = c.fovUm;  end
    if isfield(c,'precNm') && isscalar(c.precNm) && isfinite(c.precNm) && c.precNm > 0, binNm = c.precNm; end
    if isfield(c,'binNm')  && isscalar(c.binNm)  && isfinite(c.binNm)  && c.binNm  > 0, binNm = c.binNm;  end
end
end

function m = siteMetrics(ccache, A, B, Fr, e, SF, grid)
% The NORMALIZED metrics, from the same kernel the mapper runs (csDensMetricOne) on the same
% density the picker detects on (sigma = 8 px on the picker's grid). Raw counts cannot be compared
% between cells - labelling and expression differ - so prob_mass (fraction of the cell's
% localizations in this window) and enrichment (density over the cell's OWN background) are what
% travel. Computed per window and cached: one density per window, not one per site.
blank = struct('csID',NaN,'cellIndex',NaN,'file','','mito',false,'n_loc_in',0, ...
    'cell_total',0,'prob_mass',NaN,'peak_prob',NaN,'peak_prob_raw',NaN,'area_um2',NaN, ...
    'local_dens',NaN,'cell_bg_dens',NaN,'enrichment',NaN);
m = blank;
w = e.window; if isempty(w) || ~isfinite(w), w = 1; end
if isKey(ccache, w)
    cc = ccache(w);
else
    f0 = e.winFrames(1); f1 = e.winFrames(2);
    sX = A(:); sY = B(:); sF = Fr(:);
    [rawCounts, Dens] = cs_window_density(sX, sY, sF, f0, f1, SF, grid, grid, 8);
    if isinf(f0) && isinf(f1), inw = true(size(sF)); else, inw = sF >= f0 & sF <= f1; end
    okc = inw & isfinite(sX) & isfinite(sY);
    occ = rawCounts >= 1; bg = mean(Dens(occ), 'omitnan'); if ~(bg > 0), bg = NaN; end
    cc = struct('rho', Dens.', 'Hc', rawCounts.', 'cxc', (1:grid)*SF, 'cyc', (1:grid)*SF, ...
                'rho_bg', bg, 'Xc', sX(okc), 'Yc', sY(okc), 'cellTot', nnz(okc));
    ccache(w) = cc;      % containers.Map is a handle: this caches for the next site in the window
end
cs = struct('csID', e.csID, 'cellIndex', e.cellIndex, 'refCenter', e.center(:)', ...
            'refboundary', e.refboundary*1000);            % the kernel's contract: nm, rel. centre
cs = cs_site_set_near(cs, 'mito', e.mito);
try, m = csDensMetricOne(cs, cc, e.file, blank, SF^2); catch, end
end

function [nLoc, nTrk, cols] = countInside(A, B, Fr, okxy, c, rb, wf)
% Localizations inside the outline during the window, and the distinct tracks they belong to. The
% same test the mapper uses: inpolygon on the tracked matrix, frames inside the window.
c = c(:)';
if isinf(wf(1)) && isinf(wf(2)), inW = true(size(Fr)); else, inW = Fr >= wf(1) & Fr <= wf(2); end
inP = false(size(A));
inP(okxy) = inpolygon(A(okxy)-c(1), B(okxy)-c(2), rb(:,1), rb(:,2));
mem = inP & inW & okxy;
nLoc = nnz(mem); cols = find(any(mem,1)); nTrk = numel(cols);
end

function s = numList(v)
% A member list as one CSV-safe string, bracketed so it always reads back as TEXT: "[3 17 42]",
% "[5]", "[]". Unbracketed, a one-member list would read back as a number and the column would
% change type from row to row. str2num / eval turn it back into a vector.
s = ['[' strjoin(arrayfun(@(x) sprintf('%d', x), v(:)', 'uni', 0), ' ') ']'];
end

function all = appendRows(all, rows, csvFile)
rows = rows(~cellfun(@isempty, rows));
if isempty(rows), return; end
Tt = struct2table([rows{:}], 'AsArray', true);
writetable(Tt, csvFile);
if isempty(all), all = Tt; else, all = [all; Tt]; end
end

function D = pickerStats(anaDir, base, n)
% The picker's own per-site numbers (_CSsites_stats.csv), row j = site j. NaN where the file is
% missing or does not describe the same number of sites — a guess would be worse than a gap.
nan_ = nan(n,1);
D = struct('manual',nan_,'peak',nan_,'pval',nan_,'enrich',nan_,'nloc',nan_,'ntrk',nan_, ...
           'stab',nan_,'dwell',nan_,'area',nan_);
f = fullfile(anaDir, 'csIDs', [base '_CSsites_stats.csv']);
if ~isfile(f), return; end
try, M = readmatrix(f, 'NumHeaderLines', 1); catch, return; end
if size(M,1) ~= n || size(M,2) < 14, return; end
D.manual = M(:,6); D.peak = M(:,7); D.pval = M(:,8); D.enrich = M(:,9); D.nloc = M(:,10);
D.ntrk = M(:,11); D.stab = M(:,12); D.dwell = M(:,13); D.area = M(:,14);
end

function P = pickerProvenance(anaDir, base)
P = struct('method','');
f = fullfile(anaDir, 'csIDs', [base '_CSsites_provenance.json']);
if ~isfile(f), return; end
try, j = jsondecode(fileread(f)); if isfield(j,'method'), P.method = char(j.method); end, catch, end
end

function writeU16(img, f, append)
if append, imwrite(img, f, 'WriteMode', 'append', 'Compression', 'none');
else,      imwrite(img, f, 'Compression', 'none'); end
end

function writeReadme(outDir, R, finfo, tsName, stamp, incDel)
% The README travels with the files, so it has to answer every question about them on its own:
% what each file is, what every column means and in which units, and what was left out.
fid = fopen(fullfile(outDir, 'README.txt'), 'w');
c = onCleanup(@() fclose(fid));
L = {
sprintf('CONTACT-SITE EXPORT   %s', stamp)
sprintf('Build: %s   Cells: %d   Contact sites: %d   Refined sites: %d (%d refined by hand)', ...
        tsName, R.nCells, R.nContact, R.nSites, R.nRefinedEdited)
''
'=== WHAT THE NUMBERS ARE BUILT FROM ==='
'Every density image, every localization / track count and the tracks/ folder use the TRACKED'
'localizations of the build: tracks that passed filtering and curation,'
sprintf('minus %d track(s) rejected by hand on the QC tab.', R.nRejectedTracks)
'Detections that never linked into a track are not included anywhere.'
'Frame numbers are 0-based, as in the tracking output.'
'<cell> below is the cell''s file name, e.g. HVK-3C-Plate4-328-011-b_ch24_spt.'
''
'=== FILES, PER CELL ==='
'Density_<cell>.mat'
'    Variable imG: an n x n double image, row = y, column = x.'
'    imG = 30 x (localization counts per bin, Gaussian-smoothed with sigma = 2 bins), whole movie.'
'    sum(imG(:))/30 = the number of localizations in the image (smoothing keeps the total).'
'    This is the format the external ContactSites code reads.'
'Density_<cell>.tif'
'    The same image as uint16 - same values, rounded.'
'Densities/<cell>_rho.tif'
'    The same image as 8-bit RGB through the turbo colormap, scaled from the cell''s own minimum to'
'    its own maximum. For LOOKING only: colours are not comparable between cells. Use imG for numbers.'
'Density_<cell>_windows.tif'
'    The same density built separately for each picker time window: one page per window, page w ='
'    window w. Sites were picked on these, and a site from window 2 need not be visible on the'
'    whole-movie image. With a single window this page equals Density_<cell>.tif.'
'Density_<cell>_CSwindows.mat'
'    Variable windows: .ranges = [first last] frame of each window, .framesPerWindow, .nWindows,'
'    .grid and .SF_umPerPx of the picker, .frameInterval (s), .source (density source).'
'csIDs/<cell>_CSsites.txt'
'    The picks, tab-separated: idx  X  Y  XM  YM  Slice  Counter  Count'
'    X,Y = pick in the picker''s pixels (XM,YM the same); Slice = window; Counter 1 = mito, 2 = not.'
'sites/<cell>_contactsites.csv   + .mat (variable contactsites)'
'    CONTACT SITES: every pick, as the picker found it. See the column list below.'
'    The .mat adds auto_boundary_um and auto_boundary_px: the automatic outline polygon, K x 2.'
'sites/<cell>_refinedsites.csv   + .mat (variable refinedsites)'
'    REFINED SITES: the final set after Refine. See the column list below.'
'    The .mat adds boundary_um and boundary_px: the refined outline polygon, K x 2, closed.'
'tracks/<cell>_tracks.mat   (variable tracks)'
'    The localizations every number here was counted from. Fields:'
'      frame, x_um, y_um   [maxLength x nTracks]: column j is track j, rows are its localizations in'
'                          time order, NaN-padded. frame is 0-based.'
'      build_col           [1 x nTracks] the column each track has in the pipeline''s build'
'      n_loc               [1 x nTracks] localizations per track'
'      frameInterval_s, fov_um, bin_nm, file, note'
'    Track numbers here are the ones in member_tracks / auto_member_tracks.'
'tracks/<cell>_localizations.csv'
'    The same, one row per localization: track, build_col, frame, x_um, y_um.'
''
'=== FILES, WHOLE EXPORT ==='
'contactsites_all.csv    every cell''s contactsites rows in one table'
'refinedsites_all.csv    every cell''s refinedsites rows in one table'
'analyse_export_one_cell.m'
'    Base-MATLAB script (no pipeline code needed). Run it in this folder: it loads one cell at a'
'    time, recounts every refined site from tracks/, checks the counts against the tables, measures'
'    how much of each member track is inside, plots the outlines, and writes results_per_site.csv.'
'    Set cellToRun inside it to analyse a single cell.'
'advisor_format/<condition>/'
'    The same refined sites in the layout of the lab''s published ContactSites dataset (VAPB):'
'    CS_final_v3.mat, <condition>_Tracks_finalv3.mat, <condition>_EC.mat, BindingInfo.mat,'
'    CS_details_v2.xlsx, <condition>-CSstats.xlsx, <condition>-EnrichmentCoefficients.xlsx,'
'    <condition>-BindingTable.xlsx. Its own README_advisor_format.txt says what is filled, what is'
'    empty and why. One folder per condition (Experiment tab).'
'README.txt              this file'
''
'=== CONTACT SITES vs REFINED SITES ==='
'contactsites has one row per pick, INCLUDING picks deleted later on Refine (deleted_in_refine = 1).'
'It describes each site twice: as the picker DETECTED it (detect_*), and with the AUTOMATIC'
'half-max outline drawn around the pick (auto_*), which is what the mapper uses for a site that'
'was never refined. That outline is the half-max of the density at the project''s outline'
'smoothing (outline_sigma_nm in refinedsites; 100 nm unless changed on the Refine tab).'
'refinedsites has one row per site in the FINAL set: deleted sites are left out, refined sites'
'carry their refined outline, and never-refined sites carry the automatic one with edited = 0.'
'It is the complete set to analyse.'
''
'=== COLUMNS IN BOTH TABLES ==='
'file              cell file name'
'cellIndex         the cell''s position in the build (the "c#" on the Refine tab)'
'csID              site number within the cell (the "s#" on the Refine tab; row order of CSsites.txt)'
'window            picker time window the site belongs to'
'frame0, frame1    first and last frame of that window (0-based, inclusive)'
'mito              1 = classified as touching mitochondria, 0 = not'
'SF_um_per_px      microns per density pixel, = fov_um / grid_px'
'grid_px           side of the density images in this folder, in pixels'
'grid_picker_px    side of the grid the site was picked on (equal to grid_px unless the calibration changed)'
'fov_um            field of view of this cell, microns'
'bin_nm            density bin size, nanometres'
''
'=== COLUMNS IN contactsites ==='
'pick_x_um, pick_y_um    where the site was picked, microns'
'pick_x_px, pick_y_px    the same, in pixels of THIS folder''s grid (= pick_um / SF_um_per_px)'
'manual                  1 = added by hand in the picker, 0 = found by the detector'
'detect_method           detector used: local (local background), ermc (Monte-Carlo null), relative'
'detect_peak             peak of the picker''s density inside the site, localizations per bin after'
'                        smoothing with sigma = 8 px (a wider kernel than imG: not directly comparable)'
'detect_pval             p against the Monte-Carlo null; EMPTY for local and relative, which give no p'
'detect_enrich           detect_peak / median density over the support (the "enr x" column in the picker)'
'detect_n_loc            localizations inside the DETECTED blob (for a manual site: within the contact disc)'
'detect_n_tracks         distinct tracks among them'
'detect_stability        split-half reproducibility, 0-1 (empty for a manual site)'
'detect_dwell_pct        median, over those tracks, of the % of each track''s window localizations inside the blob'
'                        (high = molecules stay; low = they pass through)'
'detect_area_um2         area of the detected blob (for a manual site: the contact disc)'
'auto_x_um, auto_y_um    centre of the automatic outline'
'auto_area_um2           area of the automatic outline'
'auto_n_loc_inside       localizations inside the automatic outline during the window'
'auto_n_tracks           distinct tracks among them'
'auto_member_tracks      those tracks, as track numbers in tracks/ (CSV: text "[3 17 42]"; .mat: a vector)'
'auto_prob_mass          localizations inside the automatic outline / the cell''s localizations in that window'
'auto_enrichment         its density / the cell''s own background density (fold, dimensionless)'
'auto_local_dens_loc_um2 mean smoothed density inside it, as localizations per um^2'
'auto_peak_prob          peak density inside it / the cell''s localizations in that window'
'refined                 1 = this site was later refined by hand on the Refine tab'
'deleted_in_refine       1 = this site was deleted on the Refine tab (it is not in refinedsites)'
''
'detect_n_loc and auto_n_loc_inside differ by design: the first counts the thresholded blob the'
'picker detected on its smoother density, the second the half-max outline.'
''
'=== COLUMNS IN refinedsites ==='
'x_um, y_um        site centre, microns (the refined centre if it was moved)'
'x_px, y_px        the same centre in pixels of this folder''s grid (= x_um / SF_um_per_px)'
'pick_x_px, pick_y_px   where the site was originally picked, in the picker''s pixels'
'area_um2          area of the outline'
'n_loc_inside      localizations inside the outline during the site''s window'
'n_tracks          distinct tracks among them'
'member_tracks     those tracks, as track numbers in tracks/ (CSV: text "[3 17 42]"; .mat: a vector)'
'cell_total_loc_win  the cell''s localizations in this site''s window - the normalizing count'
'prob_mass         n_loc_inside / cell_total_loc_win: the share of the cell that is in this site'
'peak_prob         peak smoothed density inside / cell_total_loc_win'
'local_dens_loc_um2  mean smoothed density inside the outline, localizations per um^2'
'cell_bg_loc_um2   the cell''s own background density in that window (mean over occupied bins), loc/um^2'
'enrichment        local_dens_loc_um2 / cell_bg_loc_um2 (fold, dimensionless)'
'footprint         how the outline was made: halfmax = automatic; freehand = drawn by hand;'
'                  +smooth = smoothed; +centre = centre moved with the outline kept'
'outline_sigma_nm  the smoothing (Gaussian sigma, nm) of the density the outline was made on:'
'                  the half-max of it (halfmax), or the image it was drawn on (freehand). Finding'
'                  sites uses 240 nm; outlines use their own, finer scale (100 nm by default, the'
'                  value at which the automatic outline reproduces the published VAPB hand-drawn'
'                  median area). Blank = saved before this was recorded (made at 240 nm).'
'box_um            width of the NEIGHBOURHOOD BOX around the site centre (cs_neighbour_box; 1.024'
'                  um, the VAPB dataset''s +/-30 density px, unless changed on the Refine tab)'
'n_loc_near        localizations in that box but OUTSIDE the outline - the site''s local control'
'n_tracks_near     tracks among them'
'D_in_um2s         median diffusion coefficient of the localizations inside the outline, from the'
'                  tessellation map (cs_tessellate). Blank when that has not been run.'
'D_near_um2s       the same for the neighbours: the number to compare D_in with'
'rollD_in_um2s     median of the per-localization ROLLING D (Tracks.Dt) inside the outline - a'
'                  second, independent estimate that needs no tessellation'
'rollD_near_um2s   the same for the neighbours'
'outline_note      why a site should be looked at, e.g. its centre was moved to the outline''s'
'                  peak when the outlines were regenerated. Usually blank.'
'edited            1 = a saved outline (drawn, adjusted or regenerated on the Refine tab);'
'                  0 = the automatic outline, computed at export'
'deleted           always 0 here (deleted sites are left out)'
''
'=== COMPARING CELLS ==='
'Raw counts are NOT comparable between cells: a cell with twice the labelling has twice the'
'localizations everywhere. Use the normalized columns, which are computed by the same kernel the'
'pipeline and the ContactSites code use:'
'  prob_mass    the share of THIS cell''s localizations that sit in the site (window-matched)'
'  enrichment   the site''s density over THIS cell''s own background - fold over its own baseline'
'  peak_prob    the same normalization applied to the peak instead of the mean'
'local_dens_loc_um2 and n_loc_inside are absolute: fine within a cell, not across cells.'
'The density IMAGES are absolute counts too (imG = 30 x smoothed counts), not normalized.'
''
'=== COORDINATES ==='
'Use the _um columns if in doubt: they mean the same thing everywhere.'
'Pixel columns follow the ContactSites mapper''s convention: pixel c is centred on c x SF microns'
'(1-based, MATLAB indexing). The density images are histograms whose column c holds'
'x in [c x bin, (c+1) x bin) nm, so an image column and a _px value can differ by up to half a'
'pixel. If grid_picker_px differs from grid_px, the picker''s pixel numbers (CSsites.txt and'
'refinedsites pick_*_px) are on a different grid from these images - use microns.'
''
'=== LEFT OUT ==='
};
if incDel
    L{end+1} = sprintf('Sites deleted on Refine are INCLUDED in refinedsites with deleted = 1 (%d).', R.nDeleted);
else
    L{end+1} = sprintf('%d site(s) deleted on Refine: flagged in contactsites, absent from refinedsites.', R.nDeleted);
end
L{end+1} = 'Cells marked EXCLUDE on the Experiment tab, and cells with no saved sites, are not exported.';
L{end+1} = 'Refine edits that were not SAVED are not in these files.';
if finfo.nStale > 0
    L{end+1} = sprintf(['WARNING: %d saved refinement(s) no longer match any picked site (the picks ' ...
                        'moved since) and were ignored.'], finfo.nStale);
end
if ~isempty(R.skipped)
    L{end+1} = ''; L{end+1} = '=== SKIPPED ===';
    for q = 1:numel(R.skipped), L{end+1} = R.skipped{q}; end %#ok<AGROW>
end
fprintf(fid, '%s\n', L{:});
end

function [nNear, nTrk, nearIDs, inIDs] = countNear(A, B, Fr, e, boxUm)
% THE NEIGHBOURHOOD: what is in the site's box but outside its outline - the local control.
c = e.center(:)'; h = boxUm/2;
ok = isfinite(A) & isfinite(B);
inWin = true(size(A)); if ~(isinf(e.winFrames(1)) && isinf(e.winFrames(2)))
    inWin = Fr >= e.winFrames(1) & Fr <= e.winFrames(2); end
inBox = abs(A - c(1)) <= h & abs(B - c(2)) <= h & ok & inWin;
inPoly = false(size(A));
inPoly(ok) = inpolygon(A(ok) - c(1), B(ok) - c(2), e.refboundary(:,1), e.refboundary(:,2));
inIDs = find(inPoly & inWin & ok);
nearIDs = find(inBox & ~inPoly);
nNear = numel(nearIDs); nTrk = nnz(any(inBox & ~inPoly, 1));
end

function v = med(M, idx)
v = NaN;
if ~isempty(M) && ~isempty(idx), v = median(M(idx), 'omitnan'); end
end

function C = cs_track_slice_cols(M, cols)
C = [];
if ~isempty(M), C = M(:, cols); end
end

function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
