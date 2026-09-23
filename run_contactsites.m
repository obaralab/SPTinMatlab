function run_contactsites()
%RUN_CONTACTSITES  Launch Tool 4 — "Contact Sites".
%   Tabs: Experiment | Contact sites | Refine | Sites | Dwell | Engagement | Compare.
%   Starts from the project's ACTIVE build in analysis/ — the named .mat that
%   active_trackstruct.txt points at, else TrackStruct.mat — so build with Tool 3 first.
%   This was Tool 3 when the toolkit had three parts, and run_analyze still opens it.
here = fileparts(mfilename('fullpath'));
addpath(fullfile(here, 'tool2_analyze', 'app'));
addpath(fullfile(here, 'tool3_contactsites', 'app'), fullfile(here, 'tool3_contactsites', 'drivers'));
spt_analyze_app('contactsites');
end
