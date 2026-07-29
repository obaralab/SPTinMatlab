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
assert(isfile(src), 'test data missing: %s', src);

proj = fullfile(tempdir, sprintf('spt_named_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(proj); mkdir(fullfile(proj,'analysis'));
for d = {'spt','er_seg','mito_seg','tracks'}                 % symlink the inputs, never copy
    system(sprintf('ln -s "%s" "%s"', fullfile(W,d{1}), fullfile(proj,d{1})));
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

fprintf('\nNAMED-BUILD / SINGLE-LOAD SMOKE PASSED.\n');
end
