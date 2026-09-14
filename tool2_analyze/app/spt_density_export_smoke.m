function spt_density_export_smoke()
%SPT_DENSITY_EXPORT_SMOKE  Opening the contact-site picker must not fill analysis/ with files this
%pipeline never reads — and must still write the one file it does.
%
% TWO DIFFERENT FILES, ONE CHECKBOX. Opening the picker writes:
%   Densities/<base>_rho.tif       REQUIRED. Its ROW COUNT sets SF = FOV/size(img,1) for the mapper,
%                                  so every site coordinate, area and enrichment downstream is
%                                  scaled by it. Bootstrapped whenever it is missing, checkbox or not.
%   density/Density_<base>.mat/tif EXPORT ONLY, for an external ContactSites codebase. grep finds no
%                                  reader in this repo. Two files per cell = 186 on a 93-cell plate,
%                                  written on first open for a hand-off nobody had asked for.
%
% WHAT IS ASSERTED:
%   1. THE EXPORT IS OFF BY DEFAULT. A default that writes unread files into the user's analysis
%      folder is the one thing this test exists to prevent regressing.
%   2. THE REQUIRED FILE IS STILL BOOTSTRAPPED WITH IT OFF. This is the risk the default creates:
%      turning the checkbox off must not take _rho.tif with it, or the mapper silently loses its
%      µm scale and every downstream area is wrong by whatever the grid ratio happens to be.
%   3. TICKING IT STILL WORKS, and the export lands in density/, not in the analysis/ root where it
%      used to crowd everything else.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_densexp_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
mkdir(fullfile(proj,'analysis'));
cleanup = onCleanup(@() rmdir(proj,'s'));

nF = 40; nT = 8; rng(4);
X = 5 + cumsum(0.02*randn(nF,nT)); Y = 5 + cumsum(0.02*randn(nF,nT));
ok = isfinite(X);
T = struct('matrix', cat(3, repmat((1:nF)',1,nT), X, Y), 'frameInterval',0.02, 'file','cellA', ...
           'lengths', repmat(nF,nT,1), 'trackIDs',(1:nT)', ...
           'allSpots', struct('X',X(ok),'Y',Y(ok),'FRAME',repmat((1:nF)',nT,1)), ...
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

%% (1) off by default ------------------------------------------------------------------------------
ck = findobj(f,'Type','uicheckbox');
box = ck(arrayfun(@(x) contains(string(x.Text),'save density'), ck));
assert(~isempty(box), 'the density-export checkbox was not found');
box = box(1);
assert(~box.Value, ...
    ['the density export is ON by default. It writes two files per cell that nothing in this ' ...
     'pipeline reads — 186 of them on a 93-cell plate — into the user''s analysis folder, the ' ...
     'first time they open the picker.']);

%% (2) the file the mapper needs is written anyway -------------------------------------------------
press(f,'Open windowed picker');
rho = dir(fullfile(proj,'analysis','Densities','*_rho.tif'));
assert(~isempty(rho), ...
    ['no Densities/*_rho.tif after opening the picker with the export off. That file is NOT the ' ...
     'export: its row count sets the µm scale factor the mapper divides by, so without it every ' ...
     'site area and coordinate downstream is wrong.']);
exp1 = [dir(fullfile(proj,'analysis','density','Density_*.mat')); ...
        dir(fullfile(proj,'analysis','Density_*.mat'))];
assert(isempty(exp1), ...
    'the export was written (%s) with the checkbox off', strjoin({exp1.name}, ', '));

%% (3) ticking it writes the export, into density/ ---------------------------------------------------
box.Value = true;
press(f,'Open windowed picker');
exp2 = dir(fullfile(proj,'analysis','density','Density_*.mat'));
assert(~isempty(exp2), 'ticking the box wrote no export');
assert(isempty(dir(fullfile(proj,'analysis','Density_*.mat'))), ...
    'the export landed in the analysis/ root again, which is what putting it in density/ was for');

fprintf('export off by default · _rho.tif bootstrapped anyway (%s) · ticking writes %d export(s) into density/\n', ...
    rho(1).name, numel(exp2));
fprintf('\nDENSITY-EXPORT SMOKE PASSED.\n');
end

% ================================================================================================
function press(h, txt)
b = findobj(h,'Type','uibutton');
q = b(arrayfun(@(x) contains(string(x.Text), txt), b));
assert(~isempty(q), 'button "%s" not found', txt);
cb = q(1).ButtonPushedFcn; cb(q(1), struct()); drawnow;
end
