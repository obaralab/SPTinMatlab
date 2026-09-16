function R = cs_advisor_export(anaDir, opts)
%CS_ADVISOR_EXPORT  One folder to hand to someone else: every cell's density (.mat + .tif) together
%with its contact sites, all built from the SAME filtered localizations the picker and Refine show.
%
%   R = cs_advisor_export(anaDir, opts)
%
% opts  .name            folder name under analysis/exports/ (default advisor_<yyyymmdd-HHMMSS>)
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
%   sites/<cell>_contactsites.csv + .mat   the CONTACT SITES as the picker found them: every pick
%                                (including ones later deleted on Refine, flagged), the picker's own
%                                detection statistics, and the AUTOMATIC outline around it with the
%                                localizations and tracks inside
%   sites/<cell>_refinedsites.csv + .mat   the REFINED SITES: every site as it now stands, each saved
%                                Refine edit applied and deleted sites left out, with the localizations
%                                and tracks inside the refined outline
%   (the .mat files add the outline polygons)
%   contactsites_all.csv, refinedsites_all.csv   every cell in one table each
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
        outDir = fullfile(root, ['advisor_' stamp]);
        q = 1;
        while isfolder(outDir), q = q + 1; outDir = fullfile(root, sprintf('advisor_%s_%d', stamp, q)); end
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

for d = {outDir, fullfile(outDir,'Densities'), fullfile(outDir,'csIDs'), fullfile(outDir,'sites')}
    if ~isfolder(d{1}), mkdir(d{1}); end
end

allA = []; allR = [];
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

    % ---- densities: whole movie, and per window -------------------------------------------------
    [sm, di] = cs_advisor_density(A, B, fovUm, binNm);
    imG = 30*sm; %#ok<NASGU>
    save(fullfile(outDir, ['Density_' base '.mat']), 'imG');
    writeU16(uint16(30*sm), fullfile(outDir, ['Density_' base '.tif']), false);
    lo = min(sm,[],'all'); hi = max(sm,[],'all'); if ~(hi > lo), hi = lo + 1; end
    imwrite(ind2rgb(uint8(round(255*(sm-lo)/(hi-lo))), turbo(256)), fullfile(outDir,'Densities',[base '_rho.tif']));

    [ranges, ~, gridPick] = cs_load_windows(anaDir, base, [Fi.window], Fi(1).grid, Fi(1).SF);
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
        [nLoc, nTrk] = countInside(A, B, Fr, okxy, e.center, e.refboundary, e.winFrames);
        pk = e.pickPx(:)' * e.SF;                          % the pick, in um, on the grid it was made on
        rec = struct('file',base,'cellIndex',k,'csID',e.csID,'window',e.window, ...
            'frame0',e.winFrames(1),'frame1',e.winFrames(2), ...
            'pick_x_um',pk(1),'pick_y_um',pk(2),'pick_x_px',pk(1)/di.SF,'pick_y_px',pk(2)/di.SF, ...
            'mito',logical(e.mito),'manual',det.manual(j),'detect_method',prov.method, ...
            'detect_peak',det.peak(j),'detect_pval',det.pval(j),'detect_enrich',det.enrich(j), ...
            'detect_n_loc',det.nloc(j),'detect_n_tracks',det.ntrk(j),'detect_stability',det.stab(j), ...
            'detect_dwell_pct',det.dwell(j),'detect_area_um2',det.area(j), ...
            'auto_x_um',e.center(1),'auto_y_um',e.center(2),'auto_area_um2',e.areaUm2, ...
            'auto_n_loc_inside',nLoc,'auto_n_tracks',nTrk, ...
            'refined',logical(e.edited),'deleted_in_refine',logical(e.deleted), ...
            'SF_um_per_px',di.SF,'grid_px',di.n,'grid_picker_px',gridPick,'fov_um',fovUm,'bin_nm',binNm);
        rowsA{j} = rec;
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
        [nLoc, nTrk] = countInside(A, B, Fr, okxy, c, e.refboundary, e.winFrames);
        rec = struct('file',base,'cellIndex',k,'csID',e.csID,'window',e.window, ...
            'frame0',e.winFrames(1),'frame1',e.winFrames(2), ...
            'x_um',c(1),'y_um',c(2),'x_px',c(1)/di.SF,'y_px',c(2)/di.SF, ...
            'pick_x_px',e.pickPx(1),'pick_y_px',e.pickPx(2),'mito',logical(e.mito), ...
            'area_um2',e.areaUm2,'n_loc_inside',nLoc,'n_tracks',nTrk, ...
            'footprint',char(e.mode),'edited',logical(e.edited),'deleted',logical(e.deleted), ...
            'SF_um_per_px',di.SF,'grid_px',di.n,'grid_picker_px',gridPick,'fov_um',fovUm,'bin_nm',binNm);
        rowsR{j} = rec;
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
    R.nCells = R.nCells + 1; R.cells{end+1} = base;
end
if ~isempty(allA), writetable(allA, fullfile(outDir, 'contactsites_all.csv')); end
if ~isempty(allR), writetable(allR, fullfile(outDir, 'refinedsites_all.csv')); end
writeReadme(outDir, R, finfo, tsName, stamp, incDel);
end

% =================================================================================================
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

