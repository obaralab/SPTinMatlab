function spt_calib_handoff_smoke()
%SPT_CALIB_HANDOFF_SMOKE  Tool 1's calibration must reach Tools 2 and 3, and must not be overwritten.
%
% Two failures, one of which was actively destructive:
%
%   1. Tool 2's Auto read ONLY frameInterval out of a tracks XML. Pixel size and field of view kept
%      whatever the panel held — for a new dataset, the previous dataset's numbers — even though
%      tracks/<base>_settings.txt records exactly what Tool 1 tracked with.
%   2. Opening a project then called writeCalib() unconditionally, which saved those untouched
%      defaults into the project as cs_calib.mat. So opening a correctly-tracked project REPLACED
%      its calibration with the wrong one, and every later read believed the wrong file. Measured on
%      a real project: Tool 1 recorded 0.16 µm/px; cs_calib.mat afterwards held 0.10785.
%
% Note the coordinates themselves survive either way — Tool 1 writes the XML in µm using the value it
% actually used — so this corrupts what is DERIVED downstream (densities, areas, overlay
% registration), not the tracks. That is why it went unnoticed.

here = fileparts(mfilename('fullpath')); addpath(here);
tmp = fullfile(tempdir,'spt_calib_handoff'); if isfolder(tmp), rmdir(tmp,'s'); end
proj = fullfile(tmp,'proj'); mkdir(fullfile(proj,'tracks')); mkdir(fullfile(proj,'spt'));
base = 'cellA';

PX = 0.16; DT = 0.010519135743379593; W = 128;
write_movie(fullfile(proj,'spt',[base '.tif']), W, PX, DT);
write_settings(fullfile(proj,'tracks',[base '_settings.txt']), PX, DT);
write_xml(fullfile(proj,'tracks',[base '_tracks.xml']), DT);

% ---- 1. the values are recovered, and their provenance is reported ------------------------------
c = spt_project_calib(proj);
fprintf('pix %.6g (%s) · dt %.9g (%s) · fov %.6g (%s)\n', ...
    c.pixUm,c.src.pixUm, c.dt_s,c.src.dt_s, c.fovUm,c.src.fovUm);
assert(abs(c.pixUm - PX) < 1e-9, 'pixel size not taken from Tool 1''s settings: %g', c.pixUm);
% Tool 1 writes calibration.frame_s at ~7 significant figures, so the settings file is inherently
% coarser than the TIFF's stored value. The difference is ~1e-7 relative — far below anything that
% moves a diffusion coefficient — so the tolerance is relative, not exact.
assert(abs(c.dt_s - DT)/DT < 1e-6, 'frame interval not taken from Tool 1''s settings: %.12g', c.dt_s);
assert(strcmp(c.src.pixUm,'settings'), 'the pixel size should come from settings, got %s', c.src.pixUm);
% FOV spans the CENTRES of the outer columns, matching X_um = (0-based col)*pixUm
assert(abs(c.fovUm - (W-1)*PX) < 1e-9, 'FOV should be (width-1)*pixel, got %g', c.fovUm);
assert(strcmp(c.src.fovUm,'derived'), 'FOV provenance should say derived — Tool 1 records no FOV');

% ---- 2. the settings file outranks the movie -----------------------------------------------------
% If they disagree, Tool 1's record wins: it is what produced the µm coordinates already on disk.
write_settings(fullfile(proj,'tracks',[base '_settings.txt']), 0.11, DT);
c2 = spt_project_calib(proj);
assert(abs(c2.pixUm - 0.11) < 1e-9, ...
    'the movie metadata overrode Tool 1''s record — the coordinates would no longer match');
write_settings(fullfile(proj,'tracks',[base '_settings.txt']), PX, DT);

% ---- 3. no settings file: fall through to the movie ---------------------------------------------
delete(fullfile(proj,'tracks',[base '_settings.txt']));
c3 = spt_project_calib(proj);
fprintf('without settings.txt: pix %.6g (%s) · dt %.9g (%s)\n', c3.pixUm,c3.src.pixUm, c3.dt_s,c3.src.dt_s);
assert(abs(c3.pixUm - PX) < 1e-9 && strcmp(c3.src.pixUm,'movie'), 'the movie fallback failed');
write_settings(fullfile(proj,'tracks',[base '_settings.txt']), PX, DT);

