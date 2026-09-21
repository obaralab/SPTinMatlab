function R = cs_advisor_format(outDir, label, cells, opts)
%CS_ADVISOR_FORMAT  One condition's contact sites written in the layout of the lab's published
%ContactSites analysis (the VAPB dataset), so they open and read exactly like it.
%
%   R = cs_advisor_format(outDir, label, cells, opts)
%
% Writes, into outDir, the same eight files the VAPB folder holds, under the same names (label
% takes the place of "VAPB"):
%
%   CS_final_v3.mat              variable CS           one element per contact site
%   <label>_Tracks_finalv3.mat   variable Tracks       one element per cell
%   <label>_EC.mat               variable EC           per-cell enrichment counts
%   BindingInfo.mat              variable BindingInfo  per-site binding annotation
%   CS_details_v2.xlsx           one row per site
%   <label>-CSstats.xlsx         one row per cell, then totals and averages
%   <label>-EnrichmentCoefficients.xlsx   sheets StepEnrichmentByCS, EnrichmentByCell
%   <label>-BindingTable.xlsx    one row per binding interaction
%   README_advisor_format.txt    what is filled, what is empty and why, and the parameters used
%
% Every field keeps its original name, order and definition. The definitions are taken from the
% original scripts in SPT_ContactSites_Pipeline/ContactSites_original, and each is cited below at
% the line that computes it. Where the original ran an analysis this pipeline does not (JBM
% tessellation diffusion maps, the ChrisC trajectory segmentation, and the binding / dwell times,
% which were annotated BY HAND with DwellTimeManual.m and EntryExitManualClassifierv2.m), the
% field is present and empty — never filled with a different quantity under the original's name.
%
% cells(c)  .base   cell file name
%           .T      that cell's TrackStruct element, hand-rejected tracks already removed
%           .sites  the refined sites kept for the cell (cs_footprints_resolve records): csID,
%                   center (um), refboundary (um, rel. centre), pickPx, SF, winFrames, mito
% opts      .boxUm  (1.024) full width of the square neighbourhood around each ORIGINAL pick.
%                   ContactSiteMapper.m takes +/-30 density pixels; on the VAPB grid that was
%                   exactly 1.024 um, and CS_refiner_v2_wacom.m calls it "1.024 for analysis".
%                   Kept in microns here so the neighbourhood means the same thing on any grid.
%           .frameInterval_s  for the README (the original dwell scripts hard-code 0.011 s)
%
% R: .nCells .nCS .nMito .files

if nargin < 4 || ~isstruct(opts), opts = struct(); end
boxUm = getf(opts, 'boxUm', 1.024);
dtS   = getf(opts, 'frameInterval_s', NaN);
if ~isfolder(outDir), mkdir(outDir); end
lab = cs_advisor_export_name(label); if isempty(lab), lab = 'condition'; end

