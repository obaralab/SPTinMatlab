function Tracks = build_trackstruct(inputDir, varargin)
% BUILD_TRACKSTRUCT  One-call bridge from TrackMate / track_viewer output to
% the `Tracks` struct the ContactSites suite consumes.
%
% This is the single hand-off point that replaces the old
%   _tracks_builtin.xml -> XML2XLSX.xlsm -> .xlsx -> TrackImporterCJO_2024v1.m
% chain. It auto-detects whether a folder holds curated (filtered) tracks or
% raw run output and calls TrackImporter_direct with the right pattern.
%
% USAGE
%   Tracks = build_trackstruct                      % <- pops up a folder picker
%   Tracks = build_trackstruct(runOrExportDir)      % <- pass the folder directly
%   Tracks = build_trackstruct(dir, 'Prefer','filtered', 'TimeUnit','frame', ...)
%   Tracks = build_trackstruct('', 'TimeUnit','seconds')   % '' -> picker + options
%
% If <inputDir> is omitted or empty, a native folder-selection dialog opens
% (uigetdir). Cancelling the dialog returns an empty Tracks and does nothing.
%
% BEHAVIOUR
%   - If <dir> contains any '*_tracks_filtered.xml'  -> import those (curated).
%   - else if it contains any '*_tracks.xml'         -> import those (raw run).
%   - else error.
%   Override with 'Prefer','raw' | 'filtered' to force one.
%
% NAME-VALUE (passed through to TrackImporter_direct unless noted)
%   'Prefer'    : 'auto' (default) | 'filtered' | 'raw'
%   'TimeUnit'  : 'frame' (default, reproduces legacy struct) | 'seconds'
%   'FileSuffix': '' (default). Appended to Tracks(i).file so the CS suite's
%                 filename(1:end-K) stripping lands on <base>.
%   'AttachCSV' : true (default) — pair *_spots(_filtered).csv for intensities.
%   'Save'      : true (default) — write TrackStruct.mat into <dir>.
%   'Verbose'   : true (default).
%
% OUTPUT  Tracks : 1 x nFiles struct (layout and per-stage cost: docs/DATA_STRUCTURE.md).
%
% Requires TrackImporter_direct.m on the path.

% ---- Make co-located helpers findable ---------------------------------
% TrackImporter_direct.m must be on the path. If it sits in the same folder
% as this file (the usual layout), add that folder so the call below resolves
% even when build_trackstruct was launched via run('.../build_trackstruct.m').
thisDir = fileparts(mfilename('fullpath'));
if ~isempty(thisDir) && exist('TrackImporter_direct','file') ~= 2
    addpath(thisDir);
end
if exist('TrackImporter_direct','file') ~= 2
    error('build_trackstruct:noImporter', ...
        ['TrackImporter_direct.m is not on the MATLAB path.\n' ...
         'Put it in the same folder as build_trackstruct.m (%s)\n' ...
         'or run  addpath(''<folder with the integration .m files>'')  first.'], ...
         thisDir);
end

p = inputParser;
p.addParameter('Prefer','auto', @(s) any(strcmpi(s,{'auto','filtered','raw'})));
p.addParameter('TimeUnit','frame');
p.addParameter('FileSuffix','');
p.addParameter('AttachCSV',true);
p.addParameter('Save',true);
p.addParameter('Verbose',true);
p.addParameter('IncludeFiles',{});  % only build these cell bases ({}=all) — session selection
p.addParameter('ProgressFcn',[]);   % @(i,nFiles,name) forwarded to TrackImporter_direct
p.addParameter('Calib',struct());    % project-level calibration; each cell falls back to it
p.addParameter('Pattern','',@ischar);  % explicit XML glob (overrides Prefer) — e.g. dual-colour '*_ch24_spt_tracks.xml'
p.parse(varargin{:});
opt = p.Results;

% ---- Folder selection --------------------------------------------------
% No directory (or an empty one) -> open a native folder-picker dialog.
if nargin < 1 || isempty(inputDir)
    startPath = pwd;                       % dialog opens at current folder
    inputDir = uigetdir(startPath, 'Select the run_/export folder with *_tracks.xml');
    if isequal(inputDir, 0)                % user pressed Cancel
        if opt.Verbose, fprintf('build_trackstruct: cancelled — no folder selected.\n'); end
        Tracks = struct([]);               % empty struct, nothing done
        return;
    end
end

if ~isfolder(inputDir)
    error('build_trackstruct:noDir','Not a folder: %s', inputDir);
end

hasFilt = ~isempty(dir(fullfile(inputDir,'*_tracks_filtered.xml')));
hasRaw  = ~isempty(dir(fullfile(inputDir,'*_tracks.xml')));

switch lower(opt.Prefer)
    case 'filtered'
        pattern = '*_tracks_filtered.xml'; src = 'curated (forced)';
    case 'raw'
        pattern = '*_tracks.xml';          src = 'raw run (forced)';
    otherwise % auto
        if hasFilt
            pattern = '*_tracks_filtered.xml'; src = 'curated (filtered)';
        elseif hasRaw
            pattern = '*_tracks.xml';          src = 'raw run (unfiltered)';
        else
            error('build_trackstruct:noXML', ...
                ['No *_tracks.xml or *_tracks_filtered.xml in %s.\n' ...
                 'Run trackmate_run.py (raw) or export from track_viewer.m (curated) first.'], ...
                 inputDir);
        end
end

% explicit Pattern overrides the Prefer-derived glob (dual-colour: import ONE channel only)
if ~isempty(opt.Pattern)
    pattern = opt.Pattern; src = ['custom pattern (' pattern ')'];
end

% Guard: '*_tracks.xml' glob would also match '*_tracks_filtered.xml' in
% MATLAB's dir(). When importing RAW, exclude the filtered ones downstream by
% pattern; TrackImporter_direct strips both suffixes but we want the intended
% set. dir('*_tracks.xml') does NOT match '..._tracks_filtered.xml' because the
% literal '_tracks.xml' must terminate the name — verified below.
if strcmp(pattern,'*_tracks.xml')
    listing = dir(fullfile(inputDir, pattern));
    names   = {listing.name};
    stray   = names(~cellfun(@isempty, regexp(names,'_tracks_filtered\.xml$','once')));
    if ~isempty(stray)
        % Defensive: on platforms where the glob is loose, warn.
        warning('build_trackstruct:looseGlob', ...
            '%d filtered file(s) matched the raw glob; importer will still key on _tracks.xml.', numel(stray));
    end
end

if opt.Verbose
    fprintf('build_trackstruct: %s\n  source: %s\n  pattern: %s\n', inputDir, src, pattern);
end

Tracks = TrackImporter_direct(inputDir, ...
    'Pattern',    pattern, ...
    'TimeUnit',   opt.TimeUnit, ...
    'AttachCSV',  opt.AttachCSV, ...
    'FileSuffix', opt.FileSuffix, ...
    'Save',       opt.Save, ...
    'Verbose',    opt.Verbose, ...
    'IncludeFiles',opt.IncludeFiles, ...
    'ProgressFcn',opt.ProgressFcn, ...
    'Calib',      opt.Calib);

if opt.Verbose
    fprintf('build_trackstruct: done — %d file(s) in Tracks.\n', numel(Tracks));
    if opt.Save
        fprintf('  -> %s ready for the ContactSites suite.\n', fullfile(inputDir,'TrackStruct.mat'));
    end
end
end
