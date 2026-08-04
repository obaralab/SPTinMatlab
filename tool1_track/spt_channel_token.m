function [tok, info] = spt_channel_token(sptDir, erDir, mitoDir)
%SPT_CHANNEL_TOKEN  Work out the SPT channel token from the files, instead of asking for it.
%
%   [tok, info] = spt_channel_token(sptDir, erDir, mitoDir)
%
%   tok  : the token to strip from SPT names so they key against the segmentations ('_C3', '_VAPB',
%          …), or '' when none is needed / none could be determined.
%   info : .candidates  every token that would work, most-supported first
%          .nMatched    cells the winning token resolves
%          .nTotal      SPT cells present
%          .why         one line of plain English, for a status bar
%
% WHY THIS EXISTS
% The token was a typed setting. Tool 1 asks for it in a text box defaulted to '_VAPB'; Tool 2 had it
% HARDCODED to '_VAPB' with no way to change it, so the moment a dataset used a different channel
% name — '_C3' here — every ER and mito overlay silently failed to resolve and the tab just showed
% nothing. Nothing was broken enough to raise an error; the files simply never matched.
%
% But the answer is sitting in the folder. A segmentation is named for the CELL, and the SPT stack is
% named for the cell plus a channel token, so the token is whatever the SPT base has that the
% segmentation key does not. Deriving it needs no setting and cannot go stale when the naming
% changes.
%
% Strictly a suffix match: '<cell><token>' against '<cell>'. That is the convention every dataset in
% this pipeline has used, and guessing at infixes would trade a clear failure for a wrong answer.

tok = ''; info = struct('candidates',{{}},'nMatched',0,'nTotal',0,'why','');
if nargin < 2, return; end

spt = baseNames(sptDir, {'.tif','.tiff'});
info.nTotal = numel(spt);
if isempty(spt), info.why = 'no SPT stacks found'; return; end

% Segmentation keys, with the seg suffix removed — the same suffixes spt_match strips, so the two
% agree about what a cell is called.
segs = [segKeys(erDir, '_(2_TA_BC|er_mip|er)'), segKeys(mitoDir, '_(3_TA_BC|mito_mip|ch1_mito|mito)')];
segs = reshape(unique(segs), 1, []);
if isempty(segs), info.why = 'no ER or mito segmentations found'; return; end

% For every (spt, seg) pair where the seg key is a prefix of the SPT base, the remainder is a
% candidate token. Count how many cells each candidate would resolve.
cand = containers.Map('KeyType','char','ValueType','double');
for i = 1:numel(spt)
    b = spt{i};
    for j = 1:numel(segs)
        s = segs{j};
        if strncmpi(b, s, numel(s)) && numel(b) > numel(s)
            t = b(numel(s)+1:end);
            if isKey(cand,t), cand(t) = cand(t) + 1; else, cand(t) = 1; end
        elseif strcmpi(b, s)
            if isKey(cand,''), cand('') = cand('') + 1; else, cand('') = 1; end
        end
    end
end
if cand.Count == 0
    info.why = sprintf('none of the %d segmentation name(s) is a prefix of any SPT name', numel(segs));
    return;
end

ks = keys(cand); vs = cell2mat(values(cand));
% Most cells resolved wins. A tie goes to the LONGER token: '_C3' and '' can both "work" when one
% cell happens to be named without the channel, and the longer one is the real convention.
[~, ord] = sortrows([-vs(:), -cellfun(@numel,ks(:))]);
ks = ks(ord); vs = vs(ord);
tok = ks{1};
info.candidates = ks;
info.nMatched = vs(1);
if isempty(tok)
    info.why = sprintf('SPT and segmentation names match directly (%d/%d cells)', vs(1), info.nTotal);
else
    info.why = sprintf('channel token "%s" read from the file names (%d/%d cells)', tok, vs(1), info.nTotal);
end
end

% =================================================================================================
function b = baseNames(d, exts)
b = {};
if isempty(d) || ~isfolder(d), return; end
for e = exts
    L = dir(fullfile(d, ['*' e{1}]));
    for k = 1:numel(L)
        if L(k).isdir, continue; end
        [~,n] = fileparts(L(k).name);
        b{end+1} = n; %#ok<AGROW>
    end
end
b = reshape(unique(b), 1, []);   % always a row, so callers can concatenate without surprises
end

function k = segKeys(d, suf)
% A segmentation's cell key: drop the extension, the ilastik export token, then the channel suffix —
% the same order spt_match's key_of uses, so both agree on what the cell is called.
k = {};
if isempty(d) || ~isfolder(d), return; end
% Indexed, not `for n = names`: unique() returns a COLUMN, and a for-loop over an empty column
% still runs one iteration with an empty value — which is exactly the no-mito-folder case.
names = baseNames(d, {'.tif','.tiff','.h5','.hdf5'});
for q = 1:numel(names)
    s = regexprep(names{q}, '[ _](Probabilities|Simple[ _]Segmentation|Segmentation|Uncertainty|Object[ _]Predictions)$', '', 'ignorecase');
    s = regexprep(s, [suf '$'], '', 'ignorecase');
    if ~isempty(s), k{end+1} = s; end %#ok<AGROW>
end
k = reshape(unique(k), 1, []);
end
