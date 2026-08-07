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
%   tf  : true when the channel has a non-empty array in EITHER the keyed storage (T.dist.<key>) or
%         the flat legacy field (T.mitoDist). Presence is decided by the array being there and
%         non-empty — NOT by any(isfinite(...)). The importer decides "present" from the CSV column
%         NAME alone, so a column that exists but is blank yields a full NaN matrix, and treating
%         that as absent would change what the QC table and the picker status line report.
%   raw : the stored array itself, or [] — for the handful of callers that pass the matrix straight
%         to a plotting/QC helper. Prefer cs_channel_dist when you need it aligned to coordinates.
%
% 'tracked' and 'cloud' are genuinely different questions, not two ways of asking one:
% TrackImporter_direct returns early when an intensity column is missing, which leaves allSpots (and
% its distances) populated while the tracked matrices stay []. Every legacy call site asked the
% tracked question, so that is the default.
if nargin < 3 || isempty(src), src = 'tracked'; end
F = cs_channel_fields(key);
src = lower(strtrim(char(src)));
tf = false; raw = [];
if ~isstruct(T), return; end
switch src
    case 'tracked'
        raw = pick_(T, F.box.mat, F.key, F.mat);
    case 'cloud'
        as = []; if isfield(T,'allSpots'), as = T.allSpots; end
        raw = pick_(as, F.box.spots, F.key, F.spots);
    case 'any'
        [tf, raw] = cs_channel_has(T, key, 'tracked');
        if ~tf, [tf, raw] = cs_channel_has(T, key, 'cloud'); end
        return
    otherwise
        error('cs_channel_has:badSource', 'src must be ''tracked'', ''cloud'' or ''any'', not ''%s''.', src);
end
tf = ~isempty(raw);
end

% ------------------------------------------------------------------------------------------------
function raw = pick_(s, container, key, flatName)
% Keyed storage first, flat legacy field second — the same precedence cs_channel_dist uses.
raw = [];
if ~isstruct(s) || ~isscalar(s), return; end
raw = cs_channel_boxed(s, container, key);
if isempty(raw) && isfield(s, flatName), raw = s.(flatName); end
end