nCells = numel(cells);
CS = csTemplate(); CS = CS([]);
Tracks = tracksTemplate(); Tracks = Tracks([]);
cellCS = cell(1, nCells);                     % global CS indices per cell
g = 0;
for c = 1:nCells
    T = cells(c).T;
    M = T.matrix; A = M(:,:,2); B = M(:,:,3); Fr = M(:,:,1);
    okxy = isfinite(A) & isfinite(B);
    fileTag = [cells(c).base '_Tracks'];      % the original's file names end in _Tracks, and its
                                              % scripts strip 7 characters to get the base
    S = cells(c).sites;
    idx = zeros(1, numel(S));
    for j = 1:numel(S)
        e = S(j); g = g + 1; idx(j) = g;
        pick = e.pickPx(:)' * e.SF;           % ContactSiteMapper.m: center = [Xpix*SF Ypix*SF]
        rc = e.center(:)';
        if isinf(e.winFrames(1)) && isinf(e.winFrames(2)), inW = true(size(Fr));
        else, inW = Fr >= e.winFrames(1) & Fr <= e.winFrames(2); end

        % ContactSiteMapper.m: the square around the pick, the tracks in it, their localizations
        bx = pick(1) + [-1 1]*boxUm/2;  by = pick(2) + [-1 1]*boxUm/2;
        inBox = okxy & inW & A >= bx(1) & A <= bx(2) & B >= by(1) & B <= by(2);
        trk = find(any(inBox, 1));
        LocIDs = find(inBox);

        % CS_refiner_v2_wacom.m: localizations of those tracks inside the drawn outline, first in
        % the tracks' own M x N space (CSLocIDs), then mapped into the cell's (refLocIDs)
        pbx = e.refboundary(:,1) + rc(1);  pby = e.refboundary(:,2) + rc(2);
        X = A(:, trk); Y = B(:, trk);
        okCS = isfinite(X) & isfinite(Y) & inW(:, trk);
        sub = false(size(X));
        sub(okCS) = inpolygon(X(okCS), Y(okCS), pbx, pby);
        CSLocIDs = find(sub);
        [mm, nn] = ind2sub(size(X), CSLocIDs);
        refLocIDs = sub2ind(size(A), mm(:), reshape(trk(nn), [], 1));
        % CS_builder.m: neighbours = in the square but outside the outline
        neighborIDs = setdiff(LocIDs, refLocIDs);
        CSneighborIDs = find(inBox(:, trk) & ~sub);

        r = csTemplate();
        r.CS_index = g;
        r.CSindex = [];                       % legacy index from the original revisions: none
        r.file = fileTag;
        r.cellIndex = c;
        r.csID = e.csID;
        r.tracks = trk;
        r.tracksCCids = NaN(1, numel(trk));   % ChrisC analysis: not run
        r.trackBinding = [];                  % binding: annotated by hand in the original
        r.NumEntry = [];
        r.NumExit = [];
        r.refCenter = rc;
        r.refboundary = e.refboundary * 1000; % CS_refiner_v2_wacom.m: nm, relative to refCenter
        r.boundaries = struct('x', bx, 'y', by);
        r.EllipseFit = ellipseFit(pbx, pby, pick);
        r.LocIDs = LocIDs;
        r.refLocIDs = refLocIDs;
        r.neighborIDs = neighborIDs;
        r.CSLocIDs = CSLocIDs;
        r.CSneighborIDs = CSneighborIDs;
        % CS_builder.m: the tracks re-centred on refCenter, whole tracks, and their step vectors
        r.CSmatrix = cat(3, Fr(:, trk), A(:, trk) - rc(1), B(:, trk) - rc(2));
        r.CSvec = fieldOr(T, 'vector', [], trk);
        r.Deff = NaN(size(X));                % JBM tessellation: not run
        r.TessIndex = NaN(size(X));
        r.refDeff = NaN(numel(refLocIDs), 1);
        r.neighborDeff = NaN(numel(neighborIDs), 1);
        r.segIDs = NaN(size(X));              % ChrisC segmentation: not run
        r.ChPts = zeros(size(X));
        r.DwellTimes = [];
        r.MitoFlag = logical(e.mito);
        CS(g) = r; %#ok<AGROW>
    end
    cellCS{c} = idx;

    t = tracksTemplate();
    t.file = fileTag;
    t.cellIndex = c;
    for f = {'lengths','matrix','center','rawSteps','steps','MSDdata','MSD','MSDerror','CSD', ...
             'CSDnorm','MSDstdev','rawVector','vector'}
        t.(f{1}) = fieldOr(T, f{1}, [], []);
    end
    t.JBM = struct('x',{{}},'y',{{}},'D',[],'n',[],'center_x',[],'center_y',[], ...
                   'voronoi_x',{{}},'voronoi_y',{{}},'neighbors',{{}});   % JBM: not run
    t.LocIndex = NaN(size(A));
    t.Deff = NaN(size(A));
    fl = [CS(idx).MitoFlag];
    t.CSindexes = [];                         % legacy mito-only numbering: none
    t.MitoCSindex = idx(fl);
    t.CCindex = NaN(size(A));                 % ChrisC: not run
    t.segNum = NaN(size(A));
    t.segID = NaN(size(A));
    t.cp = zeros(size(A));
    t.MCSindex = idx(fl);                     % CSindiciesByFlag.m
    t.OCSindex = idx(~fl);
    Tracks(c) = t; %#ok<AGROW>
end

% GenerateEnrichmentStruct.m
EC = struct('cellIndex',{},'NumMCSs',{},'NumOCSs',{},'MCSsteps',{},'OCSsteps',{}, ...
            'TotalSteps',{},'MCStracks',{},'OCStracks',{},'FreeTracks',{});
