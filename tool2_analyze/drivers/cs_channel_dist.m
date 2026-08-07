function [d, have, n] = cs_channel_dist(T, key, src)
%CS_CHANNEL_DIST  Signed per-localization distance to a reference channel, aligned 1:1 with coords.
%
%   [d, have, n] = cs_channel_dist(T, key, src)
%
% T is ONE element of a TrackStruct Tracks array. Returns a COLUMN of signed microns in the same
% order as the coordinates of the requested source, so a caller can filter d with exactly the mask
% it uses on X/Y. Sign convention (set at import): + outside the organelle, - inside, ~0 on the
% boundary, NaN where unknown.
%
% INPUT
%   key : 'er' | 'mito' — see cs_channel_fields.
%   src : 'cloud'   (default) EVERY detection, tracked and untracked, from T.allSpots — this is the
%                   denser set and the only one that is per-frame correct for a MOVING organelle.
%         'tracked' tracked spots only, from the [nFrames x nTracks] matrix, reshaped column-major
%                   so d(mask(:)) matches M(mask) for any logical mask over matrix(:,:,1).
%
% OUTPUT
%   d    : [n x 1] double. ALL-NaN when the channel is absent — never [], so the caller never has to
%          branch on emptiness to keep d aligned with X/Y.
%   have : true only when a real, correctly-sized distance array was found.
%   n    : numel(d) — the localization count of the requested source (0 when the source is empty).
%
% The size check is what makes `have` trustworthy: a distance array that does not match its
% coordinate set is treated as ABSENT rather than indexed into. Several call sites this replaced
% omitted that check and would have thrown (or silently mis-indexed) on a mismatched build.
if nargin < 3 || isempty(src), src = 'cloud'; end
F = cs_channel_fields(key);
src = lower(strtrim(char(src)));

switch src
    case 'cloud'
        as = []; if isstruct(T) && isfield(T,'allSpots'), as = T.allSpots; end
        if ~isstruct(as) || ~isfield(as,'X'), n = 0; else, n = numel(as.X); end
        d = NaN(n,1); have = false;
        if n > 0 && isfield(as, F.spots) && numel(as.(F.spots)) == n
            d = double(as.(F.spots)(:)); have = true;
        end
    case 'tracked'
        n = 0; sz = [0 0];
        if isstruct(T) && isfield(T,'matrix') && ~isempty(T.matrix)
            sz = size(T.matrix(:,:,1)); n = prod(sz);
        end
        d = NaN(n,1); have = false;
        if n > 0 && isfield(T, F.mat) && isequal(size(T.(F.mat)), sz)
            d = reshape(double(T.(F.mat)), [], 1); have = true;
        end
    otherwise
        error('cs_channel_dist:badSource', 'src must be ''cloud'' or ''tracked'', not ''%s''.', src);
end
end
