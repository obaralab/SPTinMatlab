function st = cs_experiment_status(rec)
%CS_EXPERIMENT_STATUS  Per-cell processing status, derived from the filesystem (no tool wiring needed).
%
%   st = cs_experiment_status(rec)   rec: a cell record (from cs_experiment_scan) with .file,
%   .analysis, and optionally .tracks (the tracks folder).
%
% st is a struct of logicals across the pipeline stages:
%   .tracked  a <base>_tracks(_filtered).xml exists in the tracks folder
%   .curated  a <base>_tracks_curated.xml exists
%   .built    the folder's analysis/TrackStruct.mat exists           (folder-level)
%   .picked   analysis/csIDs/<base>_CSsites.txt exists
%   .mapped   analysis/CSW_final.mat exists                          (folder-level)
%   .dwelled  analysis/cs_window_dwell.mat exists                    (folder-level)
st = struct('tracked',false,'curated',false,'built',false,'picked',false,'mapped',false,'dwelled',false);
base = ''; if isfield(rec,'file'), base = char(rec.file); end
ana  = ''; if isfield(rec,'analysis'), ana = char(rec.analysis); end
tr   = ''; if isfield(rec,'tracks'),   tr  = char(rec.tracks);   end
if ~isempty(tr) && isfolder(tr) && ~isempty(base)
    st.tracked = ~isempty(dir(fullfile(tr,[base '_tracks_filtered.xml']))) || ~isempty(dir(fullfile(tr,[base '_tracks.xml'])));
    st.curated = ~isempty(dir(fullfile(tr,[base '_tracks_curated.xml'])));
end
if ~isempty(ana)
    st.built   = isfile(fullfile(ana,'TrackStruct.mat'));
    st.picked  = ~isempty(base) && isfile(fullfile(ana,'csIDs',[base '_CSsites.txt']));
    st.mapped  = isfile(fullfile(ana,'CSW_final.mat'));
    st.dwelled = isfile(fullfile(ana,'cs_window_dwell.mat'));
end
end
