function run_track()
%RUN_TRACK  Launch Tool 1 — SPT "Track & filter".
%   Tabs: Match files | Detect | Track & filter | Experiment.
%   Needs a dataset folder holding spt/, er_seg/, mito_seg/; writes tracks/<base>_tracks_filtered.xml
%   + _spots_filtered.csv + _settings.txt — the project folder Tool 2 imports.
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'tool1_track'));
spt_app();
end
