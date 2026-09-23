function cs_tessellate_smoke()
%CS_TESSELLATE_SMOKE  A site has to be compared with its NEIGHBOURHOOD, and the neighbourhood has to
%be the cell - not the square of empty coverslip around it.
%
% WHAT IS ASSERTED:
%   1. THE TESSELS STAY IN THE CELL: every tessel is clipped to the localization support, so their
%      areas add up to the support's area and none of them reaches into empty field. A tessel's
%      density is then a real density.
%   2. D IS RECOVERED WHERE IT IS: molecules that slow down inside a patch make the tessels there
%      slow (0.05 um^2/s against 0.30 outside), and the noise correction matters - the uncorrected
%      estimate of the same steps is inflated by the 30 nm localization error.
%   3. THE SITE INHERITS IT: the mapper attaches each site's slice, and a slow site reads slower
%      inside its outline than in its neighbourhood (DeffIn < DeffNear).
%   4. THE NEIGHBOURHOOD BOX IS THE USER'S: its width is the project setting (1.024 um, the VAPB
%      dataset's, by default), neighbours are exactly what is in the box but outside the outline,
%      and widening the setting takes in more of them.
%   5. WITHOUT THE TESSELLATION nothing breaks: the diffusion fields are NaN and every other number
%      the mapper reports is unchanged.
%   6. ROLLING D IS SPLIT THE SAME WAY (DtIn / DtNear), from the per-localization Dt the build makes.
%   7. THE APP RUNS IT OVER A WHOLE PROJECT and says what it found. Two cells, because the summary
%      has to combine per-cell results of DIFFERENT lengths - a one-cell project hides that, and the
%      first version of this button crashed on the second cell's tessels when a user pressed it.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath')); addpath(here);
root_ = fileparts(fileparts(here));          % the two tools share the build, the channels and the manifest
addpath(fullfile(root_,'tool2_analyze','drivers'), fullfile(root_,'tool2_analyze','app'), ...
        fullfile(root_,'tool3_contactsites','app'));
