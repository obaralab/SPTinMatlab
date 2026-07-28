function run_track()
%RUN_TRACK  Launch Tool 1 — SPT "Track & filter".
%   Match files -> Detect -> Track -> filter -> export curated tracks for Tool 2.
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'tool1_track'));
spt_app();
end
