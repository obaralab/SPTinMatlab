function spt_channel_stem_smoke()
%SPT_CHANNEL_STEM_SMOKE  One rule for the channel token, used in both directions.
%
% WHAT IS ASSERTED:
%   1. COMPOSE AND SPLIT ARE INVERSES, on the cell names this pipeline actually produces.
%   2. A SINGLE-COLOUR PROJECT IS UNTOUCHED: an empty key composes to the bare base, so every name
%      written before this existed is still written exactly the same.
%   3. THE SEPARATOR SURVIVES REAL NAMES. Cell names here are full of single underscores, so a
%      single-underscore token would read '..._spt' as a channel called 'spt' on every dataset that
%      exists. Splitting one of those must find NO channel.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);

real = {'HVK-3C-NoLigand-Baseline_Plate2-002_ch24_spt', '250408_WT_012_C3', 'cellA', ...
        'a_b_c_d_spt1', 'HVK-3C-Plate1-296-002_ch24_spt'};

%% (1) inverses ---------------------------------------------------------------------------------
for i = 1:numel(real)
    for k = {'ch1','ch2','red','ch10'}
        st = spt_channel_stem(real{i}, k{1});
        [b, kk] = spt_channel_stem(st);
        assert(strcmp(b, real{i}) && strcmp(kk, k{1}), ...
            'compose/split disagree on "%s" + "%s" -> "%s" -> "%s" + "%s"', real{i}, k{1}, st, b, kk);
    end
end

%% (2) a single-colour project keeps its names --------------------------------------------------
for i = 1:numel(real)
    assert(strcmp(spt_channel_stem(real{i}, ''), real{i}), ...
        'an empty key must compose to the bare base, got "%s"', spt_channel_stem(real{i}, ''));
end

%% (3) a real name carries no accidental channel ------------------------------------------------
for i = 1:numel(real)
    [b, k] = spt_channel_stem(real{i});
    assert(strcmp(b, real{i}) && isempty(k), ...
        ['"%s" has no channel token, but splitting it found base "%s" key "%s" — a single ' ...
         'underscore separator would do exactly this to every cell in the dataset'], real{i}, b, k);
end
% and the one thing that WOULD be ambiguous under a single underscore is not, under two
[b2, k2] = spt_channel_stem('cell_ch2');
assert(strcmp(b2,'cell_ch2') && isempty(k2), 'a single underscore is not a channel separator');

fprintf('channel stem: %d real cell names round-trip through 4 keys; none carries an accidental token\n', numel(real));
fprintf('\nCHANNEL-STEM SMOKE PASSED.\n');
end
