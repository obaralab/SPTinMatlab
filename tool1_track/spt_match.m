function cells = spt_match(sptDir, erDir, mitoDir, strip)
%SPT_MATCH  Match single-particle TIFF stacks to their ER/mito segmentation stacks by cell key.
%
%   cells = spt_match(sptDir, erDir, mitoDir, strip)   two fixed channels (what Tool 1 uses)
%   cells = spt_match(sptDir, spec, strip)             N channels; spec is a 1xN struct array with
%                                                      fields key / dir / suffix, built by
%                                                      cs_channel_segspec from a project's config
%
% Derives a cell KEY from each filename by stripping (in order) the file extension, an ilastik
% export token, a user 'strip' regex, and the per-channel suffix — then matches SPT <-> ER-seg
% <-> mito-seg on that key. Ported from the ERAware Python matcher (scan_and_match / key_of), so
% the same folder layout that worked there works here.
%
% Channel suffixes (anchored at the end of the name):
%   SPT  '_spt\d*'                       e.g. 250408_WT_012_spt1.tif        -> 250408_WT_012
%   ER   '_(2_TA_BC|er_mip|er)'          e.g. 250408_VAPB_WT_012_2_TA_BC    -> (strip _VAPB) 250408_WT_012
%   mito '_(3_TA_BC|mito_mip|ch1_mito|mito)'
% The 'strip' regex (e.g. '_VAPB') reconciles names where the SPT file lacks a token the
% segmentation files carry.
%
% INPUT
%   sptDir  : folder of single-particle TIFF stacks (required)
%   erDir   : folder of ER segmentation stacks; '' if none (ER-penalty / ER-geodesic then unavailable)
%   mitoDir : folder of mito segmentation stacks; '' if none (no per-spot mito distance)
%   strip   : extra regex stripped from every name before keying; '' for none
%
% OUTPUT  cells : 1xN struct (one per SPT stack) with fields
%   key      matched cell identifier
%   spt      full path to the SPT stack
%   seg      struct with ONE FIELD PER CHANNEL KEY holding that channel's matched path ('' if not
%            found) — the keyed form, and the only one that works for a channel this file has no
%            legacy name for
%   erSeg    full path to the matched ER seg, or '' if none / not found   } kept in step-2 style
%   mitoSeg  full path to the matched mito seg, or '' if none / not found } dual-write: 30 call
%                                                                          sites still read these
%   ok       true when the SPT stack is present (every reference channel is optional)

if nargin < 2, erDir   = ''; end
if nargin < 3, mitoDir = ''; end
if nargin < 4 || isempty(strip), strip = ''; end

% Two call shapes. The general one takes a SPEC — plain (key, dir, suffix) data, deliberately not a
% config object, so this file stays free of any tool2_analyze dependency. Tool 2 builds the spec
% with cs_channel_segspec; Tool 1 and every existing caller keep the two-folder form, which is just
% the spec for today's two channels.
if isstruct(erDir)
    spec = erDir;
    if nargin >= 3 && ~isempty(mitoDir), strip = mitoDir; end   % spt_match(sptDir, spec, strip)
else
    spec = struct('key',{'er','mito'}, ...
                  'dir',{erDir, mitoDir}, ...
                  'suffix',{'_(2_TA_BC|er_mip|er)', '_(3_TA_BC|mito_mip|ch1_mito|mito)'});
end

sptFiles = list_stacks(sptDir, {'tif','tiff'});
maps = cell(1, numel(spec));
for c = 1:numel(spec)
    maps{c} = key_map(spec(c).dir, spec(c).suffix, strip, {'tif','tiff','h5','hdf5'});
end

cells = emptyCells(spec);
for i = 1:numel(sptFiles)
    [~, nm, ext] = fileparts(sptFiles{i});
    key = key_of([nm ext], '_spt\d*', strip);
    seg = struct();
    for c = 1:numel(spec)
        p = ''; if isKey(maps{c}, key), p = maps{c}(key); end
        seg.(spec(c).key) = p;
    end
    % Keyed container plus the flat erSeg/mitoSeg the other 30 call sites still read. Same
    % dual-write as the rest of the migration: a channel with no legacy name is keyed-only.
    e = struct('key',key,'spt',sptFiles{i},'seg',seg, ...
        'erSeg',getf_(seg,'er'),'mitoSeg',getf_(seg,'mito'),'ok',true);
    cells(end+1) = e; %#ok<AGROW>
end
end

% -------------------------------------------------------------------------
function c = emptyCells(~)
c = struct('key',{},'spt',{},'seg',{},'erSeg',{},'mitoSeg',{},'ok',{});
end

function v = getf_(s, f)
v = ''; if isfield(s,f), v = s.(f); end
end

% -------------------------------------------------------------------------
function files = list_stacks(d, exts)
files = {};
if isempty(d) || ~isfolder(d), return; end
for e = 1:numel(exts)
    L = dir(fullfile(d, ['*.' exts{e}]));
    for k = 1:numel(L)
        if ~L(k).isdir, files{end+1} = fullfile(L(k).folder, L(k).name); end %#ok<AGROW>
    end
end
files = unique(files);
end

% -------------------------------------------------------------------------
function m = key_map(d, suf, strip, exts)
m = containers.Map('KeyType','char','ValueType','char');
if isempty(d) || ~isfolder(d), return; end
fs = list_stacks(d, exts);
for k = 1:numel(fs)
    [~, nm, ext] = fileparts(fs{k});
    key = key_of([nm ext], suf, strip);
    if ~isempty(key) && ~isKey(m, key), m(key) = fs{k}; end   % first match wins
end
end

% -------------------------------------------------------------------------
function k = key_of(name, suf, strip)
% suf is the channel's own suffix REGEX, anchored at the end — passed in rather than looked up from
% a channel name, so a project can declare a channel this file has never heard of.
k = regexprep(name, '\.(tif|tiff|h5|hdf5)$', '', 'ignorecase');
k = regexprep(k, '[ _](Probabilities|Simple[ _]Segmentation|Segmentation|Uncertainty|Object[ _]Predictions)$', '', 'ignorecase');
if ~isempty(strip)
    k = regexprep(k, strip, '', 'ignorecase');
end
if ~isempty(suf)
    k = regexprep(k, [suf '$'], '', 'ignorecase');
end
end