for c = 1:nCells
    t = Tracks(c);
    e = struct();
    e.cellIndex = t.cellIndex;
    e.NumMCSs = numel(t.MCSindex);
    e.NumOCSs = numel(t.OCSindex);
    e.MCSsteps = arrayfun(@(k) numel(CS(k).refLocIDs), t.MCSindex);
    e.OCSsteps = arrayfun(@(k) numel(CS(k).refLocIDs), t.OCSindex);
    e.TotalSteps = sum(isfinite(t.matrix(:,:,2)), 'all');
    e.MCStracks = unique([CS(t.MCSindex).tracks]);
    e.OCStracks = unique([CS(t.OCSindex).tracks]);
    e.FreeTracks = setdiff(1:numel(t.lengths), [e.MCStracks, e.OCStracks]);
    EC(c) = e; %#ok<AGROW>
end

% BindingInfo.mat (AssembleDwellTimesData.m): filled only after the hand annotation
BindingInfo = reshape(struct('csID',{},'trackBinding',{},'DwellTimesData',{},'CS_index',{}), 1, 0); %#ok<NASGU>

f1 = fullfile(outDir, 'CS_final_v3.mat');            save(f1, 'CS', '-v7');
f2 = fullfile(outDir, [lab '_Tracks_finalv3.mat']);  save(f2, 'Tracks', '-v7');
f3 = fullfile(outDir, [lab '_EC.mat']);              save(f3, 'EC');
f4 = fullfile(outDir, 'BindingInfo.mat');            save(f4, 'BindingInfo');

writeDetails(fullfile(outDir, 'CS_details_v2.xlsx'), CS);
writeCSstats(fullfile(outDir, [lab '-CSstats.xlsx']), cells, Tracks);
writeEnrichment(fullfile(outDir, [lab '-EnrichmentCoefficients.xlsx']), CS, EC, Tracks);
writeBindingTable(fullfile(outDir, [lab '-BindingTable.xlsx']));
writeReadme(fullfile(outDir, 'README_advisor_format.txt'), lab, CS, EC, boxUm, dtS);

R = struct('nCells', nCells, 'nCS', numel(CS), 'nMito', nnz([CS.MitoFlag]), 'label', lab, ...
           'files', {{f1, f2, f3, f4}});
end

% =================================================================================================
function s = ellipseFit(pbx, pby, pick)
% CS_refiner_v2_wacom.m: the outline is drawn on an 81 x 81 px crop at 30 nm magnified x10 - 3 nm
% per image pixel - where image coordinate p is (p - 400) x 3 nm from the ORIGINAL pick, and
% EllipseFit = regionprops of the outline's mask there. So Centroid is in those pixels and the axis
% lengths are in those pixels (x 3 = nm). The canvas is grown when an outline is larger than the
% original crop, which could not have held it; the pixel coordinate system is unchanged.
s = struct('Centroid', [NaN NaN], 'MajorAxisLength', NaN, 'MinorAxisLength', NaN, 'Orientation', NaN);
px = 400 + (pbx - pick(1)) / 0.003;
py = 400 + (pby - pick(2)) / 0.003;
if numel(px) < 3 || any(~isfinite([px; py])), return; end
sh = max(0, 4 - floor(min([px; py])));
W  = max(810 + sh, ceil(max([px; py])) + sh + 4);
bw = poly2mask(px + sh, py + sh, W, W);
bw = imclearborder(bw);
bw = bwareafilt(bw, 1);
if ~any(bw(:)), return; end
q = regionprops(bw, {'Centroid','Orientation','MajorAxisLength','MinorAxisLength'});
q.Centroid = q.Centroid - sh;
s = q;
end

function v = fieldOr(T, f, d, cols)
v = d;
if ~isfield(T, f) || isempty(T.(f)), return; end
v = T.(f);
if ~isempty(cols), v = v(:, cols, :); end
end

function r = csTemplate()
% The field ORDER of CS_final_v3.mat: scripts downstream call orderfields with hard-coded positions.
r = struct('CS_index',[],'CSindex',[],'file','','cellIndex',[],'csID',[],'tracks',[], ...
    'tracksCCids',[],'trackBinding',[],'NumEntry',[],'NumExit',[],'refCenter',[],'refboundary',[], ...
    'boundaries',[],'EllipseFit',[],'LocIDs',[],'refLocIDs',[],'neighborIDs',[],'CSLocIDs',[], ...
    'CSneighborIDs',[],'CSmatrix',[],'CSvec',[],'Deff',[],'TessIndex',[],'refDeff',[], ...
    'neighborDeff',[],'segIDs',[],'ChPts',[],'DwellTimes',[],'MitoFlag',false);
