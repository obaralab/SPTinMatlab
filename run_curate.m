function run_curate()
%RUN_CURATE  Launch Tool 2 — "Curate".
%   Tabs: Experiment | Import & Curate.
%   Takes a Tool 1 project folder and writes curated tracks back to tracks/ as
%   *_tracks_curated.xml. Building the TrackStruct from those is Tool 3 (run_analysis), which reads
%   the folder rather than this tool's state — so curation and building are separate jobs.
%   Shares its implementation with the other launchers; this opens spt_analyze_app in 'curate' mode.
%   The app adds ../drivers to the path itself.
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'tool2_analyze', 'app'));
spt_curate_app();
end
