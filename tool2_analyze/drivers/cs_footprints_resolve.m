function [F, info, Fauto] = cs_footprints_resolve(anaDir, opts)
%CS_FOOTPRINTS_RESOLVE  Every picked contact site with its SAVED refinement applied — the footprint
%set as it currently stands, not as the picker first proposed it.
%
%   [F, info, Fauto] = cs_footprints_resolve(anaDir, opts)
%
% Builds the auto footprint for every site in csIDs/*_CSsites.txt (cs_footprints_build), then merges
% analysis/CS_footprints.mat onto it: edited footprints replace the auto ones (centre, boundary,
% mode, area, ...) and deleted sites are flagged .deleted = true. Nothing is dropped, so a caller
% can show deleted sites or skip them.
%
% A saved edit is matched on (file, csID, window) AND on its original pick position. csID is a
% positional index, so a CS_footprints.mat left over from an earlier pick-set would otherwise put a
% refined boundary on whatever site now has that number.
%
% info: .nMerged .nDeleted .nStale (saved edits whose pick no longer matches any site)
% Fauto: the same sites BEFORE anything saved was applied — the automatic outline around each pick,
%        with .deleted / .edited copied over so a caller can say what became of each one.
%
% Used by the Refine tab and by the advisor export, so what you refine is what gets exported.
% opts go to cs_footprints_build (e.g. .outlineSigmaNm for the automatic outlines).

if nargin < 2 || ~isstruct(opts), opts = struct(); end
if ~isfield(opts,'save'),    opts.save = false;    end
if ~isfield(opts,'verbose'), opts.verbose = false; end
F = cs_footprints_build(anaDir, opts);
info = struct('nMerged',0,'nDeleted',0,'nStale',0);
Fauto = F;
if isempty(F), return; end
for q = 1:numel(F)
    if ~isfield(F,'edited')  || isempty(F(q).edited),  F(q).edited  = false; end
    if ~isfield(F,'deleted') || isempty(F(q).deleted), F(q).deleted = false; end
end
Fauto = F;
f = fullfile(anaDir, 'CS_footprints.mat');
if ~isfile(f), return; end
try, L = load(f); catch, return; end
if isfield(L,'CSfoot') && ~isempty(L.CSfoot)
    for q = 1:numel(L.CSfoot)
        m = matchFoot(F, L.CSfoot(q));
        if m > 0, F(m) = mergeFoot(F(m), L.CSfoot(q)); info.nMerged = info.nMerged + 1;
        else,     info.nStale = info.nStale + 1; end
    end
end
if isfield(L,'CSdeleted') && ~isempty(L.CSdeleted)
    for q = 1:numel(L.CSdeleted)
        m = matchFoot(F, L.CSdeleted(q));
        if m > 0, F(m).deleted = true; info.nDeleted = info.nDeleted + 1;
        else,     info.nStale = info.nStale + 1; end
    end
end
for q = 1:numel(F), Fauto(q).edited = F(q).edited; Fauto(q).deleted = F(q).deleted; end
end

% =================================================================================================
function m = matchFoot(FF, ff)
% Index in FF of the site matching ff (file + csID + window, pick-validated); 0 if none.
m = 0;
for i = 1:numel(FF)
    if strcmp(FF(i).file, ff.file) && FF(i).csID == ff.csID && FF(i).window == ff.window
        ok = true;
        if isfield(ff,'pickPx') && numel(ff.pickPx) == 2 && isfield(FF(i),'pickPx') && numel(FF(i).pickPx) == 2
            ok = hypot(FF(i).pickPx(1)-ff.pickPx(1), FF(i).pickPx(2)-ff.pickPx(2)) < 1.5;
        end
        if ok, m = i; return; end
    end
end
end

function b = mergeFoot(b, s)
for fld = {'center','refboundary','mode','frac','maxRadiusUm','areaUm2'}
    if isfield(s, fld{1}) && ~isempty(s.(fld{1})), b.(fld{1}) = s.(fld{1}); end
end
% The smoothing a SAVED outline was made at is the saved one's, not today's setting. An outline
% saved before it was recorded was drawn on the picker's 240 nm density, or computed from it,
% but that cannot be told from the file: NaN, not a guess.
b.sigmaNm = NaN; if isfield(s,'sigmaNm') && ~isempty(s.sigmaNm), b.sigmaNm = s.sigmaNm; end
b.note = '';     if isfield(s,'note') && ~isempty(s.note), b.note = char(s.note); end
b.edited = true;
end
