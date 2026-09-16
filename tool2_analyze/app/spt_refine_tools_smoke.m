function spt_refine_tools_smoke()
%SPT_REFINE_TOOLS_SMOKE  The Refine tab must show where the other sites are, never make a linked
%localization look unlinked, let the centre move on its own, and hand exactly that to the export.
%
% WHAT IS ASSERTED:
%   1. THE INFO PANEL IS READABLE. It sat in a 30 px row, so of its six lines only "area" and
%      "tracks" rendered — the localization count added for cross-checking was drawn and clipped.
%      Checked on the rendered height, which is what the user sees.
%   2. OTHER SITES ARE OUTLINED — every other site in the same cell AND window, labelled, and none
%      from another window. The toggle removes them. Clicking one opens it.
%   3. NO DOT LOOKS UNLINKED. With localizations on, every track with a localization in the window
%      is drawn — members in yellow, the rest faintly — so the drawn tracks account for every dot.
%      On real data 45 of 69 dots in one view belonged to non-member tracks and had no line.
%   4. MOVE CENTRE MOVES ONLY THE CENTRE. The boundary stays put on the map, so area, members and
%      the localization count are unchanged; the mode records it; the tab knows it is unsaved.
%   5. THE EXPORT WARNS ABOUT UNSAVED EDITS, and after Save carries the moved centre.
%   6. HAND-REJECTED TRACKS ARE OUT OF THE REFINE DENSITY: the "window locs" total is the blanked
%      matrix's, not the build's.
%   7. THE VIEW IS THE USER'S. An edit redraws the same site without re-framing it; "view ± µm"
%      zooms out without the mouse and holds for every site; opening a neighbour from its outline
%      keeps the zoom level. (That the scroll wheel works at all is spt_refine_zoom_smoke.)
%   8. THE EXPORT IS NAMED IN A DIALOG that refuses a name already used and shows the folder it will
%      write, and the export carries BOTH site sets.
%
% Synthetic; reads no dataset.

here = fileparts(mfilename('fullpath'));
addpath(here); addpath(fullfile(here,'..','drivers'));
addpath(fullfile(fileparts(fileparts(here)),'tool1_track'));

proj = fullfile(tempdir, sprintf('spt_reftools_%d', feature('getpid')));
if isfolder(proj), rmdir(proj,'s'); end
ana = fullfile(proj,'analysis'); mkdir(fullfile(ana,'csIDs'));
cleanup = onCleanup(@() rmdir(proj,'s'));

fov = 16; bin = 30; n = ceil(fov/(bin/1000)); SF = fov/n;
rng(5); nF = 60;
tracks = {};
for c = {[5 5],[7 5],[5 7.5]}
    for j = 1:6, tracks{end+1} = c{1} + 0.02*cumsum(randn(nF,2))/4; end %#ok<AGROW>