% ---- 4. no movie either: dt still comes from the XML, pixel size honestly absent -----------------
p2 = fullfile(tmp,'noMovie'); mkdir(fullfile(p2,'tracks'));
write_xml(fullfile(p2,'tracks',[base '_tracks.xml']), DT);
c4 = spt_project_calib(p2);
fprintf('XML only: pix %g (%s) · dt %.9g (%s)\n', c4.pixUm,c4.src.pixUm, c4.dt_s,c4.src.dt_s);
assert(isnan(c4.pixUm), 'a pixel size was invented from nothing');
assert(abs(c4.dt_s - DT)/DT < 1e-6 && strcmp(c4.src.dt_s,'xml'), 'dt should still come from the XML');

% ---- 5. an untracked folder must not throw or guess ----------------------------------------------
c5 = spt_project_calib(fullfile(tmp,'nothing_here'));
assert(isnan(c5.pixUm) && isnan(c5.dt_s), 'an empty project should yield nothing, not defaults');

% ---- 6. THE DESTRUCTIVE ONE: opening must not write defaults over the project --------------------
% A stale cs_calib.mat holding the previous dataset's numbers must be corrected, not believed.
calib = struct('pixSizeUm',0.10785,'fovUm',27.61,'dt_s',0.020064,'binNm',30,'snapFovUm',27.61); %#ok<NASGU>
save(fullfile(proj,'tracks','cs_calib.mat'),'calib');
src = fileread(fullfile(fileparts(here),'tool2_analyze','app','spt_analyze_app.m'));
assert(contains(src,'spt_project_calib'), 'Tool 2 does not read the project calibration');
% writeCalib must be reached only when something was actually adopted
i = strfind(src,'function onCalAuto');
assert(~isempty(i), 'onCalAuto not found');
blk = src(i(1):min(numel(src), i(1)+3000));
assert(contains(blk,'if changed'), ...
    'onCalAuto still calls writeCalib unconditionally — opening a project would overwrite it again');
fprintf('Tool 2 adopts the project calibration and only persists when it changed\n');

% ---- 7. the cross-project case: opening B after A must not stamp A's scale into B ----------------
% This is the user's complaint in its sharpest form. B has no settings file and no movie, so nothing
% can supply a pixel size — but its tracks XML DOES supply dt, and an earlier version treated "I
% adopted something" as licence to persist all four fields, writing A's pixel size into B.
pb = fullfile(tmp,'B'); mkdir(fullfile(pb,'tracks'));
write_xml(fullfile(pb,'tracks',[base '_tracks.xml']), 0.02);
cb = spt_project_calib(pb);
fprintf('project with only an XML: pix %g (%s) · dt %g (%s)\n', cb.pixUm,cb.src.pixUm, cb.dt_s,cb.src.dt_s);
assert(isnan(cb.pixUm) && strcmp(cb.src.pixUm,'missing'), 'a pixel size appeared from nowhere');
assert(abs(cb.dt_s-0.02) < 1e-9, 'dt should still be adopted from the XML');
% and the app must tie persistence to the SPATIAL scale, not to "something changed"
assert(contains(blk,'isfinite(pc.pixUm), calibKnown = true'), ...
    ['persistence is not tied to a supported pixel size — adopting dt alone would license writing ' ...
     'a pixel size the project never stated']);
fprintf('persisting a calibration requires a supported pixel size, not merely any adopted field\n');

