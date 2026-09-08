function T = cs_track_slice(T, cols)
%CS_TRACK_SLICE  Keep only these track columns of one TrackStruct cell, across every field that is
%laid out per track.
%
%   T = cs_track_slice(T, cols)      cols: 1-based track columns to KEEP, into T.matrix
%
% Fields are sliced by SHAPE rather than from a named list, so a field added later cannot be quietly
% left at full width with its columns no longer corresponding to the matrix. TWO layouts occur in a
% real TrackStruct and both are handled:
%
%   [* x nT (x k)]   the dominant one — matrix, MSD, MSDerror, Dt, CSD, steps, vector, intens,
%                    and the channel distances under .dist.<key>
%   [nT x 1]         per-track COLUMN vectors — `lengths`, `trackIDs`
%
% Only the first was handled when this logic lived inside cs_engage_examples, so on a real build
% `lengths` and `trackIDs` stayed at 262 entries beside 95 kept tracks and lengths(j) described a
% different track from matrix(:,j,:). NOTHING ERRORS ON THAT. It is the reason this is one shared
% function rather than a rule each caller reimplements.
%
% .srcCols records the ORIGINAL column of each kept track. A sliced struct renumbers its tracks from
% 1, so without it "track 30" of a subset cannot be mapped back to track 30 of the build — and a
% curation decision made while looking at a subset would be recorded against the wrong track.
% Slicing an already-sliced struct composes correctly, because srcCols is carried through.
%
% Where nF == nT a [nT x 1] column cannot be told from a per-frame one; the field is left alone and
% a warning is issued, because a wrongly sliced field is a silent mis-association and the caller is
% better off told than handed one.

% A cell with no tracks still gets .srcCols, empty. Returning without it left a struct array in
% which SOME cells carried the field and some did not, and MATLAB refuses to concatenate those —
% "the number of fields in structure arrays being concatenated do not match", thrown from the
% caller's vertcat, several frames away from the cause. A real 93-cell plate has such cells; no
% fixture did until this was found.
if ~isfield(T,'matrix') || isempty(T.matrix)
    T.srcCols = zeros(1,0); return
end
nT = size(T.matrix,2); nF = size(T.matrix,1);
cols = cols(:)';

% Original identity FIRST, so it survives the slice and composes across repeated slicing.
if isfield(T,'srcCols') && numel(T.srcCols) == nT, src = T.srcCols(:)'; else, src = 1:nT; end

T.matrix = T.matrix(:, cols, :);
fn = fieldnames(T);
for i = 1:numel(fn)
    f = fn{i};
    if strcmp(f,'matrix') || strcmp(f,'srcCols'), continue; end
    v = T.(f);
    if isnumeric(v) || islogical(v)
        T.(f) = sliceField(v, cols, nT, nF, f);
    elseif isstruct(v) && isscalar(v)
        sf = fieldnames(v);
        for q = 1:numel(sf)
            v.(sf{q}) = sliceField(v.(sf{q}), cols, nT, nF, [f '.' sf{q}]);
        end
        T.(f) = v;
    end
end
T.srcCols = src(cols);
end

% =================================================================================================
function v = sliceField(v, cols, nT, nF, name)
if ~(isnumeric(v) || islogical(v)) || isempty(v), return; end
if size(v,2) == nT
    v = v(:, cols, :); return
end
if isvector(v) && numel(v) == nT
    if nF == nT
        warning('cs_track_slice:ambiguousField', ...
            ['%s is %d long and this cell has %d frames AND %d tracks, so it cannot be told whether ' ...
             'it is per-frame or per-track. Left unsliced.'], name, numel(v), nF, nT);
        return
    end
    if size(v,1) == nT, v = v(cols, :); else, v = v(:, cols); end
end
end
