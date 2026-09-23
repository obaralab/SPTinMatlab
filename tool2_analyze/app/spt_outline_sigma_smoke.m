function spt_outline_sigma_smoke()
%SPT_OUTLINE_SIGMA_SMOKE  Contact-site outlines must be made at their own, finer smoothing - not at the
%picker's 240 nm - and regenerating them must keep what the user decided about each site.
%
% WHY: an outline traced on the 240 nm detection density cannot be smaller than the blur (a single
% point's half-max outline is 0.25 µm²). The user's outlines came out ~5x the published VAPB ones
% (median 0.45 vs 0.089 µm²); run on the VAPB data itself, the same rule at 240 nm gives 0.43.
%
% WHAT IS ASSERTED:
%   1. THE SCALE: a compact site's auto outline is below the 240 nm floor at the default (100 nm),
%      and at the floor when the project's saved setting is 240 nm - so the setting is what is read.
%   2. A BRIGHTER NEIGHBOUR does not set a site's threshold: with the peak looked for within 3σ, a
%      faint site 0.45 µm from a bright one keeps its own outline, around its own centre.
%   3. THE MAPPER'S AUTO OUTLINE is the Refine tab's, at the same σ; its metrics density is still 240 nm.
%   4. REGENERATE keeps what was decided: every saved centre that its new outline contains is kept
%      exactly; a centre left between two spots moves to the outline's peak and is flagged; deleted
%      sites stay deleted; the old file is copied first; the setting and a per-site report are written.
%   5. THE REFINE TAB draws the density at the outline σ, changes it with the control, saves it and
%      reads it back, regenerates from its button, flags moved sites in the list, and a frac change
%      keeps a centre that is not the pick.
%   6. THE EXPORT records each outline's σ and note.
%   7. THE NEIGHBOURHOOD BOX is a project setting the same way: the Refine tab reads it, saves it
%      and reads it back, and the diffusion map has a button.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));
addpath(fullfile(here,'..','..','tool3_contactsites','drivers'), fullfile(here,'..','..','tool3_contactsites','app'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_olsig_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
ana = fullfile(proj,'analysis'); mkdir(fullfile(ana,'csIDs'));
cleanup = onCleanup(@() rmdir(proj,'s'));

fov = 16; bin = 30; n = ceil(fov/(bin/1000)); SF = fov/n;
rng(11); nF = 60;
% S1: one compact spot. S2: two dense spots 0.4 µm apart (one site at 240 nm, two at 100 nm).
% S3: a spot that will be deleted. Then diffuse background.
tracks = {};
spots = {[5 5], [9 5], [9.4 5], [5 9]};
for s = 1:numel(spots)
    for j = 1:6, tracks{end+1} = spots{s} + 0.04*randn(nF,2); end %#ok<AGROW>
end
for j = 1:10, tracks{end+1} = 2 + 12*rand(1,2) + 0.05*cumsum(randn(nF,2))/4; end %#ok<AGROW>
nT = numel(tracks); X = nan(nF,nT); Y = X;
for j = 1:nT, X(:,j) = tracks{j}(:,1); Y(:,j) = tracks{j}(:,2); end
Fr = repmat((0:nF-1)',1,nT);
T = struct('file','cellA','matrix',cat(3,Fr,X,Y),'frameInterval',0.02,'lengths',repmat(nF,nT,1), ...
    'trackIDs',(1:nT)','allSpots',struct('X',X(:),'Y',Y(:),'FRAME',Fr(:)), ...
    'calib',struct('fovUm',fov,'binNm',bin,'pixSizeUm',0.16,'dt_s',0.02,'precNm',bin));
Tracks = T; %#ok<NASGU>
save(fullfile(ana,'TrackStruct.mat'),'Tracks','-v7.3');
calib = struct('pixSizeUm',0.16,'fovUm',fov,'dt_s',0.02,'binNm',bin,'snapFovUm',fov); %#ok<NASGU>
save(fullfile(ana,'cs_calib.mat'),'calib');
picks = [5 5; 9.2 5; 5 9];
fid = fopen(fullfile(ana,'csIDs','cellA_CSsites.txt'),'w');
fprintf(fid,' \tX\tY\tXM\tYM\tSlice\tCounter\tCount\n');
for j = 1:size(picks,1)
    fprintf(fid,'%d\t%.3f\t%.3f\t%.3f\t%.3f\t%d\t%d\t%d\n', j, picks(j,1)/SF, picks(j,2)/SF, picks(j,1)/SF, picks(j,2)/SF, 1, 1, 0);
end
fclose(fid);
windows = struct('framesPerWindow',nF,'nWindows',1,'ranges',[0 nF-1],'grid',n,'SF_umPerPx',SF, ...
                 'frameInterval',0.02,'source','tracked'); %#ok<NASGU>
save(cs_ana_path(ana,'density','Density_cellA_CSwindows.mat'),'windows');

%% (1) the scale ------------------------------------------------------------------------------------------
assert(cs_outline_sigma(ana) == 100, 'with nothing saved the outline σ should be the 100 nm default');
F100 = cs_footprints_build(ana, struct('verbose',false));
a100 = F100(1).areaUm2;
assert(a100 < 0.15 && F100(1).sigmaNm == 100, ...
    'a compact spot''s outline at 100 nm is %.3f µm² (σ %g) - it should be well under the 240 nm floor of 0.25', a100, F100(1).sigmaNm);
outlineSigmaNm = 240; CSfoot = struct([]); CSdeleted = struct('file',{},'csID',{},'window',{},'pickPx',{}); %#ok<NASGU>
save(fullfile(ana,'CS_footprints.mat'),'CSfoot','CSdeleted','outlineSigmaNm');
assert(cs_outline_sigma(ana) == 240, 'the saved outlineSigmaNm is not read');
F240 = cs_footprints_build(ana, struct('verbose',false));
assert(F240(1).areaUm2 >= 0.25*0.9, ...
    'at 240 nm the same spot''s outline is %.3f µm²; the blur alone makes it >= 0.25', F240(1).areaUm2);
delete(fullfile(ana,'CS_footprints.mat'));

%% (2) a brighter neighbour ---------------------------------------------------------------------------------
[XX,YY] = meshgrid(1:200); c0 = [100 100]; c1 = c0 + [0.45/SF 0];
g = @(c,a) a*exp(-((XX-c(1)).^2 + (YY-c(2)).^2)/(2*(0.1/SF)^2));
D = g(c0,1) + g(c1,4);
[~, pk] = cs_outline_sigma('scale', 100, SF, 0.6);
fpNew = cs_window_footprint(D, c0, SF, struct('frac',0.5,'maxRadiusUm',0.6,'peakRadiusUm',pk));
fpOld = cs_window_footprint(D, c0, SF, struct('frac',0.5,'maxRadiusUm',0.6));
assert(inpolygon(0,0,fpNew.refboundary(:,1),fpNew.refboundary(:,2)) && max(fpNew.refboundary(:,1)) < 0.3, ...
    'with the peak looked for within 3σ, the faint site should keep its own outline around its centre');
assert(~inpolygon(0,0,fpOld.refboundary(:,1),fpOld.refboundary(:,2)), ...
    'fixture check: with the peak looked for in the whole 0.6 µm cap, the outline should jump to the bright neighbour');

%% (3) the mapper's auto outline ----------------------------------------------------------------------------
W = cs_window_mapper(ana, struct('save',false,'verbose',false));
assert(abs(W(1).areaUm2 - F100(1).areaUm2) < 1e-9, ...
    'the mapper''s auto outline (%.4f µm²) is not the Refine tab''s at the same σ (%.4f)', W(1).areaUm2, F100(1).areaUm2);

%% (4) regenerate ------------------------------------------------------------------------------------------
% an OLD CS_footprints.mat, as saved before σ was recorded: big outlines drawn on the 240 nm view,
% S1's centre nudged off the pick by hand, S2's centre between its two spots, S3 deleted
th = linspace(0,2*pi,50)';
old = rmfield(F240, {'sigmaNm','note'});
old(1).center = [5.03 4.98]; old(1).refboundary = 0.50*[cos(th) sin(th)]; old(1).mode = 'freehand+smooth';
old(2).center = [9.2 5];     old(2).refboundary = 0.45*[cos(th) sin(th)]; old(2).mode = 'freehand';
for q = 1:2, old(q).areaUm2 = polyarea(old(q).refboundary(:,1), old(q).refboundary(:,2)); old(q).edited = true; end
CSfoot = old(1:2); %#ok<NASGU>
CSdeleted = struct('file','cellA','csID',3,'window',1,'pickPx',old(3).pickPx); %#ok<NASGU>
save(fullfile(ana,'CS_footprints.mat'),'CSfoot','CSdeleted');
oldBytes = fileread(fullfile(ana,'CS_footprints.mat'));
R = cs_footprints_regenerate(ana, struct('verbose',false));
assert(R.n == 2 && R.nDeleted == 1 && isfile(R.backup) && strcmp(fileread(R.backup), oldBytes), ...
    'regenerate should redo 2 sites, keep 1 deleted, and first copy the old file unchanged');
Lr = load(fullfile(ana,'CS_footprints.mat'));
assert(Lr.outlineSigmaNm == 100 && numel(Lr.CSdeleted) == 1, 'the setting was not saved, or the deletion was lost');
[Fr2, info] = cs_footprints_resolve(ana);
assert(info.nMerged == 2 && Fr2(3).deleted, 'after regenerating, S3 must still be deleted');
e1 = Fr2(1); e2 = Fr2(2);
assert(isequal(e1.center, [5.03 4.98]) && isempty(e1.note) && strcmp(e1.mode,'halfmax') && e1.sigmaNm == 100, ...
    'S1''s hand-placed centre is inside its new outline and must be kept exactly (got %s, note "%s")', mat2str(e1.center), e1.note);
assert(e1.areaUm2 < 0.15, 'S1 should now have the 100 nm outline (%.3f µm²)', e1.areaUm2);
assert(inpolygon(0,0,e2.refboundary(:,1),e2.refboundary(:,2)) && contains(e2.note,'centre moved') && ...
       min(abs(e2.center(1) - [9 9.4])) < 0.08, ...
    'S2''s centre sat between two spots: it should move onto one, be inside its outline, and be flagged (centre %s, note "%s")', ...
    mat2str(e2.center,3), e2.note);
rep = readtable(R.report, 'TextType','string');
assert(height(rep) == 2 && all(ismember({'old_area_um2','new_area_um2','centre_moved_nm','note'}, rep.Properties.VariableNames)) ...
    && rep.centre_moved_nm(2) > 100 && rep.centre_moved_nm(1) == 0, 'the per-site report is incomplete');

%% (5) the Refine tab ---------------------------------------------------------------------------------------
f = spt_analyze_app('analyze'); f.Visible = 'off'; f.Position = [1 1 1700 1000];
closeApp = onCleanup(@() closeQuietly(f));
pe = findobj(f,'Type','uieditfield');
for k = 1:numel(pe)
    if contains(lower(string(pe(k).Placeholder)),'project')
        pe(k).Value = proj; cb = pe(k).ValueChangedFcn; if ~isempty(cb), cb(pe(k), struct('Value',proj)); end
    end
end
selectTab(f, 'Refine');
press(f, 'Load / build contact sites');
sp = findobj(f,'Tag','refSigma');
assert(isscalar(sp) && sp.Value == 100, 'the Refine tab has no outline σ control reading the project''s 100 nm');
lst = one(findobj(f,'Type','uilistbox'), 'Refine site list', @(x) any(startsWith(string(x.Items),'c1 ')));
assert(contains(lst.Items{2}, '⚠') && ~contains(lst.Items{1}, '⚠'), 'the moved site should be flagged ⚠ in the list, and only it');
ax = one(findobj(f,'Tag','refAxes'), 'Refine axes');
lst.Value = 1; lst.ValueChangedFcn(lst, struct()); drawnow;
[raw, ~] = cs_window_density(X(:), Y(:), Fr(:), 0, nF-1, SF, n, n, 8);
im = findobj(ax,'Type','image');
assert(max(abs(im.CData - imgaussfilt(raw, 100/1000/SF)), [], 'all') < 1e-9, 'the editor does not show the density at the outline σ');
info = one(findobj(f,'Type','uilabel'), 'Refine info label', @(x) startsWith(string(x.Text),'area '));
assert(contains(strjoin(string(info.Text)), 'σ 100 nm'), 'the info panel should say what σ the outline was made at');
% a frac change recomputes AROUND the site's centre, which here is not the pick
fr = one(findobj(f,'Type','uispinner'), 'Refine frac spinner', @(x) isequal(x.Limits,[0.1 0.95]) && isVisibleTab(x));
fr.Value = 0.4; fr.ValueChangedFcn(fr, struct()); drawnow;
st = f.UserData.refState();
assert(isequal(st.foot(1).center, [5.03 4.98]), 'a frac change moved the centre back to the pick (%s)', mat2str(st.foot(1).center));
% the control: redraws at the new σ, saves it, and a reload reads it
f.UserData.refSetSigma(240); drawnow;
im = findobj(ax,'Type','image');
assert(max(abs(im.CData - imgaussfilt(raw, 240/1000/SF)), [], 'all') < 1e-9, 'changing σ did not redraw the density at it');
press(f, 'Save');
assert(cs_outline_sigma(ana) == 240, '💾 Save did not store the outline σ');
sp.Value = 100; press(f, 'Load / build contact sites');
assert(sp.Value == 240, 'reloading did not read the saved outline σ back into the control');
% regenerate from the tab
R2 = f.UserData.refRegen(true); drawnow;
st = f.UserData.refState();
assert(~isempty(R2) && all([st.foot(~[st.foot.deleted]).sigmaNm] == 240) && st.foot(3).deleted, ...
    'the tab''s regenerate did not redo the outlines at its σ, or undeleted a site');
assert(~isempty(findobj(f,'Type','uibutton','Tag','refRegen')), 'no Regenerate button on the Refine tab');
% the neighbourhood box is a project setting too: the tab reads it, saves it and reads it back
bx = findobj(f,'Tag','refBox');
assert(isscalar(bx) && bx.Value == 1.024, 'the Refine tab has no neighbourhood-box control at the 1.024 µm default');
f.UserData.refSetBox(2.048); drawnow; press(f, 'Save');
assert(cs_neighbour_box(ana) == 2.048, '💾 Save did not store the neighbourhood box');
bx.Value = 1.024; press(f, 'Load / build contact sites');
assert(bx.Value == 2.048, 'reloading did not read the saved box back into the control');
assert(~isempty(findobj(f,'Type','uibutton','Tag','refTess')), 'no diffusion-map button on the Refine tab');
closeQuietly(f);

%% (6) the export ----------------------------------------------------------------------------------------
Rx = cs_advisor_export(ana, struct('fovUm',fov,'binNm',bin,'name','olsig'));
t = readtable(fullfile(Rx.outDir,'refinedsites_all.csv'), 'TextType','string');
assert(all(ismember({'outline_sigma_nm','outline_note'}, t.Properties.VariableNames)) && all(t.outline_sigma_nm == 240), ...
    'the export should record each outline''s σ (240 here) and note');

fprintf(['outline σ: compact spot %.3f µm² at 100 nm vs %.3f at 240 · brighter neighbour ignored · mapper = Refine · ' ...
         'regenerate kept 1 centre, moved 1 (flagged), kept the deletion, backed up · tab control/save/reload/regenerate · export columns\n'], ...
        a100, F240(1).areaUm2);
fprintf('\nOUTLINE-SIGMA SMOKE PASSED.\n');
end

% ================================================================================================
function closeQuietly(h)
try, if ~isempty(h) && isgraphics(h), close(h); end, catch, end
end

function selectTab(f, name)
tg = findobj(f,'Type','uitabgroup'); tabs = tg(1).Children;
tg(1).SelectedTab = tabs(arrayfun(@(t) contains(string(t.Title), name), tabs));
drawnow;
end

function press(h, txt)
b = findobj(h,'Type','uibutton');
q = b(arrayfun(@(x) contains(string(x.Text), txt), b));
q = q(arrayfun(@(x) isVisibleTab(x), q));
assert(~isempty(q), 'button "%s" not found on the open tab', txt);
cb = q(1).ButtonPushedFcn; cb(q(1), struct()); drawnow;
end

function tf = isVisibleTab(x)
p = x.Parent;
while ~isempty(p) && ~isa(p,'matlab.ui.container.Tab'), p = p.Parent; end
if isempty(p), tf = true; return; end
tf = isequal(p.Parent.SelectedTab, p);
end

function h = one(hs, what, test)
if nargin >= 3, hs = hs(arrayfun(@(x) safe(test,x), hs)); end
assert(~isempty(hs), 'could not find the %s', what);
h = hs(1);
end
function tf = safe(test, x), try, tf = logical(test(x)); catch, tf = false; end, end
