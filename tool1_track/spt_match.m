function cells = spt_match(sptDir, erDir, mitoDir, strip)
%SPT_MATCH  Match single-particle TIFF stacks to their ER/mito segmentation stacks by cell key.
%
%   cells = spt_match(sptDir, erDir, mitoDir, strip)
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
%   erSeg    full path to the matched ER seg, or '' if none / not found
%   mitoSeg  full path to the matched mito seg, or '' if none / not found
%   ok       true when the SPT stack is present (ER/mito are optional)

if nargin < 2, erDir   = ''; end
if nargin < 3, mitoDir = ''; end
if nargin < 4 || isempty(strip), strip = ''; end

sptFiles = list_stacks(sptDir, {'tif','tiff'});
erMap    = key_map(erDir,   'er',   strip, {'tif','tiff','h5','hdf5'});
mitoMap  = key_map(mitoDir, 'mito', strip, {'tif','tiff','h5','hdf5'});

cells = struct('key',{},'spt',{},'erSeg',{},'mitoSeg',{},'ok',{});
for i = 1:numel(sptFiles)
    [~, nm, ext] = fileparts(sptFiles{i});
    key = key_of([nm ext], 'spt', strip);
    er = ''; if isKey(erMap,   key), er = erMap(key);   end
    mi = ''; if isKey(mitoMap, key), mi = mitoMap(key); end
    cells(end+1) = struct('key',key,'spt',sptFiles{i},'erSeg',er,'mitoSeg',mi,'ok',true); %#ok<AGROW>
end
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
function m = key_map(d, chan, strip, exts)
m = containers.Map('KeyType','char','ValueType','char');
if isempty(d) || ~isfolder(d), return; end
fs = list_stacks(d, exts);
for k = 1:numel(fs)
    [~, nm, ext] = fileparts(fs{k});
    key = key_of([nm ext], chan, strip);
    if ~isempty(key) && ~isKey(m, key), m(key) = fs{k}; end   % first match wins
end
end

% -------------------------------------------------------------------------
function k = key_of(name, chan, strip)
k = regexprep(name, '\.(tif|tiff|h5|hdf5)$', '', 'ignorecase');
k = regexprep(k, '[ _](Probabilities|Simple[ _]Segmentation|Segmentation|Uncertainty|Object[ _]Predictions)$', '', 'ignorecase');
if ~isempty(strip)
    k = regexprep(k, strip, '', 'ignorecase');
end
switch lower(chan)
    case 'spt',  suf = '_spt\d*';
    case 'er',   suf = '_(2_TA_BC|er_mip|er)';
    case 'mito', suf = '_(3_TA_BC|mito_mip|ch1_mito|mito)';
    otherwise,   suf = '';
end
if ~isempty(suf)
    k = regexprep(k, [suf '$'], '', 'ignorecase');
end
end
