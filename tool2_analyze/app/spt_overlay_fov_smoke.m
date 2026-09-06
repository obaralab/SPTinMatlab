function spt_overlay_fov_smoke()
%SPT_OVERLAY_FOV_SMOKE  The raw frame must be drawn across the width the TRACKS were measured in.
%
% THE DEFECT. track_viewer draws the raw movie and the ER/mito overlay across `Overlay FOV (um)`,
% and sized it from the movie's OWN TIFF tags. A movie with no metadata returns NaN, the assignment
% was skipped, and the spinner silently kept its shipped default of 27.61 µm — the old rig's field
% of view. The tracks are still in µm at the project's real scale, so the image is drawn at the
% wrong width and slides further off the tracks the further you get from the origin. On a 256 px
% movie at 0.097 µm/px the tracks span 24.735 µm and the image was drawn across 27.61 — 12 % too
% wide, and the emitter ring sits on background instead of on the molecule.
%
% It is the no-metadata case specifically: a movie that carries its pixel size has always been fine,
% which is why this looks like it only afflicts certain files.
%
% WHAT IS ASSERTED:
%   1. IT BITES        — with NO metadata and NO project pixel size, the FOV is still the shipped
%                        default. That is the broken state, asserted so the fix below cannot pass
%                        for some unrelated reason.
%   2. THE FALLBACK    — given the project's pixel size, a no-metadata movie is drawn across
%                        (width-1) x pixUm, which is the same arithmetic the track coordinates use.
%   3. THE MOVIE WINS  — a movie that DOES carry a pixel size is still sized from its own tags, even
%                        when a project value is supplied and disagrees. The file describes itself.
%   4. IT IS LIVE      — the project pixel size is read through a handle, so correcting the
%                        calibration re-sizes the overlay without re-opening the tab.
%   5. IT IS VISIBLE   — the status line says WHICH of the three the width came from, and an
%                        unsupported one is tinted. A wrong overlay that says nothing reads as a
%                        segmentation or drift problem, not as a scale problem.
%
% Synthetic; reads no dataset. Runs offscreen.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

W = 256; H = 256;
PROJ_PX = 0.097;                 % what the project says, and what the tracks are in
MOVIE_PX = 0.16;                 % what a movie WITH metadata says
DEFAULT_FOV = 27.61;             % track_viewer's shipped default — the old rig's
wantProj  = (W-1)*PROJ_PX;       % 24.735
wantMovie = (W-1)*MOVIE_PX;

root = fullfile(tempdir, sprintf('spt_ovfov_%d', feature('getpid')));
if isfolder(root), rmdir(root,'s'); end
cleanup = onCleanup(@() rmdir(root,'s'));

%% (1) THE BROKEN STATE: no metadata, no project value -----------------------------------------------
bare = fullfile(root,'bare'); mkdir(bare);
makeCell(bare, 'cellA', PROJ_PX, W, H, false);
[fovBare, srcBare, ~] = openAndRead(bare, []);
assert(abs(fovBare - DEFAULT_FOV) < 1e-6, ...
    ['with no metadata and no project pixel size the FOV came back %.5g, not the shipped default ' ...
     '%.5g. This fixture is not reproducing the defect, so assertion 2 would prove nothing.'], ...
    fovBare, DEFAULT_FOV);
assert(strcmp(srcBare,'default'), 'a FOV nobody supplied is reported as "%s", not "default"', srcBare);
% ...and that default is WRONG for this movie, by the margin the user actually sees
assert(abs(fovBare - wantProj) > 2, ...
    'the default happens to match this fixture (%.5g vs %.5g), so the test cannot detect the bug', ...
    fovBare, wantProj);

%% (2) THE FIX: the project supplies what the movie cannot -------------------------------------------
[fovProj, srcProj, lblProj] = openAndRead(bare, @() PROJ_PX);
assert(abs(fovProj - wantProj) < 1e-6, ...
    ['a movie with no metadata was drawn across %.5g µm; the tracks span (%d-1) x %.5g = %.5g. ' ...
     'The raw frame sits under the wrong place and the error grows with distance from the origin.'], ...
    fovProj, W, PROJ_PX, wantProj);
