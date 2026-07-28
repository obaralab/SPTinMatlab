function cells = scan_experiment(tracksDir, mitoDir, erDir, mitoPat, erPat, prefixStrip)
%SCAN_EXPERIMENT  Discover cells from a tracks folder and match their max-int
% mito / ER images by a NAME PATTERN across the three type-folders.
%
%   cells = scan_experiment(tracksDir, mitoDir, erDir, mitoPat, erPat, prefixStrip)
%
% Each cell's PREFIX is the tracks base (filename minus _tracks[_filtered].xml)
% with an optional trailing token stripped, because the tracks files often carry
% an extra token the images don't. Example:
%   tracks : 250408_FFAT_001_spt1_tracks.xml   -> base 250408_FFAT_001_spt1
%   prefixStrip '_spt\d+'                       -> prefix 250408_FFAT_001
%   mitoPat '{prefix}_mito_mip.tif'             -> 250408_FFAT_001_mito_mip.tif
%   erPat   '{prefix}_er_mip.tif'               -> 250408_FFAT_001_er_mip.tif
%
% Patterns may contain '*' wildcards and the literal token {prefix}. Defaults:
%   mitoPat     = '{prefix}_mito_mip.tif'
%   erPat       = '{prefix}_er_mip.tif'
%   prefixStrip = '_spt\d+'   (regex removed from the END of the tracks base;
%                              '' = use the full base as the prefix)
%
% Returns a struct array (one per cell): .name (tracks base) .prefix .tracks
% .spots .mito .er .mitoN .erN (0=missing, >1=ambiguous) .condition.

if nargin<4 || isempty(mitoPat), mitoPat = '{prefix}_mito_mip.tif'; end
if nargin<5 || isempty(erPat),   erPat   = '{prefix}_er_mip.tif';   end
if nargin<6,                     prefixStrip = '_spt\d+';           end

cells = struct('name',{},'prefix',{},'tracks',{},'spots',{},'mito',{},'er',{}, ...
               'mitoN',{},'erN',{},'condition',{});
if isempty(tracksDir) || ~isfolder(tracksDir), return; end

xmls = [dir(fullfile(tracksDir,'*_tracks.xml')); dir(fullfile(tracksDir,'*_tracks_filtered.xml'))];
if isempty(xmls), xmls = dir(fullfile(tracksDir,'*.xml')); end
xmls = xmls(~[xmls.isdir]);

seen = containers.Map('KeyType','char','ValueType','logical');
for i = 1:numel(xmls)
    xb   = xmls(i).name;
    base = regexprep(xb, '_tracks(_filtered)?\.xml$', '', 'ignorecase');
    base = regexprep(base, '\.xml$', '', 'ignorecase');
    if isempty(base) || isKey(seen,base), continue; end
    seen(base) = true;

    if isempty(prefixStrip), prefix = base;
    else, prefix = regexprep(base, [prefixStrip '$'], '', 'ignorecase');
    end

    [mp, mn] = local_match(mitoDir, subst(mitoPat, prefix));
    [ep, en] = local_match(erDir,   subst(erPat,   prefix));
    c = struct('name',base,'prefix',prefix, ...
        'tracks', fullfile(tracksDir, xb), ...
        'spots',  local_firstmatch(tracksDir, [base '*spots*.csv']), ...
        'mito',   mp, 'er', ep, 'mitoN', mn, 'erN', en, 'condition', '');
    cells(end+1) = c; %#ok<AGROW>
end
end

% -------------------------------------------------------------------------
function pat = subst(pat, prefix)
pat = strrep(pat, '{prefix}', prefix);
end

% -------------------------------------------------------------------------
function [p, n] = local_match(d, pat)
% Match a filename pattern (may contain '*') in folder d. Returns the first
% match + the count (n=0 missing, n>1 ambiguous).
p = ''; n = 0;
if isempty(d) || ~isfolder(d) || isempty(pat), return; end
f = dir(fullfile(d, pat)); f = f(~[f.isdir]);
n = numel(f);
if n >= 1, p = fullfile(d, f(1).name); end
end

% -------------------------------------------------------------------------
function p = local_firstmatch(d, pat)
p = '';
if isempty(d) || ~isfolder(d), return; end
f = dir(fullfile(d, pat)); f = f(~[f.isdir]);
if ~isempty(f), p = fullfile(d, f(1).name); end
end
