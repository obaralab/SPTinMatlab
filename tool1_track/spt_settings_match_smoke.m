function spt_settings_match_smoke()
% The file-matching regex must SURVIVE Tool 1. It is the only part of the pairing that cannot be
% recovered later: Tools 2 and 3 re-derive the channel token by comparing SPT names to segmentation
% names, which works when one is a prefix of the other and not otherwise. A regex typed in Tool 1
% because the naming is unusual used to die with the scan, and the overlays downstream silently
% resolved nothing.
%
% This pins the round trip: Tool 1 writes it -> spt_settings_match reads it back -> spt_match
% reproduces the same pairing from the record alone.
here = fileparts(mfilename('fullpath')); addpath(here);
root = fullfile(tempdir, sprintf('spt_setmatch_%d', feature('getpid')));
cleanup = onCleanup(@() rmIfThere(root));
rmIfThere(root);

fprintf('\n========== PART A: the key is written, and read back verbatim ==========\n');
td = fullfile(root,'tracks'); mkdir(td);
cel = struct('diamUm',0.5,'keepPct',6,'stripRe','(?:_C3)$','chanTok','_C3');
prm = struct('linkUm',0.8,'gapUm',1.4,'maxGap',1,'lambda',1,'pxUm',0.16,'dtS',0.0105, ...
             'mode','euclid','modeReq','euclid');
R   = struct('base','day1_cellA','spotId',(1:10)','nTracks',3,'haveEr',1,'haveMito',1, ...
             'nFramesNoErMask',0,'nDetsOffEr',0);
spt_write_settings(td, 'day1_cellA', cel, prm, R);

f = fullfile(td,'day1_cellA_settings.txt');
assert(isfile(f), 'no settings file was written');
txt = fileread(f);
assert(contains(txt,'matching.strip_regex'),   'matching.strip_regex was not recorded');
assert(contains(txt,'matching.channel_token'), 'matching.channel_token was not recorded');

[re, tok, src] = spt_settings_match(td);
assert(strcmp(re,  '(?:_C3)$'), 'regex round-tripped as ''%s''', re);
assert(strcmp(tok, '_C3'),      'token round-tripped as ''%s''', tok);
assert(~isempty(src), 'src must name the file the record came from');
fprintf('  wrote and read back: regex=%s  token=%s\n', re, tok);

% A regex is full of characters a naive writer would mangle. Round-trip a nasty one verbatim.
cel2 = cel; cel2.stripRe = '_(VAPB|C3)\d*$'; cel2.chanTok = '_VAPB';
spt_write_settings(td, 'day1_cellB', cel2, prm, R);
[re2, tok2] = spt_settings_match(td);
assert(strcmp(re2,'(?:_C3)$') || strcmp(re2,'_(VAPB|C3)\d*$'), 'a metacharacter-heavy regex was mangled: %s', re2);
fprintf('  a regex with |, \\d, * and $ survives the file unaltered\n');

fprintf('\n========== PART B: "strip nothing" is a real answer, not a missing one ==========\n');
% '' is a legitimate result — the names already agree. It must be distinguishable from "this Tool 1
% recorded nothing", or the caller cannot tell whether to fall back to deriving.
td2 = fullfile(root,'tracks_nostrip'); mkdir(td2);
celN = cel; celN.stripRe = ''; celN.chanTok = '';
spt_write_settings(td2, 'c1', celN, prm, R);
[reN, tokN, srcN] = spt_settings_match(td2);
assert(isempty(reN) && isempty(tokN), 'expected an empty regex/token');
assert(~isempty(srcN), 'an empty regex must still report a source — that is how "recorded" is told from "absent"');
fprintf('  file records "(none)", reader returns an empty regex, and src is still set\n');

fprintf('\n========== PART C: an OLD tracks folder degrades to "nothing recorded" ==========\n');
td3 = fullfile(root,'tracks_old'); mkdir(td3);
fid = fopen(fullfile(td3,'c1_settings.txt'),'w');
fprintf(fid, '# an older Tool 1\ndetection.diameter_um   = 0.5\ntracking.link_um        = 0.8\n');
fclose(fid);
[reO, tokO, srcO] = spt_settings_match(td3);
assert(isempty(reO) && isempty(tokO) && isempty(srcO), ...
    'a settings file without the key must report src = '''' so the caller falls back to deriving');
assert(isempty(spt_settings_match(fullfile(root,'no_such_folder'))), 'a missing folder must not throw');
fprintf('  pre-change folder -> src empty, caller falls back to deriving\n');

fprintf('\n========== PART D: the record alone reproduces the pairing ==========\n');
% The point of the exercise. Name the files so DERIVING cannot work — the segmentation stem is not a
% prefix of the SPT stem — and check the recorded regex still pairs them.
p = fullfile(root,'proj');
mkdir(fullfile(p,'spt')); mkdir(fullfile(p,'er_seg')); mkdir(fullfile(p,'mito_seg')); mkdir(fullfile(p,'tracks'));
imwrite(uint8(zeros(4)), fullfile(p,'spt','day1_cellA_C3.tif'));
imwrite(uint8(zeros(4)), fullfile(p,'er_seg','day1_cellA_er.tiff'));
imwrite(uint8(zeros(4)), fullfile(p,'mito_seg','day1_cellA_mito.tiff'));
celP = cel; celP.stripRe = '(?:_C3)$'; celP.chanTok = '_C3';
spt_write_settings(fullfile(p,'tracks'), 'day1_cellA', celP, prm, R);

[reP, ~, srcP] = spt_settings_match(fullfile(p,'tracks'));
assert(~isempty(srcP), 'the project record was not found');
m = spt_match(fullfile(p,'spt'), fullfile(p,'er_seg'), fullfile(p,'mito_seg'), reP);
assert(isscalar(m), 'expected one cell');
assert(~isempty(m(1).erSeg) && ~isempty(m(1).mitoSeg), ...
    'the RECORDED regex failed to pair the files it was recorded from');
fprintf('  recorded regex paired ER + mito with no derivation involved\n');

% ...and the folder-root convenience: hand it the project, it finds tracks/.
[reR, ~, srcR] = spt_settings_match(p);
assert(~isempty(srcR) && strcmp(reR, reP), 'passing the project root should find its tracks/ folder');
fprintf('  project root resolves to its tracks/ folder\n');

fprintf('\n========== PART E: both consumers prefer the record ==========\n');
for f2 = {fullfile(fileparts(here),'tool2_analyze','app','spt_analyze_app.m'), ...
          fullfile(fileparts(here),'tool2_analyze','drivers','cs_experiment_scan.m')}
    src2 = fileread(f2{1});
    [~,nm,ex] = fileparts(f2{1});
    assert(contains(src2,'spt_settings_match'), '%s%s does not read the recorded regex', nm, ex);
    fprintf('  %s%s reads spt_settings_match\n', nm, ex);
end

fprintf('\nALL SETTINGS-MATCH ASSERTIONS PASSED.\n');
end

% ------------------------------------------------------------------------------------------------
function rmIfThere(d)
if isfolder(d), try rmdir(d,'s'); catch, end, end
end
