function spt_tool3_scale_smoke()
%SPT_TOOL3_SCALE_SMOKE  Tool 3 must draw every image at the scale the TRACKS are in.
%
% THE SAME CLASS OF BUG AS spt_overlay_fov_smoke, one layer down. Tool 3 does not read a movie's
% metadata at draw time — it reads Tracks(k).calib, stamped once at build. So the question is
% whether the BUILD stamps the scale the coordinates are actually in, and it did not:
%
%   TrackImporter_direct/cell_calib resolved the pixel size from the cell's own IMAGE metadata, then
%   the panel, then a hardcoded 0.10785. It never read tracks/<base>_settings.txt — Tool 1's record
%   of what it actually tracked with. The two disagree exactly when a user overrode the pixel size
%   in Tool 1, which is the whole workflow for a movie with no usable metadata: the X_um in the XML
%   are at the OVERRIDE, and the build stamped the tag the user had rejected. Tool 3 then draws the
%   raw frame at (rawW-1)*calib.pixSizeUm and the organelle mask across calib.fovUm, both at the
%   wrong scale, and the overlay slides off the molecules.
%
% WHAT IS ASSERTED:
%   1. IT BITES        — the fixture's movie metadata and _settings.txt disagree, so a build that
%                        preferred the movie is distinguishable from one that prefers the record.
%   2. THE STAMP       — the build stamps the SETTINGS pixel size, i.e. what produced the µm
%                        coordinates in the XML it just read.
%   3. NO FREE FOV     — calib.fovUm is DERIVED as (width-1) x that pixel size, so the pair always
%                        multiplies out. A FOV resolved independently is how a cell came to carry
%                        27.61 µm beside 0.097 µm/px.
%   4. AN EDIT STILL WINS — a hand-edited project value outranks even the settings file, because a
%                        person correcting a plate is asserting the record itself is wrong.
%   5. NO MOVIE, NO GUESS — with no settings file and no movie the panel is used, exactly as before,
%                        so this changes nothing for a project that was already resolving fine.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

W = 256; H = 200;
TOOL1_PX = 0.097;      % what Tool 1 tracked with, and what the X_um in the XML are in
MOVIE_PX = 0.16;       % what the movie's own tags claim — deliberately different
PANEL_PX = 0.10785;    % the panel fallback

root = fullfile(tempdir, sprintf('spt_t3scale_%d', feature('getpid')));
if isfolder(root), rmdir(root,'s'); end
cleanup = onCleanup(@() rmdir(root,'s'));

%% (1)+(2) the record beats the movie ----------------------------------------------------------------
p1 = fullfile(root,'p1'); makeCell(p1, 'cellA', TOOL1_PX, W, H, MOVIE_PX, true);
T = importOne(p1, struct('pixSizeUm',PANEL_PX,'fovUm',27.61,'binNm',30));
assert(~isempty(T), 'the importer returned no tracks — the fixture is not readable');
got = T(1).calib.pixSizeUm;
assert(abs(got - TOOL1_PX) < 1e-9, ...
    ['the build stamped %.5g µm/px. Tool 1 tracked this cell at %.5g (tracks/<base>_settings.txt) ' ...
     'and the X_um in the XML are in that scale; %.5g is the movie tag the user overrode. Tool 3 ' ...
     'would draw every raw frame and organelle mask %.1f%% off.'], ...
    got, TOOL1_PX, MOVIE_PX, 100*abs(MOVIE_PX/TOOL1_PX - 1));
assert(strcmp(T(1).calib.src.pixSizeUm,'settings'), ...
    'the stamped pixel size reports its source as "%s", so nothing downstream can say where it came from', ...
    T(1).calib.src.pixSizeUm);

%% (3) the FOV is derived from it, never resolved separately -------------------------------------------
wantFov = (W-1)*TOOL1_PX;
assert(abs(T(1).calib.fovUm - wantFov) < 1e-6, ...
    ['calib.fovUm is %.5g against a %d px movie at %.5g µm/px, which is %.5g. A FOV that does not ' ...
     'multiply out is exactly how a cell ends up with 27.61 µm beside 0.097 µm/px.'], ...
    T(1).calib.fovUm, W, TOOL1_PX, wantFov);

%% (1, the other half) THE FIX MUST BITE ---------------------------------------------------------------
% The same project WITHOUT a settings file must fall back to the movie, or assertion 2 could be
% passing because the movie tag was never read in the first place.
p2 = fullfile(root,'p2'); makeCell(p2, 'cellA', TOOL1_PX, W, H, MOVIE_PX, false);   % no _settings.txt
T2 = importOne(p2, struct('pixSizeUm',PANEL_PX,'fovUm',27.61,'binNm',30));
assert(abs(T2(1).calib.pixSizeUm - MOVIE_PX) < 1e-3, ...
    ['with no settings file the build stamped %.5g, not the movie''s own %.5g. The movie tag is not ' ...
     'being read at all, so assertion 2 proves nothing about precedence.'], ...
    T2(1).calib.pixSizeUm, MOVIE_PX);

%% (4) a hand edit still outranks the record -----------------------------------------------------------
cb = struct('pixSizeUm',0.25,'fovUm',27.61,'binNm',30);
cb.edited = {'pixSizeUm','fovUm'};
T3 = importOne(p1, cb);
assert(abs(T3(1).calib.pixSizeUm - 0.25) < 1e-9, ...
    ['a hand-edited 0.25 µm/px was overridden by the settings file (%.5g). An edit is the user ' ...
     'asserting the record itself is wrong, and must stay rank 0.'], T3(1).calib.pixSizeUm);
