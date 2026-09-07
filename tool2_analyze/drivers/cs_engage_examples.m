function [sel, Tsub] = cs_engage_examples(Tracks, opts)
%CS_ENGAGE_EXAMPLES  The tracks that actually touch the engagement zone, and a TrackStruct holding
%only those — so the cells behind a D ratio can be looked at, and re-analysed with Tool 2's own
%machinery rather than a second implementation of it.
%
%   [sel, Tsub] = cs_engage_examples(Tracks, opts)
%
% SELECTION RULE, and why it is this one. A track is kept when at least ONE of its steps STARTS
% inside the zone — the same classification cs_mito_engage uses to build D_bound, so the examples
% are drawn from exactly the population the ratio is computed over. Any other rule would show you
% tracks that did not contribute to the number you are trying to understand.
%
% It is deliberately NOT a ranking. Selecting the most-engaged tracks would make every condition
% look engaged, including the inactive ones, because the ranking is on the quantity being measured.
% "Everything that touches the zone" has no such bias: what comes out is what the condition contains,
% and it can be narrowed afterwards in Tool 2 with the length and distance controls.
%
% INPUT
%   Tracks : a built TrackStruct array
%   opts   : .dUm   engagement distance, um (scalar — the examples are for ONE distance). Default 0.1
%            .key   reference channel, 'mito' (default) or 'er'
%
% OUTPUT
%   sel  : [nCells x 1] struct — .file .cellIndex .cols (kept track columns, 1-based into the
%          cell's matrix) .nBound (bound steps per kept track) .nTracks (before selection)
%   Tsub : a TrackStruct with the SAME cells in the same order, each holding only its kept tracks.
%          Every per-track field is sliced by column, so MSD, Dt, CSD and the channel distances all
%          travel with the tracks. Cells with no kept track are retained with zero tracks rather
%          than dropped, so cellIndex still lines up with the input and with cs_mito_engage's output.
%
% WHY A TrackStruct AND NOT AN XML/CSV EXPORT. Tool 2 opens a .mat directly (Load TrackStruct…), and
% the .mat keeps what a re-import would lose: the MSD curves, the per-localization D, the CSD, the
% organelle distances. Round-tripping through XML would hand Tool 2 a thinner object and make it
% recompute what is already here.

if nargin < 2 || ~isstruct(opts), opts = struct(); end
dUm = getf_(opts,'dUm', 0.1); dUm = dUm(1);
key = getf_(opts,'key', 'mito');

sel = repmat(struct('file','','cellIndex',0,'cols',[],'nBound',[],'nTracks',0), numel(Tracks), 1);
Tsub = Tracks;

for k = 1:numel(Tracks)
    T = Tracks(k);
    sel(k).cellIndex = k;
    if isfield(T,'file'), sel(k).file = char(T.file); end
    if ~isfield(T,'matrix') || isempty(T.matrix), Tsub(k) = sliceCell(T, []); continue; end
    M = T.matrix; [nF, nT, ~] = size(M);
    sel(k).nTracks = nT;
    X = M(:,:,2); Y = M(:,:,3);

    [dv, have] = cs_channel_dist(T, key, 'tracked');
    if ~have || numel(dv) ~= nF*nT, Tsub(k) = sliceCell(T, []); continue; end
    Dm = reshape(dv, nF, nT);
    inZone = Dm <= dUm;

    cols = []; nb = [];
    for j = 1:nT
        rr = find(isfinite(X(:,j)) & isfinite(Y(:,j)));
        if numel(rr) < 2, continue; end
        a = inZone(rr(1:end-1), j);          % where each step STARTED — cs_mito_engage's own rule
        n = sum(a & isfinite(a));
        if n > 0, cols(end+1) = j; nb(end+1) = n; end %#ok<AGROW>
    end
    sel(k).cols = cols; sel(k).nBound = nb;
    Tsub(k) = sliceCell(T, cols);
end
end

% =================================================================================================
function T = sliceCell(T, cols)
% Keep only these track columns, across every field that is laid out per track. Fields are sliced by
% SHAPE rather than by a hardcoded list: matrix is [nF x nT x 3], MSD is [nLag x nT], Dt/CSD are
% [* x nT], and a project's channel distances live under .dist.<key> at [nF x nT]. A named list
% would silently drop whichever field someone adds next, leaving a struct whose columns no longer
% correspond — which is worse than an error.
if ~isfield(T,'matrix') || isempty(T.matrix), return; end
nT = size(T.matrix,2); nF = size(T.matrix,1);
cols = cols(:)';

T.matrix = T.matrix(:, cols, :);
fn = fieldnames(T);
for i = 1:numel(fn)
    f = fn{i};
    if strcmp(f,'matrix'), continue; end
    v = T.(f);
    if isnumeric(v) || islogical(v)
        T.(f) = sliceField(v, cols, nT, nF, f);
    elseif isstruct(v) && isscalar(v)
        sf = fieldnames(v);                                   % .dist.<key>, and anything shaped like it
        for q = 1:numel(sf)
            v.(sf{q}) = sliceField(v.(sf{q}), cols, nT, nF, [f '.' sf{q}]);
        end
        T.(f) = v;
    end
end
end

function v = sliceField(v, cols, nT, nF, name)
% Slice one field to the kept tracks. TWO layouts occur in a real TrackStruct and both must be
% handled:
%   [* x nT (x k)]  the dominant one — matrix, MSD, Dt, CSD, steps, the channel distances
%   [nT x 1]        per-track COLUMN vectors — `lengths` and `trackIDs`
% Only the first was handled at first, so lengths and trackIDs stayed at full width while everything
% else was cut: lengths(j) then described a different track from matrix(:,j,:). Nothing errors on
% that, which is why it is worth being explicit here rather than trusting one shape rule.
if ~(isnumeric(v) || islogical(v)) || isempty(v), return; end
if size(v,2) == nT
    v = v(:, cols, :); return
end
if isvector(v) && numel(v) == nT
    % nF == nT would make a per-frame column indistinguishable from a per-track one. Refuse rather
    % than guess: a wrongly sliced field is a silent mis-association, and the caller is better off
    % told than handed one.
    if nF == nT
        warning('cs_engage_examples:ambiguousField', ...
            ['%s is %d long and this cell has %d frames AND %d tracks, so it cannot be told whether ' ...
             'it is per-frame or per-track. Left unsliced.'], name, numel(v), nF, nT);
        return
    end
    if size(v,1) == nT, v = v(cols, :); else, v = v(:, cols); end
end
end

function v = getf_(s, f, d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
