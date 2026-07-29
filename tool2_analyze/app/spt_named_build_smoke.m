function spt_named_build_smoke()
%SPT_NAMED_BUILD_SMOKE  Named TrackStruct builds + the single-load hand-off to Tool 3.
%
% The contract under test:
%   · a project may hold SEVERAL named builds side by side in analysis/ (Day1_WT.mat, Day1_KO.mat…);
%   · analysis/active_trackstruct.txt names the one in force, so a separately launched Analyze tool
%     (run_analyze) opens the same build Curate & Build last wrote or loaded;
%   · loading a named build must NOT overwrite TrackStruct.mat;
%   · cs_window_picker uses a Tracks struct handed to it instead of re-loading the same file
%     (the app already holds it; a second load doubles Tool 3's memory).
%
% Runs against a TEMP project whose inputs are symlinks to WithER — nothing is written into WithER.
here = fileparts(mfilename('fullpath')); addpath(here); addpath(fullfile(here,'..','drivers'));
W   = '/Users/safal-mac/Desktop/IntegratedPipeline/WithER';
src = fullfile(W,'analysis','TrackStruct.mat');
if ~isfile(src)
    % A built TrackStruct is a DERIVED artifact — it may legitimately not exist (fresh clone, or the
    % project was re-tracked and not yet rebuilt). Skip loudly rather than fail: this test is about
    % named-build plumbing, not about whether someone has run Build recently.
    fprintf(['SKIPPED — no built TrackStruct at %s.\n' ...
             '  Rebuild one (Tool 2 -> Build + QC) and re-run to exercise the named-build contract.\n'], src);
    return;
end

wsnap = snapWithER(W);   % fingerprint the pristine data; asserted unchanged at the end

proj = fullfile(tempdir, sprintf('spt_named_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(proj); mkdir(fullfile(proj,'analysis'));
% Symlink the individual FILES into real directories — never symlink the directory itself. Setting
% a project runs onCalAuto -> writeCalib, which saves cs_calib.mat into the tracks folder; through a
% directory symlink that write follows into WithER and modifies the pristine test data (it did:
% WithER/tracks/cs_calib.mat, 2026-07-28 23:43). With per-file links the new file lands here instead.
for d = {'spt','er_seg','mito_seg','tracks'}
    sdir = fullfile(W,d{1}); dst = fullfile(proj,d{1}); mkdir(dst);
    ff = dir(fullfile(sdir,'*'));
    for q = 1:numel(ff)
        if ff(q).isdir, continue; end
        % Skip .mat: setting a project writes tracks/cs_calib.mat, and save() FOLLOWS a symlink, so
        % linking that name would put the write straight back into WithER. The inputs the app reads
        % (.tif/.tiff/.xml/.csv/.txt) are safe to link because nothing writes over them.
        [~,~,ex] = fileparts(ff(q).name); if strcmpi(ex,'.mat'), continue; end
        system(sprintf('ln -s "%s" "%s"', fullfile(sdir,ff(q).name), fullfile(dst,ff(q).name)));
    end
end
cleanup = onCleanup(@() rmdir(proj,'s'));

%% two named builds, deliberately distinguishable ------------------------
L = load(src); Tracks = L.Tracks;
save(fullfile(proj,'analysis','Day1_WT.mat'),'Tracks','-v7.3');
Tracks(1).file = 'KO_MARKER';
save(fullfile(proj,'analysis','Day1_KO.mat'),'Tracks','-v7.3');
clear Tracks L;

%% the active pointer decides which one Tool 3 opens ---------------------
fid = fopen(fullfile(proj,'analysis','active_trackstruct.txt'),'w');
fprintf(fid,'Day1_KO.mat\n'); fclose(fid);

f = spt_analyze_app('analyze'); U = f.UserData;
pe = findobj(f,'Type','uieditfield');
for k = 1:numel(pe)
    if contains(lower(string(pe(k).Placeholder)),'project')
        pe(k).Value = proj; cb = pe(k).ValueChangedFcn; if ~isempty(cb), cb(pe(k), struct('Value',proj)); end
    end
end
drawnow;
bs = findobj(f,'Type','uibutton'); hit = false;
for k = 1:numel(bs)                                   % anything that forces ensureTracksLoaded
    if contains(string(bs(k).Text),'windowed picker'), cb = bs(k).ButtonPushedFcn; cb(bs(k),struct()); hit = true; break; end
end
assert(hit, 'could not find the picker button to force a load');
T = U.tracks();
assert(~isempty(T), 'analyze mode loaded nothing');
assert(strcmp(char(T(1).file),'KO_MARKER'), ...
    'analyze mode ignored active_trackstruct.txt — loaded "%s", wanted the KO build', char(T(1).file));
assert(strcmp(U.activeTs(),'Day1_KO.mat'), 'active name not adopted: %s', U.activeTs());
fprintf('active pointer honoured: Analyze opened %s\n', U.activeTs());
close(f);

%% loading a named build must not clobber TrackStruct.mat ----------------
assert(~isfile(fullfile(proj,'analysis','TrackStruct.mat')), ...
    'a named build wrote TrackStruct.mat — named builds must stay separate');
d1 = dir(fullfile(proj,'analysis','Day1_WT.mat'));
assert(~isempty(d1) && d1.bytes > 0, 'Day1_WT.mat disappeared');
fprintf('named builds coexist: %s\n', strjoin({'Day1_WT.mat','Day1_KO.mat'},', '));

%% the Experiment tab's "built" lamp must see a NAMED build --------------
% This folder deliberately has NO TrackStruct.mat — only Day1_WT.mat / Day1_KO.mat + the pointer.
rec = struct('file','250408_WT_012_spt1', 'analysis',fullfile(proj,'analysis'), 'tracks',fullfile(proj,'tracks'));
stt = cs_experiment_status(rec);
assert(stt.built, 'experiment status lamp missed a named build (it only looked for TrackStruct.mat)');
[ap, an] = cs_active_trackstruct(fullfile(proj,'analysis'));
assert(strcmp(an,'Day1_KO.mat'), 'cs_active_trackstruct resolved "%s", wanted Day1_KO.mat', an);
assert(isfile(ap), 'resolved active build does not exist');
% and with no pointer at all it must still find a named build
delete(fullfile(proj,'analysis','active_trackstruct.txt'));
[~, an2] = cs_active_trackstruct(fullfile(proj,'analysis'));
assert(~isempty(an2), 'no pointer + named build -> resolved nothing');
assert(cs_experiment_status(rec).built, 'lamp dark for a named build with no pointer');
fprintf('experiment lamp sees named builds (pointer: %s · no pointer: %s)\n', an, an2);
fid = fopen(fullfile(proj,'analysis','active_trackstruct.txt'),'w'); fprintf(fid,'Day1_KO.mat\n'); fclose(fid);

%% the picker takes a handed-over struct instead of re-loading -----------
anaDir = fullfile(proj,'analysis');
L = load(fullfile(anaDir,'Day1_WT.mat')); WT = L.Tracks;
fh = uifigure('Visible','off','Position',[1 1 1100 700]); pn = uipanel(fh);
cs_window_picker(pn, anaDir, struct('FOV_um',27.61,'binNm',30,'contactUm',0.1,'Tracks',WT));
drawnow;
lbls = findobj(fh,'Type','uilabel'); txt = strjoin(string(arrayfun(@(x) string(x.Text), lbls)), ' | ');
assert(~contains(txt,'KO_MARKER'), 'picker used the active file instead of the struct it was given');
fprintf('picker used the handed-over struct (not the active pointer)\n');
close(fh);

% and still works standalone, falling back to the active pointer
fh = uifigure('Visible','off','Position',[1 1 1100 700]); pn = uipanel(fh);
cs_window_picker(pn, anaDir, struct('FOV_um',27.61,'binNm',30,'contactUm',0.1));
drawnow;
fprintf('picker standalone fallback OK\n');
close(fh);

assertWithERIntact(W, wsnap);
fprintf('\nNAMED-BUILD / SINGLE-LOAD SMOKE PASSED.\n');
end

function snap = snapWithER(W)
% Fingerprint every file under WithER (size + mtime) so a test can PROVE it did not modify the
% pristine input data. Cheap: ~5 files plus the big stacks.
snap = containers.Map('KeyType','char','ValueType','char');
for d = {'', 'spt', 'er_seg', 'mito_seg', 'tracks', 'analysis'}
    p = fullfile(W, d{1});
    if ~isfolder(p), continue; end
    ff = dir(fullfile(p,'*'));
    for q = 1:numel(ff)
        if ff(q).isdir, continue; end
        k = fullfile(d{1}, ff(q).name);
        snap(k) = sprintf('%d|%.6f', ff(q).bytes, ff(q).datenum);
    end
end
end

function assertWithERIntact(W, before)
% The pristine test data must come out exactly as it went in. save() and fopen() FOLLOW SYMLINKS,
% so any fixture that links WithER files can silently write through them; this catches that.
after = snapWithER(W);
bad = {};
ks = before.keys;
for i = 1:numel(ks)
    k = ks{i};
    if ~after.isKey(k), bad{end+1} = sprintf('DELETED %s', k); %#ok<AGROW>
    elseif ~strcmp(before(k), after(k)), bad{end+1} = sprintf('MODIFIED %s', k); end %#ok<AGROW>
end
ks = after.keys;
for i = 1:numel(ks)
    if ~before.isKey(ks{i}), bad{end+1} = sprintf('CREATED %s', ks{i}); end %#ok<AGROW>
end
assert(isempty(bad), 'THIS TEST MODIFIED THE PRISTINE WithER DATA:\n  %s', strjoin(bad, sprintf('\n  ')));
fprintf('WithER verified untouched by this test (%d files fingerprinted)\n', before.Count);
end
