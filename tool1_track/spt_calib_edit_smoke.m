function spt_calib_edit_smoke()
%SPT_CALIB_EDIT_SMOKE  A calibration you TYPE must reach every tool, and must be the value the
%analysis actually runs on.
%
% THE DEFECT. On a dataset whose files carry no pixel size or frame interval, every tool falls back
% to the panel's resting value — for a new dataset, the previous dataset's numbers. The Experiment
% tab is where that gets corrected, and it stored the correction faithfully in the manifest. Nothing
% read it back. spt_project_calib — the ONE resolver Tool 1's run, Tool 2's build and Tool 3's top
% bar all go through — ranked _settings.txt, then the movie, then the XML, and never the manifest.
% So the Experiment tab showed 0.107 while every other surface went on using 0.16, with nothing on
% screen to say the two disagreed. A correction that is displayed but not applied is worse than no
% correction: it is a wrong number wearing the user's authority.
%
% WHAT IS ASSERTED:
%   1. RANK        — an edit outranks _settings.txt, which is the strongest file source there is.
%   2. IT BITES    — the same project WITHOUT the edit resolves to the file value, so assertion 1 is
%                    testing the manifest and not something that was already true.
%   3. LOCK ONLY   — a manifest row that was merely REPORTED (pixLock false) is not an edit and must
%                    not outrank anything. This is what keeps Tool 1's own stamp-back from
%                    laundering itself into a user correction.
%   4. PER FIELD   — editing the pixel size alone leaves dt resolving from the files.
%   5. NO LOOP     — useManifest=false (what cs_experiment_scan passes) still reports the FILES, so
%                    a rescan can show what the project actually contains rather than echoing the
%                    edit back as its own evidence.
%   6. SCOPE       — an edit recorded against a DIFFERENT project must not leak into this one.
%   7. DIMENSIONS  — width/height come back from the movie, and the FOV is (width-1) x pixel size
%                    computed from whichever pixel size won — so an edited pixel size moves the FOV
%                    with it instead of leaving stale arithmetic on the toolbar.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);

root = fullfile(tempdir, sprintf('spt_calibedit_%d', feature('getpid')));
if isfolder(root), rmdir(root,'s'); end
mkdir(root);
cleanup = onCleanup(@() rmdir(root,'s'));

FILE_PX = 0.16;   FILE_DT = 0.05;      % what the files say
EDIT_PX = 0.107;  EDIT_DT = 0.02;      % what the user typed

proj = fullfile(root,'proj');
mkProject(proj, 'cellA', FILE_PX, FILE_DT);

%% (2) THE FIX MUST BITE: without a manifest the file wins ------------------------------------------
c0 = spt_project_calib(proj);
assert(abs(c0.pixUm - FILE_PX) < 1e-12 && strcmp(c0.src.pixUm,'settings'), ...
    ['with no manifest the resolver gave %.5g (%s), not the settings file''s %.5g. This fixture is ' ...
     'not exercising the defect: assertion 1 below would pass without reading the manifest at all.'], ...
    c0.pixUm, c0.src.pixUm, FILE_PX);

%% (1) AN EDIT OUTRANKS THE STRONGEST FILE SOURCE --------------------------------------------------
writeManifest(proj, 'cellA', proj, EDIT_PX, true, EDIT_DT, true);
c1 = spt_project_calib(proj);
assert(abs(c1.pixUm - EDIT_PX) < 1e-12, ...
    ['a hand-edited pixel size of %.5g was ignored: the resolver returned %.5g from "%s". The ' ...
     'Experiment tab would show the correction while every other tool used the file.'], ...
    EDIT_PX, c1.pixUm, c1.src.pixUm);
assert(strcmp(c1.src.pixUm,'edited'), ...
    'the edited pixel size is reported as coming from "%s" — the toolbar cannot tint or explain it', c1.src.pixUm);
assert(abs(c1.dt_s - EDIT_DT) < 1e-12 && strcmp(c1.src.dt_s,'edited'), ...
    'a hand-edited dt of %.5g was ignored: got %.5g from "%s"', EDIT_DT, c1.dt_s, c1.src.dt_s);

%% (3) A REPORTED VALUE IS NOT AN EDIT --------------------------------------------------------------
% Tool 1 stamps back what its run resolved (setCalib with lock=false). If an unlocked row counted as
% an edit, that stamp would outrank the very file it was read from and the ranking would be circular.
writeManifest(proj, 'cellA', proj, 0.3, false, 0.9, false);
c2 = spt_project_calib(proj);
assert(abs(c2.pixUm - FILE_PX) < 1e-12 && strcmp(c2.src.pixUm,'settings'), ...
    ['an UNLOCKED manifest row (a value Tool 1 reported, not one the user typed) outranked the ' ...
     'settings file: got %.5g from "%s". Only a hand edit may do that.'], c2.pixUm, c2.src.pixUm);

%% (4) THE FIELDS ARE INDEPENDENT -------------------------------------------------------------------
writeManifest(proj, 'cellA', proj, EDIT_PX, true, NaN, false);
c3 = spt_project_calib(proj);
assert(abs(c3.pixUm - EDIT_PX) < 1e-12, 'editing only the pixel size lost the pixel size');
assert(abs(c3.dt_s - FILE_DT) < 1e-12 && strcmp(c3.src.dt_s,'settings'), ...
    ['editing the PIXEL SIZE also overrode dt, which came back %.5g from "%s" instead of the ' ...
     'file''s %.5g. An edit must apply to the field it was made on.'], c3.dt_s, c3.src.dt_s, FILE_DT);

