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
% Slicing is cs_track_slice's job — shared with the exclusion list, so the two-layout lesson
% (`lengths` and `trackIDs` are [nT x 1], everything else [* x nT]) is learned in one place.
%
% WHY A TrackStruct AND NOT AN XML/CSV EXPORT. Tool 2 opens a .mat directly (Load TrackStruct…), and
% the .mat keeps what a re-import would lose: the MSD curves, the per-localization D, the CSD, the
% organelle distances. Round-tripping through XML would hand Tool 2 a thinner object and make it
% recompute what is already here.

if nargin < 2 || ~isstruct(opts), opts = struct(); end
dUm = getf_(opts,'dUm', 0.1); dUm = dUm(1);
key = getf_(opts,'key', 'mito');

sel = repmat(struct('file','','cellIndex',0,'cols',[],'nBound',[],'nTracks',0), numel(Tracks), 1);
% Collected in a cell and concatenated at the end: cs_track_slice ADDS .srcCols, and assigning a
% struct with an extra field into an element of a narrower struct array is an error in MATLAB.
Tc = cell(numel(Tracks),1);

for k = 1:numel(Tracks)
    T = Tracks(k);
    sel(k).cellIndex = k;
    if isfield(T,'file'), sel(k).file = char(T.file); end
    if ~isfield(T,'matrix') || isempty(T.matrix), Tc{k} = cs_track_slice(T, []); continue; end
    M = T.matrix; [nF, nT, ~] = size(M);
    sel(k).nTracks = nT;
    X = M(:,:,2); Y = M(:,:,3);

    [dv, have] = cs_channel_dist(T, key, 'tracked');
    if ~have || numel(dv) ~= nF*nT, Tc{k} = cs_track_slice(T, []); continue; end
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
    Tc{k} = cs_track_slice(T, cols);
end
Tsub = vertcat(Tc{:})';
if isempty(Tsub), Tsub = Tracks([]); end
end

% =================================================================================================
function v = getf_(s, f, d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
