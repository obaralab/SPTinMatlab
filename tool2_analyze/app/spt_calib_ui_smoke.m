function spt_calib_ui_smoke()
%SPT_CALIB_UI_SMOKE  Typing a calibration on the Experiment tab must change the TOP BAR, the file
%every downstream stage reads, and the build — not just the table you typed it into.
%
% spt_calib_edit_smoke covers the resolver. This covers the WIRING, which is where the original bug
% lived: the manifest held the correction, and nothing asked for it again until the project was
% reopened. The tool went on analysing at the fallback while the Experiment tab displayed the
% correction, and the two never met.
%
% WHAT IS ASSERTED:
%   1. THE TOP BAR FOLLOWS  — editing µm/px on the Experiment tab moves the top-bar Pixel field.
%   2. IT BITES             — the top bar held a DIFFERENT value first, so assertion 1 is not
%                             passing because both happened to agree already.
%   3. THE FOV FOLLOWS      — FOV is (width-1) x pixel size and is recomputed, so the toolbar never
%                             shows a pixel size beside a field of view computed from another one.
%   4. IT IS PERSISTED      — analysis/cs_calib.mat carries the edited value, because that file, not
%                             the panel, is what cs_config hands to every downstream stage.
%   5. IT REACHES THE BUILD — the Calib struct sent to the importer marks the edited fields, which
%                             is what lets a correction outrank a stale frameInterval in the XML.
%   6. DIMENSIONS ARE SHOWN — the top bar names the pixel dimensions the FOV is computed from.
%
% Synthetic; reads no dataset. Runs offscreen.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(fileparts(here),'drivers'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

FILE_PX = 0.16;  FILE_DT = 0.05;
EDIT_PX = 0.107;
W = 256; H = 200;

proj = fullfile(tempdir, sprintf('spt_calibui_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(fullfile(proj,'tracks')); mkdir(fullfile(proj,'analysis')); mkdir(fullfile(proj,'spt'));
cleanup = onCleanup(@() rmdir(proj,'s'));
fid = fopen(fullfile(proj,'tracks','cellA_settings.txt'),'w');
fprintf(fid,'calibration.pixel_um = %.10g\ncalibration.frame_s = %.10g\n', FILE_PX, FILE_DT);
fclose(fid);
imwrite(uint16(zeros(H,W)), fullfile(proj,'spt','cellA.tif'));

f = spt_analyze_app('analyze'); f.Visible = 'off';
closeApp = onCleanup(@() close(f));
pe = findobj(f,'Type','uieditfield');
for k = 1:numel(pe)
    if contains(lower(string(pe(k).Placeholder)),'project')
        pe(k).Value = proj; cb = pe(k).ValueChangedFcn; if ~isempty(cb), cb(pe(k), struct('Value',proj)); end
    end
end
drawnow;

% Numeric edit fields report Type 'uinumericeditfield', not 'uieditfield' — searching for the
% latter finds the project-path box and nothing else.
nf   = findobj(f,'Type','uinumericeditfield');
ePx  = pick(nf, @(x) isequal(x.Limits,[1e-4 10]), 'top-bar Pixel field');
eFov = pick(nf, @(x) isequal(x.Limits,[0.1 1e4]), 'top-bar FOV field');
% By Tag: matching on the text found the "Pixel µm/px" caption, which also ends in "px".
lD   = pick(findobj(f,'Tag','calibDims'), @(x) true, 'dimensions label');

%% (2) the top bar starts on the FILE value ---------------------------------------------------------
assert(abs(ePx.Value - FILE_PX) < 1e-9, ...
    ['the top bar opened at %.5g, not the settings file''s %.5g. This fixture cannot show that an ' ...
     'edit propagates, because the two values would already agree.'], ePx.Value, FILE_PX);

%% (6) the dimensions the FOV comes from --------------------------------------------------------------
assert(contains(string(lD.Text), sprintf('%d', W)) && contains(string(lD.Text), sprintf('%d', H)), ...
    'the top bar shows "%s" instead of the %dx%d pixel dimensions the FOV is computed from', lD.Text, W, H);

%% now type the correction where the user types it: the Experiment tab -------------------------------
ctl = f.UserData;
assert(isstruct(ctl) && isfield(ctl,'exptCtl'), ...
    ['the app exposes no handle to the Experiment panel, so this test cannot drive the control the ' ...
     'user actually uses and would be asserting on a path nobody takes']);
ec = ctl.exptCtl();
assert(~isempty(ec) && isstruct(ec), 'the Experiment panel was never built');
cells = ec.getCells();
assert(~isempty(cells), 'the Experiment tab found no cells in the project, so there is nothing to edit');
ec.setCalib(proj, 'cellA', EDIT_PX, NaN, 'edited', true);      % lock=true is what a hand edit does
drawnow;

%% (1) the top bar followed ----------------------------------------------------------------------------
assert(abs(ePx.Value - EDIT_PX) < 1e-9, ...
    ['after editing µm/px to %.5g on the Experiment tab the top bar still reads %.5g. The manifest ' ...
     'holds the correction and the rest of the tool is using the old value, which is exactly the ' ...
     'state where the two disagree with nothing on screen to say so.'], EDIT_PX, ePx.Value);

%% (3) the FOV followed the pixel size -----------------------------------------------------------------
wantFov = (W-1)*EDIT_PX;
assert(abs(eFov.Value - wantFov) < 1e-6, ...
    ['FOV reads %.5g but the toolbar says %d px at %.5g µm/px, which is %.5g. A pixel size and a ' ...
     'field of view that do not multiply out is a silently wrong density scale.'], ...
    eFov.Value, W, EDIT_PX, wantFov);

%% (4) it reached the file every downstream stage reads --------------------------------------------------
cc = fullfile(proj,'analysis','cs_calib.mat');
assert(isfile(cc), ...
    ['no analysis/cs_calib.mat after the edit. cs_config reads that file, not the panel, so nothing ' ...
     'downstream would see the correction.']);
S = load(cc,'calib');
assert(abs(S.calib.pixSizeUm - EDIT_PX) < 1e-9, ...
    'analysis/cs_calib.mat holds %.5g, not the edited %.5g', S.calib.pixSizeUm, EDIT_PX);
assert(abs(S.calib.fovUm - wantFov) < 1e-6, ...
    'analysis/cs_calib.mat holds FOV %.5g, not the recomputed %.5g', S.calib.fovUm, wantFov);

%% (5) and the build is told WHICH fields were edited ------------------------------------------------------
assert(isfield(ctl,'calibForBuild'), 'the app exposes no view of the Calib struct it sends to the build');
cb = ctl.calibForBuild();
assert(isfield(cb,'edited') && iscellstr(cb.edited), ...
    'the Calib struct carries no ''edited'' list, so the importer cannot rank a correction above the XML');
assert(any(strcmp(cb.edited,'pixSizeUm')), ...
    ['the build is not told the pixel size was edited (edited = {%s}). Without that, cell_calib ' ...
     'prefers the cell''s own file and the build runs at the scale the user rejected.'], ...
    strjoin(cb.edited, ', '));
assert(abs(cb.pixSizeUm - EDIT_PX) < 1e-9, 'the build would receive %.5g, not %.5g', cb.pixSizeUm, EDIT_PX);

fprintf('top bar %.5g -> %.5g µm/px · FOV -> %.5g µm (%dx%d px) · cs_calib.mat written · build told: %s\n', ...
    FILE_PX, ePx.Value, eFov.Value, W, H, strjoin(cb.edited,', '));
fprintf('\nCALIBRATION-UI SMOKE PASSED.\n');
end

% ================================================================================================
function h = pick(hs, test, what)
hit = hs(arrayfun(@(x) safe(test,x), hs));
assert(~isempty(hit), 'could not find the %s', what);
h = hit(1);
end

function tf = safe(test, x)
try, tf = logical(test(x)); catch, tf = false; end
end
