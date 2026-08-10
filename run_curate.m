function run_curate()
%RUN_CURATE  Launch Tool 2 — "Curate & Build".
%   Tabs: Import & Curate | Build & QC | Experiment.
%   Takes a Tool 1 project folder; a named build writes analysis/<name>.mat (default TrackStruct.mat)
%   and points analysis/active_trackstruct.txt at it — the build Tool 3 then analyzes.
%   Shares its implementation with Tool 3; this just opens spt_analyze_app in 'curate' mode.
%   The app adds ../drivers to the path itself.
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'tool2_analyze', 'app'));
spt_curate_app();
end
