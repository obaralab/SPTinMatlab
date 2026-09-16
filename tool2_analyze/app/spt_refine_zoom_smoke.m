function spt_refine_zoom_smoke()
%SPT_REFINE_ZOOM_SMOKE  The Refine editor must zoom out (and in) with the scroll wheel — tested with a
%REAL scroll gesture, because nothing else can see this bug.
%
% THE BUG. Creating a colorbar on a uiaxes silently disables scroll-zoom. ax.Interactions still
% reports zoom and pan, InteractionOptions still says zoom is supported and bounded by the whole
% field, and the wheel does nothing. The Refine editor creates its colorbar on the first draw, so it
% could not be zoomed at all. Re-applying the interactions after the colorbar exists restores it.
%
% WHAT IS ASSERTED, each with a scripted wheel gesture (matlab.uitest):
%   1. scrolling DOWN widens the view (zoom out) on a freshly opened site;
%   2. scrolling UP narrows it again;
%   3. it still works after an edit redraws the site, and after a colour-scale change.
%
% This test OPENS A WINDOW: gestures need a rendered figure. It closes it when done.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_refzoom_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
ana = fullfile(proj,'analysis'); mkdir(fullfile(ana,'csIDs'));
cleanup = onCleanup(@() rmdir(proj,'s'));

fov = 16; bin = 30; n = ceil(fov/(bin/1000)); SF = fov/n;
rng(9); nF = 40; tracks = {};
for c = {[5 5],[7 5]}
    for j = 1:6, tracks{end+1} = c{1} + 0.02*cumsum(randn(nF,2))/4; end %#ok<AGROW>
end
nT = numel(tracks); X = nan(nF,nT); Y = X;
for j = 1:nT, X(:,j) = tracks{j}(:,1); Y(:,j) = tracks{j}(:,2); end
Fr = repmat((0:nF-1)',1,nT);
T = struct('file','cellA','matrix',cat(3,Fr,X,Y),'frameInterval',0.02,'lengths',repmat(nF,nT,1), ...
    'trackIDs',(1:nT)','allSpots',struct('X',X(:),'Y',Y(:),'FRAME',Fr(:)),'dist',struct('mito',abs(X-5)), ...
    'calib',struct('fovUm',fov,'binNm',bin,'pixSizeUm',0.16,'dt_s',0.02,'precNm',bin));
Tracks = T; %#ok<NASGU>
save(fullfile(ana,'TrackStruct.mat'),'Tracks','-v7.3');
calib = struct('pixSizeUm',0.16,'fovUm',fov,'dt_s',0.02,'binNm',bin,'snapFovUm',fov); %#ok<NASGU>
save(fullfile(ana,'cs_calib.mat'),'calib');
fid = fopen(fullfile(ana,'csIDs','cellA_CSsites.txt'),'w');
fprintf(fid,' \tX\tY\tXM\tYM\tSlice\tCounter\tCount\n');
fprintf(fid,'1\t%.3f\t%.3f\t%.3f\t%.3f\t1\t2\t0\n', 5/SF, 5/SF, 5/SF, 5/SF);
fprintf(fid,'2\t%.3f\t%.3f\t%.3f\t%.3f\t1\t2\t0\n', 7/SF, 5/SF, 7/SF, 5/SF);
fclose(fid);

f = spt_analyze_app('analyze'); f.Position = [60 60 1500 900]; f.Visible = 'on';
closeApp = onCleanup(@() closeQuietly(f));
pe = findobj(f,'Type','uieditfield');
for k = 1:numel(pe)
    if contains(lower(string(pe(k).Placeholder)),'project')
        pe(k).Value = proj; cb = pe(k).ValueChangedFcn; if ~isempty(cb), cb(pe(k), struct('Value',proj)); end
    end
end
tg = findobj(f,'Type','uitabgroup'); tabs = tg(1).Children;
tg(1).SelectedTab = tabs(arrayfun(@(t) contains(string(t.Title),'Refine'), tabs)); drawnow;
b = findobj(f,'Type','uibutton'); b = b(arrayfun(@(x) contains(string(x.Text),'Load / build'), b));
b(1).ButtonPushedFcn(b(1), struct()); drawnow;
lst = findobj(f,'Type','uilistbox'); lst = lst(arrayfun(@(x) any(startsWith(string(x.Items),'c1 ')), lst));
lst.Value = lst.ItemsData(1); lst.ValueChangedFcn(lst, struct()); drawnow;
ax = findobj(f,'Tag','refAxes');
assert(~isempty(ax) && ~isempty(findobj(f,'Type','colorbar')), ...
    'the Refine editor has no colorbar; this test pins the colorbar case and would pass for the wrong reason');
pause(1.5);

tc = matlab.uitest.TestCase.forInteractiveUse;
wheel(tc, ax, 'opened site');

% (3) after an edit redraws the site, and after a colour-scale change
st = f.UserData.refState();
f.UserData.refMoveCentre(st.sel, st.foot(st.sel).center + [0.02 0]); drawnow; pause(0.8);
wheel(tc, ax, 'after an edit');
dd = findobj(f,'Type','uidropdown'); dd = dd(arrayfun(@(x) any(strcmp(x.Items,'locs / bin')), dd));
dd.Value = 'locs / bin'; dd.ValueChangedFcn(dd, struct()); drawnow; pause(0.8);
wheel(tc, ax, 'after a colour-scale change');

fprintf('\nREFINE-ZOOM SMOKE PASSED.\n');
end

% ================================================================================================
function wheel(tc, ax, when)
w0 = diff(ax.XLim);
for q = 1:5, tc.scroll(ax, 'down'); pause(0.25); end
w1 = diff(ax.XLim);
assert(w1 > w0*1.02, ...
    ['%s: five scroll-wheel steps OUT left the view at %.4f um wide (was %.4f). The wheel does ' ...
     'nothing — the colorbar has disabled the axes'' interactions again.'], when, w1, w0);
for q = 1:5, tc.scroll(ax, 'up'); pause(0.25); end
w2 = diff(ax.XLim);
assert(w2 < w1*0.98, '%s: scrolling back IN did nothing (%.4f -> %.4f)', when, w1, w2);
fprintf('%-28s width %.3f -> out %.3f -> in %.3f um\n', when, w0, w1, w2);
end

function closeQuietly(f)
try, if isgraphics(f), close(f); end, catch, end
end