%% (5) THE SCAN MUST STILL SEE THE FILES ------------------------------------------------------------
% cs_experiment_scan FILLS the manifest. If it read the manifest back, the edit would become its own
% evidence and no rescan could ever show what changed on disk.
writeManifest(proj, 'cellA', proj, EDIT_PX, true, EDIT_DT, true);
c4 = spt_project_calib(proj, 'cellA', false);
assert(abs(c4.pixUm - FILE_PX) < 1e-12 && strcmp(c4.src.pixUm,'settings'), ...
    ['useManifest=false still returned %.5g from "%s". cs_experiment_scan passes this, so a rescan ' ...
     'would echo the edit back as though the files contained it.'], c4.pixUm, c4.src.pixUm);

%% (6) AN EDIT DOES NOT CROSS PROJECTS ---------------------------------------------------------------
% Day1/cellA and Day2/cellA is this pipeline's own layout, so a manifest keyed only on the cell name
% would apply one day's correction to the other's identically-named cell.
other = fullfile(root,'other');
mkProject(other, 'cellA', FILE_PX, FILE_DT);
writeManifest(other, 'cellA', proj, EDIT_PX, true, EDIT_DT, true);   % row names the OTHER project
c5 = spt_project_calib(other);
assert(abs(c5.pixUm - FILE_PX) < 1e-12 && strcmp(c5.src.pixUm,'settings'), ...
    ['a calibration edit recorded against a different project leaked into this one: %.5g from "%s". ' ...
     'Day1/cellA and Day2/cellA would share one correction.'], c5.pixUm, c5.src.pixUm);

%% (7) DIMENSIONS, AND AN FOV THAT FOLLOWS THE PIXEL SIZE --------------------------------------------
W = 256; H = 200;                              % deliberately not square: a swap would read as 256x256
pd = fullfile(root,'withmovie');
mkProject(pd, 'cellM', FILE_PX, FILE_DT);
mkdir(fullfile(pd,'spt'));
imwrite(uint16(zeros(H,W)), fullfile(pd,'spt','cellM.tif'));

cD = spt_project_calib(pd);
assert(cD.width == W && cD.height == H, ...
    ['image dimensions came back %gx%g, wanted %gx%g. Without them the FOV is one unexplained ' ...
     'number and cannot be checked against anything.'], cD.width, cD.height, W, H);
wantFov = (W-1)*FILE_PX;
assert(abs(cD.fovUm - wantFov) < 1e-9, 'FOV %.5g, wanted (%d-1) x %.5g = %.5g', cD.fovUm, W, FILE_PX, wantFov);
assert(strcmp(cD.src.dims,'movie'), 'dimensions reported as "%s", not read from the movie', cD.src.dims);

% ...and the FOV must be recomputed from an EDITED pixel size, not left at the file's arithmetic.
writeManifest(pd, 'cellM', pd, EDIT_PX, true, NaN, false);
cE = spt_project_calib(pd);
wantFovE = (W-1)*EDIT_PX;
assert(abs(cE.fovUm - wantFovE) < 1e-9, ...
    ['after correcting the pixel size to %.5g the FOV stayed at %.5g instead of (%d-1) x %.5g = ' ...
     '%.5g. The toolbar would show a pixel size and a field of view that no longer multiply out.'], ...
    EDIT_PX, cE.fovUm, W, EDIT_PX, wantFovE);
assert(contains(cE.why, sprintf('%dx%d px', W, H)), ...
    'the status line does not name the dimensions the FOV came from: "%s"', cE.why);

fprintf('files %.5g µm/px -> edited %.5g · dt %.5g -> %.5g · %dx%d px -> FOV %.5g µm\n', ...
    FILE_PX, c1.pixUm, FILE_DT, c1.dt_s, W, H, cE.fovUm);
fprintf('%s\n', cE.why);
fprintf('\nCALIBRATION-EDIT SMOKE PASSED.\n');
end

% ================================================================================================
function mkProject(p, base, pixUm, dtS)
mkdir(fullfile(p,'tracks'));
fid = fopen(fullfile(p,'tracks',[base '_settings.txt']),'w');
fprintf(fid, 'calibration.pixel_um = %.10g\n', pixUm);
fprintf(fid, 'calibration.frame_s = %.10g\n',  dtS);
fclose(fid);
end

function writeManifest(p, file, ownerProject, pixUm, pixLock, dtS, dtLock)
% One manifest row, shaped the way spt_experiment_panel writes it. ownerProject is stored on the row
% and is what scopes the edit — it is NOT necessarily the folder the manifest sits in, which is the
% whole point of assertion 6.
manifest = struct();
manifest.folders = {ownerProject};
manifest.cells = struct('file',file, 'project',ownerProject, 'day','', 'condition','', ...
    'exclude',false, 'reason','', 'notes','', ...
    'pixUm',pixUm, 'pixSrc',tern(pixLock,'edited','movie'), 'pixLock',pixLock, ...
    'dtS',dtS,     'dtSrc', tern(dtLock, 'edited','xml'),   'dtLock', dtLock);
save(fullfile(p,'experiment_details.mat'), 'manifest');
end

function y = tern(c,a,b), if c, y = a; else, y = b; end, end
