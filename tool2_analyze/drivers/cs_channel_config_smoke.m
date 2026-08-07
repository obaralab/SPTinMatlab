function cs_channel_config_smoke()
% Headless validation of the per-project channel config (cs_channel_config, cs_channel_segspec) and
% of the derived support mask (cs_support_mask) that replaces the whole-frame fallback when a
% project declares no support channel.
%
% Everything is synthetic and written to a scratch folder. No dataset is read.
here = fileparts(mfilename('fullpath'));
addpath(here);
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));   % spt_match / spt_channel_token

scratch = fullfile(tempdir, sprintf('cs_chan_cfg_smoke_%d', feature('getpid')));
cleanup = onCleanup(@() rmIfThere(scratch));
rmIfThere(scratch); mkdir(scratch);

fprintf('\n========== PART A: the built-in default ==========\n');
[c, info] = cs_channel_config(scratch);
assert(strcmp(info.source,'default'), 'a project with no channels.json must get the built-in default');
assert(numel(c)==2 && isequal({c.key},{'er','mito'}), 'the default is ER + mito, in that order');
assert(strcmp(c(1).role,'support') && strcmp(c(2).role,'proximity'), 'roles unchanged');
% The default MUST reproduce today's conventions exactly — every existing dataset depends on it.
assert(strcmp(c(1).folder,'er_seg') && strcmp(c(2).folder,'mito_seg'), 'folders unchanged');
assert(strcmp(c(1).suffix,'_(2_TA_BC|er_mip|er)'), 'ER suffix regex unchanged');
assert(strcmp(c(2).suffix,'_(3_TA_BC|mito_mip|ch1_mito|mito)'), 'mito suffix regex unchanged');
assert(isequal(cs_channel_keys(c), cs_channel_keys()), 'default config == built-in key list');
fprintf('  default: %s (%s)\n', strjoin({c.key},', '), strjoin({c.role},', '));

fprintf('\n========== PART B: a project declares its own ==========\n');
% One channel, inheriting the built-in conventions — declaring "ER only" is two lines, not a
% transcription of the regexes.
writeCfg(scratch, '{"channels":[{"key":"er","role":"support"}]}');
c1 = cs_channel_config(scratch);
assert(isscalar(c1) && strcmp(c1.key,'er'), 'one channel');
assert(strcmp(c1.folder,'er_seg') && strcmp(c1.suffix,'_(2_TA_BC|er_mip|er)'), ...
    'a redeclared er inherits the built-in folder and suffix');
assert(isempty(cs_channel_keys(c1,'proximity')), 'no proximity channels');

% Zero support channels — legal, and the whole point. It must WARN, because it changes how the
% background denominator is obtained.
writeCfg(scratch, '{"channels":[{"key":"mito","role":"proximity"}]}');
[c0, i0] = cs_channel_config(scratch);
assert(isempty(cs_channel_keys(c0,'support')), 'no support channel');
assert(~isempty(i0.warnings) && any(contains(lower(i0.warnings),'support')), ...
    'a project with no support channel must say so');

% Three channels, one this build has never heard of.
writeCfg(scratch, ['{"channels":[{"key":"er","role":"support"},{"key":"mito","role":"proximity"},' ...
    '{"key":"lyso","role":"proximity","label":"Lysosome","folder":"lyso_seg","suffix":"_(lyso|ch4_lyso)"}]}']);
c3 = cs_channel_config(scratch);
assert(numel(c3)==3, 'three channels');
assert(isequal(cs_channel_keys(c3,'proximity'), {'mito','lyso'}), 'declaration order preserved');
F = cs_channel_fields(c3(3));
assert(strcmp(F.key,'lyso') && strcmp(F.label,'Lysosome') && strcmp(F.folder,'lyso_seg'), 'config drives the fields');
% ...and it is KEYED-ONLY: no flat legacy names, because it never had any.
assert(isempty(F.mat) && isempty(F.spots) && isempty(F.site), 'a new channel has no flat legacy names');
assert(strcmp(F.box.mat,'dist') && strcmp(F.box.site,'near'), 'the keyed containers are shared');
fprintf('  three channels resolve, the new one keyed-only: dist.%s / near.%s\n', F.key, F.key);