assert(abs(T3(1).calib.fovUm - (W-1)*0.25) < 1e-6, ...
    'the FOV did not follow the edited pixel size: %.5g, wanted %.5g', T3(1).calib.fovUm, (W-1)*0.25);

%% (5) nothing to read: the panel, exactly as before -----------------------------------------------------
p3 = fullfile(root,'p3'); makeCell(p3, 'cellA', TOOL1_PX, W, H, NaN, false);   % no settings, no movie
T4 = importOne(p3, struct('pixSizeUm',PANEL_PX,'fovUm',27.61,'binNm',30));
assert(abs(T4(1).calib.pixSizeUm - PANEL_PX) < 1e-9, ...
    'with nothing to read the build stamped %.5g instead of the panel''s %.5g', T4(1).calib.pixSizeUm, PANEL_PX);
assert(abs(T4(1).calib.fovUm - 27.61) < 1e-6, ...
    ['with no movie there is no width to derive a FOV from, so the panel FOV must stand; got %.5g. ' ...
     'Deriving one anyway would be inventing a width.'], T4(1).calib.fovUm);

fprintf('settings %.5g beats movie tag %.5g · FOV derived %.4g µm · no settings -> movie %.4g · edit -> %.4g\n', ...
    T(1).calib.pixSizeUm, MOVIE_PX, T(1).calib.fovUm, T2(1).calib.pixSizeUm, T3(1).calib.pixSizeUm);
fprintf('\nTOOL-3 SCALE SMOKE PASSED.\n');
end

% ================================================================================================
function T = importOne(dir_, calib)
% The importer is pointed at the TRACKS folder — that is what spt_analyze_app passes (tracksDir),
% and it is the folder the settings file and the ../spt sibling are resolved relative to.
T = TrackImporter_direct(fullfile(dir_,'tracks'), 'Pattern','*_tracks.xml', 'Calib', calib, 'Verbose', false);
end

function makeCell(dir_, base, tool1Px, W, H, moviePx, withSettings)
% A cell whose XML coordinates are in tool1Px, whose movie claims moviePx (NaN = no movie at all),
% and which optionally carries Tool 1's settings record.
mkdir(fullfile(dir_,'tracks'));
tr = fullfile(dir_,'tracks');
rng(3);
far = (W-1)*tool1Px;
rows = []; SPOT = 0;
for t = 1:3
    cx = (t-1)/2 * far; cy = (t-1)/2 * far;
    for i = 0:19
        SPOT = SPOT + 1;
        rows(end+1,:) = [t, SPOT, i, i*0.02, cx+0.02*randn, cy+0.02*randn, ...
                         100, 100, 140, 4000, 0.1, 0.05]; %#ok<AGROW>
    end
end
xml = fopen(fullfile(tr,[base '_tracks.xml']),'w');
fprintf(xml,'<?xml version="1.0" encoding="UTF-8"?>\n');
fprintf(xml,'<Tracks nTracks="3" frameInterval="0.02" spaceUnit="um" timeUnit="s">\n');
for t = 1:3
    r = sortrows(rows(rows(:,1)==t,:),3);
    fprintf(xml,'  <Track TRACK_ID="%d" N_SPOTS="%d">\n',t,size(r,1));
    for i = 1:size(r,1)
        fprintf(xml,'    <Spot SPOT_ID="%d" FRAME="%d" T="%.6f" X="%.6f" Y="%.6f" Z="0.0"/>\n', ...
            r(i,2), r(i,3), r(i,4), r(i,5), r(i,6));
    end
    fprintf(xml,'  </Track>\n');
end
fprintf(xml,'</Tracks>\n'); fclose(xml);

Tb = array2table(rows,'VariableNames',{'TRACK_ID','SPOT_ID','FRAME','T_s','X_um','Y_um','QUALITY', ...
    'MEAN_INTENSITY','MAX_INTENSITY','TOTAL_INTENSITY','MITO_DIST_UM','ER_DIST_UM'});
Tb.TRACK_ID = string(Tb.TRACK_ID);
writetable(Tb, fullfile(tr,[base '_spots.csv']));

if withSettings
    fid = fopen(fullfile(tr,[base '_settings.txt']),'w');
    fprintf(fid,'calibration.pixel_um    = %.10g\n', tool1Px);
    fprintf(fid,'calibration.pixel_um_src= edited\n');
    fprintf(fid,'calibration.frame_s     = 0.02\n');
    fclose(fid);
end

if isfinite(moviePx)
    % <project>/spt/<base>.tif — the layout sibling_image looks in first. ImageJ style: pixels per
    % unit in XResolution with ResolutionUnit=None, which is how Fiji writes a calibrated file.
    mkdir(fullfile(dir_,'spt'));
    f = fullfile(dir_,'spt',[base '.tif']);
    tw = Tiff(f,'w');
    tw.setTag('ImageLength',H); tw.setTag('ImageWidth',W);
    tw.setTag('Photometric',Tiff.Photometric.MinIsBlack);
    tw.setTag('BitsPerSample',16); tw.setTag('SamplesPerPixel',1);
    tw.setTag('PlanarConfiguration',Tiff.PlanarConfiguration.Chunky);
    tw.setTag('ResolutionUnit',Tiff.ResolutionUnit.None);
    tw.setTag('XResolution',1/moviePx); tw.setTag('YResolution',1/moviePx);
    tw.setTag('ImageDescription', sprintf('ImageJ=1.54f\nimages=1\nunit=micron\n'));
    tw.write(uint16(1000+200*rand(H,W))); tw.close();
end
end