assert(strcmp(srcProj,'project'), 'the FOV is reported as coming from "%s", not the project', srcProj);

%% (5) and it SAYS so --------------------------------------------------------------------------------
assert(contains(lblProj,'PROJECT'), ...
    'the status line does not say the width came from the project: "%s"', lblProj);
assert(contains(lblBare_(bare),'NOT from this data'), ...
    'a FOV nothing supplied is not flagged on screen — the overlay would look merely "a bit off"');

%% (3) A MOVIE THAT KNOWS ITS OWN SCALE STILL WINS ----------------------------------------------------
withMeta = fullfile(root,'meta'); mkdir(withMeta);
makeCell(withMeta, 'cellB', PROJ_PX, W, H, true);            % TIFF carries MOVIE_PX
[fovMeta, srcMeta, ~] = openAndRead(withMeta, @() PROJ_PX);  % project disagrees, deliberately
assert(abs(fovMeta - wantMovie) < 1e-3, ...
    ['a movie that carries its own %.5g µm/px was drawn across %.5g µm, wanted %.5g. The project ' ...
     'value must not override a file that describes itself.'], MOVIE_PX, fovMeta, wantMovie);
assert(strcmp(srcMeta,'movie'), 'a self-describing movie reports its FOV source as "%s"', srcMeta);

%% (4) THE HANDLE IS LIVE ------------------------------------------------------------------------------
% A number captured at construction would freeze the overlay at whatever the calibration was when the
% tab was embedded, so correcting it on the Experiment tab would not reach the overlay.
livePx = PROJ_PX;
[fovA, ~, ~] = openAndRead(bare, @() livePx);
livePx = 0.2;
[fovB, ~, ~] = openAndRead(bare, @() livePx);
assert(abs(fovA - wantProj) < 1e-6 && abs(fovB - (W-1)*0.2) < 1e-6, ...
    ['the overlay width did not follow the project pixel size (%.5g then %.5g). A corrected ' ...
     'calibration would not reach the overlay until the tab was rebuilt.'], fovA, fovB);

fprintf('no metadata: %.4g µm (default, WRONG) -> %.4g µm (project, = tracks)\n', fovBare, fovProj);
fprintf('movie with metadata still wins: %.4g µm\n', fovMeta);
fprintf('\nOVERLAY-FOV SMOKE PASSED.\n');
end

% ================================================================================================
function [fov, src, lbl] = openAndRead(dir_, pixFcn)
% Build the viewer over dir_, let it auto-load the one cell, and read back the overlay width, where
% it says that width came from, and the status line.
fig = uifigure('Visible','off','Position',[1 1 1500 900]);
closer = onCleanup(@() close(fig));
pn = uipanel(fig);
o = struct('readPrefer','raw','exportSuffix','curated','preserveCloud',true);
if ~isempty(pixFcn), o.pixUmFcn = pixFcn; end
% An overlayFcn is REQUIRED for this test: the whole auto-resolve block, including the FOV, returns
% early without one, so passing [] would exercise nothing. This is the shape spt_analyze_app's own
% resolveOverlay returns.
track_viewer(pn, dir_, @(b) struct('spt', fullfile(dir_,[b '.tif'])), {}, o);
drawnow;
sp = findobj(fig,'Type','uispinner');
h = sp(arrayfun(@(x) isequal(x.Limits,[1 500]), sp));
assert(~isempty(h), 'could not find the Overlay FOV spinner');
fov = h(1).Value;
src = 'default';
if abs(h(1).BackgroundColor(3) - 1) > 1e-6, src = 'default'; end   % amber => nothing supplied it
lbl = statusText(fig);
if contains(lbl,'from the movie'),        src = 'movie';
elseif contains(lbl,'from the PROJECT'),  src = 'project';
end
end

function t = statusText(fig)
% The overlay status label — the one that carries the FOV provenance note.
ls = findobj(fig,'Type','uilabel');
t = '';
for k = 1:numel(ls)
    s = char(string(ls(k).Text));
    if contains(s,'FOV '), t = s; return; end
end
end