end
for j = 1:12, tracks{end+1} = 2 + 10*rand(1,2) + 0.05*cumsum(randn(nF,2))/4; end %#ok<AGROW>
nT = numel(tracks); X = nan(nF,nT); Y = X;
for j = 1:nT, X(:,j) = tracks{j}(:,1); Y(:,j) = tracks{j}(:,2); end
Fr = repmat((0:nF-1)',1,nT);
T = struct('file','cellA','matrix',cat(3,Fr,X,Y),'frameInterval',0.02,'lengths',repmat(nF,nT,1), ...
    'trackIDs',(1:nT)','allSpots',struct('X',X(:),'Y',Y(:),'FRAME',Fr(:)), ...
    'dist',struct('mito',abs(X-5)), ...
    'calib',struct('fovUm',fov,'binNm',bin,'pixSizeUm',0.16,'dt_s',0.02,'precNm',bin));
Tracks = T; %#ok<NASGU>
save(fullfile(ana,'TrackStruct.mat'),'Tracks','-v7.3');
calib = struct('pixSizeUm',0.16,'fovUm',fov,'dt_s',0.02,'binNm',bin,'snapFovUm',fov); %#ok<NASGU>
save(fullfile(ana,'cs_calib.mat'),'calib');
ex = cs_track_exclusions('toggle', cs_track_exclusions('load', proj), 'cellA', 1, 'smoke');
cs_track_exclusions('save', proj, ex);

% three sites in window 1 and one in window 2 (which must NOT be outlined on window-1 sites)
picks = [5 5 1; 7 5 1; 5 7.5 1; 7 5 2];
fid = fopen(fullfile(ana,'csIDs','cellA_CSsites.txt'),'w');
fprintf(fid,' \tX\tY\tXM\tYM\tSlice\tCounter\tCount\n');
for j = 1:size(picks,1)
    fprintf(fid,'%d\t%.3f\t%.3f\t%.3f\t%.3f\t%d\t%d\t%d\n', j, picks(j,1)/SF, picks(j,2)/SF, picks(j,1)/SF, picks(j,2)/SF, picks(j,3), 2, 0);
end
fclose(fid);
windows = struct('framesPerWindow',30,'nWindows',2,'ranges',[0 29; 30 59],'grid',n,'SF_umPerPx',SF, ...
                 'frameInterval',0.02,'source','tracked'); %#ok<NASGU>
save(cs_ana_path(ana,'density','Density_cellA_CSwindows.mat'),'windows');

f = spt_analyze_app('analyze'); f.Visible = 'off'; f.Position = [1 1 1700 1000];
closeApp = onCleanup(@() close(f));
pe = findobj(f,'Type','uieditfield');
for k = 1:numel(pe)
    if contains(lower(string(pe(k).Placeholder)),'project')
        pe(k).Value = proj; cb = pe(k).ValueChangedFcn; if ~isempty(cb), cb(pe(k), struct('Value',proj)); end
    end
end
selectTab(f, 'Refine');
press(f, 'Load / build contact sites');
lst = one(findobj(f,'Type','uilistbox'), 'Refine site list', @(x) any(startsWith(string(x.Items),'c1 ')));
ax  = one(findobj(f,'Tag','refAxes'), 'Refine axes');
st0 = f.UserData.refState();
k1 = find([st0.foot.csID]==1);
lst.Value = k1; lst.ValueChangedFcn(lst, struct()); drawnow;

%% (1) the info panel is readable -----------------------------------------------------------------------
info = one(findobj(f,'Type','uilabel'), 'Refine info label', @(x) startsWith(string(x.Text),'area '));
txt = char(strjoin(string(info.Text), newline));
assert(contains(txt,'window locs inside'), 'the info label no longer carries the loc count: "%s"', txt);
assert(info.Position(4) >= 90, ...
    ['the info label renders %g px tall. It holds six lines; at 30 px only the first two were ever ' ...
     'visible, which is how the localization count went unseen.'], info.Position(4));

%% (2) other sites are outlined: same window only; toggle; click to open --------------------------------
nb = findobj(ax,'Tag','refNeighbour');
assert(numel(nb) == 2, ...
    ['site 1 shows %d other-site outline(s). Its window holds 2 other sites (a 4th site is in window ' ...
     '2 and must not be drawn here).'], numel(nb));
lab = findobj(ax,'Tag','refNeighbourLabel');
assert(isequal(sort(string({lab.String})), ["s2" "s3"]), 'the outlines are labelled %s', strjoin(string({lab.String}),', '));
chkNbr = one(findobj(f,'Type','uicheckbox'), 'other-sites toggle', @(x) strcmp(x.Text,'other sites'));
chkNbr.Value = false; chkNbr.ValueChangedFcn(chkNbr, struct()); drawnow;
assert(isempty(findobj(ax,'Tag','refNeighbour')), 'turning "other sites" off left outlines drawn');
chkNbr.Value = true; chkNbr.ValueChangedFcn(chkNbr, struct()); drawnow;
nb = findobj(ax,'Tag','refNeighbour');
hit = nb(1); hit.ButtonDownFcn(hit, struct()); drawnow;
s2 = f.UserData.refState();
assert(s2.sel ~= k1 && s2.foot(s2.sel).window == 1 && ismember(s2.foot(s2.sel).csID, [2 3]), ...
    'clicking an outline did not open that site (selection is %d)', s2.sel);
lst.Value = k1; lst.ValueChangedFcn(lst, struct()); drawnow;

%% (3) no dot looks unlinked -----------------------------------------------------------------------------
chkLoc = one(findobj(f,'Type','uicheckbox'), 'localizations toggle', @(x) strcmp(x.Text,'localizations'));
chkLoc.Value = true; chkLoc.ValueChangedFcn(chkLoc, struct()); drawnow;
other = findobj(ax,'Tag','refOtherTracks');
assert(numel(other) == 1, 'expected one faint line object for the non-member tracks, found %d', numel(other));
nOtherDrawn = nnz(isnan(other.XData));                       % one NaN terminates each track
Xb = X; Xb(:,1) = NaN;                                       % the rejected track is out
inW = Fr <= 29;
nWithLocs = nnz(sum(isfinite(Xb) & inW, 1) >= 2);
ttl = char(string(ax.Title.String));
nMem = sscanf(regexp(ttl,'(\d+) trk','match','once'),'%d');
assert(nOtherDrawn + nMem == nWithLocs, ...
    ['%d member + %d other track(s) drawn, but %d tracks have localizations in this window. A dot ' ...
     'whose track is not drawn looks UNLINKED.'], nMem, nOtherDrawn, nWithLocs);

%% (6) the rejected track is out of the Refine numbers -----------------------------------------------------
txt = char(strjoin(string(info.Text), newline));
totTok = regexp(txt,'of (\d+) window locs','tokens','once');
assert(~isempty(totTok), 'the info label has no "of N window locs": "%s"', txt);
tot = str2double(totTok{1});
assert(tot == nnz(isfinite(Xb) & inW), ...
    'Refine counts %d window localizations; without the rejected track there are %d (with it, %d)', ...
    tot, nnz(isfinite(Xb) & inW), nnz(isfinite(X) & inW));

%% (7) the view is the user's ----------------------------------------------------------------------------
spv = one(findobj(f,'Tag','refView'), 'view spinner');
spv.Value = 3; spv.ValueChangedFcn(spv, struct()); drawnow;
eK = f.UserData.refState().foot(k1);
assert(abs(diff(ax.XLim) - 6) < 1e-9 && abs(mean(ax.XLim) - eK.center(1)) < 1e-9, ...
    'view ± 3 µm gave x %s; it should be 6 µm wide around the site centre %.3f', mat2str(ax.XLim,4), eK.center(1));
lst.Value = s2.sel; lst.ValueChangedFcn(lst, struct()); drawnow;
assert(abs(diff(ax.XLim) - 6) < 1e-9, 'the ± 3 µm view did not hold for the next site (%s)', mat2str(ax.XLim,4));
spv.Value = 0; spv.ValueChangedFcn(spv, struct()); drawnow;
lst.Value = k1; lst.ValueChangedFcn(lst, struct()); drawnow;
fitW = diff(ax.XLim);
% zoom out by hand (what the wheel does), then open a neighbour FROM ITS OUTLINE: same zoom level
xlim(ax, mean(ax.XLim) + [-4 4]); ylim(ax, mean(ax.YLim) + [-4 4]); drawnow;
nb = findobj(ax,'Tag','refNeighbour'); nb(1).ButtonDownFcn(nb(1), struct()); drawnow;
sN = f.UserData.refState();
assert(abs(diff(ax.XLim) - 8) < 1e-9 && abs(mean(ax.XLim) - sN.foot(sN.sel).center(1)) < 1e-9, ...
    ['opening a neighbour from its outline changed the zoom to %s — it should keep the 8 µm view ' ...
     'you found it in, centred on the neighbour'], mat2str(ax.XLim,4));
lst.Value = k1; lst.ValueChangedFcn(lst, struct()); drawnow;
assert(abs(diff(ax.XLim) - fitW) < 1e-9, 'choosing a site from the LIST did not fit it again');

%% (4) move centre moves only the centre ------------------------------------------------------------------
e0 = s2.foot(k1);
abs0 = e0.refboundary + e0.center;
ttl0 = char(string(ax.Title.String));
newC = e0.center + [0.04 -0.03];
xlim(ax, mean(ax.XLim) + [-2.5 2.5]); ylim(ax, mean(ax.YLim) + [-2.5 2.5]); drawnow;
xlKeep = ax.XLim;
f.UserData.refMoveCentre(k1, newC); drawnow;
assert(isequal(ax.XLim, xlKeep), ...
    'an edit re-framed the view (%s -> %s); zooming out and then editing snapped back in', mat2str(xlKeep,4), mat2str(ax.XLim,4));
s4 = f.UserData.refState(); e1 = s4.foot(k1);
assert(max(abs(e1.center - newC)) < 1e-12, 'the centre did not move to where it was put');
assert(max(abs((e1.refboundary + e1.center) - abs0), [], 'all') < 1e-12, ...
    'moving the centre moved the BOUNDARY on the map; it must stay put');
ttl1 = char(string(ax.Title.String));
assert(strcmp(regexp(ttl0,'\d+ trk \S+ \d+ loc','match','once'), regexp(ttl1,'\d+ trk \S+ \d+ loc','match','once')), ...
    'members or localizations changed when only the centre moved: "%s" -> "%s"', ttl0, ttl1);
assert(endsWith(char(e1.mode), '+centre') && e1.edited && s4.dirty, ...
    'the move is not recorded (mode "%s", edited %d, dirty %d)', char(e1.mode), e1.edited, s4.dirty);

%% (5) the export warns about unsaved edits, and carries the saved centre ------------------------------------
selectTab(f, 'Contact sites');
mkdir(fullfile(ana,'exports','taken')); fclose(fopen(fullfile(ana,'exports','taken','x.txt'),'w'));
dlgLog = struct('refusedTaken',false,'preview','');
tmr = timer('StartDelay',1.0,'TimerFcn',@(~,~) answerDialog());
start(tmr);
press(f, 'Export for advisor');                 % opens the dialog; the timer answers it
stop(tmr); delete(tmr);
assert(dlgLog.refusedTaken, ...
    'the name dialog let "taken" through although exports/taken already holds files');
assert(contains(dlgLog.preview, 'exports/first_run'), ...
    'the dialog did not show the folder it would write (it said "%s")', dlgLog.preview);
assert(isfolder(fullfile(ana,'exports','first_run')), 'the export did not go to the name typed in the dialog');
lblCS = one(findobj(f,'Type','uilabel'), 'contact-sites status', @(x) contains(string(x.Text),'Exported'));
assert(contains(string(lblCS.Text), 'UNSAVED'), ...
    'exported while the Refine tab held an unsaved edit, and said nothing: "%s"', lblCS.Text);
btn = one(findobj(f,'Type','uibutton'), 'export button', @(x) contains(string(x.Text),'Export for advisor'));
assert(startsWith(string(btn.Text), "✓") && contains(string(btn.Tooltip), '1 cell'), ...
    'the export button did not show that it worked: "%s" / "%s"', btn.Text, btn.Tooltip);
assert(isequal(btn.BackgroundColor, [0.98 0.88 0.70]), ...
    'the button went plain green although the export left an unsaved Refine edit behind');
selectTab(f, 'Refine');
press(f, 'Save');
assert(~f.UserData.refState().dirty, 'Save left the Refine tab marked unsaved');
assert(~startsWith(string(btn.Text), "✓"), ...
    'saving new footprints left the export button saying the (now stale) export succeeded');
selectTab(f, 'Contact sites');
f.UserData.csExport('second_run'); drawnow;
assert(~contains(string(lblCS.Text), 'UNSAVED'), 'after Save the export still warns: "%s"', lblCS.Text);
assert(isequal(btn.BackgroundColor, [0.83 0.93 0.83]), 'a clean export did not turn the button green');
% The folder THIS export wrote, from the button's own report — not the newest folder on disk:
% dir() timestamps have one-second resolution, so two exports a second apart can tie.
outDir = strtrim(extractAfter(string(btn.Tooltip), "→ "));
assert(strlength(outDir) > 0 && isfolder(outDir), 'the export button does not say where it wrote: "%s"', btn.Tooltip);
assert(endsWith(outDir, "second_run"), 'the second export went to %s', outDir);
assert(isfile(fullfile(outDir,'sites','cellA_contactsites.csv')) && isfile(fullfile(outDir,'contactsites_all.csv')), ...
    'the export is missing the contact-site (picker) tables');
C = readtable(fullfile(outDir, 'sites', 'cellA_refinedsites.csv'));
r = C(C.csID==1,:);
assert(height(r) == 1, 'site 1 appears %d times in the export', height(r));
assert(abs(r.x_um - newC(1)) < 1e-9 && abs(r.y_um - newC(2)) < 1e-9, ...
    'the export has site 1 at (%.4f, %.4f); the saved centre is (%.4f, %.4f)', r.x_um, r.y_um, newC(1), newC(2));

%% (6b) the PICKER gets the same filtered set from the app ------------------------------------------------
press(f, 'Open windowed picker');
pk = one(findobj(f,'Type','uilabel'), 'picker status line', @(x) contains(string(x.Text),'density from tracked'));
assert(contains(string(pk.Text), 'minus 1 hand-rejected track'), ...
    'the picker opened from the app does not exclude the hand-rejected track: "%s"', pk.Text);
assert(~startsWith(string(btn.Text), "✓"), 'reopening the picker left the export button vouching for the last export');

fprintf('info panel %g px · 2 same-window outlines, toggle + click work · %d member + %d other tracks = every track with locs · centre moved, boundary fixed · export warns, then carries it\n', ...
    info.Position(4), nMem, nOtherDrawn);
fprintf('\nREFINE-TOOLS SMOKE PASSED.\n');

    function answerDialog()
        dqFig = findall(groot, 'Type','figure', 'Name','Export for advisor');
        if isempty(dqFig), return; end
        dqFig = dqFig(1);
        dqEdit = findall(dqFig, 'Type','uieditfield'); dqGo = findall(dqFig, 'Type','uibutton', 'Text','Export');
        dqLbl = findall(dqFig, 'Type','uilabel');
        dqEdit.Value = 'taken'; dqEdit.ValueChangedFcn(dqEdit, struct()); drawnow;
        dlgLog.refusedTaken = strcmp(dqGo.Enable, 'off');
        dqGo.ButtonPushedFcn(dqGo, struct()); drawnow;          % must NOT close: the name is taken
        if ~isgraphics(dqFig), dlgLog.refusedTaken = false; return; end
        dqEdit.Value = 'first run'; dqEdit.ValueChangedFcn(dqEdit, struct()); drawnow;
        dqTxt = arrayfun(@(x) char(string(x.Text)), dqLbl, 'uni', 0);
        dlgLog.preview = strjoin(dqTxt(contains(dqTxt,'Will write')), ' ');
        dqGo.ButtonPushedFcn(dqGo, struct());
    end

end

% ================================================================================================
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
% Buttons on the SELECTED tab only: "Save" exists on several tabs.
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
