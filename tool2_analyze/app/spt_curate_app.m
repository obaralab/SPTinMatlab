function fig = spt_curate_app()
%SPT_CURATE_APP  Tool 2 of 4 — "Curate".
%
% Thin launcher for the curation stage: Experiment (the shared multi-folder / condition manifest)
% -> Import & Curate (embeds track_viewer). It shares its implementation with the other tools — this
% is just spt_analyze_app in 'curate' mode, so the launchers can never drift apart.
%
% Pipeline position:
%   Tool 1  spt_app          -> Match / Detect / Track / Curate / Export  (curated _tracks_filtered)
%   Tool 2  spt_curate_app   -> THIS: curate the tracked cells (writes *_tracks_curated.xml)
%   Tool 3  'analysis' mode  -> Build & QC + Vectors & bleaching (writes TrackStruct.mat)
%   Tool 4  'contactsites'   -> Contact sites / Refine / Sites / Dwell / Engagement / Compare
%
%   run:  addpath('<repo>/tool2_analyze/app'); spt_curate_app
fig = spt_analyze_app('curate');
end
