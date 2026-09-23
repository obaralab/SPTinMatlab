function spt_density_export_smoke()
%SPT_DENSITY_EXPORT_SMOKE  Opening the contact-site picker must write only the one density file this
%pipeline needs, built from the localizations the picker actually shows.
%
% TWO DIFFERENT FILES. Opening the picker writes:
%   Densities/<base>_rho.tif       REQUIRED. Its ROW COUNT sets SF = FOV/size(img,1) for the mapper,
%                                  so every site coordinate, area and enrichment downstream is
%                                  scaled by it. Bootstrapped whenever it is missing.
%   density/Density_<base>.mat/tif EXPORT ONLY, for an external ContactSites codebase. These used to
%                                  be written on open, behind a "(re)save density first" checkbox,
%                                  from the full detection cloud and without the sites they are for.
%                                  They are now the job of the "Export" button (cs_advisor_export_smoke).
%
% WHAT IS ASSERTED:
%   1. THE CHECKBOX IS GONE and the export button is there instead.
%   2. OPENING THE PICKER WRITES NO EXPORT COPY, anywhere.
%   3. THE REQUIRED FILE IS STILL BOOTSTRAPPED, at the right size.
%   4. IT IS BUILT FROM TRACKED LOCALIZATIONS: detections that never linked into a track were planted
%      in an empty corner, and that corner must be empty in the image. It used to be built from the
%      cloud, so its pixels were not the density the sites were picked on.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));
addpath(fullfile(here,'..','..','tool3_contactsites','drivers'), fullfile(here,'..','..','tool3_contactsites','app'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_densexp_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(fullfile(proj,'analysis'));
cleanup = onCleanup(@() rmdir(proj,'s'));

nF = 40; nT = 8; rng(4);
X = 5 + cumsum(0.02*randn(nF,nT)); Y = 5 + cumsum(0.02*randn(nF,nT));
ok = isfinite(X);
% 2000 UNTRACKED detections in a corner no track visits — cloud only
cx = 20 + 0.05*randn(2000,1); cy = 20 + 0.05*randn(2000,1);
T = struct('matrix', cat(3, repmat((1:nF)',1,nT), X, Y), 'frameInterval',0.02, 'file','cellA', ...
           'lengths', repmat(nF,nT,1), 'trackIDs',(1:nT)', ...
           'allSpots', struct('X',[X(ok); cx],'Y',[Y(ok); cy],'FRAME',[repmat((1:nF)',nT,1); ones(2000,1)]), ...
           'dist', struct('mito', abs(X-5)));
Tracks = T; %#ok<NASGU>
save(fullfile(proj,'analysis','TrackStruct.mat'),'Tracks','-v7.3');

f = spt_analyze_app('analyze'); f.Visible = 'off';   % the Contact-sites tab exists only in analyze mode
closeApp = onCleanup(@() close(f));
pe = findobj(f,'Type','uieditfield');
for k = 1:numel(pe)
    if contains(lower(string(pe(k).Placeholder)),'project')
        pe(k).Value = proj; cb = pe(k).ValueChangedFcn; if ~isempty(cb), cb(pe(k), struct('Value',proj)); end
    end
end
drawnow;
tg = findobj(f,'Type','uitabgroup'); tabs = tg(1).Children;
tg(1).SelectedTab = tabs(arrayfun(@(t) contains(string(t.Title),'Contact sites'), tabs));
drawnow;

%% (1) the checkbox is gone; the export button replaces it --------------------------------------------
ck = findobj(f,'Type','uicheckbox');
assert(~any(arrayfun(@(x) contains(string(x.Text),'save density'), ck)), ...
    'the "(re)save density first" checkbox is back; the density hand-off is the export button''s job');
bx = findobj(f,'Type','uibutton');
bxe = findobj(f,'Type','uibutton','Tag','csExport');
assert(~isempty(bxe) && strcmp(string(bxe(1).Text), "📦 Export"), 'the Export button is missing or mislabelled');

%% (2)+(3) opening writes the required file and no export copy -----------------------------------------
press(f,'Open windowed picker');
rho = dir(fullfile(proj,'analysis','Densities','*_rho.tif'));
assert(~isempty(rho), ...
    ['no Densities/*_rho.tif after opening the picker. That file is NOT the export: its row count ' ...
     'sets the µm scale factor the mapper divides by, so without it every site area downstream is wrong.']);
exp1 = [dir(fullfile(proj,'analysis','density','Density_*.mat')); dir(fullfile(proj,'analysis','Density_*.mat')); ...
        dir(fullfile(proj,'analysis','density','Density_cellA.tif'))];
assert(isempty(exp1), 'opening the picker wrote export copies (%s)', strjoin({exp1.name}, ', '));
img = imread(fullfile(rho(1).folder, rho(1).name));
nExp = ceil(27.61/0.030);
assert(size(img,1) == nExp, '_rho.tif is %d px tall; the grid is %d', size(img,1), nExp);

%% (4) built from tracked localizations, not the cloud ---------------------------------------------------
% turbo(1) is the colour of an empty pixel; the cloud corner must be exactly that
c = round(1000*[20 20]/30);
px = double(squeeze(img(c(2), c(1), :)))' / 255;
empty = turbo(256); empty = empty(1,:);
assert(max(abs(px - empty)) < 2/255, ...
    ['_rho.tif has signal at (20,20) um, where only UNTRACKED detections exist. It is being built from ' ...
     'the detection cloud, so it is not the density the picker shows.']);

fprintf('no checkbox · no export copies on open · %s bootstrapped from tracked localizations only\n', rho(1).name);
fprintf('\nDENSITY-EXPORT SMOKE PASSED.\n');
end

% ================================================================================================
function press(h, txt)
b = findobj(h,'Type','uibutton');
q = b(arrayfun(@(x) contains(string(x.Text), txt), b));
assert(~isempty(q), 'button "%s" not found', txt);
cb = q(1).ButtonPushedFcn; cb(q(1), struct()); drawnow;
end
