function run_analysis()
%RUN_ANALYSIS  Launch Tool 3 — "Analysis".
%   Tabs: Experiment | Build, QC & vectors.
%   Builds analysis/<name>.mat from the project's tracks/ folder (preferring Tool 2's curated XML
%   when it is there), computes per-track MSD/D and per-localization rolling D, and points
%   analysis/active_trackstruct.txt at it — the build Tool 4 then analyses. The lower half of that
%   same tab reads the build back: step vectors as arrows, and what the intensity traces say about
%   bleaching steps and background.
%   Input is a Tool 1 project folder. The build reads the tracks folder on disk, so this tool does
%   not need Tool 2 open — curate first only if you intend to.
%   Shares its implementation with the other launchers; this opens spt_analyze_app in 'analysis'
%   mode. The app adds ../drivers to the path itself.
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'tool2_analyze', 'app'));
spt_analyze_app('analysis');
end