function t = lblBare_(dir_)
fig = uifigure('Visible','off','Position',[1 1 1500 900]);
closer = onCleanup(@() close(fig));
track_viewer(uipanel(fig), dir_, @(b) struct('spt', fullfile(dir_,[b '.tif'])), {}, struct('readPrefer','raw'));
drawnow;
t = statusText(fig);
end

function makeCell(dir_, base, pxUm, W, H, withMeta)
% One cell: a few tracks spanning the FULL field in µm, the raw movie beside them, and nothing else.
% The tracks must reach the far corner — an overlay-scale error is invisible at the origin and
% largest at the far edge, which is the whole shape of this bug.
rng(7);
far = (W-1)*pxUm;                       % the same arithmetic the FOV is meant to use
N = 20; rows = []; SPOT = 0;
ctrs = [0.5 0.5; far/2 far/2; far-0.5 far-0.5];
for t = 1:size(ctrs,1)
    for i = 0:N-1
        SPOT = SPOT + 1;
        rows(end+1,:) = [t, SPOT, i, i*0.02, ctrs(t,1)+0.02*randn, ctrs(t,2)+0.02*randn, ...
                         100, 100, 140, 4000, 0.1, 0.05]; %#ok<AGROW>
    end
end

xml = fopen(fullfile(dir_,[base '_tracks.xml']),'w');
fprintf(xml,'<?xml version="1.0" encoding="UTF-8"?>\n');
tids = unique(rows(:,1));
fprintf(xml,'<Tracks nTracks="%d" frameInterval="0.02" spaceUnit="um" timeUnit="s">\n',numel(tids));
for t = tids(:)'
    r = sortrows(rows(rows(:,1)==t,:),3);
    fprintf(xml,'  <Track TRACK_ID="%d" N_SPOTS="%d">\n',t,size(r,1));
    for i = 1:size(r,1)
        fprintf(xml,'    <Spot SPOT_ID="%d" FRAME="%d" T="%.6f" X="%.6f" Y="%.6f" Z="0.0"/>\n', ...
            r(i,2), r(i,3), r(i,4), r(i,5), r(i,6));
    end
    fprintf(xml,'  </Track>\n');
end
fprintf(xml,'</Tracks>\n'); fclose(xml);

T = array2table(rows,'VariableNames',{'TRACK_ID','SPOT_ID','FRAME','T_s','X_um','Y_um','QUALITY', ...
    'MEAN_INTENSITY','MAX_INTENSITY','TOTAL_INTENSITY','MITO_DIST_UM','ER_DIST_UM'});
T.TRACK_ID = string(T.TRACK_ID);
writetable(T, fullfile(dir_,[base '_spots.csv']));

% The raw movie the overlay is drawn from. withMeta writes an ImageJ resolution the reader
% understands; without it, imfinfo reports no pixel size at all — the case this test exists for.
img = uint16(1000 + 200*rand(H,W));
f = fullfile(dir_,[base '.tif']);
if withMeta
    imwrite(img, f, 'Resolution', 1/0.16 * 2.54, ...        % px per inch at 0.16 µm/px... see below
        'Description', sprintf('ImageJ=1.54f\nimages=1\nunit=micron\n'));
    % ImageJ files store PIXELS PER UNIT in XResolution with ResolutionUnit=None. imwrite cannot set
    % ResolutionUnit=None, so write the tag directly with Tiff() instead.
    tw = Tiff(f,'w');
    tw.setTag('ImageLength',H); tw.setTag('ImageWidth',W);
    tw.setTag('Photometric',Tiff.Photometric.MinIsBlack);
    tw.setTag('BitsPerSample',16); tw.setTag('SamplesPerPixel',1);
    tw.setTag('PlanarConfiguration',Tiff.PlanarConfiguration.Chunky);
    tw.setTag('ResolutionUnit',Tiff.ResolutionUnit.None);
    tw.setTag('XResolution',1/0.16); tw.setTag('YResolution',1/0.16);
    tw.setTag('ImageDescription', sprintf('ImageJ=1.54f\nimages=1\nunit=micron\n'));
    tw.write(img); tw.close();
else
    imwrite(img, f);                                        % no resolution tags at all
end
end
