function setup_run_folder(analysisDir, varargin)
% SETUP_RUN_FOLDER  Scaffold the ContactSites working directory and place the
% per-cell images under the file-naming convention the suite expects.
%
% The ContactSites suite pairs images to cells by a SHARED base name equal to
% Tracks(i).file, and it builds image paths by string concatenation, e.g.
%     Densities/<file>_rho.tif        (ContactSiteMapper)
%     MaxInt/<file>_3_MaxInt_RGB.tif  (QuickPlotterTracks, CSrefinerNoDeff)
%     Mito/<file>_3_TA_BC.tif         (Final/CS_reorienter_v2)
% If your raw images are named differently (e.g. '*_mito_mip.tif'), the
% automated stages cannot find them. This helper creates the folder scaffold
% and copies+renames each image so its base equals Tracks(i).file, WITHOUT
% touching any suite .m file.
%
% USAGE
%   setup_run_folder(analysisDir)                       % just make the folders
%   setup_run_folder(analysisDir,'Mito',mitoSrc)        % + place mito images
%   setup_run_folder(analysisDir,'MaxInt',rgbSrc,'Mito',mitoSrc)
%
% analysisDir must already contain TrackStruct.mat (or Tracks.mat) so the
% helper can read Tracks(i).file for the target names.
%
% NAME-VALUE
%   'MaxInt' : source for the RGB overlay image(s). Either a single file
%              (1-cell runs) or a folder of images (matched to cells in the
%              sorted order below). Copied to MaxInt/<file>_3_MaxInt_RGB.tif.
%   'Mito'   : source for the mitochondria image(s). Copied to
%              Mito/<file><MitoSuffix>.
%   'ER'     : source for the ER image(s). Copied to ER/<file>_3_ER.tif.
%   'MitoSuffix' : suffix appended after <file> for the mito image
%              (default '_3_TA_BC.tif' — matches Final/CS_reorienter_v2.m;
%              use '_3_maxS2N_8bit.tif' for CS_reorienter_v3.m).
%   'DryRun' : true -> print the planned copies without writing (default false).
%
% Multi-cell matching: when a source is a FOLDER, its files are sorted
% alphabetically and zipped to Tracks in struct order. When a source is a
% SINGLE file and numel(Tracks)==1, it maps to that one cell. Any other
% mismatch is an error — you are told the counts so you can fix the inputs.

ip = inputParser;
ip.addParameter('MaxInt','',@ischar);
ip.addParameter('Mito','',@ischar);
ip.addParameter('ER','',@ischar);
ip.addParameter('MitoSuffix','_3_TA_BC.tif',@ischar);
ip.addParameter('DryRun',false,@islogical);
ip.parse(varargin{:});
o = ip.Results;

assert(isfolder(analysisDir),'analysisDir not found: %s',analysisDir);

% ---- load Tracks to learn the target base names ----------------------------
Tracks = local_load_tracks(analysisDir);
nCells = numel(Tracks);
bases  = arrayfun(@(t) string(t.file), Tracks);
fprintf('[setup] %d cell(s): %s\n', nCells, strjoin(cellstr(bases),', '));

% ---- create the standard scaffold ------------------------------------------
sub = {'MaxInt','Mito','ER','Maps','Densities','csIDs','TrackData','CSdata'};
for k = 1:numel(sub)
    d = fullfile(analysisDir,sub{k});
    if ~isfolder(d)
        if o.DryRun, fprintf('[dry] mkdir %s\n',d); else, mkdir(d); end
    end
end

% ---- place images under the naming convention ------------------------------
place_images(o.MaxInt, bases, fullfile(analysisDir,'MaxInt'), '_3_MaxInt_RGB.tif', o.DryRun);
place_images(o.Mito,   bases, fullfile(analysisDir,'Mito'),   o.MitoSuffix,        o.DryRun);
place_images(o.ER,     bases, fullfile(analysisDir,'ER'),     '_3_ER.tif',         o.DryRun);

fprintf(['[setup] scaffold ready in %s\n' ...
         '        next: run_contactsite_analysis(''%s'',''SuitePath'',<ContactSites>)\n'], ...
         analysisDir, analysisDir);
end

% ===========================================================================
function Tracks = local_load_tracks(analysisDir)
f1 = fullfile(analysisDir,'Tracks.mat');
f2 = fullfile(analysisDir,'TrackStruct.mat');
if isfile(f1)
    S = load(f1);
elseif isfile(f2)
    S = load(f2);
else
    error(['No Tracks.mat or TrackStruct.mat in %s.\n' ...
           'Run build_trackstruct.m first.'],analysisDir);
end
assert(isfield(S,'Tracks'),'.mat has no variable ''Tracks''.');
Tracks = S.Tracks;
assert(all(arrayfun(@(t) ~isempty(t.file), Tracks)), ...
       'Some Tracks(i).file are empty; cannot derive image names.');
end

% ===========================================================================
function place_images(src, bases, destDir, suffix, dryRun)
if isempty(src), return; end
nCells = numel(bases);

if isfolder(src)
    L = dir(fullfile(src,'*.tif'));
    L = L(~[L.isdir]);
    [~,ord] = sort({L.name}); L = L(ord);
    srcFiles = arrayfun(@(e) fullfile(e.folder,e.name), L, 'uni', 0);
elseif isfile(src)
    srcFiles = {src};
else
    error('Source not found: %s',src);
end

if numel(srcFiles) ~= nCells
    error(['Image count (%d) does not match cell count (%d) for -> %s.\n' ...
           'Provide one image per cell (folder, alphabetical) or a single ' ...
           'image for a single-cell run.'], numel(srcFiles), nCells, destDir);
end

for i = 1:nCells
    dst = fullfile(destDir, char(bases(i)) + string(suffix));
    if dryRun
        fprintf('[dry] copy %s\n        -> %s\n', srcFiles{i}, dst);
    else
        copyfile(srcFiles{i}, dst);
        fprintf('[setup] %s -> %s\n', srcFiles{i}, dst);
    end
end
end