end

function t = tracksTemplate()
% The field ORDER of VAPB_Tracks_finalv3.mat.
t = struct('file','','cellIndex',[],'lengths',[],'matrix',[],'center',[],'rawSteps',[],'steps',[], ...
    'MSDdata',[],'MSD',[],'MSDerror',[],'CSD',[],'CSDnorm',[],'MSDstdev',[],'rawVector',[], ...
    'vector',[],'JBM',[],'LocIndex',[],'Deff',[],'CSindexes',[],'MitoCSindex',[],'CCindex',[], ...
    'segNum',[],'segID',[],'cp',[],'MCSindex',[],'OCSindex',[]);
end

% ---- spreadsheets -------------------------------------------------------------------------------
function writeDetails(f, CS)
% ExportCSstructStatsv3.m, column for column. Columns that come from analyses not run here
% (ChrisC: numNPBtracks numSegIDs numChPts; JBM: Din Dout; the binding annotation: numBoundTracks
% numBindEvents numEntry numExit numRebind) are left BLANK. The original computes 0 for them when
% the analysis is missing, which reads as "none found" rather than "not measured".
hdr = {'CS_Number','CS_Legacy','cellIndex','csID','numTracks','numBoundTracks','numNPBtracks', ...
       'numSegIDs','numChPts','numBindEvents','numEntry','numExit','numRebind','MajorAx','MinorAx', ...
       'Angle','Area','Din','inNum','Dout','outNum','MitoFlag'};
C = cell(numel(CS), numel(hdr));
for i = 1:numel(CS)
    s = CS(i); ef = s.EllipseFit;
    C(i,:) = {s.CS_index, NaN, s.cellIndex, s.csID, numel(s.tracks), NaN, NaN, NaN, NaN, NaN, NaN, ...
              NaN, NaN, ef.MajorAxisLength, ef.MinorAxisLength, ef.Orientation, ...
              polyarea(s.refboundary(:,1), s.refboundary(:,2)), NaN, numel(s.refLocIDs), NaN, ...
              numel(s.neighborIDs), double(s.MitoFlag)};
end
writeSheet(f, 'Sheet1', [hdr; C]);
end

function writeCSstats(f, cells, Tracks)
% The per-cell count sheet: mito sites, other sites, total, and (in the original, as Excel
% formulas) the mito fraction per cell, the column totals and the averages. Written as values.
n = numel(Tracks);
C = cell(n + 4, 6);
C(1,:) = {'Row','MitoCS','OtherCS','TotalCS', [], []};
mc = zeros(n,1); oc = zeros(n,1);
for c = 1:n
    mc(c) = numel(Tracks(c).MCSindex); oc(c) = numel(Tracks(c).OCSindex);
    C(c+1,:) = {cells(c).base, mc(c), oc(c), mc(c)+oc(c), [], ratio(mc(c), mc(c)+oc(c))};
end
C(n+3,:) = {[], sum(mc), sum(oc), sum(mc+oc), [], []};
fr = arrayfun(@(k) ratio(mc(k), mc(k)+oc(k)), 1:n);
C(n+4,:) = {[], mean(mc), mean(oc), mean(mc+oc), [], mean(fr, 'omitnan')};
writeSheet(f, 'Sheet1', C);
end

function writeEnrichment(f, CS, EC, Tracks)
% OutputEnrichmentCoeffDatav2.m, both sheets, same columns and row order (per cell: its mito sites,
% then its other sites). ONE deliberate difference: the original took CSsize / CSarea / CS_Deff /
% CS_Neighbor in GLOBAL site order while the flag and step columns follow the per-cell mito-first
% order, so in its output a row's size and area belong to a different site from its step count
% (in the published VAPB sheet, 60 of 307 rows line up). Here every column of a row describes the
% same site.
hdr = {'CellIndex','MitoFlag','NumMCSsteps','NumOCSsteps','TotalSteps','CSsize_1','CSsize_2', ...
       'CSarea','CS_Deff','CS_Neighbor'};