proj = fullfile(tempdir, sprintf('spt_tess_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
ana = fullfile(proj,'analysis'); mkdir(fullfile(ana,'csIDs'));
cleanup = onCleanup(@() rmdir(proj,'s'));

fov = 16; bin = 30; n = ceil(fov/(bin/1000)); SF = fov/n; dt = 0.02; sig = 0.030;
Dslow = 0.05; Dfast = 0.30; site = [8 8]; rad = 0.35;
rng(7); nF = 200; nTr = 220;
X = nan(nF,nTr); Y = X;
for j = 1:nTr
    p = nan(nF,2); p(1,:) = [1 1] + 13*rand*[1 1] + 0.25*randn(1,2);   % a diagonal band of "ER"
    for t = 2:nF                                                        % D depends on WHERE it is
        d = Dfast; if hypot(p(t-1,1)-site(1), p(t-1,2)-site(2)) < rad, d = Dslow; end
        p(t,:) = p(t-1,:) + sqrt(2*d*dt)*randn(1,2);
    end
    p = p + sig*randn(nF,2);                                            % localization noise
    X(:,j) = p(:,1); Y(:,j) = p(:,2);
end
Fr = repmat((0:nF-1)',1,nTr);
% per-localization rolling D, as spt_track_diffusion writes it (noise-corrected single step)
Dt = nan(nF,nTr);
dr2 = [sum(diff(cat(3,X,Y),1,1).^2, 3); nan(1,nTr)];
for j = 1:nTr, Dt(:,j) = max(0, movmean(dr2(:,j), 7, 'omitnan')/(4*dt) - sig^2/dt); end
T = struct('file','cellA','matrix',cat(3,Fr,X,Y),'frameInterval',dt,'lengths',repmat(nF,nTr,1), ...
    'trackIDs',(1:nTr)','allSpots',struct('X',X(:),'Y',Y(:),'FRAME',Fr(:)),'Dt',Dt, ...
    'vector',cat(3,diff(X,1,1),diff(Y,1,1)), ...
    'calib',struct('fovUm',fov,'binNm',bin,'pixSizeUm',0.16,'dt_s',dt,'precNm',1000*sig));
% a SECOND cell, smaller: the per-cell results then have different lengths, which is what the app's
% summary line has to survive
rng(12); nTrB = 70;
XB = nan(nF,nTrB); YB = XB;
for j = 1:nTrB
    p = nan(nF,2); p(1,:) = [2 2] + 10*rand*[1 1] + 0.25*randn(1,2);
    for t = 2:nF, p(t,:) = p(t-1,:) + sqrt(2*Dfast*dt)*randn(1,2); end
    p = p + sig*randn(nF,2);
    XB(:,j) = p(:,1); YB(:,j) = p(:,2);
end
FrB = repmat((0:nF-1)',1,nTrB);
TB = struct('file','cellB','matrix',cat(3,FrB,XB,YB),'frameInterval',dt,'lengths',repmat(nF,nTrB,1), ...
    'trackIDs',(1:nTrB)','allSpots',struct('X',XB(:),'Y',YB(:),'FRAME',FrB(:)),'Dt',nan(nF,nTrB), ...
    'vector',cat(3,diff(XB,1,1),diff(YB,1,1)), ...
    'calib',struct('fovUm',fov,'binNm',bin,'pixSizeUm',0.16,'dt_s',dt,'precNm',1000*sig));
Tracks = [T TB]; %#ok<NASGU>
save(fullfile(ana,'TrackStruct.mat'),'Tracks','-v7.3');
calib = struct('pixSizeUm',0.16,'fovUm',fov,'dt_s',dt,'binNm',bin,'snapFovUm',fov); %#ok<NASGU>
save(fullfile(ana,'cs_calib.mat'),'calib');
fid = fopen(fullfile(ana,'csIDs','cellA_CSsites.txt'),'w');
fprintf(fid,' \tX\tY\tXM\tYM\tSlice\tCounter\tCount\n');
fprintf(fid,'1\t%.3f\t%.3f\t%.3f\t%.3f\t1\t1\t0\n', site(1)/SF, site(2)/SF, site(1)/SF, site(2)/SF);
fclose(fid);
windows = struct('framesPerWindow',nF,'nWindows',1,'ranges',[0 nF-1],'grid',n,'SF_umPerPx',SF, ...
                 'frameInterval',dt,'source','tracked'); %#ok<NASGU>
save(cs_ana_path(ana,'density','Density_cellA_CSwindows.mat'),'windows');
save(cs_ana_path(ana,'density','Density_cellB_CSwindows.mat'),'windows');

%% (5) the mapper without a tessellation ------------------------------------------------------------
W0 = cs_window_mapper(ana, struct('save',false,'verbose',false));
assert(isscalar(W0) && isnan(W0.DeffIn) && isnan(W0.DeffNear) && all(isnan(W0.Deff(:))), ...
    'with no tessellation the diffusion fields should be NaN, not zero or missing');
assert(W0.nLocInside > 0 && W0.nLocNear > 0, 'the site should still have its counts');

%% (1) the tessels stay in the cell ------------------------------------------------------------------
TS = cs_tessellate(ana, struct('minLocs',60,'minSteps',20,'verbose',false));
e = TS(1);
assert(abs(e.nTessels - round(e.nLoc/60)) <= 0.15*round(e.nLoc/60), ...
    'asked for one tessel per 60 localizations: %d tessels for %d localizations', e.nTessels, e.nLoc);
supportUm2 = e.supportFrac * (e.grid*e.SF)^2;
assert(abs(sum(e.areaUm2,'omitnan') - supportUm2) < 0.05*supportUm2, ...
    'the tessels cover %.1f um^2 but the support is %.1f um^2 - they are not clipped to the cell', sum(e.areaUm2,'omitnan'), supportUm2);
assert(all(cellfun(@(p) isempty(p) || ~any(isinf(p(:))), e.poly)), 'a tessel polygon is unbounded');
assert(all(cellfun(@(p) isempty(p) || all(p(~isnan(p(:,1)),1) >= -1e-9), e.poly)), 'a tessel reaches outside the field');
assert(median(e.density) > 50, 'tessel densities look like field densities, not cell densities (median %.1f locs/um^2)', median(e.density));

%% (2) D is recovered where it is ----------------------------------------------------------------------
d = hypot(e.centres(:,1)-site(1), e.centres(:,2)-site(2));
Din  = median(e.D(d < rad), 'omitnan');
Dout = median(e.D(d > 1), 'omitnan');
assert(Dout > 0.85*Dfast && Dout < 1.15*Dfast, 'far from the patch D should be ~%.2f, got %.3f', Dfast, Dout);
assert(Din < 0.4*Dfast, 'inside the patch D should be far below %.2f, got %.3f', Dfast, Din);
raw = mean(dr2(:), 'omitnan')/(4*dt);
assert(raw > 1.1*Dfast, 'fixture check: uncorrected, the 30 nm noise should inflate D (%.3f)', raw);

%% (3) and (6) the site inherits it -----------------------------------------------------------------
W = cs_window_mapper(ana, struct('save',false,'verbose',false));
assert(isfinite(W.DeffIn) && isfinite(W.DeffNear) && W.DeffIn < 0.5*W.DeffNear, ...
    'the site should read slower inside (%.3f) than in its neighbourhood (%.3f)', W.DeffIn, W.DeffNear);
assert(isequal(size(W.Deff), [nF numel(W.tracks)]) && isequal(size(W.TessIndex), size(W.Deff)), ...
    'Deff and TessIndex should be the member tracks'' slices');
assert(numel(W.refDeff) == W.nLocInside && numel(W.neighborDeff) == W.nLocNear, ...
    'refDeff / neighborDeff should be one value per inside / neighbour localization');
assert(isfinite(W.DtIn) && isfinite(W.DtNear) && W.DtIn < W.DtNear, ...
    'the rolling D should be split the same way (in %.3f, near %.3f)', W.DtIn, W.DtNear);
assert(isequal(size(W.CSvec), [nF-1 numel(W.tracks) 2]), 'CSvec should carry the member tracks'' step vectors');

%% (4) the neighbourhood box is the user's -------------------------------------------------------------
assert(cs_neighbour_box(ana) == 1.024, 'the default box should be the VAPB dataset''s 1.024 um');
assert(W.boxUm == 1.024, 'the mapper should use the project box');
assert(isequal(sort(W.neighborIDs), setdiff(W.boxLocIDs, W.LocIDs)), ...
    'neighbours must be exactly what is in the box and outside the outline');
M = load(fullfile(ana,'TrackStruct.mat')).Tracks.matrix;
inBox = abs(M(:,:,2)-W.center(1)) <= 0.512 & abs(M(:,:,3)-W.center(2)) <= 0.512;
assert(numel(W.boxLocIDs) == nnz(inBox & isfinite(M(:,:,2))), 'the box is not %g um wide about the site centre', W.boxUm);
CSfoot = struct([]); CSdeleted = struct('file',{},'csID',{},'window',{},'pickPx',{}); neighbourBoxUm = 2.0; %#ok<NASGU>
save(fullfile(ana,'CS_footprints.mat'),'CSfoot','CSdeleted','neighbourBoxUm');
assert(cs_neighbour_box(ana) == 2.0, 'the saved box width is not read back');
W2 = cs_window_mapper(ana, struct('save',false,'verbose',false));
assert(W2.boxUm == 2.0 && W2.nLocNear > W.nLocNear && W2.nLocInside == W.nLocInside, ...
    'widening the box should take in more neighbours (%d -> %d) and change nothing inside', W.nLocNear, W2.nLocNear);
delete(fullfile(ana,'CS_footprints.mat'));

%% (7) the app's button, over both cells ------------------------------------------------------------
here2 = fileparts(mfilename('fullpath'));
addpath(fullfile(fileparts(fileparts(here2)),'tool2_analyze','app'));
app = spt_analyze_app('analyze'); app.Visible = 'off';
closeApp = onCleanup(@() closeQuietly(app));
pe = findobj(app,'Type','uieditfield');
for q = 1:numel(pe)
    if contains(lower(string(pe(q).Placeholder)),'project')
        pe(q).Value = proj; cb = pe(q).ValueChangedFcn; if ~isempty(cb), cb(pe(q), struct('Value',proj)); end
    end
end
Rapp = app.UserData.runTessellation(true);      % true = no confirmation dialog
assert(numel(Rapp) == 2, 'the app should map both cells, got %d', numel(Rapp));
lbl = findobj(app,'Type','uilabel');
txt = '';
for q = 1:numel(lbl)
    t = char(strjoin(string(lbl(q).Text),' '));
    if contains(t,'Diffusion map:'), txt = t; break; end
end
assert(contains(txt,'2 cell(s)') && contains(txt,'median D'), ...
    'the app should report what it found over both cells, said: "%s"', txt);
assert(isfile(fullfile(ana,'CS_tessellation.mat')), 'the app run should have saved the map');

fprintf(['tessellation: %d tessels over %d locs, clipped to the cell (%.0f of %.0f um^2); D %.3f in the patch ' ...
         'vs %.3f outside (truth %.2f / %.2f, uncorrected %.3f)\n'], e.nTessels, e.nLoc, sum(e.areaUm2,'omitnan'), ...
         supportUm2, Din, Dout, Dslow, Dfast, raw);
fprintf('site: %d inside / %d near in a %.3f um box · Deff %.3f vs %.3f · rolling D %.3f vs %.3f\n', ...
    W.nLocInside, W.nLocNear, W.boxUm, W.DeffIn, W.DeffNear, W.DtIn, W.DtNear);
fprintf('app: both cells mapped and reported — "%s"\n', txt);
fprintf('\nTESSELLATE SMOKE PASSED.\n');
end

function closeQuietly(h)
try, if ~isempty(h) && isgraphics(h), close(h); end, catch, end
end
