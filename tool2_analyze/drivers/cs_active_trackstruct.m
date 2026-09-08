function [p, name] = cs_active_trackstruct(anaDir)
%CS_ACTIVE_TRACKSTRUCT  Path of the TrackStruct build in force for an analysis folder.
%
%   [p, name] = cs_active_trackstruct(anaDir)
%
% A project may hold several NAMED builds side by side (Day1_WT.mat, Day1_KO.mat, …).
% analysis/active_trackstruct.txt names the one in force; the Curate & Build tool writes it on every
% build and every load. This is the SINGLE definition of "which build" — the Analyze tool, the
% contact-site picker and the experiment status lamp all resolve through here so they can never
% disagree about which file a folder is currently working from.
%
% Resolution order:
%   1. active_trackstruct.txt, when it names a file that exists
%   2. TrackStruct.mat   (the default name; what every pre-naming project has)
%   3. Tracks.mat        (legacy hand-off written by run_contactsite_analysis)
%   4. any other .mat in the folder that actually contains a 'Tracks' variable — so a hand-copied
%      named build still registers even without a pointer
%
% Returns '' / '' when the folder holds no build.
p = ''; name = '';
if nargin < 1 || isempty(anaDir) || ~isfolder(anaDir), return; end
anaDir = char(anaDir);

ptr = fullfile(anaDir,'active_trackstruct.txt');
if isfile(ptr)
    try
        s = strtrim(fileread(ptr));
        % A POINTER NAMING A SUBSET IS IGNORED. examples_*.mat is the Engagement tab's set of tracks
        % that touch the organelle — a valid TrackStruct but a SELECTION. Loading one for inspection
        % used to stamp it active, and every downstream stage then measured pre-selected tracks:
        % D_free computed only from molecules that also touch the organelle is a depleted, biased
        % pool. The write path is guarded now, but projects already carry pointers written before
        % that, and a stale pointer is silent — the tool simply reports different numbers. Refusing
        % it here repairs those projects on the next read rather than waiting to be noticed.
        if ~isempty(s) && startsWith(s,'examples_')
            warning('cs_active_trackstruct:subsetPointer', ...
                ['active_trackstruct.txt names the SUBSET %s. A subset must never be the active ' ...
                 'build — measuring it biases every downstream stage — so it is being ignored and ' ...
                 'the real build used instead.'], s);
            s = '';
        end
        if ~isempty(s) && isfile(fullfile(anaDir,s)), p = fullfile(anaDir,s); name = s; return; end
    catch
    end
end
for f = {'TrackStruct.mat','Tracks.mat'}
    q = fullfile(anaDir,f{1});
    if isfile(q), p = q; name = f{1}; return; end
end
% last resort: a named build with no pointer. whos('-file') is ~1 ms, so scanning the handful of
% .mat files in an analysis folder is cheap; skip the ones we know are not builds.
skip = {'cs_calib.mat','CSW_final.mat','cs_window_dwell.mat','cs_footprints.mat','experiment_details.mat','experiment_manifest.mat'};
d = dir(fullfile(anaDir,'*.mat'));
d = d(~startsWith({d.name}','examples_'));   % never fall back to a subset either
for k = 1:numel(d)
    if any(strcmpi(d(k).name, skip)), continue; end
    try
        w = whos('-file', fullfile(anaDir,d(k).name));
        if any(strcmp({w.name},'Tracks')), p = fullfile(anaDir,d(k).name); name = d(k).name; return; end
    catch
    end
end
end
