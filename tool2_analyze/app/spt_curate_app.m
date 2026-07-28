function fig = spt_curate_app()
%SPT_CURATE_APP  Tool 2 of 3 — "Curate & Build".
%
% Thin launcher for the Curate & Build stage of the SPT workflow: Import & Curate (embeds
% track_viewer) -> Build & QC (build the TrackStruct.mat + per-track QC) -> Experiment (the shared
% multi-folder / condition manifest). It shares its implementation with the Analyze tool — this is
% just spt_analyze_app in 'curate' mode, so the two launchers can never drift apart.
%
% Pipeline position:
%   Tool 1  spt_app         -> Match / Detect / Track / Curate / Export  (curated _tracks_filtered)
%   Tool 2  spt_curate_app  -> THIS: curate the tracked cells + build TrackStruct.mat
%   Tool 3  spt_analyze_app -> Contact sites / Refine / Sites / Dwell / Compare (reads TrackStruct.mat)
%
%   run:  addpath('<repo>/tool2_analyze/app'); spt_curate_app
fig = spt_analyze_app('curate');
end