rows = {};
for c = 1:numel(Tracks)
    for k = [Tracks(c).MCSindex, Tracks(c).OCSindex]
        s = CS(k); isM = s.MitoFlag; st = numel(s.refLocIDs);
        rows(end+1,:) = {EC(c).cellIndex, double(isM), tern(isM, st, NaN), tern(isM, NaN, st), ...
            EC(c).TotalSteps, s.EllipseFit.MajorAxisLength, s.EllipseFit.MinorAxisLength, ...
            polyarea(s.refboundary(:,1), s.refboundary(:,2)), NaN, NaN}; %#ok<AGROW>
    end
end
writeSheet(f, 'StepEnrichmentByCS', [hdr; rows]);

% EnrichmentByCell, including the three columns the original computed in Excel (MCSprob = E/G,
% OCSprob = F/G, MitoEnrichCoeff = J/K) and its blank spacer columns. TotalTracks is, as in the
% original, the number of FREE tracks (size of EC.FreeTracks).
hdr2 = {'Cell','NumMCStracks','NumOCStracks','TotalTracks','NumMCSstepsCell','NumOCSstepsCell', ...
        'TotalStepsPerCell', [], [], 'MCSprob','OCSprob', [], 'MitoEnrichCoeff'};
C = cell(numel(EC), numel(hdr2));
for c = 1:numel(EC)
    e = EC(c);
    ms = sum(e.MCSsteps, 'all'); os = sum(e.OCSsteps, 'all'); ts = e.TotalSteps;
    mp = ratio(ms, ts); op = ratio(os, ts);
    C(c,:) = {c, numel(e.MCStracks), numel(e.OCStracks), numel(e.FreeTracks), ms, os, ts, [], [], ...
              mp, op, [], ratio(mp, op)};
end
writeSheet(f, 'EnrichmentByCell', [hdr2; C]);
end

function writeBindingTable(f)
% ExtractBindingInfo.m's columns. It has one row per annotated binding interaction; the annotation
% was done by hand in the original (DwellTimeManual.m), so until it is done there are no rows.
hdr = {'CS Index','Track ID','Interaction #','Entry?','Exit?','DwellTime','CS size_1','CS size_2', ...
       'CSarea','CS_Deff','CS_Neighbor','CS_MitoFlag'};
writeSheet(f, 'Sheet1', hdr);
end

function writeSheet(f, sheet, C)
% NaN and [] become EMPTY cells, as blank cells are in the original workbooks. writecell writes ''
% and NaN as cells with no value at all (checked in the xlsx XML); 'missing' it refuses.
for k = 1:numel(C)
    v = C{k};
    if isempty(v) || (isnumeric(v) && isscalar(v) && isnan(v)), C{k} = ''; end
end
writecell(C, f, 'Sheet', sheet);
end

function r = ratio(a, b)
if b == 0 || ~isfinite(b) || ~isfinite(a), r = NaN; else, r = a / b; end
end

function y = tern(c, a, b), if c, y = a; else, y = b; end, end

