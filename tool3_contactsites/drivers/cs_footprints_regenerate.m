function R = cs_footprints_regenerate(anaDir, opts)
%CS_FOOTPRINTS_REGENERATE  Replace every contact-site outline with the automatic half-max outline at
%the outline smoothing (cs_outline_sigma), keeping each site's centre, window and deletion.
%
%   R = cs_footprints_regenerate(anaDir)
%   R = cs_footprints_regenerate(anaDir, struct('sigmaNm',100, 'frac',0.5, 'maxRadiusUm',0.6))
%
% WHY: outlines drawn or computed on the picker's 240 nm density are ~5x the size of the published
% VAPB outlines (cs_outline_sigma). This redoes them all at the finer scale in one go.
%
% FOR EACH SITE that is not deleted, starting from the refinement as saved (cs_footprints_resolve):
%   - the window's density at sigmaNm, from the same localizations the picker used (hand-rejected
%     tracks blanked);
%   - the half-max outline around the SAVED CENTRE - yours where you placed or moved it - with the
%     local peak looked for within min(maxR, 3σ) of it;
%   - if that centre is not inside the outline (it sat between two dense spots that the 240 nm
%     blur had merged, so the outline went to the nearer one), the centre moves to the outline's
%     density peak so that the two agree, and the site gets a NOTE saying so. Review those.
% Deleted sites stay deleted. Every regenerated outline is saved as a Refine edit (mode
% 'halfmax', sigmaNm recorded), so the mapper and the export use it as it is.
%
% WRITES (nothing is overwritten without a copy):
%   analysis/CS_footprints_before_regen_<stamp>.mat   the file as it was (when there was one)
%   analysis/CS_footprints.mat                        CSfoot, CSdeleted, outlineSigmaNm
%   analysis/CS_footprints_regen_<stamp>.csv          one row per site: old vs new area and mode,
%                                                     how far the centre moved, the note
% The mapper's results (CSW_final.mat) are NOT rerun: press Run mapper on the Sites tab.
%
% R: .n .nDeleted .nMoved .nBox .areaOld .areaNew (medians, µm²) .sigmaNm .backup .report .file

if nargin < 2 || ~isstruct(opts), opts = struct(); end
sigNm = getf(opts, 'sigmaNm', []); if isempty(sigNm), sigNm = cs_outline_sigma(anaDir); end
frac  = getf(opts, 'frac', 0.5);
maxRu = getf(opts, 'maxRadiusUm', 0.6);
verb  = getf(opts, 'verbose', true);

F = cs_footprints_resolve(anaDir, struct('outlineSigmaNm', sigNm));
assert(~isempty(F), 'cs_footprints_regenerate:noSites', 'No picked sites in %s', anaDir);
Fold = F;

tsPath = cs_active_trackstruct(anaDir);
S = load(tsPath); fn = fieldnames(S); Tracks = S.(fn{1});
try, Tracks = cs_track_exclusions('blank', cs_track_exclusions('load', fileparts(regexprep(char(anaDir),'[\\/]+$',''))), Tracks); catch, end

