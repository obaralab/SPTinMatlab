function run_analyze()
%RUN_ANALYZE  Launch Tool 3 — "Analyze" (ContactSites pipeline).
%   Tabs: Contact sites | Refine | Sites | Dwell | Experiment | Compare.
%   Starts from the project's ACTIVE build in analysis/ — the named .mat that
%   active_trackstruct.txt points at, else TrackStruct.mat — so build with Tool 2 first.
%   The app itself adds ../drivers to the path (relative to app/), so this launcher only
%   needs to put the app folder on the path.
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'tool2_analyze', 'app'));
spt_analyze_app('analyze');
end
