function run_pipeline(projectDir, varargin)
% RUN_PIPELINE  Master driver for the integrated SPT + ContactSites pipeline.
%
% Chains the MATLAB-side stages downstream of tracking into one call, using a
% standardized folder layout and file-naming contract. The upstream stages
% (acquisition, channel extraction, TrackMate detection/tracking, and the
% track_viewer.m curation GUI) are interactive Fiji/MATLAB-GUI tools and are
% run by hand; this driver picks up from their outputs and takes you through
% the ContactSites analysis.
%
%   STAGE                     TOOL                       AUTOMATED HERE?
%   0 acquire (.czi/.nd2)     microscope                 no (external)
%   1 extract_channels_v2_2   Fiji macro                 no (external)
%   2 trackmate_find_thresh   Fiji/Jython                no (external)
%   3 trackmate_run           Fiji/Jython                no (external)
%   4 track_viewer curation   MATLAB uifigure GUI        no (interactive)
%   ------------------------------------------------------------------- 
%   5 build_trackstruct       MATLAB (this repo)         YES
%   6 run_contactsite_analysis MATLAB CS suite + gates   YES (with manual gates)
%
% STANDARDIZED LAYOUT (projectDir/)
%   tracks/        <- curated track_viewer output: *_tracks_filtered.xml,
%                     *_spots_filtered.csv, *_track_metrics.csv
%                     (or raw run_<TS>/ output: *_tracks.xml, *_spots.csv)
%   analysis/      <- working dir for the CS suite (this driver populates it)
%       TrackStruct.mat / Tracks.mat
%       MaxInt/    <- '*_3_MaxInt_RGB.tif'   (you provide, from Fiji)
%       Maps/ ER/ Mito/ Densities/ csIDs/    (JBM branch, as available)
%       ... CS suite creates TrackData/ CSdata/ CSsnaps/ CS_final.mat ...
%
% USAGE
%   run_pipeline(projectDir)                    % run stages 5..6 from the top
%   run_pipeline(projectDir,'Only','import')    % just build the struct
%   run_pipeline(projectDir,'CS',{'StartStage','mapper'})  % resume CS suite
%
% NAME-VALUE
%   'TracksDir'  : subfolder with curated/raw XML (default 'tracks').
%   'AnalysisDir': CS working dir (default 'analysis').
%   'Only'       : '' (default, run all) | 'import' | 'cs'.
%   'TimeUnit'   : 'frame' (default) | 'seconds'  (-> build_trackstruct).
%   'FileSuffix' : appended to Tracks(i).file (default '' ; see note below).
%   'CS'         : cell array of name-value pairs forwarded verbatim to
%                  run_contactsite_analysis (e.g. {'JBM',false,'MitoOnly',true}).
%   'SuitePath'  : ContactSites suite root (addpath'd for the CS stage).
%
% NOTE on FileSuffix / filename stripping: the CS suite derives a file base by
% stripping a FIXED number of trailing characters from Tracks(i).file
% (CS_builder uses end-7; refiners use end-10/-11). Your importer sets .file to
% the XML base (e.g. 'cell01'). If the suite's downstream image names assume a
% particular suffix (e.g. '_ch3_spt'), set 'FileSuffix' so the arithmetic lands
% on your MaxInt/Densities filenames. Validate on one cell before batch.

ip = inputParser;
ip.addParameter('TracksDir','tracks',@ischar);
ip.addParameter('AnalysisDir','analysis',@ischar);
ip.addParameter('Only','',@ischar);
ip.addParameter('TimeUnit','frame',@ischar);
ip.addParameter('FileSuffix','',@ischar);
ip.addParameter('CS',{},@iscell);
ip.addParameter('SuitePath','',@ischar);
ip.parse(varargin{:});
o = ip.Results;

assert(isfolder(projectDir),'projectDir not found: %s',projectDir);
tracksDir   = fullfile(projectDir,o.TracksDir);
analysisDir = fullfile(projectDir,o.AnalysisDir);

doImport = isempty(o.Only) || strcmpi(o.Only,'import');
doCS     = isempty(o.Only) || strcmpi(o.Only,'cs');

fprintf('\n########## INTEGRATED PIPELINE ##########\nproject: %s\n',projectDir);

% ---------------- Stage 5: build the Tracks struct --------------------------
if doImport
    fprintf('\n[stage 5] build_trackstruct  (%s)\n',tracksDir);
    assert(isfolder(tracksDir), ...
        'TracksDir "%s" not found. Put curated track_viewer output there.',tracksDir);
    Tracks = build_trackstruct(tracksDir, ...
        'Prefer','auto','TimeUnit',o.TimeUnit,'FileSuffix',o.FileSuffix, ...
        'AttachCSV',true,'Save',true,'Verbose',true);   %#ok<NASGU>

    if ~isfolder(analysisDir), mkdir(analysisDir); end
    src = fullfile(tracksDir,'TrackStruct.mat');
    dst = fullfile(analysisDir,'TrackStruct.mat');
    if isfile(src), copyfile(src,dst); end
    fprintf('[stage 5] -> %s (%d cells)\n',dst,numel(Tracks));
end

% ---------------- Stage 6: ContactSites analysis ----------------------------
if doCS
    fprintf('\n[stage 6] run_contactsite_analysis  (%s)\n',analysisDir);
    if ~isfile(fullfile(analysisDir,'TrackStruct.mat')) && ...
       ~isfile(fullfile(analysisDir,'Tracks.mat'))
        error(['No TrackStruct.mat/Tracks.mat in %s.\n' ...
               'Run stage 5 first, or set ''Only'',''import''.'],analysisDir);
    end
    if ~isfolder(fullfile(analysisDir,'MaxInt'))
        warning(['MaxInt/ not found in %s — the CS suite needs ' ...
                 '''*_3_MaxInt_RGB.tif'' there. Add it before the mapper stage.'],analysisDir);
    end
    csArgs = o.CS;
    if ~isempty(o.SuitePath), csArgs = [csArgs, {'SuitePath',o.SuitePath}]; end
    state = run_contactsite_analysis(analysisDir, csArgs{:});   %#ok<NASGU>
    fprintf('[stage 6] driver returned at stage "%s" (%s).\n',state.stopped_at,state.reason);
end

fprintf('\n########## done ##########\n');
end
