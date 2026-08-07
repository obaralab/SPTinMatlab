function c = cs_channel_colour(key, idx, pinned)
%CS_CHANNEL_COLOUR  Display colour for a reference channel — one rota, shared by every panel.
%
%   c = cs_channel_colour(key, idx)
%   c = cs_channel_colour(key, idx, pinned)
%
% INPUT
%   key    : channel key ('er', 'mito', 'lyso', …)
%   idx    : the channel's position in the project's DECLARATION order. Colour comes from position,
%            not from a hash of the name, so a project draws the same colour for the same channel on
%            every run and two projects with the same channels agree.
%   pinned : optional struct mapping key -> RGB, for a panel that already has published colours for
%            some channels. Those win; everything else takes the rota.
%
% WHY PINS EXIST. The contact-site picker has drawn ER as [0.25 1 0.50] and mito as [1 0.30 0.85]
% for as long as there have been figures; the dwell overlay uses its own slightly different pair,
% [0.2 1 0.35] and [1 0.25 1], because it draws a translucent FILL rather than a contour. Both are
% already in printed material. Unifying them would be a cosmetic change to published figures made as
% a side effect of adding a third channel, so each panel keeps its own pins and shares only the rota
% that decides what a NEW channel looks like.
if nargin < 2 || isempty(idx), idx = 1; end
k = lower(strtrim(char(key)));

if nargin >= 3 && isstruct(pinned) && isfield(pinned, k)
    c = pinned.(k); return
end

% The rota. Chosen to stay distinguishable from BOTH pinned pairs above and from each other, so a
% third channel never reads as "that is the ER one".
rota = [0.30 0.75 1.00      % cyan-blue
        1.00 0.80 0.20      % amber
        0.70 0.55 1.00      % violet
        1.00 0.45 0.30      % coral
        0.55 1.00 0.85];    % mint
c = rota(mod(max(round(idx),1) - 1, size(rota,1)) + 1, :);
end
