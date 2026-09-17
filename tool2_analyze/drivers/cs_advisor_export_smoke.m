function cs_advisor_export_smoke()
%CS_ADVISOR_EXPORT_SMOKE  The advisor bundle must contain the density the sites were picked on and
%the sites as they currently stand — and every number in it must be recountable.
%
% WHAT IS ASSERTED:
%   1. THE DENSITY IS THE FILTERED TRACKED SET. imG is recomputed here from the build's tracked
%      matrix minus the hand-rejected track, and must match exactly. Two things must NOT be in it:
%      the rejected track (planted inside the site, so leaving it in changes the numbers) and the
%      detection cloud (planted where no track goes, so any signal there is the cloud leaking in).
%   2. THE SITES ARE THE SAVED REFINEMENT. A saved Refine edit replaces the auto footprint (area and
%      counts follow it), a deleted site is left out and counted, and the centre is the refined one.
%   3. EVERY COUNT RECOUNTS. n_loc_inside / n_tracks are recomputed from the matrix, the boundary
%      and the window, independently of the exporter.
%   4. THE COORDINATES SAY WHAT THEY ARE. x_px = x_um / SF with SF = FOV / grid, and the README
%      states it. A bare pixel number is ambiguous between two grids that differ by half a pixel.
%   5. THE BUNDLE IS COMPLETE: per-window density pages, the picks file, the combined table, README.
%   6. THE CELL FILTER BITES: asking for a cell with no saved sites exports nothing and says why.
%   7. BOTH SITE SETS ARE THERE. contactsites = every pick as the picker found it (a site deleted on
%      Refine is still listed, flagged), with the picker's own detection numbers joined on and the
%      AUTOMATIC outline recounted; refinedsites = the final set. Neither may be mistaken for the other.
%  10. THE NUMBERS THAT COMPARE CELLS ARE THERE. Raw counts are not comparable between cells, so
%      both tables carry prob_mass (share of the cell's localizations) and enrichment (fold over the
%      cell's OWN background), from the same kernel the mapper uses — and its localization count
%      must agree with the independent recount.
%   9. THE EXPORT IS SELF-CONTAINED. The tracks go out (hand-rejected ones not), every site lists its
%      member tracks by their number in tracks/, and the shipped analyse_export_one_cell.m — which
%      depends on NO pipeline file — reloads each cell from the export alone and reproduces every
%      site's counts exactly. Without the tracks the export was pictures and summaries.
%   8. THE NAME IS THE USER'S, AND NOTHING IS OVERWRITTEN. A typed name is made folder-safe, and
%      exporting again under a name already used refuses rather than mixing two runs in one folder.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_advexp_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
ana = fullfile(proj,'analysis'); mkdir(fullfile(ana,'csIDs'));
cleanup = onCleanup(@() rmdir(proj,'s'));

fov = 16; bin = 30; n = ceil(fov/(bin/1000)); SF = fov/n;
[TA, rejCol] = mkCell('cellA', fov, bin);
TB = mkCell('cellB', fov, bin);
Tracks = [TA TB]; %#ok<NASGU>
save(fullfile(ana,'TrackStruct.mat'),'Tracks','-v7.3');
calib = struct('pixSizeUm',fov/100,'fovUm',fov,'dt_s',0.02,'binNm',bin,'snapFovUm',fov); %#ok<NASGU>
save(fullfile(ana,'cs_calib.mat'),'calib');

% hand-reject one track that sits INSIDE site 1
ex = cs_track_exclusions('load', proj);
ex = cs_track_exclusions('toggle', ex, 'cellA', rejCol, 'smoke: planted inside site 1');
cs_track_exclusions('save', proj, ex);

% saved picks: site 1 at (5,5) and site 2 at (9,9) in window 1, site 3 at (5,5) in window 2
win = [0 29; 30 59];
picks = [5 5 1; 9 9 1; 5 5 2];
fid = fopen(fullfile(ana,'csIDs','cellA_CSsites.txt'),'w');
fprintf(fid,' \tX\tY\tXM\tYM\tSlice\tCounter\tCount\n');
for j = 1:size(picks,1)
    fprintf(fid,'%d\t%.3f\t%.3f\t%.3f\t%.3f\t%d\t%d\t%d\n', j, picks(j,1)/SF, picks(j,2)/SF, ...
        picks(j,1)/SF, picks(j,2)/SF, picks(j,3), 1, 0);
end
fclose(fid);
fid = fopen(fullfile(ana,'csIDs','cellA_CSsites_stats.csv'),'w');
fprintf(fid,'site,window,x_px,y_px,mito,manual,peak,pval,enrich,nLocs,nTracks,stability,dwell_pct,area_um2\n');
for j = 1:size(picks,1)
    fprintf(fid,'%d,%d,%.3f,%.3f,1,%d,%g,%g,%g,%d,%d,%g,%g,%g\n', j, picks(j,3), picks(j,1)/SF, picks(j,2)/SF, ...
        j==3, 10+j, 0.01*j, 5+j, 100+j, 7+j, 0.9, 40+j, 0.2+j/100);
end
fclose(fid);
fid = fopen(fullfile(ana,'csIDs','cellA_CSsites_provenance.json'),'w'); fprintf(fid,'{"method":"local"}'); fclose(fid);
windows = struct('framesPerWindow',30,'nWindows',2,'ranges',win,'grid',n,'SF_umPerPx',SF, ...
                 'frameInterval',0.02,'source','tracked'); %#ok<NASGU>
save(cs_ana_path(ana,'density','Density_cellA_CSwindows.mat'),'windows');

% saved refinement: site 1 becomes a hand-drawn 0.30 um disc centred a little off the pick; site 2 deleted
F0 = cs_footprints_build(ana, struct('save',false,'verbose',false));
i1 = find([F0.csID]==1); i2 = find([F0.csID]==2);
th = linspace(0,2*pi,60)'; rDisc = 0.30;
ed = F0(i1); ed.center = [5.05 4.98]; ed.refboundary = rDisc*[cos(th) sin(th)];
ed.mode = 'freehand'; ed.areaUm2 = polyarea(ed.refboundary(:,1), ed.refboundary(:,2)); ed.edited = true;
CSfoot = ed; %#ok<NASGU>
CSdeleted = struct('file',F0(i2).file,'csID',F0(i2).csID,'window',F0(i2).window,'pickPx',F0(i2).pickPx); %#ok<NASGU>
save(fullfile(ana,'CS_footprints.mat'),'CSfoot','CSdeleted','-v7.3');

R = cs_advisor_export(ana, struct('fovUm',fov,'binNm',bin,'name','run 1: first/look'));
out = R.outDir;
fprintf('exported to %s\n', out);
% The default location is analysis/exports/ — an unknown cs_ana_path kind silently lands at the
% analysis/ root, which is exactly the crowding the subfolders exist to prevent.
assert(strcmp(out, fullfile(ana,'exports','run_1_first_look')), ...
    'the bundle was written to %s; the typed name "run 1: first/look" should give exports/run_1_first_look', out);

%% (5) the bundle is complete ----------------------------------------------------------------------------
need = {'Density_cellA.mat','Density_cellA.tif','Densities/cellA_rho.tif','Density_cellA_windows.tif', ...
        'Density_cellA_CSwindows.mat','csIDs/cellA_CSsites.txt','sites/cellA_contactsites.csv', ...
        'sites/cellA_contactsites.mat','sites/cellA_refinedsites.csv','sites/cellA_refinedsites.mat', ...
        'contactsites_all.csv','refinedsites_all.csv','README.txt', ...
        'tracks/cellA_tracks.mat','tracks/cellA_localizations.csv','analyse_export_one_cell.m'};
for q = 1:numel(need)
    assert(isfile(fullfile(out, need{q})), 'the bundle is missing %s', need{q});
end
assert(numel(imfinfo(fullfile(out,'Density_cellA_windows.tif'))) == size(win,1), ...
    'the per-window density has %d page(s) for %d windows', numel(imfinfo(fullfile(out,'Density_cellA_windows.tif'))), size(win,1));
assert(R.nCells == 1, 'exported %d cells; only cellA has saved sites', R.nCells);

%% (1) the density is the filtered tracked set ----------------------------------------------------------
Tb = cs_track_exclusions('blank', ex, TA);
[smF, di] = cs_advisor_density(Tb.matrix(:,:,2), Tb.matrix(:,:,3), fov, bin);
L = load(fullfile(out,'Density_cellA.mat'));
assert(isequal(size(L.imG), [n n]), 'imG is %s, the grid is %dx%d', mat2str(size(L.imG)), n, n);
assert(max(abs(L.imG - 30*smF), [], 'all') < 1e-9, ...
    'imG is not 30x the density of the filtered tracked localizations');
smAll = cs_advisor_density(TA.matrix(:,:,2), TA.matrix(:,:,3), fov, bin);
assert(max(abs(L.imG - 30*smAll), [], 'all') > 1e-6, ...
    ['imG equals the density WITH the hand-rejected track. That track was planted inside site 1; ' ...
     'leaving it in means the advisor gets a density the picker never showed.']);
cloudPx = round(1000*[12 12]/bin);                    % the cloud-only detections, histogram column
assert(L.imG(cloudPx(2), cloudPx(1)) == 0, ...
    ['the density has signal at (12,12) um, where only UNTRACKED detections were planted. The ' ...
     'export must be built from the tracked matrix, not the detection cloud.']);
fprintf('density: filtered tracked set (%d locs) · rejected track out · cloud out\n', di.nLoc);

%% (2)+(3) sites: saved refinement, recountable, deleted one left out ----------------------------------
C = readtable(fullfile(out,'sites','cellA_refinedsites.csv'), 'TextType','string');
assert(height(C) == 2, 'the table has %d site(s); 3 picked, 1 deleted -> 2', height(C));
assert(~any(C.csID == 2), 'the DELETED site 2 was exported');
assert(R.nDeleted == 1, 'R.nDeleted = %d, wanted 1', R.nDeleted);
r1 = C(C.csID == 1, :);
assert(abs(r1.x_um - 5.05) < 1e-9 && abs(r1.y_um - 4.98) < 1e-9, ...
    'site 1 centre is (%.4f, %.4f); the saved refinement moved it to (5.05, 4.98)', r1.x_um, r1.y_um);
assert(abs(r1.area_um2 - polyarea(rDisc*cos(th), rDisc*sin(th))) < 1e-9, ...
    'site 1 area %.5f is not the refined disc''s', r1.area_um2);
assert(r1.edited == 1 && startsWith(r1.footprint, 'freehand'), 'site 1 is not marked as refined');
% recount, independently
[nl, nt] = recount(Tb, ed.center, ed.refboundary, win(1,:));
assert(r1.n_loc_inside == nl && r1.n_tracks == nt, ...
    'site 1 reports %d loc / %d trk; a recount on the filtered matrix gives %d / %d', r1.n_loc_inside, r1.n_tracks, nl, nt);
[nlAll, ntAll] = recount(TA, ed.center, ed.refboundary, win(1,:));
assert(nlAll > nl && ntAll == nt + 1, ...
    'the fixture''s rejected track does not sit inside site 1 (%d/%d vs %d/%d) — the test proves nothing', nlAll, ntAll, nl, nt);

%% (4) coordinates say what they are ----------------------------------------------------------------------
assert(abs(r1.x_px - r1.x_um/SF) < 1e-9 && abs(r1.SF_um_per_px - SF) < 1e-12, ...
    'x_px %.4f is not x_um / SF (%.4f)', r1.x_px, r1.x_um/SF);
M = load(fullfile(out,'sites','cellA_refinedsites.mat'));
b1 = M.refinedsites([M.refinedsites.csID] == 1);
assert(max(abs(b1.boundary_um - (ed.refboundary + ed.center)), [], 'all') < 1e-9, ...
    'the exported boundary is not the refined one in absolute um');
rd = fileread(fullfile(out,'README.txt'));
assert(contains(rd,'x_um / SF') && contains(rd,'1 track(s) rejected'), ...
    'the README does not state the pixel convention and the rejected-track count');
A = readtable(fullfile(out,'refinedsites_all.csv'));
assert(height(A) == R.nSites, 'refinedsites_all.csv has %d rows, R.nSites = %d', height(A), R.nSites);

%% (7) the contact sites, as the picker found them ---------------------------------------------------------
P = readtable(fullfile(out,'sites','cellA_contactsites.csv'), 'TextType','string');
assert(height(P) == 3, 'contactsites has %d rows; 3 sites were picked', height(P));
assert(P.deleted_in_refine(P.csID==2) == 1 && P.refined(P.csID==1) == 1 && P.refined(P.csID==3) == 0, ...
    'contactsites does not record what became of each pick (deleted / refined)');
assert(isequal(P.detect_n_loc(:)', [101 102 103]) && isequal(P.detect_enrich(:)', [6 7 8]) ...
        && P.manual(P.csID==3) == 1 && all(P.detect_method == "local"), ...
    'the picker''s own statistics were not joined onto the right sites');
a1 = F0(i1);
assert(abs(P.auto_area_um2(P.csID==1) - a1.areaUm2) < 1e-9, ...
    'site 1''s AUTO area is %.5f; the automatic outline''s is %.5f', P.auto_area_um2(P.csID==1), a1.areaUm2);
assert(abs(P.auto_area_um2(P.csID==1) - r1.area_um2) > 1e-6, ...
    'the automatic and refined areas of site 1 are the same — the contact-site table is showing the refinement');
[nlA, ntA] = recount(Tb, a1.center, a1.refboundary, win(1,:));
assert(P.auto_n_loc_inside(P.csID==1) == nlA && P.auto_n_tracks(P.csID==1) == ntA, ...
    'site 1 auto counts %d / %d; a recount of the automatic outline gives %d / %d', ...
    P.auto_n_loc_inside(P.csID==1), P.auto_n_tracks(P.csID==1), nlA, ntA);
assert(abs(P.pick_x_um(P.csID==1) - 5) < 2e-3 && abs(P.pick_y_um(P.csID==1) - 5) < 2e-3, ...
    'the pick is at (%.4f, %.4f) um; it was made at (5, 5)', P.pick_x_um(P.csID==1), P.pick_y_um(P.csID==1));
M2 = load(fullfile(out,'sites','cellA_contactsites.mat'));
assert(isfield(M2.contactsites,'auto_boundary_um'), 'the contact-site .mat has no automatic outline');
A2 = readtable(fullfile(out,'contactsites_all.csv'));
assert(height(A2) == R.nContact && R.nContact == 3, 'contactsites_all.csv has %d rows, R.nContact = %d', height(A2), R.nContact);

%% (9) self-contained: tracks, member lists, and the script ----------------------------------------------
Tk = load(fullfile(out,'tracks','cellA_tracks.mat')); tk = Tk.tracks;
nKept = size(TA.matrix,2) - 1;                           % every track but the rejected one
assert(size(tk.x_um,2) == nKept && ~ismember(rejCol, tk.build_col), ...
    'tracks/ holds %d track(s) (rejected col %d present: %d); wanted %d without it', ...
    size(tk.x_um,2), rejCol, ismember(rejCol, tk.build_col), nKept);
assert(nnz(isfinite(tk.x_um)) == nnz(isfinite(Tb.matrix(:,:,2))), 'tracks/ does not hold every kept localization');
assert(isequal(tk.x_um(:,1), TA.matrix(:,tk.build_col(1),2)), 'track 1 is not build column %d', tk.build_col(1));
Lc = readtable(fullfile(out,'tracks','cellA_localizations.csv'));
assert(height(Lc) == nnz(isfinite(tk.x_um)) && all(ismember({'track','build_col','frame','x_um','y_um'}, Lc.Properties.VariableNames)), ...
    'the localizations CSV does not list every localization with track/frame/x/y');
% member lists: the .mat vector indexes tracks/, and the CSV string says the same thing
rs = M.refinedsites([M.refinedsites.csID] == 1);
in = false(size(tk.x_um)); okT = isfinite(tk.x_um) & tk.frame >= win(1,1) & tk.frame <= win(1,2);
in(okT) = inpolygon(tk.x_um(okT), tk.y_um(okT), rs.boundary_um(:,1), rs.boundary_um(:,2));
assert(isequal(rs.member_tracks(:)', find(any(in,1))), 'site 1''s member_tracks do not index its members in tracks/');
assert(strcmp(C.member_tracks(C.csID==1), "[" + strjoin(string(rs.member_tracks)," ") + "]"), ...
    'the CSV member list "%s" does not match the .mat', C.member_tracks(C.csID==1));
assert(startsWith(P.auto_member_tracks(P.csID==1), "["), 'auto_member_tracks is not the bracketed text form');
% the script: no pipeline dependency, and it reproduces every site from the export alone
scr = fullfile(out, 'analyse_export_one_cell.m');
deps = matlab.codetools.requiredFilesAndProducts(scr);
assert(isscalar(deps) && strcmp(deps{1}, scr), ...
    'analyse_export_one_cell.m depends on pipeline files, so it will not run on a machine without them: %s', strjoin(deps, ', '));
oldVis = get(groot,'DefaultFigureVisible'); set(groot,'DefaultFigureVisible','off');
restoreVis = onCleanup(@() set(groot,'DefaultFigureVisible',oldVis));
scriptOut = evalc('runExportScript(scr)');
close all force
assert(contains(scriptOut, 'recount exactly') && isfile(fullfile(out,'results_per_site.csv')), ...
    'the shipped script did not complete: %s', scriptOut);
Rs = readtable(fullfile(out,'results_per_site.csv'));
assert(height(Rs) == R.nSites && Rs.n_loc_inside(Rs.csID==1) == nl, ...
    'the script''s results (%d rows, site 1 = %d loc) disagree with the export (%d rows, %d loc)', ...
    height(Rs), Rs.n_loc_inside(Rs.csID==1), R.nSites, nl);

%% (10) normalized metrics, and they agree with the counts ------------------------------------------------
for col = {'prob_mass','peak_prob','local_dens_loc_um2','cell_bg_loc_um2','enrichment','cell_total_loc_win'}
    assert(ismember(col{1}, C.Properties.VariableNames), 'refinedsites has no %s column', col{1});
end
assert(all(isfinite(C.prob_mass)) && all(C.prob_mass > 0 & C.prob_mass <= 1), ...
    'prob_mass is not a fraction: %s', mat2str(C.prob_mass'));
assert(abs(r1.prob_mass - r1.n_loc_inside/r1.cell_total_loc_win) < 1e-12, ...
    'prob_mass %.6g is not n_loc_inside / cell_total_loc_win (%.6g)', r1.prob_mass, r1.n_loc_inside/r1.cell_total_loc_win);
assert(r1.cell_total_loc_win == nnz(isfinite(Tb.matrix(:,:,2)) & Tb.matrix(:,:,1) >= win(1,1) & Tb.matrix(:,:,1) <= win(1,2)), ...
    'cell_total_loc_win (%d) is not the cell''s localization count in that window', r1.cell_total_loc_win);
assert(r1.enrichment > 2 && isfinite(r1.cell_bg_loc_um2) && r1.local_dens_loc_um2 > r1.cell_bg_loc_um2, ...
    'a planted cluster reports enrichment %.3g over background %.3g', r1.enrichment, r1.cell_bg_loc_um2);
assert(ismember('auto_prob_mass', P.Properties.VariableNames) && ismember('auto_enrichment', P.Properties.VariableNames), ...
    'contactsites carries no normalized metrics for the automatic outline');
assert(P.auto_prob_mass(P.csID==2) > 0, 'a site deleted on Refine still gets its automatic metrics');
fprintf('normalized: site 1 prob_mass %.4f of %d window locs · enrichment %.1f× over bg %.3g loc/µm²\n', ...
    r1.prob_mass, r1.cell_total_loc_win, r1.enrichment, r1.cell_bg_loc_um2);

%% (8) an existing name is refused ------------------------------------------------------------------------------
try
    cs_advisor_export(ana, struct('fovUm',fov,'binNm',bin,'name','run_1_first_look'));
    error('smoke:noRefusal', 'exporting again under an existing name wrote into it');
catch ME
    assert(strcmp(ME.identifier, 'cs_advisor_export:exists'), ...
        'exporting under an existing name failed for the wrong reason: %s', ME.message);
end
assert(strcmp(cs_advisor_export_name('  ../..//x  '), 'x'), 'a name can climb out of exports/: "%s"', cs_advisor_export_name('  ../..//x  '));

%% (6) the cell filter ----------------------------------------------------------------------------------------
R2 = cs_advisor_export(ana, struct('fovUm',fov,'binNm',bin,'cells',{{'cellB'}},'name','filter_check'));
assert(R2.nCells == 0 && any(contains(R2.skipped,'cellB')), ...
    'exporting only cellB (no saved sites) gave %d cell(s) and no reason', R2.nCells);

fprintf('site 1: %d loc / %d trk inside the refined disc (%d / %d with the rejected track) · auto outline %d / %d · site 2 deleted: flagged in contactsites, absent from refinedsites\n', ...
    nl, nt, nlAll, ntAll, nlA, ntA);
fprintf('\nADVISOR-EXPORT SMOKE PASSED.\n');
end

% ================================================================================================
function [T, rejCol] = mkCell(name, fov, bin)
rng(sum(double(name)));
nF = 60; tracks = {};
for j = 1:10, tracks{end+1} = [5 5] + 0.03*cumsum(randn(nF,2))/4; end         %#ok<AGROW> site 1 / 3
for j = 1:6,  tracks{end+1} = [9 9] + 0.03*cumsum(randn(nF,2))/4; end         %#ok<AGROW> site 2
for j = 1:15, tracks{end+1} = 2 + 8*rand(1,2) + 0.05*cumsum(randn(nF,2))/4; end %#ok<AGROW> scatter
tracks{end+1} = [5 5] + 0.01*cumsum(randn(nF,2))/4;                             % the one to reject
rejCol = numel(tracks);
nT = numel(tracks);
X = nan(nF,nT); Y = nan(nF,nT);
for j = 1:nT, X(:,j) = tracks{j}(:,1); Y(:,j) = tracks{j}(:,2); end
Fr = repmat((0:nF-1)',1,nT);
cx = 12 + 0.02*randn(400,1); cy = 12 + 0.02*randn(400,1);                      % untracked detections only
T = struct('file',name,'matrix',cat(3,Fr,X,Y),'frameInterval',0.02, ...
    'lengths',repmat(nF,nT,1),'trackIDs',(1:nT)', ...
    'allSpots',struct('X',[X(:); cx],'Y',[Y(:); cy],'FRAME',[Fr(:); zeros(400,1)]), ...
    'calib',struct('fovUm',fov,'binNm',bin,'pixSizeUm',0.16,'dt_s',0.02,'precNm',bin));
end

function runExportScript(scr)
% run() executes the script in THIS workspace, away from the smoke's own variables.
run(scr);
end

function [nl, nt] = recount(T, c, rb, wf)
A = T.matrix(:,:,2); B = T.matrix(:,:,3); Fr = T.matrix(:,:,1);
ok = isfinite(A) & isfinite(B) & Fr >= wf(1) & Fr <= wf(2);
in = false(size(A)); in(ok) = inpolygon(A(ok)-c(1), B(ok)-c(2), rb(:,1), rb(:,2));
nl = nnz(in); nt = nnz(any(in,1));
end
