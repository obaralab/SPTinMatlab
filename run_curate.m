function run_curate()
%RUN_CURATE  Launch Tool 2 — "Curate & Build".
%   Import curated tracks -> curate (track_viewer) -> build_trackstruct -> analysis/TrackStruct.mat.
%   Shares its implementation with Tool 3; this just opens spt_analyze_app in 'curate' mode.
%   The app adds ../drivers and ../ContactSites_robust to the path itself.
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'tool2_analyze', 'app'));
spt_curate_app();
end
