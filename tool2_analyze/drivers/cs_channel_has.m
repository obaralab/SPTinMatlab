function [tf, raw] = cs_channel_has(T, key, src)
%CS_CHANNEL_HAS  Was this reference channel imaged for this cell?
%
%   [tf, raw] = cs_channel_has(T, key, src)
%
% T is ONE element of a Tracks array. Cheap availability test for UI enable/disable and QC columns —
% it does NOT read the values, so it is safe to call per row.
%
%   src : 'tracked' (default) the [nFrames x nTracks] distance matrix
%         'cloud'             the per-detection column on T.allSpots
%         'any'               either of the two
%
% OUTPUT
%   tf  : true when the field exists and is non-empty.
%   raw : the stored array itself, or [] — for the handful of callers that pass the matrix straight
%         to a plotting/QC helper. Prefer cs_channel_dist when you need it aligned to coordinates.
if nargin < 3 || isempty(src), src = 'tracked'; end
F = cs_channel_fields(key);
src = lower(strtrim(char(src)));
tf = false; raw = [];
if ~isstruct(T), return; end
switch src
    case 'tracked'
        if isfield(T, F.mat) && ~isempty(T.(F.mat)), tf = true; raw = T.(F.mat); end
    case 'cloud'
        if isfield(T,'allSpots') && isstruct(T.allSpots) && isfield(T.allSpots, F.spots) ...
                && ~isempty(T.allSpots.(F.spots))
            tf = true; raw = T.allSpots.(F.spots);
        end
    case 'any'
        [tf, raw] = cs_channel_has(T, key, 'tracked');
        if ~tf, [tf, raw] = cs_channel_has(T, key, 'cloud'); end
    otherwise
        error('cs_channel_has:badSource', 'src must be ''tracked'', ''cloud'' or ''any'', not ''%s''.', src);
end
end
