function cs_advisor_format_smoke()
%CS_ADVISOR_FORMAT_SMOKE  The export's advisor_format/ must be the lab's published ContactSites layout
%(the VAPB dataset) - same files, same variables, same fields in the same order, same spreadsheet
%columns - with every value computed the way the original scripts compute it.
%
% WHAT IS ASSERTED:
%   1. THE FILES AND THEIR NAMES, one set per Experiment-tab condition.
%   2. THE STRUCTURE: CS, Tracks, EC, BindingInfo field names IN ORDER, EllipseFit and boundaries
%      sub-fields, spreadsheet sheet names and headers (hard-coded from the VAPB files, so this does
%      not need them). The original's scripts reorder fields by hard-coded position.
%   3. THE DEFINITIONS, recomputed independently: the 1.024 um square around the ORIGINAL pick
%      (LocIDs, tracks), localizations inside the refined outline in both index spaces (refLocIDs,
%      CSLocIDs) and their relation, neighbours = square minus outline, CSmatrix centred on the
%      REFINED centre, refboundary in nm, EllipseFit in the refiner's 3 nm pixels.
%   4. EC as GenerateEnrichmentStruct.m defines it, and the per-cell sheet as the published one
%      computes it (MCSprob, OCSprob, MitoEnrichCoeff).
%   5. THE ALIGNMENT FIX: every column of a StepEnrichmentByCS row describes the same site. The
%      original script pairs a row's size and area with a different site's step count.
%   6. NOT-MEASURED IS BLANK: binding, JBM and ChrisC columns are empty, not 0.
%   8. THE IMAGING SETTINGS ARE STATED. This data's pixel size, field, frame interval and bin are
%      written per cell, and the README lists every constant in the original scripts that assumes
%      a different instrument (20.48 um, 27.61 um, 0.011 s) with the value to use instead.
%   7. IF THE ORIGINAL SCRIPTS ARE ON DISK, they run on these files and agree:
%      GenerateEnrichmentStruct reproduces EC exactly; ExportCSstructStatsv3's computable columns match.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));          % the two tools share the build, the channels and the manifest
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'), ...
        fullfile(root_,'tool3_contactsites','app'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_advfmt_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
ana = fullfile(proj,'analysis'); mkdir(fullfile(ana,'csIDs'));
cleanup = onCleanup(@() rmdir(proj,'s'));

fov = 16; bin = 30; n = ceil(fov/(bin/1000)); SF = fov/n;
TA = mkCell('cellA', fov, bin, 3); TB = mkCell('cellB', fov, bin, 4);
Tracks = [TA TB]; %#ok<NASGU>
save(fullfile(ana,'TrackStruct.mat'),'Tracks','-v7.3');
calib = struct('pixSizeUm',0.16,'fovUm',fov,'dt_s',0.02,'binNm',bin,'snapFovUm',fov); %#ok<NASGU>
save(fullfile(ana,'cs_calib.mat'),'calib');
% picks: cellA has a mito site (5,5) and an other site (9,9); cellB only a mito site (no other sites,
% the case where the published sheet leaves MitoEnrichCoeff blank)
writePicks(ana, 'cellA', [5 5 1; 9 9 2], SF);
writePicks(ana, 'cellB', [5 5 1], SF);
% the window file the picker always saves alongside the picks: it carries the grid the picks are on
windows = struct('framesPerWindow',60,'nWindows',1,'ranges',[0 59],'grid',n,'SF_umPerPx',SF, ...
                 'frameInterval',0.02,'source','tracked'); %#ok<NASGU>
save(cs_ana_path(ana,'density','Density_cellA_CSwindows.mat'),'windows');
save(cs_ana_path(ana,'density','Density_cellB_CSwindows.mat'),'windows');
% refine cellA site 1 to a disc centred off the pick, so refCenter differs from the pick
F0 = cs_footprints_build(ana, struct('save',false,'verbose',false));
k1 = find(strcmp({F0.file},'cellA') & [F0.csID]==1);
th = linspace(0,2*pi,80)'; ed = F0(k1); ed.center = [5.04 4.97]; ed.refboundary = 0.25*[cos(th) sin(th)];
ed.mode = 'freehand'; ed.areaUm2 = polyarea(ed.refboundary(:,1), ed.refboundary(:,2)); ed.edited = true;
CSfoot = ed; CSdeleted = struct('file',{},'csID',{},'window',{},'pickPx',{}); %#ok<NASGU>
save(fullfile(ana,'CS_footprints.mat'),'CSfoot','CSdeleted','-v7.3');

cond = containers.Map({'cellA','cellB'}, {'VAPB','VAPB'});
R = cs_advisor_export(ana, struct('fovUm',fov,'binNm',bin,'name','run','conditions',cond));
d = fullfile(R.outDir, 'advisor_format', 'VAPB');

%% (1) files ----------------------------------------------------------------------------------------------
want = {'CS_final_v3.mat','VAPB_Tracks_finalv3.mat','VAPB_EC.mat','BindingInfo.mat','CS_details_v2.xlsx', ...
        'VAPB-CSstats.xlsx','VAPB-EnrichmentCoefficients.xlsx','VAPB-BindingTable.xlsx','README_advisor_format.txt'};
for q = 1:numel(want), assert(isfile(fullfile(d, want{q})), 'advisor_format/VAPB is missing %s', want{q}); end
assert(isscalar(R.advisor) && R.advisor.nCells == 2 && R.advisor.nCS == 3 && R.advisor.nMito == 2, ...
    'one condition set with 2 cells / 3 sites / 2 mito expected');

%% (2) structure, in the published order ----------------------------------------------------------------
L = load(fullfile(d,'CS_final_v3.mat')); CS = L.CS;
L = load(fullfile(d,'VAPB_Tracks_finalv3.mat')); TR = L.Tracks;
L = load(fullfile(d,'VAPB_EC.mat')); EC = L.EC;
L = load(fullfile(d,'BindingInfo.mat')); BI = L.BindingInfo;
csF = {'CS_index','CSindex','file','cellIndex','csID','tracks','tracksCCids','trackBinding','NumEntry', ...
       'NumExit','refCenter','refboundary','boundaries','EllipseFit','LocIDs','refLocIDs','neighborIDs', ...
       'CSLocIDs','CSneighborIDs','CSmatrix','CSvec','Deff','TessIndex','refDeff','neighborDeff','segIDs', ...
       'ChPts','DwellTimes','MitoFlag'};
trF = {'file','cellIndex','lengths','matrix','center','rawSteps','steps','MSDdata','MSD','MSDerror','CSD', ...
       'CSDnorm','MSDstdev','rawVector','vector','JBM','LocIndex','Deff','CSindexes','MitoCSindex','CCindex', ...
       'segNum','segID','cp','MCSindex','OCSindex'};
ecF = {'cellIndex','NumMCSs','NumOCSs','MCSsteps','OCSsteps','TotalSteps','MCStracks','OCStracks','FreeTracks'};
assert(isequal(fieldnames(CS)', csF), 'CS fields/order differ from CS_final_v3.mat: %s', strjoin(fieldnames(CS)',','));
assert(isequal(fieldnames(TR)', trF), 'Tracks fields/order differ from the published Tracks: %s', strjoin(fieldnames(TR)',','));
assert(isequal(fieldnames(EC)', ecF), 'EC fields/order differ from VAPB_EC.mat');
assert(isequal(fieldnames(BI)', {'csID','trackBinding','DwellTimesData','CS_index'}), 'BindingInfo fields differ');
assert(isequal(fieldnames(CS(1).EllipseFit)', {'Centroid','MajorAxisLength','MinorAxisLength','Orientation'}) && ...
       isequal(fieldnames(CS(1).boundaries)', {'x','y'}), 'EllipseFit / boundaries sub-fields differ');
assert(all(endsWith({CS.file}, '_Tracks')) && all(endsWith({TR.file}, '_Tracks')), ...
    'file must end in _Tracks: the original scripts strip 7 characters to get the cell name');
chkHdr(fullfile(d,'CS_details_v2.xlsx'), 'Sheet1', {'CS_Number','CS_Legacy','cellIndex','csID','numTracks', ...
    'numBoundTracks','numNPBtracks','numSegIDs','numChPts','numBindEvents','numEntry','numExit','numRebind', ...
    'MajorAx','MinorAx','Angle','Area','Din','inNum','Dout','outNum','MitoFlag'});
chkHdr(fullfile(d,'VAPB-EnrichmentCoefficients.xlsx'), 'StepEnrichmentByCS', {'CellIndex','MitoFlag', ...
    'NumMCSsteps','NumOCSsteps','TotalSteps','CSsize_1','CSsize_2','CSarea','CS_Deff','CS_Neighbor'});
chkHdr(fullfile(d,'VAPB-EnrichmentCoefficients.xlsx'), 'EnrichmentByCell', {'Cell','NumMCStracks', ...
    'NumOCStracks','TotalTracks','NumMCSstepsCell','NumOCSstepsCell','TotalStepsPerCell','','','MCSprob', ...
    'OCSprob','','MitoEnrichCoeff'});
chkHdr(fullfile(d,'VAPB-BindingTable.xlsx'), 'Sheet1', {'CS Index','Track ID','Interaction #','Entry?', ...
    'Exit?','DwellTime','CS size_1','CS size_2','CSarea','CS_Deff','CS_Neighbor','CS_MitoFlag'});
chkHdr(fullfile(d,'VAPB-CSstats.xlsx'), 'Sheet1', {'Row','MitoCS','OtherCS','TotalCS','',''});

%% (3) definitions, recomputed -------------------------------------------------------------------------------
c = CS([CS.cellIndex]==1 & [CS.csID]==1);           % the refined mito site
t = TR(1); A = t.matrix(:,:,2); B = t.matrix(:,:,3);
pick = [5 5];
assert(max(abs([c.boundaries.x c.boundaries.y] - [pick(1)+[-0.512 0.512] pick(2)+[-0.512 0.512]])) < 2e-3, ...
    'boundaries are not the 1.024 um square around the ORIGINAL pick: %s %s', mat2str(c.boundaries.x,4), mat2str(c.boundaries.y,4));
inBox = A >= c.boundaries.x(1) & A <= c.boundaries.x(2) & B >= c.boundaries.y(1) & B <= c.boundaries.y(2);
assert(isequal(sort(c.LocIDs(:)), find(inBox)) && isequal(c.tracks, find(any(inBox,1))), 'LocIDs / tracks are not the square''s');
assert(max(abs(c.refCenter - [5.04 4.97])) < 1e-12, 'refCenter is not the refined centre');
assert(max(abs(c.refboundary - 1000*ed.refboundary), [], 'all') < 1e-9, 'refboundary is not nm relative to refCenter');
X = A(:, c.tracks); Y = B(:, c.tracks); ok = isfinite(X);
inP = false(size(X)); inP(ok) = inpolygon(X(ok), Y(ok), 5.04 + 0.25*cos(th), 4.97 + 0.25*sin(th));
assert(isequal(c.CSLocIDs, find(inP)), 'CSLocIDs are not the member localizations inside the outline');
[m, nn] = ind2sub(size(X), c.CSLocIDs);
assert(isequal(c.refLocIDs, sub2ind(size(A), m, c.tracks(nn)')), 'refLocIDs are not CSLocIDs mapped into the cell''s matrix');
assert(isequal(c.neighborIDs, setdiff(c.LocIDs, c.refLocIDs)), 'neighborIDs ~= LocIDs minus refLocIDs');
[m2, n2] = ind2sub(size(X), c.CSneighborIDs);
assert(isequal(sort(sub2ind(size(A), m2, c.tracks(n2)')), c.neighborIDs), 'CSneighborIDs do not map onto neighborIDs');
assert(max(abs(c.CSmatrix(:,:,2) - (X - 5.04)), [], 'all', 'omitnan') < 1e-12, 'CSmatrix is not centred on refCenter');
ef = c.EllipseFit;
assert(abs(3*ef.MajorAxisLength - 500) < 12 && abs(3*ef.MinorAxisLength - 500) < 12, ...
    'a 0.25 um-radius disc should fit a ~500 nm ellipse in 3 nm pixels; got %.0f x %.0f nm', 3*ef.MajorAxisLength, 3*ef.MinorAxisLength);
assert(max(abs(ef.Centroid - (400 + ([5.04 4.97] - pick)/0.003))) < 1.5, ...
    'EllipseFit centroid %s is not in the refiner''s frame (pixel 400 = original pick)', mat2str(ef.Centroid,5));

%% (4) EC and the per-cell sheet ------------------------------------------------------------------------------
assert(isequal(TR(1).MCSindex, c.CS_index) && EC(1).NumMCSs == 1 && EC(1).NumOCSs == 1 && EC(2).NumMCSs == 1 && EC(2).NumOCSs == 0, ...
    'MCS/OCS indexing is wrong');
assert(EC(1).MCSsteps == numel(c.refLocIDs) && EC(1).TotalSteps == nnz(isfinite(A)), 'EC step counts are wrong');
assert(isequal(EC(1).FreeTracks, setdiff(1:numel(t.lengths), [EC(1).MCStracks EC(1).OCStracks])), 'FreeTracks is wrong');
Eb = readcell(fullfile(d,'VAPB-EnrichmentCoefficients.xlsx'), 'Sheet','EnrichmentByCell');
row = Eb(2,:);
assert(row{4} == numel(EC(1).FreeTracks) && abs(row{10} - row{5}/row{7}) < 1e-12 && abs(row{13} - row{10}/row{11}) < 1e-12, ...
    'EnrichmentByCell: TotalTracks / MCSprob / MitoEnrichCoeff not as the published sheet computes them');
assert(ismissing(Eb{3,13}) && Eb{3,11} == 0, 'a cell with no other sites (OCSprob 0) must leave MitoEnrichCoeff blank, not divide by zero');

%% (5) StepEnrichmentByCS is aligned -----------------------------------------------------------------------------
St = readtable(fullfile(d,'VAPB-EnrichmentCoefficients.xlsx'), 'Sheet','StepEnrichmentByCS');
order = [TR(1).MCSindex TR(1).OCSindex TR(2).MCSindex TR(2).OCSindex];
stp = St.NumMCSsteps; stp(isnan(stp)) = St.NumOCSsteps(isnan(stp));
assert(isequal(stp, arrayfun(@(k) numel(CS(k).refLocIDs), order)') && ...
       all(abs(St.CSarea - arrayfun(@(k) polyarea(CS(k).refboundary(:,1), CS(k).refboundary(:,2)), order)') < 1e-6), ...
    'a StepEnrichmentByCS row mixes one site''s steps with another''s area');

%% (6) not measured is blank ---------------------------------------------------------------------------------------
D = readcell(fullfile(d,'CS_details_v2.xlsx'));
h = D(1,:);
for col = {'numBoundTracks','numNPBtracks','numSegIDs','numChPts','numBindEvents','numEntry','numExit','numRebind','Din','Dout','CS_Legacy'}
    v = D(2:end, strcmp(h, col{1}));
    assert(all(cellfun(@ismissing, v)), 'CS_details %s should be blank (not measured), not %s', col{1}, class(v{1}));
end
assert(numel(BI) == 0 && isempty(CS(1).trackBinding), 'binding fields must be empty until annotated');
rd = fileread(fullfile(d,'README_advisor_format.txt'));
assert(contains(rd,'0.011') && contains(rd,'DwellTimeManual') && contains(rd,'60 of 307'), ...
    'the README must warn about the hard-coded 0.011 s frame interval and name the alignment fix');

%% (8) imaging settings ---------------------------------------------------------------------------------------------
Im = readtable(fullfile(d,'imaging_settings.csv'), 'TextType','string');
assert(height(Im) == 2 && all(abs(Im.pixel_um - 0.16) < 1e-12) && all(abs(Im.fov_um - fov) < 1e-12) && ...
       all(abs(Im.frame_interval_s - 0.02) < 1e-12) && all(Im.density_bin_nm == bin) && all(Im.width_px == 101) && ...
       all(abs(Im.full_width_um - 101*0.16) < 1e-9), ...
    'imaging_settings.csv does not carry this data''s own pixel size / field / frame interval / bin');
for k = {'ContactSiteMapper.m:28','20.48','DensityVisualization.m:12','27.61','DwellTimeManual.m:38', ...
         'EntryExitManualClassifierv2.m:40,51','use 0.02','use 16','0.160 um (20.48 um / 128 px)'}
    assert(contains(rd, k{1}), 'the README does not name "%s" - the constants that assume another instrument', k{1});
end

%% (7) the original scripts, if they are on this machine ----------------------------------------------------------
orig = fullfile(fileparts(fileparts(fileparts(here))), 'SPT_ContactSites_Pipeline', 'ContactSites_original', 'Final', 'Revision');
if isfolder(orig)
    addpath(orig); rmo = onCleanup(@() rmpath(orig));
    assert(isequaln(GenerateEnrichmentStruct(TR, CS), EC), 'the original GenerateEnrichmentStruct does not reproduce EC');
    old = pwd; tmp = tempname; mkdir(tmp); cd(tmp); back = onCleanup(@() cd(old));
    Th = ExportCSstructStatsv3(CS);
    Ou = readtable(fullfile(d,'CS_details_v2.xlsx'));
    for col = {'CS_Number','cellIndex','csID','numTracks','MajorAx','MinorAx','Angle','Area','inNum','outNum','MitoFlag'}
        assert(max(abs(double(Th.(col{1})) - double(Ou.(col{1})))) < 1e-6, 'original ExportCSstructStatsv3 disagrees on %s', col{1});
    end
    fprintf('original scripts: GenerateEnrichmentStruct reproduces EC; ExportCSstructStatsv3 agrees\n');
else
    fprintf('original scripts not found at %s - part 7 skipped\n', orig);
end

fprintf('advisor_format/VAPB: %d cells, %d sites (2 mito) · fields in published order · definitions recomputed · rows aligned\n', ...
    R.advisor.nCells, R.advisor.nCS);
fprintf('\nADVISOR-FORMAT SMOKE PASSED.\n');
end

% ================================================================================================
function T = mkCell(name, fov, bin, seed)
rng(seed); nF = 60; tracks = {};
for j = 1:8,  tracks{end+1} = [5 5] + 0.03*cumsum(randn(nF,2))/4; end            %#ok<AGROW>
for j = 1:5,  tracks{end+1} = [9 9] + 0.03*cumsum(randn(nF,2))/4; end            %#ok<AGROW>
for j = 1:10, tracks{end+1} = 2 + 10*rand(1,2) + 0.05*cumsum(randn(nF,2))/4; end %#ok<AGROW>
nT = numel(tracks); X = nan(nF,nT); Y = X;
for j = 1:nT, X(:,j) = tracks{j}(:,1); Y(:,j) = tracks{j}(:,2); end
Fr = repmat((0:nF-1)',1,nT);
st = hypot(diff(X), diff(Y));
T = struct('file',name,'lengths',repmat(nF,nT,1),'matrix',cat(3,Fr,X,Y), ...
    'center',cat(3,Fr,X-X(1,:),Y-Y(1,:)),'rawSteps',cat(3,ones(nF-1,nT),st),'steps',st,'MSDdata',[], ...
    'MSD',st.^2,'MSDerror',zeros(nF-1,nT),'MSDstdev',zeros(nF-1,nT),'CSD',cumsum(st),'CSDnorm',cumsum(st)./sum(st), ...
    'rawVector',cat(3,diff(X),diff(Y)),'vector',cat(3,diff(X),diff(Y)),'frameInterval',0.02,'trackIDs',(1:nT)', ...
    'allSpots',struct('X',X(:),'Y',Y(:),'FRAME',Fr(:)), ...
    'calib',struct('fovUm',fov,'binNm',bin,'pixSizeUm',0.16,'dt_s',0.02,'precNm',bin));
end

function writePicks(ana, base, P, SF)
fid = fopen(fullfile(ana,'csIDs',[base '_CSsites.txt']),'w');
fprintf(fid,' \tX\tY\tXM\tYM\tSlice\tCounter\tCount\n');
for j = 1:size(P,1)
    fprintf(fid,'%d\t%.3f\t%.3f\t%.3f\t%.3f\t%d\t%d\t%d\n', j, P(j,1)/SF, P(j,2)/SF, P(j,1)/SF, P(j,2)/SF, 1, P(j,3), 0);
end
fclose(fid);
end

function chkHdr(f, sheet, want)
C = readcell(f, 'Sheet', sheet);
got = C(1,:); got(cellfun(@(v) ~ischar(v) && ~isstring(v), got)) = {''};
got = cellfun(@char, got, 'uni', 0);
assert(isequal(got, want), '%s / %s header is [%s], the published one is [%s]', f, sheet, strjoin(got,' | '), strjoin(want,' | '));
end
