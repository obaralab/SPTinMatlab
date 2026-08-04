function spt_channel_token_smoke()
%SPT_CHANNEL_TOKEN_SMOKE  The SPT channel token must be derived, not typed.
%
% The failure this prevents: Tool 2 hardcoded '_VAPB' as the token to strip from SPT names before
% keying them against the ER and mito segmentations. A dataset named with any other channel token —
% '_C3' — matched nothing, so every overlay silently failed to resolve and the Import & Curate tab
% showed no ER and no mito. Nothing errored. The names simply never matched, and there was no
% control anywhere in Tool 2 to correct it.
%
% The token is derivable: a segmentation is named for the CELL, the SPT stack for the cell plus the
% token, so the token is the difference. This pins that derivation across the naming conventions this
% pipeline has actually seen, and pins the degenerate cases that must not throw or guess.

here = fileparts(mfilename('fullpath')); addpath(here);
tmp = fullfile(tempdir,'spt_chan_tok'); if isfolder(tmp), rmdir(tmp,'s'); end

cases = { ...
 %  name                    spt files                              er files                        mito files                 expected
 {'_VAPB convention',      {'d1_c1_VAPB.tif','d1_c2_VAPB.tif'},   {'d1_c1_er.tiff','d1_c2_er.tiff'}, {'d1_c1_mito.tiff'},    '_VAPB'}, ...
 {'_C3 convention',        {'x_004_C3.tif'},                      {'x_004_er.tiff'},                 {'x_004_mito.tiff'},    '_C3'}, ...
 {'_spt1 convention',      {'250408_WT_012_spt1.tif'},            {'250408_WT_012_er.tiff'},         {'250408_WT_012_mito.tiff'}, '_spt1'}, ...
 {'no token at all',       {'d1_c1.tif'},                         {'d1_c1_er.tiff'},                 {'d1_c1_mito.tiff'},    ''}, ...
 {'majority wins',         {'a_C3.tif','b_C3.tif','c.tif'},       {'a_er.tiff','b_er.tiff','c_er.tiff'}, {},                 '_C3'}, ...
 {'ilastik export names',  {'y_01_C3.tif'},                       {'y_01_er_Simple Segmentation.tiff'}, {},                  '_C3'}, ...
 {'no segmentations',      {'a_C3.tif'},                          {},                                {},                     ''}, ...
 {'no SPT stacks',         {},                                    {'a_er.tiff'},                     {},                     ''}, ...
 {'nothing matches',       {'alpha_C3.tif'},                      {'beta_er.tiff'},                  {},                     ''} };

for k = 1:numel(cases)
    [nm, S, E, M, want] = cases{k}{:};
    r = fullfile(tmp, sprintf('case%d',k));
    mkdir(fullfile(r,'spt')); mkdir(fullfile(r,'er_seg')); mkdir(fullfile(r,'mito_seg'));
    for f = S, imwrite(uint16(zeros(4)), fullfile(r,'spt',f{1})); end
    for f = E, imwrite(uint16(zeros(4)), fullfile(r,'er_seg',f{1})); end
    for f = M, imwrite(uint16(zeros(4)), fullfile(r,'mito_seg',f{1})); end

    [tok, info] = spt_channel_token(fullfile(r,'spt'), fullfile(r,'er_seg'), fullfile(r,'mito_seg'));
    fprintf('  %-22s -> "%-6s"  (%d/%d)  %s\n', nm, tok, info.nMatched, info.nTotal, info.why);
    assert(strcmp(tok, want), '%s: derived "%s", expected "%s"', nm, tok, want);
    assert(ischar(info.why) && ~isempty(info.why), '%s: no explanation for the status line', nm);

    % ...and the derived token must actually make spt_match resolve, wherever there is anything to
    % resolve. Deriving a token nothing uses would be a different kind of silent failure.
    if ~isempty(S) && ~isempty(E)
        m = spt_match(fullfile(r,'spt'), fullfile(r,'er_seg'), fullfile(r,'mito_seg'), tok);
        got = sum(arrayfun(@(x) ~isempty(x.erSeg), m));
        if ~strcmp(nm,'nothing matches')
            assert(got >= 1, '%s: token "%s" derived but spt_match still resolves no ER', nm, tok);
        end
    end
end

% ---- the exact regression: '_VAPB' against a '_C3' dataset resolves nothing -----------------------
r = fullfile(tmp,'regress');
mkdir(fullfile(r,'spt')); mkdir(fullfile(r,'er_seg')); mkdir(fullfile(r,'mito_seg'));
imwrite(uint16(zeros(4)), fullfile(r,'spt','Halo-Sec61_004_C3.tif'));
imwrite(uint16(zeros(4)), fullfile(r,'er_seg','Halo-Sec61_004_er.tiff'));
imwrite(uint16(zeros(4)), fullfile(r,'mito_seg','Halo-Sec61_004_mito.tiff'));
mOld = spt_match(fullfile(r,'spt'), fullfile(r,'er_seg'), fullfile(r,'mito_seg'), '_VAPB');
assert(isempty(mOld(1).erSeg) && isempty(mOld(1).mitoSeg), ...
    'the fixture no longer reproduces the original failure');
tok = spt_channel_token(fullfile(r,'spt'), fullfile(r,'er_seg'), fullfile(r,'mito_seg'));
mNew = spt_match(fullfile(r,'spt'), fullfile(r,'er_seg'), fullfile(r,'mito_seg'), tok);
assert(~isempty(mNew(1).erSeg) && ~isempty(mNew(1).mitoSeg), ...
    'the derived token "%s" still does not resolve ER/mito', tok);
fprintf('\n  hardcoded "_VAPB": er=no  mito=no   |   derived "%s": er=YES mito=YES\n', tok);

% ---- and Tool 2 must no longer hardcode it -----------------------------------------------------
src = fileread(fullfile(fileparts(here),'tool2_analyze','app','spt_analyze_app.m'));
assert(~contains(src, "spt_match(fullfile(d,'spt'), fullfile(d,'er_seg'), fullfile(d,'mito_seg'), '_VAPB')"), ...
    'spt_analyze_app still hardcodes the _VAPB token');
assert(contains(src, 'spt_channel_token'), 'spt_analyze_app does not derive the token');
fprintf('  spt_analyze_app derives the token instead of hardcoding it\n');

fprintf('\nALL CHANNEL-TOKEN ASSERTIONS PASSED.\n');
end