% ---- 8. the per-cell stamp must find the movie ---------------------------------------------------
% sibling_image searched tracks/, the project root, raw/ and images/ — but not <project>/spt/, which
% is where this pipeline actually puts movies. So the stamp never found one and fell back to the
% panel, which is how a cell recorded at 0.16 got stamped with the panel's 0.10785.
if exist('TrackImporter_direct','file')==2
    Tk = TrackImporter_direct(fullfile(proj,'tracks'), 'AttachCSV',false, 'Save',false, 'Verbose',false, ...
        'Calib', struct('pixSizeUm',0.10785,'fovUm',27.61,'binNm',30,'densBinNm',30));
    if ~isempty(Tk) && isfield(Tk,'calib')
        cc = Tk(1).calib;
        fprintf('per-cell stamp: pix %.6g (%s), fov %.6g (%s)\n', cc.pixSizeUm,cc.src.pixSizeUm, cc.fovUm,cc.src.fovUm);
        assert(abs(cc.pixSizeUm - PX) < 1e-9 && strcmp(cc.src.pixSizeUm,'image'), ...
            'the per-cell stamp did not find <project>/spt/ — it fell back to the panel (%g, %s)', ...
            cc.pixSizeUm, cc.src.pixSizeUm);
    end
end
imp = fileread(fullfile(fileparts(here),'tool2_analyze','drivers','TrackImporter_direct.m'));
assert(contains(imp,"fullfile(d,'..','spt')"), 'sibling_image still does not look in <project>/spt/');

% ---- 9. a calibration edit must reach Tool 3 without a rebuild ------------------------------------
% Nothing reads tracks/cs_calib.mat; it is staging, copied into analysis/ at build. Writing only the
% staging file meant a correction did not reach cs_config until the next rebuild.
app = fileread(fullfile(fileparts(here),'tool2_analyze','app','spt_analyze_app.m'));
assert(contains(app,"ana = fullfile(projectDir,'analysis');"), ...
    'writeCalib still writes only the staging copy — a fix would not reach Tool 3 until a rebuild');

% ---- 10. cs_config must say when it is guessing ---------------------------------------------------
% Its defaults are the reference rig's. On any other microscope a run completes with every
% coordinate, area, density and dwell time mis-scaled, and nothing said so.
cfgsrc = fileread(fullfile(fileparts(here),'tool2_analyze','ContactSites_robust','cs_config.m'));
assert(contains(cfgsrc,'cs_config:defaultCalibration'), ...
    'cs_config still falls back to the reference rig''s calibration silently');
fprintf('per-cell stamp finds the movie · edits reach analysis/ · cs_config warns on defaults\n');

fprintf('\nALL CALIBRATION-HANDOFF ASSERTIONS PASSED.\n');
end

% =================================================================================================
function write_movie(path, W, pxUm, dt)
% A Fiji-style calibrated stack: scale in XResolution, unit in the ImageJ block, ResolutionUnit None.
t = Tiff(path,'w');
setTag(t,'Photometric',Tiff.Photometric.MinIsBlack);
setTag(t,'ImageLength',W); setTag(t,'ImageWidth',W);
setTag(t,'BitsPerSample',16); setTag(t,'SamplesPerPixel',1);
setTag(t,'PlanarConfiguration',Tiff.PlanarConfiguration.Chunky);
setTag(t,'XResolution',1/pxUm); setTag(t,'YResolution',1/pxUm); setTag(t,'ResolutionUnit',1);
setTag(t,'ImageDescription', sprintf('ImageJ=1.54f\nimages=1\nframes=1\nunit=micron\nfinterval=%.17g\n', dt));
write(t, uint16(zeros(W))); close(t);
end

function write_settings(path, pxUm, dt)
fid = fopen(path,'w'); c = onCleanup(@() fclose(fid));
fprintf(fid, ['# SPT Track run settings\n' ...
              'tracking.link_mode      = geodesic\n' ...
              'calibration.pixel_um    = %g\n' ...
              'calibration.frame_s     = %.7g\n' ...
              'result.n_spots          = 100\n' ...
              'result.n_tracks         = 10\n'], pxUm, dt);
end

function write_xml(path, dt)
fid = fopen(path,'w'); c = onCleanup(@() fclose(fid));
fprintf(fid,'<?xml version="1.0" encoding="UTF-8"?>\n');
fprintf(fid,'<Tracks nTracks="10" frameInterval="%.7g" spaceUnit="um" timeUnit="s">\n</Tracks>\n', dt);
end