% A new channel must work end to end through the accessors, with no legacy field anywhere.
r = cs_site_set_near(struct('csID',1), 'lyso', true);
assert(r.near.lyso && ~isfield(r,'MitoFlag') && cs_site_near(r,'lyso'), 'keyed-only site flag round-trips');
T = struct('matrix',cat(3,[1 2;3 4],[.1 .2;.3 .4],[.5 .6;.7 .8]), ...
           'allSpots',struct('X',(1:4)','Y',(1:4)','DIST',struct('lyso',(11:14)')), ...
           'dist',struct('lyso',[9 8;7 6]));
[d, have] = cs_channel_dist(T,'lyso','tracked');
assert(have && isequaln(d, [9;7;8;6]), 'keyed-only tracked distance');
assert(isequaln(cs_channel_dist(T,'lyso','cloud'), (11:14)'), 'keyed-only cloud distance');
assert(cs_channel_has(T,'lyso') && ~cs_channel_has(T,'mito'), 'availability is per channel');

fprintf('\n========== PART C: malformed configs error where they are declared ==========\n');
bad = { '{"channels":[{"key":"er","role":"support"},{"key":"nuc","role":"support"}]}', 'cs_channel_config:twoSupports'
        '{"channels":[{"key":"2bad","role":"proximity"}]}',                            'cs_channel_config:badKey'
        '{"channels":[{"key":"er","role":"sideways"}]}',                               'cs_channel_config:badRole'
        '{"channels":[{"key":"er"},{"key":"er"}]}',                                    'cs_channel_config:duplicateKey'
        '{"channels":[{"role":"support"}]}',                                           'cs_channel_config:noKey'
        'not json at all',                                                             'cs_channel_config:badJson' };
for b = 1:size(bad,1)
    writeCfg(scratch, bad{b,1});
    gotId = ''; try cs_channel_config(scratch); catch ME, gotId = ME.identifier; end
    assert(strcmp(gotId, bad{b,2}), 'expected %s, got ''%s''', bad{b,2}, gotId);
end
fprintf('  six malformed configs all rejected with their own identifier\n');

fprintf('\n========== PART D: the config drives file discovery ==========\n');
% Two channels, an SPT stack named with a channel token, and segmentations named for the cell.
proj = fullfile(scratch,'proj');
mkdir(fullfile(proj,'spt')); mkdir(fullfile(proj,'er_seg')); mkdir(fullfile(proj,'lyso_seg'));
imwrite(uint8(zeros(4)), fullfile(proj,'spt','day1_cellA_C3.tif'));
imwrite(uint8(zeros(4)), fullfile(proj,'er_seg','day1_cellA_er.tif'));
imwrite(uint8(zeros(4)), fullfile(proj,'lyso_seg','day1_cellA_lyso.tif'));
writeCfg(proj, ['{"channels":[{"key":"er","role":"support"},' ...
    '{"key":"lyso","role":"proximity","folder":"lyso_seg","suffix":"_(lyso|ch4_lyso)"}]}']);

spec = cs_channel_segspec(cs_channel_config(proj), proj);
assert(numel(spec)==2 && strcmp(spec(2).key,'lyso'), 'the spec carries every declared channel');
assert(strcmp(spec(1).dir, fullfile(proj,'er_seg')), 'folders resolved against the project root');

% The token is DERIVED, not typed. This is the bug that made cs_experiment_scan enumerate nothing on
% any dataset not named '_VAPB' — the user's live data is '_C3'.
tok = spt_channel_token(fullfile(proj,'spt'), spec);
assert(strcmp(tok,'_C3'), 'expected the token to be derived as _C3, got ''%s''', tok);

m = spt_match(fullfile(proj,'spt'), spec, tok);
assert(isscalar(m) && strcmp(m(1).key,'day1_cellA'), 'one cell, keyed by its name');
assert(~isempty(m(1).seg.er) && ~isempty(m(1).seg.lyso), 'BOTH channels resolved, including the new one');
assert(strcmp(m(1).erSeg, m(1).seg.er), 'the flat erSeg mirror still agrees');
assert(isempty(m(1).mitoSeg), 'a channel this project does not declare stays empty in the mirror');
fprintf('  token derived as "%s"; er + lyso both matched; erSeg mirror intact\n', tok);

% The legacy two-folder call shape must still work byte-for-byte — Tool 1 and 30 call sites use it.
mLegacy = spt_match(fullfile(proj,'spt'), fullfile(proj,'er_seg'), '', tok);
assert(isscalar(mLegacy) && strcmp(mLegacy(1).erSeg, m(1).erSeg), 'legacy call shape unchanged');
assert(isfield(mLegacy(1).seg,'er') && isfield(mLegacy(1).seg,'mito'), 'legacy shape still fills the keyed container');

fprintf('\n========== PART E: derived support beats the whole frame ==========\n');
% A cell occupying ~a quarter of the field, the rest empty coverslip.
G = 64; counts = zeros(G);
counts(12:28, 12:28) = poissrnd(4, 17, 17);          % the cell
counts(20:22, 20:22) = counts(20:22, 20:22) + 60;    % a contact site inside it
[sup, si] = cs_support_mask(counts, 'DilateR', 3);
assert(islogical(sup) && isequal(size(sup),[G G]), 'a logical mask at the count-image size');
assert(~si.degenerate && si.frac < 0.5, 'the support must be the cell, not the field (got %.2f)', si.frac);
assert(~isempty(si.why) && contains(si.why,'background median'), 'it must explain itself');
assert(all(sup(20:22,20:22),'all'), 'the site must be inside the support');
assert(~any(sup(end-3:end, end-3:end),'all'), 'empty coverslip must be outside the support');

% The point of the exercise: the background median over the derived support is a real number, while
% over the whole frame it collapses and inflates enrichment without bound.
dens  = imgaussfilt(counts, 2);
bgSup = median(dens(sup));
bgAll = median(dens(true(G)));
pk    = max(dens(:));
assert(bgSup > 0, 'the derived support gives a usable denominator');
fprintf('  background over derived support = %.4g -> enrich %.1f\n', bgSup, pk/max(bgSup,eps));
fprintf('  background over whole frame     = %.4g -> enrich %.1f  (the case this replaces)\n', ...
    bgAll, pk/max(bgAll,eps));
assert(pk/max(bgSup,eps) < pk/max(bgAll,eps), ...
    'the whole-frame denominator must be the one that inflates enrichment');

% Degenerate input must not produce an empty domain — that would silently detect nothing.
[m0, i0b] = cs_support_mask(zeros(16));
assert(all(m0(:)) && i0b.degenerate, 'no localizations at all -> whole frame, and SAY so');
assert(contains(i0b.why,'no localizations'), 'the degenerate case must explain itself');

fprintf('\ncs_channel_config_smoke: PASS\n');
end

% ------------------------------------------------------------------------------------------------
function writeCfg(d, txt)
fid = fopen(fullfile(d,'channels.json'),'w');
if fid < 0, error('cannot write channels.json in %s', d); end
fprintf(fid, '%s', txt); fclose(fid);
end

function rmIfThere(d)
if isfolder(d), try rmdir(d,'s'); catch, end, end
end
