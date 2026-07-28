function run_analyze()
%RUN_ANALYZE  Launch Tool 3 — "Analyze" (ContactSites pipeline).
%   Starts from analysis/TrackStruct.mat: density -> contact sites -> refine -> sites -> dwell -> compare.
%   The app itself adds ../drivers and ../ContactSites_robust to the path (relative to app/),
%   so this launcher only needs to put the app folder on the path.
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'tool2_analyze', 'app'));
spt_analyze_app('analyze');
end