function [nLoc, nTrk] = countInside(A, B, Fr, okxy, c, rb, wf)
% Localizations inside the outline during the window, and the distinct tracks they belong to. The
% same test the mapper uses: inpolygon on the tracked matrix, frames inside the window.
c = c(:)';
if isinf(wf(1)) && isinf(wf(2)), inW = true(size(Fr)); else, inW = Fr >= wf(1) & Fr <= wf(2); end
inP = false(size(A));
inP(okxy) = inpolygon(A(okxy)-c(1), B(okxy)-c(2), rb(:,1), rb(:,2));
mem = inP & inW & okxy;
nLoc = nnz(mem); nTrk = nnz(any(mem,1));
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
fid = fopen(fullfile(outDir, 'README.txt'), 'w');
c = onCleanup(@() fclose(fid));
p = @(varargin) fprintf(fid, varargin{:});
p('Contact-site export  -  %s\n', stamp);
p('Build: %s   Cells: %d   Contact sites: %d   Refined sites: %d (%d edited)\n\n', ...
    tsName, R.nCells, R.nContact, R.nSites, R.nRefinedEdited);
p('LOCALIZATIONS\n');
p('  Every density and every count here is built from the TRACKED localizations of the build -\n');
p('  the tracks that passed filtering and curation - minus %d track(s) rejected by hand on the QC tab.\n', R.nRejectedTracks);
p('  Detections that never linked into a track are NOT included.\n\n');
p('FILES (per cell)\n');
p('  Density_<cell>.mat          imG = 30 * smoothed localization counts (whole movie)\n');
p('  Density_<cell>.tif          uint16(imG)\n');
p('  Densities/<cell>_rho.tif    the same, rendered through the turbo colormap\n');
p('  Density_<cell>_windows.tif  the same density per time WINDOW, one page per window (page w = window w)\n');
p('  Density_<cell>_CSwindows.mat  windows.ranges = [first last] frame of each window\n');
p('  csIDs/<cell>_CSsites.txt    the picks: idx X Y XM YM Slice(=window) Counter(1=mito, 2=not) Count\n');
p('  sites/<cell>_contactsites.csv/.mat   CONTACT SITES - every pick as the picker found it (%d)\n', R.nContact);
p('  sites/<cell>_refinedsites.csv/.mat   REFINED SITES - the final set after Refine (%d, %d edited)\n', R.nSites, R.nRefinedEdited);
p('  contactsites_all.csv, refinedsites_all.csv   every cell in one table each\n\n');
p('CONTACT SITES vs REFINED SITES\n');
p('  contactsites: one row per pick, INCLUDING picks later deleted on Refine (deleted_in_refine = 1).\n');
p('    pick_*          where the site was picked\n');
p('    detect_*        the picker''s own numbers for that site (detect_method says which detector):\n');
p('                    peak density, p, enrichment,\n');
p('                    localizations and tracks in the DETECTED blob, split-half stability, dwell %%, blob area\n');
p('    auto_*          the automatic (half-max) outline around the pick: centre, area, and the\n');
p('                    localizations / tracks inside it\n');
p('    refined         1 if the site was later refined by hand\n');
p('  refinedsites: one row per site in the final set - deleted sites are left out. Sites that were\n');
p('    never refined are included with their automatic outline and edited = 0, so this table is\n');
p('    the complete set to analyse.\n');
p('  The detect_n_loc and auto_n_loc_inside counts differ by design: one is the thresholded blob the\n');
p('  picker detected, the other the half-max outline the mapper uses.\n\n');
p('DENSITY GRID\n');
p('  n = ceil(FOV / bin) pixels per side. Bin edges are bin*(1:n+1) nm, so column c holds x in\n');
p('  [c*bin, (c+1)*bin) nm; smoothing is imgaussfilt(counts, [2 2]); the image is transposed so\n');
p('  row = y and column = x.\n\n');
p('SITE COORDINATES\n');
p('  *_um             microns - unambiguous; use these if in doubt\n');
p('  x_um, y_um       refined site centre (refinedsites); auto_x_um/auto_y_um for the automatic outline\n');
p('  x_px, y_px       the same centre in density pixels, x_um / SF with SF = FOV / n\n');
p('                   (the convention the ContactSites mapper uses: pixel c <-> c*SF um).\n');
p('                   That is up to half a pixel from the histogram column above.\n');
p('  pick_x_px/y_px   where the site was originally picked (refinedsites: the picker''s own pixels;\n');
p('                   contactsites: converted to this grid, with pick_x_um/pick_y_um alongside)\n');
p('  grid_picker_px   the grid the site was picked on. If it differs from grid_px, the pick pixels\n');
p('                   are on a different grid from these density files - use the um columns.\n\n');
p('SITE MEASUREMENTS\n');
p('  n_loc_inside     localizations inside the refined boundary during its window\n');
p('  n_tracks         distinct tracks with at least one of those localizations\n');
p('  area_um2         area of the boundary polygon\n');
p('  footprint        how the boundary was made: halfmax = automatic; freehand / +smooth / +centre = refined\n');
p('  edited           true if the boundary was refined by hand\n');
p('  mito             true if the site was classified as touching mitochondria\n\n');
if incDel
    p('Sites deleted during refinement ARE included, with deleted = true (%d).\n', R.nDeleted);
else
    p('Sites deleted during refinement are left out of refinedsites (%d) and flagged in contactsites.\n', R.nDeleted);
end
if finfo.nStale > 0
    p('WARNING: %d saved refinement(s) no longer match any picked site (the picks moved) and were ignored.\n', finfo.nStale);
end
if ~isempty(R.skipped)
    p('\nSKIPPED\n'); for q = 1:numel(R.skipped), p('  %s\n', R.skipped{q}); end
end
end

function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
