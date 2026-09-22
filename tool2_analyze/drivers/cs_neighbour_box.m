function [um, src] = cs_neighbour_box(anaDir)
%CS_NEIGHBOUR_BOX  Width of the NEIGHBOURHOOD BOX around a contact site, in um (project setting).
%
%   [um, src] = cs_neighbour_box(anaDir)
%
% WHAT THE BOX IS FOR. The outline says what is IN a site. Half of every comparison is what is just
% OUTSIDE it: the same molecules, the same cell, metres of ER away from any site is not a fair
% control, and the whole field is not either. So each site also carries a square around it, and the
% localizations inside the square but outside the outline are its NEIGHBOURS. Counts, densities and
% diffusion are reported for both (cs_window_mapper: nLocNear, neighborIDs, DtNear...).
%
% THE DEFAULT IS THE VAPB DATASET'S: 1.024 um, the +/-30 density-pixel box of ContactSiteMapper.m
% (30 x 17.07 nm either side of the pick). Keeping it means a neighbour count here and a neighbour
% count there mean the same thing. Widen it to ask about a larger neighbourhood; the number is
% recorded per site in the export, because a count without its box is not interpretable.
%
% WHERE IT IS CENTRED. Here, on the site's own centre (the refined one, where the outline is). The
% published dataset centres its square on the ORIGINAL pick instead, and cs_advisor_format keeps
% that convention so an exported advisor_format folder is comparable with the original. For a
% site whose centre was never moved the two are identical.
%
% The setting is stored as neighbourBoxUm in analysis/CS_footprints.mat (the Refine tab's Save and
% cs_footprints_regenerate write it), beside the outline smoothing (cs_outline_sigma). A project
% that never set it gets the default.

DEFAULT_UM = 1.024;
um = DEFAULT_UM; src = 'default';
if nargin < 1 || isempty(anaDir), return; end
f = fullfile(char(anaDir), 'CS_footprints.mat');
if ~isfile(f), return; end
try
    w = whos('-file', f);
    if any(strcmp({w.name}, 'neighbourBoxUm'))
        L = load(f, 'neighbourBoxUm');
        if isscalar(L.neighbourBoxUm) && isfinite(L.neighbourBoxUm) && L.neighbourBoxUm > 0
            um = double(L.neighbourBoxUm); src = 'CS_footprints.mat';
        end
    end
catch
end
end