function writeReadme(f, lab, CS, EC, boxUm, dtS)
fid = fopen(f, 'w'); cleaner = onCleanup(@() fclose(fid));
L = {
'THESE FILES FOLLOW THE LAYOUT OF THE PUBLISHED VAPB ContactSites DATASET'
sprintf('Condition: %s   Cells: %d   Contact sites: %d (%d mito, %d other)', lab, numel(EC), ...
        numel(CS), nnz([CS.MitoFlag]), nnz(~[CS.MitoFlag]))
''
'Same file names (with this condition in place of VAPB), same variables, same fields in the same'
'order, same spreadsheet columns - and every field computed as the original scripts compute it'
'(SPT_ContactSites_Pipeline/ContactSites_original: ContactSiteMapper.m, CS_refiner_v2_wacom.m,'
'Final/Revision/CS_builder.m, GenerateEnrichmentStruct.m, ExportCSstructStatsv3.m,'
'OutputEnrichmentCoeffDatav2.m, ExtractBindingInfo.m). The original scripts run on them.'
''
'=== FILLED, WITH THE ORIGINAL DEFINITIONS ==='
'CS: CS_index file cellIndex csID tracks refCenter refboundary boundaries EllipseFit LocIDs refLocIDs'
'    neighborIDs CSLocIDs CSneighborIDs CSmatrix CSvec MitoFlag'
'Tracks: file cellIndex lengths matrix center rawSteps steps MSD MSDerror CSD CSDnorm MSDstdev'
'    rawVector vector MitoCSindex MCSindex OCSindex'
'EC: every field'
'CS_details: CS_Number cellIndex csID numTracks MajorAx MinorAx Angle Area inNum outNum MitoFlag'
'CSstats, EnrichmentCoefficients (both sheets): every column except CS_Deff / CS_Neighbor'
''
'=== PRESENT BUT EMPTY - THE ORIGINAL RAN ANALYSES THIS PIPELINE DOES NOT ==='
'Binding and dwell times: CS.trackBinding NumEntry NumExit DwellTimes, BindingInfo.mat (no entries),'
'    the BindingTable (header only), and in CS_details numBoundTracks numBindEvents numEntry numExit'
'    numRebind. In the original these were ANNOTATED BY HAND: DwellTimeManual.m asks how many binding'
'    events each track has and takes clicked entry/exit points; EntryExitManualClassifierv2.m then'
'    classifies each one. Run those on CS_final_v3.mat to fill them - see the frame-interval note.'
'JBM tessellation diffusion: CS.Deff TessIndex refDeff neighborDeff, Tracks.JBM LocIndex Deff,'
'    CS_details Din Dout, EnrichmentCoefficients CS_Deff CS_Neighbor.'
'ChrisC trajectory segmentation: CS.tracksCCids segIDs ChPts, Tracks.CCindex segNum segID cp,'
'    CS_details numNPBtracks numSegIDs numChPts.'
'Legacy indexes from earlier revisions: CS.CSindex, CS_details CS_Legacy, Tracks.CSindexes.'
'Empty means NOT MEASURED. In the spreadsheets these cells are blank; the original script writes 0'
'for a missing analysis, which would read as "none found".'
''
'=== PARAMETERS AND CHOICES ==='
sprintf('Neighbourhood square: %.3f um wide, centred on each ORIGINAL pick (boundaries, LocIDs,', boxUm)
'    tracks, neighborIDs). ContactSiteMapper.m uses +/-30 density pixels, which on the VAPB grid was'
'    exactly 1.024 um; it is fixed in microns here so it means the same on any grid.'
'EllipseFit: regionprops of the outline, in the refiner''s image pixels - 3 nm each, pixel 400 = the'
'    original pick. So MajorAxisLength x 3 = nm. (If an outline is larger than the refiner''s'
'    2.4 um crop, the canvas is enlarged instead of clipping it.)'
'refboundary is in nm relative to refCenter; refCenter, boundaries and CSmatrix x/y are in um.'
'Time windows: a site found in a time window uses only that window''s localizations for tracks,'
'    LocIDs, refLocIDs and neighbours. With one window spanning the movie this is the original.'
'    EC.TotalSteps is the whole cell, as in the original.'
'Tracks rejected by hand in the QC step are removed, so track numbers here count the kept tracks.'
'Sites deleted during refinement are not included.'
'file ends in _Tracks, as in the original (its scripts strip 7 characters to get the cell name).'
sprintf('FRAME INTERVAL: %.4g s. The original dwell scripts HARD-CODE 0.011 s per frame', dtS)
'    (DwellTimeManual.m, EntryExitManualClassifierv2.m: 0.011*T). Change it before using them on'
'    these files, or every dwell time comes out scaled by the wrong factor.'
''
'=== TWO THINGS THAT DIFFER FROM THE PUBLISHED SPREADSHEETS ON PURPOSE ==='
'1. EnrichmentCoefficients, StepEnrichmentByCS: in OutputEnrichmentCoeffDatav2.m the CSsize, CSarea,'
'   CS_Deff and CS_Neighbor columns follow the global site order while CellIndex, MitoFlag and the'
'   step columns list each cell''s mito sites first - so a row''s size and area belong to a different'
'   site from its step count (in the published VAPB sheet 60 of 307 rows line up). Here every column'
'   of a row describes the same site.'
'2. Columns for analyses not run are blank rather than 0 (above).'
''
'=== NOTE ON A COLUMN NAME ==='
'EnrichmentByCell TotalTracks is, as in the original, the number of FREE tracks (tracks that touch'
'no contact site), not all tracks. MCSprob = NumMCSstepsCell/TotalStepsPerCell, OCSprob likewise,'
'MitoEnrichCoeff = MCSprob/OCSprob (blank when OCSprob is 0) - computed as values here, as Excel'
'formulas in the original. A "step" in the original is a localization.'
};
fprintf(fid, '%s\n', L{:});
end

function v = getf(s, f, d), if isstruct(s) && isfield(s, f) && ~isempty(s.(f)), v = s.(f); else, v = d; end, end
