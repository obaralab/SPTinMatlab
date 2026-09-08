function S = cs_cell_summary(Tracks, opts)
%CS_CELL_SUMMARY  One row per cell: how much data it holds, how dense it is, and every engagement
%number computed on it — so a subset of cells can be chosen on the evidence rather than by eye.
%
%   S = cs_cell_summary(Tracks, opts)
%
% opts : .dUm (0.15) .key ('mito') .sigmaUm (0.030) .minSteps (50) .minLoc (5) .engFrac (0.5)
%        .binUm (0.5) — the grid the FOOTPRINT is measured on, for the density columns
%
% THE DENSITY COLUMNS, and why there are three. "Spot density" can mean three different things and
% they disagree, so all three are reported and none is chosen for you:
%
%   n_loc, n_tracks        raw counts — what a cell contributes to a pooled number
%   footprint_um2          area the cell's localizations actually occupy: the number of occupied
%                          bins on a binUm grid, times the bin area. Not a convex hull, which would
%                          include the empty middle of a spread-out cell and understate density.
%   loc_per_um2            n_loc / footprint_um2      — crowding of localizations
%   tracks_per_um2         n_tracks / footprint_um2   — crowding of MOLECULES, which is the one that
%                          governs mis-linking: two molecules within a link radius of each other can
%                          be swapped, and that depends on how many molecules there are, not on how
%                          many times each was seen.
%
% Every metric column is computed by the same driver the tabs use (cs_mito_engage,
% cs_track_occupancy, cs_zone_kinetics), so a row here and the corresponding row on screen cannot
% drift apart.

if nargin < 2 || ~isstruct(opts), opts = struct(); end
dUm = getf_(opts,'dUm',0.15);  key = getf_(opts,'key','mito');
sig = getf_(opts,'sigmaUm',0.030); mnS = getf_(opts,'minSteps',50);
mnL = getf_(opts,'minLoc',5);  engF = getf_(opts,'engFrac',0.5);
binUm = getf_(opts,'binUm',0.5);

E  = cs_mito_engage(Tracks, struct('dUm',dUm,'key',key,'sigmaUm',sig,'minSteps',mnS));
[~, occ] = cs_track_occupancy(Tracks, struct('dUm',dUm,'key',key,'minLoc',mnL,'engFrac',engF));
kin      = cs_zone_kinetics(Tracks, struct('dUm',dUm,'key',key,'minLoc',mnL));

S = repmat(emptyRow(), numel(Tracks), 1);
for k = 1:numel(Tracks)
    T = Tracks(k); r = emptyRow(); r.cellIndex = k;
    if isfield(T,'file'), r.file = char(T.file); end
    if isfield(T,'matrix') && ~isempty(T.matrix)
        X = T.matrix(:,:,2); Y = T.matrix(:,:,3);
        ok = isfinite(X) & isfinite(Y);
        r.n_tracks = size(X,2);
        r.n_loc    = nnz(ok);
        L = sum(ok,1); L = L(L>0);
        if ~isempty(L), r.med_track_len = median(L); end
        if r.n_loc > 0
            % occupied-bin footprint: unique grid cells the localizations land in
            bx = floor(X(ok)/binUm); by = floor(Y(ok)/binUm);
            r.footprint_um2 = size(unique([bx(:) by(:)],'rows'),1) * binUm^2;
            if r.footprint_um2 > 0
                r.loc_per_um2    = r.n_loc    / r.footprint_um2;
                r.tracks_per_um2 = r.n_tracks / r.footprint_um2;
            end
        end
    end
    r.D_ratio = E(k).Dratio; r.D_bound = E(k).Dbound; r.D_free = E(k).Dfree;
    r.n_bound = E(k).nBound; r.n_free = E(k).nFree;
    r.occ_median = occ(k).occMedian; r.engaged_frac = occ(k).engagedFrac; r.n_scored = occ(k).nScored;
    r.k_off = kin(k).kOff; r.k_on = kin(k).kOn;
    r.n_ended = kin(k).nEnd; r.n_censored = kin(k).nCensored;
    r.t_bound_s = kin(k).tBound; r.t_free_s = kin(k).tFree;
    S(k) = r;
end
end

% =================================================================================================
function r = emptyRow()
r = struct('file','','cellIndex',0,'condition','', ...
           'n_tracks',0,'n_loc',0,'med_track_len',NaN, ...
           'footprint_um2',NaN,'loc_per_um2',NaN,'tracks_per_um2',NaN, ...
           'D_ratio',NaN,'D_bound',NaN,'D_free',NaN,'n_bound',0,'n_free',0, ...
           'occ_median',NaN,'engaged_frac',NaN,'n_scored',0, ...
           'k_off',NaN,'k_on',NaN,'n_ended',0,'n_censored',0,'t_bound_s',0,'t_free_s',0);
end

function v = getf_(s,f,d)
if isstruct(s) && isfield(s,f) && ~isempty(s.(f)), v = s.(f); else, v = d; end
end
