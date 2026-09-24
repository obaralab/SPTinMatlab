function spt_dual_channel_smoke()
%SPT_DUAL_CHANNEL_SMOKE  Two colours of one stack, tracked independently, must not overwrite each
%other — and each must carry its OWN frame interval and its own start time.
%
% WHAT IS ASSERTED:
%   1. THE DEFAULT IS UNCHANGED. A project with no tracked colours declared writes exactly the file
%      names it always wrote. Nothing has to be renamed for this to land.
%   2. TWO COLOURS, TWO SETS OF FILES: tracking the odd pages then the even pages leaves both
%      results on disk, named by channel, instead of the second overwriting the first.
%   3. EACH COLOUR'S OWN dt. Derived it is page x stride; declared it wins, and what a colour
%      declares reaches the XML, the CSV times and the settings file. Getting this wrong scales
%      every diffusion coefficient and dwell time by that factor, silently — so a declared dt that
%      disagrees with the stack's own arithmetic WARNS, and that warning is asserted here.
%   4. THE TIME ORIGIN IS RECORDED AND USED. The colour on the even pages starts one page interval
%      after the odd one, and its times say so rather than both claiming t = 0.
%   5. THE BUILD CAN STILL FIND THE MOVIE. The build's name for the cell carries the channel token;
%      the movie does not, because the two colours share one stack. The back-link strips it.
%   6. THE CHANNEL LIST ROUND-TRIPS through the project file, including a declared dt.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
addpath(fullfile(fileparts(here),'tool2_analyze','drivers'));
proj = fullfile(tempdir, sprintf('spt_dualch_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(fullfile(proj,'spt')); mkdir(fullfile(proj,'tracks'));
cleanup = onCleanup(@() rmdir(proj,'s'));

%% an interleaved stack: colour A on the odd pages, colour B on the even ------------------------
S = 64; nPg = 40; dtPage = 0.01;
mv = fullfile(proj,'spt','cellA.tif');
rng(2);
for pg = 1:nPg
    im = uint16(200 + 8*randn(S,S));
    if mod(pg,2) == 1, x = 16 + round(pg/3); y = 20;          % A drifts one way
    else,              x = 44 - round(pg/4); y = 42;          % B the other
    end
    im(y-1:y+1, x-1:x+1) = im(y-1:y+1, x-1:x+1) + uint16(4000);
    if pg == 1, imwrite(im, mv); else, imwrite(im, mv, 'WriteMode','append'); end
end
cel = struct('spt',mv,'erSeg','','mitoSeg','','key','cellA','diamUm',0.4,'thrAbs',60);
base = struct('linkUm',1.2,'gapUm',1.2,'maxGap',1,'useEr',false,'lambda',3,'pxUm',0.1,'dtS',dtPage);

%% (1) the default path is untouched -------------------------------------------------------------
R0 = spt_process_cell(cel, base);
spt_write_outputs(R0, fullfile(proj,'tracks'));
spt_write_settings(fullfile(proj,'tracks'), R0.base, cel, base, R0);
assert(isfile(fullfile(proj,'tracks','cellA_tracks.xml')), ...
    'a project with no colours declared must write the plain name');
assert(isempty(dir(fullfile(proj,'tracks','cellA__*'))), 'and no token anywhere');
assert(isempty(R0.chKey) && R0.t0_s == 0, 'the single-colour path has no key and starts at 0');

%% (2)(3)(4) two colours ---------------------------------------------------------------------------
dtB = 0.05;                                   % B declares its own, NOT page x stride (= 0.02)
pA = base; pA.frameStride = 2; pA.frameOffset = 0; pA.chKey = 'ch1'; pA.dtFrame = NaN;
pB = base; pB.frameStride = 2; pB.frameOffset = 1; pB.chKey = 'ch2'; pB.dtFrame = dtB;
RA = spt_process_cell(cel, pA);
% A declared dt that disagrees with the stack's own arithmetic must SAY SO. It is the one place a
% typo scales every downstream second, and it is silent unless something complains.
lastwarn(''); w = warning('off','spt_process_cell:dtChannelOverride');
restoreW = onCleanup(@() warning(w));
RB = spt_process_cell(cel, pB);
[msg, wid] = lastwarn();
assert(strcmp(wid,'spt_process_cell:dtChannelOverride'), ...
    ['declaring %g s where the stack gives %g s should warn — a typo here scales every diffusion ' ...
     'coefficient and dwell time by that factor, silently (warning was "%s")'], dtB, 2*dtPage, wid);
assert(contains(msg, '0.05') && contains(msg, '0.02'), 'and the warning should name both numbers: "%s"', msg);
spt_write_outputs(RA, fullfile(proj,'tracks')); spt_write_settings(fullfile(proj,'tracks'), RA.base, cel, pA, RA);
spt_write_outputs(RB, fullfile(proj,'tracks')); spt_write_settings(fullfile(proj,'tracks'), RB.base, cel, pB, RB);

for k = {'ch1','ch2'}
    for suf = {'_tracks.xml','_spots.csv','_settings.txt'}
        f = fullfile(proj,'tracks',['cellA__' k{1} suf{1}]);
        assert(isfile(f), 'missing %s — the second colour overwrote the first', f);
    end
end
assert(isfile(fullfile(proj,'tracks','cellA_tracks.xml')), 'and the single-colour run is still there');

assert(abs(RA.dtS - dtPage*2) < 1e-12, 'ch1 derives page x stride (%.4g)', RA.dtS);
assert(abs(RB.dtS - dtB) < 1e-12, 'ch2 declared %.4g s and must keep it, got %.4g', dtB, RB.dtS);
assert(RA.t0_s == 0 && abs(RB.t0_s - dtPage) < 1e-12, ...
    'the even-page colour starts one page interval later (%.4g vs %.4g)', RA.t0_s, RB.t0_s);

xb = fileread(fullfile(proj,'tracks','cellA__ch2_tracks.xml'));
assert(contains(xb, sprintf('frameInterval="%.6g"', dtB)), 'ch2''s own dt should be in its XML');
assert(contains(xb, 'channel="ch2"') && contains(xb, sprintf('t0="%.6g"', dtPage)), ...
    'the XML should record which colour it is and when it started');
sb = fileread(fullfile(proj,'tracks','cellA__ch2_settings.txt'));
assert(contains(sb, sprintf('calibration.frame_s     = %.6g', dtB)), 'and the settings file agrees');
assert(contains(sb, 'channel.key             = ch2'), 'the settings file should name the colour');
% the CSV times start at the origin, not at zero
c2 = strsplit(strtrim(fileread(fullfile(proj,'tracks','cellA__ch2_spots.csv'))), newline);
row = strsplit(c2{2}, ','); tFirst = str2double(row{4});
assert(tFirst >= dtPage - 1e-9, 'ch2''s first time should be its t0 (%.4g), got %.4g', dtPage, tFirst);

%% (5) the build still finds the movie ------------------------------------------------------------
[b, k] = spt_channel_stem('cellA__ch2');
assert(strcmp(b,'cellA') && strcmp(k,'ch2'), 'the token must come back off for the movie lookup');

%% (6) the channel list round-trips ----------------------------------------------------------------
C = [struct('key','ch1','label','ch1 (odd pages)','stride',2,'offset',0,'dt_s',NaN,'file',''), ...
     struct('key','ch2','label','ch2 (even pages)','stride',2,'offset',1,'dt_s',dtB,'file','')];
spt_tracked_channels('save', proj, C);
C2 = spt_tracked_channels('load', proj);
assert(numel(C2) == 2 && strcmp(C2(2).key,'ch2'), 'the colours should come back');
assert(C2(2).stride == 2 && C2(2).offset == 1, 'with their pages');
assert(abs(C2(2).dt_s - dtB) < 1e-12 && isnan(C2(1).dt_s), ...
    'a declared dt should survive, and an underived one stay NaN');
D = spt_tracked_channels('load', tempdir);
assert(numel(D) == 1 && isempty(D(1).key), 'a project with no file gets the single-colour default');

fprintf('dual channel: ch1 dt %.4g s (derived), ch2 dt %.4g s (declared), t0 %.4g s; %d files written per colour\n', ...
    RA.dtS, RB.dtS, RB.t0_s, 3);
fprintf('\nDUAL-CHANNEL SMOKE PASSED.\n');
end