moved = zeros(numel(F), 1);
dcache = containers.Map('KeyType','char','ValueType','any');
for q = 1:numel(F)
    e = F(q);
    if e.deleted, continue; end
    [sig, peakR] = cs_outline_sigma('scale', sigNm, e.SF, maxRu);
    key = sprintf('%d|%g|%g|%s|%d|%.9g', e.cellIndex, e.winFrames(1), e.winFrames(2), e.densSrc, e.grid, e.SF);
    if isKey(dcache, key), D = dcache(key);
    else
        T = Tracks(e.cellIndex);
        if strcmp(e.densSrc, 'tracked')
            sX = reshape(T.matrix(:,:,2),[],1); sY = reshape(T.matrix(:,:,3),[],1); sF = reshape(T.matrix(:,:,1),[],1);
        else
            a = T.allSpots; sX = a.X(:); sY = a.Y(:); sF = a.FRAME(:);
        end
        [~, D] = cs_window_density(sX, sY, sF, e.winFrames(1), e.winFrames(2), e.SF, e.grid, e.grid, sig);
        dcache(key) = D;
    end
    fpo = struct('mode','halfmax','frac',frac,'maxRadiusUm',maxRu,'boxHalfWidthUm',0.5,'peakRadiusUm',peakR);
    c = e.center(:)';
    fp = cs_window_footprint(D, c / e.SF, e.SF, fpo);
    note = '';
    if strcmp(fp.mode, 'halfmax') && ~inpolygon(0, 0, fp.refboundary(:,1), fp.refboundary(:,2))
        % centre -> the outline's density peak; the outline itself stays where it is on the map
        [rr, cc] = find(fp.bw); [~, i] = max(D(fp.bw));
        c2 = [cc(i) rr(i)] * e.SF;
        moved(q) = hypot(c2(1) - c(1), c2(2) - c(2));
        fp.refboundary = fp.refboundary + (c - c2);
        c = c2;
        note = sprintf(['centre moved %.0f nm to the outline''s density peak: the saved centre was ' ...
                        'between dense spots, outside the regenerated outline'], 1000 * moved(q));
    elseif ~strcmp(fp.mode, 'halfmax')
        note = sprintf('no half-max patch at %g nm: fell back to a %s', sigNm, fp.mode);
    end
    F(q).center = c; F(q).refboundary = fp.refboundary; F(q).mode = fp.mode;
    F(q).frac = frac; F(q).maxRadiusUm = maxRu; F(q).areaUm2 = fp.areaUm2;
    F(q).sigmaNm = sigNm; F(q).note = note; F(q).edited = true;
end

% ---- write: backup, footprints, report ------------------------------------------------------------
stamp = char(datetime('now', 'Format', 'yyyyMMdd_HHmmss'));
f = fullfile(anaDir, 'CS_footprints.mat');
backup = '';
CSdeleted = struct('file',{},'csID',{},'window',{},'pickPx',{});
if isfile(f)
    backup = fullfile(anaDir, ['CS_footprints_before_regen_' stamp '.mat']);
    ok = copyfile(f, backup);
    assert(ok, 'cs_footprints_regenerate:backup', 'Could not back up %s - nothing was changed', f);
    try, L = load(f, 'CSdeleted'); if isfield(L,'CSdeleted') && ~isempty(L.CSdeleted), CSdeleted = L.CSdeleted; end, catch, end
end
del = [F.deleted];
CSfoot = F(~del); outlineSigmaNm = sigNm;
neighbourBoxUm = cs_neighbour_box(anaDir); %#ok<NASGU>    % the box setting survives a regeneration
save(f, 'CSfoot', 'CSdeleted', 'outlineSigmaNm', 'neighbourBoxUm', '-v7.3');

rep = fullfile(anaDir, ['CS_footprints_regen_' stamp '.csv']);
rows = cell(nnz(~del), 12); r = 0;
for q = find(~del)
    r = r + 1; o = Fold(q); e = F(q);
    rows(r,:) = {e.file, e.cellIndex, e.csID, e.window, logical(e.mito), char(o.mode), o.areaUm2, ...
                 numOr(o.sigmaNm), e.mode, e.areaUm2, round(1000 * moved(q)), e.note};
end
Tr = cell2table(rows, 'VariableNames', {'file','cell','csID','window','mito','old_outline', ...
    'old_area_um2','old_sigma_nm','new_outline','new_area_um2','centre_moved_nm','note'});
writetable(Tr, rep);

R = struct('n', nnz(~del), 'nDeleted', nnz(del), 'nMoved', nnz(moved > 0), ...
    'nBox', nnz(~del & ~strcmp({F.mode}, 'halfmax')), ...
    'areaOld', median([Fold(~del).areaUm2]), 'areaNew', median([F(~del).areaUm2]), ...
    'sigmaNm', sigNm, 'backup', backup, 'report', rep, 'file', f);
if verb
    fprintf(['cs_footprints_regenerate: %d outline(s) at %g nm (median %.3f -> %.3f um^2), ' ...
             '%d centre(s) moved, %d box fallback(s), %d deleted kept deleted\n'], ...
        R.n, sigNm, R.areaOld, R.areaNew, R.nMoved, R.nBox, R.nDeleted);
    if ~isempty(backup), fprintf('  previous outlines: %s\n', backup); end
    fprintf('  per-site report:   %s\n', rep);
end
end

function v = numOr(x), if isempty(x), v = NaN; else, v = double(x); end, end
function v = getf(s,f,d), if isstruct(s)&&isfield(s,f)&&~isempty(s.(f)), v=s.(f); else, v=d; end, end
